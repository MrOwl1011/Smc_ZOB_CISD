//+------------------------------------------------------------------+
//|                                              SMC_CISD_Engine.mqh |
//|  CISD - Change in State of Delivery. Independent detection       |
//|  module: it shares no state with the Order Block / ZOrder        |
//|  engines and runs on its own timeframe.                          |
//|                                                                  |
//|  Bullish (bearish is the mirror image), closed bars only:        |
//|   WAITING                  confirmed swing lows are liquidity    |
//|   LIQUIDITY_SWEEP_LOW      a closed bar trades below a swing low |
//|   IDENTIFY_BEARISH_SERIES  a bearish run ends (non-bearish close)|
//|                            -> complete contiguous run measured   |
//|   WAIT_FOR_BULLISH_CLOSE   setup stored; fails on a lower low    |
//|   BULLISH_CISD_CONFIRMED   close > series level                  |
//|   WAIT_FOR_RETRACEMENT     low <= level -> retraced (entry)      |
//|                            close < sweep extreme -> invalidated  |
//|                                                                  |
//|  Series level: series High (bullish) / Low (bearish) by default, |
//|  or the open of the first series candle (classic CISD).          |
//|                                                                  |
//|  Same indexing contract as the OB engine: r[0] newest CLOSED bar,|
//|  bar i reads only r[i..i+lookback]; each bar processed once.     |
//+------------------------------------------------------------------+
#ifndef SMC_CISD_ENGINE_MQH
#define SMC_CISD_ENGINE_MQH

#include "SMC_OB_Structure.mqh"    // swing confirmation is reused unchanged

enum ENUM_CISD_TF
  {
   CISD_TF_CURRENT = 0,   // Current chart
   CISD_TF_M1,            // M1
   CISD_TF_M5,            // M5
   CISD_TF_M15,           // M15
   CISD_TF_M30,           // M30
   CISD_TF_H1,            // H1
   CISD_TF_H4,            // H4
   CISD_TF_D1             // D1
  };

enum ENUM_CISD_SWEEP_MODE
  {
   CISD_SWEEP_TRADE_THROUGH = 0,  // Price trades beyond the swing
   CISD_SWEEP_REJECTION = 1       // Trades beyond and closes back inside
  };

enum ENUM_CISD_LEVEL_MODE
  {
   CISD_LEVEL_SERIES_RANGE = 0,   // Series range (High for bull / Low for bear)
   CISD_LEVEL_SERIES_OPEN = 1     // Open of first series candle (classic)
  };

//--- what "activation" gates: everything, or only the confirmation close
enum ENUM_CISD_ACTIVATION
  {
   CISD_ACT_ALL_AFTER = 0,        // sweep, series and confirmation must all be at/after activationTime
   CISD_ACT_CONFIRM_AFTER = 1     // series / sweep may start earlier; only the confirmation must be at/after
  };

//--- per-direction machine position (setup side)
enum ENUM_CISD_MACHINE
  {
   CISD_M_WAITING = 0,
   CISD_M_LIQUIDITY_SWEEP,        // sweep recorded, no series yet
   CISD_M_WAIT_FOR_CLOSE          // series identified, waiting for confirmation close
  };

//--- per-record life-cycle
enum ENUM_CISD_STATE
  {
   CISD_ST_SETUP = 0,             // sweep + series identified, NOT a confirmed CISD
   CISD_ST_SETUP_FAILED,          // deeper extreme or no confirmation in time
   CISD_ST_SETUP_REPLACED,        // a newer setup of the same direction took over
   CISD_ST_CONFIRMED,             // confirmed, waiting for retracement
   CISD_ST_RETRACED,              // retracement reached the CISD level (entry signal)
   CISD_ST_INVALIDATED,           // closed beyond the sweep extreme before retracement
   CISD_ST_EXPIRED                // no retracement within the allowed bars
  };

enum ENUM_CISD_EVENT
  {
   CISD_EVT_SWEEP = 0,
   CISD_EVT_SETUP,
   CISD_EVT_SETUP_FAILED,
   CISD_EVT_CONFIRMED,
   CISD_EVT_RETRACED,
   CISD_EVT_INVALIDATED,
   CISD_EVT_EXPIRED
  };

