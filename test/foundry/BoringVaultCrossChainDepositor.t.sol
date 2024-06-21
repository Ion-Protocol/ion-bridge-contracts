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

using stdStorage for StdStorage;
using OptionsBuilder for bytes;

interface ISendUln302 {
    function getConfig(uint32 _eid, address _oapp, uint32 _configType) external view returns (bytes memory);
}

contract BoringVaultSharedSetup is TestHelperOz5 {
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

    BoringVaultL2OFT oftL2;

    uint8 l1Eid;
    uint8 l2Eid;

    uint32 constant SEI_EID = 30280;

    address immutable BRIDGE_RECIPIENT = makeAddr("BRIDGE RECIPIENT");

    uint256 INITIAL_EXCHANGE_RATE = 1e18;

    function setUp() public override virtual {
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
            INITIAL_EXCHANGE_RATE,
            1e4,
            1e4,
            3600,
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
}

contract BoringVaultAdapterTest is BoringVaultSharedSetup {

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


    /**
     * Change the Config Type ULN for the block confirmations required. 
     * Change the Config Type Executor 
     * struct UlnConfig {
     *     uint64 confirmations;
     *     // we store the length of required DVNs and optional DVNs instead of using DVN.length directly to save gas
     *     uint8 requiredDVNCount; // 0 indicate DEFAULT, NIL_DVN_COUNT indicate NONE (to override the value of default)
     *     uint8 optionalDVNCount; // 0 indicate DEFAULT, NIL_DVN_COUNT indicate NONE (to override the value of default)
     *     uint8 optionalDVNThreshold; // (0, optionalDVNCount]
     *     address[] requiredDVNs; // no duplicates. sorted an an ascending order. allowed overlap with optionalDVNs
     *     address[] optionalDVNs; // no duplicates. sorted an an ascending order. allowed overlap with requiredDVNs
     * }
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

    function test_BoringVaultL2OFT_UpdateDelay() public {

    }
}

contract BoringVaultL2OFTTest is BoringVaultSharedSetup {
    function setUp() public override {
        super.setUp();
        vm.warp(block.timestamp + 3600);   
    }

    /** Accountant State */

    function test_UpdateDelay() public {
        uint32 delay = 3600;
        oftL2.updateDelay(delay); 
        (,,,, uint32 actualDelay) = oftL2.accountantState();
        assertEq(actualDelay, delay, "delay");
    }   

    function test_Revert_UpdateDelay() public {
        uint32 delay = 0;
        vm.expectRevert(BoringVaultL2OFT.InvalidMinimumUpdateDelay.selector);
        oftL2.updateDelay(delay);
    }

    function test_UpdateUpper() public {
        uint16 changeUpper = 1.02e4; // should be 2%
        oftL2.updateUpper(changeUpper);
    } 
    
    function test_Revert_UpdateUpper() public {
        uint16 changeUpper = 0.99e4;
        vm.expectRevert(BoringVaultL2OFT.InvalidAllowedExchangeRateChangeUpper.selector);
        oftL2.updateUpper(changeUpper);
    }
    
    function test_UpdateLower() public {
        uint16 changeLower = 0.98e4;
        oftL2.updateLower(changeLower);
    }

    function test_Revert_UpdateLower() public {
        uint16 changeLower = 1.1e4; 
        vm.expectRevert(BoringVaultL2OFT.InvalidAllowedExchangeRateChangeLower.selector);
        oftL2.updateLower(changeLower);
    }

    function test_UpdateExchangeRate_WithinUpperBound() public {
        oftL2.updateUpper(1.02e4); // 2%
        oftL2.updateExchangeRate(1.02e18); 
        assertEq(oftL2.getRate(), 1.02e18, "exchange rate");
    }

    function test_Revert_UpdateExchangeRate_PastUpperBound() public {
        oftL2.updateUpper(1.02e4);
        vm.expectRevert(BoringVaultL2OFT.InvalidNewExchangeRate.selector);
        oftL2.updateExchangeRate(1.021e18);
    }

    function test_UpdateExchangeRate_WithinLowerBound() public {
        oftL2.updateLower(0.98e4);
        oftL2.updateExchangeRate(0.99e18);
        assertEq(oftL2.getRate(), 0.99e18, "exchange rate");
    }

    function test_Revert_UpdateExchangeRate_PastLowerBound() public {
        oftL2.updateLower(0.98e4);
        vm.expectRevert(BoringVaultL2OFT.InvalidNewExchangeRate.selector);
        oftL2.updateExchangeRate(0.97e18);
    }

    function test_UpdateExchangeRate_WithinMinimumDelay() public {
        oftL2.updateUpper(1.02e4);
        oftL2.updateExchangeRate(1.01e18);

        vm.warp(block.timestamp + 3600);
        oftL2.updateExchangeRate(1.02e18);
        assertEq(oftL2.getRate(), 1.02e18, "exchange rate");
    }

    function test_Revert_UpdateExchangeRate_WithinMinimumDelay() public {
        oftL2.updateUpper(1.02e4);
        oftL2.updateExchangeRate(1.01e18);

        vm.expectRevert(BoringVaultL2OFT.InvalidNewExchangeRate.selector);
        oftL2.updateExchangeRate(1.015e18);
    }

    /** Access Control */

    function test_UpdateExchangeRateRole() public {
        address updateRole = makeAddr("UPDATE_EXCHANGE_RATE_ROLE");

        assertEq(oftL2.updateExchangeRateRole(updateRole), false, "role not granted");

        oftL2.grantUpdateExchangeRateRole(updateRole);
        
        assertEq(oftL2.updateExchangeRateRole(updateRole), true, "role granted");

        oftL2.revokeUpdateExchangeRateRole(updateRole);

        assertEq(oftL2.updateExchangeRateRole(updateRole), false, "role revoked");
    }

    function test_AccessControl_GrantAndRevokeRoles() public {
        address delegate = makeAddr("DELEGATE");
        BoringVaultL2OFT oft = new BoringVaultL2OFT (
            WETH,
            INITIAL_EXCHANGE_RATE,
            1e4,
            1e4,
            3600,
            "Ion Boring Vault",
            "IBV",
            address(rollupEndpoint),
            delegate
        );

        address updateRole = makeAddr("UPDATE_EXCHANGE_RATE_ROLE");

        assertEq(oft.updateExchangeRateRole(updateRole), false, "role not granted");

        vm.prank(delegate);
        oft.grantUpdateExchangeRateRole(updateRole);
        
        assertEq(oft.updateExchangeRateRole(updateRole), true, "role granted");
    }

    function test_AccessControl_UpdateExchangeRate() public {
        address updateRoleOne = makeAddr("UPDATE_EXCHANGE_RATE_ROLE_ONE");
        address updateRoleTwo = makeAddr("UPDATE_EXCHANGE_RATE_ROLE_TWO");

        oftL2.grantUpdateExchangeRateRole(updateRoleOne);
        oftL2.grantUpdateExchangeRateRole(updateRoleTwo);

        vm.prank(updateRoleOne);
        oftL2.updateExchangeRate(1.01e18);

        assertEq(oftL2.getRate(), 1.01e18, "exchange rate update one");

        vm.warp(block.timestamp + 3600);

        vm.prank(updateRoleTwo); 
        oftL2.updateExchangeRate(1.02e18);
        assertEq(oftL2.getRate(), 1.02e18, "exchange rate update two");
    }

    function test_Revert_AccessControl_UpdateExchangeRate() public {
        vm.expectRevert(BoringVaultL2OFT.NotUpdateExchangeRateRole.selector);
        oftL2.updateExchangeRate(1e18);
    }

}