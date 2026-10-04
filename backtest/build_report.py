"""Builds docs/SMC-OrderBlock-Backtest.html from the per-symbol packs.

    python backtest/build_report.py results/mnq results/mes results/mym results/mgc

Reads <pack>/pack.json (analyze.py), optional <pack>/nt8.json (NT8 confirmation of the recommended set)
and backtest/results/validation.json (replica vs NT8, trade by trade). Every verdict is computed.
"""
import html, json, os, sys, datetime as dt

ROOT = os.path.dirname(os.path.abspath(__file__))
NAMES = {"MNQ": "Micro E-mini Nasdaq-100", "MES": "Micro E-mini S&P 500", "MYM": "Micro E-mini Dow", "MGC": "Micro Gold"}
INPUT_NAMES = {
    "TimeframePair": "Timeframes (HTF Order Block -> CISD)", "TargetRR": "Take profit, as a multiple of risk",
    "TrendFilter": "Trend filter: only CISDs with the OB-timeframe trend", "FVGMode": "FVG confirmation",
    "CISDSweep": "Liquidity Sweep (CISD)", "ConnCISDMode": "CISD validation", "ConnRetestMode": "Retest mode",
    "EnableBull": "Detect bullish OBs", "EnableBear": "Detect bearish OBs", "DispATRMult": "Displacement ATR multiplier",
    "SwingLength": "Swing strength (bars each side)", "DispMinRelStrength": "Min relative strength", "TrendATRMult": "Trend filter: displacement needed, in ATR",
    "TrendBars": "Trend filter: OB candles measured", "MitigationMode": "Mitigation detection", "ConnMitigationStops": "Mitigation stops CISD search",
    "InvalidationMode": "OB invalidation method", "CISDLevelMode": "Confirmation level", "CISDMaxSeries": "Max candles in the series",
    "ConnMaxCISDBars": "Bars to find a CISD after the retest", "MaxAgeBars": "Expire OB after N bars", "OppositeBlockExit": "Opposite block exit",
    "RideTrend": "Ride the trend", "BreakEven": "Break even", "BreakEvenTicks": "Break even trigger (ticks)", "ConnMode": "CISD validation + retest mode",
    "Direction": "Direction (bull / bear OB detection)"}
E = html.escape


def money(v, sign=False):
    s = f"{abs(v):,.0f}"
    return ("-" if v < 0 else ("+" if sign and v > 0 else "")) + "$" + s


def pctf(v): return f"{v * 100:.1f}%"


def ndd(v): return "&infin;" if v >= 99 else f"{v:.2f}"


def pf(v): return "&infin;" if v >= 99 else f"{v:.2f}"


def pill(ok, yes="Meets brief", no="Misses brief"):
    return f'<span class="pill {"ok" if ok else "bad"}">{"&#10003; " + yes if ok else "&#10007; " + no}</span>'


def mrow(name, m, extra=""):
    return (f"<tr><th scope=row>{name}</th><td>{m['trades']}</td><td>{pctf(m['win'])}</td><td>{money(m['net'])}</td><td>{pf(m['pf'])}</td>"
            f"<td>{money(m['dd'])}</td><td class=strong>{ndd(m['ndd'])}</td><td>{money(m['avg'])}</td>{extra}</tr>")


MHEAD = "<tr><th></th><th>Trades</th><th>Win rate</th><th>Net</th><th>Profit factor</th><th>Max DD</th><th>Net / DD</th><th>Avg trade</th></tr>"


def passes(m, brief, yrs):
    return m["pf"] > brief["pf_min"] and m["ndd"] >= brief["ndd_min"] and m["losers"] >= brief["min_losers"] and m["trades"] >= int(brief["trades_per_year_min"] * yrs)


def years(a, b): return (dt.date.fromisoformat(b) - dt.date.fromisoformat(a)).days / 365.25


def chart(cid, series, split=None, height=240):
    """Line chart (equity in $) with hover; series: [(name, cssvar, [[date, value], ...])]."""
    data = {"series": [{"name": n, "var": v, "pts": pts} for n, v, pts in series], "split": split}
    return (f'<figure class="chart" id="{cid}" data-h="{height}"><script type="application/json">{json.dumps(data)}</script>'
            f'<div class="legend">' + "".join(f'<span><i style="background:var({v})"></i>{E(n)}</span>' for n, v, _ in series) +
            (f'<span class="split">| dashed line: in-sample ends {split}</span>' if split else "") + "</div></figure>")