struct SCISDSettings
  {
   ENUM_TIMEFRAMES      timeframe;
   bool                 useSweep;          // panel: Liquidity Sweep
   bool                 useConfirm;        // panel: Confirmation Close
   bool                 useRetrace;        // panel: Retracement / Entry
   int                  swingLength;
   double               swingMinATR;
   int                  atrPeriod;
   int                  swingMaxAge;       // bars a swing stays valid liquidity (0 = unlimited)
   ENUM_CISD_SWEEP_MODE sweepMode;
   int                  sweepValidityBars; // bars a sweep can still feed a later series
   ENUM_CISD_LEVEL_MODE levelMode;
   int                  maxSeriesCandles;
   int                  maxConfirmBars;    // setup expires after N bars
   int                  maxRetraceBars;    // confirmed CISD expires after N bars
   int                  maxStored;
   ENUM_SMC_LOG_LEVEL   logLevel;
   //--- HTF OB -> LTF CISD integration (defaults keep standalone behaviour unchanged)
   datetime             activationTime;    // 0 = always; else no sweep / series may start before it
   int                  dirFilter;         // 0 = both directions, SMC_DIR_BULL / SMC_DIR_BEAR = one side only
   ENUM_CISD_ACTIVATION activationMode;    // how activationTime is applied (default: gate everything)
  };

struct SCISDSwing
  {
   datetime          time;
   double            price;
   long              barNo;         // processed-bar counter at confirmation
   bool              swept;
  };

struct SCISDSweep
  {
   long              id;
   int               dir;           // CISD direction it sets up (sell-side sweep -> bullish)
   datetime          time;
   double            price;         // extreme of the sweeping bar
   datetime          swingTime;     // swept swing
   double            swingPrice;
   long              barNo;
   bool              used;          // already produced a confirmed CISD
  };

struct SCISD
  {
   //--- identity (fixed when the setup is created)
   long              id;
   int               dir;
   ENUM_TIMEFRAMES   timeframe;
   bool              hasSweep;
   long              sweepId;
   datetime          sweepTime;
   double            sweepPrice;
   datetime          sweptSwingTime;
   double            sweptSwingPrice;
   datetime          seriesStartTime;
   datetime          seriesEndTime;
   int               seriesCount;
   double            seriesHigh;
   double            seriesLow;
   double            seriesOpen;
   datetime          extremeTime;   // manipulation extreme (SD anchor)
   double            extremePrice;
   double            level;         // confirmation level
   datetime          setupTime;     // bar that ended the series
   //--- confirmation (fixed once confirmed)
   datetime          confirmTime;
   double            confirmPrice;
   double            sdRange;       // |level - extreme|
   //--- life-cycle
   ENUM_CISD_STATE   state;
   int               barsInState;
   datetime          retraceTime;
   double            retracePrice;
   datetime          endTime;       // 0 = still active
  };

struct SCISDEvent
  {
   ENUM_CISD_EVENT   type;
   long              id;
   int               dir;
   datetime          time;
   double            price;
   bool              historical;
  };

struct SCISDStats
  {
   int               bars;
   int               swingHighs;
   int               swingLows;
   int               sweepsSellSide;
   int               sweepsBuySide;
   int               setupsBull;
   int               setupsBear;
   int               noSweep;
   int               seriesTooLong;
   int               setupFailed;
   int               setupReplaced;
   int               confirmedBull;
   int               confirmedBear;
   int               retraced;
   int               invalidated;
   int               expired;
  };

//+------------------------------------------------------------------+
ENUM_TIMEFRAMES SMC_CISDTimeframe(const ENUM_CISD_TF tf)
  {
   switch(tf)
     {
      case CISD_TF_M1:  return PERIOD_M1;
      case CISD_TF_M5:  return PERIOD_M5;
      case CISD_TF_M15: return PERIOD_M15;
      case CISD_TF_M30: return PERIOD_M30;
      case CISD_TF_H1:  return PERIOD_H1;
      case CISD_TF_H4:  return PERIOD_H4;
      case CISD_TF_D1:  return PERIOD_D1;
      default:          return (ENUM_TIMEFRAMES)_Period;
     }
  }

string SMC_TFText(const ENUM_TIMEFRAMES tf)
  {
   string s = EnumToString(tf);
   return StringSubstr(s, 7);          // "PERIOD_M5" -> "M5"
  }

string SMC_CISDStateText(const ENUM_CISD_STATE s)
  {
   switch(s)
     {
      case CISD_ST_SETUP:          return "SETUP (waiting close)";
      case CISD_ST_SETUP_FAILED:   return "SETUP FAILED";
      case CISD_ST_SETUP_REPLACED: return "SETUP REPLACED";
      case CISD_ST_CONFIRMED:      return "CONFIRMED (waiting retracement)";
      case CISD_ST_RETRACED:       return "RETRACED";
      case CISD_ST_INVALIDATED:    return "INVALIDATED";
      case CISD_ST_EXPIRED:        return "EXPIRED";
     }
   return "?";
  }

