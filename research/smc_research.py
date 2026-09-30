"""SMC Order Block EA - research framework (phases 1-7).

Reads the signal exports produced by SMC_SignalValidator (one folder per
HTF->LTF combination) and evaluates the EA's own, already-exposed parameters.
No strategy logic is invented here: outcomes come from the exported signals,
which were verified signal-for-signal against the EA.

Outputs: a markdown report plus the per-table CSVs.
"""
import os, sys, math, json, random
import numpy as np
import pandas as pd

COMMON = r"C:\Users\Zaid\AppData\Roaming\MetaQuotes\Terminal\Common\Files"
RUNS = {  # label -> folder
    "H4->M15": "SMC_V_H4M15",
    "H1->M5":  "SMC_V_H1",
    "M15->M1": "SMC_V_M15M1",
}
OUT = sys.argv[1] if len(sys.argv) > 1 else r"C:\Users\Zaid\Desktop\SMC_Research"
SPLITS = {}                               # per-combo IS/OOS cut, filled in load()
THRESHOLDS = [0.0, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5]
RNG = np.random.default_rng(20260928)

# ----------------------------------------------------------------- statistics
def wilson(k, n, z=1.96):
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0.0, c - h), min(1.0, c + h))


def binom_p(k, n, p0=0.5):
    """two-sided exact binomial p-value"""
    if n == 0:
        return 1.0
    from math import lgamma, log, exp
    def logpmf(i):
        return (lgamma(n + 1) - lgamma(i + 1) - lgamma(n - i + 1)
                + i * log(p0) + (n - i) * log(1 - p0))
    lo = logpmf(k)
    tot = 0.0
    for i in range(n + 1):
        li = logpmf(i)
        if li <= lo + 1e-12:
            tot += exp(li)
    return min(1.0, tot)


def curve_stats(r):
    """equity-curve metrics on a series of R multiples, in trade order"""
    r = np.asarray(r, dtype=float)
    n = len(r)
    if n == 0:
        return dict(trades=0)
    eq = np.cumsum(r)
    peak = np.maximum.accumulate(eq)
    dd = peak - eq
    wins = r[r > 0]
    loss = r[r < 0]
    gp, gl = wins.sum(), -loss.sum()
    # max consecutive losses
    mc = c = 0
    for v in r:
        c = c + 1 if v < 0 else 0
        mc = max(mc, c)
    sd = r.std(ddof=1) if n > 1 else 0.0
    return dict(
        trades=n,
        wins=int((r > 0).sum()),
        win_rate=float((r > 0).mean()),
        total_r=float(eq[-1]),
        expectancy=float(r.mean()),
        profit_factor=float(gp / gl) if gl > 0 else float("inf"),
        max_dd_r=float(dd.max()),
        recovery=float(eq[-1] / dd.max()) if dd.max() > 0 else float("inf"),
        sharpe_trade=float(r.mean() / sd) if sd > 0 else 0.0,
        max_consec_loss=int(mc),
    )


def annualised_sharpe(df):
    """Sharpe of the monthly R series (robust to trade frequency)"""
    if df.empty:
        return 0.0
    m = df.set_index("time").resample("ME")["r"].sum()
    if len(m) < 3 or m.std(ddof=1) == 0:
        return 0.0
    return float(m.mean() / m.std(ddof=1) * math.sqrt(12))


# ----------------------------------------------------------------- load
def load():
    frames = []
    for label, folder in RUNS.items():
        p = os.path.join(COMMON, folder, "signals.csv")
        d = pd.read_csv(p)
        d["combo"] = label
        frames.append(d)
    df = pd.concat(frames, ignore_index=True)
    df["time"] = pd.to_datetime(df["signal_time"], format="%Y.%m.%d %H:%M")
    df = df.sort_values(["combo", "time"]).reset_index(drop=True)
    #--- the EA trades 1:1: realized_r is +1 / -1 (ambiguous / unresolved dropped)
    df["outcome"] = df["outcome"].astype(str).str.upper()
    df = df[df["outcome"].isin(["SUCCESS", "FAILURE"])].copy()
    df["r"] = np.where(df["outcome"] == "SUCCESS", 1.0, -1.0)
    df["aligned"] = df["trend_aligned"].astype(str).str.lower().isin(["yes", "1", "true"])
    df["abs_score"] = df["trend_score"].abs()
    #--- per combo: the first 2/3 of ITS OWN history is in-sample. M1 history is
    #--- much shorter than H1/H4 history, so one global date would leave M15->M1
    #--- with an empty in-sample block.
    df["sample"] = "IS"
    global SPLITS
    SPLITS = {}
    for combo, g in df.groupby("combo"):
        cut = g["time"].quantile(0.67)
        SPLITS[combo] = str(cut)
        df.loc[(df["combo"] == combo) & (df["time"] >= cut), "sample"] = "OOS"
    return df


