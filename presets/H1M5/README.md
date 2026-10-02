# H1 to M5 presets

Gold (XAUUSD), **H1 Order Blocks with M5 CISD confirmation**. Best of 16 configurations
tested over 2023-10-01 to 2026-10-01.

| Preset | Swing | Sizing | Measured with fixed lots |
| --- | --- | --- | --- |
| `H1M5_Gold_Fixed` | 5 | 0.01 lots | +298.76 USD, 30 trades, 66.7%, PF 3.12, DD 122.54 |
| `H1M5_Gold_Risk025` | 5 | 0.25% equity | same signals, compounded |
| `H1M5_Gold_Risk050` | 5 | 0.50% equity | same signals, compounded |
| `H1M5_Gold_Swing4` | 4 | 0.01 lots | +256.41 USD, 31 trades, 64.5%, PF 2.40 |

All four: displacement 2.50 ATR, trend gate 2.5, **1:1 target**, break even off,
opposite block exit off, mitigation stops CISD on.

## How this differs from the M15 to M1 presets

| | H1 to M5 | M15 to M1 |
| --- | --- | --- |
| Trades in 3 years | 30 | 92 |
| Win rate | 66.7% | 44.6% |
| Target | 1:1 | 1:2 |
| Profit | +299 | +810 |
| Profit factor | 3.12 | 2.11 |
| Recovery factor | 2.44 | 5.85 |
| Longest losing run | 3 | 5 |

**M15 to M1 earns roughly three times as much.** H1 to M5 wins far more often, loses less
often in a row, and trades about ten times a year instead of thirty.

Two findings held across the whole H1 to M5 grid and are worth knowing:

1. **A 1:1 target beat 1:2 in seven of eight pairs.** That is the reverse of M15 to M1,
   where 1:2 won everywhere. Do not copy the target between pairings.
2. **Tighter filters helped more here.** Displacement 2.5 with gate 2.5 produced the best
   profit factor on both swing settings.

## Read before using them

**Thirty trades in three years is a small sample.** A 66.7% win rate on 30 trades has a wide
confidence interval: treat it as a direction, not a number to rely on.

**Chosen by reading results.** Sixteen configurations were measured and the best kept, so
expect less than the figures quoted.

**Risk-sizing variants were not separately measured.** The signals are identical to the fixed
version, but compounding changes the equity curve. On the M15 to M1 presets, moving from
fixed lots to 0.25% risk raised profit 38% and roughly doubled drawdown; expect the same
shape here.

**Trading is ON in these files.** Loading one and pressing OK arms live execution.
