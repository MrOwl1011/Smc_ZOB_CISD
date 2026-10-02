# Guards — capital protection

One preset, one guard. `Guards_Gold_Spread.set` arms the spread filter and leaves the other
five capital-protection guards at zero.

## Why only one

All six guards were measured on gold M15 blocks to M1 confirmation, at 0.50% equity risk per
trade, each guard alone before the stack, over three separate one-year windows.

| Guard | 2023-24 | 2024-25 | 2025-26 | 3-year | Worst DD |
| --- | --- | --- | --- | --- | --- |
| none | +752 | **−123** | +288 | 917 | 1089 |
| daily 2% | +752 | −123 | +288 | 917 | 1089 |
| weekly 4% | +752 | −123 | +288 | 917 | 1089 |
| equity 12% | +752 | −123 | +288 | 917 | 1089 |
| volatility 2.5× | +673 | −123 | +237 | 786 | 1089 |
| streak 5 | +568 | −150 | +306 | 724 | 998 |
| streak 3 | +410 | +18 | +487 | 915 | 944 |
| **spread 3% of R** | **+955** | **+21** | **+586** | **1562** | 984 |
| all five stacked | +737 | +246 | +604 | 1587 | 895 |

**The spread filter improved every year independently** — +203, +144, +298 — and it is the only
guard with support from a second, separate dataset: across 271 scored trades, spread as a share
of the stop had the strongest rank relation to outcome of any factor measured. Its refusals track
when it is needed: 40 trades in 2023-24 against 4 in 2025-26, matching how much wider the
broker's historical spread was in the earlier period.

**The daily, weekly and equity stops never fired once** in 27 runs across three years. At 0.5%
risk a 2% daily stop needs four losses inside one server day, and the worst drawdown of the three
years was 10.3% of peak equity, just under the 12% stop. At these thresholds they are inert, not
conservative.

**The streak filters cost more than they saved.** Streak 3 cut the best year from +752 to +410.
Both sit at or below no-guards over three years. The volatility filter was negative in every year
it fired.

## Verified

Loaded as shipped, nothing overridden but the date window:

| Window | Profit | Trades | PF | Refused |
| --- | --- | --- | --- | --- |
| 2023-24 | 955.18 | 115 | 1.254 | 40 |
| 2024-25 | 20.76 | 148 | 1.004 | 13 |
| 2025-26 | 586.26 | 141 | 1.122 | 4 |

## Before you switch the others on

They are catastrophe brakes, and a backtest holds no disconnection, no gap through a stop, no bad
tick. Three years of silence is not proof they are useless. But at these values they are
decoration — do not switch them on and believe the account is protected. Making them real means
tightening them a long way, perhaps a 1% daily stop and a 7% equity stop, and that is a trade
between protection and participation that no backtest can settle. It is yours to make.

## Every other preset

All 15 shipped presets now carry the eight guard keys with `InpCapitalGuards=false`, so their
behaviour is unchanged. The keys are written out explicitly because a preset that omits an input
lets the tester fall back to whatever it last remembered, which has silently changed results in
this project before.
