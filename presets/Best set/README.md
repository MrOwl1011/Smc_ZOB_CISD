# Best set

`H1M5_Gold_Swing4.set` — the recommended starting point, and the EA's own compiled defaults.
Load it, or load nothing at all: the two are identical.

## What it runs

Gold (XAUUSD), **H1 Order Blocks with M5 CISD confirmation**, swing 4, displacement 2.50 ATR,
trend gate 2.5 ATR over 20 bars, **1:1 target**, fixed 0.01 lots. Break even, ride the trend,
opposite block exit and the capital guards are all off. Mitigation stops the CISD search.

| Measured 2023-10-01 to 2026-10-01 | |
| --- | --- |
| Profit | +256.41 USD |
| Trades | 31 |
| Correct | 64.5% |
| Profit factor | 2.40 |
| Recovery factor | 2.09 |
| Drawdown | 122.54 |
| Longest losing run | 3 |

## Read this before you trust those numbers

**Thirty-one trades over three years is a small sample.** Ten trades a year means a single bad
run moves the win rate several points. Treat 64.5% as a direction, not a figure to size
positions against.

**The configuration was chosen by looking at results.** It was the pick of 16 tested on this
pairing, so the numbers above are the best of sixteen tries rather than what a fresh period
should be expected to produce. Nothing here has been tested out of sample.

**Trade execution is on.** The EA places real orders as soon as a setup confirms. Run it on a
demo account first, or switch Trade execution off in the panel and watch it draw.

**No configuration in this project has been profitable in every year tested.** Position sizing
and take profit change how much is made when an edge is present and how much is lost when it is
not. They do not create edge.

## The swing-5 variant scored higher

On the same three years, `../H1M5/H1M5_Gold_Fixed.set` — identical but swing 5 — measured
**+298.76 USD, 30 trades, 66.7%, PF 3.12**, against this file's +256.41 and PF 2.40.

Swing 4 is kept as the recommendation because a looser swing length finds structure on more
instruments and is less brittle when a symbol's character differs from gold's. If you only
trade gold on H1, the swing-5 file measured better over this particular window, and the gap is
within what thirty trades can produce by chance either way.

## If you want a different character

| Want | Load |
| --- | --- |
| More trades, bigger total | `../MaxProfit/` — M15 to M1, three times the trades, 44% win rate, 1:2 target |
| Percent-of-equity sizing | `../RiskPercent/` |
| The one guard with evidence behind it | `../Guards/Guards_Gold_Spread.set` |
| Another symbol | `../SMC_SYM_*.set` |

Full tables: [../PACKAGES.md](../PACKAGES.md) and [../SYMBOL_PRESETS.md](../SYMBOL_PRESETS.md).
