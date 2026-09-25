# SMC Order Block EA

A Smart-Money-Concepts **detection and analysis** Expert Advisor for MetaTrader 5.
It finds Order Blocks, ZOrder Blocks, FVGs, liquidity sweeps and CISDs, links a
higher-timeframe Order Block to a lower-timeframe CISD, and draws everything on the
chart with a full on-chart control panel.

**It places no orders.** There is no position sizing, no money management and no trade
execution anywhere in the code — it is a chart-analysis tool with a separate offline
validation harness.

Version 1.50 · MQL5 · ~10.7k lines across 20 modules.

---

## Contents

| Path | What it is |
|---|---|
| `SMC_OrderBlock_EA.mq5` | Entry point: inputs, event handlers, module wiring, verification hooks |
| `SMC_OB_Types.mqh` | Shared enums and structs |
| `SMC_OB_MarketData.mqh` | Closed-candle data access (never reads the forming bar) |
| `SMC_OB_Structure.mqh` | Swings, BOS / CHoCH |
| `SMC_OB_Displacement.mqh` | Displacement tests and OB-candle selection |
| `SMC_OB_FVG.mqh` | Fair Value Gap detection / confluence |
| `SMC_OB_Engine.mqh` | Order Block + ZOrder Block lifecycle |
| `SMC_CISD_Engine.mqh` | Liquidity sweep to candle series to confirmation to retracement |
| `SMC_Connect_Engine.mqh` | HTF Order Block to LTF CISD connection, M1 retest, trend filter |
| `SMC_OB_Visual.mqh`, `SMC_CISD_Visual.mqh`, `SMC_Connect_Visual.mqh` | Drawing (incremental, no full redraws) |
| `SMC_OB_Panel.mqh` | On-chart control panel |
| `SMC_Config.mqh` | Named profiles saved to / loaded from disk |
| `SMC_OB_TradeHooks.mqh` | Event hooks for downstream tools (no trading) |
| `*_SelfTest.mqh`, `SMC_OB_PanelTest.mqh` | Built-in verification suites |
| `DESIGN.md` | Exact definitions of every rule and threshold |

Related, outside this folder:

- `Experts/Zaid/2026/SMC_Validation/SMC_SignalValidatorEA.mq5` — tester wrapper for the offline validator
- `Scripts/Zaid/2026/SMC_SignalValidator.mq5` — standalone signal exporter (CSV; no broker, balance, lots or P&L)
- `Scripts/Zaid/2026/smc_validation_report.py`, `smc_validation_suite.py`, `smc_walkforward.py` — statistics and reports

---

## Detection pipeline

1. **Structure** — swing highs/lows confirmed only after `SwingLength` bars close on both sides, with an optional ATR prominence filter. A swing can produce at most one break.
2. **BOS / CHoCH** — a close beyond the newest unbroken swing, optionally with an ATR buffer. A break against the previous direction is labelled CHoCH.
3. **Displacement** — the leg into the break must pass four independent tests (net ATR move, strongest body in ATR, body/range %, body vs average body). ATR and average body are measured *before* the move, so displacement cannot inflate its own threshold.
4. **Order Block** — the last opposite-colour candle before the leg. Zone modes: Wick, Body, Open-Extreme, and **Open-Last Ext** (bear: last candle's high to first candle's open; bull: first candle's open to last candle's low; single candle: bear open to high, bull low to open).
5. **ZOrder Block** — the same idea applied to a *series* of candles instead of one.
6. **FVG** — optional confluence requirement for a valid block.
7. **Lifecycle** — live, retested, mitigated (touch / 50% / full), invalidated (close beyond), expired or superseded.
8. **CISD** — liquidity sweep, candle series, confirmation close, retracement entry area, with standard-deviation projection levels.
9. **Connection** — when price re-enters a live HTF Order Block on M1, a CISD engine is started on the lower timeframe and watched for a confirmation.

Everything is evaluated **on closed candles only**, each bar is processed once, and
cross-module decisions are made on timestamps. Nothing repaints: a marker never moves
or disappears once drawn, and a zone's right edge stops at the candle that ended it.