def apply_filter(df, thr):
    """the EA's trend gate: |score| >= thr and the sign matches (thr 0 = filter off)"""
    if thr <= 0:
        return df
    return df[(df["abs_score"] >= thr) & df["aligned"]]


# ----------------------------------------------------------------- phases
def table_instruments(df, thr_by_combo):
    rows = []
    for combo, g in df.groupby("combo"):
        d = apply_filter(g, thr_by_combo[combo])
        for (sym, cls), s in d.groupby(["symbol", "asset_class"]):
            st = curve_stats(s["r"].values)
            lo, hi = wilson(st["wins"], st["trades"])
            rows.append(dict(combo=combo, symbol=sym, asset_class=cls, thr=thr_by_combo[combo],
                             wr_lo=lo, wr_hi=hi, sharpe_ann=annualised_sharpe(s), **st))
    return pd.DataFrame(rows)


def table_grid(df):
    rows = []
    for combo, g in df.groupby("combo"):
        for thr in THRESHOLDS:
            d = apply_filter(g, thr)
            for sample in ("ALL", "IS", "OOS"):
                s = d if sample == "ALL" else d[d["sample"] == sample]
                st = curve_stats(s["r"].values)
                if st["trades"] == 0:
                    continue
                lo, hi = wilson(st["wins"], st["trades"])
                rows.append(dict(combo=combo, thr=thr, sample=sample, wr_lo=lo, wr_hi=hi,
                                 p_value=binom_p(st["wins"], st["trades"]),
                                 symbols=s["symbol"].nunique(),
                                 pos_symbols=int((s.groupby("symbol")["r"].mean() > 0).sum()),
                                 sharpe_ann=annualised_sharpe(s), **st))
    g = pd.DataFrame(rows)
    n_tests = len(g[g["sample"] == "IS"])
    g["p_bonferroni"] = (g["p_value"] * n_tests).clip(upper=1.0)
    return g


def walk_forward(df, is_months=6, oos_months=3):
    """rolling: pick the threshold on in-sample, score it on the next window only"""
    rows = []
    for combo, g in df.groupby("combo"):
        t0, t1 = g["time"].min(), g["time"].max()
        start = pd.Timestamp(t0.year, t0.month, 1)
        while True:
            is_a = start
            is_b = is_a + pd.DateOffset(months=is_months)
            oos_b = is_b + pd.DateOffset(months=oos_months)
            if is_b > t1:
                break
            tr = g[(g["time"] >= is_a) & (g["time"] < is_b)]
            te = g[(g["time"] >= is_b) & (g["time"] < oos_b)]
            if len(tr) < 40 or len(te) < 15:
                start = start + pd.DateOffset(months=oos_months)
                continue
            best, best_e = None, -9
            for thr in THRESHOLDS:
                s = apply_filter(tr, thr)
                if len(s) < 30:
                    continue
                e = s["r"].mean()
                if e > best_e:
                    best, best_e = thr, e
            if best is None:
                start = start + pd.DateOffset(months=oos_months)
                continue
            sel = apply_filter(te, best)
            base = te
            rows.append(dict(combo=combo, is_from=is_a.date(), oos_from=is_b.date(), oos_to=oos_b.date(),
                             chosen_thr=best, is_trades=len(apply_filter(tr, best)), is_exp=best_e,
                             oos_trades=len(sel), oos_exp=float(sel["r"].mean()) if len(sel) else np.nan,
                             oos_wr=float((sel["r"] > 0).mean()) if len(sel) else np.nan,
                             unfiltered_exp=float(base["r"].mean())))
            start = start + pd.DateOffset(months=oos_months)
    return pd.DataFrame(rows)