def sym_section(pack, nt8, val):
    s = pack["symbol"]; rec = pack["rec"]; alt = pack.get("alt"); P = pack["periods"]; brief = pack["brief"]
    out = [f'<section class="sym" id="{s.lower()}"><header class="symhead"><p class="eyebrow">{E(NAMES[s])}</p><h2>{s}</h2></header>']
    out.append(f"<p class=lede>{pack['n_sets']:,} parameter sets tested. {pack['n_pass_is']:,} meet the brief in-sample "
               f"({P['start']} to {P['is_end']}), {pack['n_pass_full']:,} over the full five years.</p>")
    if not rec:
        out.append('<p class="callout bad">No parameter set met the brief (profit factor above 1 and net profit at least 3x the max drawdown, '
                   f'at least {brief["trades_per_year_min"]} trades a year and {brief["min_losers"]} losing trades) on the in-sample years. '
                   'The table below shows the closest sets.</p>')
    else:
        yrs_full = years(P["start"], P["end"])
        full_ok = passes(rec["full"], brief, yrs_full)
        oos_ok = rec["oos"]["pf"] > 1 and rec["oos"]["net"] > 0
        out.append('<h3>Recommended set</h3>')
        out.append(f'<p class="setlabel"><code>{E(rec["label"])}</code> {pill(full_ok, "3:1 over five years", "below 3:1 over five years")} '
                   f'{pill(oos_ok, "profitable out-of-sample", "loses out-of-sample")}</p>')
        diffs = [(k, v) for k, v in rec["params"].items() if not _is_default(k, v)]
        out.append('<p class="note">Picked on in-sample data only: highest win rate among the sets that meet the brief there. '
                   'Inputs not listed keep the strategy defaults.</p>')
        out.append('<div class="tablewrap"><table class="inputs"><tr><th>Input</th><th>Value</th></tr>' +
                   "".join(f"<tr><td>{E(INPUT_NAMES.get(k, k))}</td><td><code>{E(v)}</code></td></tr>" for k, v in diffs) + "</table></div>")
        out.append('<div class="tablewrap"><table class="m">' + MHEAD + mrow(f"In-sample {P['start'][:7]} to {P['is_end'][:7]}", rec["is"]) +
                   mrow(f"Out-of-sample {P['is_end'][:7]} to {P['end'][:7]}", rec["oos"]) + mrow("Full period", rec["full"]) +
                   mrow("Long trades", rec["long"]) + mrow("Short trades", rec["short"]) + "</table></div>")
        if nt8:
            out.append(nt8_block(nt8, rec))
        out.append(chart(f"eq-{s}", [("Recommended set, 1 contract, after commission", "--s1", rec["equity"])] +
                         ([("Strategy defaults", "--s2", pack["defaults"]["equity"])] if pack.get("defaults", {}).get("equity") else []),
                         split=P["is_end"]))
        out.append('<h3>Year by year</h3><div class="tablewrap"><table class="m"><tr><th>Year</th><th>Trades</th><th>Win rate</th><th>Net</th>'
                   '<th>Profit factor</th><th>Max DD</th><th>Net / DD</th><th>Avg trade</th></tr>' +
                   "".join(mrow(str(y["year"]), y) for y in rec["yearly"]) + "</table></div>")
        ex = rec["exits"]
        out.append('<p class="note">Exits over the full period: ' + ", ".join(f"{E(k)} {v}" for k, v in ex.items()) + ".</p>")
    if pack.get("defaults"):
        d = pack["defaults"]
        out.append('<h3>The defaults</h3><p class="note">The strategy as it ships (H1 Order Blocks, M5 CISD, 1:1 target, trend filter on), '
                   'with Execute trades on.</p><div class="tablewrap"><table class="m">' + MHEAD + mrow("In-sample", d["is"]) +
                   mrow("Out-of-sample", d["oos"]) + mrow("Full period", d["full"]) + "</table></div>")
    wf = pack["walkforward"]
    out.append('<h3>Walk-forward (forward test)</h3><p class="note">At each cut-off the selection rule is re-run on all data before it, '
               'and the chosen set trades the next six months untouched. Stitched together, those six-month segments are what a trader '
               'who re-optimised twice a year would have earned.</p>')
    rows = []
    for st in wf["steps"]:
        if st["set"] is None:
            rows.append(f"<tr><td>{st['cut']}</td><td>{st['to']}</td><td colspan=6 class=muted>nothing met the brief before this date: flat</td></tr>")
        else:
            o = st["oos"]
            rows.append(f"<tr><td>{st['cut']}</td><td>{st['to']}</td><td class=lbl><code>{E(st['label'])}</code></td><td>{o['trades']}</td>"
                        f"<td>{pctf(o['win'])}</td><td>{money(o['net'])}</td><td>{pf(o['pf'])}</td><td>{money(o['dd'])}</td></tr>")
    out.append('<div class="tablewrap"><table class="m wf"><tr><th>Picked on data before</th><th>Traded until</th><th>Set picked</th><th>Trades</th>'
               '<th>Win rate</th><th>Net</th><th>Profit factor</th><th>Max DD</th></tr>' + "".join(rows) + "</table></div>")
    sw = wf["stitched"]
    out.append('<div class="tablewrap"><table class="m">' + MHEAD + mrow(f"Stitched forward test {P['wf_cuts'][0][:7]} to {P['end'][:7]}", sw) + "</table></div>")
    if wf.get("equity") and len(wf["equity"]) > 2:
        out.append(chart(f"wf-{s}", [("Walk-forward equity (out-of-sample only)", "--s3", wf["equity"])]))
    if rec:
        out.append(mc_block(rec, wf))
        out.append(sens_block(rec))
    if alt:
        out.append('<h3>Alternative: best net / DD in-sample</h3><p class="note">The set that maximises profit per unit of drawdown '
                   'in-sample, for comparison with the win-rate pick.</p>' +
                   f'<p class="setlabel"><code>{E(alt["label"])}</code></p><div class="tablewrap"><table class="m">' + MHEAD +
                   mrow("In-sample", alt["is"]) + mrow("Out-of-sample", alt["oos"]) + mrow("Full period", alt["full"]) + "</table></div>")
    out.append(top_block(pack))
    out.append("</section>")
    return "\n".join(out)


