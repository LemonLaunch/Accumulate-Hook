// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IUniswapV4Router04} from "v4-router/interfaces/IUniswapV4Router04.sol";

/// @title AccumulateToken - MicroStrategy-inspired BTC Accumulation Token
/// @notice ERC20 token that receives ETH from trading fees and uses it to buy WBTC via TWAP
/// @dev Set this contract's address as the fee recipient in AccumulateHook.
///      Anyone can call buyBtc() to trigger a purchase when balance >= minThreshold.
/// @author LemonLaunch
contract AccumulateToken is ERC20, Ownable, ReentrancyGuard {
    /* ═══════════════════════════════════════════════════════ */
    /*                       CONSTANTS                        */
    /* ═══════════════════════════════════════════════════════ */

    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18;

    /* ═══════════════════════════════════════════════════════ */
    /*                    STATE VARIABLES                      */
    /* ═══════════════════════════════════════════════════════ */

    // ── Trading ──
    bool public tradingActive = false;
    uint256 public tradingActivationBlock;
    mapping(address => bool) public isExcludedFromTradingRestriction;

    // ── BTC Accumulation ──
    /// @notice Minimum ETH balance required before a buy can be triggered
    uint256 public minThreshold;

    /// @notice Amount of ETH to swap per TWAP call
    uint256 public twapIncrement;

    /// @notice Blocks to wait between TWAP buys
    uint256 public twapDelayInBlocks;

    /// @notice Last block a TWAP buy was executed
    uint256 public lastTwapBlock;

    /// @notice Address that receives the purchased WBTC
    address public btcTreasury;

    /// @notice Uniswap V4 Router
    IPoolManager public poolManager;

    // ── WBTC Pool Config ──
    address public wbtcAddress;
    address public wbtcPoolHook;
    int24 public wbtcPoolTickSpacing;
    uint24 public wbtcPoolFee;

    // ── Tracking ──
    /// @notice Total ETH spent buying WBTC (lifetime)
    uint256 public totalEthSpentOnBtc;

    /// @notice Total number of BTC buys executed
    uint256 public totalBuys;

    /* ═══════════════════════════════════════════════════════ */
    /*                        EVENTS                          */
    /* ═══════════════════════════════════════════════════════ */

    event TradingEnabled(uint256 activationBlock);
    event ExcludedFromTradingRestriction(
        address indexed account,
        bool isExcluded
    );
    event BtcPurchased(
        uint256 indexed buyNumber,
        uint256 ethSpent,
        address indexed caller,
        uint256 callerReward,
        uint256 contractBalance
    );
    event ConfigUpdated(
        uint256 minThreshold,
        uint256 twapIncrement,
        uint256 twapDelayInBlocks
    );
    event WbtcPoolConfigUpdated(
        address wbtc,
        address hook,
        uint24 fee,
        int24 tickSpacing
    );
    event BtcTreasuryUpdated(address indexed newTreasury);

    /* ═══════════════════════════════════════════════════════ */
    /*                     CUSTOM ERRORS                      */
    /* ═══════════════════════════════════════════════════════ */

    error TradingAlreadyActive();
    error BelowThreshold();
    error TwapDelayNotMet();
    error ZeroAddress();
    error WbtcPoolNotConfigured();

    /* ═══════════════════════════════════════════════════════ */
    /*                      CONSTRUCTOR                       */
    /* ═══════════════════════════════════════════════════════ */

    constructor(
        string memory _name,
        string memory _symbol,
        address _btcTreasury,
        address payable _router
    ) ERC20(_name, _symbol) Ownable(msg.sender) {
        if (_btcTreasury == address(0)) revert ZeroAddress();

        btcTreasury = _btcTreasury;
        router = IUniswapV4Router04(_router);

        // Defaults
        minThreshold = 0.05 ether;
        twapIncrement = 0.05 ether;
        twapDelayInBlocks = 1;

        isExcludedFromTradingRestriction[msg.sender] = true;
        isExcludedFromTradingRestriction[address(this)] = true;

        _mint(msg.sender, MAX_SUPPLY);
    }

    /* ═══════════════════════════════════════════════════════ */
    /*                    ADMIN FUNCTIONS                      */
    /* ═══════════════════════════════════════════════════════ */

    function enableTrading() external onlyOwner {
        if (tradingActive) revert TradingAlreadyActive();
        tradingActive = true;
        tradingActivationBlock = block.number;
        emit TradingEnabled(tradingActivationBlock);
    }

    function setExcludedFromTradingRestriction(
        address account,
        bool excluded
    ) external onlyOwner {
        isExcludedFromTradingRestriction[account] = excluded;
        emit ExcludedFromTradingRestriction(account, excluded);
    }

    function setBtcTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        btcTreasury = _treasury;
        emit BtcTreasuryUpdated(_treasury);
    }

    /// @notice Configure the WBTC pool for on-chain purchases
    function setWbtcPoolConfig(
        address _wbtc,
        address _hook,
        uint24 _fee,
        int24 _tickSpacing
    ) external onlyOwner {
        wbtcAddress = _wbtc;
        wbtcPoolHook = _hook;
        wbtcPoolFee = _fee;
        wbtcPoolTickSpacing = _tickSpacing;
        emit WbtcPoolConfigUpdated(_wbtc, _hook, _fee, _tickSpacing);
    }

    /// @notice Update threshold and TWAP parameters
    function setConfig(
        uint256 _minThreshold,
        uint256 _twapIncrement,
        uint256 _delayInBlocks
    ) external onlyOwner {
        minThreshold = _minThreshold;
        twapIncrement = _twapIncrement;
        twapDelayInBlocks = _delayInBlocks;
        emit ConfigUpdated(_minThreshold, _twapIncrement, _delayInBlocks);
    }

    function setRouter(address payable _router) external onlyOwner {
        router = IUniswapV4Router04(_router);
    }

    /// @notice Emergency ETH withdrawal
    function transferEther(
        address _to,
        uint256 _amount
    ) external payable onlyOwner {
        SafeTransferLib.forceSafeTransferETH(_to, _amount);
    }

    /* ═══════════════════════════════════════════════════════ */
    /*              BTC ACCUMULATION (PUBLIC)                  */
    /* ═══════════════════════════════════════════════════════ */

    /// @notice Anyone can call to trigger a WBTC purchase when balance >= threshold
    /// @dev Buys in twapIncrement chunks. Caller gets 0.5% reward as gas incentive.
    function buyBtc() external nonReentrant {
        if (wbtcAddress == address(0)) revert WbtcPoolNotConfigured();
        if (address(this).balance < minThreshold) revert BelowThreshold();
        if (block.number < lastTwapBlock + twapDelayInBlocks)
            revert TwapDelayNotMet();

        // Determine how much to spend this call
        uint256 balance = address(this).balance;
        uint256 buyAmount = balance < twapIncrement ? balance : twapIncrement;

        // 0.5% reward to caller
        uint256 reward = (buyAmount * 5) / 1000;
        uint256 swapAmount = buyAmount - reward;

        // Update state before external calls (CEI)
        lastTwapBlock = block.number;
        totalEthSpentOnBtc += swapAmount;
        totalBuys++;

        // Swap ETH -> WBTC, sent directly to treasury
        _buyWBTC(swapAmount);

        // Reward caller
        SafeTransferLib.forceSafeTransferETH(msg.sender, reward);

        emit BtcPurchased(
            totalBuys,
            swapAmount,
            msg.sender,
            reward,
            address(this).balance
        );
    }

    /// @notice Check if a buy can be triggered right now
    function canBuyBtc() external view returns (bool) {
        return
            wbtcAddress != address(0) &&
            address(this).balance >= minThreshold &&
            block.number >= lastTwapBlock + twapDelayInBlocks;
    }

    /// @notice How much ETH is available for the next buy
    function pendingEth() external view returns (uint256) {
        return address(this).balance;
    }

    /* ═══════════════════════════════════════════════════════ */
    /*                  INTERNAL FUNCTIONS                     */
    /* ═══════════════════════════════════════════════════════ */

    /// @notice Swaps ETH for WBTC via Uniswap V4 and sends to treasury
    function _buyWBTC(uint256 amountIn) internal {
        PoolKey memory key = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(wbtcAddress),
            wbtcPoolFee,
            wbtcPoolTickSpacing,
            IHooks(wbtcPoolHook)
        );

        router.swapExactTokensForTokens{value: amountIn}(
            amountIn,
            0,
            true, // zeroForOne: ETH -> WBTC
            key,
            "",
            btcTreasury, // WBTC sent directly to treasury
            block.timestamp
        );
    }

    /// @notice Enforce trading restrictions
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            return;
        }

        if (!tradingActive) {
            require(
                isExcludedFromTradingRestriction[from] ||
                    isExcludedFromTradingRestriction[to],
                "Trading is not active"
            );
        }

        super._update(from, to, amount);
    }

    /// @notice Receive ETH from hook fees, direct transfers, etc.
    receive() external payable {}
}