string SMC_CISDMachineText(const ENUM_CISD_MACHINE m, const int dir)
  {
   bool bull = (dir == SMC_DIR_BULL);
   switch(m)
     {
      case CISD_M_LIQUIDITY_SWEEP: return bull ? "LIQUIDITY_SWEEP_LOW" : "LIQUIDITY_SWEEP_HIGH";
      case CISD_M_WAIT_FOR_CLOSE:  return bull ? "WAIT_FOR_BULLISH_CLOSE" : "WAIT_FOR_BEARISH_CLOSE";
      default:                     return "WAITING";
     }
  }

bool SMC_CISDConfirmedState(const ENUM_CISD_STATE s)
  {
   return s == CISD_ST_CONFIRMED || s == CISD_ST_RETRACED || s == CISD_ST_INVALIDATED || s == CISD_ST_EXPIRED;
  }

//--- standard-deviation projection: 0 = CISD level, -1 = manipulation extreme,
//--- positive values project in the CISD direction (1.0, 1.5, 2.0, 2.5 ...)
double SMC_CISDDeviationPrice(const SCISD &c, const double k)
  {
   return c.level + c.dir * k * c.sdRange;
  }

//--- setup identity (fields that never change after creation)
bool SMC_CISDSameSetup(const SCISD &a, const SCISD &b)
  {
   return a.id == b.id && a.dir == b.dir && a.hasSweep == b.hasSweep && a.sweepTime == b.sweepTime &&
          a.sweptSwingTime == b.sweptSwingTime && a.seriesStartTime == b.seriesStartTime &&
          a.seriesEndTime == b.seriesEndTime && a.seriesCount == b.seriesCount && a.setupTime == b.setupTime &&
          a.extremeTime == b.extremeTime && MathAbs(a.level - b.level) < 1e-10 &&
          MathAbs(a.seriesHigh - b.seriesHigh) < 1e-10 && MathAbs(a.seriesLow - b.seriesLow) < 1e-10 &&
          MathAbs(a.extremePrice - b.extremePrice) < 1e-10 && MathAbs(a.sweepPrice - b.sweepPrice) < 1e-10;
  }

//+------------------------------------------------------------------+
class CSMCCISDEngine
  {
private:
   SCISDSettings     m_s;
   SSMCSettings      m_swingCfg;
   CSMCStructure     m_swingDetector;
   SCISDSwing        m_lows[];          // sell-side liquidity
   SCISDSwing        m_highs[];         // buy-side liquidity
   SCISDSweep        m_sweeps[];
   SSwing            m_swBuf[];        // per-bar scratch, kept allocated between bars
   SCISDSweep        m_lastSweep[2];    // [0] sell-side (bull), [1] buy-side (bear)
   bool              m_hasSweep[2];
   long              m_pendingId[2];
   SCISD             m_rec[];
   SCISDEvent        m_events[];
   SCISDStats        m_st;
   long              m_nextId;
   long              m_nextSweepId;
   long              m_barNo;
   datetime          m_last;
   datetime          m_first;
   int               m_lookback;
   bool              m_hist;

   int               Side(const int dir) const { return dir == SMC_DIR_BULL ? 0 : 1; }
   void              Log(const ENUM_SMC_LOG_LEVEL level, const string msg) const;
   //--- true when Log() would print: lets callers skip building the message string
   bool              Logs(const ENUM_SMC_LOG_LEVEL level) const
     { return m_s.logLevel >= level && !(m_hist && m_s.logLevel < SMC_LOG_VERBOSE); }
   void              Event(const ENUM_CISD_EVENT type, const long id, const int dir, const datetime t, const double p);
   void              AddSwing(SCISDSwing &arr[], const SSwing &sw);
   void              UpdateRecords(const MqlRates &bar);
   void              DetectSweep(const MqlRates &bar, const int dir);
   void              TryCreateSetup(const MqlRates &r[], const int i, const int size, const int dir);
   void              TryConfirm(const MqlRates &bar, const int dir);
   void              Prune(void);

public:
                     CSMCCISDEngine(void) : m_nextId(1), m_nextSweepId(1), m_barNo(0), m_last(0), m_first(0), m_lookback(0), m_hist(false) {}
   bool              Init(const SCISDSettings &s);
   void              Reset(void);
   int               RequiredLookback(void) const { return m_lookback; }
   bool              ProcessBar(const MqlRates &r[], const int i, const int size);
   int               ProcessWindow(const MqlRates &r[], const int size);
   void              SetHistoricalMode(const bool on) { m_hist = on; }
   datetime          LastProcessedTime(void) const { return m_last; }
   datetime          FirstBarTime(void) const { return m_first; }
   void              GetSettings(SCISDSettings &out) const { out = m_s; }

   int               Count(void) const { return ArraySize(m_rec); }
   bool              Get(const int idx, SCISD &out) const;
   int               FindById(const long id) const;
   int               SweepCount(void) const { return ArraySize(m_sweeps); }
   bool              GetSweep(const int idx, SCISDSweep &out) const;
   ENUM_CISD_MACHINE MachineState(const int dir) const;

   int               EventCount(void) const { return ArraySize(m_events); }
   bool              GetEvent(const int idx, SCISDEvent &e) const;
   void              ClearEvents(void) { ArrayResize(m_events, 0, 128); }
   void              GetStats(SCISDStats &st) const { st = m_st; }
   string            StatsText(void) const;
  };

