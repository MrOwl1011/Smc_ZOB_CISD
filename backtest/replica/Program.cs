using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using NinjaTrader.Cbi;

namespace SmcReplica
{
    /// <summary>
    /// dotnet SmcReplica.dll single --data DIR --symbol MNQ --front "MNQ 12-26" --from 2021-09-01 --to 2026-10-02
    ///        [--set Name=Value ...] [--trades out.csv] [--print] [--nt-defaults]
    /// dotnet SmcReplica.dll sweep  --data DIR --symbol MNQ --front "MNQ 12-26" --from ... --to ... --grid grid.json
    ///        --out DIR [--threads N]
    /// dotnet SmcReplica.dll defaults
    /// grid.json: { "base": { "Name": "Value", ... }, "sets": [ { "Name": "Value", ... }, ... ] }   (sets = explicit list)
    ///        or  { "base": {...}, "axes": { "Name": ["v1","v2"], ... } }                            (cartesian product)
    /// The sweep writes combos.csv (id + every swept input) and trades.csv (id + one row per trade), appending,
    /// so an interrupted sweep resumes where it stopped.
    /// </summary>
    public static class Program
    {
        public static int Main(string[] args)
        {
            CultureInfo.DefaultThreadCurrentCulture = CultureInfo.InvariantCulture;
            Thread.CurrentThread.CurrentCulture = CultureInfo.InvariantCulture;
            if (args.Length == 0) { Console.Error.WriteLine("usage: single|sweep|defaults ..."); return 2; }
            string mode = args[0];
            var opt = new Dictionary<string, string>(); var sets = new Dictionary<string, string>();
            for (int i = 1; i < args.Length; i++)
            {
                if (!args[i].StartsWith("--")) continue;
                string k = args[i].Substring(2);
                string v = i + 1 < args.Length && !args[i + 1].StartsWith("--") ? args[++i] : "true";
                if (k == "set") { int e = v.IndexOf('='); sets[v.Substring(0, e)] = v.Substring(e + 1); }
                else opt[k] = v;
            }
            if (mode == "defaults")
            {
                foreach (var kv in Runner.Defaults()) Console.WriteLine($"{kv.Key}={kv.Value}");
                return 0;
            }

            var sw = Stopwatch.StartNew();
            string sym = opt["symbol"];
            var spec = InstrumentSpec.For(sym, opt.GetValueOrDefault("front", sym + " 12-26"));
            if (opt.TryGetValue("commission", out var cps)) spec.CommissionPerSide = double.Parse(cps, CultureInfo.InvariantCulture);
            List<Bar> m1;
            if (opt.TryGetValue("series", out var seriesPath))
            {
                // NT8's own merged back-adjusted 1-minute series, dumped by SMCBarDump (preferred: no stitching)
                m1 = Data.LoadExport(seriesPath);
                Console.Error.WriteLine($"{sym}: NT8 continuous series {Path.GetFileName(seriesPath)}, {m1.Count} 1-min bars {m1[0].Time:yyyy-MM-dd} .. {m1[^1].Time:yyyy-MM-dd}");
            }
            else
            {
                string rolls = opt.GetValueOrDefault("rolls", Path.Combine(opt["data"], "..", "..", "rolls.json"));
                m1 = Data.LoadContinuous(opt["data"], sym, rolls, Console.Error);
            }
            var full = new Dataset(m1, spec);
            DateTime from = DateTime.Parse(opt["from"], CultureInfo.InvariantCulture), to = DateTime.Parse(opt["to"], CultureInfo.InvariantCulture);
            var ds = full.Slice(from, to);
            Console.Error.WriteLine($"window {from:yyyy-MM-dd} .. {to:yyyy-MM-dd}: {ds.M1.Count} 1-min bars, loaded in {sw.Elapsed.TotalSeconds:0.0}s");

            if (mode == "single")
            {
                sw.Restart();
                Action<string> print = opt.ContainsKey("print") ? (Action<string>)(s => Console.WriteLine(s)) : null;
                bool harness = !opt.ContainsKey("nt-defaults");
                if (opt.TryGetValue("userdir", out var ud)) { Directory.CreateDirectory(ud); NinjaTrader.Core.Globals.UserDataDir = ud; }
                var trades = Runner.Run(ds, sets, print, harness);
                Console.Error.WriteLine($"run: {trades.Count} trades in {sw.Elapsed.TotalSeconds:0.0}s");
                Summarize(trades, Console.Out);
                if (opt.TryGetValue("trades", out var tp)) WriteTrades(tp, trades, null, false);
                return 0;
            }
            if (mode == "sweep") return Sweep(ds, opt);
            Console.Error.WriteLine("unknown mode " + mode);
            return 2;
        }

