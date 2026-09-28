# SMC Order Block EA

A MetaTrader 5 Expert Advisor that marks Smart Money Concepts structure on the chart and can trade it.

It finds Order Blocks on a higher timeframe, waits for a CISD confirmation on a lower timeframe, and only enters when the higher timeframe is trending the same way. Everything is switchable from an on-chart panel.

**Trading is off by default.** Out of the box it only draws.

![MQL5](https://img.shields.io/badge/MQL5-MetaTrader%205-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Self tests](https://img.shields.io/badge/self%20tests-271%20checks-lightgrey)

## Contents

1. [Install](#install)
2. [First run](#first-run)
3. [The panel](#the-panel)
4. [Trading rules](#trading-rules)
5. [Settings packages](#settings-packages)
6. [Screenshots](#screenshots)
7. [Does it work?](#does-it-work)
8. [Files](#files)
9. [Self tests](#self-tests)
10. [Troubleshooting](#troubleshooting)
11. [Contributing](#contributing)
12. [License](#license)

## Install

**1. Clone into your MQL5 Experts folder**

```bash
cd "%APPDATA%\MetaQuotes\Terminal\<terminal-id>\MQL5\Experts"
git clone https://github.com/MrOwl1011/Smc_ZOB_CISD.git SMC_OrderBlock_EA
```

**2. Compile**

Open `SMC_OrderBlock_EA.mq5` in MetaEditor and press F7. A clean build says `0 errors, 0 warnings`.

**3. Copy the settings files**

```text
presets\*.set   ->  MQL5\Presets\
profiles\*.cfg  ->  MQL5\Files\SMC_OrderBlock_EA\
```

Needs MetaTrader 5 (developed on build 6182) and M1 history for any symbol you trade.

## First run

1. Drag the EA onto a chart.
2. In the properties dialog press **Load** and pick `presets/SMC_1_BestOverall.set`.
3. Let it draw. Zones, retests and CISD confirmations appear as it scans history.
4. When you are ready to trade, switch **Trade execution** on in the panel.

That preset uses H1 blocks with M5 confirmations, which is the combination that tested best.

## The panel

Everything day-to-day is on the chart, not in the inputs dialog.

| Section | Controls |
| --- | --- |
| Mode | Easy (zones only) or Advanced |
| Display | Bull and bear zones, labels, fills, old zones, retests, retest start, swings |
| Timeframes | Order Block TF and CISD TF, independent of the chart |
| CISD | Liquidity sweep, confirmation close, retracement |
| Connection | Retest mode, CISD mode, mitigation stops CISD, trend filter |
| Trading | Trade execution, lot size, ride the trend, take profit R, break even, break even points, opposite block exit |
| Configuration | Save, Load, Reset to inputs |

Panel state is remembered per chart.

## Trading rules

| | |
| --- | --- |
| Entry | Market, when the CISD confirms inside a retested block |
| Stop | The far side of the block |
| Target | Reward:risk multiple of that distance, default 1:1 |
| Size | Fixed lots, default 0.01 |
| Exposure | One position at a time |

Three optional exits, each its own switch:

| Switch | What it does |
| --- | --- |
| **Ride the trend** | No fixed target. Holds until price reaches the nearest opposite-direction block, which becomes a moving target. Overrides the R:R setting. |
| **Break even** | Once the trade is a set number of points in profit, moves the stop to entry. Off by default; it cost most of the profit in testing. |
| **Opposite block exit** | A block forming against an open trade, then retested, closes it early. |

## Settings packages

Seven general packages plus fifteen per-symbol ones, as MT5 presets (`.set`) and panel profiles (`.cfg`).

| Preset | For |
| --- | --- |
| `SMC_1_BestOverall` | The default. Best and most stable in testing. |
| `SMC_2_Forex` | FX majors |
| `SMC_3_Metals` | Gold |
| `SMC_4_Indices` | US500, GER30, UK100, US30 |
| `SMC_5_Safest` | Fewer trades, smaller drawdown |
| `SMC_SYM_*` | One symbol and timeframe pair each, from the markets that scored above 59% |

Full tables: [presets/PACKAGES.md](presets/PACKAGES.md) and [presets/SYMBOL_PRESETS.md](presets/SYMBOL_PRESETS.md).

## Screenshots

None yet. The repository deliberately contains no generated or illustrated images, so this section is empty until real MetaTrader screenshots are added.

To add your own, drop the files in a `screenshots/` folder and reference them here:

| File | Show |
| --- | --- |
| `screenshots/chart.png` | A chart with zones, a retest and a CISD confirmation |
| `screenshots/panel.png` | The control panel, Advanced mode |
| `screenshots/trade.png` | An open trade with its stop and target |

## Does it work?

Measured over 19 markets and 20 months in R multiples, not currency. Full detail in [research/REPORT.md](research/REPORT.md).

| | |
| --- | --- |
| Recommended setup, H1 to M5 | 57.2% win rate, +0.143 R per trade, profit factor 1.34 |
| In sample against out of sample | +0.143 R against +0.144 R |
| Walk forward | 5 of 5 windows positive out of sample |
| Monte Carlo | 99.9% chance the edge is positive; expect a drawdown near 22 R |
| Markets positive | 15 of 19 |
| **Trend filter off** | **50.3%, no edge at all** |

Read that last line twice. The trend filter is the strategy.

Three limits worth knowing.

1. **H4 to M15 is unproven** — 127 trades in 20 months and negative out of sample.
2. **M15 to M1 cannot be validated far back** — brokers keep only a few months of M1 history.
3. **Fixed lots means uneven risk** — the stop is the block height, so dollar risk changes trade to trade.

Results come from one broker over one 20-month stretch.

## Files

```text
SMC_OrderBlock_EA.mq5      entry point: inputs, events, wiring
SMC_OB_Structure.mqh       swings, BOS, CHoCH
SMC_OB_Displacement.mqh    impulse tests, picks the block candle
SMC_OB_Engine.mqh          Order Block lifecycle
SMC_OB_FVG.mqh             Fair Value Gaps
SMC_CISD_Engine.mqh        sweep, series, confirmation, retracement
SMC_Connect_Engine.mqh     HTF block to LTF CISD, M1 retest, trend filter
SMC_OB_TradeHooks.mqh      the only file that sends orders
SMC_OB_Panel.mqh           the on-chart panel
SMC_Config.mqh             named profiles on disk
SMC_*_Visual.mqh           drawing
SMC_*_SelfTest.mqh         verification suites
DESIGN.md                  every rule and threshold, precisely
presets/ profiles/         settings packages
research/                  validation report, data tables, analysis scripts
```

Detection never calls the broker. Only `SMC_OB_TradeHooks.mqh` does.

Three rules the code keeps: closed candles only, nothing repaints, and no trading from history-scan signals.

## Self tests

Set `InpRunSelfTest = true` and run the EA in the Strategy Tester.

| Suite | Checks |
| --- | --- |
| Order Blocks | 129 |
| Panel | 47 |
| CISD | 76 plus 3 wiring |
| Connection | 10 wiring, plus a full replay suite |
| Config profiles | 6 |

The connection suite replays every engine in batch and demands it match the live bar-by-bar run exactly. That is the test that catches repainting or look-ahead.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| No zones | History still downloading, or `InpScanDepth` exceeds available bars |
| No retests | M1 history missing; open an M1 chart once to download it |
| No orders | `InpEnableTrading` off, algo trading disabled in the terminal, or a position is already open. The journal says which, tagged `[SMC-TRADE]`. |
| Signal skipped, "stop too close" | The block is narrower than the broker's minimum stop distance |
| Self test fails after an edit | Compare against `DESIGN.md`; the tests assert what is written there |

## Contributing

Pull requests welcome. Two asks: run the self tests and paste the journal summary, and if you change detection, update `DESIGN.md` in the same commit.

## License

MIT, see [LICENSE](LICENSE). Free to use, change and redistribute, including commercially, with the copyright notice kept.

Not financial advice. Trading risks real money, and the numbers above describe the past.
