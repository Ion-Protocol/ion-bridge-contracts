// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {BoringVaultL2OFT} from "./../../src/BoringVaultL2OFT.sol";
import {BoringVaultOFTAdapter} from "./../../src/BoringVaultOFTAdapter.sol";
import {BoringVaultCrossChainDepositor} from "./../../src/BoringVaultCrossChainDepositor.sol";
import {BaseScript} from "../Base.s.sol";
import {CREATEX} from "./../../src/Constants.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import { MessagingFee } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { OptionsBuilder } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {SendParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";

import {SafeCastLib} from "@solmate/utils/SafeCastLib.sol";
import { stdJson as StdJson } from "forge-std/StdJson.sol";

interface IWETH {
    function deposit() external payable;
    function approve(address, uint256) external;
    function balanceOf(address) external view returns (uint256);
}

contract TestBridge is BaseScript {    
    using SafeCastLib for uint256;
    using StdJson for string;
    using OptionsBuilder for bytes;

    function run() public broadcast {

        uint256 depositAmt = 0.000123 ether;

        BoringVaultOFTAdapter oftAdapter = BoringVaultOFTAdapter(0x0000000000d8858E1A9B373582A691dB992C23CA);
        BoringVaultCrossChainDepositor depositor = BoringVaultCrossChainDepositor(0x00000000008a3A77bd91bC738Ed2Efaa262c3763);
        
        // mint base asset 
        IWETH base = IWETH(0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9);
        base.deposit{value: depositAmt}();
        
        // approve adapter
        base.approve(address(depositor), type(uint256).max);
        depositor.maxApprove(ERC20(address(base)));        

        uint128 gasLimit = 200000;
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(gasLimit, 0);
        SendParam memory sendParam = SendParam({
            dstEid: 40232,
            to: bytes32(uint256(uint160(address(0x94544835Cf97c631f101c5f538787fE14E2E04f6)))),
            amountLD: depositAmt,
            minAmountLD: depositAmt,
            extraOptions: options, 
            composeMsg: "",
            oftCmd: "" 
        });
        MessagingFee memory fee = oftAdapter.quoteSend(sendParam, false);

        depositor.deposit{value: fee.nativeFee}(
            ERC20(address(base)),
            depositAmt,
            depositAmt,
            broadcaster,
            gasLimit
        );
    }
}