STRAT_DEFAULTS = json.load(open(os.path.join(ROOT, "strategy_defaults.json")))


def _is_default(k, v):
    d = STRAT_DEFAULTS.get(k)
    if d is None: return False
    try: return float(d) == float(v)
    except ValueError: return d.lower() == v.lower()


def nt8_block(nt8, rec):
    rows = []
    for run in nt8["runs"]:
        rows.append(f"<tr><th scope=row>{E(run['name'])}</th><td>{run['trades']}</td><td>{pctf(run['win'])}</td><td>{money(run['net'])}</td>"
                    f"<td>{pf(run['pf'])}</td><td>{money(run['dd'])}</td><td class=strong>{ndd(run['ndd'])}</td><td>{money(run['net'] / run['trades'] if run['trades'] else 0)}</td></tr>")
    return ('<h3>NinjaTrader 8 confirmation</h3><p class="note">The same set run in NT8\'s Strategy Analyzer over the full period, '
            f'1-minute data, commission on ({E(nt8.get("commission", ""))}). These are NT8\'s own numbers.</p>'
            '<div class="tablewrap"><table class="m">' + MHEAD + "".join(rows) + "</table></div>" +
            (f'<p class="note">{E(nt8["note"])}</p>' if nt8.get("note") else ""))


def mc_block(rec, wf):
    f, y, sh = rec["mc"]["full"], rec["mc"]["year"], rec["mc"]["shuffle"]
    thr = y["p_dd_gt"]
    return ('<h3>Monte Carlo</h3><p class="note">5,000 resampled histories of the recommended set: trading days drawn with replacement '
            'in 5-day blocks (keeps losing streaks that cluster together), plus 5,000 reshuffles of the trade order. The historical path is one draw among many.</p>'
            '<div class="tablewrap"><table class="m"><tr><th></th><th>Net, 5th pct</th><th>Net, median</th><th>Net, 95th pct</th><th>Chance of a loss</th>'
            '<th>Max DD, median</th><th>Max DD, 95th pct</th><th>Max DD, 99th pct</th><th>Chance net/DD &ge; 3</th></tr>'
            f"<tr><th scope=row>Five years ({f['days']} trading days)</th><td>{money(f['net_p05'])}</td><td>{money(f['net_p50'])}</td><td>{money(f['net_p95'])}</td>"
            f"<td>{pctf(f['p_loss'])}</td><td>{money(f['dd_p50'])}</td><td>{money(f['dd_p95'])}</td><td>{money(f['dd_p99'])}</td><td>{pctf(f['p_ndd3'])}</td></tr>"
            f"<tr><th scope=row>Any one year (252 days)</th><td>{money(y['net_p05'])}</td><td>{money(y['net_p50'])}</td><td>{money(y['net_p95'])}</td>"
            f"<td>{pctf(y['p_loss'])}</td><td>{money(y['dd_p50'])}</td><td>{money(y['dd_p95'])}</td><td>{money(y['dd_p99'])}</td><td>{pctf(y['p_ndd3'])}</td></tr>"
            "</table></div>"
            f'<p class="note">Trade-order shuffle: historical max drawdown {money(sh["obs_dd"])}; median of the reshuffles {money(sh["dd_p50"])}, '
            f'95th percentile {money(sh["dd_p95"])}, 99th {money(sh["dd_p99"])}. Chance that a one-year stretch draws down more than '
            + ", ".join(f"{money(float(k))}: {pctf(v)}" for k, v in thr.items()) + " (1 contract).</p>")