//+------------------------------------------------------------------+
bool CSMCCISDEngine::Init(const SCISDSettings &s)
  {
   m_s = s;
   if(m_s.swingLength < 1 || m_s.atrPeriod < 1 || m_s.maxSeriesCandles < 1 || m_s.maxConfirmBars < 1 ||
      m_s.maxRetraceBars < 1 || m_s.sweepValidityBars < 0 || m_s.maxStored < 10)
      return false;
   ZeroMemory(m_swingCfg);
   m_swingCfg.swingLength = m_s.swingLength;
   m_swingCfg.swingMinATR = m_s.swingMinATR;
   m_swingCfg.atrPeriod   = m_s.atrPeriod;
   int R = m_s.swingLength, P = m_s.atrPeriod;
   m_lookback = (int)MathMax(MathMax(2 * R, R + P + 1), m_s.maxSeriesCandles + 2) + 3;
   Reset();
   return true;
  }

void CSMCCISDEngine::Reset(void)
  {
   m_swingDetector.Reset();
   ArrayResize(m_lows, 0);
   ArrayResize(m_highs, 0);
   ArrayResize(m_sweeps, 0);
   ArrayResize(m_rec, 0, 64);
   ArrayResize(m_events, 0, 128);
   ZeroMemory(m_lastSweep[0]);
   ZeroMemory(m_lastSweep[1]);
   m_hasSweep[0] = m_hasSweep[1] = false;
   m_pendingId[0] = m_pendingId[1] = 0;
   ZeroMemory(m_st);
   m_nextId = 1;
   m_nextSweepId = 1;
   m_barNo = 0;
   m_last = 0;
   m_first = 0;
  }

//+------------------------------------------------------------------+
void CSMCCISDEngine::Log(const ENUM_SMC_LOG_LEVEL level, const string msg) const
  {
   if(m_s.logLevel < level || (m_hist && m_s.logLevel < SMC_LOG_VERBOSE))
      return;
   PrintFormat("[SMC-CISD][%s]%s %s", SMC_TFText(m_s.timeframe), m_hist ? "[hist]" : "", msg);
  }

void CSMCCISDEngine::Event(const ENUM_CISD_EVENT type, const long id, const int dir, const datetime t, const double p)
  {
   int n = ArraySize(m_events);
   ArrayResize(m_events, n + 1, 128);
   m_events[n].type       = type;
   m_events[n].id         = id;
   m_events[n].dir        = dir;
   m_events[n].time       = t;
   m_events[n].price      = p;
   m_events[n].historical = m_hist;
  }

void CSMCCISDEngine::AddSwing(SCISDSwing &arr[], const SSwing &sw)
  {
   int n = ArraySize(arr);
   if(n >= 300)
     {
      for(int k = 1; k < n; k++)
         arr[k - 1] = arr[k];
      n--;
     }
   ArrayResize(arr, n + 1, 64);
   arr[n].time   = sw.time;
   arr[n].price  = sw.price;
   arr[n].barNo  = m_barNo;
   arr[n].swept  = false;
  }

//+------------------------------------------------------------------+
bool CSMCCISDEngine::ProcessBar(const MqlRates &r[], const int i, const int size)
  {
   if(i < 0 || i >= size)
      return false;
   datetime t = r[i].time;
   if(t <= m_last)
      return false;                        // each bar exactly once
   if(m_first == 0)
      m_first = r[size - 1].time;
   m_last = t;
   if(i + m_lookback >= size)
      return false;                        // warm-up
   m_barNo++;
   m_st.bars++;

   //--- 1. life-cycle of existing setups / CISDs (created before this bar)
   UpdateRecords(r[i]);

   //--- 2. liquidity: swings confirmed on this bar (reused swing definition).
   //--- m_swBuf is a member: the per-bar scratch array stays allocated between bars.
   int ns = m_swingDetector.ConfirmSwings(r, i, size, m_swingCfg, m_swBuf);
   for(int k = 0; k < ns; k++)
     {
      if(m_swBuf[k].type == SMC_DIR_BULL) { AddSwing(m_highs, m_swBuf[k]); m_st.swingHighs++; }
      else                                { AddSwing(m_lows, m_swBuf[k]);  m_st.swingLows++;  }
     }

   //--- 3-5. per direction: sweep -> series -> confirmation close
   for(int d = 0; d < 2; d++)
     {
      int dir = (d == 0) ? SMC_DIR_BULL : SMC_DIR_BEAR;
      if(m_s.dirFilter != 0 && dir != m_s.dirFilter)
         continue;
      if(m_s.useSweep)
         DetectSweep(r[i], dir);
      TryCreateSetup(r, i, size, dir);
      if(m_s.useConfirm)
         TryConfirm(r[i], dir);
     }
   Prune();
   return true;
  }

