//+------------------------------------------------------------------+
//|                                               SMC_OB_Guards.mqh  |
//|  SPDX-License-Identifier: MIT                                    |
//|  https://github.com/MrOwl1011/Smc_ZOB_CISD                       |
//|  Capital protection. Step 5 of RISK_FRAMEWORK.md.                |
//|                                                                  |
//|  Every guard here is a refusal, never a resize: it either lets   |
//|  a new trade through or it does not. Nothing in this file sends  |
//|  an order. The equity stop asks for a flatten and the trade      |
//|  engine carries it out, so SMC_OB_TradeHooks.mqh stays the only  |
//|  place an order is sent from.                                    |
//|                                                                  |
//|  Every guard defaults to off, so a preset written before this    |
//|  file existed behaves exactly as it did.                         |
//|                                                                  |
//|  The counters that must outlive a restart - the day and week     |
//|  baselines, the equity peak, the losing streak and the halt      |
//|  flag - live in GlobalVariables keyed by magic and symbol. A     |
//|  terminal restart in the middle of a breached day must not hand  |
//|  the EA a clean slate.                                           |
//+------------------------------------------------------------------+
#ifndef SMC_OB_GUARDS_MQH
#define SMC_OB_GUARDS_MQH

//--- why a signal was refused, for the journal and the panel
enum ENUM_GUARD_BLOCK
  {
   GUARD_OK = 0,
   GUARD_DAILY_LOSS,
   GUARD_WEEKLY_LOSS,
   GUARD_CONSEC_LOSSES,
   GUARD_EQUITY_STOP,
   GUARD_SPREAD,
   GUARD_VOLATILITY
  };

string SMC_GuardName(const ENUM_GUARD_BLOCK g)
  {
   switch(g)
     {
      case GUARD_DAILY_LOSS:     return "daily loss limit";
      case GUARD_WEEKLY_LOSS:    return "weekly loss limit";
      case GUARD_CONSEC_LOSSES:  return "losing streak";
      case GUARD_EQUITY_STOP:    return "equity stop";
      case GUARD_SPREAD:         return "spread too wide";
      case GUARD_VOLATILITY:     return "volatility spike";
     }
   return "none";
  }

