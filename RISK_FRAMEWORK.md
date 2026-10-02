# Adaptive risk and take-profit framework

Design document for position sizing, confidence scoring, take profit and capital protection
in the SMC Order Block EA. Every model below is written against data the EA already
produces, so none of it needs new detection logic.

Measured results quoted here come from this repository's own tests: 177 three-year
backtests on XAUUSD and six other instruments, logged in `research/` and the stage CSVs.

---

## 0. What the EA already gives you

Position sizing and take profit are only as good as the information they receive. The EA
already computes everything in this table and currently throws most of it away.

| Field | Where | What it tells a sizing or TP model |
| --- | --- | --- |
| `netMove` | `SOrderBlock` | Size of the impulse out of the block, in price |
| `atr` | `SOrderBlock` | ATR measured **before** the impulse, so it never inflates itself |
| `strongestBodyPct` | `SOrderBlock` | Body/range of the strongest candle in the leg |
| `relStrength` | `SOrderBlock` | Strongest body divided by the average body |
| `legBars` | `SOrderBlock` | Bars from block to break; shorter is more violent |
| `isChoch` | `SOrderBlock` | Break was a character change, not a continuation |
| `hasFVG` | `SOrderBlock` | Fair value gap accompanies the block |
| `seriesCount` | `SOrderBlock` | Candles in the block series; width proxy |
| `top`, `bottom` | `SOrderBlock` | Zone height, which is also the stop distance |
| `confirmTime` | `SOrderBlock` | Block age at entry |
| `retestCount` | `SOrderBlock` | Which touch this is |
| `barsMonitored` | `SOrderBlock` | How long the block has been watched |
| `state` | `SOrderBlock` | Live / retested / mitigated |
| `cisd.sweepTime` | `SConnCISDHit` | Whether a liquidity sweep preceded the CISD |
| `confirmPrice` | `SConnCISDHit` | Entry reference |
| `retestNo` | `SConnCISDHit` | Retest index that produced this signal |
| trend score | `CSMCConnection::TrendOK` | `(close − close[N]) / ATR`, already computed per signal |

Three derived quantities are used throughout this document:

```
R            = |entry − stop|                        risk distance in price
zoneATR      = (top − bottom) / atr                  block height in ATR
ageBars      = (now − confirmTime) / PeriodSeconds   block age on the OB timeframe
trendScore   = (close − close[trendBars]) / ATR(14)  signed, already in the engine
```

---

## 1. Position sizing models

All models answer one question: how many lots for this trade. The money form is always

```
lots = riskMoney / (R_points × valuePerPointPerLot)

valuePerPointPerLot = SYMBOL_TRADE_TICK_VALUE × (SYMBOL_POINT / SYMBOL_TRADE_TICK_SIZE)
R_points            = |entry − stop| / SYMBOL_POINT
```

The models differ only in how `riskMoney` is decided. This matters: with a block-edge stop,
R varies from a few dollars to tens of dollars on the same symbol, so **fixed lots means
wildly unequal risk**. That is the single biggest defect in the EA today, and it is why
currency profit in the optimisation partly reflected stop width rather than accuracy.

### 1.1 Fixed risk percent

```
riskMoney = equity × riskPct            typical riskPct = 0.005 … 0.01
```

| | |
| --- | --- |
| Logic | Every trade risks the same fraction of equity, whatever the stop width |
| Advantages | Normalises R across instruments and volatility regimes; the only model whose backtest translates directly to a live account; compounds |
| Weaknesses | Takes full risk into losing streaks; equity-linked so a drawdown shrinks size exactly when the edge may be recovering |
| Profit factor | Unchanged. PF is ratio-based and insensitive to uniform scaling |
| Drawdown | Falls sharply in percent terms against fixed lots on instruments with variable stop width |
| Recovery factor | Rises, because drawdown falls faster than profit |
| Consecutive losses | Unchanged. Sizing never changes which trades win |

