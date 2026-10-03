//+------------------------------------------------------------------+
//|                                         SMCOrderBlockStrategy.cs |
//|  NinjaTrader 8 port of SMC_OrderBlock_EA.mq5 (v2.00).             |
//|                                                                  |
//|  HTF Order Block (complete opposite-candle series, Open-Last-Ext  |
//|  zone) -> retest on M1 -> LTF CISD confirmation -> trend filter   |
//|  -> market entry, stop at the far side of the block, R:R target.  |
//|                                                                  |
//|  Data series (added in this order, so NinjaTrader delivers bars   |
//|  that close at the same moment in this order):                    |
//|    BIP 0  the chart series (only used for the volatility guard)   |
//|    BIP 1  Order Block timeframe   (H4 / H1 / M15 from the pair)   |
//|    BIP 2  CISD timeframe          (M15 / M5 / M1 from the pair)   |
//|    BIP 3  M1 (retest timestamps)                                  |
//|  This reproduces the MT5 OnTick order: OB bars first, then the    |
//|  connection processes M1 candles before CISD candles.             |
//|                                                                  |
//|  All engine logic lives in SMCZobEngines.cs and is a line-for-    |
//|  line port of the .mqh files. Panel, theme and chart-object code  |
//|  of the EA carries no trading logic and is not ported; panel      |
//|  defaults come from the inputs exactly as in the EA.              |
//+------------------------------------------------------------------+
#region Using declarations
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.ComponentModel.DataAnnotations;
using System.Globalization;
using System.IO;
using System.Windows.Media;
using System.Xml.Serialization;
using NinjaTrader.Cbi;
using NinjaTrader.Data;
using NinjaTrader.Gui;
using NinjaTrader.NinjaScript;
using NinjaTrader.NinjaScript.DrawingTools;
using NinjaTrader.NinjaScript.Strategies.SMCZob;
#endregion

namespace NinjaTrader.NinjaScript.Strategies
{
    public class SMCOrderBlockStrategy : Strategy
    {
        #region State

        private const int M1_CAP = 150000;          // MT5 TryConnScan caps the M1 history at 150000 bars

        private SmcEnv g_env;
        private SmcDetector g_detector;
        private SmcCisdEngine g_cisd;
        private SmcConnection g_conn;
        private SmcCapitalGuard g_guard;

        private int obIdx = 1, cisdIdx = 2, m1Idx = 3;
        private int g_obPS, g_cisdPS;
        private bool g_invalid;

        //--- chronological closed candles per timeframe (MT5 CopyRates source)
        private readonly List<Rates> g_obBars = new List<Rates>();
        private readonly List<Rates> g_cisdBars = new List<Rates>();
        private readonly List<Rates> g_m1Bars = new List<Rates>();
        private int g_obCapBars, g_cisdCapBars;

        //--- chart-series ATR(14) history for the volatility guard (iATR on PERIOD_CURRENT)
        private readonly List<double> g_chartTR = new List<double>();
        private readonly List<double> g_chartATR = new List<double>();

        //--- EA globals
        private bool g_scanned;
        private long g_lastBarOpen;
        private long g_lastClosedBar;
        private int g_scanFailLogged;
        private bool g_cisdScanned;
        private long g_cisdLastBarOpen;
        private int g_cisdFailLogged;
        private bool g_connScanned;
        private int g_connFailLogged;
        private long g_syncTime;
        private int g_syncStd = -1;
        private bool g_guardReset;

        //--- panel state derived from the inputs (CSMCPanel::Sanitize)
        private int p_swingLength, p_maxOBToBOSBars, p_maxActivePerDir, p_bePoints, p_lots;
        private double p_dispATRMult, p_trendGate, p_targetRR, p_riskPercent;

        //--- trade engine (SMC_OB_TradeHooks.mqh, CSMCTradeEngine)
        private bool t_enabled, t_oppExit, t_ride, t_alerts, t_riskPct, t_beEnabled, t_ready;
        private double t_rr, t_riskPercent;
        private int t_bePoints, t_lots;
        private int t_sent, t_closed, t_beMoved, t_rideExits, t_alerted, t_skipped;
        private string t_last = "";
        private bool t_openPos;              // m_openPosId != 0
        private long t_openObId;
        private double t_openScore;
        private double t_openRiskMoney;
        private long t_openTime;
        private int t_tradeCountAtEntry;
        //--- NinjaTrader order bookkeeping (MT5 position calls are synchronous; NT orders are not)
        private bool o_entryPending;
        private bool o_exitPending;
        private string o_signal = "";
        private int o_seq;
        private long o_posOpenTime;
        private double o_curSL;
        private double o_curTP;

        private StreamWriter g_confWriter;
        private StreamWriter g_resultWriter;

        #endregion

        protected override void OnStateChange()
        {
            if (State == State.SetDefaults)
            {
                Description = "SMC Order Block EA port: HTF order blocks, LTF CISD confirmation, trend filter.";
                Name = "SMCOrderBlockStrategy";
                Calculate = Calculate.OnBarClose;
                EntriesPerDirection = 1;
                EntryHandling = EntryHandling.AllEntries;
                IsExitOnSessionCloseStrategy = false;          // the EA never flattens at a session close
                ExitOnSessionCloseSeconds = 30;
                IsFillLimitOnTouch = false;
                MaximumBarsLookBack = MaximumBarsLookBack.TwoHundredFiftySix;
                OrderFillResolution = OrderFillResolution.Standard;
                Slippage = 0;
                StartBehavior = StartBehavior.WaitUntilFlat;
                TimeInForce = TimeInForce.Gtc;
                TraceOrders = false;
                RealtimeErrorHandling = RealtimeErrorHandling.StopCancelClose;
                StopTargetHandling = StopTargetHandling.PerEntryExecution;
                BarsRequiredToTrade = 0;
                IsInstantiatedOnEachOptimizationIteration = true;

                //--- Market structure
                SwingLength = 4;
                SwingMinATR = 0.5;
                BOSMode = SmcBosMode.Close;
                BOSBufferATR = 0.10;
                //--- Displacement
                ATRPeriod = 14;
                DispATRMult = 2.0;
                DispCandleATRMult = 0.8;
                DispMinBodyPct = 55.0;
                DispMinRelStrength = 1.5;
                MaxOBToBOSBars = 8;
                RejectLegViolation = false;
                //--- Order blocks
                TimeframePair = SmcTfPair.H1_M5;
                EnableBull = true;
                EnableBear = true;
                ExtendBars = 20;
                MaxActivePerDir = 10;
                MaxAgeBars = 0;
                OverlapMode = SmcOverlapMode.SkipNew;
                OverlapPct = 50.0;
                //--- FVG
                FVGMode = SmcFvgMode.Confluence;
                FVGMinATR = 0.05;
                //--- Retest / mitigation
                RetestEnabled = true;
                MitigationMode = SmcMitigationMode.Midpoint;
                InvalidationMode = SmcInvalidationMode.CloseBeyond;
                //--- CISD
                EnableCISD = true;
                CISDSweep = false;
                CISDConfirm = true;
                CISDRetrace = false;
                CISDSwingLength = 3;
                CISDSwingMinATR = 0.3;
                CISDSwingMaxAge = 150;
                CISDSweepMode = CisdSweepMode.TradeThrough;
                CISDSweepValidity = 10;
                CISDLevelMode = CisdLevelMode.SeriesRange;
                CISDMaxSeries = 12;
                CISDMaxConfirmBars = 20;
                CISDMaxRetraceBars = 50;
                CISDScanDepth = 1500;
                //--- HTF OB -> LTF CISD
                ConnEnable = true;
                ConnCISDMode = ConnCisdMode.Single;
                ConnMaxCISDBars = 100;
                ConnWarmupBars = 200;
                ConnRetestMode = ConnRetestMode.Single;
                ConnMaxRetests = 10;
                ConnMitigationStops = true;
                //--- Trading
                TrendFilter = true;
                TrendBars = 20;
                TrendATRMult = 1.5;
                EnableTrading = false;
                Contracts = 1;
                RiskPercentMode = false;
                RiskPercent = 0.50;
                OppositeBlockExit = false;
                TargetRR = 1.0;
                RideTrend = false;
                EntryAlert = true;
                ConfidenceLog = true;
                ConfidenceFile = "SMC_Confidence.csv";
                ResultFile = "SMC_Results.csv";
                BreakEven = false;
                BreakEvenTicks = 100;
                EquityBase = 10000.0;
                //--- Capital protection
                CapitalGuards = false;
                GuardDailyLoss = 2.0;
                GuardWeeklyLoss = 4.0;
                GuardMaxConsec = 5;
                GuardEquityStop = 12.0;
                GuardSpreadPctOfR = 3.0;
                GuardVolSpike = 0.0;
                GuardVolAvgBars = 200;
                //--- History
                ScanDepth = 3000;
                //--- Visualization / diagnostics
                ShowZones = true;
                ShowInactive = false;
                DebugLogLevel = SmcLogLevel.Events;
                AlertsEnabled = false;
            }
            else if (State == State.Configure)
            {
                int pair = (int)TimeframePair;
                int obMin = Smc.IndexMinutes(Smc.PairOBIndex(pair));
                int cisdMin = Smc.IndexMinutes(Smc.PairCISDIndex(pair));
                AddDataSeries(BarsPeriodType.Minute, obMin);     // BIP 1: Order Block timeframe
                AddDataSeries(BarsPeriodType.Minute, cisdMin);   // BIP 2: CISD timeframe
                AddDataSeries(BarsPeriodType.Minute, 1);         // BIP 3: M1 retests
                g_obPS = obMin * 60;
                g_cisdPS = cisdMin * 60;
            }
            else if (State == State.DataLoaded)
            {
                InitAll();
            }
            else if (State == State.Terminated)
            {
                DeinitAll();
            }
        }

        #region Init / deinit (OnInit / OnDeinit)