class CSMCCapitalGuard
  {
private:
   //--- settings
   bool              m_on;             // master switch: off means every guard is inert
   double            m_dailyPct;       // stop new trades once the day is down this much, 0 = off
   double            m_weeklyPct;      // same for the week, 0 = off
   int               m_maxConsec;      // pause after this many losses in a row, 0 = off
   double            m_equityStopPct;  // flatten and halt below this much off the peak, 0 = off
   double            m_spreadPctOfR;   // refuse when spread exceeds this share of the stop, 0 = off
   double            m_volSpikeMult;   // refuse when ATR is this many times its own average, 0 = off
   int               m_volAvgBars;     // bars in that ATR average

   //--- state
   long              m_magic;
   bool              m_ready;
   int               m_atrHandle;
   datetime          m_dayStart;       // server midnight of the day the baseline belongs to
   datetime          m_weekStart;      // server midnight of that week's Monday
   double            m_dayRealised;    // realised P/L since m_dayStart
   double            m_weekRealised;
   double            m_peakEquity;
   int               m_consec;         // losses in a row
   datetime          m_lastLossTime;
   bool              m_halted;         // equity stop has fired; only a human clears it
   bool              m_flatten;        // the engine is being asked to close everything
   ENUM_GUARD_BLOCK  m_lastBlock;
   int               m_refused;

   //--- persistence -------------------------------------------------
   string            GVName(const string key) const
     {
      return StringFormat("SMC_GUARD_%I64d_%s_%s", m_magic, _Symbol, key);
     }
   void              Store(const string key, const double v) const
     {
      GlobalVariableSet(GVName(key), v);
     }
   double            Load(const string key, const double dflt) const
     {
      double v = 0.0;
      if(GlobalVariableGet(GVName(key), v))
         return v;
      return dflt;
     }
   void              Persist(void) const
     {
      Store("dayStart",   (double)m_dayStart);
      Store("weekStart",  (double)m_weekStart);
      Store("dayPL",      m_dayRealised);
      Store("weekPL",     m_weekRealised);
      Store("peak",       m_peakEquity);
      Store("consec",     (double)m_consec);
      Store("lastLoss",   (double)m_lastLossTime);
      Store("halted",     m_halted ? 1.0 : 0.0);
     }

   //--- server midnight of the day t falls in
   static datetime   DayOf(const datetime t)
     {
      MqlDateTime d;
      TimeToStruct(t, d);
      d.hour = 0; d.min = 0; d.sec = 0;
      return StructToTime(d);
     }
   //--- Server midnight of that week's Monday. The broker's week, not the
   //--- calendar's: a Sunday session belongs to the week about to start, not the
   //--- one that just ended.
   static datetime   WeekOf(const datetime t)
     {
      MqlDateTime d;
      TimeToStruct(t, d);
      int back = (d.day_of_week == 0) ? 0 : d.day_of_week - 1;
      return DayOf(t) - back * 86400;
     }

public:
                     CSMCCapitalGuard(void) : m_on(false), m_dailyPct(0.0), m_weeklyPct(0.0),
                                              m_maxConsec(0), m_equityStopPct(0.0),
                                              m_spreadPctOfR(0.0), m_volSpikeMult(0.0),
                                              m_volAvgBars(200), m_magic(0), m_ready(false),
                                              m_atrHandle(INVALID_HANDLE), m_dayStart(0), m_weekStart(0),
                                              m_dayRealised(0.0), m_weekRealised(0.0),
                                              m_peakEquity(0.0), m_consec(0), m_lastLossTime(0),
                                              m_halted(false), m_flatten(false),
                                              m_lastBlock(GUARD_OK), m_refused(0) {}
                    ~CSMCCapitalGuard(void)
     {
      if(m_atrHandle != INVALID_HANDLE)
         IndicatorRelease(m_atrHandle);
     }

   void              Configure(const bool on, const double dailyPct, const double weeklyPct,
                               const int maxConsec, const double equityStopPct,
                               const double spreadPctOfR, const double volSpikeMult,
                               const int volAvgBars, const long magic)
     {
      m_on            = on;
      m_dailyPct      = MathMax(0.0, dailyPct);
      m_weeklyPct     = MathMax(0.0, weeklyPct);
      m_maxConsec     = MathMax(0, maxConsec);
      m_equityStopPct = MathMax(0.0, equityStopPct);
      m_spreadPctOfR  = MathMax(0.0, spreadPctOfR);
      m_volSpikeMult  = MathMax(0.0, volSpikeMult);
      m_volAvgBars    = MathMax(20, volAvgBars);
      m_magic         = magic;

      if(m_volSpikeMult > 0.0 && m_atrHandle == INVALID_HANDLE)
        {
         m_atrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
         if(m_atrHandle == INVALID_HANDLE)
            Print("[SMC-GUARD] ATR unavailable: the volatility filter is inert");
        }

      //--- pick up where a previous session left off
      datetime now   = TimeCurrent();
      m_dayStart     = (datetime)Load("dayStart", 0);
      m_weekStart    = (datetime)Load("weekStart", 0);
      m_dayRealised  = Load("dayPL", 0.0);
      m_weekRealised = Load("weekPL", 0.0);
      m_peakEquity   = Load("peak", 0.0);
      m_consec       = (int)Load("consec", 0);
      m_lastLossTime = (datetime)Load("lastLoss", 0);
      m_halted       = (Load("halted", 0.0) > 0.5);
      if(m_peakEquity <= 0.0)
         m_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(m_dayStart == 0 || DayOf(now) != m_dayStart)
        {
         m_dayStart    = DayOf(now);
         m_dayRealised = 0.0;
        }
      if(m_weekStart == 0 || WeekOf(now) != m_weekStart)
        {
         m_weekStart    = WeekOf(now);
         m_weekRealised = 0.0;
        }
      m_ready = true;
      Persist();

      if(m_on)
         Print("[SMC-GUARD] capital protection ON: ", Settings());
      else
         Print("[SMC-GUARD] capital protection OFF");
     }

   //--- A fresh tester run must not inherit the last one's counters. The tester
   //--- keeps GlobalVariables between runs, which would otherwise carry a halt
   //--- from one backtest into the next and silently flatten the results.
   void              ResetState(void)
     {
      datetime now   = TimeCurrent();
      m_dayStart     = DayOf(now);
      m_weekStart    = WeekOf(now);
      m_dayRealised  = 0.0;
      m_weekRealised = 0.0;
      m_peakEquity   = AccountInfoDouble(ACCOUNT_EQUITY);
      m_consec       = 0;
      m_lastLossTime = 0;
      m_halted       = false;
      m_flatten      = false;
      m_refused      = 0;
      m_lastBlock    = GUARD_OK;
      Persist();
     }

   //--- Called every tick. Rolls the day and week baselines, tracks the equity
   //--- peak, and fires the equity stop. Returns true when it has just asked for
   //--- a flatten, so the caller can act on it without polling.
   bool              Update(void)
     {
      if(!m_ready || !m_on)
         return false;
      datetime now = TimeCurrent();
      if(DayOf(now) != m_dayStart)
        {
         m_dayStart    = DayOf(now);
         m_dayRealised = 0.0;
        }
      if(WeekOf(now) != m_weekStart)
        {
         m_weekStart    = WeekOf(now);
         m_weekRealised = 0.0;
        }
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity > m_peakEquity)
         m_peakEquity = equity;
      //--- The equity stop watches equity, not realised P/L: an open trade running
      //--- away is exactly the case it exists for.
      if(m_equityStopPct > 0.0 && !m_halted && m_peakEquity > 0.0 &&
         equity < m_peakEquity * (1.0 - m_equityStopPct / 100.0))
        {
         m_halted  = true;
         m_flatten = true;
         PrintFormat("[SMC-GUARD] EQUITY STOP: %.2f is %.2f%% below the peak of %.2f. "
                     "Flattening, and no new trades until the halt is cleared.",
                     equity, 100.0 * (m_peakEquity - equity) / m_peakEquity, m_peakEquity);
         Persist();
         return true;
        }
      return false;
     }

   //--- The engine reports every closed trade here, so the streak and the day and
   //--- week totals are built from realised money only.
   void              OnTradeClosed(const double profit)
     {
      if(!m_ready)
         return;
      m_dayRealised  += profit;
      m_weekRealised += profit;
      if(profit < 0.0)
        {
         m_consec++;
         m_lastLossTime = TimeCurrent();
         if(m_on && m_maxConsec > 0 && m_consec >= m_maxConsec)
            PrintFormat("[SMC-GUARD] %d losses in a row: paused until the next session", m_consec);
        }
      else
         m_consec = 0;
      Persist();
     }

   //--- A losing streak is forgiven by a new day, which is what "the next session"
   //--- means for an EA that trades one symbol around the clock.
   bool              NewSessionSinceLastLoss(void) const
     {
      if(m_lastLossTime == 0)
         return true;
      return (DayOf(TimeCurrent()) > DayOf(m_lastLossTime));
     }

   bool              SpreadTooWide(const double riskPrice) const
     {
      if(m_spreadPctOfR <= 0.0 || riskPrice <= 0.0)
         return false;
      double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * point;
      if(spread <= 0.0)
         return false;
      return (spread > m_spreadPctOfR / 100.0 * riskPrice);
     }

   bool              VolatilitySpike(void) const
     {
      if(m_volSpikeMult <= 0.0 || m_atrHandle == INVALID_HANDLE)
         return false;
      int need = m_volAvgBars;
      double a[];
      if(CopyBuffer(m_atrHandle, 0, 0, need, a) < need)
         return false;                            // not enough history yet: do not block
      double sum = 0.0;
      for(int i = 0; i < need; i++)
         sum += a[i];
      double avg = sum / need;
      if(avg <= 0.0)
         return false;
      return (a[need - 1] > m_volSpikeMult * avg);
     }

   //--- Is this signal allowed through? riskPrice is the entry-to-stop distance in
   //--- price, which is what the spread guard measures itself against.
   bool              AllowNewTrade(const double riskPrice)
     {
      m_lastBlock = GUARD_OK;
      if(!m_ready || !m_on)
         return true;

      if(m_halted)
         m_lastBlock = GUARD_EQUITY_STOP;
      else
        {
         //--- The baselines are reconstructed from current equity rather than
         //--- stored, so a deposit or withdrawal mid-day cannot be mistaken for
         //--- a loss.
         double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
         double dayBase  = equity - m_dayRealised;
         double weekBase = equity - m_weekRealised;
         if(m_dailyPct > 0.0 && dayBase > 0.0 &&
            m_dayRealised <= -m_dailyPct / 100.0 * dayBase)
            m_lastBlock = GUARD_DAILY_LOSS;
         else if(m_weeklyPct > 0.0 && weekBase > 0.0 &&
                 m_weekRealised <= -m_weeklyPct / 100.0 * weekBase)
            m_lastBlock = GUARD_WEEKLY_LOSS;
         else if(m_maxConsec > 0 && m_consec >= m_maxConsec && !NewSessionSinceLastLoss())
            m_lastBlock = GUARD_CONSEC_LOSSES;
         else if(SpreadTooWide(riskPrice))
            m_lastBlock = GUARD_SPREAD;
         else if(VolatilitySpike())
            m_lastBlock = GUARD_VOLATILITY;
        }

      if(m_lastBlock == GUARD_OK)
         return true;
      m_refused++;
      Print("[SMC-GUARD] refused: ", SMC_GuardName(m_lastBlock));
      return false;
     }

   //--- the equity stop asks, the trade engine closes
   bool              FlattenRequested(void) const { return m_flatten; }
   void              ClearFlatten(void)           { m_flatten = false; }

   bool              Enabled(void) const      { return m_on; }
   bool              Halted(void) const       { return m_halted; }
   int               Refused(void) const      { return m_refused; }
   int               ConsecLosses(void) const  { return m_consec; }
   double            DayPL(void) const         { return m_dayRealised; }
   double            WeekPL(void) const        { return m_weekRealised; }
   ENUM_GUARD_BLOCK  LastBlock(void) const     { return m_lastBlock; }

   void              SetEnabled(const bool on)
     {
      if(on != m_on)
         Print("[SMC-GUARD] capital protection ", on ? "ON" : "OFF");
      m_on = on;
     }

   //--- A halt is deliberately sticky: it survives restarts, and clearing it is a
   //--- decision a person makes, from the panel or by reloading with the guard off.
   void              ClearHalt(void)
     {
      if(!m_halted)
         return;
      m_halted     = false;
      m_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      Print("[SMC-GUARD] halt cleared by hand; the equity peak is reset to the current equity");
      Persist();
     }

   string            Settings(void) const
     {
      string s = "";
      if(m_dailyPct > 0.0)      s += StringFormat("day -%.1f%% ", m_dailyPct);
      if(m_weeklyPct > 0.0)     s += StringFormat("week -%.1f%% ", m_weeklyPct);
      if(m_maxConsec > 0)       s += StringFormat("streak %d ", m_maxConsec);
      if(m_equityStopPct > 0.0) s += StringFormat("equity -%.1f%% ", m_equityStopPct);
      if(m_spreadPctOfR > 0.0)  s += StringFormat("spread %.1f%% of R ", m_spreadPctOfR);
      if(m_volSpikeMult > 0.0)  s += StringFormat("vol %.1fx ", m_volSpikeMult);
      if(StringLen(s) == 0)
         s = "nothing armed";
      return s;
     }

   //--- one line for the panel
   string            Status(void) const
     {
      if(!m_on)
         return "guards OFF";
      if(m_halted)
         return "HALTED by the equity stop";
      return StringFormat("guards ON | day %.2f week %.2f | streak %d | %d refused",
                          m_dayRealised, m_weekRealised, m_consec, m_refused);
     }
  };

#endif // SMC_OB_GUARDS_MQH