**Example.** Equity 10,000, risk 0.75%, gold stop 1,340 points, tick value 1.00 per 0.01 lot
per 0.01 move. riskMoney = 75. valuePerPointPerLot = 1.00. lots = 75 / 1340 = 0.056 → 0.05
after rounding to the lot step.

**MQL5 notes.** Compute in `CSMCTradeEngine::OnSignal` where `risk` is already known.
Round with `MathFloor(lots/step)*step`, clamp to `SYMBOL_VOLUME_MIN/MAX`, then confirm with
`OrderCalcMargin` and reduce until margin fits free margin with a buffer. Never round up.

### 1.2 ATR-based risk

```
riskMoney = equity × riskPct
stop      = entry ± k × ATR            k typically 1.0 … 1.5
```

Replaces the block edge with an ATR distance. **Do not adopt this.** The block edge is the
strategy's invalidation point: price beyond it means the setup was wrong. An ATR stop
discards that information and the measured stop-to-structure relationship. Keep ATR for
*normalising* risk, not for placing stops.

### 1.3 Volatility-adjusted risk

```
volRatio  = ATR(14) / SMA(ATR(14), 200)
riskMoney = equity × riskPct × clamp(1 / volRatio, 0.5, 1.5)
```

| | |
| --- | --- |
| Logic | Cut size when the instrument is unusually volatile, restore it when quiet |
| Advantages | Smooths the equity curve; protects against gap-prone sessions |
| Weaknesses | Gold's best periods in this study were the volatile ones, so this would have cut size into the trend |
| Expected impact | Drawdown down, profit down, recovery factor roughly flat |

Measured context: the earlier 19-market study found high-volatility buckets at 54.6% and low
at 53.2%, both insignificant. **Volatility did not predict outcome, so this model costs
return without buying accuracy.** Include it only as a tail guard with a floor of 0.5.

### 1.4 Market regime risk

```
regime    = |trendScore|                              already computed
riskMoney = equity × riskPct × (regime >= 2.5 ? 1.25 : regime >= 1.5 ? 1.0 : 0.0)
```

| | |
| --- | --- |
| Logic | Scale with the filter that is already proven to carry the edge |
| Advantages | Directly supported by measurement rather than theory |
| Weaknesses | Concentrates risk in the regime that is also most crowded |
| Expected impact | PF up, profit up, drawdown up slightly, recovery factor up |

Measured context: trend gate 1.5 → average +100 USD, gate 2.5 → average +279 USD across 81
configurations. This is the strongest single relationship found in the whole study.

### 1.5 Drawdown-adaptive risk

```
peakEquity = max(peakEquity, equity)
dd         = (peakEquity − equity) / peakEquity
riskMoney  = equity × riskPct × (dd < 0.05 ? 1.0 : dd < 0.10 ? 0.6 : dd < 0.15 ? 0.35 : 0.0)
```

| | |
| --- | --- |
| Logic | Shrink exposure as the account falls from its high-water mark; stop at a hard floor |
| Advantages | Bounds the worst case; the one model that reliably prevents account death |
| Weaknesses | Guarantees slower recovery; if the edge is intact, you are small exactly when you should be normal |
| Drawdown | Materially reduced. This is its entire purpose |
| Recovery factor | Usually up, since the denominator falls faster than profit |
| Consecutive losses | Unchanged in count, reduced in cost |

**MQL5 notes.** Track `peakEquity` in a global and persist it to a `GlobalVariable` keyed by
magic number, so a terminal restart does not reset the high-water mark and silently restore
full risk mid-drawdown.

### 1.6 Consecutive-loss adaptive risk

```
riskMoney = equity × riskPct × pow(0.75, min(consecLosses, 4))
```

Four losses in a row reduces risk to 32% of base; the first win restores it.

| | |
| --- | --- |
| Advantages | Cheap to implement; responds faster than drawdown-based scaling |
| Weaknesses | Streaks are mostly random. This buys comfort, not expectancy |
| Expected impact | Drawdown down modestly, profit down modestly, PF unchanged |

