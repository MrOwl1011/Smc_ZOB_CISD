# Recommended settings packages

Each package ships two files:

* `<name>.set` - MT5 input preset. Load it in the EA properties dialog (Load button)
  or in the Strategy Tester Inputs tab. It carries every input, including the trend gate.
* `<name>.cfg` - runtime profile for the on-chart panel. Type the package name in the
  panel's CONFIGURATION field and press Load.

Trading is OFF in every package: switch it on from the panel when you are ready.
Opposite-block exit is OFF because it was not part of the tested rule set.

| Package | Swing | Displacement | Trend gate | Instruments |
|---|---|---|---|---|
| SMC_1_BestOverall | 4 | 2.0 ATR | 1.5 ATR | all 19 instruments |
| SMC_2_Forex | 4 | 2.0 ATR | 1.5 ATR | FX majors: EURUSD GBPUSD USDJPY USDCHF AUDUSD USDCAD NZDUSD |
| SMC_3_Metals | 4 | 1.5 ATR | 1.5 ATR | XAUUSD only (silver showed no edge) |
| SMC_4_Indices | 4 | 2.0 ATR | 1.5 ATR | US500 GER30 UK100 US30 |
| SMC_5_Safest | 5 | 2.0 ATR | 2.0 ATR | all 19 instruments |
| SMC_6_HighestExpectancy | 4 | 1.5 ATR | 1.5 ATR | XAUUSD only |
| SMC_7_HighestRobustness | 4 | 2.0 ATR | 1.5 ATR | all 19 instruments |

## Notes per package

* **SMC_1_BestOverall** - Best overall AND highest robustness. IS +0.143 R / OOS +0.144 R, PF 1.34, DD 12 R, 565 trades.
* **SMC_2_Forex** - Same parameters as package 1, restricted to FX majors: +0.167 R, PF 1.40, DD 8 R.
* **SMC_3_Metals** - Gold: +0.422 R, PF 2.46, DD 3 R on 45 trades. Strong sign, uncertain level.
* **SMC_4_Indices** - Strongest asset class at disp 2.00: +0.241 R, PF 1.64, DD 4 R, 4 of 4 symbols positive.
* **SMC_5_Safest** - Fewest trades, smallest drawdown: +0.158 R, PF 1.38, DD 11 R, ~200 trades/year.
* **SMC_6_HighestExpectancy** - Highest expectancy found (+0.422 R) but it rests on one instrument and 45 trades.
* **SMC_7_HighestRobustness** - Identical to package 1 - the best performer is also the most stable configuration.

Packages 1, 2, 4 and 7 share the same parameters and differ only in which
instruments you attach them to; packages 3 and 6 are likewise identical.
Four distinct parameter sets in total.
