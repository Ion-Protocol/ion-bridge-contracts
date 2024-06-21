// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {BoringVaultCrossChainDepositor} from "./../../src/BoringVaultCrossChainDepositor.sol";
import {BoringVaultOFTAdapter} from "./../../src/BoringVaultOFTAdapter.sol";
import {BaseScript} from "../Base.s.sol";
import {CREATEX} from "./../../src/Constants.sol";

import {SafeCastLib} from "@solmate/utils/SafeCastLib.sol";
import { stdJson as StdJson } from "forge-std/StdJson.sol";

contract DeployL1 is BaseScript {    
    using SafeCastLib for uint256;
    using StdJson for string;

    string configPath = "./deployment-config/01_DeployL1.json";
    string config = vm.readFile(configPath);

    bytes32 oftAdapterSalt = config.readBytes32(".oftAdapterSalt");
    bytes32 depositorSalt = config.readBytes32(".depositorSalt");

    address boringVault = config.readAddress(".boringVault");
    address teller = config.readAddress(".teller");
    address l1Endpoint = config.readAddress(".l1Endpoint");
    address l2Endpoint = config.readAddress(".l2Endpoint");
    address delegate = config.readAddress(".delegate");

    uint32 l2Eid = config.readUint(".l2Eid").safeCastTo32();

    function run() public broadcast returns (BoringVaultOFTAdapter boringVaultOFTAdapter, BoringVaultCrossChainDepositor boringVaultCrossChainDepositor){
        bytes memory boringVaultOFTAdapterCreationCode = type(BoringVaultOFTAdapter).creationCode;

        boringVaultOFTAdapter = BoringVaultOFTAdapter(
            CREATEX.deployCreate3(
                oftAdapterSalt,
                abi.encodePacked(
                    boringVaultOFTAdapterCreationCode,
                    abi.encode(
                        boringVault,
                        l1Endpoint,
                        delegate
                    )
                )
            )
        );

        bytes memory boringVaultCrossChainDepositorCreationCode = type(BoringVaultCrossChainDepositor).creationCode;

        boringVaultCrossChainDepositor = BoringVaultCrossChainDepositor(
            CREATEX.deployCreate3(
                depositorSalt,
                abi.encodePacked(
                    boringVaultCrossChainDepositorCreationCode,
                    abi.encode(
                        boringVault,
                        teller,
                        boringVaultOFTAdapter,
                        l2Eid
                    )
                )
            )
        );
    }
}