        private static int ClampI(int v, int lo, int hi) { return Math.Max(lo, Math.Min(hi, v)); }
        private static double ClampD(double v, double lo, double hi) { return Math.Max(lo, Math.Min(hi, v)); }
        private static double MqlRound(double v) { return Math.Round(v, MidpointRounding.AwayFromZero); }

        private void InitAll()
        {
            g_env = new SmcEnv();
            g_env.Print = delegate (string s) { Print(s); };
            g_env.Price = delegate (double p) { return Instrument != null ? Instrument.MasterInstrument.FormatPrice(p) : p.ToString(CultureInfo.InvariantCulture); };

            g_invalid = false;
            if (!ValidateInputs() || !ValidateCISDInputs())
            {
                g_invalid = true;
                return;
            }

            //--- CSMCPanel::Sanitize applied to the input defaults
            p_lots = ClampI(Contracts, 1, 100);
            p_riskPercent = ClampD(MqlRound(RiskPercent * 100.0) / 100.0, 0.05, 10.0);
            p_trendGate = ClampD(MqlRound(TrendATRMult * 100.0) / 100.0, 0.1, 10.0);
            p_targetRR = ClampD(MqlRound(TargetRR * 10.0) / 10.0, 0.1, 20.0);
            p_bePoints = ClampI(BreakEvenTicks, 10, 100000);
            p_swingLength = ClampI(SwingLength, 1, 50);
            p_dispATRMult = ClampD(MqlRound(DispATRMult * 100.0) / 100.0, 0.1, 10.0);
            p_maxOBToBOSBars = ClampI(MaxOBToBOSBars, 1, 100);
            p_maxActivePerDir = ClampI(MaxActivePerDir, 1, 200);

            g_detector = new SmcDetector(g_env);
            if (!g_detector.Init(BuildSettings()))
            {
                Print("[SMC-OB] Detector initialisation failed");
                g_invalid = true;
                return;
            }

            //--- trade engine: Init, then ApplyTradeSettings (panel values override the inputs)
            t_enabled = EnableTrading;
            t_lots = Contracts > 0 ? Contracts : 1;
            t_rr = TargetRR > 0.0 ? TargetRR : 1.0;
            t_beEnabled = BreakEven;
            t_bePoints = BreakEvenTicks > 0 ? BreakEvenTicks : 100;
            t_ride = RideTrend;
            t_alerts = EntryAlert;
            t_riskPct = RiskPercentMode;
            t_riskPercent = RiskPercent > 0.0 ? RiskPercent : 0.5;
            t_ready = true;
            t_sent = t_closed = t_beMoved = t_rideExits = t_alerted = t_skipped = 0;
            t_last = "";

            g_guard = new SmcCapitalGuard();
            g_guard.Print = delegate (string s) { Print(s); };
            g_guard.Now = NowSec;
            g_guard.Equity = GetEquity;
            g_guard.SpreadPrice = CurrentSpread;
            g_guard.AtrHistory = ChartAtrHistory;
            g_guard.Configure(CapitalGuards, GuardDailyLoss, GuardWeeklyLoss, GuardMaxConsec,
                              GuardEquityStop, GuardSpreadPctOfR, GuardVolSpike, GuardVolAvgBars);
            g_guardReset = false;               // ResetState() runs on the first bar (needs a clock)
            ApplyTradeSettings();

            g_obCapBars = ScanDepth + g_detector.RequiredLookback + TrendBars + ATRPeriod + 100;

            g_scanned = false;
            g_lastBarOpen = 0;
            g_scanFailLogged = 0;

            g_cisd = new SmcCisdEngine(g_env);
            g_conn = new SmcConnection(g_env);
            g_cisdCapBars = CISDScanDepth + ConnWarmupBars + 500;
            if (EnableCISD && !InitCISD())
            {
                g_invalid = true;
                return;
            }
            InitConnection();
        }

        private void DeinitAll()
        {
            try
            {
                if (g_confWriter != null) { g_confWriter.Flush(); g_confWriter.Dispose(); g_confWriter = null; }
                if (g_resultWriter != null) { g_resultWriter.Flush(); g_resultWriter.Dispose(); g_resultWriter = null; }
            }
            catch (Exception) { }
            if (g_detector == null || g_invalid)
                return;
            if (DebugLogLevel >= SmcLogLevel.Events)
            {
                Print("[SMC-OB] Final statistics:\n" + g_detector.StatsText());
                if (EnableCISD && g_cisd != null && g_cisdScanned)
                    Print("[SMC-CISD] Final statistics: " + g_cisd.StatsText());
                if (g_connScanned && g_conn != null)
                    Print("[SMC-CONN] Final statistics: " + g_conn.StatsText());
            }
        }

        private SmcSettings BuildSettings()
        {
            SmcSettings s = new SmcSettings();
            s.swingLength = p_swingLength;
            s.swingMinATR = SwingMinATR;
            s.bosMode = BOSMode;
            s.bosBufferATR = BOSBufferATR;
            s.atrPeriod = ATRPeriod;
            s.dispATRMult = p_dispATRMult;
            s.dispCandleATRMult = DispCandleATRMult;
            s.dispMinBodyPct = DispMinBodyPct;
            s.dispMinRelStrength = DispMinRelStrength;
            s.maxOBToBOSBars = p_maxOBToBOSBars;
            s.rejectLegViolation = RejectLegViolation;
            s.zoneSource = SmcZoneSource.CandleSeries;      // the only zone model in this EA
            s.zoneMode = SmcZoneMode.OpenLastExtreme;       // the only zone model in this EA
            s.overlapMode = OverlapMode;
            s.overlapPct = OverlapPct;
            s.maxActivePerDir = p_maxActivePerDir;
            s.maxAgeBars = MaxAgeBars;
            s.maxStored = Math.Max(500, p_maxActivePerDir * 20);
            s.enableBull = EnableBull;
            s.enableBear = EnableBear;
            s.fvgMode = FVGMode;
            s.fvgMinATR = FVGMinATR;
            s.retestEnabled = RetestEnabled;
            s.mitigationMode = MitigationMode;
            s.invalidationMode = InvalidationMode;
            s.logLevel = DebugLogLevel;
            return s;
        }

        private CisdSettings BuildCISDSettings()
        {
            CisdSettings s = new CisdSettings();
            s.timeframeSeconds = g_cisdPS;
            s.useSweep = CISDSweep;
            s.useConfirm = CISDConfirm;
            s.useRetrace = CISDRetrace;
            s.swingLength = CISDSwingLength;
            s.swingMinATR = CISDSwingMinATR;
            s.atrPeriod = ATRPeriod;
            s.swingMaxAge = CISDSwingMaxAge;
            s.sweepMode = CISDSweepMode;
            s.sweepValidityBars = CISDSweepValidity;
            s.levelMode = CISDLevelMode;
            s.maxSeriesCandles = CISDMaxSeries;
            s.maxConfirmBars = CISDMaxConfirmBars;
            s.maxRetraceBars = CISDMaxRetraceBars;
            s.maxStored = 500;
            s.logLevel = DebugLogLevel;
            return s;
        }

        private ConnSettings BuildConnSettings(long windowStart)
        {
            ConnSettings s = new ConnSettings();
            s.obTFSeconds = g_obPS;
            s.cisdTFSeconds = g_cisdPS;
            //--- a single Order Block type, always the source
            s.useStandard = true;
            s.useZOrder = false;
            s.multiCISD = (ConnCISDMode == ConnCisdMode.Multi);
            s.multiRetest = (ConnRetestMode == ConnRetestMode.Multi);
            s.maxRetests = ConnMaxRetests;
            s.stopOnMitigation = ConnMitigationStops;
            s.trendFilter = TrendFilter;
            s.trendBars = TrendBars;
            s.trendATRMult = p_trendGate;
            s.trendATRPeriod = ATRPeriod;
            s.mitigationMode = (int)MitigationMode;
            s.cisd = BuildCISDSettings();
            s.warmupBars = ConnWarmupBars;
            s.maxMonitorBars = ConnMaxCISDBars;
            s.windowStart = windowStart;
            s.logLevel = DebugLogLevel;
            return s;
        }

        private bool ValidateCISDInputs()
        {
            if (!EnableCISD)
                return true;
            string err = "";
            if (CISDSwingLength < 1 || CISDSwingLength > 50) err += "CISD swing strength must be 1..50. ";
            if (CISDSwingMinATR < 0.0) err += "CISD swing prominence must be >= 0. ";
            if (CISDSwingMaxAge < 0) err += "CISD swing age must be >= 0. ";
            if (CISDSweepValidity < 0 || CISDSweepValidity > 500) err += "CISD sweep validity must be 0..500. ";
            if (CISDMaxSeries < 1 || CISDMaxSeries > 50) err += "CISD max series must be 1..50. ";
            if (CISDMaxConfirmBars < 1 || CISDMaxConfirmBars > 1000) err += "CISD setup expiry must be 1..1000. ";
            if (CISDMaxRetraceBars < 1 || CISDMaxRetraceBars > 5000) err += "CISD retracement window must be 1..5000. ";
            if (CISDScanDepth < 200) err += "CISD scan depth must be >= 200. ";
            if (ConnMaxCISDBars < 1 || ConnMaxCISDBars > 10000) err += "HTF OB -> CISD window must be 1..10000 bars. ";
            if (ConnWarmupBars < 50 || ConnWarmupBars > 5000) err += "HTF OB -> CISD warm-up must be 50..5000 bars. ";
            if (ConnMaxRetests < 1 || ConnMaxRetests > 100) err += "Max CISD sequences per OB must be 1..100. ";
            if (err != "")
            {
                Print("[SMC-CISD] Invalid inputs: " + err);
                return false;
            }
            return true;
        }

