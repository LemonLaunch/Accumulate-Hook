# Accumulate Hook 🟠

**A Uniswap V4 Hook that implements a MicroStrategy-inspired BTC accumulation strategy fully on-chain.**

Every swap in the pool is taxed. Collected fees are converted to ETH, split between a BTC acquisition treasury and an operational fund — autonomously building a Bitcoin reserve.

## Architecture

```
┌──────────────┐     swap tax      ┌────────────────────┐
│  Uniswap V4  │ ───── ETH ─────▶ │  AccumulateToken   │
│    Pool       │                   │  (fee receiver)    │
└──────┬───────┘                   └────────┬───────────┘
       │                                    │
       │                           buyBtc() │ (anyone can call)
  AccumulateHook                            │
  (afterSwap tax)                           ▼
                                   ┌────────────────────┐
                                   │   PoolManager      │
                                   │   ETH → WBTC swap  │
                                   └────────┬───────────┘
                                            │
                                            ▼
                                   ┌────────────────────┐
                                   │   BTC Treasury 🟠  │
                                   └────────────────────┘
```

## Contracts

| Contract              | Description                                                                                       |
| --------------------- | ------------------------------------------------------------------------------------------------- |
| `AccumulateHook.sol`  | Uniswap V4 afterSwap hook — charges buy/sell fees, converts to ETH, distributes to treasury + ops |
| `AccumulateToken.sol` | ERC20 token that receives ETH fees and buys WBTC via PoolManager when threshold is met            |

## Deployed Addresses (Sepolia)

| Contract           | Address                                      |
| ------------------ | -------------------------------------------- |
| **AccumulateHook** | `0x64b54C01afCb36A405a2615e65B5E22A52b28044` |

## How It Works

1. **Fee Collection** — `AccumulateHook` intercepts every swap and takes a configurable buy/sell fee (in basis points)
2. **ETH Conversion** — Fees taken in tokens are swapped back to ETH within the hook
3. **Fee Split** — 80% goes to BTC treasury (AccumulateToken), 20% to operational wallet
4. **BTC Accumulation** — Anyone calls `buyBtc()` on AccumulateToken when ETH balance ≥ threshold. Uses TWAP to swap ETH → WBTC via PoolManager. Caller gets 0.5% reward as gas incentive
5. **WBTC sent to Treasury** — Purchased WBTC goes directly to the BTC treasury address

## Fee Configuration

- **Max fee**: 30% (3000 bips)
- **Default split**: 80% BTC treasury / 20% operations
- **TWAP**: Buys in small increments with block delay to reduce price impact

## Build

```shell
forge build --via-ir
```

## Test

```shell
forge test --via-ir
```

## Admin Operations

Update wallets on the hook:

```shell
cast send 0x64b54C01afCb36A405a2615e65B5E22A52b28044 \
  "updateWallets(address,address)" <BTC_TREASURY> <OPS_WALLET> \
  --rpc-url $SEPOLIA_RPC_URL --account w1
```

Update fees:

```shell
cast send 0x64b54C01afCb36A405a2615e65B5E22A52b28044 \
  "updateFees(uint128,uint128)" <BUY_BIPS> <SELL_BIPS> \
  --rpc-url $SEPOLIA_RPC_URL --account w1
```

## License

MIT