        private static int Sweep(Dataset ds, Dictionary<string, string> opt)
        {
            string outDir = opt["out"]; Directory.CreateDirectory(outDir);
            using var doc = JsonDocument.Parse(File.ReadAllText(opt["grid"]));
            var root = doc.RootElement;
            var baseSet = new Dictionary<string, string>();
            if (root.TryGetProperty("base", out var be)) foreach (var p in be.EnumerateObject()) baseSet[p.Name] = Str(p.Value);
            var combos = new List<Dictionary<string, string>>();
            if (root.TryGetProperty("sets", out var se))
                foreach (var s in se.EnumerateArray()) { var d = new Dictionary<string, string>(); foreach (var p in s.EnumerateObject()) d[p.Name] = Str(p.Value); combos.Add(d); }
            if (root.TryGetProperty("axes", out var ax))
            {
                var axes = ax.EnumerateObject().Select(p => (p.Name, p.Value.EnumerateArray().Select(Str).ToList())).ToList();
                var acc = new List<Dictionary<string, string>> { new Dictionary<string, string>() };
                foreach (var (name, vals) in axes)
                    acc = acc.SelectMany(a => vals.Select(v => new Dictionary<string, string>(a) { [name] = v })).ToList();
                combos.AddRange(acc);
            }
            var keys = combos.SelectMany(c => c.Keys).Distinct().OrderBy(k => k).ToList();
            string Key(Dictionary<string, string> c) => string.Join("|", keys.Select(k => k + "=" + c.GetValueOrDefault(k, "")));

            string combosPath = Path.Combine(outDir, "combos.csv"), tradesPath = Path.Combine(outDir, "trades.csv");
            var done = new HashSet<string>(); int nextId = 0;
            if (File.Exists(combosPath))
                foreach (var line in File.ReadLines(combosPath).Skip(1))
                {
                    var f = line.Split(',');
                    nextId = Math.Max(nextId, int.Parse(f[0]) + 1);
                    done.Add(f[^1]);
                }
            var todo = combos.Where(c => !done.Contains(Key(c))).ToList();
            Console.Error.WriteLine($"sweep: {combos.Count} combos, {combos.Count - todo.Count} already done, {todo.Count} to run");
            if (!File.Exists(combosPath)) File.WriteAllText(combosPath, "id,trades,net,key\n");
            if (!File.Exists(tradesPath)) File.WriteAllText(tradesPath, "id,entry_time,exit_time,dir,entry,exit,qty,profit,exit_name\n");

            int threads = int.Parse(opt.GetValueOrDefault("threads", Math.Max(1, Environment.ProcessorCount - 2).ToString()));
            object gate = new object(); int finished = 0; var sw = Stopwatch.StartNew();
            // warm the shared series once so threads do not all resample at the same time
            ds.Series(1); foreach (int m in new[] { 5, 15, 60, 240 }) ds.Series(m);
            Parallel.ForEach(todo, new ParallelOptions { MaxDegreeOfParallelism = threads }, c =>
            {
                var p = new Dictionary<string, string>(baseSet);
                foreach (var kv in c) p[kv.Key] = kv.Value;
                List<Trade> trades;
                try { trades = Runner.Run(ds, p); }
                catch (Exception ex) { Console.Error.WriteLine($"FAILED {Key(c)}: {ex.Message}"); return; }
                lock (gate)
                {
                    int id = nextId++;
                    WriteTrades(tradesPath, trades, id.ToString(), true);
                    File.AppendAllText(combosPath, $"{id},{trades.Count},{trades.Sum(t => t.ProfitCurrency):0.00},{Key(c)}\n");
                    finished++;
                    if (finished % 10 == 0 || finished == todo.Count)
                        Console.Error.WriteLine($"{finished}/{todo.Count} combos, {sw.Elapsed.TotalMinutes:0.0} min, eta {sw.Elapsed.TotalMinutes / finished * (todo.Count - finished):0} min");
                }
            });
            return 0;
        }

        private static string Str(JsonElement e) => e.ValueKind == JsonValueKind.String ? e.GetString() : e.GetRawText();

        public static void WriteTrades(string path, List<Trade> trades, string id, bool append)
        {
            var sb = new StringBuilder();
            if (!append) sb.Append("entry_time,exit_time,dir,entry,exit,qty,profit,exit_name\n");
            foreach (var t in trades)
            {
                if (id != null) sb.Append(id).Append(',');
                sb.Append(t.EntryTime.ToString("yyyy-MM-dd HH:mm")).Append(',').Append(t.ExitTime.ToString("yyyy-MM-dd HH:mm")).Append(',')
                  .Append(t.IsLong ? "L" : "S").Append(',').Append(t.EntryPrice.ToString("0.#####")).Append(',').Append(t.ExitPrice.ToString("0.#####")).Append(',')
                  .Append(t.Quantity).Append(',').Append(t.ProfitCurrency.ToString("0.00")).Append(',').Append(t.ExitName).Append('\n');
            }
            if (append) File.AppendAllText(path, sb.ToString()); else File.WriteAllText(path, sb.ToString());
        }

        private static void Summarize(List<Trade> trades, TextWriter w)
        {
            double net = 0, peak = 0, dd = 0, gp = 0, gl = 0; int wins = 0;
            foreach (var t in trades)
            {
                net += t.ProfitCurrency; peak = Math.Max(peak, net); dd = Math.Max(dd, peak - net);
                if (t.ProfitCurrency > 0) { wins++; gp += t.ProfitCurrency; } else gl -= t.ProfitCurrency;
            }
            w.WriteLine($"trades {trades.Count}  net {net:0.00}  win% {(trades.Count > 0 ? 100.0 * wins / trades.Count : 0):0.0}  PF {(gl > 0 ? gp / gl : 0):0.00}  maxDD {dd:0.00}  net/DD {(dd > 0 ? net / dd : 0):0.00}");
        }
    }
}