Measured context: longest losing run was 5 trades for the recommended configuration and 8–17
for the weaker ones. A streak-based rule rarely triggers on the good configurations, which is
a point in its favour: it stays out of the way until something is wrong.

### 1.7 Equity-curve sizing

```
equityMA = SMA(closed-trade equity curve, 10 trades)
riskMoney = equity × riskPct × (equity > equityMA ? 1.0 : 0.5)
```

Trade full size only while the strategy's own equity is above its moving average.

| | |
| --- | --- |
| Advantages | Systematic version of "stop trading when it stops working" |
| Weaknesses | Whipsaws on a 40% win rate strategy; cuts size right before recoveries as often as before declines |
| Expected impact | Neutral to negative at this win rate. Needs ≥ 100 trades before the average means anything |

Not recommended for the 2R configurations, which win 40% of the time. Defensible on the 1R
configurations, which win 56%.

### 1.8 Confidence-score sizing

```
riskMoney = equity × riskPct × confidenceMultiplier(score)      see section 2
```

The model this framework recommends as the primary one. It is the only sizing approach that
uses the setup's own quality rather than account state.

### 1.9 Order-block quality sizing

A component of the confidence score rather than a standalone model:

```
quality = 0.35 × norm(relStrength, 1.5, 4.0)
        + 0.25 × norm(strongestBodyPct, 55, 85)
        + 0.20 × norm(netMove / atr, 1.5, 4.0)
        + 0.10 × (hasFVG ? 1 : 0)
        + 0.10 × (1 − norm(legBars, 1, 8))
```

Measured context: displacement 2.5 versus 1.5 changed the average result from +197 to +373
USD with profit factor 1.08 → 1.36. **Block quality measurably predicts outcome**, which is
what justifies sizing on it.

### 1.10 Structure-strength sizing

```
strength = 0.5 × norm(|trendScore|, 1.5, 3.5) + 0.3 × (isChoch ? 0.4 : 1.0) + 0.2 × norm(bosDistance/atr, 0.5, 2.5)
```

A continuation break in an established trend earns more size than a first character change.
Overlaps heavily with 1.4; use one or the other, not both at full weight.

### 1.11 Liquidity-based sizing

```
sweepAge  = confirmTime − cisd.sweepTime
liquidity = sweepPresent ? (sweepAge <= 10 bars ? 1.0 : 0.7) : 0.4
```

Measured context: the CISD engine's sweep stage was **off** in every profitable configuration
found (`cisdSweep=0` in the tested profile). Treat this factor as unvalidated on this EA, give
it a small weight, and test it before trusting it.

### Sizing summary

| Model | Profit | Drawdown | Recovery | Streaks | Verdict |
| --- | --- | --- | --- | --- | --- |
| Fixed risk % | = | down | up | = | **Foundation. Adopt first.** |
| Confidence score | up | down | up | down | **Primary allocator** |
| Regime risk | up | up | up | = | Adopt, capped |
| Drawdown adaptive | down | **down** | up | = | **Adopt as a floor** |
| OB quality | up | down | up | down | Fold into confidence |
| Structure strength | up | = | up | = | Fold into confidence |
| Consecutive loss | down | down | = | = | Optional comfort |
| Volatility adjusted | down | down | = | = | Tail guard only |
| Equity curve | ? | ? | ? | ? | Not at 40% win rate |
| Liquidity | ? | ? | ? | ? | Unvalidated here |
| ATR stop | — | — | — | — | **Rejected: discards invalidation** |

---

## 2. Confidence score engine

A single 0–100 score computed once, at the moment the CISD confirms, from data already in
hand. No forward-looking inputs, so it cannot repaint.

### Factors and weights