def sens_block(rec):
    rows = []
    for inp, lst in sorted(rec["sensitivity"].items()):
        for n in sorted(lst, key=lambda n: n["value"]):
            rows.append(f"<tr><td>{E(INPUT_NAMES.get(inp, inp))}</td><td><code>{E(n['value'] if inp not in ('ConnMode', 'Direction') else n['label'].split(' ')[1] if inp == 'Direction' else n['label'])}</code></td>"
                        f"<td>{n['is']['trades']}</td><td>{pctf(n['is']['win'])}</td><td>{ndd(n['is']['ndd'])}</td><td>{n['oos']['trades']}</td>"
                        f"<td>{pctf(n['oos']['win'])}</td><td>{money(n['oos']['net'])}</td></tr>")
    if not rows: return ""
    m = rec
    return ('<h3>Sensitivity: one input at a time</h3><p class="note">Each row changes a single input of the recommended set. '
            f'For reference the set itself: in-sample {m["is"]["trades"]} trades, win {pctf(m["is"]["win"])}, net/DD {ndd(m["is"]["ndd"])}; '
            f'out-of-sample net {money(m["oos"]["net"])}. A good set sits on a plateau: neighbours that are only a little worse.</p>'
            '<div class="tablewrap"><table class="m sens"><tr><th>Input</th><th>Value</th><th>IS trades</th><th>IS win</th><th>IS net/DD</th>'
            '<th>OOS trades</th><th>OOS win</th><th>OOS net</th></tr>' + "".join(rows) + "</table></div>")


def top_block(pack):
    rows = []
    for r in pack["top_full"][:12]:
        rows.append(f"<tr><td class=lbl><code>{E(r['label'])}</code></td><td>{r['full']['trades']}</td><td>{pctf(r['full']['win'])}</td>"
                    f"<td>{money(r['full']['net'])}</td><td>{pf(r['full']['pf'])}</td><td>{money(r['full']['dd'])}</td><td>{ndd(r['full']['ndd'])}</td>"
                    f"<td>{ndd(r['is']['ndd'])}</td><td>{ndd(r['oos']['ndd'])}</td></tr>")
    return ('<details><summary>Top 12 sets by full-period win rate among those meeting the brief over five years (hindsight view)</summary>'
            '<p class="note">These were chosen with all the data, out-of-sample included, so they are optimistic by construction. '
            'They show where the edge lives, not what to expect.</p><div class="tablewrap"><table class="m"><tr><th>Set</th><th>Trades</th><th>Win</th><th>Net</th>'
            '<th>PF</th><th>Max DD</th><th>Net/DD</th><th>IS net/DD</th><th>OOS net/DD</th></tr>' + "".join(rows) + "</table></div></details>")


def scorecard(packs, nt8s):
    rows = []
    for p in packs:
        s = p["symbol"]; r = p["rec"]; wf = p["walkforward"]["stitched"]; P = p["periods"]
        if not r:
            rows.append(f'<tr><th scope=row><a href="#{s.lower()}">{s}</a></th><td colspan=9 class=muted>no set meets the brief in-sample</td>'
                        f'<td>{ndd(wf["ndd"])}</td><td>{pill(False, "", "No pick")}</td></tr>'); continue
        ok = passes(r["full"], p["brief"], years(P["start"], P["end"])) and r["oos"]["net"] > 0
        nt = nt8s.get(s)
        ntn = money(nt["runs"][0]["net"]) if nt and nt.get("runs") else "&ndash;"
        rows.append(f'<tr><th scope=row><a href="#{s.lower()}">{s}</a></th><td class=lbl><code>{E(r["label"])}</code></td><td>{r["full"]["trades"]}</td>'
                    f'<td class=strong>{pctf(r["full"]["win"])}</td><td>{money(r["full"]["net"])}</td><td>{pf(r["full"]["pf"])}</td><td>{money(r["full"]["dd"])}</td>'
                    f'<td class=strong>{ndd(r["full"]["ndd"])}</td><td>{money(r["oos"]["net"])}</td><td>{ntn}</td><td>{ndd(wf["ndd"])}</td><td>{pill(ok, "Pass", "Fail")}</td></tr>')
    return ('<div class="tablewrap"><table class="m score"><tr><th>Market</th><th>Recommended set (picked in-sample)</th><th>Trades</th><th>Win rate</th>'
            '<th>Net</th><th>PF</th><th>Max DD</th><th>Net / DD</th><th>Out-of-sample net</th><th>NT8 net</th><th>Walk-forward net/DD</th><th>Verdict</th></tr>' + "".join(rows) + "</table></div>")


