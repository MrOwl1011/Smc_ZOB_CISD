# SMC Order Block EA

[![Snapchat](https://img.shields.io/badge/Snapchat-cicada.kw-FFFC00?logo=snapchat&logoColor=black)](https://www.snapchat.com/@cicada.kw)
[![TikTok](https://img.shields.io/badge/TikTok-%40z39-000000?logo=tiktok&logoColor=white)](https://www.tiktok.com/@z39)
[![Instagram](https://img.shields.io/badge/Instagram-coding__xaid-E4405F?logo=instagram&logoColor=white)](https://www.instagram.com/coding_xaid)

An **algorithmic trading bot** for MetaTrader 5, built on Smart Money Concepts. It reads market structure, marks Order Blocks on the chart, and executes trades by itself once you switch execution on.

It finds Order Blocks on a higher timeframe, waits for a CISD confirmation on a lower timeframe, and only enters when the higher timeframe is trending the same way. Everything is switchable from an on-chart panel.

**Trading is off by default.** Out of the box it only draws.

### What this software is

| | |
| --- | --- |
| Type | Automated trading robot (MT5 Expert Advisor), written in MQL5 |
| Automation | Fully automatic from signal to order: it finds the setup, opens the trade, sets the stop and target, and manages the exit without input from you |
| Also usable manually | Leave execution off and it works as a pure SMC chart tool, marking zones and confirmations for you to trade by hand |
| Decision making | Rule based and deterministic. The same history and settings always produce the same trades. No machine learning, no black box, no martingale, no grid, no hedging |
| Execution | Market orders, one position at a time, fixed lot size, stop and target placed with the order |
| Where it runs | On your own terminal or VPS, on any symbol your broker offers. Nothing is sent anywhere else |
| Source | Open source under MIT. Every rule is readable in the files listed below and written out in `DESIGN.md` |

Terms people use for this kind of software: algorithmic trading, algo trading, automated trading, auto trading, trading bot, trading robot, forex robot, expert advisor, EA, systematic trading, rule based trading, mechanical trading system.

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
13. [Keywords](#keywords)

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

## Keywords

For anyone searching in their own language. English and Arabic in full, Russian in short.

<details>
<summary>English keywords</summary>

**Smart Money Concepts**
`smart money concepts` · `SMC trading` · `smart money trading` · `institutional trading` · `institutional order flow` · `order block` · `order blocks` · `bullish order block` · `bearish order block` · `ZOrder block` · `series order block` · `breaker block` · `mitigation block` · `rejection block` · `supply zone` · `demand zone` · `supply and demand` · `imbalance` · `fair value gap` · `FVG` · `liquidity void` · `liquidity gap` · `liquidity sweep` · `liquidity grab` · `stop hunt` · `stop run` · `inducement` · `displacement` · `expansion candle` · `market structure` · `market structure shift` · `MSS` · `break of structure` · `BOS` · `change of character` · `CHoCH` · `change in state of delivery` · `CISD` · `delivery change` · `internal structure` · `external structure` · `swing high` · `swing low` · `higher high` · `higher low` · `lower high` · `lower low` · `equal highs` · `equal lows` · `dealing range` · `premium and discount` · `equilibrium` · `optimal trade entry` · `OTE` · `point of interest` · `POI` · `mitigation` · `invalidation` · `retest` · `zone retest` · `confirmation entry` · `ICT concepts` · `ICT trading` · `Wyckoff` · `accumulation` · `distribution` · `orderflow`

**Platform**
`MetaTrader 5` · `MetaTrader5` · `MT5` · `MT5 EA` · `MQL5` · `MQL5 source code` · `expert advisor` · `expert advisor MT5` · `EA` · `trading EA` · `MT5 indicator` · `chart indicator` · `custom indicator` · `strategy tester` · `MT5 strategy tester` · `backtest` · `backtesting` · `forward test` · `optimization` · `preset file` · `set file` · `configuration profile` · `magic number` · `MetaEditor` · `OnTick` · `OnChartEvent` · `chart objects` · `on chart panel` · `control panel EA` · `dashboard EA` · `open source EA` · `free expert advisor` · `MQL5 include` · `standard library` · `CTrade`

**Strategy and risk**
`algorithmic trading` · `algo trading` · `automated trading` · `trading bot` · `trading robot` · `systematic trading` · `quantitative trading` · `trend following` · `trend filter` · `multi timeframe` · `multi timeframe analysis` · `higher timeframe bias` · `lower timeframe entry` · `non repainting` · `no repaint` · `closed candle confirmation` · `ATR` · `average true range` · `ATR filter` · `volatility filter` · `risk reward` · `risk to reward` · `risk management` · `stop loss` · `take profit` · `break even stop` · `trailing stop` · `fixed lot` · `position sizing` · `one position at a time` · `drawdown` · `maximum drawdown` · `expectancy` · `win rate` · `profit factor` · `recovery factor` · `Sharpe ratio` · `R multiple` · `Monte Carlo` · `walk forward analysis` · `in sample` · `out of sample` · `overfitting` · `curve fitting` · `statistical validation` · `Wilson interval` · `binomial test` · `Bonferroni correction` · `signal validation` · `trade journal` · `self test` · `unit test`

**Markets**
`forex` · `forex trading` · `FX majors` · `FX minors` · `currency pairs` · `EURUSD` · `GBPUSD` · `USDJPY` · `USDCHF` · `AUDUSD` · `USDCAD` · `NZDUSD` · `CADJPY` · `EURCAD` · `gold` · `gold trading` · `XAUUSD` · `silver` · `XAGUSD` · `metals` · `indices` · `stock indices` · `US30` · `Dow Jones` · `NAS100` · `US100` · `Nasdaq` · `SPX500` · `US500` · `SP500` · `DAX40` · `GER30` · `GER40` · `UK100` · `FTSE100` · `US2000` · `Russell 2000` · `oil` · `crude oil` · `WTI` · `Brent` · `energy` · `CFD` · `spot` · `scalping` · `day trading` · `intraday trading` · `swing trading` · `London session` · `New York session` · `Asian session` · `killzone` · `session timing`

</details>

<details>
<summary>الكلمات المفتاحية بالعربية</summary>

**مفاهيم السمارت موني**
`سمارت موني` · `مفاهيم السمارت موني` · `التداول المؤسسي` · `أوامر المؤسسات` · `أوردر بلوك` · `أوردر بلوك شرائي` · `أوردر بلوك بيعي` · `مناطق الأوامر` · `مناطق الأوامر المؤسسية` · `بلوك الكسر` · `بلوك التعويض` · `منطقة العرض` · `منطقة الطلب` · `العرض والطلب` · `عدم التوازن` · `فجوة القيمة العادلة` · `فجوة سعرية` · `فراغ السيولة` · `سحب السيولة` · `اقتناص السيولة` · `صيد وقف الخسارة` · `استدراج` · `اندفاع سعري` · `شمعة اندفاعية` · `هيكل السوق` · `تغير هيكل السوق` · `كسر الهيكل` · `تغير الشخصية` · `تغير حالة التسليم` · `الهيكل الداخلي` · `الهيكل الخارجي` · `قمة سعرية` · `قاع سعري` · `قمم أعلى` · `قيعان أعلى` · `قمم أدنى` · `قيعان أدنى` · `قمم متساوية` · `قيعان متساوية` · `نطاق التداول` · `منطقة الخصم` · `منطقة العلاوة` · `نقطة التوازن` · `أفضل نقطة دخول` · `نقطة اهتمام` · `إعادة الاختبار` · `تعويض المنطقة` · `إبطال المنطقة` · `دخول بعد التأكيد` · `مفاهيم ICT` · `وايكوف` · `تجميع` · `تصريف` · `تدفق الأوامر`

**المنصة**
`ميتاتريدر 5` · `ميتاتريدر` · `إم تي 5` · `إكسبرت` · `إكسبرت ميتاتريدر 5` · `إكسبرت تداول` · `MQL5` · `كود MQL5` · `مؤشر ميتاتريدر` · `مؤشر مخصص` · `مختبر الاستراتيجيات` · `اختبار تاريخي` · `باك تست` · `اختبار أمامي` · `تحسين الإعدادات` · `ملف إعدادات` · `ملف preset` · `ملف تعريف` · `الرقم السحري` · `ميتا إيديتور` · `لوحة تحكم على الشارت` · `داشبورد` · `إكسبرت مفتوح المصدر` · `إكسبرت مجاني` · `مكتبة قياسية`

**الاستراتيجية وإدارة المخاطر**
`تداول آلي` · `تداول خوارزمي` · `روبوت تداول` · `بوت تداول` · `تداول مبرمج` · `تداول كمي` · `تتبع الاتجاه` · `فلتر الاتجاه` · `تعدد الأطر الزمنية` · `تحليل متعدد الأطر` · `اتجاه الفريم الكبير` · `دخول من فريم صغير` · `بدون إعادة رسم` · `تأكيد إغلاق الشمعة` · `متوسط المدى الحقيقي` · `فلتر التقلب` · `المخاطرة إلى العائد` · `إدارة المخاطر` · `وقف الخسارة` · `أخذ الربح` · `نقل الوقف لنقطة التعادل` · `وقف متحرك` · `حجم عقد ثابت` · `حجم المركز` · `مركز واحد فقط` · `أقصى تراجع` · `التوقع الرياضي` · `نسبة الربح` · `عامل الربح` · `عامل الاسترداد` · `مضاعف المخاطرة` · `مونت كارلو` · `تحليل أمامي متدرج` · `بيانات داخل النطاق` · `بيانات خارج النطاق` · `الإفراط في التحسين` · `تحقق إحصائي` · `اختبار ذاتي` · `سجل التداولات`

**الأسواق**
`فوركس` · `تداول الفوركس` · `العملات الرئيسية` · `العملات الثانوية` · `أزواج العملات` · `يورو دولار` · `باوند دولار` · `دولار ين` · `دولار فرنك` · `أسترالي دولار` · `دولار كندي` · `نيوزلندي دولار` · `الذهب` · `تداول الذهب` · `أوقية الذهب` · `الفضة` · `المعادن` · `المؤشرات` · `مؤشر داو جونز` · `مؤشر ناسداك` · `مؤشر إس آند بي` · `مؤشر داكس` · `مؤشر فوتسي` · `النفط` · `النفط الخام` · `خام برنت` · `خام غرب تكساس` · `الطاقة` · `عقود الفروقات` · `سكالبينج` · `تداول يومي` · `تداول سوينج` · `جلسة لندن` · `جلسة نيويورك` · `الجلسة الآسيوية` · `أوقات الجلسات`

</details>

**Русский**
`MetaTrader 5` · `советник` · `MQL5` · `смарт мани` · `ордер блок` · `зоны институциональных ордеров` · `смена характера поставки` · `слом структуры` · `смена характера рынка` · `имбаланс` · `снятие ликвидности` · `структура рынка` · `мультитаймфрейм` · `фильтр тренда` · `без перерисовки` · `алготрейдинг` · `торговый робот` · `бэктест` · `форекс` · `золото` · `индексы`

GitHub repository topics only accept Latin letters, digits and hyphens, so the Arabic and
Russian terms live here in the README, where search still finds them. Topics for the
repository itself:

```text
mql5  metatrader5  expert-advisor  smart-money-concepts  smc  order-block  cisd
market-structure  break-of-structure  fair-value-gap  algorithmic-trading  trading-bot
forex  gold  xauusd  indices  backtesting  non-repainting
```
