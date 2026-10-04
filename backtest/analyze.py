"""Sweep analysis for SMCOrderBlockStrategy: metrics per set and period, the recommended set (picked on
in-sample data only), anchored walk-forward, Monte Carlo.

    python backtest/analyze.py --symbol MNQ --sweeps work/sweep/mnq-A,work/sweep/mnq-B --out results/mnq

Brief: profit factor > 1 and net profit / max drawdown >= 3, then the highest win rate.
Selection never sees out-of-sample trades; the walk-forward re-runs the same rule at every cut-off
on the data before it and trades the next six months with whatever it picked.
"""
import argparse, bisect, csv, datetime as dt, json, math, os, random
from collections import defaultdict

START, IS_END, END = "2021-09-01", "2025-01-01", "2026-10-03"
WF_CUTS = ["2023-07-01", "2024-01-01", "2024-07-01", "2025-01-01", "2025-07-01", "2026-01-01", "2026-07-01"]
NDD_MIN, PF_MIN, MIN_LOSERS = 3.0, 1.0, 10
TRADES_PER_YEAR_MIN = 12                     # deployability floor: about one trade a month
DEFAULTS = {"TimeframePair": "H1_M5", "TargetRR": "1.0", "TrendFilter": "True", "FVGMode": "Confluence", "CISDSweep": "False",
            "ConnCISDMode": "Single", "ConnRetestMode": "Single", "EnableBull": "True", "EnableBear": "True"}
MC_N, MC_BLOCK, MC_SEED = 5000, 5, 20261004


def years(a, b): return (dt.date.fromisoformat(b) - dt.date.fromisoformat(a)).days / 365.25


def load(sweeps):
    sets, trades = {}, defaultdict(list)
    for d in sweeps:
        idmap = {}
        with open(os.path.join(d, "combos.csv")) as f:
            for r in csv.DictReader(f):
                key = r["key"]
                params = dict(kv.split("=", 1) for kv in key.split("|"))
                params = {k: v for k, v in params.items() if v != ""}
                k2 = canon(params)
                idmap[r["id"]] = k2
                sets[k2] = params
        with open(os.path.join(d, "trades.csv")) as f:
            seen = set()
            for r in csv.DictReader(f):
                k2 = idmap.get(r["id"])
                if k2 is None: continue
                trades[(d, k2)].append(r)
        # a set swept in several folders keeps one trade list (the last folder's)
        for k2 in set(idmap.values()):
            trades[k2] = [{"entry": t["entry_time"], "exit": t["exit_time"], "dir": t["dir"], "pnl": float(t["profit"]),
                           "why": t["exit_name"], "e": float(t["entry"]), "x": float(t["exit"])} for t in trades.pop((d, k2), [])]
    return sets, {k: v for k, v in trades.items() if isinstance(k, str)}


STRAT_DEFAULTS = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "strategy_defaults.json")))


def same(a, b):
    try: return float(a) == float(b)
    except ValueError: return a.lower() == b.lower()


def canon(p):
    """Stage-A inputs always appear; any other input only when it differs from the strategy default."""
    q = dict(DEFAULTS); q.update(p)
    q = {k: v for k, v in q.items() if k in DEFAULTS or not same(v, STRAT_DEFAULTS.get(k, ""))}
    return "|".join(f"{k}={q[k]}" for k in sorted(q))


def label(p):
    q = dict(DEFAULTS); q.update(p)
    d = "Both" if q["EnableBull"] == "True" and q["EnableBear"] == "True" else ("Long" if q["EnableBull"] == "True" else "Short")
    s = f"{q['TimeframePair'].replace('_', '>')} {d} RR{q['TargetRR']} trend{'On' if q['TrendFilter'] == 'True' else 'Off'} FVG{q['FVGMode'][:4]} " \
        f"sweep{'On' if q['CISDSweep'] == 'True' else 'Off'} {q['ConnCISDMode']}"
    extra = [f"{k}={v}" for k, v in sorted(q.items()) if k not in DEFAULTS]
    return s + (" " + " ".join(extra) if extra else "")