int CSMCCISDEngine::ProcessWindow(const MqlRates &r[], const int size)
  {
   int n = 0;
   for(int i = size - 1; i >= 0; i--)
      if(ProcessBar(r, i, size))
         n++;
   return n;
  }

//+------------------------------------------------------------------+
void CSMCCISDEngine::UpdateRecords(const MqlRates &bar)
  {
   datetime t = bar.time;
   for(int k = 0; k < ArraySize(m_rec); k++)
     {
      int dir = m_rec[k].dir;
      if(m_rec[k].state == CISD_ST_SETUP)
        {
         if(m_rec[k].setupTime >= t)
            continue;
         m_rec[k].barsInState++;
         bool deeper = (dir == SMC_DIR_BULL) ? bar.low < m_rec[k].extremePrice : bar.high > m_rec[k].extremePrice;
         if(deeper || m_rec[k].barsInState > m_s.maxConfirmBars)
           {
            m_rec[k].state = CISD_ST_SETUP_FAILED;
            m_rec[k].endTime = t;
            m_st.setupFailed++;
            if(m_pendingId[Side(dir)] == m_rec[k].id)
               m_pendingId[Side(dir)] = 0;
            Event(CISD_EVT_SETUP_FAILED, m_rec[k].id, dir, t, deeper ? (dir == SMC_DIR_BULL ? bar.low : bar.high) : bar.close);
            if(Logs(SMC_LOG_VERBOSE)) Log(SMC_LOG_VERBOSE, StringFormat("%s CISD setup #%I64d failed (%s)", SMC_DirText(dir), m_rec[k].id,
                                              deeper ? "deeper extreme" : "no confirmation in time"));
           }
         continue;
        }

      if(m_rec[k].state != CISD_ST_CONFIRMED || m_rec[k].endTime != 0 || m_rec[k].confirmTime >= t)
         continue;
      m_rec[k].barsInState++;

      //--- invalidation: close beyond the manipulation extreme
      if(dir * (bar.close - m_rec[k].extremePrice) < 0)
        {
         m_rec[k].state = CISD_ST_INVALIDATED;
         m_rec[k].endTime = t;
         m_st.invalidated++;
         Event(CISD_EVT_INVALIDATED, m_rec[k].id, dir, t, bar.close);
         if(Logs(SMC_LOG_EVENTS)) Log(SMC_LOG_EVENTS, StringFormat("%s CISD #%I64d invalidated @ %s", SMC_DirText(dir), m_rec[k].id, TimeToString(t)));
         continue;
        }

      if(m_s.useRetrace)
        {
         bool touch = (dir == SMC_DIR_BULL) ? bar.low <= m_rec[k].level : bar.high >= m_rec[k].level;
         if(touch)
           {
            m_rec[k].state = CISD_ST_RETRACED;
            m_rec[k].retraceTime = t;
            m_rec[k].retracePrice = (dir == SMC_DIR_BULL) ? MathMax(bar.low, m_rec[k].seriesLow)
                                                          : MathMin(bar.high, m_rec[k].seriesHigh);
            m_rec[k].endTime = t;
            m_st.retraced++;
            Event(CISD_EVT_RETRACED, m_rec[k].id, dir, t, m_rec[k].retracePrice);
            if(Logs(SMC_LOG_EVENTS)) Log(SMC_LOG_EVENTS, StringFormat("%s CISD #%I64d retracement / entry @ %s (%s)", SMC_DirText(dir), m_rec[k].id,
                                             TimeToString(t), DoubleToString(m_rec[k].retracePrice, _Digits)));
            continue;
           }
        }
      if(m_rec[k].barsInState >= m_s.maxRetraceBars)
        {
         if(m_s.useRetrace)
           {
            m_rec[k].state = CISD_ST_EXPIRED;
            m_st.expired++;
            Event(CISD_EVT_EXPIRED, m_rec[k].id, dir, t, bar.close);
           }
         m_rec[k].endTime = t;             // stop monitoring
        }
     }
  }

