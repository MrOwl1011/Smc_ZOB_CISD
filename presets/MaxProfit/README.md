# MaxProfit presets

Gold (XAUUSD), **M15 Order Blocks with M1 CISD confirmation**, trading **enabled**,
0.01 lots. Picked from a 72-configuration sweep run on 2026-01-01 to 2026-10-01 with
this broker's spread.

| Preset | Swing | Displacement | Trend gate | Target | Measured |
| --- | --- | --- | --- | --- | --- |
| `MaxProfit_Gold_Top` | 3 | 2.00 ATR | 2.0 | 2R | +725.80 USD, 66 trades |
| `MaxProfit_Gold_Second` | 4 | 2.00 ATR | 2.0 | 2R | +704.29 USD, 59 trades |
| `MaxProfit_Gold_Fewer` | 3 | 2.50 ATR | 2.0 | 2R | +504.19 USD, 35 trades |
| `MaxProfit_Gold_1R` | 3 | 2.00 ATR | 2.0 | 1R | +445.57 USD, 66 trades |

## What the sweep showed

Three effects held across all 72 runs, which matters more than any single figure.

1. **Wide targets beat tight ones.** 2R averaged +279 USD, 1R +228, and 0.5R only +8.
   Every one of the twelve losing configurations used a 0.5R target.
2. **The trend gate pays.** At 2.0 the average was +279 USD against +100 at 1.5.
3. **Displacement 2.00 beat 2.50** on average, because the stricter filter trades too
   little to make up for it.

## Read before using them

**Selected by looking at results.** 72 configurations were measured and the best kept,
so expect less than the headline number. Picking the maximum of 72 draws overstates
what repeats.

**No out-of-sample test.** These have not been fitted on one period and scored on
another. That test is still outstanding.

**Profit partly reflects wider stops.** A 2R target on a block-height stop produces
bigger wins and bigger losses in currency at the same 0.01 lot, so this is not the
same ranking as risk-adjusted quality.

**Trading is ON in these files.** Loading one and pressing OK arms live execution on
that chart.
