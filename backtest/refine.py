"""Stage B: coordinate refinement of the best stage-A sets, scored on IN-SAMPLE data only.

    python backtest/refine.py --symbol MNQ --series work/series/MNQ.txt --stageA work/sweep/mnq-A --out work/sweep/mnq-B [--bases 6] [--rounds 3]

Each round takes the current best sets, varies every secondary input one at a time (the values in
EXTRA), runs them through the replica (resumable sweep folder), and moves each base to its best
variant if that beats it. Score = passes the brief first, then win rate, then net/DD (all in-sample).
"""
import argparse, json, os, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import analyze as A

BE_TICKS = {"MNQ": ["40", "80", "160"], "MES": ["8", "16", "32"], "MYM": ["20", "40", "80"], "MGC": ["10", "20", "40"]}
EXTRA = {
    "DispATRMult": ["1.5", "2.5", "3.0"],
    "SwingLength": ["3", "5", "6"],
    "DispMinRelStrength": ["1.0", "2.0"],
    "TrendATRMult": ["1.0", "2.0", "2.5"],
    "TrendBars": ["10", "30"],
    "MitigationMode": ["Touch", "Full"],
    "ConnMitigationStops": ["False"],
    "InvalidationMode": ["WickBeyond"],
    "CISDLevelMode": ["SeriesOpen"],
    "CISDMaxSeries": ["6", "20"],
    "ConnMaxCISDBars": ["50", "200"],
    "MaxAgeBars": ["100", "300"],
    "OppositeBlockExit": ["True"],
    "RideTrend": ["True"],
    "TargetRR": ["0.5", "0.75", "1.0", "1.25", "1.5", "2.0", "3.0"],
}
ROOT = os.path.dirname(os.path.abspath(__file__))
EXE = os.path.join(ROOT, "replica", "bin", "Release", "net10.0", "SmcReplica.dll")


def score(m):
    """Meets the brief > meets the sample floors (trades a year, losing trades) > neither; then win rate
    when the brief is met, else net/DD (capped, so a sample with no losers cannot win on infinity)."""
    ok = A.passes(m, A.START, A.IS_END)
    floors = m["losers"] >= A.MIN_LOSERS and m["trades"] >= A.TRADES_PER_YEAR_MIN * A.years(A.START, A.IS_END)
    return (ok, floors, m["win"] if ok else min(m["ndd"], 20.0), m["ndd"], m["net"])


def params_of(key): return dict(kv.split("=", 1) for kv in key.split("|"))


def run_sets(sets, args):
    grid = os.path.join(args.out, "grid.json")
    os.makedirs(args.out, exist_ok=True)
    # every set carries the same inputs so the sweep's resume key is stable across rounds
    full = [{k: s.get(k, A.DEFAULTS[k] if k in A.DEFAULTS else A.STRAT_DEFAULTS[k]) for k in sorted(ALLKEYS)} for s in sets]
    json.dump({"base": {}, "sets": full}, open(grid, "w"))
    cmd = ["dotnet", EXE, "sweep", "--series", args.series, "--data", ROOT, "--symbol", args.symbol,
           "--front", args.front, "--from", A.START, "--to", A.END, "--grid", grid, "--out", args.out, "--threads", str(args.threads)]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=open(os.path.join(args.out, "log.txt"), "a"))


ALLKEYS = set()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbol"); ap.add_argument("--series"); ap.add_argument("--stageA"); ap.add_argument("--out")
    ap.add_argument("--front", default=None); ap.add_argument("--bases", type=int, default=6); ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--threads", type=int, default=14)
    args = ap.parse_args()
    args.front = args.front or f"{args.symbol} 12-26"
    extra = dict(EXTRA); extra["BreakEven"] = ["True"]; extra["BreakEvenTicks"] = BE_TICKS[args.symbol]
    ALLKEYS.update(A.DEFAULTS); ALLKEYS.update(extra)

    _, table = A.load([args.stageA])
    ranked = sorted(table, key=lambda k: score(A.metrics(table[k], A.START, A.IS_END)), reverse=True)
    # distinct bases: at most two per timeframe pair so the refinement explores more than one corner
    bases, per_tf = [], {}
    for k in ranked:
        tf = params_of(k)["TimeframePair"]
        if per_tf.get(tf, 0) >= 2: continue
        bases.append(k); per_tf[tf] = per_tf.get(tf, 0) + 1
        if len(bases) >= args.bases: break
    log = []
    for rnd in range(1, args.rounds + 1):
        sets = []
        for b in bases:
            p = A.full_params(b)
            for inp, vals in extra.items():
                if inp == "BreakEvenTicks":
                    for v in vals: q = dict(p); q["BreakEven"] = "True"; q["BreakEvenTicks"] = v; sets.append(q)
                    continue
                if inp == "BreakEven": continue
                if inp in ("TrendATRMult", "TrendBars") and p.get("TrendFilter") != "True": continue
                for v in vals:
                    if A.same(v, p.get(inp, "")): continue
                    q = dict(p); q[inp] = v; sets.append(q)
        sets = [{k: v for k, v in q.items() if k in ALLKEYS} for q in sets]
        print(f"{args.symbol} round {rnd}: {len(sets)} variants of {len(bases)} bases", flush=True)
        run_sets(sets, args)
        _, tb = A.load([args.stageA, args.out])
        table.update(tb)
        new_bases = []
        for b in bases:
            fam = [b] + [k for k in tb if all(A.same(v, A.full_params(b).get(x, "")) for x, v in A.full_params(k).items()
                                               if x not in extra and x != "BreakEven") ]
            best = max(fam, key=lambda k: score(A.metrics(table[k], A.START, A.IS_END)))
            mb, mn = A.metrics(table[b], A.START, A.IS_END), A.metrics(table[best], A.START, A.IS_END)
            log.append({"round": rnd, "base": A.label(params_of(b)), "best": A.label(params_of(best)),
                        "base_is": mb, "best_is": mn})
            print(f"  {A.label(params_of(b))[:70]:70} win {mb['win']:.1%} ndd {mb['ndd']:.2f} -> {A.label(params_of(best))[-60:]} win {mn['win']:.1%} ndd {mn['ndd']:.2f}", flush=True)
            new_bases.append(best)
        if new_bases == bases: break
        bases = list(dict.fromkeys(new_bases))
    json.dump(log, open(os.path.join(args.out, "refine_log.json"), "w"), indent=1, default=str)


if __name__ == "__main__":
    main()
