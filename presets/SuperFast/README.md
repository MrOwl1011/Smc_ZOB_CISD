# SuperFast presets

Gold (XAUUSD) on **M15 Order Blocks with M1 CISD confirmation**, trading **enabled**,
0.01 lots. Found by sweeping 256 configurations over 2025-09-25 to 2026-09-20.

| Preset | Swing | Displacement | Trend gate | Target | Measured on that year |
| --- | --- | --- | --- | --- | --- |
| `SuperFast_Gold_Expectancy` | 4 | 2.50 ATR | 2.0 | 1R | 30 trades, 70.0%, +0.40 R |
| `SuperFast_Gold_Balanced` | 4 | 2.50 ATR | 1.25 | 1R | 50 trades, 66.0%, +0.32 R |
| `SuperFast_Gold_HighWin` | 6 | 2.00 ATR | 1.25 | 0.25R | 61 trades, 91.8%, +0.15 R |

## Read before using them

**These were selected by looking at results.** 256 configurations were measured on one
symbol over one year and the best were kept, so the numbers above are the best case
rather than an expectation. None of them has been tested out of sample.

**The same pair loses money at the default settings**: gold M15 to M1 scored 46.9%
and -0.06 R per trade with swing 4 and displacement 1.50. Only the stricter
displacement filters lifted it above water.

**A high win rate is not a high return.** `HighWin` wins 91.8% of the time because its
target is a quarter of its stop; it needs 80% just to break even and earns less per
trade than the two 1R presets.

**Trading is ON in these files.** Loading one and pressing OK arms live execution on
that chart. The other presets in the parent folder ship with trading off.
