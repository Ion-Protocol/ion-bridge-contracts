// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {BoringVaultL2OFT} from "./../../src/BoringVaultL2OFT.sol";
import {BaseScript} from "../Base.s.sol";
import {CREATEX} from "./../../src/Constants.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";

import {SafeCastLib} from "@solmate/utils/SafeCastLib.sol";
import { stdJson as StdJson } from "forge-std/StdJson.sol";

contract DeployL2 is BaseScript, TestHelperOz5 {    
    using SafeCastLib for uint256;
    using StdJson for string;

    string configPath = "./deployment-config/02_DeployL2.json";
    string config = vm.readFile(configPath);

    bytes32 l2OFTSalt = config.readBytes32(".l2OFTSalt");
    address base = config.readAddress(".base");
    uint256 startingExchangeRate = config.readUint(".startingExchangeRate");
    uint256 allowedExchangeRateChangeUpper = config.readUint(".allowedExchangeRateChangeUpper");
    uint256 allowedExchangeRateChangeLower = config.readUint(".allowedExchangeRateChangeLower");
    uint256 minimumUpdateDelayInSeconds = config.readUint(".minimumUpdateDelayInSeconds");
    string name = config.readString(".name");
    string symbol = config.readString(".symbol");
    address lzEndpoint = config.readAddress(".lzEndpoint");
    address delegate = config.readAddress(".delegate");

    function run() public broadcast returns (BoringVaultL2OFT boringVaultL2OFT){
        bytes memory boringVaultL2OFTCreationCode = type(BoringVaultL2OFT).creationCode;

        boringVaultL2OFT = BoringVaultL2OFT(
            CREATEX.deployCreate3(
                l2OFTSalt,
                abi.encodePacked(
                    boringVaultL2OFTCreationCode,
                    abi.encode(
                        base,
                        startingExchangeRate,
                        allowedExchangeRateChangeUpper,
                        allowedExchangeRateChangeLower,
                        minimumUpdateDelayInSeconds,
                        name,
                        symbol,
                        lzEndpoint,
                        delegate
                    )
                )
            )
        );
    }
}