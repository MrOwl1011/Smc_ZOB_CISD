"""Parameter-sensitivity grid: one EA parameter changed at a time, H1->M5.

Every variant is scored with the SAME decision rule (trend filter 1.5 ATR,
1:1 target, stop on the block edge) and the SAME in-sample / out-of-sample
split as the main study, so only the parameter differs.
"""
import os, sys
import numpy as np
import pandas as pd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from smc_research import curve_stats, wilson, binom_p, annualised_sharpe  # noqa: E402

COMMON = r"C:\Users\Zaid\AppData\Roaming\MetaQuotes\Terminal\Common\Files"
THR = 1.5
OUT = sys.argv[1] if len(sys.argv) > 1 else r"C:\Users\Zaid\Desktop\SMC_Research"

VARIANTS = {
    "baseline (swing 4, disp 1.50, mitStop ON, zone Open-Last Ext)": "SMC_V_H1",
    "swing length 3":            "SMC_G_SW3",
    "swing length 5":            "SMC_G_SW5",
    "displacement 1.25 ATR":     "SMC_G_D125",
    "displacement 2.00 ATR":     "SMC_G_D200",
    "mitigation stops CISD OFF": "SMC_G_MITOFF",
    "zone mode Wick":            "SMC_G_ZONE0",
}


def load(folder):
    p = os.path.join(COMMON, folder, "signals.csv")
    if not os.path.isfile(p):
        return None
    d = pd.read_csv(p)
    d["time"] = pd.to_datetime(d["signal_time"], format="%Y.%m.%d %H:%M")
    d["outcome"] = d["outcome"].astype(str).str.upper()
    d = d[d["outcome"].isin(["SUCCESS", "FAILURE"])].copy()
    d["r"] = np.where(d["outcome"] == "SUCCESS", 1.0, -1.0)
    d["aligned"] = d["trend_aligned"].astype(str).str.lower().isin(["yes", "1", "true"])
    d = d[(d["trend_score"].abs() >= THR) & d["aligned"]].sort_values("time")
    cut = d["time"].quantile(0.67)
    d["sample"] = np.where(d["time"] < cut, "IS", "OOS")
    return d


def main():
    rows = []
    for label, folder in VARIANTS.items():
        d = load(folder)
        if d is None:
            rows.append(dict(variant=label, note="missing run"))
            continue
        for sample in ("ALL", "IS", "OOS"):
            s = d if sample == "ALL" else d[d["sample"] == sample]
            st = curve_stats(s["r"].values)
            if not st.get("trades"):
                continue
            lo, hi = wilson(st["wins"], st["trades"])
            rows.append(dict(variant=label, sample=sample, wr_lo=lo, wr_hi=hi,
                             p_value=binom_p(st["wins"], st["trades"]),
                             symbols=s["symbol"].nunique(),
                             pos_symbols=int((s.groupby("symbol")["r"].mean() > 0).sum()),
                             sharpe_ann=annualised_sharpe(s), **st))
    t = pd.DataFrame(rows)
    os.makedirs(OUT, exist_ok=True)
    t.to_csv(os.path.join(OUT, "parameter_grid.csv"), index=False)
    pd.set_option("display.width", 220, "display.max_columns", 40)
    cols = ["variant", "sample", "trades", "win_rate", "expectancy", "profit_factor", "total_r",
            "max_dd_r", "recovery", "sharpe_ann", "max_consec_loss", "p_value", "pos_symbols", "symbols"]
    print(t[[c for c in cols if c in t.columns]].to_string(index=False, float_format=lambda v: f"{v:.3f}"))
    print("\nwrote", os.path.join(OUT, "parameter_grid.csv"))


if __name__ == "__main__":
    main()