---

## Trend filter (with-trend **and** trending)

Before a CISD is accepted for a retested Order Block, directional displacement is
measured on the **OB timeframe**:

```
score = (close - close[TrendBars ago]) / ATR(ATRPeriod)
```

The signal is accepted only when `|score| >= TrendATRMult` **and** the sign matches the
block's direction. So the market must be *moving* (trending) and *moving the right way*
(with trend). Only candles that had already closed at the confirmation timestamp are
used, so the filter cannot look ahead.

Switch: panel row **"Trend filter"**, or `InpTrendFilter` (default on), with
`InpTrendBars = 20` and `InpTrendATRMult = 1.5`. Rejected signals are counted in the
statistics line.

On XAUUSD H1, May–Sep 2026, the filter reduced 1229 raw CISDs to 123, and every
accepted signal was re-verified against raw candles by the self-test.

---

## Control panel

An on-chart panel exposes the day-to-day switches without touching inputs:

- **Easy mode** — OB zones only; full mode adds structure, FVG, CISD and links
- Bull / bear, standard / ZOrder, zone mode, extension, mitigation and invalidation modes
- CISD stages (sweep / confirmation / retracement) and timeframe selection
- Connection section: OB source, retest mode, CISD mode, **Mitigation stops CISD**, **Trend filter**
- Visuals: labels, fills, inactive zones, retest markers, **Retest start** marks
- Named configuration profiles (save / load / reset), collapsible, height-capped

Panel state and inputs round-trip through profile files, verified by tests.

---

## Verification

Set `InpRunSelfTest = true` (optionally `InpSelfTestBars`) and run the EA in the
Strategy Tester. Each suite prints a pass/fail summary to the journal:

| Suite | Checks |
|---|---|
| `[SMC-OB]` | 129 — structure, displacement, lifecycle, zones, on synthetic and real data |
| `[SMC-OB]` panel | 55 — state, wiring, layout |
| `[SMC-CISD]` | 76, plus live-vs-batch equality |
| `[SMC-CONN]` | 36 — retest validity, direction, ordering, invalidation, single/multi modes, trend filter re-derived from raw candles |
| `[SMC-CFG]` | 6 — profile round-trip |

The connection suite also rebuilds each engine in batch mode and requires it to match
the live, bar-by-bar run exactly — the strongest guard against look-ahead and
repainting.

---

## Offline validation harness

A separate tool exports every detected signal to CSV and analyses it in Python.
It deliberately has **no broker model**: no balance, no lot sizes, no P&L — outcomes are
measured in R multiples only.

- Pinned settings file and reproducible runs (`run_meta.txt`)
- Stops from the swing or from the block edge; fixed-R targets, break-even and trailing variants
- Wilson confidence intervals and binomial p-values with Bonferroni correction
- Regime, volatility and session buckets; news-week segmentation
- Walk-forward: rules are selected in-sample and scored out-of-sample only

The walk-forward run that motivated the trend filter reported a 54.2% out-of-sample hit
rate at 1:1 (p = 0.0008) against 49.8% unfiltered.

---

## Usage

1. Copy the folder to `MQL5/Experts/Zaid/2026/SMC_OrderBlock_EA/` and compile `SMC_OrderBlock_EA.mq5`.
2. Attach it to a chart, then set the Order Block and CISD timeframes (default: current chart).
3. Use the panel for day-to-day switches and the inputs for defaults and profiles.
4. History depth is controlled by `InpScanDepth` (OB) and `InpCISDScanDepth` (CISD).
5. For journal detail raise `InpLogLevel`; for verification enable `InpRunSelfTest`.

## Requirements

MetaTrader 5, build 3000 or newer. M1 history is required for retest detection whenever
the Order Block timeframe is higher than M1.

## Notes

- Detection only — it never sends an order.
- Non-repainting by construction; `DESIGN.md` documents every threshold and definition.
- Past detection statistics are not a promise of future results, and nothing here is financial advice.
