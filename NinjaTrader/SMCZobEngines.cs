//+------------------------------------------------------------------+
//|                                                 SMCZobEngines.cs |
//|  NinjaTrader 8 port of the SMC Order Block EA detection engines.  |
//|                                                                  |
//|  Line-for-line ports of:                                         |
//|   SMC_OB_Types.mqh / SMC_OB_MarketData.mqh                       |
//|   SMC_OB_Structure.mqh      (CSMCStructure  -> SmcStructure)     |
//|   SMC_OB_Displacement.mqh   (CSMCDisplacement -> SmcDisplacement)|
//|   SMC_OB_FVG.mqh            (CSMCFVG        -> SmcFvg)           |
//|   SMC_OB_Engine.mqh         (CSMCDetector   -> SmcDetector)      |
//|   SMC_CISD_Engine.mqh       (CSMCCISDEngine -> SmcCisdEngine)    |
//|   SMC_Connect_Engine.mqh    (CSMCConnection -> SmcConnection)    |
//|   SMC_OB_Guards.mqh         (CSMCCapitalGuard -> SmcCapitalGuard)|
//|   SMC_OB_Confidence.mqh     (SMC_Confidence -> SmcConfidence)    |
//|                                                                  |
//|  INDEXING CONVENTION (unchanged from MQL5):                      |
//|  All price arrays passed to the engines are in *series* order:   |
//|     r[0]      = newest CLOSED bar in the window                  |
//|     r[i + k]  = k bars OLDER than r[i]                           |
//|  Times are seconds, and a bar's time is its OPEN time (MT5       |
//|  semantics). The strategy converts NinjaTrader's bar-close       |
//|  timestamps before anything reaches these classes.               |
//|                                                                  |
//|  MQL structs are value types: wherever MQL copied a record, the  |
//|  port calls Clone() so no record is shared by reference.         |
//+------------------------------------------------------------------+
using System;
using System.Collections.Generic;
using System.Globalization;

namespace NinjaTrader.NinjaScript.Strategies.SMCZob
{
    #region Enums (SMC_OB_Types.mqh, SMC_CISD_Engine.mqh, SMC_Connect_Engine.mqh, SMC_OB_Guards.mqh)

    public enum SmcBosMode { Close = 0, CloseAtrBuffer = 1 }
    public enum SmcZoneMode { Wick = 0, Body = 1, OpenToExtreme = 2, OpenLastExtreme = 3 }
    public enum SmcZoneSource { LastCandle = 0, CandleSeries = 1 }
    public enum SmcFvgMode { Off = 0, Confluence = 1, Required = 2 }
    public enum SmcMitigationMode { Off = 0, Touch = 1, Midpoint = 2, Full = 3 }
    public enum SmcInvalidationMode { Off = 0, CloseBeyond = 1, WickBeyond = 2 }
    public enum SmcOverlapMode { KeepAll = 0, SkipNew = 1, SupersedeOld = 2 }
    public enum SmcLogLevel { Off = 0, Events = 1, Verbose = 2 }
    public enum SmcObState { Active = 0, Retested, Mitigated, Invalidated, Expired, Superseded }
    public enum SmcEventType { Swing = 0, Bos, ObCreated, ObFvgLinked, ObRetest, ObMitigated, ObInvalidated, ObExpired, ObSuperseded, ObRemoved }
    public enum SmcReject
    {
        None = 0, DirectionDisabled, InsufficientData, BosCandleOpposite, NoOppositeCandle, WeakMove, WeakCandle,
        SmallBody, WeakRelative, LegViolatesOb, ZeroZone, FvgMissing, Overlap, Duplicate, SeriesTooLong
    }
    // HTF is the Order Block timeframe, the CISD timeframe is tied to it
    public enum SmcTfPair { H4_M15 = 0, H1_M5 = 1, M15_M1 = 2 }

    public enum CisdSweepMode { TradeThrough = 0, Rejection = 1 }
    public enum CisdLevelMode { SeriesRange = 0, SeriesOpen = 1 }
    public enum CisdActivation { AllAfter = 0, ConfirmAfter = 1 }
    public enum CisdMachine { Waiting = 0, LiquiditySweep, WaitForClose }
    public enum CisdState { Setup = 0, SetupFailed, SetupReplaced, Confirmed, Retraced, Invalidated, Expired }
    public enum CisdEventType { Sweep = 0, Setup, SetupFailed, Confirmed, Retraced, Invalidated, Expired }

    public enum ConnCisdMode { Single = 0, Multi = 1 }
    public enum ConnRetestMode { Single = 0, Multi = 1 }
    public enum ConnState
    {
        ObCreated = 0, WaitingForRetest, ObRetested, CisdMonitoring, CisdSweepDetected, CisdConfirmed,
        Retracement, Completed, Invalidated, Expired
    }
    public enum ConnEventType { Retest = 0, Activated, Sweep, Confirmed, Retraced, Completed, Invalidated, Expired, ObInvalidated }

    public enum GuardBlock { Ok = 0, DailyLoss, WeeklyLoss, ConsecLosses, EquityStop, Spread, Volatility }

    #endregion

    #region Shared helpers

    //--- MqlRates equivalent. time = bar OPEN time in seconds.
    public struct Rates
    {
        public long time;
        public double open;
        public double high;
        public double low;
        public double close;
    }

    //--- logging / formatting hooks supplied by the strategy
    public class SmcEnv
    {
        public Action<string> Print = delegate (string s) { };
        public Func<double, string> Price = delegate (double p) { return p.ToString("0.#####", CultureInfo.InvariantCulture); };