        private bool ValidateInputs()
        {
            string err = "";
            if (SwingLength < 1 || SwingLength > 50) err += "Swing strength must be 1..50. ";
            if (SwingMinATR < 0.0) err += "Swing prominence must be >= 0. ";
            if (BOSBufferATR < 0.0) err += "BOS buffer must be >= 0. ";
            if (ATRPeriod < 1 || ATRPeriod > 500) err += "ATR period must be 1..500. ";
            if (DispATRMult < 0.0 || DispCandleATRMult < 0.0) err += "Displacement multipliers must be >= 0. ";
            if (DispMinBodyPct < 0.0 || DispMinBodyPct > 100.0) err += "Body % must be 0..100. ";
            if (DispMinRelStrength < 0.0) err += "Relative strength must be >= 0. ";
            if (MaxOBToBOSBars < 1 || MaxOBToBOSBars > 100) err += "Max OB->BOS distance must be 1..100. ";
            if (ExtendBars < 0) err += "OB extension must be >= 0. ";
            if (MaxActivePerDir < 1 || MaxActivePerDir > 200) err += "Max active OBs must be 1..200. ";
            if (MaxAgeBars < 0) err += "OB age must be >= 0. ";
            if (OverlapPct < 0.0 || OverlapPct > 100.0) err += "Overlap % must be 0..100. ";
            if (FVGMinATR < 0.0) err += "FVG min size must be >= 0. ";
            if (ScanDepth < 100) err += "Scan depth must be >= 100. ";
            if (!EnableBull && !EnableBear) err += "Enable at least one OB direction. ";
            if (err != "")
            {
                Print("[SMC-OB] Invalid inputs: " + err);
                return false;
            }
            return true;
        }

        #endregion

        #region Bar feed

        private long NowSec() { return SmcEnv.ToSec(Times[BarsInProgress][0]); }

        private int SeriesSeconds(int bip)
        {
            if (bip == obIdx) return g_obPS;
            if (bip == cisdIdx) return g_cisdPS;
            if (bip == m1Idx) return 60;
            return 0;
        }

        //--- NinjaTrader stamps a bar with its CLOSE time; MT5 with its OPEN time.
        //--- A bar shortened by a session boundary opens at the previous bar's close.
        private Rates BarAt(int bip)
        {
            long close = SmcEnv.ToSec(Times[bip][0]);
            long open = close - SeriesSeconds(bip);
            if (CurrentBars[bip] > 0)
            {
                long prevClose = SmcEnv.ToSec(Times[bip][1]);
                if (prevClose > open)
                    open = prevClose;
            }
            Rates b = new Rates();
            b.time = open;
            b.open = Opens[bip][0];
            b.high = Highs[bip][0];
            b.low = Lows[bip][0];
            b.close = Closes[bip][0];
            return b;
        }

        private static void Append(List<Rates> list, Rates b, int cap)
        {
            if (list.Count > 0 && b.time <= list[list.Count - 1].time)
                return;
            list.Add(b);
            if (list.Count > cap + 2000)
                list.RemoveRange(0, list.Count - cap);
        }

        //--- CopyRates(..., 1, count, ...) in series order: newest closed bar first
        private static Rates[] CopyWindow(List<Rates> list, int count)
        {
            int n = Math.Max(0, Math.Min(count, list.Count));
            Rates[] w = new Rates[n];
            for (int j = 0; j < n; j++)
                w[j] = list[list.Count - 1 - j];
            return w;
        }

        //--- closed bars newer than t (iBarShift(t) - 1)
        private static int CountNewer(List<Rates> list, long t)
        {
            int n = 0;
            for (int j = list.Count - 1; j >= 0 && list[j].time > t; j--)
                n++;
            return n;
        }

        //--- iTime(shift): shift 0 is the forming bar, shift 1 the newest closed one
        private static long TimeAtShift(List<Rates> list, int shift, long formingOpen)
        {
            if (shift == 0)
                return formingOpen;
            if (shift < 0 || shift > list.Count)
                return 0;
            return list[list.Count - shift].time;
        }

        //--- iBarShift(t, exact=false): the bar holding t (nearest older), forming bar = 0
        private static int BarShift(List<Rates> list, long t, long formingOpen)
        {
            if (t >= formingOpen)
                return 0;
            for (int j = list.Count - 1; j >= 0; j--)
                if (list[j].time <= t)
                    return list.Count - j;
            return -1;
        }

        protected override void OnBarUpdate()
        {
            if (g_invalid || g_detector == null)
                return;
            int bip = BarsInProgress;
            if (CurrentBars[bip] < 0)
                return;

            if (bip == 0)
            {
                UpdateChartATR();
                return;
            }

            if (bip == obIdx)
            {
                Append(g_obBars, BarAt(bip), g_obCapBars);
                TickWork();
                if (!g_scanned && !TryInitialScan())
                    return;
                ProcessNewBars();
                return;
            }

            if (bip == cisdIdx)
            {
                Append(g_cisdBars, BarAt(bip), g_cisdCapBars);
                if (EnableCISD && !ConnActive())
                    ProcessCISD();                 // standalone CISD (connection OFF)
                return;
            }

            if (bip == m1Idx)
            {
                Append(g_m1Bars, BarAt(bip), M1_CAP + 10);
                TickWork();
                if (!g_scanned)
                    return;
                if (ConnActive())
                    ProcessConnection();           // after the OB detectors are up to date
                if (CurrentBars[obIdx] >= 0)
                    g_detector.OnTickPrice(Closes[m1Idx][0]);
            }
        }

        //--- MT5 iATR(_Symbol, PERIOD_CURRENT, 14): simple average of the true range
        private void UpdateChartATR()
        {
            double tr = (CurrentBar > 0)
                ? Math.Max(High[0], Close[1]) - Math.Min(Low[0], Close[1])
                : High[0] - Low[0];
            g_chartTR.Add(tr);
            double atr = 0.0;
            if (g_chartTR.Count >= 14)
            {
                double sum = 0.0;
                for (int k = g_chartTR.Count - 14; k < g_chartTR.Count; k++)
                    sum += g_chartTR[k];
                atr = sum / 14.0;
            }
            g_chartATR.Add(atr);
            int keep = Math.Max(20, GuardVolAvgBars) + 50;
            if (g_chartTR.Count > keep + 500)
            {
                g_chartTR.RemoveRange(0, g_chartTR.Count - keep);
                g_chartATR.RemoveRange(0, g_chartATR.Count - keep);
            }
        }

        private double[] ChartAtrHistory(int need)
        {
            if (g_chartATR.Count < need)
                return null;
            double[] a = new double[need];
            for (int i = 0; i < need; i++)
                a[i] = g_chartATR[g_chartATR.Count - need + i];
            return a;
        }

        //--- OnTick housekeeping, in the EA's order
        private void TickWork()
        {
            if (!g_guardReset)
            {
                g_guard.ResetState();          // a fresh run never inherits counters
                g_guardReset = true;
            }
            if (o_exitPending && Position.MarketPosition == MarketPosition.Flat)
                o_exitPending = false;
            g_guard.Update();                  // day / week rollover, equity peak, equity stop
            FlattenIfAsked();                  // carry out an equity-stop flatten
            RecordClosedTrade();               // write the result of a trade that just closed
            ManageOpenPosition();              // break-even stop, if armed
            RideOpenPosition();                // opposite-block target, if riding
        }

        #endregion

        #region Order Block pipeline (TryInitialScan / ProcessNewBars / HandleEvents)

        private long OBFormingOpen()
        {
            //--- the forming OB bar opened when the newest closed one closed
            return CurrentBars[obIdx] >= 0 ? SmcEnv.ToSec(Times[obIdx][0]) : 0;
        }

        private bool TryInitialScan()
        {
            if (g_scanned)
                return true;

            int need = g_detector.RequiredLookback + 10;
            int bars = g_obBars.Count + 1;                       // Bars() counts the forming bar
            int count = Math.Min(ScanDepth + g_detector.RequiredLookback, bars - 1);
            Rates[] rates = (count >= need) ? CopyWindow(g_obBars, count) : new Rates[0];
            int got = rates.Length;
            if (got < need)
            {
                if (g_scanFailLogged++ == 0)
                    Print(string.Format("[SMC-OB] Waiting for history: {0} bars available, {1} required", bars, need));
                return false;
            }

            g_detector.Reset();
            g_detector.SetHistoricalMode(true);
            g_detector.ProcessWindow(rates, got);
            g_detector.SetHistoricalMode(false);

            g_lastClosedBar = rates[0].time;
            g_lastBarOpen = 0;                // force a new-bar check
            g_scanned = true;
            g_connScanned = false;            // HTF OB -> CISD monitors follow the (re)scanned OBs

            HandleEvents();
            Print(string.Format("[SMC-OB] History scan: {0} bars {1} {2}, {3} OBs stored",
                got, Instrument.FullName, Smc.TFText(g_obPS), g_detector.OBCount));
            if (DebugLogLevel >= SmcLogLevel.Events)
                Print("[SMC-OB] " + g_detector.StatsText());
            return true;
        }

        private void ProcessNewBars()
        {
            long open0 = OBFormingOpen();
            if (open0 == 0 || open0 == g_lastBarOpen)
                return;

            int newBars = CountNewer(g_obBars, g_detector.LastProcessedTime);   // closed bars newer than the last processed one
            if (newBars > ScanDepth)
            {
                Print("[SMC-OB] Large data gap detected - rescanning history");
                RemoveZoneDrawings();
                g_scanned = false;
                TryInitialScan();
                return;
            }
            if (newBars <= 0)
            {
                g_lastBarOpen = open0;
                return;
            }

            int count = newBars + g_detector.RequiredLookback + 2;
            Rates[] r = CopyWindow(g_obBars, count);
            int got = r.Length;
            if (got <= 0)
                return;

            g_detector.ProcessWindow(r, got);
            g_conn.ProcessOBWindow(r, got);     // trend filter context
            g_lastBarOpen = open0;
            g_lastClosedBar = r[0].time;

            HandleEvents();
        }