//+------------------------------------------------------------------+
//| Liquidity sweep: bullish CISD <- sell-side (swing lows) taken.   |
//+------------------------------------------------------------------+
void CSMCCISDEngine::DetectSweep(const MqlRates &bar, const int dir)
  {
   bool bull = (dir == SMC_DIR_BULL);
   int best = -1;
   datetime bestTime = 0;
   double bestPrice = 0.0;
   int n = bull ? ArraySize(m_lows) : ArraySize(m_highs);
   for(int k = 0; k < n; k++)
     {
      datetime swTime;
      double swPrice;
      bool swSwept;
      long swBar;
      if(bull) { swTime = m_lows[k].time;  swPrice = m_lows[k].price;  swSwept = m_lows[k].swept;  swBar = m_lows[k].barNo;  }
      else     { swTime = m_highs[k].time; swPrice = m_highs[k].price; swSwept = m_highs[k].swept; swBar = m_highs[k].barNo; }
      if(swSwept || swTime >= bar.time)
         continue;
      if(m_s.swingMaxAge > 0 && m_barNo - swBar > m_s.swingMaxAge)
         continue;
      bool through = bull ? bar.low < swPrice : bar.high > swPrice;
      if(!through)
         continue;
      if(bull) m_lows[k].swept = true;           // liquidity is consumed once taken
      else     m_highs[k].swept = true;
      if(m_s.sweepMode == CISD_SWEEP_REJECTION && !(bull ? bar.close > swPrice : bar.close < swPrice))
         continue;
      if(best < 0 || (bull ? swPrice < bestPrice : swPrice > bestPrice))
        {
         best = k;                               // deepest liquidity taken
         bestTime = swTime;
         bestPrice = swPrice;
        }
     }
   if(best < 0)
      return;
   if(m_s.activationMode == CISD_ACT_ALL_AFTER && bar.time < m_s.activationTime)
      return;                                    // liquidity consumed, but no sweep before activation

   SCISDSweep s;
   ZeroMemory(s);
   s.id         = m_nextSweepId++;
   s.dir        = dir;
   s.time       = bar.time;
   s.price      = bull ? bar.low : bar.high;
   s.swingTime  = bestTime;
   s.swingPrice = bestPrice;
   s.barNo      = m_barNo;
   s.used       = false;

   int m = ArraySize(m_sweeps);
   if(m >= 500)
     {
      for(int k = 1; k < m; k++)
         m_sweeps[k - 1] = m_sweeps[k];
      m--;
     }
   ArrayResize(m_sweeps, m + 1, 64);
   m_sweeps[m] = s;
   m_lastSweep[Side(dir)] = s;
   m_hasSweep[Side(dir)] = true;
   if(bull) m_st.sweepsSellSide++;
   else     m_st.sweepsBuySide++;
   Event(CISD_EVT_SWEEP, s.id, dir, s.time, s.price);
   if(Logs(SMC_LOG_VERBOSE)) Log(SMC_LOG_VERBOSE, StringFormat("%s liquidity sweep @ %s: %s took swing %s",
                                     bull ? "Sell-side" : "Buy-side", TimeToString(s.time),
                                     DoubleToString(s.price, _Digits), DoubleToString(s.swingPrice, _Digits)));
  }