| # | Factor | Source | Weight | Full marks when |
| --- | --- | --- | --- | --- |
| 1 | HTF trend strength | `trendScore` | 20 | \|score\| ≥ 3.0 |
| 2 | Block quality | `relStrength`, `strongestBodyPct` | 15 | relStrength ≥ 3.0 and body ≥ 75% |
| 3 | Impulse size | `netMove / atr` | 10 | ≥ 3.0 ATR |
| 4 | Block freshness | `ageBars` | 10 | ≤ 20 bars old |
| 5 | Retest index | `retestNo` | 8 | first retest |
| 6 | Block height | `zoneATR` | 8 | 0.4 … 1.2 ATR |
| 7 | FVG confluence | `hasFVG` | 7 | present and not late |
| 8 | CISD quality | series length, confirm close vs level | 7 | close beyond level by ≥ 0.2 ATR |
| 9 | Spread quality | `SYMBOL_SPREAD` vs R | 6 | spread ≤ 2% of R |
| 10 | Session | server hour | 5 | London or London/NY overlap |
| 11 | Liquidity sweep | `cisd.sweepTime` | 4 | sweep within 10 bars |

Sum = 100. Factors 1–3 carry 45 points because they are the three the backtests showed
actually separate winners from losers.

### Normalisation helper

```
double Norm(double v, double lo, double hi)   // 0 at lo, 1 at hi, clamped
  {
   if(hi <= lo) return 0.0;
   return MathMax(0.0, MathMin(1.0, (v - lo) / (hi - lo)));
  }
```

### Score formula

```
score = 20 × Norm(|trendScore|, 1.5, 3.0)
      + 15 × (0.6 × Norm(relStrength, 1.5, 3.0) + 0.4 × Norm(strongestBodyPct, 55, 75))
      + 10 × Norm(netMove / atr, 1.5, 3.0)
      + 10 × (1 − Norm(ageBars, 10, 60))
      +  8 × (retestNo == 1 ? 1.0 : retestNo == 2 ? 0.5 : 0.0)
      +  8 × Band(zoneATR, 0.4, 1.2)                  // 1 inside the band, decaying outside
      +  7 × (hasFVG ? (fvgLate ? 0.5 : 1.0) : 0.0)
      +  7 × Norm(confirmBeyondLevel / atr, 0.0, 0.3)
      +  6 × (1 − Norm(spreadPoints / R_points, 0.005, 0.03))
      +  5 × SessionWeight(hour)                      // London 1.0, NY 0.8, Asia 0.4
      +  4 × (sweepPresent ? (sweepAgeBars <= 10 ? 1.0 : 0.6) : 0.0)
```

### Risk bands

| Score | Action | Risk multiplier |
| --- | --- | --- |
| 90–100 | Maximum | 1.50 × base |
| 75–89 | Normal | 1.00 × base |
| 60–74 | Reduced | 0.50 × base |
| < 60 | **No trade** | 0 |

With base risk 0.5% of equity this gives 0.25% to 0.75% per trade, and a hard refusal below
60. Cap total risk-on-the-book at 1.5% regardless of score.

### Worked example

Gold M15 block, trendScore 2.8, relStrength 3.4, body 71%, netMove 3.1 ATR, 14 bars old,
first retest, zone 0.8 ATR, FVG present, confirm 0.25 ATR beyond level, spread 0.9% of R,
London, sweep 6 bars ago:

```
20×0.87 + 15×(0.6×1.0 + 0.4×0.80) + 10×1.0 + 10×(1−0.08) + 8×1.0
+ 8×1.0 + 7×1.0 + 7×0.83 + 6×0.84 + 5×1.0 + 4×1.0
= 17.4 + 13.8 + 10 + 9.2 + 8 + 8 + 7 + 5.8 + 5.0 + 5 + 4 = 93.2
```

Score 93 → maximum risk. Equity 10,000, base 0.5%, multiplier 1.5 → riskMoney 75 →
0.05 lots on a 1,340-point stop.

### MQL5 notes

Compute in `TradeConfirmedSetup` where both `SOrderBlock` and `SConnEvent` are in scope, pass
the score into `OnSignal`, and **log every component**. A score you cannot decompose after a
losing month is a score you will stop trusting. Store the score in the order comment or a
parallel CSV so the factors can be regressed against outcome later — that regression is how
the weights get fixed properly instead of by judgement.