CSS = r"""
:root{--bg:#f6f7f9;--panel:#ffffff;--fg:#141b23;--muted:#5a6573;--line:#dfe3e8;--accent:#1f5f8b;--ok:#1d7a4a;--okbg:#e3f3ea;--bad:#a93636;--badbg:#f8e5e5;
--s1:#2a78d6;--s2:#8a8f98;--s3:#eb6834;--grid:#e8ebef;
--display:"Archivo","Segoe UI",system-ui,sans-serif;--body:"IBM Plex Sans","Segoe UI",system-ui,sans-serif;--mono:"IBM Plex Mono",ui-monospace,Consolas,monospace}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#0f1419;--panel:#161d24;--fg:#e4e9ee;--muted:#9aa6b2;--line:#2a333d;--accent:#6fb0dc;--ok:#62c48d;--okbg:#173326;--bad:#e57a7a;--badbg:#3a1d1d;--s1:#3987e5;--s2:#7d838c;--s3:#d95926;--grid:#222b34;color-scheme:dark}}
:root[data-theme="dark"]{--bg:#0f1419;--panel:#161d24;--fg:#e4e9ee;--muted:#9aa6b2;--line:#2a333d;--accent:#6fb0dc;--ok:#62c48d;--okbg:#173326;--bad:#e57a7a;--badbg:#3a1d1d;--s1:#3987e5;--s2:#7d838c;--s3:#d95926;--grid:#222b34;color-scheme:dark}
body{background:var(--bg);color:var(--fg);font:15px/1.55 var(--body);margin:0}
.wrap{max-width:1180px;margin:0 auto;padding-inline:20px;padding-block:28px 64px}
h1,h2,h3{font-family:var(--display);text-wrap:balance;line-height:1.15}
h1{font-size:2.3rem;margin:.2em 0 .3em;font-weight:800;letter-spacing:-.01em}
h2{font-size:1.7rem;margin:0;font-weight:800}
h3{font-size:1.1rem;margin:2em 0 .5em;font-weight:700}
.eyebrow{font:600 .75rem/1 var(--body);letter-spacing:.12em;text-transform:uppercase;color:var(--accent);margin:0}
.lede{font-size:1.05rem;max-width:72ch}
p,li{max-width:80ch}
.note{color:var(--muted);font-size:.9rem}
code{font-family:var(--mono);font-size:.82em}
nav.toc{display:flex;flex-wrap:wrap;gap:8px 18px;margin:16px 0 0;font-size:.9rem}
nav.toc a{color:var(--accent);text-decoration:none;border-bottom:1px solid transparent}nav.toc a:hover,nav.toc a:focus{border-bottom-color:var(--accent)}
section{margin-top:44px}
section.sym{border-top:2px solid var(--fg);padding-top:18px}
.symhead{display:flex;flex-direction:column;gap:4px}
.tablewrap{overflow-x:auto;margin:.6em 0}
table{border-collapse:collapse;font-variant-numeric:tabular-nums;font-size:.86rem;background:var(--panel)}
th,td{padding:6px 10px;border-bottom:1px solid var(--line);text-align:right;white-space:nowrap}
th{font-weight:600;color:var(--muted);font-size:.78rem}
th[scope=row]{text-align:left;color:var(--fg);font-size:.86rem}
table.inputs td,table.inputs th{text-align:left}
td.lbl{text-align:left;white-space:normal;min-width:260px}
td.strong{font-weight:700}
td.muted{color:var(--muted);text-align:left}
.pill{display:inline-block;font:600 .72rem/1 var(--body);padding:4px 8px;border-radius:999px;margin-left:4px;white-space:nowrap}
.pill.ok{color:var(--ok);background:var(--okbg)}.pill.bad{color:var(--bad);background:var(--badbg)}
.callout{padding:12px 14px;border-left:3px solid var(--accent);background:var(--panel)}
.callout.bad{border-left-color:var(--bad)}
.setlabel{display:flex;flex-wrap:wrap;gap:6px;align-items:center}
.verdict{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:14px;margin:18px 0}
.verdict div{background:var(--panel);border:1px solid var(--line);padding:12px 14px;min-width:0}
.verdict b{display:block;font:800 1.5rem/1.1 var(--display)}
.verdict span{color:var(--muted);font-size:.82rem}
figure.chart{margin:14px 0;background:var(--panel);border:1px solid var(--line);padding:10px 10px 6px;position:relative}
figure.chart svg{display:block;width:100%;height:auto;overflow:visible}
figure.chart text{fill:var(--muted);font:11px var(--body)}
.legend{display:flex;flex-wrap:wrap;gap:4px 16px;font-size:.8rem;color:var(--muted);padding:4px 4px 0}
.legend i{display:inline-block;width:14px;height:3px;border-radius:2px;margin-right:6px;vertical-align:middle}
.tip{position:absolute;pointer-events:none;background:var(--fg);color:var(--bg);font:12px/1.35 var(--body);padding:6px 8px;border-radius:4px;white-space:nowrap}
details{margin-top:1.6em}summary{cursor:pointer;font-weight:600}
ol li,ul li{margin:.3em 0}
@media (max-width:600px){h1{font-size:1.7rem}}
"""

