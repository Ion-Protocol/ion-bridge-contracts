// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { OFTAdapter } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFTAdapter.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract BoringVaultOFTAdapter is OFTAdapter {
    constructor(
        address _token, 
        address _lzEndpoint, 
        address _delegate // TODO Why is this being passed as a delegate?
    ) OFTAdapter(_token, _lzEndpoint, _delegate) Ownable(_delegate) {} 
}