---

## 3. Take profit models

Measured baseline, 81 configurations across three years on gold:

| Target | Avg profit | Avg PF | Avg recovery | Avg drawdown | Avg streak |
| --- | --- | --- | --- | --- | --- |
| 1R | +321 | 1.25 | 1.78 | 202 | 6.3 |
| **2R** | **+525** | **1.34** | **2.21** | 289 | 8.9 |
| 3R | +198 | 1.12 | 0.33 | 642 | 13.2 |

### 3.1 Fixed RR

Current behaviour. **Best when** the instrument's moves are consistent in size, and for
honest measurement, because the R multiple is unambiguous. **Poor when** volatility changes
between regimes: a fixed 2R is too far in quiet markets and too near in trends.

Win rate falls as RR rises (56% at 1R, 40% at 2R, 30% at 3R measured). Profit factor peaks
at 2R. Keep fixed RR as the control arm for every experiment below.

### 3.2 Dynamic RR from confidence

```
targetRR = 1.5 + 1.5 × (score − 60) / 40          // 1.5R at score 60, 3.0R at 100
```

**Best when** the confidence score genuinely discriminates. **Poor when** it does not: you
then simply move good trades further away. Expected: win rate down slightly, average trade up,
PF up if the score works. This is the model to test immediately after the score exists.

### 3.3 ATR-based TP

```
target = entry ± k × ATR(14)        k = 2 … 4
```

**Best when** stop distance is unrelated to volatility. In this EA the stop *is* the block
height, which already scales with volatility, so ATR targets duplicate information. Expect
little change from fixed RR. Low priority.

### 3.4 Liquidity-target TP

Target the nearest opposing liquidity pool: equal highs/lows, or the swing the CISD engine
already tracks.

```
target = nearest untouched swing extreme beyond entry in trade direction
guard  = clamp(target, entry ± 1.0R, entry ± 3.5R)
```

**Best when** structure is clean and the pool is 1.5–3R away. **Poor when** the pool is
adjacent, which caps the trade below 1R. The guard is mandatory. Expected: win rate up,
average trade down, PF up modestly.

### 3.5 Structure-based TP

Target the opposite-direction block, which the EA already finds: this is the existing
**ride the trend** switch. Measured: recovery factor 5.69 → 1.28 on gold. **It made things
materially worse**, because without a fixed target the trade gives back open profit while
waiting for a block that may not form. Do not use it as the default; it is defensible only
with a trailing stop attached, which is section 3.8.

### 3.6 Swing high/low TP

A narrower case of 3.4 using only confirmed swings from `CSMCStructure`. Same profile, easier
to implement, less adaptive. Use it as the fallback when no liquidity pool is in range.

### 3.7 Partial take profits

```
50% of position at 1R, stop to break even
remaining 50% at 2.5R or structure target
```

**Best when** win rate is low and give-back is the main leak — exactly this EA's profile at
2R. **Poor when** spread or commission is large relative to R, since you pay to exit twice.
Expected: win rate up strongly (the first half nearly always fills at 1R), drawdown down,
average trade down, PF usually up.

Caution from this repository's own data: moving the stop to break even **too early** was the
single most damaging exit change tested — break even at 1000 points cut profit from +810 to
+430, while 4000 points improved it. If partials move the stop to break even at 1R, the
remaining half must then tolerate normal noise or the same damage appears.

### 3.8 Volatility-expansion TP (trailing)

```
if (openProfit >= 1.5R) trail stop by max(2.5 × ATR(14), 0.8R) behind the extreme
```

**Best when** the instrument trends persistently — gold in 2025-26. **Poor when** it chops:
the trail converts winners into scratches. Expected: win rate down, average winner up, PF up
only if the trend persists.

### 3.9 Trend-strength TP

```
targetRR = |trendScore| >= 2.5 ? 2.5 : |trendScore| >= 1.5 ? 2.0 : 1.5
```

