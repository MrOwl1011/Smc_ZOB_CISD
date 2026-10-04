using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace SmcReplica
{
    /// <summary>One bar stamped with its CLOSE time in US/Eastern (NT8's Time[0] on this install).</summary>
    public struct Bar
    {
        public DateTime Time;
        public double Open, High, Low, Close;
    }

    public static class Data
    {
        private static readonly TimeZoneInfo Et = TimeZoneInfo.FindSystemTimeZoneById("Eastern Standard Time");

        /// <summary>NT8 Historical Data export (yyyyMMdd HHmmss;o;h;l;c;v, UTC, bar-close stamps) -> ET bars.</summary>
        public static List<Bar> LoadExport(string path)
        {
            var bars = new List<Bar>(1 << 18);
            foreach (string raw in File.ReadLines(path))
            {
                string line = raw.Trim();
                if (line.Length < 20) continue;
                string[] f = line.Split(';');
                if (f.Length < 5) continue;
                if (!DateTime.TryParseExact(f[0], "yyyyMMdd HHmmss", CultureInfo.InvariantCulture, DateTimeStyles.None, out DateTime t)) continue;
                t = TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(t, DateTimeKind.Utc), Et);
                bars.Add(new Bar
                {
                    Time = DateTime.SpecifyKind(t, DateTimeKind.Unspecified),
                    Open = double.Parse(f[1], CultureInfo.InvariantCulture),
                    High = double.Parse(f[2], CultureInfo.InvariantCulture),
                    Low = double.Parse(f[3], CultureInfo.InvariantCulture),
                    Close = double.Parse(f[4], CultureInfo.InvariantCulture)
                });
            }
            bars.Sort((a, b) => a.Time.CompareTo(b.Time));
            var dedup = new List<Bar>(bars.Count);
            foreach (var b in bars) if (dedup.Count == 0 || dedup[^1].Time != b.Time) dedup.Add(b);
            return dedup;
        }

        /// <summary>Continuous back-adjusted 1-minute series for <paramref name="symbol"/> from every
        /// &lt;SYM&gt;-&lt;MMYY&gt;-1min.txt in <paramref name="dir"/>, rolled on NT8's own rollover dates
        /// (rolls.json), the way NT8's MergeBackAdjusted series is built (same rules as the
        /// dms-sun-engine harness, which matched NT8 trade for trade).</summary>
        public static List<Bar> LoadContinuous(string dir, string symbol, string rollsPath, TextWriter log)
        {
            var files = Directory.GetFiles(dir, symbol + "-*-1min.txt").ToList();
            if (files.Count == 0) throw new FileNotFoundException("no exports for " + symbol + " in " + dir);
            var map = File.Exists(rollsPath)
                ? JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(rollsPath))
                : new Dictionary<string, string>();
            var contracts = new List<List<Bar>>();
            var rolls = new List<DateTime>();
            foreach (var f in files)
            {
                var b = LoadExport(f);
                if (b.Count == 0) continue;
                contracts.Add(b);
                string key = Path.GetFileName(f).Replace("-1min.txt", "");
                rolls.Add(map.TryGetValue(key, out var d) ? DateTime.Parse(d, CultureInfo.InvariantCulture) : DateTime.MinValue);
            }
            var r = Stitch(contracts, rolls, out var rollLog);
            foreach (var l in rollLog) log?.WriteLine(l);
            log?.WriteLine($"{symbol}: {files.Count} contracts, {rolls.Count(x => x != DateTime.MinValue)} with NT8 roll dates, {r.Count} 1-min bars {r[0].Time:yyyy-MM-dd} .. {r[^1].Time:yyyy-MM-dd}");
            return r;
        }

        public static List<Bar> Stitch(List<List<Bar>> contracts, List<DateTime> rollDates, out List<string> log)
        {
            log = new List<string>();
            var order = Enumerable.Range(0, contracts.Count).ToList();
            DateTime StartOf(int i) => rollDates[i] != DateTime.MinValue ? rollDates[i] : contracts[i][0].Time;
            order.Sort((a, b) => StartOf(a).CompareTo(StartOf(b)));
            contracts = order.Select(i => contracts[i]).ToList();
            rollDates = order.Select(i => rollDates[i]).ToList();

            var offsets = new double[contracts.Count];
            for (int c = contracts.Count - 2; c >= 0; c--)
            {
                var older = contracts[c];
                var newer = contracts[c + 1];
                DateTime roll = StartOf(c + 1);
                var byTime = new Dictionary<DateTime, double>();
                foreach (var b in newer) byTime[b.Time] = b.Close;
                var diffs = new List<double>();
                foreach (var b in older)
                    if (Math.Abs((b.Time - roll).TotalDays) <= 3 && byTime.TryGetValue(b.Time, out double nc)) diffs.Add(nc - b.Close);
                if (diffs.Count < 30)
                    foreach (var b in older)
                        if (byTime.TryGetValue(b.Time, out double nc)) diffs.Add(nc - b.Close);
                double gap;
                if (diffs.Count >= 30)
                {
                    diffs.Sort();
                    gap = diffs[diffs.Count / 2];
                    log.Add($"roll @ {roll:yyyy-MM-dd}: {diffs.Count} overlapping bars, median basis {gap:+0.00;-0.00}");
                }
                else
                {
                    Bar last = older[^1];
                    Bar first = newer.FirstOrDefault(b => b.Time >= roll);
                    if (first.Time == default) first = newer[0];
                    gap = first.Open - last.Close;
                    log.Add($"roll @ {roll:yyyy-MM-dd}: no overlap, next-open minus last-close {gap:+0.00;-0.00}");
                }
                offsets[c] = offsets[c + 1] + gap;
            }

            var result = new List<Bar>();
            DateTime cutoff = DateTime.MinValue;
            for (int c = 0; c < contracts.Count; c++)
            {
                DateTime start = StartOf(c);
                DateTime stop = c + 1 < contracts.Count ? StartOf(c + 1) : DateTime.MaxValue;
                foreach (var b0 in contracts[c])
                {
                    if (b0.Time <= cutoff || b0.Time < start || b0.Time >= stop) continue;
                    if (!InSession(b0.Time)) continue;
                    var b = b0;
                    b.Open += offsets[c]; b.High += offsets[c]; b.Low += offsets[c]; b.Close += offsets[c];
                    result.Add(b);
                    cutoff = b.Time;
                }
            }
            return result;
        }

        /// <summary>Close-stamped ET bar inside the CME Globex session (Sun 18:00 -> Fri 17:00, daily 17:00-18:00 break).
        /// Index futures and metals share these hours.</summary>
        public static bool InSession(DateTime et)
        {
            int m = et.Hour * 60 + et.Minute;
            switch (et.DayOfWeek)
            {
                case DayOfWeek.Saturday: return false;
                case DayOfWeek.Sunday: return m > 18 * 60;
                case DayOfWeek.Friday: return m <= 17 * 60;
                default: return m <= 17 * 60 || m > 18 * 60;
            }
        }

        /// <summary>Start of the trading session (18:00 ET of the previous calendar day) that holds a close-stamped bar.</summary>
        public static DateTime SessionStart(DateTime closeStamp)
        {
            DateTime open = closeStamp.AddMinutes(-1);
            DateTime d = open.Date.AddHours(18);
            return open >= d ? d : d.AddDays(-1);
        }

        /// <summary>
        /// NT8 minute bars of <paramref name="minutes"/> built from 1-minute bars: buckets anchored on the
        /// session open (18:00 ET), the bar stamped with the bucket end, or with the last minute of the
        /// session when the session ends inside the bucket (NT8 "Break at EOD"; e.g. the 14:00-17:00 H4 bar).
        /// </summary>
        public static List<Bar> Resample(List<Bar> m1, int minutes)
        {
            if (minutes <= 1) return m1;
            var res = new List<Bar>(m1.Count / minutes + 16);
            DateTime curSession = DateTime.MinValue; long curKey = long.MinValue;
            Bar acc = default; bool open = false; DateTime bucketEnd = default;
            for (int i = 0; i < m1.Count; i++)
            {
                Bar b = m1[i];
                DateTime ss = SessionStart(b.Time);
                long key = (long)((b.Time - ss).TotalMinutes - 1) / minutes;
                if (ss != curSession || key != curKey)
                {
                    if (open) { res.Add(Finish(acc, bucketEnd, m1, i)); }
                    curSession = ss; curKey = key;
                    acc = b;
                    bucketEnd = ss.AddMinutes((key + 1) * minutes);
                    open = true;
                }
                else
                {
                    acc.High = Math.Max(acc.High, b.High);
                    acc.Low = Math.Min(acc.Low, b.Low);
                    acc.Close = b.Close;
                    acc.Time = b.Time;          // last constituent so far
                }
            }
            if (open) res.Add(Finish(acc, bucketEnd, m1, m1.Count));
            return res;
        }

        // A bucket closes at its end, unless the session ends inside it: then at the session close
        // (17:00 ET on a normal day; on an early-close holiday the quarter hour where the data stops).
        private static Bar Finish(Bar acc, DateTime bucketEnd, List<Bar> m1, int nextIndex)
        {
            DateTime lastMinute = acc.Time;
            bool sessionEnds = nextIndex >= m1.Count || SessionStart(m1[nextIndex].Time) != SessionStart(lastMinute);
            DateTime stamp = bucketEnd;
            if (sessionEnds)
            {
                int rem = lastMinute.Minute % 15;
                DateTime close = rem == 0 ? lastMinute : lastMinute.AddMinutes(15 - rem);
                if (close < bucketEnd) stamp = close;
            }
            acc.Time = stamp;
            return acc;
        }
    }
}