//+------------------------------------------------------------------+
//| A setup is evaluated once, on the bar that ends an opposite run. |
//+------------------------------------------------------------------+
void CSMCCISDEngine::TryCreateSetup(const MqlRates &r[], const int i, const int size, const int dir)
  {
   //--- the run must have ended exactly on bar i (series candles are opposite-coloured)
   if(SMC_IsDirCandle(r[i], -dir) || i + 1 >= size || !SMC_IsDirCandle(r[i + 1], -dir))
      return;

   int newest = i + 1, oldest = newest;
   int deepest = i + m_lookback;                 // deepest bar present in every data window
   while(oldest + 1 <= deepest && SMC_IsDirCandle(r[oldest + 1], -dir))
     {
      oldest++;
      if(oldest - newest + 1 > m_s.maxSeriesCandles)
         break;
     }
   if(oldest - newest + 1 > m_s.maxSeriesCandles || oldest + 1 > deepest)
     {
      m_st.seriesTooLong++;                      // never truncate a series
      return;
     }
   if(m_s.activationMode == CISD_ACT_ALL_AFTER && r[oldest].time < m_s.activationTime)
      return;                                    // series began before activation (e.g. before HTF OB retest)

   bool bull = (dir == SMC_DIR_BULL);
   double hi = r[oldest].high, lo = r[oldest].low;
   double ext = bull ? r[oldest].low : r[oldest].high;
   datetime extT = r[oldest].time;
   for(int k = oldest; k >= i; k--)              // oldest -> bar i, earliest extreme wins ties
     {
      if(k >= newest)
        {
         hi = MathMax(hi, r[k].high);
         lo = MathMin(lo, r[k].low);
        }
      double e = bull ? r[k].low : r[k].high;
      if(bull ? e < ext : e > ext)
        {
         ext = e;
         extT = r[k].time;
        }
     }

   //--- liquidity sweep requirement
   SCISDSweep sw;
   ZeroMemory(sw);
   bool hasSweep = false;
   if(m_s.useSweep)
     {
      int sd = Side(dir);
      if(m_hasSweep[sd] && !m_lastSweep[sd].used)
        {
         sw = m_lastSweep[sd];
         bool inside = (sw.time >= r[oldest].time && sw.time <= r[i].time);
         bool after  = (sw.time < r[oldest].time && m_barNo - sw.barNo <= m_s.sweepValidityBars &&
                        (bull ? ext < sw.swingPrice : ext > sw.swingPrice));
         hasSweep = inside || after;
        }
      if(!hasSweep)
        {
         m_st.noSweep++;
         return;
        }
     }

   SCISD c;
   ZeroMemory(c);
   c.id              = m_nextId++;
   c.dir             = dir;
   c.timeframe       = m_s.timeframe;
   c.hasSweep        = hasSweep;
   if(hasSweep)
     {
      c.sweepId         = sw.id;
      c.sweepTime       = sw.time;
      c.sweepPrice      = sw.price;
      c.sweptSwingTime  = sw.swingTime;
      c.sweptSwingPrice = sw.swingPrice;
     }
   c.seriesStartTime = r[oldest].time;
   c.seriesEndTime   = r[newest].time;
   c.seriesCount     = oldest - newest + 1;
   c.seriesHigh      = hi;
   c.seriesLow       = lo;
   c.seriesOpen      = r[oldest].open;
   c.extremeTime     = extT;
   c.extremePrice    = ext;
   c.level           = (m_s.levelMode == CISD_LEVEL_SERIES_OPEN) ? c.seriesOpen : (bull ? hi : lo);
   c.setupTime       = r[i].time;
   c.state           = CISD_ST_SETUP;

   //--- one waiting setup per direction: the newer series takes over
   int sd = Side(dir);
   if(m_pendingId[sd] > 0)
     {
      int old = FindById(m_pendingId[sd]);
      if(old >= 0 && m_rec[old].state == CISD_ST_SETUP)
        {
         m_rec[old].state = CISD_ST_SETUP_REPLACED;
         m_rec[old].endTime = r[i].time;
         m_st.setupReplaced++;
        }
     }

   int n = ArraySize(m_rec);
   ArrayResize(m_rec, n + 1, 64);
   m_rec[n] = c;
   m_pendingId[sd] = c.id;
   if(bull) m_st.setupsBull++;
   else     m_st.setupsBear++;
   Event(CISD_EVT_SETUP, c.id, dir, c.setupTime, c.level);
   if(Logs(SMC_LOG_VERBOSE)) Log(SMC_LOG_VERBOSE, StringFormat("%s CISD setup #%I64d: %d-candle series %s..%s, level %s%s", SMC_DirText(dir), c.id,
                                     c.seriesCount, TimeToString(c.seriesStartTime), TimeToString(c.seriesEndTime),
                                     DoubleToString(c.level, _Digits), hasSweep ? ", after liquidity sweep" : ""));
  }

//+------------------------------------------------------------------+
void CSMCCISDEngine::TryConfirm(const MqlRates &bar, const int dir)
  {
   int sd = Side(dir);
   if(m_pendingId[sd] <= 0)
      return;
   int k = FindById(m_pendingId[sd]);
   if(k < 0 || m_rec[k].state != CISD_ST_SETUP)
     {
      m_pendingId[sd] = 0;
      return;
     }
   if(dir * (bar.close - m_rec[k].level) <= 0)
      return;                                    // close must be strictly beyond the level

   //--- CONFIRM_AFTER: the series may predate activation, but a close that already changed delivery
   //--- before it consumes the setup - an old CISD is never reused for a later association
   if(m_s.activationMode == CISD_ACT_CONFIRM_AFTER && bar.time < m_s.activationTime)
     {
      m_rec[k].state = CISD_ST_SETUP_FAILED;
      m_rec[k].endTime = bar.time;
      m_st.setupFailed++;
      m_pendingId[sd] = 0;
      if(Logs(SMC_LOG_VERBOSE)) Log(SMC_LOG_VERBOSE, StringFormat("%s setup #%I64d consumed before activation @ %s", SMC_DirText(dir),
                                        m_rec[k].id, TimeToString(bar.time)));
      return;
     }

   m_rec[k].state        = CISD_ST_CONFIRMED;
   m_rec[k].confirmTime  = bar.time;
   m_rec[k].confirmPrice = bar.close;
   m_rec[k].sdRange      = MathAbs(m_rec[k].level - m_rec[k].extremePrice);
   m_rec[k].barsInState  = 0;
   m_rec[k].endTime      = 0;
   m_pendingId[sd] = 0;
   if(m_rec[k].hasSweep && m_lastSweep[sd].id == m_rec[k].sweepId)
      m_lastSweep[sd].used = true;               // one CISD per sweep
   for(int s = ArraySize(m_sweeps) - 1; s >= 0; s--)
      if(m_sweeps[s].id == m_rec[k].sweepId) { m_sweeps[s].used = true; break; }

   if(dir == SMC_DIR_BULL) m_st.confirmedBull++;
   else                    m_st.confirmedBear++;
   Event(CISD_EVT_CONFIRMED, m_rec[k].id, dir, bar.time, bar.close);
   if(Logs(SMC_LOG_EVENTS)) Log(SMC_LOG_EVENTS, StringFormat("%s CISD #%I64d CONFIRMED @ %s: close %s beyond %s (series %d candles%s)",
                                    SMC_DirText(dir), m_rec[k].id, TimeToString(bar.time),
                                    DoubleToString(bar.close, _Digits), DoubleToString(m_rec[k].level, _Digits),
                                    m_rec[k].seriesCount, m_rec[k].hasSweep ? ", after liquidity sweep" : ""));
  }

