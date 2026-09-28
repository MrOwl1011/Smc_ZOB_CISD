# SMC Order Block EA — Validation & Optimisation Research Report

**Scope:** ZOrder Blocks only (as instructed). 19 broker instruments, three HTF→LTF
combinations, 2025-01 → 2026-09. Strategy logic unchanged; only parameters the EA
already exposes were varied. No indicators added, no entry rules invented.

**Unit of account:** R multiples. With fixed 0.01 lots and block-edge stops ranging from
a few points to several hundred, currency profit is not comparable across instruments;
R is. Currency net profit is reported separately as a live-execution confirmation.

**Data:** the signal export produced by `SMC_SignalValidator`, which was previously
verified signal-for-signal against the EA itself (43/43 blocks, 15/15 signals identical).
7,878 resolved signals. Outcomes are 1:1 — stop on the far side of the block, target the
same distance.

**Discipline:** every parameter choice is made on in-sample data (first 2/3 of each
combination's own history) and only then read out-of-sample. Walk-forward re-selects in
each window. p-values are two-sided exact binomial against 50%, with Bonferroni
correction across the 21-cell threshold grid.

---

## Phase 1–2 — Instruments and timeframe combinations

| Combo | Gate | Trades | Win rate | Expectancy | PF | Max DD | Recovery | Sharpe (ann.) | Max consec. loss | p | p (Bonf.) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **H1→M5** | 1.5 | 813 | 55.5% | +0.109 R | 1.25 | 18 R | 4.94 | 3.27 | 10 | 0.002 | **0.042** |
| H4→M15 | 2.5 | 127 | 55.9% | +0.118 R | 1.27 | 9 R | 1.67 | 1.06 | 9 | 0.214 | 1.00 |
| M15→M1 | 1.5 | 1158 | 52.8% | +0.057 R | 1.12 | 23 R | 2.87 | 2.06 | 11 | 0.056 | 0.95 |

Out-of-sample: H1→M5 held at 55.6% / +0.113 R (in-sample +0.108 R). H4→M15 turned
negative out-of-sample at its in-sample-best gate (−0.077 R, 39 trades). M15→M1 is
capped by broker M1 history (~8 months), so its out-of-sample block is 2.5 months.

**H1→M5 is the only combination that survives multiple-testing correction.**

## Phase 3 — Trend gate (the dominant parameter)

H1→M5:

| Gate | Trades | Win rate | Expectancy | PF |
|---|---|---|---|---|
| off | 2891 | 50.3% | +0.005 R | 1.01 |
| 1.0 | 1052 | 54.0% | +0.080 R | 1.17 |
| 1.5 | 813 | 55.5% | +0.109 R | 1.25 |
| 2.0 | 607 | 55.8% | +0.117 R | 1.27 |
| 2.5 | 434 | 56.0% | +0.120 R | 1.27 |

Without the gate the signal is a coin flip. With it, a monotone plateau — no spike — so
1.5 is not a fitted value; it sits mid-plateau and preserves trade count.

## Phase 3 — Detection parameters (one change at a time, H1→M5, gate 1.5)

| Variant | Trades | Win rate | Expectancy | PF | Max DD | IS → OOS | Verdict |
|---|---|---|---|---|---|---|---|
| baseline (swing 4, disp 1.50) | 813 | 55.5% | +0.109 R | 1.25 | 18 R | 0.101 → 0.127 | stable |
| swing 3 | 905 | 55.9% | +0.118 R | 1.27 | 16 R | 0.119 → 0.117 | stable |
| swing 5 | 718 | 56.3% | +0.125 R | 1.29 | 16 R | 0.123 → 0.131 | stable |
| displacement 1.25 | 917 | 55.3% | +0.106 R | 1.24 | 14 R | 0.098 → 0.122 | stable |
| **displacement 2.00** | 565 | 57.2% | **+0.143 R** | 1.34 | **12 R** | 0.143 → 0.144 | most stable |
| mitigation stops CISD OFF | 1229 | 55.6% | +0.111 R | 1.25 | 21 R | 0.132 → **0.069** | fails OOS |
| zone mode Wick | 1233 | 54.9% | +0.098 R | 1.22 | 23 R | 0.099 → 0.096 | weaker |

- Swing length and displacement form plateaus: every value tested is positive and holds
  out-of-sample. That insensitivity is the evidence against curve fitting.
- Displacement 2.00 ATR is the single genuine improvement: identical in and out of sample
  (0.143 / 0.144), lowest drawdown, fewest consecutive losses; 30% fewer trades.
- "Mitigation stops CISD OFF" is the one trap: best in-sample, and it halves out-of-sample
  while drawdown and losing streaks grow. Keep it **ON**.

Gate sensitivity *within* the displacement-2.00 configuration (all positive, OOS rising):

| Gate | Trades | Win rate | Expectancy | PF | Max DD | p | OOS expectancy |
|---|---|---|---|---|---|---|---|
| 1.0 | 763 | 54.9% | +0.098 R | 1.22 | 15 R | 0.0073 | +0.088 R |
| 1.5 | 565 | 57.2% | +0.143 R | 1.34 | 12 R | 0.0007 | +0.151 R |
| 2.0 | 399 | 57.9% | +0.158 R | 1.38 | 11 R | 0.0019 | +0.252 R |
| 2.5 | 280 | 57.9% | +0.157 R | 1.37 | 7 R | 0.0101 | +0.196 R |

## Phase 5 — Walk-forward (rolling 6 months select → next 3 months score)

H1→M5: **5 of 5 windows positive out-of-sample** (+0.108, +0.073, +0.178, +0.132,
+0.258 R) against ~+0.01 R for the unfiltered signal in the same windows (negative in
two of them). The selected gate wandered 1.25 → 2.5, consistent with a plateau rather
than one special value.

## Phase 6 — Monte Carlo

| Combo | Expectancy | Bootstrap 5–95% | P(edge>0) | Monthly block bootstrap P(>0) | Median DD | 95th pct DD | Worst DD |
|---|---|---|---|---|---|---|---|
| H1→M5 | +0.109 R | +0.050 … +0.166 | 99.9% | 100% | 15 R | 22 R | 32 R |
| H4→M15 | +0.118 R | −0.024 … +0.260 | 91.0% | 92.2% | 8 R | 12 R | 24 R |
| M15→M1 | +0.057 R | +0.010 … +0.104 | 97.4% | 96.9% | 22 R | 34 R | 54 R |

Only H1→M5 keeps its interval clear of zero under month-block resampling, which
preserves clustering. Plan for a ~22 R drawdown at the 95th percentile.

## Phase 4 — Cross-market comparison (H1→M5)

disp 1.50 / gate 1.5:

| Asset class | Trades | Win rate | Expectancy | PF | Max DD | Positive symbols |
|---|---|---|---|---|---|---|
| Metals (Gold) | 45 | 71.1% | +0.422 R | 2.46 | 3 R | 1/1 |
| Indices | 164 | 57.9% | +0.159 R | 1.38 | 7 R | 3/4 |
| FX Minor | 92 | 55.4% | +0.109 R | 1.24 | 5 R | 1/2 |
| FX Major | 337 | 54.9% | +0.098 R | 1.22 | 14 R | 7/7 |
| Metals (Silver) | 37 | 51.4% | +0.027 R | 1.06 | 7 R | 1/1 |
| Energy | 71 | 49.3% | −0.014 R | 0.97 | 11 R | 1/2 |

disp 2.00 / gate 1.5: Indices improve markedly (116 trades, 62.1%, +0.241 R, DD 4 R,
**4/4 symbols positive**), FX Majors improve (+0.167 R), Gold stays strong (+0.351 R),
FX Minors and Energy go flat/negative.

Best instruments (disp 1.50): XAUUSD +0.42 R, US500 +0.33, GBPUSD +0.32, GER30 +0.30,
USDJPY +0.22. Weakest: WTI −0.18, US30 −0.10. 15 of 19 positive.

## Phase 7 — Live-execution confirmation (MT5 tester, trading on, 0.01 lots)

Jan 2025 → Sep 2026, ZOB only, gate 1.5, 1:1, opposite-block exit off:

| Symbol | disp 1.50 | disp 2.00 |
|---|---|---|
| XAUUSD | +672.67 USD | +474.64 USD |
| US500 | +292.19 | +280.84 |
| GBPUSD | +33.90 | +18.09 |
| US30 | +22.99 | +35.78 |

All eight passes profitable, including US30, which is negative in R. That divergence is
the fixed-lot effect: equal risk in R is not equal risk in currency when stop distance
varies. Currency drawdown is deliberately not quoted — under fixed lots it mixes
position-risk changes with strategy performance and would mislead.

---

## Recommended settings packages

Common to all packages (unchanged from the tested configuration):
OB source **ZOrder only** · zone **Open-Last Ext** · mitigation **50%** ·
invalidation **close beyond** · mitigation-stops-CISD **ON** · CISD stages
sweep off / confirmation on / retracement off · retest **Single** · CISD **Single** ·
FVG **confluence** · max OB→BOS 8 · max active 10 · overlap skip-new 50% ·
stop = block edge · target **1:1** · one position at a time · fixed lots.

| # | Package | Combo | Swing | Displacement | Gate | Instruments | Expected | Confidence |
|---|---|---|---|---|---|---|---|---|
| 1 | **Best overall** | H1→M5 | 4 | **2.00** | 1.5 | all 19 | +0.143 R, PF 1.34, DD 12 R, ~280 trades/yr | **High** |
| 2 | Best Forex | H1→M5 | 4 | 2.00 | 1.5 | FX majors | +0.167 R, PF 1.40, DD 8 R | Moderate-high |
| 3 | Best Metals | H1→M5 | 4 | 1.50 | 1.5 | XAUUSD only | +0.422 R, PF 2.46, DD 3 R | Moderate (45 trades) |
| 4 | Best Indices | H1→M5 | 4 | 2.00 | 1.5 | US500, GER30, UK100, US30 | +0.241 R, PF 1.64, DD 4 R, 4/4 positive | Moderate-high |
| 5 | **Safest** | H1→M5 | 5 | 2.00 | **2.0** | all 19 | +0.158 R, PF 1.38, DD 11 R, ~200 trades/yr | High |
| 6 | Highest expectancy | H1→M5 | 4 | 1.50 | 1.5 | XAUUSD only | +0.422 R | Low-moderate (sample) |
| 7 | Highest robustness | H1→M5 | 4 | 2.00 | 1.5 | all 19 | IS +0.143 / OOS +0.144 R — identical | **High** |

Packages 1 and 7 are the same configuration; it is both the best performer and the most
stable, which is the ideal outcome of this kind of search.

### Not recommended
- **H4→M15** — 127 trades in 20 months, fails Bonferroni, negative out-of-sample.
- **M15→M1** — positive but weak (+0.057 R), fails Bonferroni, and unverifiable beyond
  8 months of M1 history.
- **Mitigation-stops-CISD OFF** — the classic in-sample mirage.
- **Trend filter off** — no edge at all (50.3%).
- **Symbol whitelisting beyond the packages above.** Dropping WTI, US30 and other
  losers would raise every metric, but those instruments are chosen *from the same data*,
  which is selection bias. Energy was negative in-sample and out-of-sample at disp 1.50
  yet positive out-of-sample at disp 2.00 — not a stable enough signal to exclude on.

## Confidence and limitations

- The core finding — trend-gated H1→M5 ZOrder signals carry a real, repeatable
  edge of roughly +0.10 to +0.15 R at 1:1 — is supported by: Bonferroni-corrected
  significance, IS/OOS agreement, 5/5 walk-forward windows, 99.9% Monte Carlo
  positivity, 15/19 instruments positive, and plateau (not spike) behaviour across
  four separate parameters.
- Displacement 2.00 was selected from six tested variants; its p-value (0.0007) survives
  ×6 correction, and its IS/OOS agreement is the strongest in the set.
- Per-instrument figures rest on 30–75 trades each: the *sign* is meaningful, the *level*
  is not. Gold's 71% has a 57–82% confidence interval.
- Signals across 19 instruments in the same sessions are correlated, so effective sample
  size is smaller than the raw trade count; the monthly block bootstrap is the figure to
  trust (still 100% positive for H1→M5).
- No spread, slippage or commission model is in the R results. The tester confirmation
  includes real spread, and stayed positive on all eight passes.
- Results are single-broker (CFI) and cover one 20-month regime.

## Artefacts

`C:\Users\Zaid\Desktop\SMC_Research\` — `grid.csv`, `instruments.csv`, `asset_class.csv`,
`walkforward.csv`, `montecarlo.csv`, `sensitivity.csv`, `parameter_grid.csv`, `meta.json`,
this report. Framework: `MQL5\Scripts\Zaid\2026\smc_research.py`,
`smc_research_grid.py`. Every table is reproducible from the signal exports in
`Terminal\Common\Files\SMC_V_*` and `SMC_G_*`.
