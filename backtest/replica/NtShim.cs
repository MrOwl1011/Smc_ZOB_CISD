// Minimal stand-ins for the NinjaTrader 8 API surface that SMCOrderBlockStrategy.cs touches, so
// the strategy compiles unchanged against the replica. The order layer (Strategy base below)
// reproduces the Strategy Analyzer's historical fill rules for this strategy's managed orders:
//   - EnterLong/EnterShort/ExitLong/ExitShort are market orders on the series they name; they fill
//     at the Open of that series' next processed bar.
//   - SetStopLoss/SetProfitTarget (CalculationMode.Price) arm a stop-market / limit pair per entry
//     signal; they go live the instant the entry fills, so the fill bar's own range can hit them.
//   - Stop before target when one bar touches both (NT8 cannot know the order inside a bar either
//     way; the pessimistic choice matches what the Analyzer reports for this harness's validation).
//   - A stop gapped through fills at the Open; a limit fills only on trade-through
//     (IsFillLimitOnTouch = false), at the limit price even when the bar gaps past it (as NT8 reports).
using System;
using System.Collections.Generic;
using System.Globalization;

namespace System.Windows.Media
{
    public class Brush { }
    public static class Brushes
    {
        public static readonly Brush Black = new Brush(), Yellow = new Brush(), DimGray = new Brush(), Goldenrod = new Brush(),
            DeepSkyBlue = new Brush(), Magenta = new Brush();
    }
}

namespace NinjaTrader.Core
{
    public static class Globals
    {
        public static string UserDataDir = System.IO.Path.GetTempPath();
        public static string InstallDir = System.IO.Path.GetTempPath();
    }
}

namespace NinjaTrader.Gui { internal static class _GuiNs { } }

namespace NinjaTrader.Data
{
    public enum BarsPeriodType { Tick, Volume, Range, Second, Minute, Day, Week, Month, Year }
}

namespace NinjaTrader.Cbi
{
    public enum MarketPosition { Flat, Long, Short }
    public enum OrderState { Initialized, Submitted, Accepted, Working, PartFilled, Filled, Cancelled, Rejected }
    public enum ErrorCode { NoError }
    public enum PerformanceUnit { Currency, Percent, Pips, Points, Ticks }
    public enum TimeInForce { Day, Gtc }

    public class MasterInstrument
    {
        public string Name;
        public double TickSize;
        public double PointValue;
        public string FormatPrice(double p) { return p.ToString("0.########", CultureInfo.InvariantCulture); }
        public double RoundToTickSize(double p) { return Math.Round(p / TickSize, MidpointRounding.AwayFromZero) * TickSize; }
    }

    public class Instrument
    {
        public string FullName;
        public MasterInstrument MasterInstrument;
    }

    public class Order
    {
        public string Name;
        public OrderState OrderState;
    }

    public class Execution
    {
        public Order Order;
    }

    public class Position
    {
        internal NinjaTrader.NinjaScript.Strategies.Strategy owner;
        public MarketPosition MarketPosition;
        public int Quantity;
        public double AveragePrice;
        public double GetUnrealizedProfitLoss(PerformanceUnit unit, double price)
        {
            if (MarketPosition == MarketPosition.Flat) return 0.0;
            int d = MarketPosition == MarketPosition.Long ? 1 : -1;
            return (price - AveragePrice) * d * Quantity * owner.Instrument.MasterInstrument.PointValue;
        }
    }

    public class Trade
    {
        public DateTime EntryTime, ExitTime;
        public bool IsLong;
        public double EntryPrice, ExitPrice;
        public int Quantity;
        public string ExitName;
        public double ProfitCurrency;     // after commission
        public double Commission;
    }

    public class CurrencyPerf { public double CumProfit; }
    public class TradesPerformance { public CurrencyPerf Currency = new CurrencyPerf(); }

    public class TradeCollection
    {
        internal readonly List<Trade> list = new List<Trade>();
        public TradesPerformance TradesPerformance = new TradesPerformance();
        public int Count { get { return list.Count; } }
        public Trade this[int i] { get { return list[i]; } }
        internal void Add(Trade t) { list.Add(t); TradesPerformance.Currency.CumProfit += t.ProfitCurrency; }
    }

    public class SystemPerformance { public TradeCollection AllTrades = new TradeCollection(); }
}