def monte_carlo(df, thr_by_combo, n=5000):
    rows = []
    for combo, g in df.groupby("combo"):
        d = apply_filter(g, thr_by_combo[combo])
        r = d["r"].values
        if len(r) < 30:
            continue
        #--- 1. bootstrap trades: expectancy CI
        boot = np.array([RNG.choice(r, len(r), replace=True).mean() for _ in range(n)])
        #--- 2. block bootstrap by month: keeps clustering
        months = d["time"].dt.to_period("M").astype(str).values
        uniq = list(pd.unique(months))
        blocks = {m: r[months == m] for m in uniq}
        bexp = []
        for _ in range(n // 5):
            pick = RNG.choice(uniq, len(uniq), replace=True)
            v = np.concatenate([blocks[m] for m in pick])
            bexp.append(v.mean())
        bexp = np.array(bexp)
        #--- 3. shuffled trade order: drawdown distribution
        dds = []
        for _ in range(n // 5):
            s = RNG.permutation(r)
            eq = np.cumsum(s)
            dds.append(float((np.maximum.accumulate(eq) - eq).max()))
        dds = np.array(dds)
        rows.append(dict(combo=combo, thr=thr_by_combo[combo], trades=len(r),
                         exp=float(r.mean()),
                         exp_p05=float(np.percentile(boot, 5)), exp_p95=float(np.percentile(boot, 95)),
                         p_exp_positive=float((boot > 0).mean()),
                         block_exp_p05=float(np.percentile(bexp, 5)),
                         block_p_positive=float((bexp > 0).mean()),
                         dd_median_r=float(np.median(dds)), dd_p95_r=float(np.percentile(dds, 95)),
                         dd_worst_r=float(dds.max())))
    return pd.DataFrame(rows)


def sensitivity(df, combo, thr):
    """neighbourhood of the chosen threshold: a plateau, or a spike?"""
    g = df[df["combo"] == combo]
    rows = []
    for t in THRESHOLDS:
        s = apply_filter(g, t)
        st = curve_stats(s["r"].values)
        if st["trades"]:
            rows.append(dict(thr=t, trades=st["trades"], win_rate=st["win_rate"],
                             expectancy=st["expectancy"], profit_factor=st["profit_factor"]))
    return pd.DataFrame(rows)


# ----------------------------------------------------------------- main
def main():
    os.makedirs(OUT, exist_ok=True)
    df = load()
    grid = table_grid(df)
    grid.to_csv(os.path.join(OUT, "grid.csv"), index=False)

    #--- choose per combo on IS only, then read OOS (never the other way round)
    chosen = {}
    for combo in RUNS:
        g = grid[(grid["combo"] == combo) & (grid["sample"] == "IS") & (grid["trades"] >= 80)]
        if g.empty:
            chosen[combo] = 1.5
            continue
        chosen[combo] = float(g.sort_values("expectancy", ascending=False).iloc[0]["thr"])

    inst = table_instruments(df, chosen)
    inst.to_csv(os.path.join(OUT, "instruments.csv"), index=False)
    wf = walk_forward(df)
    wf.to_csv(os.path.join(OUT, "walkforward.csv"), index=False)
    mc = monte_carlo(df, chosen)
    mc.to_csv(os.path.join(OUT, "montecarlo.csv"), index=False)
    sens = pd.concat([sensitivity(df, c, chosen[c]).assign(combo=c) for c in RUNS], ignore_index=True)
    sens.to_csv(os.path.join(OUT, "sensitivity.csv"), index=False)

    #--- asset-class view at the chosen thresholds
    rows = []
    for combo, g in df.groupby("combo"):
        d = apply_filter(g, chosen[combo])
        for cls, s in d.groupby("asset_class"):
            st = curve_stats(s["r"].values)
            lo, hi = wilson(st["wins"], st["trades"])
            rows.append(dict(combo=combo, asset_class=cls, thr=chosen[combo], wr_lo=lo, wr_hi=hi,
                             p_value=binom_p(st["wins"], st["trades"]),
                             symbols=s["symbol"].nunique(),
                             pos_symbols=int((s.groupby("symbol")["r"].mean() > 0).sum()),
                             sharpe_ann=annualised_sharpe(s), **st))
    cls_tab = pd.DataFrame(rows)
    cls_tab.to_csv(os.path.join(OUT, "asset_class.csv"), index=False)

    meta = dict(chosen_thresholds=chosen, is_oos_split=SPLITS,
                signals=len(df), symbols=sorted(df["symbol"].unique().tolist()),
                combos=list(RUNS.keys()), thresholds=THRESHOLDS)
    with open(os.path.join(OUT, "meta.json"), "w") as f:
        json.dump(meta, f, indent=2)

    pd.set_option("display.width", 200, "display.max_columns", 50, "display.max_rows", 200)
    print("== chosen (IS only):", chosen)
    print("\n== GRID (ALL / IS / OOS)\n", grid[["combo", "thr", "sample", "trades", "win_rate", "expectancy",
                                                "profit_factor", "max_dd_r", "recovery", "sharpe_ann",
                                                "max_consec_loss", "p_value", "p_bonferroni", "pos_symbols",
                                                "symbols"]].to_string(index=False, float_format=lambda v: f"{v:.3f}"))
    print("\n== ASSET CLASS\n", cls_tab.to_string(index=False, float_format=lambda v: f"{v:.3f}"))
    print("\n== WALK FORWARD\n", wf.to_string(index=False, float_format=lambda v: f"{v:.3f}"))
    print("\n== MONTE CARLO\n", mc.to_string(index=False, float_format=lambda v: f"{v:.3f}"))
    print("\n== SENSITIVITY\n", sens.to_string(index=False, float_format=lambda v: f"{v:.3f}"))
    print("\n== INSTRUMENTS\n", inst.sort_values(["combo", "expectancy"], ascending=[True, False])
          [["combo", "symbol", "asset_class", "trades", "win_rate", "expectancy", "profit_factor",
            "max_dd_r", "total_r"]].to_string(index=False, float_format=lambda v: f"{v:.3f}"))
    print("\nwrote", OUT)


if __name__ == "__main__":
    main()