def metrics(tr, a=START, b=END):
    t = [x for x in tr if a <= x["entry"] < b]
    n = len(t); wins = sum(1 for x in t if x["pnl"] > 0)
    gp = sum(x["pnl"] for x in t if x["pnl"] > 0); gl = -sum(x["pnl"] for x in t if x["pnl"] <= 0)
    c = pk = dd = 0.0
    for x in sorted(t, key=lambda x: x["exit"]):
        c += x["pnl"]; pk = max(pk, c); dd = max(dd, pk - c)
    net = gp - gl
    return {"trades": n, "wins": wins, "losers": n - wins, "win": wins / n if n else 0.0, "net": net, "gp": gp, "gl": gl,
            "pf": gp / gl if gl > 0 else (99.0 if gp > 0 else 0.0), "dd": dd, "ndd": net / dd if dd > 0 else (99.0 if net > 0 else 0.0),
            "avg": net / n if n else 0.0, "avg_win": gp / wins if wins else 0.0, "avg_loss": -gl / (n - wins) if n - wins else 0.0}


def passes(m, a, b):
    return (m["pf"] > PF_MIN and m["ndd"] >= NDD_MIN and m["losers"] >= MIN_LOSERS
            and m["trades"] >= TRADES_PER_YEAR_MIN * years(a, b))


def rank_key(m): return (round(m["win"], 4), m["ndd"], m["net"])


def ndefaults(key):
    return sum(1 for k, v in full_params(key).items() if not same(v, STRAT_DEFAULTS.get(k, v)))


def pick(table, a, b):
    """The rule: among sets passing the brief on [a, b), highest win rate (then net/DD). None if nothing passes."""
    best = None
    for k, tr in table.items():
        m = metrics(tr, a, b)
        # identical results (e.g. FVG off vs confluence) resolve to the set with fewer non-default inputs
        if passes(m, a, b) and (best is None or (rank_key(m), -ndefaults(k)) > (rank_key(best[1]), -ndefaults(best[0]))): best = (k, m)
    return best


def daily(tr, a, b):
    days = defaultdict(float)
    for x in tr:
        if a <= x["entry"] < b: days[x["exit"][:10]] += x["pnl"]
    d0, d1 = dt.date.fromisoformat(a), dt.date.fromisoformat(b)
    out = []
    while d0 < d1:
        if d0.weekday() < 5: out.append(days.get(d0.isoformat(), 0.0))
        d0 += dt.timedelta(days=1)
    return out


def path_stats(seq):
    c = pk = dd = 0.0
    for v in seq:
        c += v; pk = max(pk, c); dd = max(dd, pk - c)
    return c, dd


def pct(v, p): return v[min(len(v) - 1, int(round(p * (len(v) - 1))))]


def monte_carlo(tr, a, b, horizon_days=252):
    """Day-block bootstrap of the daily P&L (5-day blocks) over the full period and over a one-year
    horizon, and trade-order shuffles of the closed trades."""
    rng = random.Random(MC_SEED)
    seq = daily(tr, a, b); n = len(seq)
    def draw(length):
        idx = []
        while len(idx) < length:
            s = rng.randrange(n); idx.extend((s + j) % n for j in range(MC_BLOCK))
        return [seq[i] for i in idx[:length]]
    out = {}
    for name, length in (("full", n), ("year", horizon_days)):
        nets, dds, ndd3 = [], [], 0
        for _ in range(MC_N):
            net, dd = path_stats(draw(length)); nets.append(net); dds.append(dd)
            if dd > 0 and net >= 3 * dd: ndd3 += 1
        nets.sort(); dds.sort()
        out[name] = {"days": length, "net_p05": pct(nets, .05), "net_p50": pct(nets, .5), "net_p95": pct(nets, .95),
                     "p_loss": sum(1 for v in nets if v <= 0) / MC_N, "dd_p50": pct(dds, .5), "dd_p95": pct(dds, .95),
                     "dd_p99": pct(dds, .99), "p_ndd3": ndd3 / MC_N,
                     "p_dd_gt": {str(x): sum(1 for v in dds if v > x) / MC_N for x in (1000, 1500, 2000, 2500, 3000, 5000)}}
    pn = [x["pnl"] for x in sorted(tr, key=lambda x: x["exit"]) if a <= x["entry"] < b]
    dds = []
    for _ in range(MC_N):
        rng.shuffle(pn); dds.append(path_stats(pn)[1])
    dds.sort()
    out["shuffle"] = {"dd_p50": pct(dds, .5), "dd_p95": pct(dds, .95), "dd_p99": pct(dds, .99), "obs_dd": metrics(tr, a, b)["dd"]}
    return out