namespace NinjaTrader.NinjaScript
{
    public enum State { SetDefaults, Configure, DataLoaded, Historical, Transition, Realtime, Terminated }
    public enum Calculate { OnBarClose, OnEachTick, OnPriceChange }
    public enum EntryHandling { AllEntries, UniqueEntries }
    public enum MaximumBarsLookBack { TwoHundredFiftySix, Infinite }
    public enum OrderFillResolution { Standard, High }
    public enum StartBehavior { AdoptAccountPosition, ImmediatelySubmit, WaitUntilFlat, WaitUntilFlatSynchronizeAccount }
    public enum RealtimeErrorHandling { IgnoreAllErrors, StopCancelClose, StopCancelCloseIgnoreRejects }
    public enum StopTargetHandling { ByStrategyPosition, PerEntryExecution }
    public enum CalculationMode { Currency, Percent, Price, Ticks, Pips }
    public enum Priority { Low, Medium, High }

    [AttributeUsage(AttributeTargets.Property)]
    public class NinjaScriptPropertyAttribute : Attribute { }
}

namespace NinjaTrader.NinjaScript.DrawingTools
{
    public static class Draw
    {
        public static object Rectangle(object owner, string tag, bool autoScale, DateTime t1, double y1, DateTime t2, double y2,
                                       System.Windows.Media.Brush b1, System.Windows.Media.Brush b2, int opacity) { return null; }
    }
}

namespace NinjaTrader.NinjaScript.Strategies
{
    using NinjaTrader.Cbi;
    using NinjaTrader.Data;
    using NinjaTrader.NinjaScript;

    /// <summary>One bar series as NinjaScript sees it: arrays in chronological order and the index
    /// of the bar currently being processed (-1 before the first).</summary>
    public class SeriesData
    {
        public DateTime[] T;
        public double[] O, H, L, C;
        public int Cur = -1;
        public int Count { get { return T.Length; } }
    }

    public class BarsAgo<T>
    {
        private readonly SeriesData s; private readonly Func<SeriesData, int, T> get;
        public BarsAgo(SeriesData s, Func<SeriesData, int, T> get) { this.s = s; this.get = get; }
        public T this[int barsAgo] { get { return get(s, s.Cur - barsAgo); } }
    }

    public class Multi<T>
    {
        internal BarsAgo<T>[] arr;
        public BarsAgo<T> this[int bip] { get { return arr[bip]; } }
    }

    public class CurrentBarsView
    {
        internal Func<SeriesData[]> series;
        public int this[int bip] { get { return series()[bip].Cur; } }
    }

    /// <summary>The NT8 Strategy surface used by SMCOrderBlockStrategy, plus the replica's fill engine.</summary>
    public abstract class Strategy
    {
        // ---- NinjaScript properties set in SetDefaults ----
        public string Name, Description;
        public Calculate Calculate;
        public int EntriesPerDirection;
        public EntryHandling EntryHandling;
        public bool IsExitOnSessionCloseStrategy;
        public int ExitOnSessionCloseSeconds;
        public bool IsFillLimitOnTouch;
        public MaximumBarsLookBack MaximumBarsLookBack;
        public OrderFillResolution OrderFillResolution;
        public int Slippage;
        public StartBehavior StartBehavior;
        public TimeInForce TimeInForce;
        public bool TraceOrders;
        public RealtimeErrorHandling RealtimeErrorHandling;
        public StopTargetHandling StopTargetHandling;
        public int BarsRequiredToTrade;
        public bool IsInstantiatedOnEachOptimizationIteration;
        public State State;

        public Instrument Instrument;
        public double TickSize { get { return Instrument.MasterInstrument.TickSize; } }
        public Position Position;
        public SystemPerformance SystemPerformance = new SystemPerformance();

        // ---- replica wiring ----
        internal SeriesData[] series = new SeriesData[0];
        internal readonly List<int> requestedMinutes = new List<int>();
        public int BarsInProgress { get; internal set; }
        public Multi<DateTime> Times;
        public Multi<double> Opens, Highs, Lows, Closes;
        public CurrentBarsView CurrentBars;
        public double CommissionPerSide;
        public Action<string> PrintSink;

        protected Strategy()
        {
            Position = new Position { owner = this };
            CurrentBars = new CurrentBarsView { series = () => series };
        }

