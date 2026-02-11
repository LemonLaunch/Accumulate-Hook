// Soon// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @title AccumulateHook - Uniswap V4 Tax Hook for BTC Accumulation
/// @notice Intercepts swaps in a Uniswap V4 pool and charges buy/sell fees.
///         All collected fees are forwarded to the Accumulate Treasury, which
///         autonomously acquires BTC — implementing a MicroStrategy-inspired
///         reserve strategy fully on-chain.
/// @dev    Fees are taken in the output token of each swap, converted to ETH
///         internally, then split between the BTC acquisition treasury and an
///         operational/development fund.
/// @author LemonLaunch
contract AccumulateHook is BaseHook, ReentrancyGuard, Ownable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeCast for uint256;
    using SafeCast for int128;

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                      CONSTANTS                      */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    uint128 private constant TOTAL_BIPS = 10_000;
    uint128 private constant MAX_TAX_BIPS = 3_000;
    uint256 private constant TREASURY_SPLIT = 80;
    uint160 private constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;
    IPoolManager immutable manager;

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                   STATE VARIABLES                   */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Address of the BTC accumulation treasury
    address public btcTreasury;

    /// @notice Address for operational / development funds
    address public operationalWallet;

    /// @notice Buy fee in basis points (e.g., 500 = 5%)
    uint128 public buyFeeBips;

    /// @notice Sell fee in basis points (e.g., 500 = 5%)
    uint128 public sellFeeBips;

    /// @notice Addresses excluded from fees (deployer, treasury, LPs, etc.)
    mapping(address => bool) public isExcludedFromFee;

    /// @notice Running total of ETH sent to BTC treasury
    uint256 public totalEthAccumulatedForBTC;

    /// @notice Running total of ETH sent to operational wallet
    uint256 public totalEthToOperations;

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                    CUSTOM ERRORS                    */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    error FeeTooHigh();
    error ZeroAddress();
    error ExactOutputNotSupported();

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                    CUSTOM EVENTS                    */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Emitted when fee basis points are updated
    event FeesUpdated(uint128 newBuyFeeBips, uint128 newSellFeeBips);

    /// @notice Emitted when treasury or operational wallet is updated
    event WalletsUpdated(address btcTreasury, address operationalWallet);

    /// @notice Emitted when an address is included/excluded from fees
    event FeeExclusionUpdated(address indexed account, bool excluded);

    /// @notice Emitted on every taxed swap with fee breakdown
    event TaxCollected(
        bool indexed isBuy,
        uint256 totalFeeETH,
        uint256 toBtcTreasury,
        uint256 toOperations
    );

    /// @notice Emitted on every swap for price tracking
    event Trade(uint160 sqrtPriceX96, int128 ethDelta, int128 tokenDelta);

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                     CONSTRUCTOR                     */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Initializes the hook with pool manager, token, and fee configuration
    /// @param _poolManager The Uniswap V4 Pool Manager contract
    /// @param _btcTreasury  Wallet/contract that receives ETH to buy BTC
    /// @param _opsWallet    Wallet for operational/dev expenses
    /// @param _buyFeeBips   Initial buy fee (basis points)
    /// @param _sellFeeBips  Initial sell fee (basis points)
    /// @dev Reverts if either fee exceeds 100% (10000 basis points)
    constructor(
        IPoolManager _poolManager,
        address _btcTreasury,
        address _opsWallet,
        uint128 _buyFeeBips,
        uint128 _sellFeeBips,
        address owner
    ) BaseHook(_poolManager) {
        if (_btcTreasury == address(0) || _opsWallet == address(0))
            revert ZeroAddress();
        if (_buyFeeBips > MAX_TAX_BIPS || _sellFeeBips > MAX_TAX_BIPS)
            revert FeeTooHigh();

        manager = _poolManager;
        btcTreasury = _btcTreasury;
        operationalWallet = _opsWallet;
        buyFeeBips = _buyFeeBips;
        sellFeeBips = _sellFeeBips;

        _initializeOwner(owner);
    }

    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */
    /*                     ADMIN FUNCTIONS                 */
    /* ™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™™ */

    /// @notice Include or exclude an address from swap fees
    function setFeeExclusion(
        address account,
        bool excluded
    ) external onlyOwner {
        isExcludedFromFee[account] = excluded;
        emit FeeExclusionUpdated(account, excluded);
    }

    /// @notice Update buy and sell fee percentages
    /// @param _buyFee  New buy fee in basis points (max MAX_TAX_BIPS)
    /// @param _sellFee New sell fee in basis points (max MAX_TAX_BIPS)
    function updateFees(uint128 _buyFee, uint128 _sellFee) external onlyOwner {
        if (_buyFee > MAX_TAX_BIPS || _sellFee > MAX_TAX_BIPS)
            revert FeeTooHigh();
        buyFeeBips = _buyFee;
        sellFeeBips = _sellFee;
        emit FeesUpdated(_buyFee, _sellFee);
    }

    /// @notice Update the BTC treasury and operational wallet addresses
    function updateWallets(
        address _btcTreasury,
        address _opsWallet
    ) external onlyOwner {
        if (_btcTreasury == address(0) || _opsWallet == address(0))
            revert ZeroAddress();
        btcTreasury = _btcTreasury;
        operationalWallet = _opsWallet;
        emit WalletsUpdated(_btcTreasury, _opsWallet);
    }

    /// @notice Returns the hook's permissions for the Uniswap V4 pool
    /// @return Hooks.Permissions struct indicating which hooks are enabled
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    /// @notice Processes swap events and takes the swap fee
    /// @param key The pool key containing token pair and fee information
    /// @param params Swap parameters
    /// @param delta Balance changes resulting from the swap
    /// @return Selector indicating successful hook execution and fee amount
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // Restrict Exact Out
        if (params.amountSpecified > 0) revert ExactOutputNotSupported();
        // ── Skip fee for excluded addresses ─────────────────
        if (isExcludedFromFee[tx.origin]) {
            return (BaseHook.afterSwap.selector, 0);
        }

        bool isBuy = params.zeroForOne; // ETH (currency0) -> Token (currency1)
        bool specifiedTokenIs0 = (params.amountSpecified < 0 ==
            params.zeroForOne);
        (Currency feeCurrency, int128 swapAmount) = specifiedTokenIs0
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());

        if (swapAmount < 0) swapAmount = -swapAmount;

        // Calculate fee based on direction
        uint128 feeBips = isBuy ? buyFeeBips : sellFeeBips;
        uint256 feeAmount = (uint128(swapAmount) * feeBips) / TOTAL_BIPS;

        if (feeAmount == 0) {
            return (BaseHook.afterSwap.selector, 0);
        }

        // Take the fee
        manager.take(feeCurrency, address(this), feeAmount);

        // Convert to ETH if needed
        bool feeIsETH = Currency.unwrap(feeCurrency) == address(0);
        uint256 ethFeeAmount = feeIsETH
            ? feeAmount
            : _swapTokensForETH(key, feeAmount);

        // Send ETH to fee recipient
        _distributeFees(ethFeeAmount, isBuy);

        emit Trade(_getCurrentPrice(key), delta.amount0(), delta.amount1());

        return (BaseHook.afterSwap.selector, feeAmount.toInt128());
    }

    /* ═══════════════════════════════════════════════════════ */
    /*                   INTERNAL HELPERS                       */
    /* ═══════════════════════════════════════════════════════ */

    /// @notice Distributes collected ETH fees between treasury and operations
    /// @param ethAmount Total ETH fee collected from this swap
    /// @param isBuy     Whether the original swap was a buy
    function _distributeFees(uint256 ethAmount, bool isBuy) internal {
        // 80% → BTC accumulation treasury
        uint256 toBtcTreasury = (ethAmount * TREASURY_SPLIT) / 100;
        // 20% → operational / development fund
        uint256 toOperations = ethAmount - toBtcTreasury;

        // Update accumulators
        totalEthAccumulatedForBTC += toBtcTreasury;
        totalEthToOperations += toOperations;

        // Transfer
        SafeTransferLib.forceSafeTransferETH(btcTreasury, toBtcTreasury);
        SafeTransferLib.forceSafeTransferETH(operationalWallet, toOperations);

        emit TaxCollected(isBuy, ethAmount, toBtcTreasury, toOperations);
    }

    /// @notice Swaps a token to ETH
    /// @param key The pool key for the swap
    /// @param tokenAmount The amount of tokens to swap
    /// @return The amount of ETH received from the swap
    function _swapTokensForETH(
        PoolKey memory key,
        uint256 tokenAmount
    ) internal returns (uint256) {
        uint256 ethBefore = address(this).balance;

        BalanceDelta delta = manager.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(tokenAmount),
                sqrtPriceLimitX96: MAX_PRICE_LIMIT
            }),
            bytes("")
        );

        // Handle token settlements
        key.currency1.settle(
            poolManager,
            address(this),
            uint256(int256(-delta.amount1())),
            false
        );
        key.currency0.take(
            poolManager,
            address(this),
            uint256(int256(delta.amount0())),
            false
        );

        return address(this).balance - ethBefore;
    }

    /// @notice Gets the current price of a token pair from the pool
    /// @param key The pool key containing the token pair and pool parameters
    /// @return The current sqrtPriceX96 from slot0
    /// @dev Reads the current price from the pool's slot0 storage
    function _getCurrentPrice(
        PoolKey calldata key
    ) internal view returns (uint160) {
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(key.toId());
        return sqrtPriceX96;
    }

    /// @notice Allows the contract to receive ETH
    receive() external payable {}
}
