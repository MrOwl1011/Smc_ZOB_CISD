using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Reflection;
using NinjaTrader.Cbi;
using NinjaTrader.NinjaScript;
using NinjaTrader.NinjaScript.Strategies;
using NinjaTrader.NinjaScript.Strategies.Toreda;

namespace SmcReplica
{
    public class InstrumentSpec
    {
        public string Symbol, FullName;
        public double TickSize, PointValue, CommissionPerSide;

        public static InstrumentSpec For(string sym, string front)
        {
            switch (sym.ToUpperInvariant())
            {
                case "MNQ": return new InstrumentSpec { Symbol = "MNQ", FullName = front, TickSize = 0.25, PointValue = 2.0, CommissionPerSide = 0.95 };
                case "MES": return new InstrumentSpec { Symbol = "MES", FullName = front, TickSize = 0.25, PointValue = 5.0, CommissionPerSide = 0.95 };
                case "MYM": return new InstrumentSpec { Symbol = "MYM", FullName = front, TickSize = 1.0, PointValue = 0.5, CommissionPerSide = 0.95 };
                case "MGC": return new InstrumentSpec { Symbol = "MGC", FullName = front, TickSize = 0.1, PointValue = 10.0, CommissionPerSide = 1.20 };
            }
            throw new ArgumentException("unknown symbol " + sym);
        }
    }

    /// <summary>The 1-minute history of one instrument and its resampled series, shared read-only by every run.</summary>
    public class Dataset
    {
        public readonly List<Bar> M1;
        public readonly InstrumentSpec Spec;
        private readonly ConcurrentDictionary<int, SeriesData> cache = new ConcurrentDictionary<int, SeriesData>();

        public Dataset(List<Bar> m1, InstrumentSpec spec) { M1 = m1; Spec = spec; }

        public SeriesData Series(int minutes)
        {
            return cache.GetOrAdd(minutes, m =>
            {
                var bars = Data.Resample(M1, m);
                return new SeriesData
                {
                    T = bars.Select(b => b.Time).ToArray(), O = bars.Select(b => b.Open).ToArray(),
                    H = bars.Select(b => b.High).ToArray(), L = bars.Select(b => b.Low).ToArray(), C = bars.Select(b => b.Close).ToArray()
                };
            });
        }

        /// <summary>NT8 Strategy Analyzer starts on a TRADING day, which opens at 18:00 ET the evening before.</summary>
        public Dataset Slice(DateTime from, DateTime to)
        {
            DateTime t0 = from.Date.AddDays(-1).AddHours(18), t1 = to.Date.AddDays(1).AddHours(-6);   // through 18:00 of the end date's session
            return new Dataset(M1.Where(b => b.Time > t0 && b.Time <= t1).ToList(), Spec);
        }
    }

    public static class Runner
    {
        /// <summary>Harness defaults applied on top of the strategy's SetDefaults: trading on, nothing
        /// that only prints, draws or writes files (none of it feeds a decision).</summary>
        public static readonly Dictionary<string, string> HarnessDefaults = new Dictionary<string, string>
        {
            { "EnableTrading", "true" }, { "ConfidenceLog", "false" }, { "ResultFile", "" }, { "ConfidenceFile", "" },
            { "ShowZones", "false" }, { "DebugLogLevel", "Off" }, { "EntryAlert", "false" }, { "AlertsEnabled", "false" }
        };

        public static List<Trade> Run(Dataset ds, IDictionary<string, string> parameters, Action<string> print = null, bool harnessDefaults = true)
        {
            var s = new SMCOrderBlockStrategy();
            s.Instrument = new Instrument
            {
                FullName = ds.Spec.FullName,
                MasterInstrument = new MasterInstrument { Name = ds.Spec.Symbol, TickSize = ds.Spec.TickSize, PointValue = ds.Spec.PointValue }
            };
            s.CommissionPerSide = ds.Spec.CommissionPerSide;
            s.PrintSink = print;
            s.RaiseStateChange(State.SetDefaults);
            if (harnessDefaults) Apply(s, HarnessDefaults);
            Apply(s, parameters);
            s.RaiseStateChange(State.Configure);

            // BIP 0 = the Analyzer's primary series (1 minute in every run of this study), then the
            // series the strategy added, in order.
            var mins = new List<int> { 1 };
            mins.AddRange(s.requestedMinutes);
            var series = mins.Select(m => { var sh = ds.Series(m); return new SeriesData { T = sh.T, O = sh.O, H = sh.H, L = sh.L, C = sh.C }; }).ToArray();
            s.BindSeries(series);
            s.RaiseStateChange(State.DataLoaded);
            s.RaiseStateChange(State.Historical);

            // NT8 processes every series' bars in time order; bars closing at the same moment go in BIP order.
            int n = series.Length;
            var next = new int[n];
            // NT8 settles every series' fills for the bars stamped T before any OnBarUpdate at T, so an order
            // sent from one series' update fills at the next bar of its own series, never a bar stamped the same moment.
            var group = new List<int>(n);
            while (true)
            {
                DateTime best = DateTime.MaxValue;
                for (int b = 0; b < n; b++)
                    if (next[b] < series[b].Count && series[b].T[next[b]] < best) best = series[b].T[next[b]];
                if (best == DateTime.MaxValue) break;
                group.Clear();
                for (int b = 0; b < n; b++)
                    if (next[b] < series[b].Count && series[b].T[next[b]] == best) group.Add(b);
                foreach (int b in group) s.ProcessFills(b, next[b]);
                foreach (int b in group)
                {
                    series[b].Cur = next[b]++;
                    s.RaiseBarUpdate(b);
                }
            }
            s.CloseAtEnd();
            s.RaiseStateChange(State.Terminated);
            return s.SystemPerformance.AllTrades.list;
        }

        public static void Apply(object target, IDictionary<string, string> values)
        {
            if (values == null) return;
            var t = target.GetType();
            foreach (var kv in values)
            {
                var p = t.GetProperty(kv.Key, BindingFlags.Public | BindingFlags.Instance);
                if (p == null) throw new ArgumentException("no strategy input named " + kv.Key);
                object v;
                var pt = p.PropertyType;
                if (pt.IsEnum) v = Enum.Parse(pt, kv.Value, true);
                else if (pt == typeof(bool)) v = bool.Parse(kv.Value);
                else if (pt == typeof(int)) v = int.Parse(kv.Value, CultureInfo.InvariantCulture);
                else if (pt == typeof(double)) v = double.Parse(kv.Value, CultureInfo.InvariantCulture);
                else v = kv.Value;
                p.SetValue(target, v);
            }
        }

        public static Dictionary<string, string> Defaults()
        {
            var s = new SMCOrderBlockStrategy();
            s.RaiseStateChange(State.SetDefaults);
            var d = new Dictionary<string, string>();
            foreach (var p in typeof(SMCOrderBlockStrategy).GetProperties(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly))
                d[p.Name] = Convert.ToString(p.GetValue(s), CultureInfo.InvariantCulture);
            return d;
        }
    }
}