        private void HandleEvents()
        {
            List<long> touched = new List<long>();
            SmcEvent e;
            int n = g_detector.EventCount;
            for (int k = 0; k < n; k++)
            {
                if (!g_detector.GetEvent(k, out e))
                    continue;
                if (e.obId > 0)
                    touched.Add(e.obId);
                OnOppositeBlockRetest(e);
                if (AlertsEnabled && !e.historical)
                {
                    if (e.type == SmcEventType.ObCreated)
                        RaiseAlert(string.Format("{0} {1}: {2} Order Block #{3} confirmed", Instrument.FullName,
                            Smc.TFText(g_obPS), Smc.DirText(e.dir), e.obId));
                    else if (e.type == SmcEventType.ObRetest && e.flag)
                        RaiseAlert(string.Format("{0} {1}: first retest of {2} OB #{3}", Instrument.FullName,
                            Smc.TFText(g_obPS), Smc.DirText(e.dir), e.obId));
                }
                if (e.type == SmcEventType.ObRemoved)
                    RemoveZone(e.obId);
            }
            g_detector.ClearEvents();
            DrawZones(touched);
        }

        #endregion

        #region Standalone CISD (connection OFF)

        private bool ConnActive()
        {
            if (!EnableCISD)
                return false;
            return ConnEnable;
        }

        private bool InitCISD()
        {
            CisdSettings cs = BuildCISDSettings();
            if (!g_cisd.Init(cs))
            {
                Print("[SMC-CISD] Initialisation failed");
                return false;
            }
            g_cisdScanned = false;
            g_cisdLastBarOpen = 0;
            g_cisdFailLogged = 0;
            Print(string.Format("[SMC-CISD] Enabled on {0} candles: sweep {1}, confirmation {2}, retracement {3}",
                Smc.TFText(g_cisdPS), cs.useSweep ? "ON" : "OFF", cs.useConfirm ? "ON" : "OFF", cs.useRetrace ? "ON" : "OFF"));
            if (ConnActive())
                Print("[SMC-CISD] Standalone CISD paused: HTF OB -> CISD connection is ON (CISD runs per retested OB)");
            return true;
        }

        private bool TryCISDScan()
        {
            if (g_cisdScanned)
                return true;
            int need = g_cisd.RequiredLookback + 10;
            int bars = g_cisdBars.Count + 1;
            int count = Math.Min(CISDScanDepth + g_cisd.RequiredLookback, bars - 1);
            Rates[] rates = (count >= need) ? CopyWindow(g_cisdBars, count) : new Rates[0];
            int got = rates.Length;
            if (got < need)
            {
                if (g_cisdFailLogged++ == 0)
                    Print(string.Format("[SMC-CISD] Waiting for {0} history: {1} bars available, {2} required",
                        Smc.TFText(g_cisdPS), bars, need));
                return false;
            }

            g_cisd.Reset();
            g_cisd.SetHistoricalMode(true);
            g_cisd.ProcessWindow(rates, got);
            g_cisd.SetHistoricalMode(false);
            g_cisdLastBarOpen = 0;
            g_cisdScanned = true;
            HandleCISDEvents();
            Print(string.Format("[SMC-CISD] History scan: {0} {1} bars, {2} CISD records", got, Smc.TFText(g_cisdPS), g_cisd.Count));
            if (DebugLogLevel >= SmcLogLevel.Events)
                Print("[SMC-CISD] " + g_cisd.StatsText());
            return true;
        }

        private void ProcessCISD()
        {
            if (!g_cisdScanned)
            {
                TryCISDScan();
                return;
            }
            long open0 = SmcEnv.ToSec(Times[cisdIdx][0]);
            if (open0 == 0 || open0 == g_cisdLastBarOpen)
                return;
            int newBars = CountNewer(g_cisdBars, g_cisd.LastProcessedTime);
            if (newBars > CISDScanDepth)
            {
                Print("[SMC-CISD] Large data gap detected - rescanning CISD history");
                g_cisdScanned = false;
                TryCISDScan();
                return;
            }
            if (newBars <= 0)
            {
                g_cisdLastBarOpen = open0;
                return;
            }
            Rates[] r = CopyWindow(g_cisdBars, newBars + g_cisd.RequiredLookback + 2);
            if (r.Length <= 0)
                return;
            g_cisd.ProcessWindow(r, r.Length);
            g_cisdLastBarOpen = open0;
            HandleCISDEvents();
        }

        private void HandleCISDEvents()
        {
            CisdEvent e;
            int n = g_cisd.EventCount;
            for (int k = 0; k < n; k++)
            {
                if (!g_cisd.GetEvent(k, out e))
                    continue;
                if (AlertsEnabled && !e.historical)
                {
                    string side = (e.dir == Smc.DIR_BULL) ? "Bullish" : "Bearish";
                    if (e.type == CisdEventType.Confirmed)
                        RaiseAlert(string.Format("{0} CISD {1}: {2} CISD #{3} confirmed", Instrument.FullName, Smc.TFText(g_cisdPS), side, e.id));
                    else if (e.type == CisdEventType.Retraced)
                        RaiseAlert(string.Format("{0} CISD {1}: {2} CISD #{3} retracement / entry", Instrument.FullName, Smc.TFText(g_cisdPS), side, e.id));
                }
            }
            g_cisd.ClearEvents();
        }

        #endregion

        #region HTF OB -> LTF CISD connection

        //--- latest time up to which OB knowledge is complete
        private long ConnHorizon()
        {
            int ps = g_obPS;
            long last = g_detector.LastProcessedTime;
            long open0 = OBFormingOpen();
            if (last > 0 && open0 > 0 && last + ps >= open0)
                return NowSec();               // detectors processed the latest closed OB bar
            return last + ps;                  // OB data lagging: wait
        }

        private void InitConnection()
        {
            g_syncTime = 0;
            g_syncStd = -1;
            g_connScanned = false;
            g_connFailLogged = 0;
            if (ConnActive())
            {
                ConnSettings info = BuildConnSettings(0);
                Print(string.Format("[SMC-CONN] HTF OB -> LTF CISD ON: OB {0}, CISD {1} | source standard {2} / ZOrder {3} | CISD validation {4}",
                    Smc.TFText(g_obPS), Smc.TFText(g_cisdPS),
                    info.useStandard ? "ON" : "OFF", info.useZOrder ? "ON" : "OFF", info.multiCISD ? "MULTI" : "SINGLE"));
            }
        }

        private void RebuildConnection()
        {
            g_conn.Reset();
            g_syncTime = 0;                    // the rebuilt engine must be synchronised again
            g_syncStd = -1;
            g_connScanned = false;
            g_connFailLogged = 0;
            if (ConnActive())
            {
                Print(string.Format("[SMC-CONN] Rebuilding HTF OB -> LTF CISD: OB {0}, CISD {1}", Smc.TFText(g_obPS), Smc.TFText(g_cisdPS)));
                TryConnScan();
            }
        }

        private bool TryConnScan()
        {
            if (g_connScanned)
                return true;
            if (!g_scanned)
                return false;                  // OB detectors first
            long cisdForming = g_cisdBars.Count > 0 ? g_cisdBars[g_cisdBars.Count - 1].time + g_cisdPS : 0;
            long m1Forming = g_m1Bars.Count > 0 ? g_m1Bars[g_m1Bars.Count - 1].time + 60 : 0;
            int cisdBars = g_cisdBars.Count + 1;   // Bars() counts the forming candle
            int m1Bars = g_m1Bars.Count + 1;
            if (cisdBars < ConnWarmupBars + 50 || m1Bars < 100)
            {
                if (g_connFailLogged++ == 0)
                    Print(string.Format("[SMC-CONN] Waiting for history: {0} {1} bars, M1 {2} bars", Smc.TFText(g_cisdPS), cisdBars, m1Bars));
                return false;
            }
            int depth = Math.Min(CISDScanDepth, cisdBars - ConnWarmupBars - 20);
            long ws = TimeAtShift(g_cisdBars, depth, cisdForming);
            int m1Shift = BarShift(g_m1Bars, ws, m1Forming);
            if (ws == 0 || m1Shift < 1)
                return false;
            if (m1Shift > M1_CAP)
            {
                m1Shift = M1_CAP;
                ws = TimeAtShift(g_m1Bars, m1Shift, m1Forming);
            }

            ConnSettings cs = BuildConnSettings(ws);
            if (!g_conn.Init(cs, g_detector, null))
            {
                Print("[SMC-CONN] Initialisation failed");
                return false;
            }
            ConnSettings eff = g_conn.Settings;
            Rates[] m1 = CopyWindow(g_m1Bars, m1Shift);
            int n1 = m1.Length;
            int cShift = BarShift(g_cisdBars, ws, cisdForming);
            Rates[] cr = (cShift > 0) ? CopyWindow(g_cisdBars, cShift + eff.warmupBars + 5) : new Rates[0];
            int nc = cr.Length;
            if (n1 <= 0 || nc <= eff.warmupBars)
            {
                if (g_connFailLogged++ == 0)
                    Print(string.Format("[SMC-CONN] Waiting for M1 / {0} data (M1 {1}, CISD {2})", Smc.TFText(g_cisdPS), n1, nc));
                return false;
            }

            long hz = ConnHorizon();
            g_conn.SetHistoricalMode(true);
            g_conn.SyncOBs();
            //--- OB-timeframe candles for the trend filter (same window the detectors scanned)
            Rates[] obh = CopyWindow(g_obBars, TrendBars + ATRPeriod + 5 + ScanDepth);
            if (obh.Length > 0)
                g_conn.ProcessOBWindow(obh, obh.Length);
            g_conn.ProcessM1Window(m1, n1, hz);
            g_conn.ProcessCISDWindow(cr, nc, hz);
            g_conn.SetHistoricalMode(false);
            g_connScanned = true;
            HandleConnEvents();
            Print(string.Format("[SMC-CONN] History scan: OB {0} -> CISD {1}, window from {2} ({3} M1 + {4} {5} bars), {6} OB monitors",
                Smc.TFText(g_obPS), Smc.TFText(g_cisdPS), SmcEnv.T(ws), n1, nc, Smc.TFText(g_cisdPS), g_conn.Count));
            if (DebugLogLevel >= SmcLogLevel.Events)
                Print("[SMC-CONN] " + g_conn.StatsText());
            return true;
        }

