// Dev aid for backtest/: writes every primary-series bar NinjaTrader feeds a Strategy Analyzer run
// (the merged, back-adjusted continuous series) to Documents\NinjaTrader 8\bardump_<instrument>_<period>.txt
// as "yyyyMMdd HHmmss;open;high;low;close;volume" with UTC bar-close stamps, the Historical Data export format.
// Places no orders.
using System;
using System.IO;
using NinjaTrader.Cbi;
using NinjaTrader.NinjaScript;

namespace NinjaTrader.NinjaScript.Strategies.Toreda.SMCPresets
{
    public class SMCBarDump : Strategy
    {
        private StreamWriter w;
        private TimeZoneInfo tz;

        protected override void OnStateChange()
        {
            if (State == State.SetDefaults)
            {
                Name = "SMCBarDump";
                Calculate = Calculate.OnBarClose;
                BarsRequiredToTrade = 0;
                IsExitOnSessionCloseStrategy = false;
            }
            else if (State == State.DataLoaded)
            {
                tz = NinjaTrader.Core.Globals.GeneralOptions.TimeZoneInfo;
                string name = string.Format("bardump_{0}_{1}.txt", Instrument.FullName.Replace(" ", "_"), BarsPeriod.Value);
                w = new StreamWriter(Path.Combine(NinjaTrader.Core.Globals.UserDataDir, name), false);
            }
            else if (State == State.Terminated)
            {
                if (w != null) { w.Flush(); w.Dispose(); w = null; }
            }
        }

        protected override void OnBarUpdate()
        {
            if (w == null || BarsInProgress != 0)
                return;
            DateTime utc = TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(Time[0], DateTimeKind.Unspecified), tz);
            w.WriteLine(string.Format(System.Globalization.CultureInfo.InvariantCulture, "{0:yyyyMMdd HHmmss};{1};{2};{3};{4};{5}",
                utc, Open[0], High[0], Low[0], Close[0], Volume[0]));
        }
    }
}