        public static readonly DateTime Epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Unspecified);
        public static long ToSec(DateTime t) { return (t.Ticks - Epoch.Ticks) / TimeSpan.TicksPerSecond; }
        public static DateTime FromSec(long s) { return new DateTime(Epoch.Ticks + s * TimeSpan.TicksPerSecond, DateTimeKind.Unspecified); }
        public static string T(long s) { return FromSec(s).ToString("yyyy.MM.dd HH:mm", CultureInfo.InvariantCulture); }
    }

    public static class Smc
    {
        public const int DIR_BULL = 1;
        public const int DIR_BEAR = -1;

        //--- SMC_OB_MarketData.mqh
        public static double Body(Rates b) { return Math.Abs(b.close - b.open); }
        public static double Range(Rates b) { return b.high - b.low; }
        public static bool IsBullish(Rates b) { return b.close > b.open; }
        public static bool IsBearish(Rates b) { return b.close < b.open; }

        //--- candle colour matches a direction (+1 bullish, -1 bearish); dojis match neither
        public static bool IsDirCandle(Rates b, int dir) { return dir == DIR_BULL ? IsBullish(b) : IsBearish(b); }

        public static double BodyPct(Rates b)
        {
            double rng = Range(b);
            return rng > 0.0 ? Body(b) / rng * 100.0 : 0.0;
        }

        //--- True range of bar i (needs the previous close at i+1)
        public static double TrueRange(Rates[] r, int i, int size)
        {
            if (i + 1 >= size)
                return Range(r[i]);
            double pc = r[i + 1].close;
            return Math.Max(r[i].high, pc) - Math.Min(r[i].low, pc);
        }

        //--- Simple-average ATR over bars i .. i+period-1. Returns 0 if not enough data.
        public static double ATR(Rates[] r, int i, int size, int period)
        {
            if (period <= 0 || i < 0 || i + period >= size)
                return 0.0;
            double sum = 0.0;
            for (int k = i; k < i + period; k++)
                sum += TrueRange(r, k, size);
            return sum / period;
        }

        //--- Average candle body over bars i .. i+period-1. Returns -1 if not enough data.
        public static double AvgBody(Rates[] r, int i, int size, int period)
        {
            if (period <= 0 || i < 0 || i + period > size)
                return -1.0;
            double sum = 0.0;
            for (int k = i; k < i + period; k++)
                sum += Body(r[k]);
            return sum / period;
        }

        public static string DirText(int dir) { return dir == DIR_BULL ? "Bull" : "Bear"; }

        //--- "Live" = still relevant to price (monitored for retest/invalidation)
        public static bool IsLiveState(SmcObState s)
        {
            return s == SmcObState.Active || s == SmcObState.Retested || s == SmcObState.Mitigated;
        }

        //--- pair -> ENUM_CISD_TF index (0 Chart, 1 M1, 2 M5, 3 M15, 4 M30, 5 H1, 6 H4, 7 D1)
        public static int PairOBIndex(int pair)
        {
            switch (pair)
            {
                case (int)SmcTfPair.H1_M5: return 5;
                case (int)SmcTfPair.M15_M1: return 3;
                default: return 6;
            }
        }

        public static int PairCISDIndex(int pair)
        {
            switch (pair)
            {
                case (int)SmcTfPair.H1_M5: return 2;
                case (int)SmcTfPair.M15_M1: return 1;
                default: return 3;
            }
        }

        //--- SMC_CISDTimeframe, in minutes (index 0 "current chart" is never produced by a pair)
        public static int IndexMinutes(int idx)
        {
            switch (idx)
            {
                case 1: return 1;
                case 2: return 5;
                case 3: return 15;
                case 4: return 30;
                case 5: return 60;
                case 6: return 240;
                case 7: return 1440;
                default: return 0;
            }
        }

        public static string TFText(int seconds)
        {
            switch (seconds)
            {
                case 60: return "M1";
                case 300: return "M5";
                case 900: return "M15";
                case 1800: return "M30";
                case 3600: return "H1";
                case 14400: return "H4";
                case 86400: return "D1";
            }
            return (seconds / 60).ToString(CultureInfo.InvariantCulture) + "min";
        }

        public static string RejectText(SmcReject r)
        {
            switch (r)
            {
                case SmcReject.None: return "none";
                case SmcReject.DirectionDisabled: return "direction disabled";
                case SmcReject.InsufficientData: return "insufficient data";
                case SmcReject.BosCandleOpposite: return "BOS candle is opposite colour (no displacement)";
                case SmcReject.NoOppositeCandle: return "no opposite candle within max OB->BOS distance";
                case SmcReject.WeakMove: return "displacement net move below ATR threshold";
                case SmcReject.WeakCandle: return "strongest displacement body below ATR threshold";
                case SmcReject.SmallBody: return "strongest displacement candle body % too small";
                case SmcReject.WeakRelative: return "displacement weak relative to prior candles";
                case SmcReject.LegViolatesOb: return "displacement leg traded beyond OB far edge";
                case SmcReject.ZeroZone: return "zero-height zone";
                case SmcReject.FvgMissing: return "FVG required but not formed";
                case SmcReject.Overlap: return "overlaps existing live OB";
                case SmcReject.Duplicate: return "duplicate OB";
                case SmcReject.SeriesTooLong: return "ZOrder series start not within lookback";
            }
            return "unknown";
        }

        public static string F2(double v) { return v.ToString("0.00", CultureInfo.InvariantCulture); }
    }

    #endregion

    #region Records (SMC_OB_Types.mqh)

    //--- Detection settings
    public struct SmcSettings
    {
        //--- market structure
        public int swingLength;
        public double swingMinATR;
        public SmcBosMode bosMode;
        public double bosBufferATR;
        //--- displacement
        public int atrPeriod;
        public double dispATRMult;
        public double dispCandleATRMult;
        public double dispMinBodyPct;
        public double dispMinRelStrength;
        public int maxOBToBOSBars;
        public bool rejectLegViolation;
        //--- order block
        public SmcZoneMode zoneMode;
        public SmcZoneSource zoneSource;
        public SmcOverlapMode overlapMode;
        public double overlapPct;
        public int maxActivePerDir;
        public int maxAgeBars;
        public int maxStored;
        public bool enableBull;
        public bool enableBear;
        //--- FVG
        public SmcFvgMode fvgMode;
        public double fvgMinATR;
        //--- retest / mitigation
        public bool retestEnabled;
        public SmcMitigationMode mitigationMode;
        public SmcInvalidationMode invalidationMode;
        //--- misc
        public SmcLogLevel logLevel;
    }

    public class SmcSwing
    {
        public int type;            // DIR_BULL = swing high, DIR_BEAR = swing low
        public long time;           // swing candle open time
        public double price;
        public long confirmTime;    // bar whose close confirmed the swing
        public bool broken;
        public long brokenTime;
        public SmcSwing Clone() { return (SmcSwing)MemberwiseClone(); }
    }

    public struct SmcBos
    {
        public int dir;
        public long barTime;
        public double closePrice;
        public double level;
        public long swingTime;
        public bool isChoch;
    }

    public struct SmcDisplacementResult
    {
        public SmcReject reject;
        public int obIndex;
        public int legBars;
        public double atr;
        public double netMove;
        public double strongestBody;
        public double strongestBodyPct;
        public double relStrength;
    }

    public struct SmcFvgResult
    {
        public bool found;
        public long leftTime;
        public long midTime;
        public long rightTime;
        public double top;
        public double bottom;
    }

    public class SmcOrderBlock
    {
        //--- identity (immutable after confirmation)
        public long id;
        public int dir;
        public long obTime;
        public long confirmTime;
        public double top;
        public double bottom;
        public double mid;
        public double candleOpen;
        public double candleHigh;
        public double candleLow;
        public double candleClose;
        public long bosTime;
        public double bosLevel;
        public long swingTime;
        public bool isChoch;
        public int legBars;
        public double atr;
        public double netMove;
        public double strongestBodyPct;
        public double relStrength;
        public long overlapWithId;
        public bool isZOrder;
        public int seriesCount;
        public long seriesStartTime;
        //--- FVG confluence
        public bool hasFVG;
        public bool fvgLate;
        public bool fvgPending;
        public long fvgLeftTime;
        public long fvgRightTime;
        public double fvgTop;
        public double fvgBottom;
        //--- life-cycle
        public SmcObState state;
        public int barsMonitored;
        public int retestCount;
        public bool touchingPrev;
        public long firstRetestTime;
        public double firstRetestPrice;
        public long mitigatedTime;
        public long invalidatedTime;
        public long endTime;
        public long expiredTime;
        public bool liveInside;

        public SmcOrderBlock Clone() { return (SmcOrderBlock)MemberwiseClone(); }
    }

    public struct SmcEvent
    {
        public SmcEventType type;
        public long obId;
        public int dir;
        public long time;
        public double price;
        public long time2;
        public double price2;
        public bool flag;
        public bool historical;
    }

    public struct SmcStats
    {
        public int barsProcessed, swingHighs, swingLows, bosBull, bosBear, choch;
        public int rejDisabled, rejData, rejBosOpposite, rejNoOpposite, rejWeakMove, rejWeakCandle, rejSmallBody;
        public int rejWeakRelative, rejLegViolation, rejZeroZone, rejFVGMissing, rejOverlap, duplicates, rejSeriesTooLong;
        public int obBull, obBear, fvgLinked, retests, mitigations, invalidations, expired, superseded;
    }

    #endregion

    #region Market structure (SMC_OB_Structure.mqh)

    public class SmcStructure
    {
        private readonly List<SmcSwing> m_highs = new List<SmcSwing>();   // chronological (oldest first)
        private readonly List<SmcSwing> m_lows = new List<SmcSwing>();
        private int m_trend;                                             // last BOS direction, 0 = unknown
        private readonly int m_maxSwings = 300;

        public int Trend { get { return m_trend; } }

        public void Reset()
        {
            m_highs.Clear();
            m_lows.Clear();
            m_trend = 0;
        }

        private void Push(List<SmcSwing> arr, SmcSwing sw)
        {
            if (arr.Count >= m_maxSwings)
                arr.RemoveAt(0);                    // drop the oldest swing (chronological array)
            arr.Add(sw);
        }

        private int LatestUnbroken(List<SmcSwing> arr, long before)
        {
            for (int k = arr.Count - 1; k >= 0; k--)
                if (!arr[k].broken && arr[k].time < before)
                    return k;
            return -1;
        }

        private bool IsSwing(Rates[] r, int c, int size, int type, SmcSettings s)
        {
            int R = s.swingLength;
            if (c - R < 0 || c + R >= size)
                return false;

            double extreme = (type == Smc.DIR_BULL) ? r[c].high : r[c].low;
            double opposite = (type == Smc.DIR_BULL) ? r[c].low : r[c].high;

            for (int j = 1; j <= R; j++)
            {
                if (type == Smc.DIR_BULL)
                {
                    if (r[c + j].high >= extreme) return false;   // older bars strictly lower
                    if (r[c - j].high > extreme) return false;    // newer bars not higher
                    opposite = Math.Min(opposite, Math.Min(r[c + j].low, r[c - j].low));
                }
                else
                {
                    if (r[c + j].low <= extreme) return false;
                    if (r[c - j].low < extreme) return false;
                    opposite = Math.Max(opposite, Math.Max(r[c + j].high, r[c - j].high));
                }
            }

            if (s.swingMinATR > 0.0)
            {
                double atr = Smc.ATR(r, c, size, s.atrPeriod);
                if (atr <= 0.0)
                    return false;
                if (Math.Abs(extreme - opposite) < s.swingMinATR * atr)
                    return false;
            }
            return true;
        }

        //--- Evaluate candidate c = i + R using bars up to i (closed).
        public int ConfirmSwings(Rates[] r, int i, int size, SmcSettings s, List<SmcSwing> outList)
        {
            outList.Clear();
            int c = i + s.swingLength;
            if (c + s.swingLength >= size)
                return 0;

            for (int t = 0; t < 2; t++)
            {
                int type = (t == 0) ? Smc.DIR_BULL : Smc.DIR_BEAR;
                if (!IsSwing(r, c, size, type, s))
                    continue;

                int n = (type == Smc.DIR_BULL) ? m_highs.Count : m_lows.Count;
                long lastTime = 0;
                if (n > 0)
                    lastTime = (type == Smc.DIR_BULL) ? m_highs[n - 1].time : m_lows[n - 1].time;
                if (lastTime >= r[c].time)
                    continue;                                   // already recorded

                SmcSwing sw = new SmcSwing();
                sw.type = type;
                sw.time = r[c].time;
                sw.price = (type == Smc.DIR_BULL) ? r[c].high : r[c].low;
                sw.confirmTime = r[i].time;
                sw.broken = false;

                if (type == Smc.DIR_BULL) Push(m_highs, sw.Clone());
                else Push(m_lows, sw.Clone());

                outList.Add(sw.Clone());
            }
            return outList.Count;
        }

        private bool BreakSide(Rates[] r, int i, int size, int dir, double buffer, out SmcBos bos)
        {
            bos = new SmcBos();
            double close = r[i].close;
            long t = r[i].time;
            int idx;
            SmcSwing refSw;

            if (dir == Smc.DIR_BULL)
            {
                idx = LatestUnbroken(m_highs, t);
                if (idx < 0 || !(close > m_highs[idx].price + buffer))
                    return false;
                refSw = m_highs[idx].Clone();
                for (int k = m_highs.Count - 1; k >= 0; k--)
                    if (!m_highs[k].broken && m_highs[k].time < t && close > m_highs[k].price + buffer)
                    {
                        m_highs[k].broken = true;
                        m_highs[k].brokenTime = t;
                    }
            }
            else
            {
                idx = LatestUnbroken(m_lows, t);
                if (idx < 0 || !(close < m_lows[idx].price - buffer))
                    return false;
                refSw = m_lows[idx].Clone();
                for (int k = m_lows.Count - 1; k >= 0; k--)
                    if (!m_lows[k].broken && m_lows[k].time < t && close < m_lows[k].price - buffer)
                    {
                        m_lows[k].broken = true;
                        m_lows[k].brokenTime = t;
                    }
            }

            bos.dir = dir;
            bos.barTime = t;
            bos.closePrice = close;
            bos.level = refSw.price;
            bos.swingTime = refSw.time;
            bos.isChoch = (m_trend == -dir);
            m_trend = dir;
            return true;
        }

        public int DetectBOS(Rates[] r, int i, int size, SmcSettings s, List<SmcBos> outList)
        {
            outList.Clear();
            double buffer = 0.0;
            if (s.bosMode == SmcBosMode.CloseAtrBuffer)
                buffer = s.bosBufferATR * Smc.ATR(r, i, size, s.atrPeriod);

            SmcBos bos;
            for (int t = 0; t < 2; t++)
            {
                int dir = (t == 0) ? Smc.DIR_BULL : Smc.DIR_BEAR;
                if (BreakSide(r, i, size, dir, buffer, out bos))
                    outList.Add(bos);
            }
            return outList.Count;
        }

        public int SwingCount(int type) { return type == Smc.DIR_BULL ? m_highs.Count : m_lows.Count; }
    }

    #endregion

    #region Displacement (SMC_OB_Displacement.mqh)

    public class SmcDisplacement
    {
        public bool Evaluate(Rates[] r, int i, int size, int dir, SmcSettings s, out SmcDisplacementResult d)
        {
            d = new SmcDisplacementResult();
            d.reject = SmcReject.None;
            d.obIndex = -1;

            //--- 1. last opposite candle before (or at) the BOS candle
            for (int j = i; j <= i + s.maxOBToBOSBars; j++)
            {
                if (j >= size)
                {
                    d.reject = SmcReject.InsufficientData;
                    return false;
                }
                if (Smc.IsDirCandle(r[j], -dir))
                {
                    d.obIndex = j;
                    break;
                }
            }
            if (d.obIndex < 0)
            {
                d.reject = SmcReject.NoOppositeCandle;
                return false;
            }
            if (d.obIndex == i)
            {
                d.reject = SmcReject.BosCandleOpposite;
                return false;
            }

            int ob = d.obIndex;
            d.legBars = ob - i;

            //--- 2. volatility reference measured before the displacement
            d.atr = Smc.ATR(r, ob, size, s.atrPeriod);
            double avgBody = Smc.AvgBody(r, ob, size, s.atrPeriod);
            if (d.atr <= 0.0 || avgBody < 0.0)
            {
                d.reject = SmcReject.InsufficientData;
                return false;
            }

            //--- 3. leg metrics
            d.netMove = dir * (r[i].close - r[ob - 1].open);
            int best = -1;
            double legExtreme = (dir == Smc.DIR_BULL) ? double.MaxValue : -double.MaxValue;
            for (int k = i; k <= ob - 1; k++)
            {
                if (Smc.IsDirCandle(r[k], dir) && (best < 0 || Smc.Body(r[k]) > d.strongestBody))
                {
                    best = k;
                    d.strongestBody = Smc.Body(r[k]);
                }
                if (dir == Smc.DIR_BULL) legExtreme = Math.Min(legExtreme, r[k].low);
                else legExtreme = Math.Max(legExtreme, r[k].high);
            }
            d.strongestBodyPct = (best >= 0) ? Smc.BodyPct(r[best]) : 0.0;
            d.relStrength = (avgBody > 0.0) ? d.strongestBody / avgBody : (d.strongestBody > 0.0 ? 999.0 : 0.0);

            if (d.netMove < s.dispATRMult * d.atr) { d.reject = SmcReject.WeakMove; return false; }
            if (best < 0 || d.strongestBody < s.dispCandleATRMult * d.atr) { d.reject = SmcReject.WeakCandle; return false; }
            if (d.strongestBodyPct < s.dispMinBodyPct) { d.reject = SmcReject.SmallBody; return false; }
            if (d.relStrength < s.dispMinRelStrength) { d.reject = SmcReject.WeakRelative; return false; }

            if (s.rejectLegViolation)
            {
                bool violated = (dir == Smc.DIR_BULL) ? (legExtreme < r[ob].low) : (legExtreme > r[ob].high);
                if (violated)
                {
                    d.reject = SmcReject.LegViolatesOb;
                    return false;
                }
            }
            return true;
        }
    }

    #endregion

    #region FVG (SMC_OB_FVG.mqh)

    public class SmcFvg
    {
        //--- single candle triple with middle m; needs m-1 >= i (already closed)
        public bool CheckAt(Rates[] r, int i, int size, int dir, int m, double minSize, out SmcFvgResult f)
        {
            f = new SmcFvgResult();
            if (m - 1 < i || m + 1 >= size)
                return false;

            double top, bottom;
            if (dir == Smc.DIR_BULL)
            {
                bottom = r[m + 1].high;
                top = r[m - 1].low;
            }
            else
            {
                top = r[m + 1].low;
                bottom = r[m - 1].high;
            }
            double gap = top - bottom;
            if (gap <= 0.0 || gap < minSize)
                return false;
            if (!Smc.IsDirCandle(r[m], dir))
                return false;

            f.found = true;
            f.leftTime = r[m + 1].time;
            f.midTime = r[m].time;
            f.rightTime = r[m - 1].time;
            f.top = top;
            f.bottom = bottom;
            return true;
        }

        //--- largest FVG whose three candles are all closed and whose middle is in the leg
        public bool FindInLeg(Rates[] r, int i, int size, int dir, int obIndex, double minSize, out SmcFvgResult f)
        {
            f = new SmcFvgResult();
            SmcFvgResult cand;
            for (int m = obIndex - 1; m >= i + 1; m--)
            {
                if (CheckAt(r, i, size, dir, m, minSize, out cand) &&
                    (!f.found || (cand.top - cand.bottom) > (f.top - f.bottom)))
                    f = cand;
            }
            return f.found;
        }
    }

    #endregion

    #region Order Block detector (SMC_OB_Engine.mqh)

    public class SmcDetector
    {
        private SmcSettings m_s;
        private readonly SmcStructure m_structure = new SmcStructure();
        private readonly SmcDisplacement m_disp = new SmcDisplacement();
        private readonly SmcFvg m_fvg = new SmcFvg();

        private readonly List<SmcOrderBlock> m_obs = new List<SmcOrderBlock>();
        private readonly List<SmcOrderBlock> m_pending = new List<SmcOrderBlock>();   // FVG-required candidates (NOT confirmed OBs)
        private readonly List<SmcEvent> m_events = new List<SmcEvent>();
        private SmcStats m_stats;

        private readonly List<SmcSwing> m_swingBuf = new List<SmcSwing>();
        private readonly List<SmcBos> m_bosBuf = new List<SmcBos>();
        private long m_nextId = 1;
        private long m_lastProcessed;
        private int m_lookback;
        private bool m_historical;
        private string m_tag = "";
        private readonly SmcEnv m_env;

        public SmcDetector(SmcEnv env) { m_env = env; }

        public bool Init(SmcSettings s)
        {
            m_s = s;
            m_tag = (m_s.zoneSource == SmcZoneSource.CandleSeries) ? "[ZOrder]" : "";
            if (m_s.swingLength < 1 || m_s.atrPeriod < 1 || m_s.maxOBToBOSBars < 1 ||
                m_s.maxActivePerDir < 1 || m_s.maxStored < m_s.maxActivePerDir * 2)
                return false;
            int R = m_s.swingLength, P = m_s.atrPeriod;
            //--- deepest read: swing left side (i+2R), swing ATR (i+R+P), OB ATR (i+maxDist+P), late FVG (i+2)
            m_lookback = Math.Max(Math.Max(2 * R, R + P + 1), m_s.maxOBToBOSBars + P + 1) + 3;
            Reset();
            return true;
        }

        public void Reset()
        {
            m_structure.Reset();
            m_obs.Clear();
            m_pending.Clear();
            m_events.Clear();
            m_stats = new SmcStats();
            m_nextId = 1;
            m_lastProcessed = 0;
        }

        public int RequiredLookback { get { return m_lookback; } }
        public void SetHistoricalMode(bool on) { m_historical = on; }
        public long LastProcessedTime { get { return m_lastProcessed; } }
        public SmcSettings Settings { get { return m_s; } }
        public int OBCount { get { return m_obs.Count; } }
        public int PendingCount { get { return m_pending.Count; } }
        public int EventCount { get { return m_events.Count; } }
        public void ClearEvents() { m_events.Clear(); }
        public SmcStats Stats { get { return m_stats; } }

        private bool Logs(SmcLogLevel level)
        {
            return m_s.logLevel >= level && !(m_historical && m_s.logLevel < SmcLogLevel.Verbose);
        }

        private void Log(SmcLogLevel level, string msg)
        {
            if (m_s.logLevel < level)
                return;
            //--- during the history scan only verbose mode prints per-item messages
            if (m_historical && m_s.logLevel < SmcLogLevel.Verbose)
                return;
            m_env.Print("[SMC-OB]" + m_tag + (m_historical ? "[hist]" : "") + " " + msg);
        }

        private void PushEvent(SmcEventType type, long obId, int dir, long t, double p, long t2 = 0, double p2 = 0.0, bool flag = false)
        {
            SmcEvent e = new SmcEvent();
            e.type = type;
            e.obId = obId;
            e.dir = dir;
            e.time = t;
            e.price = p;
            e.time2 = t2;
            e.price2 = p2;
            e.flag = flag;
            e.historical = m_historical;
            m_events.Add(e);
        }

        private void Reject(SmcReject code, SmcBos bos)
        {
            switch (code)
            {
                case SmcReject.DirectionDisabled: m_stats.rejDisabled++; break;
                case SmcReject.InsufficientData: m_stats.rejData++; break;
                case SmcReject.BosCandleOpposite: m_stats.rejBosOpposite++; break;
                case SmcReject.NoOppositeCandle: m_stats.rejNoOpposite++; break;
                case SmcReject.WeakMove: m_stats.rejWeakMove++; break;
                case SmcReject.WeakCandle: m_stats.rejWeakCandle++; break;
                case SmcReject.SmallBody: m_stats.rejSmallBody++; break;
                case SmcReject.WeakRelative: m_stats.rejWeakRelative++; break;
                case SmcReject.LegViolatesOb: m_stats.rejLegViolation++; break;
                case SmcReject.ZeroZone: m_stats.rejZeroZone++; break;
                case SmcReject.FvgMissing: m_stats.rejFVGMissing++; break;
                case SmcReject.Overlap: m_stats.rejOverlap++; break;
                case SmcReject.Duplicate: m_stats.duplicates++; break;
                case SmcReject.SeriesTooLong: m_stats.rejSeriesTooLong++; break;
                default: break;
            }
            if (Logs(SmcLogLevel.Verbose))
                Log(SmcLogLevel.Verbose, string.Format("{0} BOS @ {1} (level {2}) -> no OB: {3}",
                    Smc.DirText(bos.dir), SmcEnv.T(bos.barTime), m_env.Price(bos.level), Smc.RejectText(code)));
        }

        private void LinkFVG(SmcOrderBlock o, SmcFvgResult f, bool late)
        {
            o.hasFVG = true;
            o.fvgLate = late;
            o.fvgPending = false;
            o.fvgLeftTime = f.leftTime;
            o.fvgRightTime = f.rightTime;
            o.fvgTop = f.top;
            o.fvgBottom = f.bottom;
        }

        public bool ProcessBar(Rates[] r, int i, int size)
        {
            if (i < 0 || i >= size)
                return false;
            long t = r[i].time;
            if (t <= m_lastProcessed)
                return false;                              // each bar processed exactly once
            m_lastProcessed = t;
            if (i + m_lookback >= size)
                return false;                              // warm-up: not enough history behind bar i

            m_stats.barsProcessed++;

            //--- 1-2. existing zones
            ResolvePendingFVG(r, i, size);
            UpdateLifecycle(r[i]);

            //--- 3. swings
            int ns = m_structure.ConfirmSwings(r, i, size, m_s, m_swingBuf);
            for (int k = 0; k < ns; k++)
            {
                if (m_swingBuf[k].type == Smc.DIR_BULL) m_stats.swingHighs++;
                else m_stats.swingLows++;
                PushEvent(SmcEventType.Swing, 0, m_swingBuf[k].type, m_swingBuf[k].time, m_swingBuf[k].price, m_swingBuf[k].confirmTime);
            }

            //--- 4-5. structure breaks and order blocks
            int nb = m_structure.DetectBOS(r, i, size, m_s, m_bosBuf);
            for (int k = 0; k < nb; k++)
            {
                SmcBos b = m_bosBuf[k];
                if (b.dir == Smc.DIR_BULL) m_stats.bosBull++;
                else m_stats.bosBear++;
                if (b.isChoch) m_stats.choch++;

                long id = TryCreateOB(r, i, size, b);
                PushEvent(SmcEventType.Bos, id, b.dir, b.swingTime, b.level, b.barTime, b.closePrice, b.isChoch);
            }
            return true;
        }

        //--- Process a series-ordered window oldest -> newest.
        public int ProcessWindow(Rates[] r, int size)
        {
            int n = 0;
            for (int i = size - 1; i >= 0; i--)
                if (ProcessBar(r, i, size))
                    n++;
            return n;
        }

        private long TryCreateOB(Rates[] r, int i, int size, SmcBos bos)
        {
            int dir = bos.dir;
            if ((dir == Smc.DIR_BULL && !m_s.enableBull) || (dir == Smc.DIR_BEAR && !m_s.enableBear))
            {
                Reject(SmcReject.DirectionDisabled, bos);
                return 0;
            }

            SmcDisplacementResult d;
            if (!m_disp.Evaluate(r, i, size, dir, m_s, out d))
            {
                Reject(d.reject, bos);
                return 0;
            }

            int ob = d.obIndex;
            if (HasOB(dir, r[ob].time) || HasPending(dir, r[ob].time))
            {
                Reject(SmcReject.Duplicate, bos);
                return 0;
            }

            //--- ZOrder: extend back from the last opposite candle over the complete CONTIGUOUS
            //--- series of opposite-colour candles (stops at the first candle that is not opposite).
            bool series = (m_s.zoneSource == SmcZoneSource.CandleSeries);
            int oldest = ob;
            if (series)
            {
                int deepest = i + m_lookback;
                while (oldest + 1 <= deepest && Smc.IsDirCandle(r[oldest + 1], -dir))
                    oldest++;
                if (oldest + 1 > deepest)
                {
                    Reject(SmcReject.SeriesTooLong, bos);   // start of the series not visible: never truncate
                    return 0;
                }
            }

            SmcOrderBlock o = new SmcOrderBlock();
            o.dir = dir;
            o.obTime = r[ob].time;
            o.candleOpen = r[ob].open;
            o.candleHigh = r[ob].high;
            o.candleLow = r[ob].low;
            o.candleClose = r[ob].close;
            o.bosTime = bos.barTime;
            o.bosLevel = bos.level;
            o.swingTime = bos.swingTime;
            o.isChoch = bos.isChoch;
            o.legBars = d.legBars;
            o.atr = d.atr;
            o.netMove = d.netMove;
            o.strongestBodyPct = d.strongestBodyPct;
            o.relStrength = d.relStrength;

            if (series)
            {
                o.isZOrder = true;
                o.seriesCount = oldest - ob + 1;
                o.seriesStartTime = r[oldest].time;
                if (m_s.zoneMode == SmcZoneMode.OpenLastExtreme)
                {
                    //--- first (oldest) candle Open to the extreme of the last (newest) candle
                    double ext = (dir == Smc.DIR_BULL) ? r[ob].low : r[ob].high;
                    o.top = Math.Max(r[oldest].open, ext);
                    o.bottom = Math.Min(r[oldest].open, ext);
                }
                else
                {
                    //--- ZOrder zone: highest High to lowest Low of the whole series
                    o.top = r[ob].high;
                    o.bottom = r[ob].low;
                    for (int k = ob + 1; k <= oldest; k++)
                    {
                        o.top = Math.Max(o.top, r[k].high);
                        o.bottom = Math.Min(o.bottom, r[k].low);
                    }
                }
            }
            else
            {
                switch (m_s.zoneMode)
                {
                    case SmcZoneMode.Body:
                        o.top = Math.Max(r[ob].open, r[ob].close);
                        o.bottom = Math.Min(r[ob].open, r[ob].close);
                        break;
                    case SmcZoneMode.OpenToExtreme:
                        if (dir == Smc.DIR_BULL) { o.top = r[ob].open; o.bottom = r[ob].low; }
                        else { o.top = r[ob].high; o.bottom = r[ob].open; }
                        break;
                    case SmcZoneMode.OpenLastExtreme:
                        if (dir == Smc.DIR_BULL) { o.top = r[ob].open; o.bottom = r[ob].low; }
                        else { o.top = r[ob].high; o.bottom = r[ob].open; }
                        break;
                    default:
                        o.top = r[ob].high;
                        o.bottom = r[ob].low;
                        break;
                }
            }
            if (o.top <= o.bottom)
            {
                Reject(SmcReject.ZeroZone, bos);
                return 0;
            }
            o.mid = (o.top + o.bottom) / 2.0;

            if (m_s.fvgMode != SmcFvgMode.Off)
            {
                SmcFvgResult f;
                if (m_fvg.FindInLeg(r, i, size, dir, ob, m_s.fvgMinATR * d.atr, out f))
                    LinkFVG(o, f, false);
                else
                    o.fvgPending = true;   // the BOS candle may be the middle of an FVG completed next bar

                if (m_s.fvgMode == SmcFvgMode.Required && !o.hasFVG)
                {
                    //--- NOT a confirmed OB: waits one closed bar for the FVG to complete
                    m_pending.Add(o);
                    if (Logs(SmcLogLevel.Verbose))
                        Log(SmcLogLevel.Verbose, string.Format("{0} OB candidate @ {1} pending FVG confirmation",
                            Smc.DirText(dir), SmcEnv.T(o.obTime)));
                    return 0;
                }
            }

            long id = Commit(o, bos.barTime);
            if (id == 0)
                Reject(SmcReject.Overlap, bos);
            return id;
        }

        //--- Apply overlap policy and store a confirmed OB. Returns id or 0.
        private long Commit(SmcOrderBlock o, long confirmTime)
        {
            int n = m_obs.Count;
            List<int> supersede = new List<int>();

            for (int k = 0; k < n; k++)
            {
                if (m_obs[k].dir != o.dir || !Smc.IsLiveState(m_obs[k].state))
                    continue;
                double inter = Math.Min(o.top, m_obs[k].top) - Math.Max(o.bottom, m_obs[k].bottom);
                if (inter <= 0.0)
                    continue;
                double h = Math.Min(o.top - o.bottom, m_obs[k].top - m_obs[k].bottom);
                double pct = (h > 0.0) ? inter / h * 100.0 : 100.0;
                if (pct < m_s.overlapPct)
                    continue;

                if (m_s.overlapMode == SmcOverlapMode.SkipNew)
                {
                    if (Logs(SmcLogLevel.Verbose))
                        Log(SmcLogLevel.Verbose, string.Format("{0} OB @ {1} skipped: {2:0}% overlap with #{3}",
                            Smc.DirText(o.dir), SmcEnv.T(o.obTime), pct, m_obs[k].id));
                    return 0;
                }
                o.overlapWithId = m_obs[k].id;
                if (m_s.overlapMode == SmcOverlapMode.SupersedeOld)
                    supersede.Add(k);
            }

            o.id = m_nextId++;
            o.confirmTime = confirmTime;
            o.state = SmcObState.Active;
            o.endTime = 0;

            for (int s = 0; s < supersede.Count; s++)
            {
                int k = supersede[s];
                m_obs[k].state = SmcObState.Superseded;
                m_obs[k].endTime = confirmTime;
                m_stats.superseded++;
                PushEvent(SmcEventType.ObSuperseded, m_obs[k].id, m_obs[k].dir, confirmTime, m_obs[k].mid, 0, 0.0, false);
                if (Logs(SmcLogLevel.Events))
                    Log(SmcLogLevel.Events, string.Format("OB #{0} superseded by #{1}", m_obs[k].id, o.id));
            }

            m_obs.Add(o);
            if (o.dir == Smc.DIR_BULL) m_stats.obBull++;
            else m_stats.obBear++;
            if (o.hasFVG) m_stats.fvgLinked++;

            PushEvent(SmcEventType.ObCreated, o.id, o.dir, confirmTime, o.dir == Smc.DIR_BULL ? o.top : o.bottom,
                      o.obTime, o.mid, o.hasFVG);
            if (Logs(SmcLogLevel.Events))
                Log(SmcLogLevel.Events, string.Format("{0} OB #{1} confirmed @ {2} | candle {3} | zone {4} - {5} | {6}{7} | leg {8} | move {9}xATR | FVG {10}",
                    Smc.DirText(o.dir), o.id, SmcEnv.T(confirmTime), SmcEnv.T(o.obTime),
                    m_env.Price(o.bottom), m_env.Price(o.top),
                    o.isChoch ? "CHoCH" : "BOS", o.overlapWithId > 0 ? " (overlap)" : "",
                    o.legBars, Smc.F2(o.atr > 0 ? o.netMove / o.atr : 0.0),
                    o.hasFVG ? "yes" : (o.fvgPending ? "pending" : "no")));

            if (o.isZOrder && Logs(SmcLogLevel.Events))
                Log(SmcLogLevel.Events, string.Format("ZOrder #{0} series: {1} candles {2} .. {3}", o.id, o.seriesCount,
                    SmcEnv.T(o.seriesStartTime), SmcEnv.T(o.obTime)));

            EnforceMaxActive(o.dir, confirmTime);
            Prune();
            return o.id;
        }

        private void EnforceMaxActive(int dir, long t)
        {
            while (true)
            {
                int live = 0, oldest = -1;
                for (int k = 0; k < m_obs.Count; k++)
                {
                    if (m_obs[k].dir != dir || !Smc.IsLiveState(m_obs[k].state))
                        continue;
                    live++;
                    if (oldest < 0 || m_obs[k].id < m_obs[oldest].id)
                        oldest = k;
                }
                if (live <= m_s.maxActivePerDir || oldest < 0)
                    return;
                m_obs[oldest].state = SmcObState.Expired;
                m_obs[oldest].expiredTime = t;
                if (m_obs[oldest].endTime == 0)
                    m_obs[oldest].endTime = t;
                m_stats.expired++;
                PushEvent(SmcEventType.ObExpired, m_obs[oldest].id, dir, t, m_obs[oldest].mid);
                if (Logs(SmcLogLevel.Events))
                    Log(SmcLogLevel.Events, string.Format("OB #{0} expired (max active per direction)", m_obs[oldest].id));
            }
        }

        private void Prune()
        {
            while (m_obs.Count > m_s.maxStored)
            {
                int victim = -1;
                for (int k = 0; k < m_obs.Count; k++)
                    if (!Smc.IsLiveState(m_obs[k].state)) { victim = k; break; }   // array is id-ordered
                if (victim < 0)
                    return;
                long id = m_obs[victim].id;
                int dir = m_obs[victim].dir;
                m_obs.RemoveAt(victim);
                PushEvent(SmcEventType.ObRemoved, id, dir, 0, 0.0);
            }
        }

        //--- FVG whose third candle is bar i and whose middle is the BOS bar.
        private void ResolvePendingFVG(Rates[] r, int i, int size)
        {
            if (i + 2 >= size)
                return;
            SmcFvgResult f;

            //--- confluence mode: link to already confirmed OBs (zone never changes)
            for (int k = 0; k < m_obs.Count; k++)
            {
                if (!m_obs[k].fvgPending || m_obs[k].confirmTime >= r[i].time)
                    continue;
                m_obs[k].fvgPending = false;
                if (r[i + 1].time != m_obs[k].bosTime)
                    continue;
                if (m_fvg.CheckAt(r, i, size, m_obs[k].dir, i + 1, m_s.fvgMinATR * m_obs[k].atr, out f))
                {
                    LinkFVG(m_obs[k], f, true);
                    m_stats.fvgLinked++;
                    PushEvent(SmcEventType.ObFvgLinked, m_obs[k].id, m_obs[k].dir, r[i].time, f.top, f.leftTime, f.bottom);
                    if (Logs(SmcLogLevel.Events))
                        Log(SmcLogLevel.Events, string.Format("FVG linked to OB #{0} @ {1}", m_obs[k].id, SmcEnv.T(r[i].time)));
                }
            }

            //--- required mode: confirm or reject waiting candidates
            int np = m_pending.Count;
            if (np == 0)
                return;
            List<SmcOrderBlock> waiting = new List<SmcOrderBlock>(m_pending);
            m_pending.Clear();

            for (int k = 0; k < np; k++)
            {
                SmcBos bos = new SmcBos();
                bos.dir = waiting[k].dir;
                bos.barTime = waiting[k].bosTime;
                bos.level = waiting[k].bosLevel;

                if (r[i + 1].time == waiting[k].bosTime &&
                    m_fvg.CheckAt(r, i, size, waiting[k].dir, i + 1, m_s.fvgMinATR * waiting[k].atr, out f))
                {
                    LinkFVG(waiting[k], f, true);
                    if (Commit(waiting[k], r[i].time) == 0)
                        Reject(SmcReject.Overlap, bos);
                }
                else
                    Reject(SmcReject.FvgMissing, bos);
            }
        }

        private void UpdateLifecycle(Rates bar)
        {
            for (int k = 0; k < m_obs.Count; k++)
                UpdateOne(k, bar);
        }

        private void UpdateOne(int k, Rates bar)
        {
            SmcOrderBlock o = m_obs[k];
            if (!Smc.IsLiveState(o.state) || o.confirmTime >= bar.time)
                return;

            long id = o.id;
            int dir = o.dir;
            o.barsMonitored++;

            if (m_s.maxAgeBars > 0 && o.barsMonitored > m_s.maxAgeBars)
            {
                o.state = SmcObState.Expired;
                o.expiredTime = bar.time;
                if (o.endTime == 0)
                    o.endTime = bar.time;
                m_stats.expired++;
                PushEvent(SmcEventType.ObExpired, id, dir, bar.time, o.mid);
                if (Logs(SmcLogLevel.Events))
                    Log(SmcLogLevel.Events, string.Format("OB #{0} expired (age)", id));
                return;
            }

            double top = o.top, bottom = o.bottom, mid = o.mid;
            bool touched, reachedMid, reachedFar, closeBeyond, wickBeyond;
            if (dir == Smc.DIR_BULL)
            {
                touched = bar.low <= top;
                reachedMid = bar.low <= mid;
                reachedFar = bar.low <= bottom;
                closeBeyond = bar.close < bottom;
                wickBeyond = bar.low < bottom;
            }
            else
            {
                touched = bar.high >= bottom;
                reachedMid = bar.high >= mid;
                reachedFar = bar.high >= top;
                closeBeyond = bar.close > top;
                wickBeyond = bar.high > top;
            }

            //--- retest: a fresh entry into the zone (previous bar was outside)
            if (m_s.retestEnabled && touched && !o.touchingPrev)
            {
                o.retestCount++;
                m_stats.retests++;
                bool first = (o.retestCount == 1);
                double price = (dir == Smc.DIR_BULL) ? Math.Max(bar.low, bottom) : Math.Min(bar.high, top);
                if (first)
                {
                    o.firstRetestTime = bar.time;
                    o.firstRetestPrice = price;
                    if (o.state == SmcObState.Active)
                        o.state = SmcObState.Retested;
                }
                PushEvent(SmcEventType.ObRetest, id, dir, bar.time, price, 0, (double)o.retestCount, first);
                if (Logs(SmcLogLevel.Events))
                    Log(SmcLogLevel.Events, string.Format("{0} OB #{1} retest #{2} @ {3}", Smc.DirText(dir), id,
                        o.retestCount, SmcEnv.T(bar.time)));
            }
            o.touchingPrev = touched;

            //--- mitigation
            if (m_s.mitigationMode != SmcMitigationMode.Off && o.state != SmcObState.Mitigated)
            {
                bool mit = (m_s.mitigationMode == SmcMitigationMode.Touch) ? touched :
                           (m_s.mitigationMode == SmcMitigationMode.Midpoint) ? reachedMid : reachedFar;
                if (mit)
                {
                    o.state = SmcObState.Mitigated;
                    o.mitigatedTime = bar.time;
                    o.endTime = bar.time;
                    m_stats.mitigations++;
                    PushEvent(SmcEventType.ObMitigated, id, dir, bar.time, dir == Smc.DIR_BULL ? bar.low : bar.high);
                    if (Logs(SmcLogLevel.Events))
                        Log(SmcLogLevel.Events, string.Format("{0} OB #{1} mitigated @ {2}", Smc.DirText(dir), id, SmcEnv.T(bar.time)));
                }
            }

            //--- invalidation (final)
            if (m_s.invalidationMode != SmcInvalidationMode.Off)
            {
                bool inv = (m_s.invalidationMode == SmcInvalidationMode.CloseBeyond) ? closeBeyond : wickBeyond;
                if (inv)
                {
                    o.state = SmcObState.Invalidated;
                    o.invalidatedTime = bar.time;
                    if (o.endTime == 0)
                        o.endTime = bar.time;
                    o.liveInside = false;
                    m_stats.invalidations++;
                    PushEvent(SmcEventType.ObInvalidated, id, dir, bar.time, bar.close);
                    if (Logs(SmcLogLevel.Events))
                        Log(SmcLogLevel.Events, string.Format("{0} OB #{1} invalidated @ {2}", Smc.DirText(dir), id, SmcEnv.T(bar.time)));
                }
            }
        }

        //--- Tick-level "price inside zone" flag. Informational only.
        public bool OnTickPrice(double price)
        {
            bool changed = false;
            for (int k = 0; k < m_obs.Count; k++)
            {
                bool inside = Smc.IsLiveState(m_obs[k].state) && price <= m_obs[k].top && price >= m_obs[k].bottom;
                if (inside != m_obs[k].liveInside)
                {
                    m_obs[k].liveInside = inside;
                    changed = true;
                }
            }
            return changed;
        }

        public bool GetOB(int idx, out SmcOrderBlock outOb)
        {
            outOb = null;
            if (idx < 0 || idx >= m_obs.Count)
                return false;
            outOb = m_obs[idx].Clone();
            return true;
        }

        //--- single-field reads for hot loops
        public long OBIdAt(int idx) { return (idx >= 0 && idx < m_obs.Count) ? m_obs[idx].id : 0; }
        public SmcObState OBStateAt(int idx) { return (idx >= 0 && idx < m_obs.Count) ? m_obs[idx].state : SmcObState.Expired; }

        public int FindById(long id)
        {
            for (int k = m_obs.Count - 1; k >= 0; k--)
                if (m_obs[k].id == id)
                    return k;
            return -1;
        }

        public bool HasOB(int dir, long obTime)
        {
            for (int k = m_obs.Count - 1; k >= 0; k--)
                if (m_obs[k].dir == dir && m_obs[k].obTime == obTime)
                    return true;
            return false;
        }

        private bool HasPending(int dir, long obTime)
        {
            for (int k = 0; k < m_pending.Count; k++)
                if (m_pending[k].dir == dir && m_pending[k].obTime == obTime)
                    return true;
            return false;
        }

        public int LiveCount(int dir)
        {
            int n = 0;
            for (int k = 0; k < m_obs.Count; k++)
                if (Smc.IsLiveState(m_obs[k].state) && (dir == 0 || m_obs[k].dir == dir))
                    n++;
            return n;
        }

        public int GetLiveOBs(int dir, List<SmcOrderBlock> outList)
        {
            outList.Clear();
            for (int k = 0; k < m_obs.Count; k++)
            {
                if (!Smc.IsLiveState(m_obs[k].state) || (dir != 0 && m_obs[k].dir != dir))
                    continue;
                outList.Add(m_obs[k].Clone());
            }
            return outList.Count;
        }

        public bool GetEvent(int idx, out SmcEvent e)
        {
            e = new SmcEvent();
            if (idx < 0 || idx >= m_events.Count)
                return false;
            e = m_events[idx];
            return true;
        }

        public string StatsText()
        {
            SmcStats s = m_stats;
            string text = string.Format(
                "bars={0} | swings H/L={1}/{2} | BOS bull/bear={3}/{4} (CHoCH {5}) | OB bull/bear={6}/{7} | FVG linked={8}\n" +
                "rejections: disabled={9} data={10} bosOpposite={11} noOpposite={12} weakMove={13} weakCandle={14} smallBody={15} weakRel={16} legViolation={17} zeroZone={18} fvgMissing={19} overlap={20} duplicate={21}\n" +
                "lifecycle: retests={22} mitigated={23} invalidated={24} expired={25} superseded={26} | stored={27}",
                s.barsProcessed, s.swingHighs, s.swingLows, s.bosBull, s.bosBear, s.choch, s.obBull, s.obBear, s.fvgLinked,
                s.rejDisabled, s.rejData, s.rejBosOpposite, s.rejNoOpposite, s.rejWeakMove, s.rejWeakCandle, s.rejSmallBody,
                s.rejWeakRelative, s.rejLegViolation, s.rejZeroZone, s.rejFVGMissing, s.rejOverlap, s.duplicates,
                s.retests, s.mitigations, s.invalidations, s.expired, s.superseded, m_obs.Count);
            if (m_s.zoneSource == SmcZoneSource.CandleSeries)
                text += string.Format(" | seriesTooLong={0}", s.rejSeriesTooLong);
            return text;
        }
    }

    #endregion

    #region CISD engine (SMC_CISD_Engine.mqh)

    public struct CisdSettings
    {
        public int timeframeSeconds;     // ENUM_TIMEFRAMES timeframe (labels only)
        public bool useSweep;
        public bool useConfirm;
        public bool useRetrace;
        public int swingLength;
        public double swingMinATR;
        public int atrPeriod;
        public int swingMaxAge;
        public CisdSweepMode sweepMode;
        public int sweepValidityBars;
        public CisdLevelMode levelMode;
        public int maxSeriesCandles;
        public int maxConfirmBars;
        public int maxRetraceBars;
        public int maxStored;
        public SmcLogLevel logLevel;
        //--- HTF OB -> LTF CISD integration (defaults keep standalone behaviour unchanged)
        public long activationTime;
        public int dirFilter;
        public CisdActivation activationMode;
    }

    public class CisdSwing
    {
        public long time;
        public double price;
        public long barNo;
        public bool swept;
    }

    public class CisdSweep
    {
        public long id;
        public int dir;
        public long time;
        public double price;
        public long swingTime;
        public double swingPrice;
        public long barNo;
        public bool used;
        public CisdSweep Clone() { return (CisdSweep)MemberwiseClone(); }
    }

    public class CisdRecord
    {
        //--- identity (fixed when the setup is created)
        public long id;
        public int dir;
        public int timeframeSeconds;
        public bool hasSweep;
        public long sweepId;
        public long sweepTime;
        public double sweepPrice;
        public long sweptSwingTime;
        public double sweptSwingPrice;
        public long seriesStartTime;
        public long seriesEndTime;
        public int seriesCount;
        public double seriesHigh;
        public double seriesLow;
        public double seriesOpen;
        public long extremeTime;
        public double extremePrice;
        public double level;
        public long setupTime;
        //--- confirmation (fixed once confirmed)
        public long confirmTime;
        public double confirmPrice;
        public double sdRange;
        //--- life-cycle
        public CisdState state;
        public int barsInState;
        public long retraceTime;
        public double retracePrice;
        public long endTime;

        public CisdRecord Clone() { return (CisdRecord)MemberwiseClone(); }
    }

    public struct CisdEvent
    {
        public CisdEventType type;
        public long id;
        public int dir;
        public long time;
        public double price;
        public bool historical;
    }

    public struct CisdStats
    {
        public int bars, swingHighs, swingLows, sweepsSellSide, sweepsBuySide, setupsBull, setupsBear, noSweep;
        public int seriesTooLong, setupFailed, setupReplaced, confirmedBull, confirmedBear, retraced, invalidated, expired;
    }

    public static class CisdUtil
    {
        public static bool ConfirmedState(CisdState s)
        {
            return s == CisdState.Confirmed || s == CisdState.Retraced || s == CisdState.Invalidated || s == CisdState.Expired;
        }
    }

    public class SmcCisdEngine
    {
        private CisdSettings m_s;
        private SmcSettings m_swingCfg;
        private readonly SmcStructure m_swingDetector = new SmcStructure();
        private readonly List<CisdSwing> m_lows = new List<CisdSwing>();     // sell-side liquidity
        private readonly List<CisdSwing> m_highs = new List<CisdSwing>();    // buy-side liquidity
        private readonly List<CisdSweep> m_sweeps = new List<CisdSweep>();
        private readonly List<SmcSwing> m_swBuf = new List<SmcSwing>();
        private readonly CisdSweep[] m_lastSweep = new CisdSweep[2];         // [0] sell-side (bull), [1] buy-side (bear)
        private readonly bool[] m_hasSweep = new bool[2];
        private readonly long[] m_pendingId = new long[2];
        private readonly List<CisdRecord> m_rec = new List<CisdRecord>();
        private readonly List<CisdEvent> m_events = new List<CisdEvent>();
        private CisdStats m_st;
        private long m_nextId = 1;
        private long m_nextSweepId = 1;
        private long m_barNo;
        private long m_last;
        private long m_first;
        private int m_lookback;
        private bool m_hist;
        private readonly SmcEnv m_env;

        public SmcCisdEngine(SmcEnv env)
        {
            m_env = env;
            m_lastSweep[0] = new CisdSweep();
            m_lastSweep[1] = new CisdSweep();
        }

        private int Side(int dir) { return dir == Smc.DIR_BULL ? 0 : 1; }

        private bool Logs(SmcLogLevel level)
        {
            return m_s.logLevel >= level && !(m_hist && m_s.logLevel < SmcLogLevel.Verbose);
        }

        private void Log(SmcLogLevel level, string msg)
        {
            if (m_s.logLevel < level || (m_hist && m_s.logLevel < SmcLogLevel.Verbose))
                return;
            m_env.Print("[SMC-CISD][" + Smc.TFText(m_s.timeframeSeconds) + "]" + (m_hist ? "[hist]" : "") + " " + msg);
        }

        public bool Init(CisdSettings s)
        {
            m_s = s;
            if (m_s.swingLength < 1 || m_s.atrPeriod < 1 || m_s.maxSeriesCandles < 1 || m_s.maxConfirmBars < 1 ||
                m_s.maxRetraceBars < 1 || m_s.sweepValidityBars < 0 || m_s.maxStored < 10)
                return false;
            m_swingCfg = new SmcSettings();
            m_swingCfg.swingLength = m_s.swingLength;
            m_swingCfg.swingMinATR = m_s.swingMinATR;
            m_swingCfg.atrPeriod = m_s.atrPeriod;
            int R = m_s.swingLength, P = m_s.atrPeriod;
            m_lookback = Math.Max(Math.Max(2 * R, R + P + 1), m_s.maxSeriesCandles + 2) + 3;
            Reset();
            return true;
        }

        public void Reset()
        {
            m_swingDetector.Reset();
            m_lows.Clear();
            m_highs.Clear();
            m_sweeps.Clear();
            m_rec.Clear();
            m_events.Clear();
            m_lastSweep[0] = new CisdSweep();
            m_lastSweep[1] = new CisdSweep();
            m_hasSweep[0] = m_hasSweep[1] = false;
            m_pendingId[0] = m_pendingId[1] = 0;
            m_st = new CisdStats();
            m_nextId = 1;
            m_nextSweepId = 1;
            m_barNo = 0;
            m_last = 0;
            m_first = 0;
        }

        public int RequiredLookback { get { return m_lookback; } }
        public void SetHistoricalMode(bool on) { m_hist = on; }
        public long LastProcessedTime { get { return m_last; } }
        public long FirstBarTime { get { return m_first; } }
        public CisdSettings Settings { get { return m_s; } }
        public int Count { get { return m_rec.Count; } }
        public int SweepCount { get { return m_sweeps.Count; } }
        public int EventCount { get { return m_events.Count; } }
        public void ClearEvents() { m_events.Clear(); }

        private void Event(CisdEventType type, long id, int dir, long t, double p)
        {
            CisdEvent e = new CisdEvent();
            e.type = type;
            e.id = id;
            e.dir = dir;
            e.time = t;
            e.price = p;
            e.historical = m_hist;
            m_events.Add(e);
        }

        private void AddSwing(List<CisdSwing> arr, SmcSwing sw)
        {
            if (arr.Count >= 300)
                arr.RemoveAt(0);
            CisdSwing c = new CisdSwing();
            c.time = sw.time;
            c.price = sw.price;
            c.barNo = m_barNo;
            c.swept = false;
            arr.Add(c);
        }

        public bool ProcessBar(Rates[] r, int i, int size)
        {
            if (i < 0 || i >= size)
                return false;
            long t = r[i].time;
            if (t <= m_last)
                return false;                        // each bar exactly once
            if (m_first == 0)
                m_first = r[size - 1].time;
            m_last = t;
            if (i + m_lookback >= size)
                return false;                        // warm-up
            m_barNo++;
            m_st.bars++;

            //--- 1. life-cycle of existing setups / CISDs (created before this bar)
            UpdateRecords(r[i]);

            //--- 2. liquidity: swings confirmed on this bar (reused swing definition)
            int ns = m_swingDetector.ConfirmSwings(r, i, size, m_swingCfg, m_swBuf);
            for (int k = 0; k < ns; k++)
            {
                if (m_swBuf[k].type == Smc.DIR_BULL) { AddSwing(m_highs, m_swBuf[k]); m_st.swingHighs++; }
                else { AddSwing(m_lows, m_swBuf[k]); m_st.swingLows++; }
            }

            //--- 3-5. per direction: sweep -> series -> confirmation close
            for (int d = 0; d < 2; d++)
            {
                int dir = (d == 0) ? Smc.DIR_BULL : Smc.DIR_BEAR;
                if (m_s.dirFilter != 0 && dir != m_s.dirFilter)
                    continue;
                if (m_s.useSweep)
                    DetectSweep(r[i], dir);
                TryCreateSetup(r, i, size, dir);
                if (m_s.useConfirm)
                    TryConfirm(r[i], dir);
            }
            Prune();
            return true;
        }

        public int ProcessWindow(Rates[] r, int size)
        {
            int n = 0;
            for (int i = size - 1; i >= 0; i--)
                if (ProcessBar(r, i, size))
                    n++;
            return n;
        }

        private void UpdateRecords(Rates bar)
        {
            long t = bar.time;
            for (int k = 0; k < m_rec.Count; k++)
            {
                CisdRecord rc = m_rec[k];
                int dir = rc.dir;
                if (rc.state == CisdState.Setup)
                {
                    if (rc.setupTime >= t)
                        continue;
                    rc.barsInState++;
                    bool deeper = (dir == Smc.DIR_BULL) ? bar.low < rc.extremePrice : bar.high > rc.extremePrice;
                    if (deeper || rc.barsInState > m_s.maxConfirmBars)
                    {
                        rc.state = CisdState.SetupFailed;
                        rc.endTime = t;
                        m_st.setupFailed++;
                        if (m_pendingId[Side(dir)] == rc.id)
                            m_pendingId[Side(dir)] = 0;
                        Event(CisdEventType.SetupFailed, rc.id, dir, t, deeper ? (dir == Smc.DIR_BULL ? bar.low : bar.high) : bar.close);
                        if (Logs(SmcLogLevel.Verbose))
                            Log(SmcLogLevel.Verbose, string.Format("{0} CISD setup #{1} failed ({2})", Smc.DirText(dir), rc.id,
                                deeper ? "deeper extreme" : "no confirmation in time"));
                    }
                    continue;
                }

                if (rc.state != CisdState.Confirmed || rc.endTime != 0 || rc.confirmTime >= t)
                    continue;
                rc.barsInState++;

                //--- invalidation: close beyond the manipulation extreme
                if (dir * (bar.close - rc.extremePrice) < 0)
                {
                    rc.state = CisdState.Invalidated;
                    rc.endTime = t;
                    m_st.invalidated++;
                    Event(CisdEventType.Invalidated, rc.id, dir, t, bar.close);
                    if (Logs(SmcLogLevel.Events))
                        Log(SmcLogLevel.Events, string.Format("{0} CISD #{1} invalidated @ {2}", Smc.DirText(dir), rc.id, SmcEnv.T(t)));
                    continue;
                }

                if (m_s.useRetrace)
                {
                    bool touch = (dir == Smc.DIR_BULL) ? bar.low <= rc.level : bar.high >= rc.level;
                    if (touch)
                    {
                        rc.state = CisdState.Retraced;
                        rc.retraceTime = t;
                        rc.retracePrice = (dir == Smc.DIR_BULL) ? Math.Max(bar.low, rc.seriesLow)
                                                                : Math.Min(bar.high, rc.seriesHigh);
                        rc.endTime = t;
                        m_st.retraced++;
                        Event(CisdEventType.Retraced, rc.id, dir, t, rc.retracePrice);
                        if (Logs(SmcLogLevel.Events))
                            Log(SmcLogLevel.Events, string.Format("{0} CISD #{1} retracement / entry @ {2} ({3})", Smc.DirText(dir), rc.id,
                                SmcEnv.T(t), m_env.Price(rc.retracePrice)));
                        continue;
                    }
                }
                if (rc.barsInState >= m_s.maxRetraceBars)
                {
                    if (m_s.useRetrace)
                    {
                        rc.state = CisdState.Expired;
                        m_st.expired++;
                        Event(CisdEventType.Expired, rc.id, dir, t, bar.close);
                    }
                    rc.endTime = t;             // stop monitoring
                }
            }
        }

        //--- Liquidity sweep: bullish CISD <- sell-side (swing lows) taken.
        private void DetectSweep(Rates bar, int dir)
        {
            bool bull = (dir == Smc.DIR_BULL);
            int best = -1;
            long bestTime = 0;
            double bestPrice = 0.0;
            List<CisdSwing> arr = bull ? m_lows : m_highs;
            int n = arr.Count;
            for (int k = 0; k < n; k++)
            {
                long swTime = arr[k].time;
                double swPrice = arr[k].price;
                bool swSwept = arr[k].swept;
                long swBar = arr[k].barNo;
                if (swSwept || swTime >= bar.time)
                    continue;
                if (m_s.swingMaxAge > 0 && m_barNo - swBar > m_s.swingMaxAge)
                    continue;
                bool through = bull ? bar.low < swPrice : bar.high > swPrice;
                if (!through)
                    continue;
                arr[k].swept = true;                       // liquidity is consumed once taken
                if (m_s.sweepMode == CisdSweepMode.Rejection && !(bull ? bar.close > swPrice : bar.close < swPrice))
                    continue;
                if (best < 0 || (bull ? swPrice < bestPrice : swPrice > bestPrice))
                {
                    best = k;                               // deepest liquidity taken
                    bestTime = swTime;
                    bestPrice = swPrice;
                }
            }
            if (best < 0)
                return;
            if (m_s.activationMode == CisdActivation.AllAfter && bar.time < m_s.activationTime)
                return;                                    // liquidity consumed, but no sweep before activation

            CisdSweep s = new CisdSweep();
            s.id = m_nextSweepId++;
            s.dir = dir;
            s.time = bar.time;
            s.price = bull ? bar.low : bar.high;
            s.swingTime = bestTime;
            s.swingPrice = bestPrice;
            s.barNo = m_barNo;
            s.used = false;

            if (m_sweeps.Count >= 500)
                m_sweeps.RemoveAt(0);
            m_sweeps.Add(s.Clone());
            m_lastSweep[Side(dir)] = s.Clone();
            m_hasSweep[Side(dir)] = true;
            if (bull) m_st.sweepsSellSide++;
            else m_st.sweepsBuySide++;
            Event(CisdEventType.Sweep, s.id, dir, s.time, s.price);
            if (Logs(SmcLogLevel.Verbose))
                Log(SmcLogLevel.Verbose, string.Format("{0} liquidity sweep @ {1}: {2} took swing {3}",
                    bull ? "Sell-side" : "Buy-side", SmcEnv.T(s.time), m_env.Price(s.price), m_env.Price(s.swingPrice)));
        }

        //--- A setup is evaluated once, on the bar that ends an opposite run.
        private void TryCreateSetup(Rates[] r, int i, int size, int dir)
        {
            //--- the run must have ended exactly on bar i (series candles are opposite-coloured)
            if (Smc.IsDirCandle(r[i], -dir) || i + 1 >= size || !Smc.IsDirCandle(r[i + 1], -dir))
                return;

            int newest = i + 1, oldest = newest;
            int deepest = i + m_lookback;                 // deepest bar present in every data window
            while (oldest + 1 <= deepest && Smc.IsDirCandle(r[oldest + 1], -dir))
            {
                oldest++;
                if (oldest - newest + 1 > m_s.maxSeriesCandles)
                    break;
            }
            if (oldest - newest + 1 > m_s.maxSeriesCandles || oldest + 1 > deepest)
            {
                m_st.seriesTooLong++;                      // never truncate a series
                return;
            }
            if (m_s.activationMode == CisdActivation.AllAfter && r[oldest].time < m_s.activationTime)
                return;                                    // series began before activation

            bool bull = (dir == Smc.DIR_BULL);
            double hi = r[oldest].high, lo = r[oldest].low;
            double ext = bull ? r[oldest].low : r[oldest].high;
            long extT = r[oldest].time;
            for (int k = oldest; k >= i; k--)              // oldest -> bar i, earliest extreme wins ties
            {
                if (k >= newest)
                {
                    hi = Math.Max(hi, r[k].high);
                    lo = Math.Min(lo, r[k].low);
                }
                double e = bull ? r[k].low : r[k].high;
                if (bull ? e < ext : e > ext)
                {
                    ext = e;
                    extT = r[k].time;
                }
            }

            //--- liquidity sweep requirement
            CisdSweep sw = new CisdSweep();
            bool hasSweep = false;
            if (m_s.useSweep)
            {
                int sdx = Side(dir);
                if (m_hasSweep[sdx] && !m_lastSweep[sdx].used)
                {
                    sw = m_lastSweep[sdx].Clone();
                    bool inside = (sw.time >= r[oldest].time && sw.time <= r[i].time);
                    bool after = (sw.time < r[oldest].time && m_barNo - sw.barNo <= m_s.sweepValidityBars &&
                                  (bull ? ext < sw.swingPrice : ext > sw.swingPrice));
                    hasSweep = inside || after;
                }
                if (!hasSweep)
                {
                    m_st.noSweep++;
                    return;
                }
            }

            CisdRecord c = new CisdRecord();
            c.id = m_nextId++;
            c.dir = dir;
            c.timeframeSeconds = m_s.timeframeSeconds;
            c.hasSweep = hasSweep;
            if (hasSweep)
            {
                c.sweepId = sw.id;
                c.sweepTime = sw.time;
                c.sweepPrice = sw.price;
                c.sweptSwingTime = sw.swingTime;
                c.sweptSwingPrice = sw.swingPrice;
            }
            c.seriesStartTime = r[oldest].time;
            c.seriesEndTime = r[newest].time;
            c.seriesCount = oldest - newest + 1;
            c.seriesHigh = hi;
            c.seriesLow = lo;
            c.seriesOpen = r[oldest].open;
            c.extremeTime = extT;
            c.extremePrice = ext;
            c.level = (m_s.levelMode == CisdLevelMode.SeriesOpen) ? c.seriesOpen : (bull ? hi : lo);
            c.setupTime = r[i].time;
            c.state = CisdState.Setup;

            //--- one waiting setup per direction: the newer series takes over
            int sd = Side(dir);
            if (m_pendingId[sd] > 0)
            {
                int old = FindById(m_pendingId[sd]);
                if (old >= 0 && m_rec[old].state == CisdState.Setup)
                {
                    m_rec[old].state = CisdState.SetupReplaced;
                    m_rec[old].endTime = r[i].time;
                    m_st.setupReplaced++;
                }
            }

            m_rec.Add(c);
            m_pendingId[sd] = c.id;
            if (bull) m_st.setupsBull++;
            else m_st.setupsBear++;
            Event(CisdEventType.Setup, c.id, dir, c.setupTime, c.level);
            if (Logs(SmcLogLevel.Verbose))
                Log(SmcLogLevel.Verbose, string.Format("{0} CISD setup #{1}: {2}-candle series {3}..{4}, level {5}{6}", Smc.DirText(dir), c.id,
                    c.seriesCount, SmcEnv.T(c.seriesStartTime), SmcEnv.T(c.seriesEndTime),
                    m_env.Price(c.level), hasSweep ? ", after liquidity sweep" : ""));
        }

        private void TryConfirm(Rates bar, int dir)
        {
            int sd = Side(dir);
            if (m_pendingId[sd] <= 0)
                return;
            int k = FindById(m_pendingId[sd]);
            if (k < 0 || m_rec[k].state != CisdState.Setup)
            {
                m_pendingId[sd] = 0;
                return;
            }
            CisdRecord rc = m_rec[k];
            if (dir * (bar.close - rc.level) <= 0)
                return;                                    // close must be strictly beyond the level

            //--- CONFIRM_AFTER: the series may predate activation, but a close that already changed delivery
            //--- before it consumes the setup - an old CISD is never reused for a later association
            if (m_s.activationMode == CisdActivation.ConfirmAfter && bar.time < m_s.activationTime)
            {
                rc.state = CisdState.SetupFailed;
                rc.endTime = bar.time;
                m_st.setupFailed++;
                m_pendingId[sd] = 0;
                if (Logs(SmcLogLevel.Verbose))
                    Log(SmcLogLevel.Verbose, string.Format("{0} setup #{1} consumed before activation @ {2}", Smc.DirText(dir),
                        rc.id, SmcEnv.T(bar.time)));
                return;
            }

            rc.state = CisdState.Confirmed;
            rc.confirmTime = bar.time;
            rc.confirmPrice = bar.close;
            rc.sdRange = Math.Abs(rc.level - rc.extremePrice);
            rc.barsInState = 0;
            rc.endTime = 0;
            m_pendingId[sd] = 0;
            if (rc.hasSweep && m_lastSweep[sd].id == rc.sweepId)
                m_lastSweep[sd].used = true;               // one CISD per sweep
            for (int s = m_sweeps.Count - 1; s >= 0; s--)
                if (m_sweeps[s].id == rc.sweepId) { m_sweeps[s].used = true; break; }

            if (dir == Smc.DIR_BULL) m_st.confirmedBull++;
            else m_st.confirmedBear++;
            Event(CisdEventType.Confirmed, rc.id, dir, bar.time, bar.close);
            if (Logs(SmcLogLevel.Events))
                Log(SmcLogLevel.Events, string.Format("{0} CISD #{1} CONFIRMED @ {2}: close {3} beyond {4} (series {5} candles{6})",
                    Smc.DirText(dir), rc.id, SmcEnv.T(bar.time),
                    m_env.Price(bar.close), m_env.Price(rc.level),
                    rc.seriesCount, rc.hasSweep ? ", after liquidity sweep" : ""));
        }

        private void Prune()
        {
            while (m_rec.Count > m_s.maxStored)
            {
                int victim = -1;
                for (int k = 0; k < m_rec.Count; k++)
                    if (m_rec[k].state != CisdState.Setup && !(m_rec[k].state == CisdState.Confirmed && m_rec[k].endTime == 0))
                    { victim = k; break; }
                if (victim < 0)
                    return;
                m_rec.RemoveAt(victim);
            }
        }

        public bool Get(int idx, out CisdRecord outRec)
        {
            outRec = null;
            if (idx < 0 || idx >= m_rec.Count)
                return false;
            outRec = m_rec[idx].Clone();
            return true;
        }

        public int FindById(long id)
        {
            for (int k = m_rec.Count - 1; k >= 0; k--)
                if (m_rec[k].id == id)
                    return k;
            return -1;
        }

        public bool GetSweep(int idx, out CisdSweep outSw)
        {
            outSw = null;
            if (idx < 0 || idx >= m_sweeps.Count)
                return false;
            outSw = m_sweeps[idx].Clone();
            return true;
        }

        public bool GetEvent(int idx, out CisdEvent e)
        {
            e = new CisdEvent();
            if (idx < 0 || idx >= m_events.Count)
                return false;
            e = m_events[idx];
            return true;
        }

        public CisdMachine MachineState(int dir)
        {
            int sd = Side(dir);
            if (m_pendingId[sd] > 0)
                return CisdMachine.WaitForClose;
            if (m_s.useSweep && m_hasSweep[sd] && !m_lastSweep[sd].used &&
                m_barNo - m_lastSweep[sd].barNo <= m_s.sweepValidityBars)
                return CisdMachine.LiquiditySweep;
            return CisdMachine.Waiting;
        }

        public string StatsText()
        {
            CisdStats s = m_st;
            return string.Format("bars={0} | swings H/L={1}/{2} | sweeps sell/buy={3}/{4} | setups bull/bear={5}/{6} (noSweep {7}, seriesTooLong {8}, failed {9}, replaced {10}) | " +
                                 "CISD bull/bear={11}/{12} | retraced={13} invalidated={14} expired={15} | stored={16}",
                                 s.bars, s.swingHighs, s.swingLows, s.sweepsSellSide, s.sweepsBuySide,
                                 s.setupsBull, s.setupsBear, s.noSweep, s.seriesTooLong, s.setupFailed,
                                 s.setupReplaced, s.confirmedBull, s.confirmedBear, s.retraced, s.invalidated,
                                 s.expired, m_rec.Count);
        }
    }

    #endregion

    #region HTF OB -> LTF CISD connection (SMC_Connect_Engine.mqh)

    public static class Conn
    {
        public const int KIND_STANDARD = 0;
        public const int KIND_ZORDER = 1;
        public const int TREND_HISTORY = 4000;   // extra closed OB candles kept for historical trend queries

        public static string StateText(ConnState s)
        {
            switch (s)
            {
                case ConnState.ObCreated: return "OB_CREATED";
                case ConnState.WaitingForRetest: return "WAITING_FOR_RETEST";
                case ConnState.ObRetested: return "OB_RETESTED";
                case ConnState.CisdMonitoring: return "CISD_MONITORING";
                case ConnState.CisdSweepDetected: return "CISD_SWEEP_DETECTED";
                case ConnState.CisdConfirmed: return "CISD_CONFIRMED";
                case ConnState.Retracement: return "RETRACEMENT";
                case ConnState.Completed: return "COMPLETED";
                case ConnState.Invalidated: return "INVALIDATED";
                case ConnState.Expired: return "EXPIRED";
            }
            return "?";
        }

        public static string KindText(int kind) { return kind == KIND_ZORDER ? "ZOrder" : "OB"; }

        public static bool Terminal(ConnState s)
        {
            return s == ConnState.Retracement || s == ConnState.Completed || s == ConnState.Invalidated || s == ConnState.Expired;
        }

        public static bool Monitoring(ConnState s)
        {
            return s == ConnState.CisdMonitoring || s == ConnState.CisdSweepDetected || s == ConnState.CisdConfirmed;
        }

        //--- first bar open time >= t for a timeframe of 'ps' seconds (bars align to epoch multiples)
        public static long AlignUp(long t, int ps)
        {
            if (ps <= 0)
                return t;
            long rem = t % ps;
            return rem == 0 ? t : (t - rem + ps);
        }
    }

    public struct ConnSettings
    {
        public int obTFSeconds;
        public int cisdTFSeconds;
        public bool useStandard;
        public bool useZOrder;
        public bool multiRetest;
        public bool multiCISD;
        public bool stopOnMitigation;
        public bool trendFilter;
        public int trendBars;
        public double trendATRMult;
        public int trendATRPeriod;
        public int mitigationMode;
        public int maxRetests;
        public CisdSettings cisd;
        public int warmupBars;
        public int maxMonitorBars;
        public long windowStart;
        public SmcLogLevel logLevel;
    }

    public class ConnSetup
    {
        public long id;
        public int kind;
        public long obId;
        public int dir;
        public long obTime;
        public long obConfirmTime;
        public long availTime;
        public double top;
        public double bottom;
        public long deadKnown;
        public bool deadByMitigation;
        public long mitM1Time;
        public ConnState state;
        public long stateTime;
        public bool touching;
        public int retestCount;
        public int seqCount;
        public int cisdCount;
        public long retestTime;
        public double retestPrice;
        public long cisdStartTime;
        public long endTime;
    }

    public class ConnSeq
    {
        public double trendScore;
        public double cisdLevel;
        public long cisdSweepTime;
        public long id;
        public long setupId;
        public int setupIdx;
        public long obId;
        public int kind;
        public int dir;
        public int retestNo;
        public long retestTime;
        public double retestPrice;
        public long cisdStartTime;
        public long activatedTime;
        public int cisdBars;
        public ConnState state;
        public long stateTime;
        public long sweepTime;
        public double sweepPrice;
        public long sweepSwingTime;
        public double sweepSwingPrice;
        public bool hasCISD;
        public long cisdId;
        public int cisdCount;
        public long lastSeenCisdId;
        public CisdRecord cisd = new CisdRecord();
        public long retraceTime;
        public double retracePrice;
        public long endTime;
    }

    public class ConnCisdHit
    {
        public long setupId;
        public long seqId;
        public long obId;
        public int kind;
        public int dir;
        public int retestNo;
        public long cisdId;
        public long confirmTime;
        public double confirmPrice;
        public long retraceTime;
        public double retracePrice;
        public CisdState cisdState;
        public CisdRecord cisd;
    }

    public struct ConnEvent
    {
        public ConnEventType type;
        public long setupId;
        public long seqId;
        public long obId;
        public int kind;
        public int dir;
        public int retestNo;
        public long cisdId;
        public long time;
        public double price;
        public double trendScore;
        public double cisdLevel;
        public long sweepTime;
        public bool historical;
    }

    public struct ConnStats
    {
        public int trendFiltered, registered, retests, retestsIgnored, sequences, activated, sweepStage;
        public int confirmedStd, confirmedZ, confirmedBull, confirmedBear, cisdHits, multiExtra, retraced, completed;
        public int obInvalidated, invalidatedBeforeRetest, invalidatedMonitoring, expired, maxConcurrent;
    }

    public struct ConnCandidate
    {
        public long avail;
        public int kind;
        public long id;
    }

    public class SmcConnection
    {
        private ConnSettings m_s;
        private SmcDetector m_std;
        private SmcDetector m_z;
        private readonly List<ConnSetup> m_set = new List<ConnSetup>();
        private readonly List<ConnSeq> m_seq = new List<ConnSeq>();
        private readonly List<ConnCisdHit> m_hits = new List<ConnCisdHit>();
        private readonly List<SmcCisdEngine> m_eng = new List<SmcCisdEngine>();   // parallel to m_seq
        private readonly List<Rates> m_buf = new List<Rates>();                  // chronological CISD-timeframe candles
        private int m_bufCap;
        private readonly List<Rates> m_obBuf = new List<Rates>();                // OB-timeframe candles, chronological
        private int m_obCap;
        private Rates[] m_win = new Rates[0];
        private int m_winBars;
        private readonly List<int> m_obIdx = new List<int>();
        private readonly long[] m_lastObId = new long[2];
        private long m_lastM1;
        private long m_lastCISD;
        private int m_obPS;
        private int m_cisdPS;
        private int m_cisdLookback;
        private readonly List<ConnEvent> m_events = new List<ConnEvent>();
        private ConnStats m_st;
        private long m_nextSetupId = 1;
        private long m_nextSeqId = 1;
        private bool m_hist;
        private readonly SmcEnv m_env;

        public SmcConnection(SmcEnv env) { m_env = env; }

        private bool Logs(SmcLogLevel level)
        {
            return m_s.logLevel >= level && !(m_hist && m_s.logLevel < SmcLogLevel.Verbose);
        }

        private void Log(SmcLogLevel level, string msg)
        {
            if (m_s.logLevel < level || (m_hist && m_s.logLevel < SmcLogLevel.Verbose))
                return;
            m_env.Print("[SMC-CONN][" + Smc.TFText(m_s.obTFSeconds) + ">" + Smc.TFText(m_s.cisdTFSeconds) + "]" + (m_hist ? "[hist]" : "") + " " + msg);
        }

        public bool Init(ConnSettings s, SmcDetector stdDet, SmcDetector zDet)
        {
            Reset();
            m_s = s;
            m_std = stdDet;
            m_z = zDet;
            m_obPS = m_s.obTFSeconds;
            m_cisdPS = m_s.cisdTFSeconds;
            if (m_obPS <= 0 || m_cisdPS <= 0 || m_s.maxMonitorBars < 1)
                return false;
            if (m_s.maxRetests < 1)
                m_s.maxRetests = 1;
            SmcCisdEngine probe = new SmcCisdEngine(m_env);
            CisdSettings cs = m_s.cisd;
            cs.timeframeSeconds = m_s.cisdTFSeconds;
            if (!probe.Init(cs))
                return false;
            m_cisdLookback = probe.RequiredLookback;
            m_s.warmupBars = Math.Max(m_s.warmupBars, m_cisdLookback + 10);
            m_bufCap = m_s.warmupBars + m_cisdLookback + 5;
            if (m_s.trendBars < 1)
                m_s.trendBars = 20;
            if (m_s.trendATRPeriod < 1)
                m_s.trendATRPeriod = 14;
            m_obCap = m_s.trendBars + m_s.trendATRPeriod + 5 + Conn.TREND_HISTORY;
            return true;
        }

        public void Reset()
        {
            for (int q = 0; q < m_eng.Count; q++)
                FreeEngine(q);
            m_set.Clear();
            m_seq.Clear();
            m_hits.Clear();
            m_eng.Clear();
            m_buf.Clear();
            m_events.Clear();
            m_obIdx.Clear();
            m_obBuf.Clear();
            m_winBars = 0;
            m_st = new ConnStats();
            m_lastObId[0] = m_lastObId[1] = 0;
            m_lastM1 = 0;
            m_lastCISD = 0;
            m_nextSetupId = 1;
            m_nextSeqId = 1;
        }

        public void SetHistoricalMode(bool on) { m_hist = on; }
        public long LastM1Time { get { return m_lastM1; } }
        public long LastCISDTime { get { return m_lastCISD; } }
        public int CISDLookback { get { return m_cisdLookback; } }
        public ConnSettings Settings { get { return m_s; } }
        public int Count { get { return m_set.Count; } }
        public int SeqCount { get { return m_seq.Count; } }
        public int HitCount { get { return m_hits.Count; } }
        public int EventCount { get { return m_events.Count; } }
        public void ClearEvents() { m_events.Clear(); }

        private void EventSeq(ConnEventType type, int q, long t, double price)
        {
            ConnEvent e = new ConnEvent();
            e.type = type;
            e.setupId = m_seq[q].setupId;
            e.seqId = m_seq[q].id;
            e.obId = m_seq[q].obId;
            e.kind = m_seq[q].kind;
            e.dir = m_seq[q].dir;
            e.retestNo = m_seq[q].retestNo;
            e.cisdId = m_seq[q].cisdId;
            e.time = t;
            e.price = price;
            e.trendScore = m_seq[q].trendScore;
            e.cisdLevel = m_seq[q].cisdLevel;
            e.sweepTime = m_seq[q].cisdSweepTime;
            e.historical = m_hist;
            m_events.Add(e);
        }

        private void EventOB(ConnEventType type, int k, long t, double price)
        {
            ConnEvent e = new ConnEvent();
            e.type = type;
            e.setupId = m_set[k].id;
            e.obId = m_set[k].obId;
            e.kind = m_set[k].kind;
            e.dir = m_set[k].dir;
            e.time = t;
            e.price = price;
            e.historical = m_hist;
            m_events.Add(e);
        }

        //--- when the end of the OB became known (0 = still valid as far as the detector knows)
        private long DeadKnown(SmcOrderBlock o, out bool byMitigation)
        {
            long dead = 0;
            switch (o.state)
            {
                case SmcObState.Invalidated: dead = o.invalidatedTime + m_obPS; break;
                case SmcObState.Expired: dead = o.expiredTime + m_obPS; break;   // not endTime: may be an earlier mitigation
                case SmcObState.Superseded: dead = o.endTime + m_obPS; break;
                default: break;
            }
            //--- option: mitigation ends the CISD search too (known when the mitigating candle closes)
            byMitigation = false;
            if (m_s.stopOnMitigation && o.mitigatedTime > 0)
            {
                long mit = o.mitigatedTime + m_obPS;
                if (dead == 0 || mit < dead)
                {
                    dead = mit;
                    byMitigation = true;
                }
            }
            return dead;
        }

        private void Collect(SmcDetector det, int kind, bool use, List<ConnCandidate> cand)
        {
            if (det == null)
                return;
            long maxId = m_lastObId[kind];
            int n = det.OBCount;
            for (int k = 0; k < n; k++)
            {
                if (det.OBIdAt(k) <= m_lastObId[kind])          // id only: no struct copy for known OBs
                    continue;
                SmcOrderBlock o;
                if (!det.GetOB(k, out o))
                    continue;
                maxId = Math.Max(maxId, o.id);
                long avail = o.confirmTime + m_obPS;
                if (!use || avail < m_s.windowStart)
                    continue;
                ConnCandidate c = new ConnCandidate();
                c.avail = avail;
                c.kind = kind;
                c.id = o.id;
                cand.Add(c);
            }
            m_lastObId[kind] = maxId;
        }

        private void Register(ConnCandidate c)
        {
            SmcDetector det = (c.kind == Conn.KIND_ZORDER) ? m_z : m_std;
            int idx = det.FindById(c.id);
            SmcOrderBlock o;
            if (idx < 0 || !det.GetOB(idx, out o))
                return;
            ConnSetup x = new ConnSetup();
            x.id = m_nextSetupId++;
            x.kind = c.kind;
            x.obId = o.id;
            x.dir = o.dir;
            x.obTime = o.isZOrder ? o.seriesStartTime : o.obTime;
            x.obConfirmTime = o.confirmTime;
            x.availTime = c.avail;
            x.top = o.top;
            x.bottom = o.bottom;
            x.deadKnown = DeadKnown(o, out x.deadByMitigation);
            x.state = ConnState.ObCreated;
            x.stateTime = c.avail;
            m_set.Add(x);
            m_st.registered++;
        }

        public void SyncOBs()
        {
            //--- refresh what is known about the end of monitored OBs
            int ns = m_set.Count;
            while (m_obIdx.Count < ns)
                m_obIdx.Add(-1);
            for (int k = 0; k < ns; k++)
            {
                if (m_set[k].state == ConnState.Invalidated)
                    continue;
                SmcDetector det = (m_set[k].kind == Conn.KIND_ZORDER) ? m_z : m_std;
                if (det == null)
                    continue;
                int idx = m_obIdx[k];
                if (idx < 0 || det.OBIdAt(idx) != m_set[k].obId)
                {
                    idx = det.FindById(m_set[k].obId);
                    m_obIdx[k] = idx;
                }
                //--- a live OB has no end yet, and a dead one never becomes live again: one copy is enough.
                //--- With stopOnMitigation a mitigated (still live) OB also ends the search.
                SmcObState ost = (idx >= 0) ? det.OBStateAt(idx) : SmcObState.Active;
                if (idx >= 0 && m_set[k].deadKnown == 0 &&
                    (!Smc.IsLiveState(ost) || (m_s.stopOnMitigation && ost == SmcObState.Mitigated)))
                {
                    SmcOrderBlock o;
                    if (det.GetOB(idx, out o))
                        m_set[k].deadKnown = DeadKnown(o, out m_set[k].deadByMitigation);
                }
            }

            //--- register new OBs in deterministic (availability, kind, id) order
            List<ConnCandidate> cand = new List<ConnCandidate>();
            Collect(m_std, Conn.KIND_STANDARD, m_s.useStandard, cand);
            Collect(m_z, Conn.KIND_ZORDER, m_s.useZOrder, cand);
            int n = cand.Count;
            for (int a = 1; a < n; a++)
            {
                ConnCandidate key = cand[a];
                int b = a - 1;
                while (b >= 0 && (cand[b].avail > key.avail || (cand[b].avail == key.avail &&
                                  (cand[b].kind > key.kind || (cand[b].kind == key.kind && cand[b].id > key.id)))))
                {
                    cand[b + 1] = cand[b];
                    b--;
                }
                cand[b + 1] = key;
            }
            for (int a = 0; a < n; a++)
                Register(cand[a]);
        }

        //--- OB-timeframe candles kept for the trend filter. Only closed bars are pushed.
        public void ProcessOBBar(Rates bar)
        {
            int n = m_obBuf.Count;
            if (n > 0 && bar.time <= m_obBuf[n - 1].time)
                return;                                   // each candle once, chronological
            if (m_obCap > 0 && n >= m_obCap)
                m_obBuf.RemoveAt(0);
            m_obBuf.Add(bar);
        }

        public int ProcessOBWindow(Rates[] r, int size)
        {
            int n = 0;
            for (int i = size - 1; i >= 0; i--)                 // series order: oldest first
            {
                int before = m_obBuf.Count;
                ProcessOBBar(r[i]);
                if (m_obBuf.Count != before || (before > 0 && m_obBuf[before - 1].time == r[i].time))
                    n++;
            }
            return n;
        }

        //--- Trend filter: displacement over trendBars OB candles, measured in ATR,
        //--- using only candles that had closed at 'when'.
        //---   score = (close - close[trendBars ago]) / ATR
        public bool TrendOK(int dir, long when, out double score)
        {
            score = 0.0;
            if (!m_s.trendFilter)
                return true;
            int n = m_obBuf.Count;
            //--- newest candle that had already closed at 'when'
            int last = -1;
            for (int k = n - 1; k >= 0; k--)
                if (m_obBuf[k].time + m_obPS <= when)
                {
                    last = k;
                    break;
                }
            if (last < m_s.trendBars || last < m_s.trendATRPeriod)
                return false;                              // not enough closed history: no trend evidence

            double tr = 0.0;
            int cnt = 0;
            for (int k = last; k > 0 && cnt < m_s.trendATRPeriod; k--, cnt++)
            {
                double h = m_obBuf[k].high, l = m_obBuf[k].low, pc = m_obBuf[k - 1].close;
                tr += Math.Max(h - l, Math.Max(Math.Abs(h - pc), Math.Abs(l - pc)));
            }
            if (cnt < 1)
                return false;
            double atr = tr / cnt;
            if (atr <= 0.0)
                return false;
            score = (m_obBuf[last].close - m_obBuf[last - m_s.trendBars].close) / atr;
            if (Math.Abs(score) < m_s.trendATRMult)
                return false;                              // ranging
            return (dir == Smc.DIR_BULL) ? (score > 0.0) : (score < 0.0);
        }

        private void FreeEngine(int q)
        {
            if (q < 0 || q >= m_eng.Count)
                return;
            m_eng[q] = null;
        }

        private void TerminalSeq(int q, ConnState st, long t)
        {
            m_seq[q].state = st;
            m_seq[q].stateTime = t;
            m_seq[q].endTime = t;
            FreeEngine(q);
            switch (st)
            {
                case ConnState.Retracement: EventSeq(ConnEventType.Retraced, q, t, m_seq[q].retracePrice); break;
                case ConnState.Completed: EventSeq(ConnEventType.Completed, q, t, m_seq[q].cisd.confirmPrice); break;
                case ConnState.Invalidated: EventSeq(ConnEventType.Invalidated, q, t, 0.0); break;
                case ConnState.Expired: EventSeq(ConnEventType.Expired, q, t, 0.0); break;
                default: break;
            }
            if (Logs(SmcLogLevel.Events))
                Log(SmcLogLevel.Events, string.Format("{0} {1} #{2} retest #{3} (seq #{4}) -> {5} @ {6}", Smc.DirText(m_seq[q].dir),
                    Conn.KindText(m_seq[q].kind), m_seq[q].obId, m_seq[q].retestNo, m_seq[q].id,
                    Conn.StateText(st), SmcEnv.T(t)));
        }

        private void NewSequence(int k, Rates bar)
        {
            ConnSeq s = new ConnSeq();
            s.id = m_nextSeqId++;
            s.setupId = m_set[k].id;
            s.setupIdx = k;
            s.obId = m_set[k].obId;
            s.kind = m_set[k].kind;
            s.dir = m_set[k].dir;
            s.retestNo = m_set[k].retestCount;
            s.retestTime = bar.time;
            s.retestPrice = (m_set[k].dir == Smc.DIR_BULL) ? Math.Max(bar.low, m_set[k].bottom)
                                                           : Math.Min(bar.high, m_set[k].top);
            s.cisdStartTime = Conn.AlignUp(bar.time, m_cisdPS);
            s.state = ConnState.ObRetested;
            s.stateTime = bar.time;

            int n = m_seq.Count;
            m_seq.Add(s);
            m_eng.Add(null);

            m_set[k].seqCount++;
            if (m_set[k].retestTime == 0)
            {
                m_set[k].retestTime = s.retestTime;
                m_set[k].retestPrice = s.retestPrice;
                m_set[k].cisdStartTime = s.cisdStartTime;
            }
            m_st.sequences++;
            EventSeq(ConnEventType.Retest, n, bar.time, s.retestPrice);
            if (Logs(SmcLogLevel.Events))
                Log(SmcLogLevel.Events, string.Format("{0} {1} #{2} RETEST #{3} @ {4} ({5}) -> {6} CISD sequence #{7} from {8}",
                    Smc.DirText(s.dir), Conn.KindText(s.kind), s.obId, s.retestNo,
                    SmcEnv.T(bar.time), m_env.Price(s.retestPrice),
                    Smc.TFText(m_s.cisdTFSeconds), s.id, SmcEnv.T(s.cisdStartTime)));
        }

        //--- M1 closed candle: OB validity, retests and new sequences
        public bool ProcessM1Bar(Rates bar)
        {
            if (bar.time <= m_lastM1)
                return false;
            m_lastM1 = bar.time;
            for (int k = 0; k < m_set.Count; k++)
            {
                ConnSetup x = m_set[k];
                if (x.state == ConnState.Invalidated)
                    continue;
                if (bar.time < x.availTime)
                    continue;                                          // OB not confirmed yet at this candle

                //--- invalidation is absolute: the OB can never start another sequence
                if (x.deadKnown > 0 && x.deadKnown <= bar.time)
                {
                    x.state = ConnState.Invalidated;
                    x.stateTime = x.deadKnown;
                    x.endTime = x.deadKnown;
                    x.touching = false;
                    m_st.obInvalidated++;
                    EventOB(ConnEventType.ObInvalidated, k, x.deadKnown, 0.0);
                    if (Logs(SmcLogLevel.Events))
                        Log(SmcLogLevel.Events, string.Format("{0} {1} #{2} {3} @ {4} - CISD monitoring stopped",
                            Smc.DirText(x.dir), Conn.KindText(x.kind), x.obId,
                            x.deadByMitigation ? "MITIGATED" : "INVALIDATED", SmcEnv.T(x.deadKnown)));
                    continue;
                }

                if (x.state == ConnState.ObCreated)
                {
                    x.state = ConnState.WaitingForRetest;
                    x.stateTime = bar.time;
                }

                //--- a retest is a fresh entry into the zone (price must have left it first)
                bool touching = (bar.low <= x.top && bar.high >= x.bottom);
                if (touching && !x.touching)
                {
                    x.retestCount++;
                    x.state = ConnState.ObRetested;
                    x.stateTime = bar.time;
                    m_st.retests++;
                    bool allow = (m_s.multiRetest || x.seqCount == 0) && (x.seqCount < m_s.maxRetests);
                    if (allow)
                        NewSequence(k, bar);
                    else
                    {
                        m_st.retestsIgnored++;
                        if (Logs(SmcLogLevel.Verbose))
                            Log(SmcLogLevel.Verbose, string.Format("{0} {1} #{2} retest #{3} ignored ({4})", Smc.DirText(x.dir),
                                Conn.KindText(x.kind), x.obId, x.retestCount,
                                m_s.multiRetest ? "retest cap reached" : "SINGLE retest mode"));
                    }
                }
                x.touching = touching;

                //--- option: mitigation stops the CISD search. Checked on EVERY M1 candle.
                if (m_s.stopOnMitigation && m_s.mitigationMode != (int)SmcMitigationMode.Off && x.mitM1Time == 0)
                {
                    bool bull = (x.dir == Smc.DIR_BULL);
                    double mid = (x.top + x.bottom) / 2.0;
                    bool mit;
                    if (m_s.mitigationMode == (int)SmcMitigationMode.Touch)
                        mit = bull ? (bar.low <= x.top) : (bar.high >= x.bottom);
                    else if (m_s.mitigationMode == (int)SmcMitigationMode.Midpoint)
                        mit = bull ? (bar.low <= mid) : (bar.high >= mid);
                    else
                        mit = bull ? (bar.low <= x.bottom) : (bar.high >= x.top);
                    if (mit)
                    {
                        x.mitM1Time = bar.time;
                        long known = bar.time + 60;        // close of this M1 candle
                        if (x.deadKnown == 0 || known < x.deadKnown)
                        {
                            x.deadKnown = known;
                            x.deadByMitigation = true;
                        }
                    }
                }
            }
            return true;
        }

        //--- CISD-timeframe closed candle: activation and per-sequence engines
        public bool ProcessCISDBar(Rates bar)
        {
            if (bar.time <= m_lastCISD)
                return false;
            m_lastCISD = bar.time;

            if (m_buf.Count >= m_bufCap)
                m_buf.RemoveAt(0);                       // drop the oldest candle
            m_buf.Add(bar);
            m_winBars = 0;                               // the shared window belongs to the previous candle

            long tc = bar.time + m_cisdPS;
            for (int q = 0; q < m_seq.Count; q++)
            {
                ConnState st = m_seq[q].state;
                if (Conn.Terminal(st))
                    continue;
                int k = m_seq[q].setupIdx;
                long dead = (k >= 0 && k < m_set.Count) ? m_set[k].deadKnown : 0;

                //--- OB invalidation stops the sequence in every mode, before anything else is evaluated
                if (dead > 0 && dead < tc)
                {
                    if (m_seq[q].hasCISD)
                    {
                        m_st.completed++;                              // confirmed CISDs are preserved
                        TerminalSeq(q, ConnState.Completed, dead);
                    }
                    else
                    {
                        if (st == ConnState.ObRetested) m_st.invalidatedBeforeRetest++;
                        else m_st.invalidatedMonitoring++;
                        TerminalSeq(q, ConnState.Invalidated, dead);
                    }
                    continue;
                }

                if (st == ConnState.ObRetested)
                {
                    if (bar.time < m_seq[q].cisdStartTime)
                        continue;
                    Activate(q, bar);
                }
                else
                {
                    Feed(q);
                    Evaluate(q, tc);
                }
            }
            m_st.maxConcurrent = Math.Max(m_st.maxConcurrent, ActiveCount());
            return true;
        }

        private void Activate(int q, Rates bar)
        {
            SmcCisdEngine e = new SmcCisdEngine(m_env);
            CisdSettings cs = m_s.cisd;
            cs.timeframeSeconds = m_s.cisdTFSeconds;
            cs.activationTime = m_seq[q].cisdStartTime;       // confirmation must be at/after the retest
            cs.activationMode = CisdActivation.ConfirmAfter;  // the candle series itself may start earlier
            cs.dirFilter = m_seq[q].dir;                      // CISD direction must match the OB
            cs.logLevel = SmcLogLevel.Off;
            if (!e.Init(cs))
            {
                m_st.expired++;
                TerminalSeq(q, ConnState.Expired, bar.time + m_cisdPS);
                return;
            }
            m_eng[q] = e;

            //--- warm-up: liquidity pools, ATR and any candle series that began before the retest
            int n = m_buf.Count;
            int size = Math.Min(n, m_s.warmupBars + 1);
            Rates[] win = new Rates[size];
            for (int j = 0; j < size; j++)
                win[j] = m_buf[n - 1 - j];
            e.ProcessWindow(win, size);

            m_seq[q].state = ConnState.CisdMonitoring;
            m_seq[q].stateTime = bar.time;
            m_seq[q].activatedTime = bar.time;
            m_seq[q].cisdBars = 0;
            m_st.activated++;
            EventSeq(ConnEventType.Activated, q, bar.time, bar.open);
            if (Logs(SmcLogLevel.Verbose))
                Log(SmcLogLevel.Verbose, string.Format("sequence #{0} (OB #{1} retest #{2}) monitoring from {3}", m_seq[q].id,
                    m_seq[q].obId, m_seq[q].retestNo, SmcEnv.T(bar.time)));
            Evaluate(q, bar.time + m_cisdPS);
        }

        private void Feed(int q)
        {
            if (m_eng[q] == null)
                return;
            //--- every sequence sees the same newest-first window of this candle: build it once and reuse it
            if (m_winBars <= 0)
            {
                int n = m_buf.Count;
                int size = Math.Min(n, m_cisdLookback + 1);
                if (m_win.Length < size)
                    m_win = new Rates[size];
                for (int j = 0; j < size; j++)
                    m_win[j] = m_buf[n - 1 - j];
                m_winBars = size;
            }
            m_eng[q].ProcessBar(m_win, 0, m_winBars);
        }

        //--- record one confirmed CISD of this sequence
        private void AddHit(int q, CisdRecord c)
        {
            int k = m_seq[q].setupIdx;
            ConnCisdHit h = new ConnCisdHit();
            h.setupId = m_seq[q].setupId;
            h.seqId = m_seq[q].id;
            h.obId = m_seq[q].obId;
            h.kind = m_seq[q].kind;
            h.dir = m_seq[q].dir;
            h.retestNo = m_seq[q].retestNo;
            h.cisdId = c.id;
            h.confirmTime = c.confirmTime;
            h.confirmPrice = c.confirmPrice;
            h.cisdState = c.state;
            h.cisd = c.Clone();
            m_hits.Add(h);

            bool first = !m_seq[q].hasCISD;
            m_seq[q].cisdCount++;
            if (k >= 0 && k < m_set.Count)
                m_set[k].cisdCount++;
            m_st.cisdHits++;
            if (first)
            {
                m_seq[q].hasCISD = true;
                m_seq[q].cisdId = c.id;
                m_seq[q].cisd = c.Clone();
                m_seq[q].state = ConnState.CisdConfirmed;
                m_seq[q].stateTime = c.confirmTime;
                if (c.hasSweep)
                {
                    m_seq[q].sweepTime = c.sweepTime;
                    m_seq[q].sweepPrice = c.sweepPrice;
                    m_seq[q].sweepSwingTime = c.sweptSwingTime;
                    m_seq[q].sweepSwingPrice = c.sweptSwingPrice;
                }
                if (m_seq[q].kind == Conn.KIND_ZORDER) m_st.confirmedZ++;
                else m_st.confirmedStd++;
                if (m_seq[q].dir == Smc.DIR_BULL) m_st.confirmedBull++;
                else m_st.confirmedBear++;
            }
            else
                m_st.multiExtra++;

            EventSeq(ConnEventType.Confirmed, q, c.confirmTime, c.confirmPrice);
            if (Logs(SmcLogLevel.Events))
                Log(SmcLogLevel.Events, string.Format("CONFIRMED {0} setup{1}: {2} {3} #{4} retest #{5} + {6} CISD #{7} close {8} @ {9}{10}",
                    Smc.DirText(m_seq[q].dir),
                    first ? "" : string.Format(" (CISD {0} of this sequence)", m_seq[q].cisdCount),
                    Smc.TFText(m_s.obTFSeconds), Conn.KindText(m_seq[q].kind), m_seq[q].obId,
                    m_seq[q].retestNo, Smc.TFText(m_s.cisdTFSeconds), c.id,
                    m_env.Price(c.confirmPrice), SmcEnv.T(c.confirmTime),
                    c.seriesStartTime < m_seq[q].cisdStartTime ? " (series began before the retest)" : ""));
        }

        //--- refresh the life-cycle (retracement) of every CISD recorded for this sequence
        private void UpdateHits(int q)
        {
            SmcCisdEngine e = m_eng[q];
            if (e == null)
                return;
            CisdRecord c;
            for (int h = 0; h < m_hits.Count; h++)
            {
                if (m_hits[h].seqId != m_seq[q].id)
                    continue;
                int idx = e.FindById(m_hits[h].cisdId);
                if (idx < 0 || !e.Get(idx, out c))
                    continue;
                m_hits[h].cisd = c.Clone();                         // identity unchanged; life-cycle only
                m_hits[h].cisdState = c.state;
                if (c.state == CisdState.Retraced && m_hits[h].retraceTime == 0)
                {
                    m_hits[h].retraceTime = c.retraceTime;
                    m_hits[h].retracePrice = c.retracePrice;
                    if (m_s.multiCISD)
                    {
                        m_st.retraced++;                          // Single reports this from TerminalSeq()
                        EventSeq(ConnEventType.Retraced, q, c.retraceTime, c.retracePrice);
                        if (Logs(SmcLogLevel.Events))
                            Log(SmcLogLevel.Events, string.Format("sequence #{0} CISD #{1} retracement / entry @ {2}", m_seq[q].id, c.id,
                                SmcEnv.T(c.retraceTime)));
                    }
                }
                if (m_hits[h].cisdId == m_seq[q].cisdId)
                    m_seq[q].cisd = c.Clone();
            }
        }

        private void Evaluate(int q, long closeTime)
        {
            SmcCisdEngine e = m_eng[q];
            if (e == null)
                return;
            m_seq[q].cisdBars++;
            CisdRecord c;

            //--- new same-direction confirmations; SINGLE stops after the first one
            if (!m_seq[q].hasCISD || m_s.multiCISD)
            {
                for (int j = 0; j < e.Count; j++)
                {
                    if (!e.Get(j, out c) || c.dir != m_seq[q].dir || !CisdUtil.ConfirmedState(c.state) || c.id <= m_seq[q].lastSeenCisdId)
                        continue;
                    m_seq[q].lastSeenCisdId = c.id;
                    double tscore;
                    if (!TrendOK(m_seq[q].dir, c.confirmTime, out tscore))
                    {
                        m_st.trendFiltered++;                 // valid CISD, rejected by the trend filter
                        if (Logs(SmcLogLevel.Verbose))
                            Log(SmcLogLevel.Verbose, string.Format("{0} {1} #{2} + CISD #{3} rejected by the trend filter " +
                                "(score {4}, needs {5}{6})", Smc.DirText(m_seq[q].dir),
                                Conn.KindText(m_seq[q].kind), m_seq[q].obId, c.id, Smc.F2(tscore),
                                m_seq[q].dir == Smc.DIR_BULL ? "+" : "-", Smc.F2(m_s.trendATRMult)));
                        continue;
                    }
                    m_seq[q].trendScore = tscore;        // kept for the trade layer's confidence score
                    m_seq[q].cisdLevel = c.level;
                    m_seq[q].cisdSweepTime = c.hasSweep ? c.sweepTime : 0;
                    AddHit(q, c);
                    if (!m_s.multiCISD)
                        break;
                }
            }

            if (!m_seq[q].hasCISD)
            {
                if (e.SweepCount > 0)
                {
                    CisdSweep sw;
                    e.GetSweep(e.SweepCount - 1, out sw);
                    m_seq[q].sweepTime = sw.time;
                    m_seq[q].sweepPrice = sw.price;
                    m_seq[q].sweepSwingTime = sw.swingTime;
                    m_seq[q].sweepSwingPrice = sw.swingPrice;
                    if (m_seq[q].state == ConnState.CisdMonitoring)
                    {
                        m_seq[q].state = ConnState.CisdSweepDetected;
                        m_seq[q].stateTime = sw.time;
                        m_st.sweepStage++;
                        EventSeq(ConnEventType.Sweep, q, sw.time, sw.price);
                    }
                }
                if (m_seq[q].cisdBars >= m_s.maxMonitorBars)
                {
                    m_st.expired++;
                    TerminalSeq(q, ConnState.Expired, closeTime);
                }
                return;
            }

            UpdateHits(q);

            //--- MULTI CISD: keep collecting from this sequence until the window ends
            if (m_s.multiCISD)
            {
                if (m_seq[q].cisdBars >= m_s.maxMonitorBars)
                {
                    m_st.completed++;
                    TerminalSeq(q, ConnState.Completed, closeTime);
                }
                return;
            }

            //--- SINGLE CISD: confirmed -> retracement / completion
            if (!m_s.cisd.useRetrace)
            {
                m_st.completed++;
                TerminalSeq(q, ConnState.Completed, closeTime);
                return;
            }
            if (m_seq[q].cisd.state == CisdState.Retraced)
            {
                m_seq[q].retraceTime = m_seq[q].cisd.retraceTime;
                m_seq[q].retracePrice = m_seq[q].cisd.retracePrice;
                m_st.retraced++;
                TerminalSeq(q, ConnState.Retracement, m_seq[q].retraceTime);
            }
            else if (m_seq[q].cisd.endTime != 0)
            {
                m_st.completed++;
                TerminalSeq(q, ConnState.Completed, closeTime);
            }
        }

        public int ProcessM1Window(Rates[] r, int size, long horizon)
        {
            int n = 0;
            for (int i = size - 1; i >= 0; i--)
            {
                if (r[i].time <= m_lastM1)
                    continue;
                if (r[i].time + 60 > horizon)
                    break;
                if (ProcessM1Bar(r[i]))
                    n++;
            }
            return n;
        }

        public int ProcessCISDWindow(Rates[] r, int size, long horizon)
        {
            int n = 0;
            for (int i = size - 1; i >= 0; i--)
            {
                if (r[i].time <= m_lastCISD)
                    continue;
                if (r[i].time + m_cisdPS > horizon || r[i].time + m_cisdPS > m_lastM1 + 60)
                    break;                                          // OB / retest knowledge must cover the candle
                if (ProcessCISDBar(r[i]))
                    n++;
            }
            return n;
        }

        public int ActiveCount()
        {
            int n = 0;
            for (int q = 0; q < m_seq.Count; q++)
                if (Conn.Monitoring(m_seq[q].state))
                    n++;
            return n;
        }

        public bool GetEvent(int idx, out ConnEvent e)
        {
            e = new ConnEvent();
            if (idx < 0 || idx >= m_events.Count)
                return false;
            e = m_events[idx];
            return true;
        }

        public string StatsText()
        {
            int waiting = 0, dead = 0;
            for (int k = 0; k < m_set.Count; k++)
            {
                if (m_set[k].state == ConnState.Invalidated) dead++;
                else if (m_set[k].state != ConnState.ObRetested) waiting++;
            }
            ConnStats s = m_st;
            return string.Format("source std/zorder={0}/{1} retest={2} cisd={3} | OBs={4} (waiting {5}, invalidated {6}) | " +
                                 "retests={7} (ignored {8}) sequences={9} activated={10} sweep={11} | CONFIRMED std/zorder={12}/{13} bull/bear={14}/{15} | " +
                                 "CISDs={16} (extra {17}) | retraced={18} completed={19} | invalidated beforeCISD/monitoring={20}/{21} expired={22} | " +
                                 "active now={23} max concurrent={24}",
                                 m_s.useStandard ? "ON" : "OFF", m_s.useZOrder ? "ON" : "OFF",
                                 m_s.multiRetest ? "MULTI" : "SINGLE", m_s.multiCISD ? "MULTI" : "SINGLE",
                                 s.registered, waiting, dead, s.retests, s.retestsIgnored, s.sequences,
                                 s.activated, s.sweepStage, s.confirmedStd, s.confirmedZ, s.confirmedBull,
                                 s.confirmedBear, s.cisdHits, s.multiExtra, s.retraced, s.completed,
                                 s.invalidatedBeforeRetest, s.invalidatedMonitoring, s.expired,
                                 ActiveCount(), s.maxConcurrent) +
                   (m_s.stopOnMitigation ? " | mitigation stops CISD=ON" : "") +
                   (m_s.trendFilter ? string.Format(" | trend filter=ON ({0} bars, {1} ATR), rejected {2}",
                                                    m_s.trendBars, Smc.F2(m_s.trendATRMult), s.trendFiltered) : "");
        }
    }

    #endregion

    #region Capital guard (SMC_OB_Guards.mqh)

    public class SmcCapitalGuard
    {
        //--- settings
        private bool m_on;
        private double m_dailyPct;
        private double m_weeklyPct;
        private int m_maxConsec;
        private double m_equityStopPct;
        private double m_spreadPctOfR;
        private double m_volSpikeMult;
        private int m_volAvgBars = 200;

        //--- state
        private bool m_ready;
        private long m_dayStart;
        private long m_weekStart;
        private double m_dayRealised;
        private double m_weekRealised;
        private double m_peakEquity;
        private int m_consec;
        private long m_lastLossTime;
        private bool m_halted;
        private bool m_flatten;
        private GuardBlock m_lastBlock = GuardBlock.Ok;
        private int m_refused;

        //--- platform hooks
        public Func<long> Now = delegate { return 0L; };
        public Func<double> Equity = delegate { return 0.0; };
        public Func<double> SpreadPrice = delegate { return 0.0; };          // SYMBOL_SPREAD * SYMBOL_POINT
        public Func<int, double[]> AtrHistory = delegate (int n) { return null; };   // oldest -> newest, null if not enough
        public Action<string> Print = delegate (string s) { };

        public static string Name(GuardBlock g)
        {
            switch (g)
            {
                case GuardBlock.DailyLoss: return "daily loss limit";
                case GuardBlock.WeeklyLoss: return "weekly loss limit";
                case GuardBlock.ConsecLosses: return "losing streak";
                case GuardBlock.EquityStop: return "equity stop";
                case GuardBlock.Spread: return "spread too wide";
                case GuardBlock.Volatility: return "volatility spike";
            }
            return "none";
        }

        //--- midnight of the day t falls in
        public static long DayOf(long t)
        {
            DateTime d = SmcEnv.FromSec(t);
            return SmcEnv.ToSec(d.Date);
        }

        //--- Midnight of that week's Monday (Sunday keeps its own midnight, as in the MQL5 code)
        public static long WeekOf(long t)
        {
            DateTime d = SmcEnv.FromSec(t);
            int dow = (int)d.DayOfWeek;              // Sunday = 0, as MqlDateTime.day_of_week
            int back = (dow == 0) ? 0 : dow - 1;
            return DayOf(t) - back * 86400L;
        }

        public void Configure(bool on, double dailyPct, double weeklyPct, int maxConsec, double equityStopPct,
                              double spreadPctOfR, double volSpikeMult, int volAvgBars)
        {
            m_on = on;
            m_dailyPct = Math.Max(0.0, dailyPct);
            m_weeklyPct = Math.Max(0.0, weeklyPct);
            m_maxConsec = Math.Max(0, maxConsec);
            m_equityStopPct = Math.Max(0.0, equityStopPct);
            m_spreadPctOfR = Math.Max(0.0, spreadPctOfR);
            m_volSpikeMult = Math.Max(0.0, volSpikeMult);
            m_volAvgBars = Math.Max(20, volAvgBars);
            m_ready = true;
            if (m_on)
                Print("[SMC-GUARD] capital protection ON: " + Settings());
            else
                Print("[SMC-GUARD] capital protection OFF");
        }

        //--- A fresh run must not inherit the last one's counters.
        public void ResetState()
        {
            long now = Now();
            m_dayStart = DayOf(now);
            m_weekStart = WeekOf(now);
            m_dayRealised = 0.0;
            m_weekRealised = 0.0;
            m_peakEquity = Equity();
            m_consec = 0;
            m_lastLossTime = 0;
            m_halted = false;
            m_flatten = false;
            m_refused = 0;
            m_lastBlock = GuardBlock.Ok;
        }

        //--- Called every tick. Rolls the day and week baselines, tracks the equity peak, fires the equity stop.
        public bool Update()
        {
            if (!m_ready || !m_on)
                return false;
            long now = Now();
            if (DayOf(now) != m_dayStart)
            {
                m_dayStart = DayOf(now);
                m_dayRealised = 0.0;
            }
            if (WeekOf(now) != m_weekStart)
            {
                m_weekStart = WeekOf(now);
                m_weekRealised = 0.0;
            }
            double equity = Equity();
            if (equity > m_peakEquity)
                m_peakEquity = equity;
            if (m_equityStopPct > 0.0 && !m_halted && m_peakEquity > 0.0 &&
                equity < m_peakEquity * (1.0 - m_equityStopPct / 100.0))
            {
                m_halted = true;
                m_flatten = true;
                Print(string.Format(CultureInfo.InvariantCulture,
                    "[SMC-GUARD] EQUITY STOP: {0:0.00} is {1:0.00}% below the peak of {2:0.00}. Flattening, and no new trades until the halt is cleared.",
                    equity, 100.0 * (m_peakEquity - equity) / m_peakEquity, m_peakEquity));
                return true;
            }
            return false;
        }

        public void OnTradeClosed(double profit)
        {
            if (!m_ready)
                return;
            m_dayRealised += profit;
            m_weekRealised += profit;
            if (profit < 0.0)
            {
                m_consec++;
                m_lastLossTime = Now();
                if (m_on && m_maxConsec > 0 && m_consec >= m_maxConsec)
                    Print(string.Format("[SMC-GUARD] {0} losses in a row: paused until the next session", m_consec));
            }
            else
                m_consec = 0;
        }

        public bool NewSessionSinceLastLoss()
        {
            if (m_lastLossTime == 0)
                return true;
            return DayOf(Now()) > DayOf(m_lastLossTime);
        }

        public bool SpreadTooWide(double riskPrice)
        {
            if (m_spreadPctOfR <= 0.0 || riskPrice <= 0.0)
                return false;
            double spread = SpreadPrice();
            if (spread <= 0.0)
                return false;
            return spread > m_spreadPctOfR / 100.0 * riskPrice;
        }

        public bool VolatilitySpike()
        {
            if (m_volSpikeMult <= 0.0)
                return false;
            int need = m_volAvgBars;
            double[] a = AtrHistory(need);
            if (a == null || a.Length < need)
                return false;                            // not enough history yet: do not block
            double sum = 0.0;
            for (int i = 0; i < need; i++)
                sum += a[i];
            double avg = sum / need;
            if (avg <= 0.0)
                return false;
            return a[need - 1] > m_volSpikeMult * avg;
        }

        public bool AllowNewTrade(double riskPrice)
        {
            m_lastBlock = GuardBlock.Ok;
            if (!m_ready || !m_on)
                return true;

            if (m_halted)
                m_lastBlock = GuardBlock.EquityStop;
            else
            {
                double equity = Equity();
                double dayBase = equity - m_dayRealised;
                double weekBase = equity - m_weekRealised;
                if (m_dailyPct > 0.0 && dayBase > 0.0 &&
                    m_dayRealised <= -m_dailyPct / 100.0 * dayBase)
                    m_lastBlock = GuardBlock.DailyLoss;
                else if (m_weeklyPct > 0.0 && weekBase > 0.0 &&
                         m_weekRealised <= -m_weeklyPct / 100.0 * weekBase)
                    m_lastBlock = GuardBlock.WeeklyLoss;
                else if (m_maxConsec > 0 && m_consec >= m_maxConsec && !NewSessionSinceLastLoss())
                    m_lastBlock = GuardBlock.ConsecLosses;
                else if (SpreadTooWide(riskPrice))
                    m_lastBlock = GuardBlock.Spread;
                else if (VolatilitySpike())
                    m_lastBlock = GuardBlock.Volatility;
            }

            if (m_lastBlock == GuardBlock.Ok)
                return true;
            m_refused++;
            Print("[SMC-GUARD] refused: " + Name(m_lastBlock));
            return false;
        }

        public bool FlattenRequested { get { return m_flatten; } }
        public void ClearFlatten() { m_flatten = false; }
        public bool Enabled { get { return m_on; } }
        public bool Halted { get { return m_halted; } }
        public GuardBlock LastBlock { get { return m_lastBlock; } }

        public string Settings()
        {
            string s = "";
            if (m_dailyPct > 0.0) s += string.Format(CultureInfo.InvariantCulture, "day -{0:0.0}% ", m_dailyPct);
            if (m_weeklyPct > 0.0) s += string.Format(CultureInfo.InvariantCulture, "week -{0:0.0}% ", m_weeklyPct);
            if (m_maxConsec > 0) s += string.Format("streak {0} ", m_maxConsec);
            if (m_equityStopPct > 0.0) s += string.Format(CultureInfo.InvariantCulture, "equity -{0:0.0}% ", m_equityStopPct);
            if (m_spreadPctOfR > 0.0) s += string.Format(CultureInfo.InvariantCulture, "spread {0:0.0}% of R ", m_spreadPctOfR);
            if (m_volSpikeMult > 0.0) s += string.Format(CultureInfo.InvariantCulture, "vol {0:0.0}x ", m_volSpikeMult);
            if (s.Length == 0)
                s = "nothing armed";
            return s;
        }
    }

    #endregion

    #region Confidence score (SMC_OB_Confidence.mqh)

    public class SmcConfidence
    {
        public double total, trend, quality, impulse, freshness, retest, height, fvg, cisd, spread, session, sweep;
        public double trendScore, relStrength, bodyPct, impulseATR, ageBars;
        public int retestNo;
        public double zoneATR, confirmBeyondATR, spreadPctOfR;
        public int hour;
        public double sweepAgeBars;

        //--- 0 at lo, 1 at hi, flat outside
        public static double Norm(double v, double lo, double hi)
        {
            if (hi <= lo)
                return 0.0;
            return Math.Max(0.0, Math.Min(1.0, (v - lo) / (hi - lo)));
        }

        //--- 1 inside the band, decaying to 0 one band-width outside it
        public static double Band(double v, double lo, double hi)
        {
            if (v >= lo && v <= hi)
                return 1.0;
            double w = Math.Max(hi - lo, 1e-9);
            double d = (v < lo) ? (lo - v) : (v - hi);
            return Math.Max(0.0, 1.0 - d / w);
        }

        public static double SessionWeight(int hour)
        {
            if (hour >= 8 && hour <= 15)
                return 1.0;
            if (hour >= 16 && hour <= 23)
                return 0.8;
            return 0.4;
        }

        public static SmcConfidence Score(SmcOrderBlock ob, double trendScore, int retestNo, double cisdLevel, double confirmPx,
                                          long sweepTime, long signalTime, double riskPrice, double spreadPrice,
                                          int obPeriodSeconds, int cisdPeriodSeconds)
        {
            SmcConfidence c = new SmcConfidence();
            double atr = (ob.atr > 0.0) ? ob.atr : 1.0;

            //--- raw readings
            c.trendScore = trendScore;
            c.relStrength = ob.relStrength;
            c.bodyPct = ob.strongestBodyPct;
            c.impulseATR = Math.Abs(ob.netMove) / atr;
            c.ageBars = (obPeriodSeconds > 0) ? (double)(signalTime - ob.confirmTime) / obPeriodSeconds : 0.0;
            c.retestNo = retestNo;
            c.zoneATR = (ob.top - ob.bottom) / atr;
            c.confirmBeyondATR = (cisdLevel > 0.0) ? Math.Abs(confirmPx - cisdLevel) / atr : 0.0;
            c.spreadPctOfR = (riskPrice > 0.0) ? spreadPrice / riskPrice : 1.0;
            c.hour = SmcEnv.FromSec(signalTime).Hour;
            c.sweepAgeBars = (sweepTime > 0 && cisdPeriodSeconds > 0)
                             ? (double)(signalTime - sweepTime) / cisdPeriodSeconds : -1.0;

            //--- weighted components
            c.trend = 25.0 * Norm(Math.Abs(c.trendScore), 1.5, 3.0);
            c.quality = 18.0 * (0.6 * Norm(c.relStrength, 1.5, 3.0) + 0.4 * Norm(c.bodyPct, 55.0, 75.0));
            c.impulse = 12.0 * Norm(c.impulseATR, 1.5, 3.0);
            c.freshness = 10.0 * (1.0 - Norm(c.ageBars, 10.0, 60.0));
            c.height = 10.0 * Band(c.zoneATR, 0.4, 1.2);
            c.cisd = 9.0 * Norm(c.confirmBeyondATR, 0.0, 0.3);
            c.fvg = 8.0 * (ob.hasFVG ? (ob.fvgLate ? 0.5 : 1.0) : 0.0);
            c.spread = 5.0 * (1.0 - Norm(c.spreadPctOfR, 0.005, 0.03));
            c.session = 3.0 * SessionWeight(c.hour);
            //--- recorded, not scored
            c.retest = 0.0 * (retestNo <= 1 ? 1.0 : (retestNo == 2 ? 0.5 : 0.0));
            c.sweep = 0.0 * ((c.sweepAgeBars < 0.0) ? 0.0 : (c.sweepAgeBars <= 10.0 ? 1.0 : 0.6));

            c.total = c.trend + c.quality + c.impulse + c.freshness + c.retest + c.height +
                      c.fvg + c.cisd + c.spread + c.session + c.sweep;
            return c;
        }

        public static string BandText(double score)
        {
            if (score >= 90.0)
                return "maximum";
            if (score >= 75.0)
                return "normal";
            if (score >= 60.0)
                return "reduced";
            return "below threshold";
        }

        public string Text()
        {
            return string.Format(CultureInfo.InvariantCulture,
                "score {0:0.0} ({1}) | trend {2:0.0} quality {3:0.0} impulse {4:0.0} fresh {5:0.0} retest {6:0.0} " +
                "height {7:0.0} fvg {8:0.0} cisd {9:0.0} spread {10:0.0} session {11:0.0} sweep {12:0.0}",
                total, BandText(total), trend, quality, impulse, freshness,
                retest, height, fvg, cisd, spread, session, sweep);
        }
    }

    #endregion
}