        //--- Live: new OBs, M1 retests, then CISD-timeframe candles.
        private void ProcessConnection()
        {
            if (!g_connScanned)
            {
                TryConnScan();
                return;
            }
            //--- SyncOBs() reads confirmed order blocks and their end times; both change only when
            //--- the detectors process a new bar, so the scan is skipped while the detectors stand still.
            long dt = g_detector.LastProcessedTime;
            int cStd = g_detector.OBCount;
            if (dt != g_syncTime || cStd != g_syncStd)
            {
                g_conn.SyncOBs();
                g_syncTime = dt;
                g_syncStd = cStd;
            }
            long hz = ConnHorizon();
            bool changed = false;

            bool m1ok = true;
            long lastM1 = g_m1Bars.Count > 0 ? g_m1Bars[g_m1Bars.Count - 1].time : 0;
            if (lastM1 > g_conn.LastM1Time)
            {
                int shift = CountNewer(g_m1Bars, g_conn.LastM1Time) + 1;
                if (shift > M1_CAP)
                {
                    Print("[SMC-CONN] Large data gap detected - rescanning HTF OB -> CISD");
                    RebuildConnection();
                    return;
                }
                Rates[] w = CopyWindow(g_m1Bars, Math.Max(shift, 1));
                if (w.Length <= 0)
                    m1ok = false;              // retry next bar; CISD must not run ahead of retests
                else if (g_conn.ProcessM1Window(w, w.Length, hz) > 0)
                    changed = true;
            }

            long lastC = g_cisdBars.Count > 0 ? g_cisdBars[g_cisdBars.Count - 1].time : 0;
            if (m1ok && lastC > g_conn.LastCISDTime)
            {
                int shift = CountNewer(g_cisdBars, g_conn.LastCISDTime) + 1;
                Rates[] w = CopyWindow(g_cisdBars, Math.Max(shift, 1));
                if (w.Length > 0 && g_conn.ProcessCISDWindow(w, w.Length, hz) > 0)
                    changed = true;
            }
            if (changed || g_conn.EventCount > 0)
                HandleConnEvents();
        }

        private void HandleConnEvents()
        {
            ConnEvent e;
            int n = g_conn.EventCount;
            for (int k = 0; k < n; k++)
            {
                if (!g_conn.GetEvent(k, out e))
                    continue;
                if (e.type == ConnEventType.Confirmed && !e.historical)
                    TradeConfirmedSetup(e);
                if (!AlertsEnabled || e.historical)
                    continue;
                string side = (e.dir == Smc.DIR_BULL) ? "Bullish" : "Bearish";
                if (e.type == ConnEventType.Retest)
                    RaiseAlert(string.Format("{0}: {1} {2} {3} #{4} retested -> {5} CISD monitoring", Instrument.FullName, Smc.TFText(g_obPS), side,
                        Conn.KindText(e.kind), e.obId, Smc.TFText(g_cisdPS)));
                else if (e.type == ConnEventType.Confirmed)
                    RaiseAlert(string.Format("{0}: {1} {2} {3} #{4} R{5} + {6} CISD #{7} CONFIRMED", Instrument.FullName, Smc.TFText(g_obPS), side,
                        Conn.KindText(e.kind), e.obId, e.retestNo, Smc.TFText(g_cisdPS), e.cisdId));
                else if (e.type == ConnEventType.Retraced)
                    RaiseAlert(string.Format("{0}: {1} setup (OB #{2}, CISD #{3}) retracement / entry", Instrument.FullName, side, e.obId, e.cisdId));
            }
            g_conn.ClearEvents();
        }

        //--- A confirmed HTF OB + LTF CISD setup: hand the block's edges to the trade engine.
        private void TradeConfirmedSetup(ConnEvent e)
        {
            if (!t_enabled && !t_alerts && !ConfidenceLog)
                return;                        // not trading, not alerting, not scoring: nothing to do
            SmcOrderBlock ob = null;
            int idx = g_detector.FindById(e.obId);
            bool found = (idx >= 0 && g_detector.GetOB(idx, out ob));
            if (!found)
            {
                Print(string.Format("[SMC-TRADE] confirmed setup skipped: Order Block #{0} not found", e.obId));
                return;
            }
            //--- Score the setup for measurement. Logged, never acted on.
            double setupScore;
            {
                double entryPx = (e.dir == Smc.DIR_BULL) ? GetCurrentAsk(m1Idx) : GetCurrentBid(m1Idx);
                double stopPx = (e.dir == Smc.DIR_BULL) ? ob.bottom : ob.top;
                double riskPx = Math.Abs(entryPx - stopPx);
                SmcConfidence conf = SmcConfidence.Score(ob, e.trendScore, e.retestNo, e.cisdLevel, e.price,
                                                         e.sweepTime, e.time, riskPx, CurrentSpread(),
                                                         g_obPS, g_cisdPS);
                setupScore = conf.total;
                if (ConfidenceLog)
                    Print(string.Format("[SMC-SCORE] OB #{0} {1} {2}", e.obId, e.dir == Smc.DIR_BULL ? "BUY" : "SELL", conf.Text()));
                if (ConfidenceLog && !string.IsNullOrEmpty(ConfidenceFile))
                {
                    double tpPx = (e.dir == Smc.DIR_BULL) ? entryPx + riskPx * TargetRR
                                                          : entryPx - riskPx * TargetRR;
                    WriteConfidenceRow(conf, e.obId, e.dir, e.time, entryPx, stopPx, tpPx);
                }
            }
            OnSignal(e.dir, ob.top, ob.bottom, e.obId, e.cisdId, setupScore);
        }

        #endregion

        #region Trade engine (CSMCTradeEngine)

        private void ApplyTradeSettings()
        {
            if (EnableTrading != t_enabled) Print("[SMC-TRADE] execution " + (EnableTrading ? "ON" : "OFF"));
            t_enabled = EnableTrading;
            if (p_lots > 0) t_lots = p_lots;
            if (OppositeBlockExit != t_oppExit) Print("[SMC-TRADE] opposite block exit " + (OppositeBlockExit ? "ON" : "OFF"));
            t_oppExit = OppositeBlockExit;
            if (p_targetRR > 0.0) t_rr = p_targetRR;
            t_ride = RideTrend;
            t_alerts = EntryAlert;
            t_riskPct = RiskPercentMode;
            if (p_riskPercent > 0.0) t_riskPercent = p_riskPercent;
            t_beEnabled = BreakEven;
            if (p_bePoints > 0) t_bePoints = p_bePoints;
        }

        private bool HasPosition()
        {
            return Position.MarketPosition != MarketPosition.Flat || o_entryPending;
        }

        private bool FindPosition(out int dir, out long opened)
        {
            dir = 0;
            opened = 0;
            if (Position.MarketPosition == MarketPosition.Flat)
                return false;
            dir = (Position.MarketPosition == MarketPosition.Long) ? Smc.DIR_BULL : Smc.DIR_BEAR;
            opened = o_posOpenTime;
            return true;
        }

        private double CurrentPrice()
        {
            return CurrentBars[BarsInProgress] >= 0 ? Closes[BarsInProgress][0] : 0.0;
        }

        //--- SYMBOL_SPREAD * SYMBOL_POINT. Historical bars carry no spread, which reads as 0 (guard inert).
        private double CurrentSpread()
        {
            if (CurrentBars[m1Idx] < 0)
                return 0.0;
            double s = GetCurrentAsk(m1Idx) - GetCurrentBid(m1Idx);
            return s > 0.0 ? s : 0.0;
        }

        //--- ACCOUNT_EQUITY: account size + closed P/L + open P/L of this strategy
        private double GetEquity()
        {
            double unreal = 0.0;
            if (Position.MarketPosition != MarketPosition.Flat && CurrentBars[m1Idx] >= 0)
                unreal = Position.GetUnrealizedProfitLoss(PerformanceUnit.Currency, Closes[m1Idx][0]);
            return EquityBase + SystemPerformance.AllTrades.TradesPerformance.Currency.CumProfit + unreal;
        }

        //--- Contracts that put exactly riskMoney at risk over a stop of riskPrice.
        private double LotsForRisk(double riskPrice, out double riskMoneyOut)
        {
            riskMoneyOut = 0.0;
            if (riskPrice <= 0.0)
                return t_lots;
            double point = TickSize;
            double pointValue = Instrument.MasterInstrument.PointValue;
            if (point <= 0.0 || pointValue <= 0.0)
            {
                Print("[SMC-TRADE] risk sizing unavailable for " + Instrument.FullName + ": using the fixed contract size");
                return t_lots;
            }
            double equity = GetEquity();
            if (equity <= 0.0)
                return t_lots;
            double riskMoney = equity * t_riskPercent / 100.0;
            double valuePerPointLot = pointValue * point;    // account currency per tick per contract
            double riskPoints = riskPrice / point;
            if (valuePerPointLot <= 0.0 || riskPoints <= 0.0)
                return t_lots;
            riskMoneyOut = riskMoney;
            return riskMoney / (riskPoints * valuePerPointLot);
        }

        //--- volume step 1 contract, minimum 1
        private int NormLots(double lots)
        {
            double v = Math.Floor(lots / 1.0 + 0.5) * 1.0;
            v = Math.Max(1.0, v);
            return (int)v;
        }

        private void RaiseEntryAlert(int dir, double entry, double sl, double tp, long obId, bool traded)
        {
            string side = (dir == Smc.DIR_BULL) ? "BUY" : "SELL";
            string target = (tp > 0.0) ? "TP " + Instrument.MasterInstrument.FormatPrice(tp) : "TP at the opposite block";
            string text = string.Format("{0} {1}  {2}  entry {3}  SL {4}  {5}  (OB #{6}){7}",
                Instrument.FullName, Smc.TFText(g_obPS), side,
                Instrument.MasterInstrument.FormatPrice(entry), Instrument.MasterInstrument.FormatPrice(sl), target, obId,
                traded ? "" : " [signal only]");
            t_alerted++;
            RaiseAlert(text);
            Print("[SMC-TRADE][ALERT] " + text);
        }

