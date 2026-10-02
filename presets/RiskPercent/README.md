# Risk-percent presets

Gold (XAUUSD), **M15 Order Blocks with M1 CISD confirmation**, trading enabled, and the
position size taken from account risk instead of a fixed lot.

| Preset | Risk per trade | Cost of a five-loss run | Cost of a ten-loss run |
| --- | --- | --- | --- |
| `Risk_Gold_025` | 0.25% | about 1.25% | about 2.5% |
| `Risk_Gold_050` | 0.50% | about 2.5% | about 5% |
| `Risk_Gold_100` | 1.00% | about 5% | about 10% |

The longest losing run measured on this configuration over three years was **five**.

## How the size is worked out

```
lots = equity * riskPercent / (stopPoints * valuePerPointPerLot)
```

The stop is the far side of the Order Block, so it varies with the block's height. That is
the point: a wide block now takes a smaller position and a tight block a larger one, and both
risk the same money. With a fixed lot they did not, which is why currency profit in the
optimisation partly reflected stop width rather than accuracy.

Four guards are built into the EA: a symbol that cannot price a point falls back to the fixed
lot rather than sizing up, a size the account cannot margin is stepped down, a size below one
minimum lot skips the trade instead of rounding up, and rounding is always down.

## Read before using them

**The detection settings are measured; the sizing is not.** Those settings are the
risk-adjusted winner of 128 three-year backtests, but every one of those backtests used fixed
0.01 lots. Risk sizing compounds and scales with stop width, so the equity curve will differ.
Re-run the backtest with the preset loaded before believing any figure.

**The first year lost money.** No configuration tested was profitable in all three years.

**Confidence logging is on.** Each confirmed setup writes a row to `SMC_Confidence.csv` in
the common Files folder. It changes nothing about how trades are taken; it exists so the
score's weights can be fitted against realised results later.

**Start at 0.25% if you are putting this on a live account.** The three-year test contains one
losing year, and the sizing behaviour has not yet been verified in a backtest of its own.