Cheap, uses the one factor measurement supports, and needs no new state. **Recommended as the
first adaptive TP to test.**

### 3.10 Session-based TP

```
London  → 2.0R      NY → 2.0R      Asia → 1.5R
```

Measured context: sessions differed by under one percentage point of accuracy (53.8% to
54.8%) in the 19-market study, so expect a small effect. Low priority.

---

## 4. Adaptive TP engine

Choose the method per trade from state the EA already has. Deterministic, so it remains
testable.

```
ENUM_TP_MODE SelectTP(symbolClass, trendScore, volRatio, session, structureStrength)
  {
   // 1. Hard floor: weak structure never earns a distant target
   if(|trendScore| < 1.5)                      return TP_FIXED_1R;

   // 2. Instrument character
   if(symbolClass == METAL)                     // wide, trending, high ATR
      return (|trendScore| >= 2.5) ? TP_TREND_2_5R : TP_FIXED_2R;

   if(symbolClass == INDEX)                     // momentum, fast mean reversion
      return (volRatio > 1.2) ? TP_PARTIAL_1R_2_5R : TP_FIXED_2R;

   if(symbolClass == FOREX)                     // structure respected, pools cluster
      return TP_LIQUIDITY_GUARDED;

   if(symbolClass == COMMODITY)                 // volatile, gap prone
      return TP_ATR_3X;

   return TP_FIXED_2R;
  }
```

| Instrument | Default | Reasoning from measurement |
| --- | --- | --- |
| Gold | 2R fixed, 2.5R when trendScore ≥ 2.5 | 2R was optimal across 81 configs; 3R collapsed to RF 0.33 |
| Indices | Partial 1R / 2.5R | US30 best config won 78.6% on 28 trades: few, high-quality signals favour banking half |
| Forex | Liquidity target, guarded 1–3R | FX was flat on every fixed RR tested; structure targets are the untested alternative |
| Commodities | 3 × ATR | No commodity in the sample had enough trades to say more |

**Classification.** Do not parse symbol names. Derive the class from
`SYMBOL_TRADE_CALC_MODE`, `SYMBOL_PROFIT_CURRENCY` and the ratio
`ATR(14) / SYMBOL_POINT`, with an input override per chart. Name parsing breaks the moment a
broker renames the feed — this repository already hit that failure twice.

---

## 5. Capital protection

Hard limits that run before anything else. Each is a refusal, never a resize.

| Guard | Rule | Default |
| --- | --- | --- |
| Daily loss | Stop new trades when realised P/L today ≤ −x% of day-start equity | 2% |
| Weekly loss | Same, Monday to Friday | 4% |
| Consecutive losses | Pause until the next session after N losses | 5 |
| Equity protection | Flatten and stop below x% of the high-water mark | 12% |
| Dynamic reduction | Risk × 0.6 at 5% drawdown, × 0.35 at 10% | section 1.5 |
| Spread filter | Skip if spread > 3% of R | 3% |
| Volatility filter | Skip if ATR(14) > 2.5 × SMA(ATR,200) | 2.5× |
| Session filter | Optional: skip 00:00–01:00 server | off |
| News | Skip ±15 min around high-impact events | off by default |

### Pseudocode

```
bool AllowNewTrade(score, R, spread)
  {
   if(DayLoss()   <= -dailyLimit  * dayStartEquity)  return false;
   if(WeekLoss()  <= -weeklyLimit * weekStartEquity) return false;
   if(consecLosses >= maxConsec && !NewSessionSince(lastLossTime)) return false;
   if(equity < peakEquity * (1 - equityStop))        { CloseAll(); Halt(); return false; }
   if(spread > spreadPctOfR * R)                     return false;
   if(ATR(14) > volSpike * ATRAverage())             return false;
   if(score < 60)                                    return false;
   return true;
  }
```

**News protection.** MQL5's economic calendar (`CalendarValueHistory`) is unavailable in the
Strategy Tester, so a news filter cannot be backtested. Two consequences: build it as an
input that is **off** during optimisation, and never compare a news-filtered live result to an
unfiltered backtest.