def walk_forward(table):
    steps, stitched = [], []
    cuts = WF_CUTS + [END]
    for i in range(len(cuts) - 1):
        c, nxt = cuts[i], cuts[i + 1]
        p = pick(table, START, c)
        if p is None:
            steps.append({"cut": c, "to": nxt, "set": None, "is": None, "oos": None}); continue
        k, mis = p
        seg = [x for x in table[k] if c <= x["entry"] < nxt]
        stitched += seg
        steps.append({"cut": c, "to": nxt, "set": k, "label": label(dict(kv.split("=", 1) for kv in k.split("|"))), "is": mis,
                      "oos": metrics(table[k], c, nxt)})
    return {"steps": steps, "stitched": metrics(stitched, WF_CUTS[0], END), "trades": stitched}


def equity(tr, a=START, b=END):
    c, pts = 0.0, [[a, 0.0]]
    for x in sorted((x for x in tr if a <= x["entry"] < b), key=lambda x: x["exit"]):
        c += x["pnl"]; pts.append([x["exit"], round(c, 2)])
    return pts


def yearly(tr):
    out = []
    for y in range(int(START[:4]), int(END[:4]) + 1):
        a, b = max(START, f"{y}-01-01"), min(END, f"{y + 1}-01-01")
        if a < b: m = metrics(tr, a, b); m["year"] = y; out.append(m)
    return out


def full_params(key):
    p = dict(STRAT_DEFAULTS); p.update(dict(kv.split("=", 1) for kv in key.split("|")))
    return p