        internal void BindSeries(SeriesData[] all)
        {
            series = all;
            int n = all.Length;
            Times = new Multi<DateTime> { arr = new BarsAgo<DateTime>[n] };
            Opens = new Multi<double> { arr = new BarsAgo<double>[n] };
            Highs = new Multi<double> { arr = new BarsAgo<double>[n] };
            Lows = new Multi<double> { arr = new BarsAgo<double>[n] };
            Closes = new Multi<double> { arr = new BarsAgo<double>[n] };
            for (int b = 0; b < n; b++)
            {
                Times.arr[b] = new BarsAgo<DateTime>(all[b], (s, i) => s.T[i]);
                Opens.arr[b] = new BarsAgo<double>(all[b], (s, i) => s.O[i]);
                Highs.arr[b] = new BarsAgo<double>(all[b], (s, i) => s.H[i]);
                Lows.arr[b] = new BarsAgo<double>(all[b], (s, i) => s.L[i]);
                Closes.arr[b] = new BarsAgo<double>(all[b], (s, i) => s.C[i]);
            }
        }

        private SeriesData Cs { get { return series[BarsInProgress]; } }
        public int CurrentBar { get { return Cs.Cur; } }
        public BarsAgo<double> High { get { return Highs[BarsInProgress]; } }
        public BarsAgo<double> Low { get { return Lows[BarsInProgress]; } }
        public BarsAgo<double> Close { get { return Closes[BarsInProgress]; } }

        protected virtual void OnStateChange() { }
        protected virtual void OnBarUpdate() { }
        protected virtual void OnExecutionUpdate(Execution execution, string executionId, double price, int quantity,
                                                 MarketPosition marketPosition, string orderId, DateTime time) { }
        protected virtual void OnOrderUpdate(Order order, double limitPrice, double stopPrice, int quantity, int filled,
                                             double averageFillPrice, OrderState orderState, DateTime time, ErrorCode error, string comment) { }
        protected virtual void OnPositionUpdate(Position position, double averagePrice, int quantity, MarketPosition marketPosition) { }

        internal void RaiseStateChange(State s) { State = s; OnStateChange(); }
        internal void RaiseBarUpdate(int bip) { BarsInProgress = bip; OnBarUpdate(); }

        protected void AddDataSeries(BarsPeriodType type, int value) { requestedMinutes.Add(value); }
        public void Print(object o) { PrintSink?.Invoke(o == null ? "" : o.ToString()); }
        protected void Alert(string id, Priority p, string msg, string sound, int rearm, System.Windows.Media.Brush back, System.Windows.Media.Brush fore) { }
        protected void RemoveDrawObject(string tag) { }

        // Historical bars have no bid/ask: NT8 returns the series' close for both.
        public double GetCurrentAsk(int bip) { return series[bip].C[series[bip].Cur]; }
        public double GetCurrentBid(int bip) { return series[bip].C[series[bip].Cur]; }

        // ---- managed orders ----
        private sealed class Pending { public bool isEntry; public int dir; public int qty; public string name; public int bip; public Order order; }
        private readonly List<Pending> pending = new List<Pending>();
        private readonly Dictionary<string, double> stopFor = new Dictionary<string, double>();
        private readonly Dictionary<string, double> targetFor = new Dictionary<string, double>();
        private string liveSignal;
        private double liveStop = double.NaN, liveTarget = double.NaN;
        private DateTime entryTime;
        private int orderBip = -1;

        protected void SetStopLoss(string fromEntrySignal, CalculationMode mode, double value, bool isSimulatedStop)
        {
            stopFor[fromEntrySignal] = value;
            if (Position.MarketPosition != MarketPosition.Flat && fromEntrySignal == liveSignal) liveStop = value;
        }

        protected void SetProfitTarget(string fromEntrySignal, CalculationMode mode, double value)
        {
            targetFor[fromEntrySignal] = value;
            if (Position.MarketPosition != MarketPosition.Flat && fromEntrySignal == liveSignal) liveTarget = value;
        }

        protected Order EnterLong(int bip, int qty, string signalName) { return Submit(true, 1, bip, qty, signalName); }
        protected Order EnterShort(int bip, int qty, string signalName) { return Submit(true, -1, bip, qty, signalName); }
        protected Order ExitLong(int bip, int qty, string signalName, string fromEntrySignal)
        {
            if (Position.MarketPosition != MarketPosition.Long) return null;
            return Submit(false, -1, bip, qty, signalName);
        }
        protected Order ExitShort(int bip, int qty, string signalName, string fromEntrySignal)
        {
            if (Position.MarketPosition != MarketPosition.Short) return null;
            return Submit(false, 1, bip, qty, signalName);
        }

        private Order Submit(bool isEntry, int dir, int bip, int qty, string name)
        {
            if (isEntry)
            {
                // EntriesPerDirection = 1: a second entry while one is open or working is ignored.
                if (Position.MarketPosition != MarketPosition.Flat) return null;
                foreach (var p in pending) if (p.isEntry) return null;
            }
            var o = new Order { Name = name, OrderState = OrderState.Working };
            pending.Add(new Pending { isEntry = isEntry, dir = dir, qty = qty, name = name, bip = bip, order = o });
            return o;
        }