JS = r"""
document.querySelectorAll('figure.chart').forEach(fig=>{
 const d=JSON.parse(fig.querySelector('script').textContent);const H=+fig.dataset.h||240,W=1000,L=70,R=12,T=10,B=28;
 const t=s=>Date.parse(s.length>10?s.replace(' ','T'):s);let xs=[],ys=[0];
 d.series.forEach(s=>s.pts.forEach(p=>{xs.push(t(p[0]));ys.push(p[1])}));
 const x0=Math.min(...xs),x1=Math.max(...xs);let y0=Math.min(...ys),y1=Math.max(...ys);const pad=(y1-y0)*.06||1;y0-=pad;y1+=pad;
 const X=v=>L+(v-x0)/(x1-x0)*(W-L-R),Y=v=>T+(1-(v-y0)/(y1-y0))*(H-T-B);
 const step=(()=>{const r=(y1-y0)/5,m=Math.pow(10,Math.floor(Math.log10(r)));return [1,2,2.5,5,10].map(k=>k*m).find(k=>k>=r)})();
 let g='';for(let v=Math.ceil(y0/step)*step;v<=y1;v+=step){g+=`<line x1="${L}" x2="${W-R}" y1="${Y(v)}" y2="${Y(v)}" stroke="var(--grid)" stroke-width="1"/><text x="${L-8}" y="${Y(v)+4}" text-anchor="end">${v<0?'-':''}$${Math.abs(v).toLocaleString()}</text>`}
 const yA=new Date(x0).getFullYear(),yB=new Date(x1).getFullYear();for(let yy=yA+1;yy<=yB;yy++){const tx=Date.parse(yy+'-01-01');g+=`<text x="${X(tx)}" y="${H-8}" text-anchor="middle">${yy}</text><line x1="${X(tx)}" x2="${X(tx)}" y1="${H-B}" y2="${H-B+4}" stroke="var(--muted)"/>`}
 g+=`<line x1="${L}" x2="${W-R}" y1="${Y(0)}" y2="${Y(0)}" stroke="var(--muted)" stroke-width="1"/>`;
 if(d.split){const sx=X(t(d.split));g+=`<line x1="${sx}" x2="${sx}" y1="${T}" y2="${H-B}" stroke="var(--muted)" stroke-dasharray="4 4"/><text x="${sx+6}" y="${T+12}">out-of-sample &rarr;</text>`}
 d.series.forEach(s=>{const p=s.pts.map((q,i)=>(i?'L':'M')+X(t(q[0])).toFixed(1)+' '+Y(q[1]).toFixed(1)).join('');g+=`<path d="${p}" fill="none" stroke="var(${s.var})" stroke-width="2" stroke-linejoin="round"/>`});
 g+=`<line class="cx" x1="0" x2="0" y1="${T}" y2="${H-B}" stroke="var(--muted)" visibility="hidden"/><circle class="cd" r="4" fill="var(--s1)" stroke="var(--panel)" stroke-width="2" visibility="hidden"/>`;
 fig.insertAdjacentHTML('afterbegin',`<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Equity curve">${g}</svg>`);
 const svg=fig.querySelector('svg'),cx=svg.querySelector('.cx'),cd=svg.querySelector('.cd'),tip=document.createElement('div');tip.className='tip';tip.hidden=true;fig.appendChild(tip);
 const main=d.series[0].pts.map(q=>[t(q[0]),q[1],q[0]]);
 svg.addEventListener('pointermove',e=>{const r=svg.getBoundingClientRect(),vx=(e.clientX-r.left)/r.width*W,tx=x0+(vx-L)/(W-L-R)*(x1-x0);
  let i=0;while(i<main.length-1&&main[i+1][0]<=tx)i++;const q=main[i];const px=X(q[0]),py=Y(q[1]);
  cx.setAttribute('x1',px);cx.setAttribute('x2',px);cx.setAttribute('visibility','visible');cd.setAttribute('cx',px);cd.setAttribute('cy',py);cd.setAttribute('fill',`var(${d.series[0].var})`);cd.setAttribute('visibility','visible');
  tip.hidden=false;tip.innerHTML=`${q[2].slice(0,10)}<br><b>${q[1]<0?'-':''}$${Math.abs(q[1]).toLocaleString(undefined,{maximumFractionDigits:0})}</b> ${d.series[0].name.split(',')[0]}`;
  const fx=px/W*r.width;tip.style.left=Math.min(fx+12,r.width-150)+'px';tip.style.top=(py/H*r.height)+'px'});
 svg.addEventListener('pointerleave',()=>{cx.setAttribute('visibility','hidden');cd.setAttribute('visibility','hidden');tip.hidden=true});
});
"""


