# SMC Order Block Strategy — NinjaTrader 8 port

A port of `SMC_OrderBlock_EA.mq5` (v2.00) to a NinjaTrader 8 strategy. The detection
and trade logic is translated line for line from the `.mqh` engines:

| NinjaTrader class | MQL5 source |
| --- | --- |
| `SmcStructure` | `SMC_OB_Structure.mqh` |
| `SmcDisplacement` | `SMC_OB_Displacement.mqh` |
| `SmcFvg` | `SMC_OB_FVG.mqh` |
| `SmcDetector` | `SMC_OB_Engine.mqh` |
| `SmcCisdEngine` | `SMC_CISD_Engine.mqh` |
| `SmcConnection` | `SMC_Connect_Engine.mqh` (trend filter included) |
| `SmcCapitalGuard` | `SMC_OB_Guards.mqh` |
| `SmcConfidence` | `SMC_OB_Confidence.mqh` |
| trade region of `SMCOrderBlockStrategy` | `SMC_OB_TradeHooks.mqh` and the EA's `OnTick` / `TradeConfirmedSetup` wiring |

## Install

1. Copy `SMCZobEngines.cs` and `SMCOrderBlockStrategy.cs` to
   `Documents\NinjaTrader 8\bin\Custom\Strategies\`.
2. Open the NinjaScript Editor and compile (F5).
3. Add **SMCOrderBlockStrategy** to a chart or the Strategy Analyzer.

## Running it

- The strategy adds three series itself: the Order Block timeframe, the CISD timeframe
  (both set by **Timeframes**: H4→M15, H1→M5, M15→M1) and **1 minute**. The instrument
  needs 1-minute history.
- **Execute trades** is off by default, as in the EA. Turn it on for a backtest.
- Load enough days for warm-up. The EA's history scan runs once the first bars are
  available, and those scan events never trade, the same as in MT5. Everything after
  the scan trades.
- The EA's presets map one to one onto the inputs, which keep their MT5 names without the
  `Inp` prefix.

## What differs, and why

These differences come from the platform. The detection rules are unchanged.

| Area | MT5 EA | NinjaTrader port |
| --- | --- | --- |
| Bar timestamps | Bar open time | NinjaTrader stamps bars at their close. The port converts every bar to open time before the engines see it, so all timestamp comparisons work unchanged. |
| H4 candles | Aligned to server midnight | Built from the instrument's trading hours template. H1, M15, M5 and M1 line up; H4 boundaries depend on the template. |
| Size | Lots (`InpLots`) | Whole contracts (`Contracts`, min 1, step 1). Risk % sizing uses `PointValue`. |
| Points | `SYMBOL_POINT` | Ticks (`BreakEvenTicks`). |
| Equity | `ACCOUNT_EQUITY` | `EquityBase` + this strategy's closed P/L + open P/L. Used by risk % sizing and the guards. |
| Margin fit | `FitMargin` shrinks size to free margin | Not available in NinjaTrader, so it's skipped. |
| Broker stop level | `SYMBOL_TRADE_STOPS_LEVEL` | 0 |
| Spread guard / score | `SYMBOL_SPREAD` | Ask − Bid. Historical data has no spread, so the guard is inert in backtests (MT5 behaves the same when the spread is 0). |
| Volatility guard | ATR(14) including the forming bar | ATR(14), a simple mean of true range, on closed chart bars. |
| Guard memory | GlobalVariables survive restarts (reset in the tester) | Starts fresh on every run, like the MT5 tester. |
| Break even / ride the trend / equity stop | Checked every tick | Checked on each M1 and OB bar close. |
| Market entry | Fills at the current tick | Fills at the next M1 bar open in backtests. Stop and target prices are computed from the signal-time price, as in the EA. |
| Orders in flight | MT5 opens and closes positions synchronously | Pending-entry and pending-exit flags stop a second entry or exit from firing before a fill. |
| Alerts | `Alert()` | `Alert()` in realtime only. Every message also goes to the Output window. |
| CSV logs | Common Files folder | `Documents\NinjaTrader 8\` (`SMC_Confidence.csv`, `SMC_Results.csv`) |

Not ported, because they contain no trading logic: the on-chart panel (its defaults
come from the inputs, sanitised exactly as `CSMCPanel::Sanitize` does), the chart
theme, the CISD and connection drawings, the SD projections, configuration profiles
and the self-tests. Order Block zones are drawn as rectangles; switch this off with
**Draw Order Block zones**.
