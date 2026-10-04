"""Collects each market's recommended set (results/<sym>/pack.json) into nt8/presets_rec.json as
SMC_<SYM>_Rec, merged with the validation presets, then regenerates and deploys SMCPresets.cs."""
import json, os, subprocess, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import analyze as A
presets = json.load(open(os.path.join(ROOT, "nt8", "presets_validate.json")))
for sym in ("MNQ", "MES", "MYM", "MGC"):
    f = os.path.join(ROOT, "results", sym.lower(), "pack.json")
    if not os.path.exists(f): continue
    rec = json.load(open(f))["rec"]
    if not rec: continue
    presets[f"SMC_{sym}_Rec"] = {k: v for k, v in rec["params"].items() if not A.same(v, A.STRAT_DEFAULTS.get(k, ""))}
json.dump(presets, open(os.path.join(ROOT, "nt8", "presets_rec.json"), "w"), indent=1)
for k, v in presets.items(): print(k, v)
subprocess.run([sys.executable, os.path.join(ROOT, "nt8", "make_presets.py"), os.path.join(ROOT, "nt8", "presets_rec.json")] + sys.argv[1:], check=True)