        //--- A confirmed HTF OB + LTF CISD setup: enter at market, stop on the far side of the block.
        private bool OnSignal(int dir, double obTop, double obBottom, long obId, long cisdId, double score)
        {
            if (!t_ready || (!t_enabled && !t_alerts))
                return false;                            // nothing to do: no orders, no alerts
            if (obTop <= obBottom)
                return false;

            double point = TickSize;
            double stops = 0.0;                          // NinjaTrader has no broker stops level
            double ask = GetCurrentAsk(m1Idx);
            double bid = GetCurrentBid(m1Idx);
            if (ask <= 0.0 || bid <= 0.0)
                return false;

            double entry, sl, tp, risk;
            if (dir == Smc.DIR_BULL)
            {
                entry = ask;
                sl = obBottom;                           // other side of the block
                risk = entry - sl;
                tp = t_ride ? 0.0 : entry + risk * t_rr;  // riding: the opposite block is the target
            }
            else
            {
                entry = bid;
                sl = obTop;
                risk = sl - entry;
                tp = t_ride ? 0.0 : entry - risk * t_rr;
            }
            sl = Instrument.MasterInstrument.RoundToTickSize(sl);
            tp = (tp > 0.0) ? Instrument.MasterInstrument.RoundToTickSize(tp) : 0.0;

            if (risk <= 0.0 || risk <= stops)
            {
                if (t_enabled)
                {
                    t_skipped++;
                    t_last = string.Format("skip OB #{0}: stop too close ({1:0.0} points)", obId, risk / (point > 0 ? point : 1));
                }
                return false;                            // an unusable stop is not worth announcing
            }

            //--- a guard refusal is decided before the alert, so the alert can say honestly whether it will act
            bool allowed = (g_guard == null) ? true : g_guard.AllowNewTrade(risk);
            bool willTrade = t_enabled && allowed && !HasPosition();
            if (t_alerts)
                RaiseEntryAlert(dir, entry, sl, tp, obId, willTrade);

            if (!t_enabled)
                return false;
            if (!allowed)
            {
                t_skipped++;
                t_last = string.Format("skip OB #{0}: {1}", obId, SmcCapitalGuard.Name(g_guard.LastBlock));
                return false;
            }
            if (HasPosition())
            {
                t_skipped++;
                t_last = string.Format("skip OB #{0}: a position is already open", obId);
                return false;
            }

            double riskMoney = 0.0;
            int lots = t_riskPct ? NormLots(LotsForRisk(risk, out riskMoney)) : NormLots(t_lots);
            if (lots < 1)
            {
                t_skipped++;
                t_last = string.Format("skip OB #{0}: risk {1:0.00} is below one minimum lot", obId, riskMoney);
                Print("[SMC-TRADE] " + t_last);
                return false;
            }

            o_seq++;
            string signal = string.Format("SMC {0} {1}", dir == Smc.DIR_BULL ? "L" : "S", o_seq);
            SetStopLoss(signal, CalculationMode.Price, sl, false);
            if (tp > 0.0)
                SetProfitTarget(signal, CalculationMode.Price, tp);
            Order ord = (dir == Smc.DIR_BULL) ? EnterLong(m1Idx, lots, signal) : EnterShort(m1Idx, lots, signal);
            bool ok = (ord != null);
            if (ok)
            {
                t_sent++;
                o_signal = signal;
                o_entryPending = true;
                o_curSL = sl;
                o_curTP = tp;
                o_posOpenTime = NowSec();
                //--- remember this trade so its result can be matched to its score later
                t_openPos = true;
                t_tradeCountAtEntry = SystemPerformance.AllTrades.Count;
                t_openObId = obId;
                t_openScore = score;
                t_openTime = NowSec();
                t_openRiskMoney = (riskMoney > 0.0) ? riskMoney
                                  : risk * lots * Instrument.MasterInstrument.PointValue;
                if (t_riskPct)
                    Print(string.Format(CultureInfo.InvariantCulture,
                        "[SMC-TRADE] sizing: equity {0:0.00}, risk {1:0.00}% = {2:0.00}, stop {3:0.0} ticks -> {4} contracts",
                        GetEquity(), t_riskPercent, riskMoney, risk / (point > 0 ? point : 1), lots));
                t_last = (tp > 0.0)
                    ? string.Format("{0} {1} @ {2} sl {3} tp {4} (OB #{5} CISD #{6})", dir == Smc.DIR_BULL ? "BUY" : "SELL", lots,
                        Instrument.MasterInstrument.FormatPrice(entry), Instrument.MasterInstrument.FormatPrice(sl),
                        Instrument.MasterInstrument.FormatPrice(tp), obId, cisdId)
                    : string.Format("{0} {1} @ {2} sl {3} riding the trend (OB #{4} CISD #{5})", dir == Smc.DIR_BULL ? "BUY" : "SELL", lots,
                        Instrument.MasterInstrument.FormatPrice(entry), Instrument.MasterInstrument.FormatPrice(sl), obId, cisdId);
                Print("[SMC-TRADE] " + t_last);
            }
            else
            {
                t_skipped++;
                t_last = "order rejected";
                Print("[SMC-TRADE] " + t_last);
            }
            return ok;
        }

        //--- A trade that is no longer open gets its realised result written next to its score.
        private void RecordClosedTrade()
        {
            if (!t_openPos)
                return;
            if (HasPosition())
                return;                                   // still open
            double profit = 0.0;
            int count = SystemPerformance.AllTrades.Count;
            for (int i = t_tradeCountAtEntry; i < count; i++)
                profit += SystemPerformance.AllTrades[i].ProfitCurrency;
            double realisedR = (t_openRiskMoney > 0.0) ? profit / t_openRiskMoney : 0.0;
            if (!string.IsNullOrEmpty(ResultFile))
            {
                try
                {
                    if (g_resultWriter == null)
                    {
                        string path = Path.Combine(NinjaTrader.Core.Globals.UserDataDir, ResultFile);
                        bool isNew = !File.Exists(path) || new FileInfo(path).Length == 0;
                        g_resultWriter = new StreamWriter(path, true);
                        if (isNew)
                            g_resultWriter.WriteLine("open_time,close_time,symbol,ob_id,score,risk_money,profit,realised_r");
                    }
                    g_resultWriter.WriteLine(string.Join(",", new string[] {
                        SmcEnv.T(t_openTime), SmcEnv.T(NowSec()), Instrument.FullName, t_openObId.ToString(CultureInfo.InvariantCulture),
                        t_openScore.ToString("0.0", CultureInfo.InvariantCulture), t_openRiskMoney.ToString("0.00", CultureInfo.InvariantCulture),
                        profit.ToString("0.00", CultureInfo.InvariantCulture), realisedR.ToString("0.000", CultureInfo.InvariantCulture) }));
                    g_resultWriter.Flush();
                }
                catch (Exception ex)
                {
                    Print("[SMC-TRADE] result file error: " + ex.Message);
                }
            }
            Print(string.Format(CultureInfo.InvariantCulture, "[SMC-TRADE] closed OB #{0}: {1:0.00} ({2:0.00} R), score {3:0.0}",
                t_openObId, profit, realisedR, t_openScore));
            if (g_guard != null)
                g_guard.OnTradeClosed(profit);
            t_openPos = false;
        }

        private void ClosePosition(string why)
        {
            if (Position.MarketPosition == MarketPosition.Long)
                ExitLong(m1Idx, Position.Quantity, "SMC Exit", o_signal);
            else if (Position.MarketPosition == MarketPosition.Short)
                ExitShort(m1Idx, Position.Quantity, "SMC Exit", o_signal);
            o_exitPending = true;
        }

        //--- The equity stop asked for a flatten.
        private bool FlattenIfAsked()
        {
            if (g_guard == null || !g_guard.FlattenRequested)
                return false;
            g_guard.ClearFlatten();
            if (Position.MarketPosition == MarketPosition.Flat)
                return false;
            ClosePosition("equity stop");
            Print("[SMC-TRADE] flattened on the equity stop");
            return true;
        }

        //--- Break-even: once the open position is t_bePoints ticks in profit, the stop moves to entry, once.
        private bool ManageOpenPosition()
        {
            if (!t_enabled || !t_beEnabled || !t_ready || o_exitPending)
                return false;
            int posDir;
            long opened;
            if (!FindPosition(out posDir, out opened))
                return false;

            double point = TickSize;
            if (point <= 0.0)
                return false;
            double entry = Instrument.MasterInstrument.RoundToTickSize(Position.AveragePrice);
            double sl = o_curSL;
            double price = CurrentPrice();
            double profit = (posDir == Smc.DIR_BULL) ? (price - entry) : (entry - price);
            if (profit < t_bePoints * point)
                return false;                            // not far enough in profit yet
            //--- already at or beyond entry: nothing to do
            if (sl != 0.0 && ((posDir == Smc.DIR_BULL && sl >= entry) || (posDir == Smc.DIR_BEAR && sl <= entry)))
                return false;
            double stops = 0.0;
            if (Math.Abs(price - entry) <= stops)
                return false;

            SetStopLoss(o_signal, CalculationMode.Price, entry, false);
            o_curSL = entry;
            t_beMoved++;
            t_last = string.Format("stop moved to break even at {0} ({1:0} ticks in profit)",
                Instrument.MasterInstrument.FormatPrice(entry), profit / point);
            Print("[SMC-TRADE] " + t_last);
            return true;
        }