def neighbours(sets, key):
    """Sets that differ from `key` in exactly one input (the one-at-a-time sensitivity table); the
    paired inputs (CISD/retest mode, long/short switches) count as one."""
    p = full_params(key)
    out = defaultdict(list)
    for k in sets:
        if k == key: continue
        q = full_params(k)
        diff = sorted(x for x in set(p) | set(q) if not same(p.get(x, ""), q.get(x, "")))
        if len(diff) == 1: out[diff[0]].append(k)
        elif diff == ["ConnCISDMode", "ConnRetestMode"]: out["ConnMode"].append(k)
        elif diff == ["EnableBear", "EnableBull"]: out["Direction"].append(k)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbol"); ap.add_argument("--sweeps"); ap.add_argument("--out")
    a = ap.parse_args()
    sets, table = load(a.sweeps.split(","))
    os.makedirs(a.out, exist_ok=True)
    rows = []
    for k, tr in table.items():
        mi, mo, mf = metrics(tr, START, IS_END), metrics(tr, IS_END, END), metrics(tr)
        rows.append({"key": k, "label": label(dict(kv.split("=", 1) for kv in k.split("|"))), "is": mi, "oos": mo, "full": mf,
                     "pass_is": passes(mi, START, IS_END), "pass_full": passes(mf, START, END), "pass_oos": passes(mo, IS_END, END)})
    rec = pick(table, START, IS_END)
    alt = None   # best net/DD on in-sample among passing sets (the "profit" alternative)
    for r in rows:
        if r["pass_is"] and (alt is None or r["is"]["ndd"] > alt["is"]["ndd"]): alt = r
    dflt = table.get(canon({}))
    pack = {"symbol": a.symbol, "periods": {"start": START, "is_end": IS_END, "end": END, "wf_cuts": WF_CUTS},
            "brief": {"ndd_min": NDD_MIN, "pf_min": PF_MIN, "min_losers": MIN_LOSERS, "trades_per_year_min": TRADES_PER_YEAR_MIN},
            "n_sets": len(rows), "n_pass_is": sum(r["pass_is"] for r in rows), "n_pass_full": sum(r["pass_full"] for r in rows),
            "n_pass_is_and_oos": sum(1 for r in rows if r["pass_is"] and r["oos"]["pf"] > 1 and r["oos"]["net"] > 0)}
    if dflt is not None:
        pack["defaults"] = {"key": canon({}), "is": metrics(dflt, START, IS_END), "oos": metrics(dflt, IS_END, END), "full": metrics(dflt),
                            "yearly": yearly(dflt), "equity": equity(dflt)}
    def describe(k):
        tr = table[k]
        return {"key": k, "label": label(dict(kv.split("=", 1) for kv in k.split("|"))), "params": dict(kv.split("=", 1) for kv in k.split("|")),
                "is": metrics(tr, START, IS_END), "oos": metrics(tr, IS_END, END), "full": metrics(tr), "yearly": yearly(tr),
                "equity": equity(tr), "mc": monte_carlo(tr, START, END), "mc_oos": monte_carlo(tr, IS_END, END),
                "long": metrics([x for x in tr if x["dir"] == "L"]), "short": metrics([x for x in tr if x["dir"] == "S"]),
                "exits": {w: sum(1 for x in tr if x["why"] == w) for w in sorted({x["why"] for x in tr})},
                "sensitivity": {inp: [{"label": label(dict(kv.split("=", 1) for kv in n.split("|"))), "value": dict(kv.split("=", 1) for kv in n.split("|")).get(inp, ""),
                                      "is": metrics(table[n], START, IS_END), "oos": metrics(table[n], IS_END, END)} for n in ns]
                                for inp, ns in neighbours(table, k).items()}}
    pack["rec"] = describe(rec[0]) if rec else None
    pack["alt"] = describe(alt["key"]) if alt and (not rec or alt["key"] != rec[0]) else None
    wf = walk_forward(table)
    pack["walkforward"] = {"steps": wf["steps"], "stitched": wf["stitched"], "equity": equity(wf["trades"], WF_CUTS[0], END),
                           "mc": monte_carlo(wf["trades"], WF_CUTS[0], END) if wf["trades"] else None}
    rows.sort(key=lambda r: (r["pass_is"], rank_key(r["is"])), reverse=True)
    pack["top_is"] = [{k: r[k] for k in ("key", "label", "is", "oos", "full", "pass_is", "pass_oos", "pass_full")} for r in rows[:30]]
    rows.sort(key=lambda r: (r["pass_full"], rank_key(r["full"])), reverse=True)
    pack["top_full"] = [{k: r[k] for k in ("key", "label", "is", "oos", "full", "pass_is", "pass_oos", "pass_full")} for r in rows[:30]]
    json.dump(pack, open(os.path.join(a.out, "pack.json"), "w"), indent=1, default=str)
    with open(os.path.join(a.out, "sets.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["label", "is_trades", "is_win", "is_net", "is_pf", "is_dd", "is_ndd", "oos_trades", "oos_win", "oos_net", "oos_pf", "oos_dd",
                    "oos_ndd", "full_trades", "full_win", "full_net", "full_pf", "full_dd", "full_ndd", "pass_is", "key"])
        for r in rows:
            w.writerow([r["label"]] + [round(r[p][m], 4) for p in ("is", "oos", "full") for m in ("trades", "win", "net", "pf", "dd", "ndd")
                                       if not (p != "is" and False)][:18] + [r["pass_is"], r["key"]])
    if rec:
        with open(os.path.join(a.out, "rec_trades.csv"), "w", newline="") as f:
            w = csv.writer(f); w.writerow(["entry_time", "exit_time", "dir", "entry", "exit", "profit", "exit_name"])
            for x in table[rec[0]]: w.writerow([x["entry"], x["exit"], x["dir"], x["e"], x["x"], x["pnl"], x["why"]])
    r = pack["rec"]
    print(f"{a.symbol}: {len(rows)} sets, {pack['n_pass_is']} pass in-sample, {pack['n_pass_full']} pass full period")
    if r:
        print(f"  rec  {r['label']}")
        for p in ("is", "oos", "full"):
            m = r[p]; print(f"   {p:4} trades {m['trades']:4} win {m['win']:.1%} net {m['net']:9.0f} PF {m['pf']:.2f} DD {m['dd']:7.0f} net/DD {m['ndd']:.2f}")
    else:
        print("  no set passes the brief in-sample")
    s = pack["walkforward"]["stitched"]
    print(f"  walk-forward {WF_CUTS[0]}..{END}: trades {s['trades']} win {s['win']:.1%} net {s['net']:.0f} PF {s['pf']:.2f} DD {s['dd']:.0f} net/DD {s['ndd']:.2f}")


if __name__ == "__main__":
    main()
