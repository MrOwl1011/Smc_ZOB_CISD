# SMC Order Block EA

An MT5 Expert Advisor that finds Smart Money Concepts setups on the chart — Order Blocks,
ZOrder Blocks, liquidity sweeps, CISD — and can trade them for you.

It reads the higher timeframe for the level, the lower timeframe for the trigger, and only
takes the trade when the market is actually trending that way. Everything is drawn on the
chart, and everything is switchable from a panel without touching the inputs.

> **Trading is off by default.** Out of the box this is a chart-analysis tool. You turn
> execution on yourself, from the panel, when you want it.

---

## What it does, in one paragraph

Price breaks structure with a real impulsive move. The last opposite-colour candle before
that move is where the orders were left behind — that's the block. Later, price comes back
to it. If the lower timeframe then shows delivery flipping inside that block (a liquidity
sweep, a candle series, a confirmation close), and the higher timeframe is genuinely
trending in the block's direction, the EA takes it: stop on the far side of the block,
target the same distance away.

## Quick start

1. Copy this folder to `MQL5\Experts\Zaid\2026\SMC_OrderBlock_EA\` and compile
   `SMC_OrderBlock_EA.mq5` (0 errors, 0 warnings expected).
2. Attach it to a chart. Default timeframes are the chart's own; the tested setup is
   **H1 blocks → M5 triggers**.
3. Open the EA properties, press **Load**, and pick a preset from `presets\`
   (start with `SMC_1_BestOverall.set`).
4. Watch it draw. When you're happy, switch **Trade execution** on in the panel.

If you want the researched configuration exactly: preset `SMC_1_BestOverall.set`,
one chart per instrument, lots 0.01.

## The control panel

Everything day-to-day lives on the chart, not in the inputs dialog:

| Section | What you can change |
|---|---|
| **Mode** | Easy (zones only) or full (structure, FVG, CISD, links) |
| **Display** | Bull/bear, ZOrder zones, labels, fills, old zones, retests, retest-start marks, swings |
| **Timeframes** | Order Block TF and CISD TF, independently of the chart |
| **CISD** | Liquidity sweep / confirmation close / retracement stages |
| **Connection** | OB source, retest mode, CISD mode, *Mitigation stops CISD*, *Trend filter* |
| **Trading** | *Trade execution* on/off, *Lot size* (± 0.01), *Opposite block exit* on/off |
| **Configuration** | Save / load named profiles, reset to inputs |

Panel state survives a restart, per chart.

## How a trade works

|  |  |
|---|---|
| **Entry** | Market, the moment the setup confirms |
| **Stop** | The far side of the block — below a bullish block, above a bearish one |
| **Target** | 1:1 — the same distance the other way |
| **Size** | Fixed lots, 0.01 by default, changeable from the panel |
| **Exposure** | One position at a time |

**Three ways a trade ends:** target hit, stop hit, or — if you enable it — *Opposite block
exit*: a block forms **against** your open trade after you entered, price retests it, and
the position is closed early. The market just built and respected structure the other way.

## Which settings to use

Seven ready-made packages are in `presets\` (MT5 input presets) and `profiles\`
(panel profiles). Full table and notes in [presets/PACKAGES.md](presets/PACKAGES.md).

| Preset | Use it for |
|---|---|
| `SMC_1_BestOverall` | The default. Best performance *and* the most stable in testing |
| `SMC_2_Forex` | FX majors |
| `SMC_3_Metals` | Gold |
| `SMC_4_Indices` | US500, GER30, UK100, US30 |
| `SMC_5_Safest` | Fewer trades, smaller drawdown |
| `SMC_6_HighestExpectancy` | Gold, highest expectancy found (small sample — read the caveat) |
| `SMC_7_HighestRobustness` | Same as package 1 |

Load a `.set` from the EA properties dialog. Load a `.cfg` by typing its name in the
panel's CONFIGURATION field and pressing Load. The `.set` files also carry the trend gate,
which the panel profiles can't hold — so for `SMC_5_Safest`, use the `.set`.

## Does it actually work?

The honest version, from [research/REPORT.md](research/REPORT.md) — 19 instruments,
20 months, ZOrder Blocks only, measured in R (not currency):

| | |
|---|---|
| Recommended setup (H1→M5) | **57.2% win rate, +0.143 R per trade**, profit factor 1.34 |
| In-sample vs out-of-sample | +0.143 R vs **+0.144 R** — identical |
| Walk-forward | 5 of 5 windows positive out-of-sample |
| Monte Carlo | 99.9% probability the edge is real; plan for a ~22 R drawdown |
| Instruments positive | 15 of 19 |
| **Without the trend filter** | **50.3% — no edge at all** |

That last line is the important one: the trend filter *is* the strategy, not a garnish.

Also worth knowing, and also in the report:

* **H4→M15 is unproven** — only 127 trades in 20 months, and it went negative
  out-of-sample. Not disproven, just not shown.
* **M15→M1 is weak** (+0.057 R) and can't be validated properly — most brokers only keep
  a few months of M1 history.
* **Fixed lots means your dollar risk is not constant**, because block heights vary. R is
  the honest unit. One instrument (US30) is negative in R yet positive in dollars purely
  because of this.
* Results are one broker, one 20-month regime. Past detection statistics are not a promise.

## Verify it yourself

Set `InpRunSelfTest = true` and run it in the Strategy Tester. Every module checks itself
and prints a pass/fail summary:

| Suite | Checks |
|---|---|
| Order Blocks | 129 — structure, displacement, lifecycle, zones, synthetic + real data |
| Panel | 55 — state, wiring, layout |
| CISD | 76, plus live-vs-batch equality |
| Connection | 36 — retests, direction, ordering, invalidation, modes, trend filter re-derived from raw candles |
| Config profiles | 6 — save/load round trip |

The connection suite replays every engine in batch mode and demands it match the live
bar-by-bar run **exactly**. That's the real guarantee against repainting and look-ahead.

To reproduce the research instead: `research/smc_research.py` and
`research/smc_research_grid.py`, fed by the signal exports the validator writes.

## What's in here

| Path | |
|---|---|
| `SMC_OrderBlock_EA.mq5` | Entry point — inputs, events, wiring |
| `SMC_OB_Structure.mqh` | Swings, BOS, CHoCH |
| `SMC_OB_Displacement.mqh` | Impulse tests, picks the block candle |
| `SMC_OB_Engine.mqh` | Order Block + ZOrder Block lifecycle |
| `SMC_OB_FVG.mqh` | Fair Value Gaps |
| `SMC_CISD_Engine.mqh` | Sweep → series → confirmation → retracement |
| `SMC_Connect_Engine.mqh` | HTF block → LTF CISD, M1 retest, trend filter |
| `SMC_OB_TradeHooks.mqh` | Order placement and the opposite-block exit |
| `SMC_OB_Panel.mqh` | The on-chart panel |
| `SMC_Config.mqh` | Named profiles |
| `SMC_*_Visual.mqh` | Drawing (incremental — no full redraws) |
| `SMC_*_SelfTest.mqh` | The verification suites |
| `DESIGN.md` | Every rule and threshold, written out precisely |
| `presets/`, `profiles/` | The seven settings packages |
| `research/` | Full report, all data tables, the analysis scripts |

About 10.7k lines across 20 modules. Detection and execution are fully separate: the
detectors never call the broker, and `SMC_OB_TradeHooks.mqh` is the only file that does.

## Design rules it sticks to

* **Closed candles only.** The forming bar is never read. Nothing repaints — a marker
  never moves or vanishes once drawn, and a zone's right edge stops at the candle that
  ended it.
* **Each bar processed once**, with cross-module decisions made on timestamps.
* **No trading from history.** Signals found during the initial scan never place orders.

## Requirements

MetaTrader 5 build 3000+. M1 history is needed for retest detection when the Order Block
timeframe is above M1.

---

Detection only until you switch trading on. Nothing here is financial advice, and the
numbers above describe the past, not your next month.
