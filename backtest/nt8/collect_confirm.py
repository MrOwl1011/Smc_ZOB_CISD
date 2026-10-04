"""Stores NT8's confirmation of a market's recommended set in results/<sym>/nt8.json (and the log XML +
the strategy's result file next to it). Usage: python nt8/collect_confirm.py MNQ"""
import glob, json, os, re, shutil, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NT = os.path.join(os.path.expanduser("~"), "OneDrive", "Documents", "NinjaTrader 8")
sym = sys.argv[1]; pre = f"SMC_{sym}_Rec"; out = os.path.join(ROOT, "results", sym.lower())
log = sorted(glob.glob(os.path.join(NT, "strategyanalyzerlogs", f"@@@{pre}_*.xml")), key=os.path.getmtime)[-1]
s = open(log, encoding="utf-8").read()
m = re.search(r"<PerformanceUnit>Currency</PerformanceUnit>\s*<SummaryPerformancesSerialize>(.*?)</SummaryPerformancesSerialize>", s, re.S)
st = {kv.split(";")[0]: kv.split(";")[1:] for kv in m.group(1).split("|")}
f = lambda k: float(st[k][0])
run = {"name": "NT8 Strategy Analyzer, 1 contract", "trades": int(f("TotalNumTrades")), "win": f("PercentProfitable"), "net": f("TotalNetProfit"),
       "pf": f("ProfitFactor"), "dd": abs(f("MaxDrawdown")), "commission_total": f("Commission")}
run["ndd"] = run["net"] / run["dd"] if run["dd"] else 99.0
shutil.copy(log, os.path.join(out, "nt8_rec.xml"))
res = os.path.join(NT, f"SMC_Results_{pre}.csv")
if os.path.exists(res): shutil.move(res, os.path.join(out, "nt8_rec_results.csv"))
json.dump({"runs": [run], "commission": "NinjaTrader Brokerage template, $0.95/side index micros, $1.20 MGC",
           "instrument": re.search(r"<Instrument>(.*?)</Instrument>", s).group(1)}, open(os.path.join(out, "nt8.json"), "w"), indent=1)
print(sym, run)
