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
import {Test, stdStorage, StdStorage, stdError, console} from "forge-std/Test.sol";

import { console2 } from "forge-std/console2.sol";

contract BoringVaultAdapterTest is TestHelperOz5 {
    using stdStorage for StdStorage;
    using OptionsBuilder for bytes;

    ERC20 constant WETH = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    ERC20 constant WSTETH = ERC20(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);

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
    ILayerZeroEndpointV2 mainnetEndpoint = ILayerZeroEndpointV2(0x1a44076050125825900e736c501f859c50fE728c);
    OFT oftL2;

    uint8 l1Eid;
    uint8 l2Eid;

    uint32 constant SEI_EID = 30280;

    function setUp() public override {
        vm.createSelectFork(
            vm.envString("MAINNET_RPC_URL"),
            20027194
        );

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
        
        address mainnetEndpoint = endpoints[l1Eid];
        address rollupEndpoint = endpoints[l2Eid];

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
            "Ion Boring Vault",
            "IBV",
            address(rollupEndpoint),
            delegate
        );

        address[] memory ofts = new address[](2);
        ofts[0] = address(oftAdapterL1);
        ofts[1] = address(oftL2);
        this.wireOApps(ofts);

        // --- Assets Setup ---
        
        WETH.approve(address(boringVault), type(uint256).max);
        WSTETH.approve(address(boringVault), type(uint256).max);
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
        WETH.approve(address(crossChainDepositorL1), depositAmt);

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);

        // Simulate costs 
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

        // deposits to teller, then calls `send` on OFTAdapter
        uint256 sharesMinted = crossChainDepositorL1.deposit{value: fee.nativeFee}(
            WETH,
            depositAmt,
            minimumMint,
            address(this),
            options
        );

        // verifyPackets(l2Eid, addressToBytes32(address(oftL2)));

        assertEq(boringVault.balanceOf(address(oftAdapterL1)), sharesMinted, "shares locked in adapter");
        // assertEq(oftL2.balanceOf(address(this)), sharesMinted, "mints OFT to user");

    }

    function test_Revert_DepositAndBridge_BelowMinimumMint() public {

    }
}