//+------------------------------------------------------------------+
void CSMCCISDEngine::Prune(void)
  {
   while(ArraySize(m_rec) > m_s.maxStored)
     {
      int victim = -1;
      for(int k = 0; k < ArraySize(m_rec); k++)
         if(m_rec[k].state != CISD_ST_SETUP && !(m_rec[k].state == CISD_ST_CONFIRMED && m_rec[k].endTime == 0))
           { victim = k; break; }
      if(victim < 0)
         return;
      int n = ArraySize(m_rec);
      for(int k = victim + 1; k < n; k++)
         m_rec[k - 1] = m_rec[k];
      ArrayResize(m_rec, n - 1, 64);
     }
  }

//+------------------------------------------------------------------+
bool CSMCCISDEngine::Get(const int idx, SCISD &out) const
  {
   if(idx < 0 || idx >= ArraySize(m_rec))
      return false;
   out = m_rec[idx];
   return true;
  }

int CSMCCISDEngine::FindById(const long id) const
  {
   for(int k = ArraySize(m_rec) - 1; k >= 0; k--)
      if(m_rec[k].id == id)
         return k;
   return -1;
  }

bool CSMCCISDEngine::GetSweep(const int idx, SCISDSweep &out) const
  {
   if(idx < 0 || idx >= ArraySize(m_sweeps))
      return false;
   out = m_sweeps[idx];
   return true;
  }

bool CSMCCISDEngine::GetEvent(const int idx, SCISDEvent &e) const
  {
   if(idx < 0 || idx >= ArraySize(m_events))
      return false;
   e = m_events[idx];
   return true;
  }

ENUM_CISD_MACHINE CSMCCISDEngine::MachineState(const int dir) const
  {
   int sd = Side(dir);
   if(m_pendingId[sd] > 0)
      return CISD_M_WAIT_FOR_CLOSE;
   if(m_s.useSweep && m_hasSweep[sd] && !m_lastSweep[sd].used &&
      m_barNo - m_lastSweep[sd].barNo <= m_s.sweepValidityBars)
      return CISD_M_LIQUIDITY_SWEEP;
   return CISD_M_WAITING;
  }

string CSMCCISDEngine::StatsText(void) const
  {
   return StringFormat("bars=%d | swings H/L=%d/%d | sweeps sell/buy=%d/%d | setups bull/bear=%d/%d (noSweep %d, seriesTooLong %d, failed %d, replaced %d) | "
                       "CISD bull/bear=%d/%d | retraced=%d invalidated=%d expired=%d | stored=%d | machine bull=%s bear=%s",
                       m_st.bars, m_st.swingHighs, m_st.swingLows, m_st.sweepsSellSide, m_st.sweepsBuySide,
                       m_st.setupsBull, m_st.setupsBear, m_st.noSweep, m_st.seriesTooLong, m_st.setupFailed,
                       m_st.setupReplaced, m_st.confirmedBull, m_st.confirmedBear, m_st.retraced, m_st.invalidated,
                       m_st.expired, ArraySize(m_rec),
                       SMC_CISDMachineText(MachineState(SMC_DIR_BULL), SMC_DIR_BULL),
                       SMC_CISDMachineText(MachineState(SMC_DIR_BEAR), SMC_DIR_BEAR));
  }

#endif // SMC_CISD_ENGINE_MQH
