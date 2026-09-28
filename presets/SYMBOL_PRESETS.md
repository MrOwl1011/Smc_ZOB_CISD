# Per-symbol presets

Built from the "Symbol x timeframe accuracy" table of the trend-filtered signal
validation report: every cell that scored above 59%.

Settings are the study's own profile in every file, so only the two timeframes differ:
series Order Block, Open-Last Ext zones, swing 4, displacement 1.50 ATR, single retest,
single CISD, mitigation stops the search, trend gate 1.5 ATR over 20 bars. Trading is off.

Attach each one to its own symbol. The accuracy quoted is that market alone.

## Usable sample (30 signals or more)

| Preset | Symbol | Timeframes | Reported accuracy | Signals |
|---|---|---|---|---|
| `SMC_SYM_XAUUSD_H1M5` | XAUUSD_ | H1 -> M5 | 71.1% | 45 |
| `SMC_SYM_GBPUSD_H1M5` | GBPUSD_ | H1 -> M5 | 65.9% | 44 |
| `SMC_SYM_GER30_H1M5` | GER30_SPOT | H1 -> M5 | 65.0% | 40 |
| `SMC_SYM_US500_H1M5` | US500_SPOT | H1 -> M5 | 65.0% | 40 |
| `SMC_SYM_USDJPY_H1M5` | USDJPY_ | H1 -> M5 | 61.2% | 49 |
| `SMC_SYM_CADJPY_H1M5` | CADJPY_ | H1 -> M5 | 60.0% | 50 |
| `SMC_SYM_US30_M15M1` | US30_SPOT | M15 -> M1 | 60.7% | 61 |
| `SMC_SYM_CADJPY_M15M1` | CADJPY_ | M15 -> M1 | 59.2% | 71 |

## Below the report's own noise threshold

The report marks cells under 30 signals as noise. These are included because they
cleared 59%, but the percentage is not meaningful at this sample size.

| Preset | Symbol | Timeframes | Reported accuracy | Signals |
|---|---|---|---|---|
| `SMC_SYM_EURUSD_H4M15` | EURUSD_ | H4 -> M15 | 75.0% | 12 |
| `SMC_SYM_NZDUSD_H4M15` | NZDUSD_ | H4 -> M15 | 75.0% | 16 |
| `SMC_SYM_US500_H4M15` | US500_SPOT | H4 -> M15 | 72.7% | 11 |
| `SMC_SYM_WTI_H4M15` | WTI | H4 -> M15 | 66.7% | 15 |
| `SMC_SYM_BRENT_H4M15` | BRENT | H4 -> M15 | 65.0% | 20 |
| `SMC_SYM_US100_H4M15` | US100_Spot | H4 -> M15 | 60.0% | 20 |
| `SMC_SYM_US2000_H4M15` | US2000_SPOT | H4 -> M15 | 60.0% | 10 |

## Read this before trading them

These cells were picked by looking at results, which is selection bias: the report's own
conclusion is that no symbol clears a Bonferroni-corrected threshold and the spread across
markets is consistent with noise. A high cell here is a candidate to watch, not a proven edge.
Position size stays fixed, so risk per trade varies with block height.