def main():
    packs = [json.load(open(os.path.join(d, "pack.json"))) for d in sys.argv[1:] if not d.startswith("--")]
    nt8s = {}
    for d in sys.argv[1:]:
        f = os.path.join(d, "nt8.json")
        if os.path.exists(f): nt8s[json.load(open(os.path.join(d, "pack.json")))["symbol"]] = json.load(open(f))
    for p in packs:   # defaults equity for the chart
        tf = os.path.join(sys.argv[1 + packs.index(p)], "defaults_equity.json")
        if os.path.exists(tf): p["defaults"]["equity"] = json.load(open(tf))
    val = json.load(open(os.path.join(ROOT, "results", "validation.json"))) if os.path.exists(os.path.join(ROOT, "results", "validation.json")) else None
    method = json.load(open(os.path.join(ROOT, "results", "method.json"))) if os.path.exists(os.path.join(ROOT, "results", "method.json")) else {}
    P = packs[0]["periods"]; brief = packs[0]["brief"]
    n_ok = sum(1 for p in packs if p["rec"] and passes(p["rec"]["full"], p["brief"], years(P["start"], P["end"])) and p["rec"]["oos"]["net"] > 0)
    parts = [f"<title>SMC Order Block Backtest</title><style>{CSS}</style>",
             '<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Archivo:wght@600;800&family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:wght@400;600&display=swap">',
             '<div class="wrap"><header><p class="eyebrow">SMCOrderBlockStrategy &middot; NinjaTrader 8 &middot; Toreda</p>',
             '<h1>SMC Order Block Backtest</h1>',
             f'<p class="lede">HTF Order Block retest &rarr; LTF CISD confirmation, tested on {", ".join(p["symbol"] for p in packs)} from {P["start"]} to {P["end"]}: '
             f'five years of 1-minute data covering the 2022 bear market, the 2023&ndash;24 rally and the 2025&ndash;26 tape. The brief: a profit factor above 1, '
             f'net profit at least {brief["ndd_min"]:.0f}&times; the maximum drawdown, and within that, the highest win rate. '
             f'<b>{n_ok} of {len(packs)}</b> markets have a set, picked on in-sample data alone, that meets the brief over five years and stays profitable out-of-sample.</p>',
             '<nav class="toc"><a href="#scorecard">Scorecard</a><a href="#bottomline">What the numbers say</a><a href="#method">How it was tested</a>' +
             "".join(f'<a href="#{p["symbol"].lower()}">{p["symbol"]}</a>' for p in packs) + '<a href="#caveats">Know before you trade it</a><a href="#run">Run it in NT8</a></nav></header>',
             '<section id="scorecard"><h2>Scorecard</h2><p class="note">1 contract, after commission ($0.95 a side for the index micros, $1.20 for MGC), '
             'full period unless noted. Verdict: meets the brief over five years and profitable out-of-sample.</p>' + scorecard(packs, nt8s) + "</section>",
             (open(os.path.join(ROOT, "results", "bottomline.html"), encoding="utf-8").read() if os.path.exists(os.path.join(ROOT, "results", "bottomline.html")) else ""),
             method_block(packs, val, method)]
    for p in packs: parts.append(sym_section(p, nt8s.get(p["symbol"]), val))
    parts.append(caveats(packs))
    parts.append(run_block(packs, method))
    parts.append(f'<p class="note">Generated {dt.date.today().isoformat()} by backtest/build_report.py from the replica sweep packs.</p></div><script>{JS}</script>')
    out = os.path.join(ROOT, "..", "docs", "SMC-OrderBlock-Backtest.html")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    open(out, "w", encoding="utf-8").write("\n".join(parts))
    print("wrote", os.path.abspath(out))


