// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {BoringVault} from "@ion-boring-vault/base/BoringVault.sol";
import {TellerWithMultiAssetSupport} from "@ion-boring-vault/base/Roles/TellerWithMultiAssetSupport.sol";
import { OFTAdapter } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFTAdapter.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import {SendParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import { MessagingFee } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/**
 * @notice Allows the caller to atomically deposit into a BoringVault and bridge it crosschain.
 */
contract BoringVaultCrossChainDepositor {
    using SafeTransferLib for ERC20;

    // --- Errors ---
    error BelowMinimumMint(uint256 shares, uint256 minimumMint);
    error InvalidOFTAdapter();
    error InvalidTeller();

    uint32 immutable dstEid;
    BoringVault immutable boringVault;
    TellerWithMultiAssetSupport immutable teller;
    OFTAdapter immutable oftAdapter;

    /**
     * @dev The boring vault token must be the `innerToken` of the OFTAdapter.
     */
    constructor(
        BoringVault _boringVault,
        TellerWithMultiAssetSupport _teller,
        OFTAdapter _oftAdapter,
        uint32 _dstEid
    ) {
        boringVault = _boringVault;
        teller = _teller;
        oftAdapter = _oftAdapter;
        dstEid = _dstEid;

        if (_teller.vault() != _boringVault) revert InvalidTeller();
        if (_oftAdapter.token() != address(_boringVault)) revert InvalidOFTAdapter();

        // Gives infinite approvals for the OFTAdapter to transfer boring vault
        // tokens.
        _boringVault.approve(address(_oftAdapter), type(uint256).max);
    }

    /**
     * @notice Deposits into boring vault and bridges the boring vault shares to the L2.
     */
    function deposit(
        ERC20 depositAsset,
        uint256 depositAmount,
        uint256 minimumMint,
        address bridgeRecipient,
        bytes memory options // TODO should this be restricted or kept parameterizable
    ) external payable returns (uint256 shares) {
        depositAsset.safeTransferFrom(msg.sender, address(this), depositAmount);
        
        depositAsset.approve(address(boringVault), depositAmount);
        shares = teller.deposit(depositAsset, depositAmount, minimumMint);
        
        if (shares < minimumMint) revert BelowMinimumMint(shares, minimumMint);

        SendParam memory sendParam = SendParam({
            dstEid: dstEid,
            to: bytes32(uint256(uint160(bridgeRecipient))),
            amountLD: shares,
            minAmountLD: shares,
            extraOptions: options, 
            composeMsg: "",
            oftCmd: "" 
        });

        MessagingFee memory messagingFee = MessagingFee({
            nativeFee: msg.value,
            lzTokenFee: 0
        });
        
        oftAdapter.send{value: msg.value}({
            _sendParam: sendParam, 
            _fee: messagingFee,
            _refundAddress: msg.sender
        });
    }
}
