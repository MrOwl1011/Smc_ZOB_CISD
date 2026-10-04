"""Trade-by-trade comparison of two SMC_Results*.csv files (the strategy's own closed-trade log): the
one NinjaTrader 8 wrote in the Strategy Analyzer and the one the replica wrote for the same preset.

    python backtest/compare_results.py <nt8.csv> <replica.csv> [--from YYYY-MM-DD]

Trades are matched on open_time (the signal minute); the report lists the matched count, P&L
differences and every unmatched trade on either side.
"""
import csv, sys


def load(p, since):
    rows = []
    with open(p) as f:
        for r in csv.DictReader(f):
            if since and r["open_time"].replace(".", "-") < since: continue
            rows.append(r)
    return rows


def main():
    a, b = sys.argv[1], sys.argv[2]
    since = sys.argv[sys.argv.index("--from") + 1] if "--from" in sys.argv else None
    nt, rp = load(a, since), load(b, since)
    by = {}
    for r in rp: by.setdefault(r["open_time"], []).append(r)
    matched, diffs, only_nt = 0, [], []
    for r in nt:
        lst = by.get(r["open_time"])
        if lst:
            q = lst.pop(0); matched += 1
            d = float(r["profit"]) - float(q["profit"])
            if abs(d) > 0.005: diffs.append((r["open_time"], r["close_time"], q["close_time"], float(r["profit"]), float(q["profit"])))
        else:
            only_nt.append(r)
    only_rp = [r for lst in by.values() for r in lst]
    net_nt = sum(float(r["profit"]) for r in nt); net_rp = sum(float(r["profit"]) for r in rp)
    print(f"NT8 {len(nt)} trades net {net_nt:.2f} | replica {len(rp)} trades net {net_rp:.2f} | matched {matched}, "
          f"P&L differs on {len(diffs)}, NT8-only {len(only_nt)}, replica-only {len(only_rp)}")
    for x in diffs[:20]: print("  P&L differs", x)
    for r in only_nt[:20]: print("  NT8 only", r["open_time"], r["close_time"], r["profit"])
    for r in only_rp[:20]: print("  replica only", r["open_time"], r["close_time"], r["profit"])
    return 0 if not diffs and not only_nt and not only_rp else 1


if __name__ == "__main__":
    sys.exit(main())