        //--- Ride the trend: the nearest live Order Block facing the other way becomes the target.
        private bool RideOpenPosition()
        {
            if (!t_enabled || !t_ride || !t_ready || o_exitPending)
                return false;
            int posDir;
            long opened;
            if (!FindPosition(out posDir, out opened))
                return false;

            double point = TickSize;
            double entry = Position.AveragePrice;
            double tp = o_curTP;
            double price = CurrentPrice();
            int want = (posDir == Smc.DIR_BULL) ? Smc.DIR_BEAR : Smc.DIR_BULL;

            //--- nearest live opposite block ahead of the trade
            List<SmcOrderBlock> obs = new List<SmcOrderBlock>();
            int n = g_detector.GetLiveOBs(want, obs);
            double target = 0.0;
            long tid = 0;
            for (int i = 0; i < n; i++)
            {
                //--- a bearish block is resistance: its lower edge is the first touch from below
                double edge = (posDir == Smc.DIR_BULL) ? obs[i].bottom : obs[i].top;
                if (posDir == Smc.DIR_BULL && edge <= entry)
                    continue;                              // not ahead of the trade
                if (posDir == Smc.DIR_BEAR && edge >= entry)
                    continue;
                if (target == 0.0 ||
                    (posDir == Smc.DIR_BULL && edge < target) || (posDir == Smc.DIR_BEAR && edge > target))
                {
                    target = edge;
                    tid = obs[i].id;
                }
            }
            if (target == 0.0)
                return false;                             // nothing opposite ahead yet: keep riding
            target = Instrument.MasterInstrument.RoundToTickSize(target);

            //--- already there: take it at market
            if ((posDir == Smc.DIR_BULL && price >= target) || (posDir == Smc.DIR_BEAR && price <= target))
            {
                ClosePosition("ride target");
                t_rideExits++;
                t_last = string.Format("closed {0} at opposite Order Block #{1} ({2})",
                    posDir == Smc.DIR_BULL ? "BUY" : "SELL", tid, Instrument.MasterInstrument.FormatPrice(target));
                Print("[SMC-TRADE] " + t_last);
                return true;
            }
            //--- otherwise park the target there
            double stops = 0.0;
            if (Math.Abs(target - price) <= stops)
                return false;
            if (Math.Abs(tp - target) < point / 2.0)
                return false;                             // already set there
            SetProfitTarget(o_signal, CalculationMode.Price, target);
            o_curTP = target;
            t_last = string.Format("target set at opposite Order Block #{0} ({1})", tid, Instrument.MasterInstrument.FormatPrice(target));
            return true;
        }

        //--- Opposite Block Exit: a block created against the open position, and now retested, closes it.
        private bool OnOppositeBlockRetest(SmcEvent e)
        {
            if (!t_enabled || !t_oppExit || !t_ready || e.historical || o_exitPending)
                return false;
            if (e.type != SmcEventType.ObRetest)
                return false;
            int posDir;
            long opened;
            if (!FindPosition(out posDir, out opened))
                return false;
            if (e.dir == posDir)
                return false;                            // same side as the trade: not an exit
            int idx = g_detector.FindById(e.obId);
            SmcOrderBlock ob;
            if (idx < 0 || !g_detector.GetOB(idx, out ob))
                return false;
            if (ob.confirmTime <= opened)
                return false;                            // the block is older than the trade
            ClosePosition("opposite block");
            t_closed++;
            t_last = string.Format("closed {0} on retested opposite Order Block #{1}",
                posDir == Smc.DIR_BULL ? "BUY" : "SELL", e.obId);
            Print("[SMC-TRADE] " + t_last);
            return true;
        }

        protected override void OnExecutionUpdate(Execution execution, string executionId, double price, int quantity,
                                                  MarketPosition marketPosition, string orderId, DateTime time)
        {
            if (execution == null || execution.Order == null)
                return;
            if (execution.Order.Name == o_signal && o_entryPending)
            {
                o_posOpenTime = SmcEnv.ToSec(time);         // POSITION_TIME
                if (execution.Order.OrderState == OrderState.Filled)
                    o_entryPending = false;
            }
        }

        protected override void OnOrderUpdate(Order order, double limitPrice, double stopPrice, int quantity, int filled,
                                              double averageFillPrice, OrderState orderState, DateTime time, ErrorCode error, string comment)
        {
            if (order == null)
                return;
            if (order.Name == o_signal && (orderState == OrderState.Cancelled || orderState == OrderState.Rejected))
            {
                o_entryPending = false;
                if (filled == 0)
                {
                    //--- the MT5 order call would have returned false: nothing was opened
                    t_openPos = false;
                    t_sent--;
                    t_skipped++;
                    t_last = "order rejected: " + orderState;
                    Print("[SMC-TRADE] " + t_last);
                }
            }
            if (order.Name == "SMC Exit" && (orderState == OrderState.Cancelled || orderState == OrderState.Rejected))
                o_exitPending = false;
        }

        protected override void OnPositionUpdate(Position position, double averagePrice, int quantity, MarketPosition marketPosition)
        {
            if (marketPosition == MarketPosition.Flat)
                o_exitPending = false;
        }

        #endregion

        #region Logging, alerts, drawing

        private void RaiseAlert(string text)
        {
            if (State == State.Realtime)
                Alert("SMCOB" + text.GetHashCode(), Priority.High, text, NinjaTrader.Core.Globals.InstallDir + @"\sounds\Alert1.wav",
                      0, Brushes.Black, Brushes.Yellow);
            Print("[SMC-ALERT] " + text);
        }

        private void WriteConfidenceRow(SmcConfidence c, long obId, int dir, long signalTime, double entry, double sl, double tp)
        {
            try
            {
                if (g_confWriter == null)
                {
                    string path = Path.Combine(NinjaTrader.Core.Globals.UserDataDir, ConfidenceFile);
                    bool isNew = !File.Exists(path) || new FileInfo(path).Length == 0;
                    g_confWriter = new StreamWriter(path, true);
                    if (isNew)
                        g_confWriter.WriteLine("time,symbol,ob_id,dir,entry,sl,tp,score,band,trend,quality,impulse,freshness,retest,height,fvg,cisd," +
                                               "spread,session,sweep,trend_score,rel_strength,body_pct,impulse_atr,age_bars,retest_no,zone_atr," +
                                               "confirm_beyond_atr,spread_pct_of_r,hour,sweep_age_bars");
                }
                CultureInfo ci = CultureInfo.InvariantCulture;
                g_confWriter.WriteLine(string.Join(",", new string[] {
                    SmcEnv.T(signalTime), Instrument.FullName, obId.ToString(ci), dir == Smc.DIR_BULL ? "BUY" : "SELL",
                    entry.ToString(ci), sl.ToString(ci), tp.ToString(ci),
                    c.total.ToString("0.0", ci), SmcConfidence.BandText(c.total),
                    c.trend.ToString("0.00", ci), c.quality.ToString("0.00", ci), c.impulse.ToString("0.00", ci),
                    c.freshness.ToString("0.00", ci), c.retest.ToString("0.00", ci), c.height.ToString("0.00", ci),
                    c.fvg.ToString("0.00", ci), c.cisd.ToString("0.00", ci), c.spread.ToString("0.00", ci),
                    c.session.ToString("0.00", ci), c.sweep.ToString("0.00", ci),
                    c.trendScore.ToString("0.000", ci), c.relStrength.ToString("0.000", ci),
                    c.bodyPct.ToString("0.00", ci), c.impulseATR.ToString("0.000", ci),
                    c.ageBars.ToString("0.0", ci), c.retestNo.ToString(ci), c.zoneATR.ToString("0.000", ci),
                    c.confirmBeyondATR.ToString("0.000", ci), c.spreadPctOfR.ToString("0.0000", ci), c.hour.ToString(ci),
                    c.sweepAgeBars.ToString("0.0", ci) }));
                g_confWriter.Flush();
            }
            catch (Exception ex)
            {
                Print("[SMC-SCORE] confidence file error: " + ex.Message);
            }
        }

        private string ZoneTag(long id) { return "SMCOB_OB_" + id.ToString(CultureInfo.InvariantCulture); }

        private void RemoveZone(long id)
        {
            try { RemoveDrawObject(ZoneTag(id)); } catch (Exception) { }
        }

        private void RemoveZoneDrawings()
        {
            if (g_detector == null)
                return;
            for (int k = 0; k < g_detector.OBCount; k++)
                RemoveZone(g_detector.OBIdAt(k));
        }

        //--- Order Block zones on the chart. Display only: nothing here feeds a decision.
        private void DrawZones(List<long> touched)
        {
            if (!ShowZones || CurrentBars[obIdx] < 0)
                return;
            try
            {
                DateTime lastBar = Times[obIdx][0];
                SmcOrderBlock o;
                for (int k = 0; k < g_detector.OBCount; k++)
                {
                    bool live = Smc.IsLiveState(g_detector.OBStateAt(k));
                    long id = g_detector.OBIdAt(k);
                    if (!live && !touched.Contains(id))
                        continue;                      // a dead zone is drawn once, when it ends
                    if (!g_detector.GetOB(k, out o))
                        continue;
                    if (!live && !ShowInactive)
                    {
                        RemoveZone(o.id);
                        continue;
                    }
                    long start = (o.isZOrder ? o.seriesStartTime : o.obTime) + g_obPS;   // NinjaTrader stamps bars at their close
                    DateTime t1 = SmcEnv.FromSec(start);
                    DateTime t2 = live ? lastBar : SmcEnv.FromSec(o.endTime + g_obPS);
                    if (t2 > lastBar)
                        t2 = lastBar;
                    Brush b = !live ? Brushes.DimGray
                            : (o.state == SmcObState.Mitigated ? Brushes.Goldenrod
                            : (o.dir == Smc.DIR_BULL ? Brushes.DeepSkyBlue : Brushes.Magenta));
                    Draw.Rectangle(this, ZoneTag(o.id), false, t1, o.top, t2, o.bottom, b, b, 15);
                }
            }
            catch (Exception)
            {
                //--- drawing is optional (e.g. Strategy Analyzer has no chart)
            }
        }

        #endregion

        #region Properties

        //--- Market structure
        [NinjaScriptProperty]
        [Display(Name = "Swing strength (bars each side)", Order = 1, GroupName = "01. Market Structure")]
        public int SwingLength { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Min swing prominence (x ATR, 0 = off)", Order = 2, GroupName = "01. Market Structure")]
        public double SwingMinATR { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "BOS confirmation mode", Order = 3, GroupName = "01. Market Structure")]
        public SmcBosMode BOSMode { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "BOS close buffer (x ATR, buffer mode)", Order = 4, GroupName = "01. Market Structure")]
        public double BOSBufferATR { get; set; }

