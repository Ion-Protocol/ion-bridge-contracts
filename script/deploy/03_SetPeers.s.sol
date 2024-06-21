// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {BoringVaultOFTAdapter} from "./../../src/BoringVaultOFTAdapter.sol";
import {BoringVaultL2OFT} from "./../../src/BoringVaultL2OFT.sol";
import {BaseScript} from "../Base.s.sol";
import {CREATEX} from "./../../src/Constants.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";

import {SafeCastLib} from "@solmate/utils/SafeCastLib.sol";
import { stdJson as StdJson } from "forge-std/StdJson.sol";

contract SetPeers is BaseScript, TestHelperOz5 {    
    using SafeCastLib for uint256;
    using StdJson for string;

    string configPath = "./deployment-config/03_SetPeers.json";
    string config = vm.readFile(configPath);

    BoringVaultOFTAdapter oftAdapterL1 = BoringVaultOFTAdapter(config.readAddress(".oftAdapterL1"));
    BoringVaultL2OFT oftL2 = BoringVaultL2OFT(config.readAddress(".oftL2"));
    uint32 l2Eid = config.readUint(".l2Eid").safeCastTo32();
    uint32 l1Eid = config.readUint(".l1Eid").safeCastTo32();

    function run() public broadcast {
        // NOTE Run with L1 RPC
        oftAdapterL1.setPeer(l2Eid, addressToBytes32(address(oftL2)));
        // NOTE Run with L2 RPC
        // oftL2.setPeer(l1Eid, addressToBytes32(address(oftAdapterL1)));
    }
}