**Daily and weekly boundaries** use server time, and the week must reset on the broker's
Monday, not the calendar's. Persist `dayStartEquity`, `weekStartEquity` and `peakEquity` in
`GlobalVariable`s keyed by magic so a restart cannot clear a breach.

---

## 6. Recommendations

### Top 5 sizing systems

1. **Fixed risk percent** — the foundation. Nothing else is meaningful until risk per trade is constant.
2. **Confidence-score multiplier** (0.5× / 1.0× / 1.5×, refuse below 60) — the only model that uses setup quality.
3. **Drawdown-adaptive floor** (0.6× at 5%, 0.35× at 10%, stop at 12%) — bounds the worst case.
4. **Regime multiplier** capped at 1.25× — backed by the strongest measured relationship in the study.
5. **Consecutive-loss damping** (0.75^n, n ≤ 4) — cheap insurance that stays dormant on good configurations.

Stack as: `risk = equity × base × confidence × regime × drawdown × streak`, with a hard cap of
1.5% on any single trade and 3% open at once.

### Top 5 TP systems

1. **Fixed 2R** — measured optimum, and the control every other model must beat.
2. **Trend-strength RR** (1.5 / 2.0 / 2.5 by trendScore) — adaptive, one input, testable immediately.
3. **Partial 1R + 2.5R runner** — targets this EA's actual leak, the 40% win rate at 2R.
4. **Liquidity target, guarded 1–3R** — the main hope for making FX work.
5. **Trailing after 1.5R at 2.5 ATR** — trend capture without the open-profit give-back that sank ride-the-trend.

### Configuration per asset class

| | Forex | Gold | Indices | Commodities |
| --- | --- | --- | --- | --- |
| Timeframes | H1 → M5 | M15 → M1 | H1 → M5 | H4 → M15 |
| Base risk | 0.5% | 0.5% | 0.4% | 0.4% |
| Min score | 70 | 60 | 70 | 75 |
| TP | liquidity, 1–3R | 2R, 2.5R when trend ≥ 2.5 | partial 1R / 2.5R | 3 × ATR |
| Break even | off | 4000 pts (≈ 2.5 ATR) | after first partial | off |
| Displacement | 2.0 | 2.5 | 2.5 | 2.5 |
| Trend gate | 1.5 | 2.5 | 2.5 | 2.0 |
| Daily stop | 2% | 2% | 1.5% | 1.5% |

Gold's row is measured. The other three are starting points: FX, indices and commodities were
flat to negative in testing, and the higher score thresholds reflect that they must prove
themselves before taking size.

### Implementation order

Each step is independently testable, and each should be measured against the step before it
rather than against the original EA.

| Step | Change | Success test |
| --- | --- | --- |
| 1 | Risk-percent sizing replaces fixed lots | Same trades, drawdown in % falls, R-multiple results unchanged |
| 2 | Confidence score computed and **logged only**, no behaviour change | Score correlates with outcome on ≥ 200 trades |
| 3 | Refuse below 60 | Trade count falls, PF rises, profit per trade rises |
| 4 | Score multiplier on size | Recovery factor rises |
| 5 | Drawdown floor and daily/weekly stops | Worst year improves; totals may fall |
| 6 | Trend-strength RR | PF and average trade beat fixed 2R |
| 7 | Partials | Win rate and drawdown improve; check spread cost |

**Step 2 is not optional.** Shipping a score that sizes trades before any evidence it predicts
anything is how a strategy acquires complexity without edge. Log it, collect 200 trades, regress
score against realised R, and only then let it touch position size.

### What this framework cannot fix

The optimisation found that **no configuration was profitable in all three tested years**, and
that the first year lost money in every one. Position sizing and take profit change how much
you make when the edge is present and how much you lose when it is not. They do not create
edge. A regime filter that keeps the EA flat during a year like 2023-24 would be worth more
than every model above combined, and nothing in this document attempts that.