def method_block(packs, val, method):
    P = packs[0]["periods"]; b = packs[0]["brief"]
    vrows = ""
    if val:
        vrows = '<div class="tablewrap"><table class="m"><tr><th>Preset</th><th>What it exercises</th><th>Market</th><th>NT8 trades</th><th>Replica trades</th><th>Found on both sides</th><th>Same P&amp;L to the cent</th><th>NT8 net</th><th>Replica net</th></tr>' + "".join(
            f"<tr><th scope=row>{E(v['preset'])}</th><td class=lbl>{E(v['what'])}</td><td>{v['symbol']}</td><td>{v['nt8_trades']:,}</td><td>{v['replica_trades']:,}</td>"
            f"<td>{v['matched']:,}</td><td>{v['same_pnl']:,}</td><td>{money(v['nt8_net'])}</td><td>{money(v['replica_net'])}</td></tr>" for v in val["runs"]) + "</table></div>" \
            + f'<p class="note">{E(val["note"])} Window {val["runs"][0]["from"]} to {val["runs"][0]["to"]}.</p>'
    data = method.get("data", {})
    drows = "".join(f"<li><b>{s}</b>: {v}</li>" for s, v in data.items())
    return f"""<section id="method"><h2>How it was tested</h2>
<h3>Data</h3><p>NinjaTrader 8 downloaded 1-minute history for every contract from mid-2021 through the current front month (Rithmic feed). A small dump strategy
(<code>SMCBarDump</code>) then wrote out the exact 1-minute series NT8 feeds a Strategy Analyzer run: the merged, back-adjusted continuous contract, rolled on NT8's own rollover dates.
The replica reads that file, so both see identical bars. Trading starts {P['start']}; the three months before it only warm up the detectors.</p><ul>{drows}</ul>
<h3>Replica, and how closely it matches NinjaTrader</h3><p>A NinjaTrader run of five years of 1-minute data across four series takes minutes, too slow for thousands of combinations. The sweep uses a replica instead:
<code>SMCOrderBlockStrategy.cs</code> and <code>SMCZobEngines.cs</code> compiled <b>unchanged</b> against a small stand-in for the NinjaTrader API, fed the same four series in NT8's order
(bars that close at the same moment run in series order) and filled with the Strategy Analyzer's historical rules: market orders at the next 1-minute open, the stop and target live from the fill bar,
stop first when one bar touches both, targets only on trade-through and at their limit price, and every series' fills for a minute settled before any series updates on that minute. Presets run in NT8 and in the replica write the strategy's own closed-trade file, which is compared line by line:</p>{vrows}
<h3>Sweep</h3><ol>
<li><b>Stage A, structure grid</b> ({method.get("stageA", 1296):,} sets per market): timeframe pair (H4&rarr;M15, H1&rarr;M5, M15&rarr;M1) &times; target 0.5, 0.75, 1, 1.5, 2, 3 R &times; trend filter on/off &times; FVG off / confluence / required
&times; CISD liquidity sweep on/off &times; single or multi CISD and retest &times; direction (both, long only, short only).</li>
<li><b>Stage B, refinement</b>: the six best stage-A sets (at most two per timeframe pair) had every secondary input varied one at a time: displacement, swing strength, relative strength, trend gate and length,
mitigation and invalidation rules, CISD level and series length, CISD search window, OB expiry, opposite-block exit, ride-the-trend, break-even (three trigger distances) and the full target ladder. Each base moved to its best variant, and the round repeated (up to three rounds). Scored on in-sample data only.</li>
<li><b>Selection rule</b>: on in-sample data ({P['start']} to {P['is_end']}), keep sets with a profit factor above {b['pf_min']:.0f}, net profit &ge; {b['ndd_min']:.0f}&times; max drawdown, at least {b['trades_per_year_min']} trades a year and {b['min_losers']} losing trades;
pick the highest win rate (ties: higher net/DD). The out-of-sample years ({P['is_end']} to {P['end']}) are never used to choose.</li>
<li><b>Walk-forward</b>: the same rule re-run at {", ".join(c[:7] for c in P['wf_cuts'])}, each pick trading the following six months.</li>
<li><b>Monte Carlo</b>: 5,000 day-block bootstraps and 5,000 trade-order shuffles of the recommended set.</li>
<li><b>NinjaTrader confirmation</b>: each market's recommended set runs in NT8's Strategy Analyzer over the full five years with commission.</li></ol></section>"""


def caveats(packs):
    items = ["<li><b>Trades are rare.</b> One position at a time, and a setup needs a fresh higher-timeframe Order Block, a retest, and a CISD in the trend's direction. "
             "Expect weeks without a trade; small samples make every ratio noisy.</li>",
             "<li><b>Win-rate selection pulls the target in.</b> The highest win rates come with targets below 1R. Such a set needs its win rate to hold: a few points lower and the edge is gone. "
             "The Monte Carlo and walk-forward sections show how much room there is.</li>",
             "<li><b>No slippage modelled.</b> Market entries fill at the next 1-minute open and stops at their price. On the micros a tick of slippage per side costs "
             "$0.50 (MNQ, MYM), $1.25 (MES) or $1 (MGC) per contract per side.</li>",
             "<li><b>Back-adjusted prices.</b> Older contracts are shifted to line up with the current one, so 2021 prices in the trade lists are not the prices traded then. P&amp;L in points is unaffected.</li>",
             "<li><b>In-sample choices.</b> Thousands of sets were tried; the in-sample winner is optimistic by construction. The out-of-sample columns and the walk-forward are the fair estimate.</li>",
             "<li><b>Walk-forward pool.</b> At each cut-off the rule re-picks from every set the sweep tried, and the refinement that added some of those sets was steered by data through 2024. "
             "Cut-offs before 2025 therefore choose from a slightly better-informed pool than a trader would have had; read the walk-forward as a ceiling, not a floor.</li>",
             "<li><b>Live differences.</b> NT8 live checks break-even and ride-the-trend on bar close of the 1-minute series, as in this backtest; the MT5 EA checked every tick.</li>"]
    return '<section id="caveats"><h2>Know before you trade it</h2><ul>' + "".join(items) + "</ul></section>"


def run_block(packs, method):
    rows = "".join(f"<li><b>{p['symbol']}</b>: <code>Toreda &rsaquo; SMCPresets &rsaquo; SMC_{p['symbol']}_Rec</code></li>" for p in packs if p["rec"])
    return f"""<section id="run"><h2>Run it in NT8</h2><p>Each recommended set is compiled into NinjaTrader as a preset strategy with the inputs baked in and Execute trades on:</p><ul>{rows}</ul>
<p>Add it to a chart or the Strategy Analyzer on the front-month contract with 1-minute (or any) primary bars. The strategy adds its own Order Block, CISD and 1-minute series, and needs a few days of history to warm up.
To change an input, use <code>SMCOrderBlockStrategy</code> itself and copy the values from the tables above.</p></section>"""


if __name__ == "__main__":
    main()
