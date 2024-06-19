// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OFT} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFT.sol";
import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";

contract BoringVaultL2OFT is OFT {
    using FixedPointMathLib for uint256;

    event DelayInSecondsUpdated(uint32 minimumUpdateDelayInSeconds);
    event AllowedExchangeRateChangeUpperUpdated(uint16 allowedExchangeRateChangeUpper);
    event AllowedExchangeRateChangeLowerUpdated(uint16 allowedExchangeRateChangeLower);
    event ExchangeRateUpdated(uint96 currentExchangeRate, uint96 newExchangeRate);

    error InvalidAllowedExchangeRateChangeUpper();
    error InvalidAllowedExchangeRateChangeLower();
    error InvalidNewExchangeRate();

    struct AccountantState {
        uint96 exchangeRate;
        uint16 allowedExchangeRateChangeUpper;
        uint16 allowedExchangeRateChangeLower;
        uint64 lastUpdateTimestamp;
        uint32 minimumUpdateDelayInSeconds;
    }

    /**
     * @notice The base asset rates are provided in.
     */
    ERC20 public immutable base; 

    /**
     * @notice The decimals rates are provided in.
     * @dev Note that this could differ from the decimals of this OFT.
     */
    uint8 public immutable rateDecimals;

    /**
     * @notice The exchange rate per token denominated in the base asset.
     */
    uint256 public exchangeRate;

    /**
     * @notice The state for exchange rate and update constraints.
     */
    AccountantState public accountantState; 

    constructor(ERC20 _base, string memory _name, string memory _symbol, address _lzEndpoint, address _delegate)
        OFT(_name, _symbol, _lzEndpoint, _delegate)
        Ownable(_delegate)
    {
        base = _base;
        rateDecimals = _base.decimals();
    }

    function updateDelay(uint32 minimumUpdateDelayInSeconds) external onlyOwner {
        accountantState.minimumUpdateDelayInSeconds = minimumUpdateDelayInSeconds;
        emit DelayInSecondsUpdated(minimumUpdateDelayInSeconds);
    }

    function updateUpper(uint16 allowedExchangeRateChangeUpper) external onlyOwner {
        if (allowedExchangeRateChangeUpper < 1e4) revert InvalidAllowedExchangeRateChangeUpper();
        accountantState.allowedExchangeRateChangeUpper = allowedExchangeRateChangeUpper;
        emit AllowedExchangeRateChangeUpperUpdated(allowedExchangeRateChangeUpper);
    }

    function updateLower(uint16 allowedExchangeRateChangeLower) external onlyOwner {
        if (allowedExchangeRateChangeLower > 1e4) revert InvalidAllowedExchangeRateChangeLower();
        accountantState.allowedExchangeRateChangeLower = allowedExchangeRateChangeLower;
        emit AllowedExchangeRateChangeLowerUpdated(allowedExchangeRateChangeLower);
    }

    /**
     * @notice Relays the L1 `Accountant`'s `updateExchangeRate` to the L2.
     * @dev Implements the same update constraint logic as the `Teller` in the L1.
     */
    function updateExchangeRate(uint96 newExchangeRate) external onlyOwner {
        AccountantState storage state = accountantState;
        
        uint64 currentTime = uint64(block.timestamp);
        uint256 currentExchangeRate = state.exchangeRate;

        if (
            currentTime < state.lastUpdateTimestamp + state.minimumUpdateDelayInSeconds
                || newExchangeRate > currentExchangeRate.mulDivDown(state.allowedExchangeRateChangeUpper, 1e4)
                || newExchangeRate < currentExchangeRate.mulDivDown(state.allowedExchangeRateChangeLower, 1e4)
        ) revert InvalidNewExchangeRate();

        state.exchangeRate = newExchangeRate;  
        state.lastUpdateTimestamp = currentTime;

        emit ExchangeRateUpdated(uint96(currentExchangeRate), newExchangeRate);      
    }
}
