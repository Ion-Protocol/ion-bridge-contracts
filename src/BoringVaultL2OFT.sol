// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {OFT} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFT.sol";
import {FixedPointMathLib} from "@solmate/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "@solmate/utils/SafeCastLib.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";

contract BoringVaultL2OFT is OFT {
    using FixedPointMathLib for uint256;
    using SafeCastLib for uint256;

    event DelayInSecondsUpdated(uint32 minimumUpdateDelayInSeconds);
    event AllowedExchangeRateChangeUpperUpdated(uint16 allowedExchangeRateChangeUpper);
    event AllowedExchangeRateChangeLowerUpdated(uint16 allowedExchangeRateChangeLower);
    event ExchangeRateUpdated(uint96 currentExchangeRate, uint96 newExchangeRate);

    error NotUpdateExchangeRateRole();
    error InvalidMinimumUpdateDelay();
    error InvalidAllowedExchangeRateChangeUpper();
    error InvalidAllowedExchangeRateChangeLower();
    error InvalidNewExchangeRate();
    error InvalidLzEndpoint();

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
     * @notice The state for exchange rate and update constraints.
     */
    AccountantState public accountantState; 

    /**
     * @notice The role that can update the exchange rate.
     */
    mapping(address => bool) public updateExchangeRateRole;

    modifier onlyUpdateExchangeRole() {
        if (!updateExchangeRateRole[msg.sender]) {
            revert NotUpdateExchangeRateRole();
        }
        _;
    }

    constructor(
        ERC20 _base, 
        uint256 _exchangeRate, 
        uint256 _allowedExchangeRateChangeUpper,
        uint256 _allowedExchangeRateChangeLower,
        uint256 _minimumUpdateDelayInSeconds,
        string memory _name, 
        string memory _symbol, 
        address _lzEndpoint,
        address _delegate
    )
        OFT(_name, _symbol, _lzEndpoint, _delegate)
        Ownable(_delegate)
    {
        base = _base;
        rateDecimals = _base.decimals();

        if (_lzEndpoint == address(0)) revert InvalidLzEndpoint();
        if (_delegate == address(0)) revert InvalidDelegate();
        if (_allowedExchangeRateChangeUpper < 1e4) revert InvalidAllowedExchangeRateChangeUpper();
        if (_allowedExchangeRateChangeLower > 1e4) revert InvalidAllowedExchangeRateChangeLower();

        // initialize state
        accountantState.exchangeRate = _exchangeRate.safeCastTo96();
        accountantState.allowedExchangeRateChangeUpper = _allowedExchangeRateChangeUpper.safeCastTo16();
        accountantState.allowedExchangeRateChangeLower = _allowedExchangeRateChangeLower.safeCastTo16();
        accountantState.minimumUpdateDelayInSeconds = _minimumUpdateDelayInSeconds.safeCastTo32();
        accountantState.lastUpdateTimestamp = block.timestamp.safeCastTo64();
    }

    /**
     * @notice Grants the role to update the exchange rate.
     */
    function grantUpdateExchangeRateRole(address account) external onlyOwner {
        updateExchangeRateRole[account] = true;
    }

    /**
     * @notice Revokes the role to update the exchange rate.
     */
    function revokeUpdateExchangeRateRole(address account) external onlyOwner {
        updateExchangeRateRole[account] = false;
    }

    /**
     * @notice Updates the minimum delay between exchange rate updates.
     */
    function updateDelay(uint32 minimumUpdateDelayInSeconds) external onlyOwner {
        if (minimumUpdateDelayInSeconds == 0) revert InvalidMinimumUpdateDelay();
        accountantState.minimumUpdateDelayInSeconds = minimumUpdateDelayInSeconds;
        emit DelayInSecondsUpdated(minimumUpdateDelayInSeconds);
    }

    /**
     * @notice Updates the allowed exchange rate change upper bound.
     */
    function updateUpper(uint16 allowedExchangeRateChangeUpper) external onlyOwner {
        if (allowedExchangeRateChangeUpper < 1e4) revert InvalidAllowedExchangeRateChangeUpper();
        accountantState.allowedExchangeRateChangeUpper = allowedExchangeRateChangeUpper;
        emit AllowedExchangeRateChangeUpperUpdated(allowedExchangeRateChangeUpper);
    }

    /**
     * @notice Updates the allowed exchange rate change lower bound.
     */
    function updateLower(uint16 allowedExchangeRateChangeLower) external onlyOwner {
        if (allowedExchangeRateChangeLower > 1e4) revert InvalidAllowedExchangeRateChangeLower();
        accountantState.allowedExchangeRateChangeLower = allowedExchangeRateChangeLower;
        emit AllowedExchangeRateChangeLowerUpdated(allowedExchangeRateChangeLower);
    }

    /**
     * @notice Relays the L1 `Accountant`'s `updateExchangeRate` to the L2.
     * @dev Implements the same update constraint logic as the `Teller` in the L1.
     */
    function updateExchangeRate(uint96 newExchangeRate) external onlyUpdateExchangeRole {
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

    /**
     * @notice Returns the current exchange rate.
     */
    function getRate() external view returns (uint256) {
        return uint256(accountantState.exchangeRate);
    }
}