        /// <summary>Fills for orders routed to <paramref name="bip"/>, at the bar about to be processed.
        /// Called by the runner BEFORE OnBarUpdate of that bar.</summary>
        internal void ProcessFills(int bip, int barIndex)
        {
            SeriesData s = series[bip];
            DateTime t = s.T[barIndex];
            double o = s.O[barIndex], h = s.H[barIndex], l = s.L[barIndex];

            // 1. market orders at the open (exits before entries, as they were queued first in practice)
            for (int k = 0; k < pending.Count; k++)
            {
                Pending p = pending[k];
                if (p.bip != bip) continue;
                pending.RemoveAt(k); k--;
                if (!p.isEntry)
                {
                    if (Position.MarketPosition == MarketPosition.Flat) { Cancel(p.order, t); continue; }
                    CloseAt(o, t, p.name);
                }
                else
                {
                    if (Position.MarketPosition != MarketPosition.Flat) { Cancel(p.order, t); continue; }
                    OpenAt(p, o, t, bip);
                }
            }

            // 2. brackets against this bar's range
            if (Position.MarketPosition == MarketPosition.Flat || orderBip != bip) return;
            bool isLong = Position.MarketPosition == MarketPosition.Long;
            bool stopHit = !double.IsNaN(liveStop) && (isLong ? l <= liveStop : h >= liveStop);
            bool tgtHit = !double.IsNaN(liveTarget) && (isLong ? h > liveTarget : l < liveTarget);
            if (stopHit)
                CloseAt(isLong ? Math.Min(liveStop, o) : Math.Max(liveStop, o), t, "Stop loss");
            else if (tgtHit)
                CloseAt(liveTarget, t, "Profit target");   // NT8 fills a limit at its price, even when the bar opens beyond it
        }

        private void Cancel(Order ord, DateTime t)
        {
            ord.OrderState = OrderState.Cancelled;
            OnOrderUpdate(ord, 0, 0, 0, 0, 0, OrderState.Cancelled, t, ErrorCode.NoError, "");
        }

        private void OpenAt(Pending p, double price, DateTime t, int bip)
        {
            Position.MarketPosition = p.dir > 0 ? MarketPosition.Long : MarketPosition.Short;
            Position.Quantity = p.qty;
            Position.AveragePrice = price;
            entryTime = t;
            orderBip = bip;
            liveSignal = p.name;
            liveStop = stopFor.TryGetValue(p.name, out double sp) ? sp : double.NaN;
            liveTarget = targetFor.TryGetValue(p.name, out double tp) ? tp : double.NaN;
            p.order.OrderState = OrderState.Filled;
            OnOrderUpdate(p.order, 0, 0, p.qty, p.qty, price, OrderState.Filled, t, ErrorCode.NoError, "");
            OnExecutionUpdate(new Execution { Order = p.order }, "", price, p.qty, Position.MarketPosition, "", t);
            OnPositionUpdate(Position, price, p.qty, Position.MarketPosition);
        }

        private void CloseAt(double price, DateTime t, string exitName)
        {
            bool isLong = Position.MarketPosition == MarketPosition.Long;
            int qty = Position.Quantity;
            double pv = Instrument.MasterInstrument.PointValue;
            double comm = 2 * CommissionPerSide * qty;
            double gross = (isLong ? price - Position.AveragePrice : Position.AveragePrice - price) * qty * pv;
            SystemPerformance.AllTrades.Add(new Trade
            {
                EntryTime = entryTime, ExitTime = t, IsLong = isLong, EntryPrice = Position.AveragePrice, ExitPrice = price,
                Quantity = qty, ExitName = exitName, ProfitCurrency = gross - comm, Commission = comm
            });
            Position.MarketPosition = MarketPosition.Flat;
            Position.Quantity = 0;
            liveStop = liveTarget = double.NaN;
            liveSignal = null;
            OnPositionUpdate(Position, 0, 0, MarketPosition.Flat);
        }

        /// <summary>End of the backtest: an open position is closed at the last processed close.</summary>
        internal void CloseAtEnd()
        {
            if (Position.MarketPosition == MarketPosition.Flat) return;
            SeriesData s = series[orderBip];
            CloseAt(s.C[s.Cur], s.T[s.Cur], "Exit on session close");
        }
    }
}