        //--- Displacement
        [NinjaScriptProperty]
        [Display(Name = "ATR period", Order = 1, GroupName = "02. Displacement")]
        public int ATRPeriod { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Displacement ATR multiplier (net leg move)", Order = 2, GroupName = "02. Displacement")]
        public double DispATRMult { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Min displacement strength (strongest body x ATR)", Order = 3, GroupName = "02. Displacement")]
        public double DispCandleATRMult { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Min candle body % of range", Order = 4, GroupName = "02. Displacement")]
        public double DispMinBodyPct { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Min relative strength (body / avg body)", Order = 5, GroupName = "02. Displacement")]
        public double DispMinRelStrength { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Max distance OB -> BOS (bars)", Order = 6, GroupName = "02. Displacement")]
        public int MaxOBToBOSBars { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Reject if leg trades beyond OB far edge", Order = 7, GroupName = "02. Displacement")]
        public bool RejectLegViolation { get; set; }

        //--- Order blocks
        [NinjaScriptProperty]
        [Display(Name = "Timeframes (HTF Order Block -> CISD)", Order = 1, GroupName = "03. Order Blocks")]
        public SmcTfPair TimeframePair { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Detect bullish OBs", Order = 2, GroupName = "03. Order Blocks")]
        public bool EnableBull { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Detect bearish OBs", Order = 3, GroupName = "03. Order Blocks")]
        public bool EnableBear { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "OB extension (bars right of last bar)", Order = 4, GroupName = "03. Order Blocks")]
        public int ExtendBars { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Max active OBs per direction", Order = 5, GroupName = "03. Order Blocks")]
        public int MaxActivePerDir { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Expire OB after N bars (0 = never)", Order = 6, GroupName = "03. Order Blocks")]
        public int MaxAgeBars { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Overlapping zones", Order = 7, GroupName = "03. Order Blocks")]
        public SmcOverlapMode OverlapMode { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Overlap threshold (% of smaller zone)", Order = 8, GroupName = "03. Order Blocks")]
        public double OverlapPct { get; set; }

        //--- FVG
        [NinjaScriptProperty]
        [Display(Name = "FVG confirmation", Order = 1, GroupName = "04. Fair Value Gap")]
        public SmcFvgMode FVGMode { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "FVG minimum size (x ATR)", Order = 2, GroupName = "04. Fair Value Gap")]
        public double FVGMinATR { get; set; }

        //--- Retest / mitigation
        [NinjaScriptProperty]
        [Display(Name = "Retest detection", Order = 1, GroupName = "05. Retest / Mitigation")]
        public bool RetestEnabled { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Mitigation detection", Order = 2, GroupName = "05. Retest / Mitigation")]
        public SmcMitigationMode MitigationMode { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "OB invalidation method", Order = 3, GroupName = "05. Retest / Mitigation")]
        public SmcInvalidationMode InvalidationMode { get; set; }

        //--- CISD
        [NinjaScriptProperty]
        [Display(Name = "Enable CISD", Order = 1, GroupName = "06. CISD")]
        public bool EnableCISD { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Liquidity Sweep", Order = 2, GroupName = "06. CISD")]
        public bool CISDSweep { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Confirmation Close", Order = 3, GroupName = "06. CISD")]
        public bool CISDConfirm { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Retracement / Entry", Order = 4, GroupName = "06. CISD")]
        public bool CISDRetrace { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Liquidity swing strength (bars each side)", Order = 5, GroupName = "06. CISD")]
        public int CISDSwingLength { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Liquidity swing min prominence (x ATR)", Order = 6, GroupName = "06. CISD")]
        public double CISDSwingMinATR { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Swing stays liquidity for N bars (0 = always)", Order = 7, GroupName = "06. CISD")]
        public int CISDSwingMaxAge { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Sweep definition", Order = 8, GroupName = "06. CISD")]
        public CisdSweepMode CISDSweepMode { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Sweep can feed a later series for N bars", Order = 9, GroupName = "06. CISD")]
        public int CISDSweepValidity { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Confirmation level", Order = 10, GroupName = "06. CISD")]
        public CisdLevelMode CISDLevelMode { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Max candles in the series", Order = 11, GroupName = "06. CISD")]
        public int CISDMaxSeries { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Setup expires after N bars", Order = 12, GroupName = "06. CISD")]
        public int CISDMaxConfirmBars { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Retracement window (bars)", Order = 13, GroupName = "06. CISD")]
        public int CISDMaxRetraceBars { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "CISD history scan depth (CISD bars)", Order = 14, GroupName = "06. CISD")]
        public int CISDScanDepth { get; set; }

        //--- HTF OB -> LTF CISD
        [NinjaScriptProperty]
        [Display(Name = "HTF OB -> CISD connection", Order = 1, GroupName = "07. HTF OB -> LTF CISD")]
        public bool ConnEnable { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "CISD validation", Order = 2, GroupName = "07. HTF OB -> LTF CISD")]
        public ConnCisdMode ConnCISDMode { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Bars to find a CISD after the retest (CISD TF)", Order = 3, GroupName = "07. HTF OB -> LTF CISD")]
        public int ConnMaxCISDBars { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "CISD warm-up bars before the retest", Order = 4, GroupName = "07. HTF OB -> LTF CISD")]
        public int ConnWarmupBars { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Retest mode", Order = 5, GroupName = "07. HTF OB -> LTF CISD")]
        public ConnRetestMode ConnRetestMode { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Max CISD sequences per Order Block", Order = 6, GroupName = "07. HTF OB -> LTF CISD")]
        public int ConnMaxRetests { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Mitigation stops CISD search", Order = 7, GroupName = "07. HTF OB -> LTF CISD")]
        public bool ConnMitigationStops { get; set; }

        //--- Trading
        [NinjaScriptProperty]
        [Display(Name = "Trend filter: only CISDs with the OB-timeframe trend", Order = 1, GroupName = "08. Trading")]
        public bool TrendFilter { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Trend filter: OB candles measured", Order = 2, GroupName = "08. Trading")]
        public int TrendBars { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Trend filter: displacement needed, in ATR", Order = 3, GroupName = "08. Trading")]
        public double TrendATRMult { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Execute trades", Order = 4, GroupName = "08. Trading")]
        public bool EnableTrading { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Contracts, when risk sizing is off (MT5: lot size)", Order = 5, GroupName = "08. Trading")]
        public int Contracts { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Size from equity risk instead of fixed contracts", Order = 6, GroupName = "08. Trading")]
        public bool RiskPercentMode { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Percent of equity risked per trade", Order = 7, GroupName = "08. Trading")]
        public double RiskPercent { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Opposite block exit", Order = 8, GroupName = "08. Trading")]
        public bool OppositeBlockExit { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Take profit, as a multiple of risk (1.0 = 1:1)", Order = 9, GroupName = "08. Trading")]
        public double TargetRR { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Ride the trend: hold to the nearest opposite OB", Order = 10, GroupName = "08. Trading")]
        public bool RideTrend { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Entry alert (works with trading off)", Order = 11, GroupName = "08. Trading")]
        public bool EntryAlert { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Score every confirmed setup and log it", Order = 12, GroupName = "08. Trading")]
        public bool ConfidenceLog { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Confidence log file (NinjaTrader 8 user folder)", Order = 13, GroupName = "08. Trading")]
        public string ConfidenceFile { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Closed-trade results file (NinjaTrader 8 user folder)", Order = 14, GroupName = "08. Trading")]
        public string ResultFile { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Break even: move the stop to entry once in profit", Order = 15, GroupName = "08. Trading")]
        public bool BreakEven { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Break even trigger: profit in ticks (MT5: points)", Order = 16, GroupName = "08. Trading")]
        public int BreakEvenTicks { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Account size (equity base for risk % and guards)", Order = 17, GroupName = "08. Trading")]
        public double EquityBase { get; set; }

        //--- Capital protection
        [NinjaScriptProperty]
        [Display(Name = "Capital protection", Order = 1, GroupName = "09. Capital Protection")]
        public bool CapitalGuards { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Daily loss, % of day-start equity (0 = off)", Order = 2, GroupName = "09. Capital Protection")]
        public double GuardDailyLoss { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Weekly loss, % of week-start equity (0 = off)", Order = 3, GroupName = "09. Capital Protection")]
        public double GuardWeeklyLoss { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Losses in a row before pausing (0 = off)", Order = 4, GroupName = "09. Capital Protection")]
        public int GuardMaxConsec { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Equity stop below the peak, % (0 = off)", Order = 5, GroupName = "09. Capital Protection")]
        public double GuardEquityStop { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Spread above this share of the stop, % (0 = off)", Order = 6, GroupName = "09. Capital Protection")]
        public double GuardSpreadPctOfR { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "ATR(14) above this multiple of its average (0 = off)", Order = 7, GroupName = "09. Capital Protection")]
        public double GuardVolSpike { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Bars in that ATR average", Order = 8, GroupName = "09. Capital Protection")]
        public int GuardVolAvgBars { get; set; }

        //--- History
        [NinjaScriptProperty]
        [Display(Name = "Historical scan depth (OB bars)", Order = 1, GroupName = "10. History")]
        public int ScanDepth { get; set; }

        //--- Display / diagnostics
        [Display(Name = "Draw Order Block zones", Order = 1, GroupName = "11. Display / Diagnostics")]
        public bool ShowZones { get; set; }

        [Display(Name = "Keep mitigated / invalidated zones", Order = 2, GroupName = "11. Display / Diagnostics")]
        public bool ShowInactive { get; set; }

        [Display(Name = "Debug logging", Order = 3, GroupName = "11. Display / Diagnostics")]
        public SmcLogLevel DebugLogLevel { get; set; }

        [Display(Name = "Alert on OB created / retest / CISD", Order = 4, GroupName = "11. Display / Diagnostics")]
        public bool AlertsEnabled { get; set; }

        #endregion
    }
}
