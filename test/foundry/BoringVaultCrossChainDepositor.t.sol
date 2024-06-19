// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {BoringVaultCrossChainDepositor} from "../../src/BoringVaultCrossChainDepositor.sol";
import {BoringVaultOFTAdapter} from "./../../src/BoringVaultOFTAdapter.sol";
import {BoringVaultL2OFT} from "./../../src/BoringVaultL2OFT.sol";
import {BoringVault} from "@ion-boring-vault/base/BoringVault.sol";
import {AccountantWithRateProviders} from "@ion-boring-vault/base/Roles/AccountantWithRateProviders.sol";
import {TellerWithMultiAssetSupport} from "@ion-boring-vault/base/Roles/TellerWithMultiAssetSupport.sol";
import {RolesAuthority, Authority} from "@solmate/auth/authorities/RolesAuthority.sol";

import { OFTAdapter } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFTAdapter.sol";
import { OFT } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFT.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import { OptionsBuilder } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {SendParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import { MessagingFee } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {UlnConfig} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";

import {ERC20Mock} from "../mocks/ERC20Mock.sol";

import {Test, stdStorage, StdStorage, stdError, console} from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

interface ISendUln302 {
    function getConfig(uint32 _eid, address _oapp, uint32 _configType) external view returns (bytes memory);
}

contract BoringVaultAdapterTest is TestHelperOz5 {
    using stdStorage for StdStorage;
    using OptionsBuilder for bytes;

    ERC20 WETH = ERC20(address(new ERC20Mock("Wrapped Ether", "WETH"))); // ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    ERC20 WSTETH = ERC20(address(new ERC20Mock("Wrapped stETH", "wstETH"))); // ERC20(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);

    address VAULT_OWNER = makeAddr("BORING_VAULT_OWNER");

    BoringVault boringVault;
    AccountantWithRateProviders accountant;
    TellerWithMultiAssetSupport teller;

    RolesAuthority rolesAuthority;

    // --- Accountant ---
    address immutable PAYOUT_ADDRESS = makeAddr("PAYOUT_ADDRESS"); 
    uint96 immutable STARTING_EXCHANGE_RATE = 1e18; 
    uint16 immutable ALLOWED_EXCHANGE_RATE_CHANGE_UPPER = 1.005e4; 
    uint16 immutable ALLOWED_EXCHANGE_RATE_CHANGE_LOWER = 0.995e4;
    uint32 immutable MINIMUM_UPDATE_DELAY_IN_SECONDS = 3600; // 1 hour
    uint16 immutable MANAGEMENT_FEE = 0.2e4; // maximum 0.2e4
    
    // --- RolesAuthority --- 
    uint8 public constant MANAGER_ROLE = 1;
    uint8 public constant TELLER_ROLE = 3;
    
    // --- Bridge ---
    BoringVaultOFTAdapter oftAdapterL1;
    BoringVaultCrossChainDepositor crossChainDepositorL1;
    ILayerZeroEndpointV2 mainnetEndpoint; // = ILayerZeroEndpointV2(0x1a44076050125825900e736c501f859c50fE728c);
    ILayerZeroEndpointV2 rollupEndpoint;

    OFT oftL2;

    uint8 l1Eid;
    uint8 l2Eid;

    uint32 constant SEI_EID = 30280;

    address immutable BRIDGE_RECIPIENT = makeAddr("BRIDGE RECIPIENT");

    function setUp() public override {
        // --- Boring Vault Setup ---

        boringVault = new BoringVault(
            VAULT_OWNER,
            "Ion Boring Vault", 
            "IBV",
            18
        );

        accountant = new AccountantWithRateProviders(
            VAULT_OWNER,
            address(boringVault),
            PAYOUT_ADDRESS,
            STARTING_EXCHANGE_RATE,
            address(WETH), // BASE
            ALLOWED_EXCHANGE_RATE_CHANGE_UPPER,
            ALLOWED_EXCHANGE_RATE_CHANGE_LOWER,
            MINIMUM_UPDATE_DELAY_IN_SECONDS,
            MANAGEMENT_FEE
        );

        teller = new TellerWithMultiAssetSupport(
            VAULT_OWNER,
            address(boringVault),
            address(accountant),
            address(WETH) // NOTE NOT THE BASE ASSET, ALWAYS WETH FOR WRAPPER
        );

        rolesAuthority = new RolesAuthority(address(this), Authority(address(0)));

        rolesAuthority.setRoleCapability(
            TELLER_ROLE,
            address(boringVault),
            BoringVault.enter.selector,
            true
        );

        rolesAuthority.setRoleCapability(
            TELLER_ROLE,
            address(boringVault),
            BoringVault.exit.selector,
            true
        );

        rolesAuthority.setPublicCapability(
            address(teller), 
            TellerWithMultiAssetSupport.deposit.selector, 
            true
        );

        rolesAuthority.setUserRole(
            address(teller),
            TELLER_ROLE,
            true
        );

        vm.startPrank(VAULT_OWNER);
        accountant.setAuthority(rolesAuthority);
        boringVault.setAuthority(rolesAuthority);
        teller.setAuthority(rolesAuthority);
        
        teller.addAsset(WETH);
        teller.addAsset(WSTETH); 
        vm.stopPrank();
        
        // --- Bridge Setup ---
        // 1. Deploy endpoints on source and destination networks.
        // 2. Set OFTAdapter and OFT as peers.

        l1Eid = 1; 
        l2Eid = 2;

        setUpEndpoints(2, LibraryType.UltraLightNode);
        
        mainnetEndpoint = ILayerZeroEndpointV2(endpoints[l1Eid]);
        rollupEndpoint = ILayerZeroEndpointV2(endpoints[l2Eid]);

        address delegate = address(this);

        oftAdapterL1 = new BoringVaultOFTAdapter(
            address(boringVault),
            address(mainnetEndpoint), 
            delegate // TODO What are the delegate permissions
        );
        
        crossChainDepositorL1 = new BoringVaultCrossChainDepositor(
            boringVault,
            teller,
            oftAdapterL1,
            l2Eid
        );

        oftL2 = new BoringVaultL2OFT (
            WETH,
            "Ion Boring Vault",
            "IBV",
            address(rollupEndpoint),
            delegate
        );

        address[] memory ofts = new address[](2);
        ofts[0] = address(oftAdapterL1);
        ofts[1] = address(oftL2);
        
        // Sets peers
        // this.wireOApps(ofts);
        oftAdapterL1.setPeer(l2Eid, addressToBytes32(address(oftL2)));
        oftL2.setPeer(l1Eid, addressToBytes32(address(oftAdapterL1)));

        // --- Assets Setup ---
        
        WETH.approve(address(boringVault), type(uint256).max);
        WSTETH.approve(address(boringVault), type(uint256).max);

        WETH.approve(address(crossChainDepositorL1), type(uint256).max);
        WSTETH.approve(address(crossChainDepositorL1), type(uint256).max);
        
        crossChainDepositorL1.maxApprove(WETH);
    }

    function test_MaxApprove() public {
        assertEq(WETH.allowance(address(crossChainDepositorL1), address(boringVault)), 0, "no allowance"); 
        crossChainDepositorL1.maxApprove(WETH);
        assertEq(WETH.allowance(address(crossChainDepositorL1), address(boringVault)), type(uint256).max, "max allowance");
    }

    function test_Revert_MaxApproveAssetNotSupported() public {
        ERC20 token = ERC20(address(new ERC20Mock("Random Token", "TOKEN")));
        vm.expectRevert(BoringVaultCrossChainDepositor.AssetNotSupported.selector);
        crossChainDepositorL1.maxApprove(token); 
    }

    function test_Revert_OFTAdapterTokenIsNotBoringVault() public {

    }

    /**
     * Testing that the send transaction does not fail. 
     */
    function test_DepositAndBridge() public {
        uint256 depositAmt = 1e18;
        uint256 minimumMint = 1e18;

        deal(address(WETH), address(this), depositAmt);

        uint128 gasLimit = 200000;
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gasLimit, 0);
        console2.log('options');
        console2.logBytes(options);
        // Just for simulating costs
        SendParam memory sendParam = SendParam({
            dstEid: 2,
            to: bytes32(uint256(uint160(address(this)))),
            amountLD: 1e18,
            minAmountLD: 1e18,
            extraOptions: options, 
            composeMsg: "",
            oftCmd: "" 
        });
        MessagingFee memory fee = oftAdapterL1.quoteSend(sendParam, false);

        vm.deal(address(this), fee.nativeFee);

        // Deposits to the teller, then calls `send` on OFTAdapter
        uint256 sharesMinted = crossChainDepositorL1.deposit{value: fee.nativeFee}(
            WETH,
            depositAmt,
            minimumMint,
            BRIDGE_RECIPIENT,
            gasLimit
        );

        verifyPackets(l2Eid, addressToBytes32(address(oftL2)));

        assertEq(boringVault.balanceOf(address(oftAdapterL1)), sharesMinted, "shares locked in adapter");
        assertEq(oftL2.balanceOf(BRIDGE_RECIPIENT), sharesMinted, "mints OFT to user");
    }

    function test_DepositAndBridge_MultipleTransactions() public {
        uint256 depositAmt = 1e18;
        uint256 minimumMint = 1e18;

        deal(address(WETH), address(this), depositAmt);

        // (gas limit, msg.value) 
        // msg.value for the lzReceive() should be zero since the executor
        // doesn't need to send ether to complete the call.
        uint128 gasLimit = 200000;
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gasLimit, 0);

        // Just for simulating costs
        SendParam memory sendParam = SendParam({
            dstEid: 2,
            to: bytes32(uint256(uint160(address(this)))),
            amountLD: 1e18,
            minAmountLD: 1e18,
            extraOptions: options, 
            composeMsg: "",
            oftCmd: "" 
        });
        MessagingFee memory fee = oftAdapterL1.quoteSend(sendParam, false);                

        vm.deal(address(this), fee.nativeFee);
        
        bytes memory packetBytes0 = getNextInflightPacket(l2Eid, addressToBytes32(address(oftL2)));

        uint256 sharesMinted = crossChainDepositorL1.deposit{value: fee.nativeFee}(
            WETH,
            depositAmt,
            minimumMint,
            BRIDGE_RECIPIENT,
            gasLimit
        );
        
        bytes memory packetBytes = getNextInflightPacket(l2Eid, addressToBytes32(address(oftL2)));
        assertTrue(packetBytes.length != 0, "packetBytes are not empty");
    }


    // struct UlnConfig {
    //     uint64 confirmations;
    //     // we store the length of required DVNs and optional DVNs instead of using DVN.length directly to save gas
    //     uint8 requiredDVNCount; // 0 indicate DEFAULT, NIL_DVN_COUNT indicate NONE (to override the value of default)
    //     uint8 optionalDVNCount; // 0 indicate DEFAULT, NIL_DVN_COUNT indicate NONE (to override the value of default)
    //     uint8 optionalDVNThreshold; // (0, optionalDVNCount]
    //     address[] requiredDVNs; // no duplicates. sorted an an ascending order. allowed overlap with optionalDVNs
    //     address[] optionalDVNs; // no duplicates. sorted an an ascending order. allowed overlap with requiredDVNs
    // }
    /**
     * Change the Config Type ULN for the block confirmations required. 
     * Change the Config Type Executor 
     */
    function test_LayerZeroConfigs() public {
        uint8 CONFIG_TYPE_EXECUTOR = 1;
        uint8 CONFIG_TYPE_ULN = 2;

        address sendLibrary = mainnetEndpoint.getSendLibrary(address(oftAdapterL1), l2Eid);
        bool isDefaultSendLibrary = mainnetEndpoint.isDefaultSendLibrary(address(oftAdapterL1), l2Eid);
        (address receiveLibrary, bool isDefaultReceiveLibrary) = rollupEndpoint.getReceiveLibrary(address(oftL2), l1Eid);
        
        // Default config is stored at the zero oapp address.
        bytes memory sendExecutorConfig = ISendUln302(payable(sendLibrary)).getConfig(
            l1Eid,
            address(0),
            CONFIG_TYPE_EXECUTOR
        );

        bytes memory sendUlnConfig = ISendUln302(payable(sendLibrary)).getConfig(
            l1Eid,
            address(0),
            CONFIG_TYPE_ULN
        );
    }

    function test_Revert_DepositAndBridge_BelowMinimumMint() public {

    }
}