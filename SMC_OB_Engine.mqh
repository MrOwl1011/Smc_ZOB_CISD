//+------------------------------------------------------------------+
//|                                                SMC_OB_Engine.mqh |
//|  SPDX-License-Identifier: MIT                                    |
//|  https://github.com/MrOwl1011/Smc_ZOB_CISD                       |
//|  Order Block Engine + Retest/Mitigation Engine + orchestrator.   |
//|                                                                  |
//|  Pipeline per CLOSED bar i (ProcessBar):                         |
//|   1. Resolve FVGs completed by bar i (late confluence link, or   |
//|      confirmation of OBs waiting for a required FVG).            |
//|   2. Update life-cycle of OBs confirmed BEFORE bar i.            |
//|   3. Confirm swing at candle i+R.                                |
//|   4. Detect BOS on bar i.                                        |
//|   5. For each BOS: displacement -> last opposite candle -> OB.   |
//|                                                                  |
//|  Each bar is processed exactly once (guarded by bar time), and   |
//|  only bars r[i..] are ever read, so batch history scan and live  |
//|  bar-by-bar processing produce identical results.                |
//+------------------------------------------------------------------+
#ifndef SMC_OB_ENGINE_MQH
#define SMC_OB_ENGINE_MQH

#include "SMC_OB_Structure.mqh"
#include "SMC_OB_Displacement.mqh"
#include "SMC_OB_FVG.mqh"

//+------------------------------------------------------------------+
//| Identity comparison used by the non-repaint self tests.          |
//+------------------------------------------------------------------+
bool SMC_SameIdentity(const SOrderBlock &a, const SOrderBlock &b, const bool compareFVG)
  {
   if(a.id != b.id || a.dir != b.dir || a.obTime != b.obTime || a.confirmTime != b.confirmTime ||
      a.bosTime != b.bosTime || a.swingTime != b.swingTime || a.legBars != b.legBars ||
      a.isZOrder != b.isZOrder || a.seriesCount != b.seriesCount || a.seriesStartTime != b.seriesStartTime)
      return false;
   if(MathAbs(a.top - b.top) > 1e-10 || MathAbs(a.bottom - b.bottom) > 1e-10 ||
      MathAbs(a.bosLevel - b.bosLevel) > 1e-10)
      return false;
   if(compareFVG)
     {
      if(a.hasFVG != b.hasFVG)
         return false;
      if(a.hasFVG && (a.fvgLeftTime != b.fvgLeftTime || MathAbs(a.fvgTop - b.fvgTop) > 1e-10 ||
                      MathAbs(a.fvgBottom - b.fvgBottom) > 1e-10))
         return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
class CSMCDetector
  {
private:
   SSMCSettings      m_s;
   CSMCStructure     m_structure;
   CSMCDisplacement  m_disp;
   CSMCFVG           m_fvg;

   SOrderBlock       m_obs[];
   SOrderBlock       m_pending[];      // FVG-required candidates (NOT confirmed OBs)
   SSMCEvent         m_events[];
   SSMCStats         m_stats;

   SSwing            m_swingBuf[];    // per-bar scratch, kept allocated between bars
   SBOS              m_bosBuf[];
   long              m_nextId;
   datetime          m_lastProcessed;
   int               m_lookback;
   bool              m_historical;
   string            m_tag;            // log tag: "" standard, "[ZOrder]" series detector

   void              Log(const ENUM_SMC_LOG_LEVEL level, const string msg) const;
   //--- true when Log() would print: lets callers skip building the message string
   bool              Logs(const ENUM_SMC_LOG_LEVEL level) const
     { return m_s.logLevel >= level && !(m_historical && m_s.logLevel < SMC_LOG_VERBOSE); }
   void              PushEvent(const ENUM_SMC_EVENT type, const long obId, const int dir,
                               const datetime t, const double p,
                               const datetime t2 = 0, const double p2 = 0.0, const bool flag = false);
   void              Reject(const ENUM_SMC_REJECT code, const SBOS &bos);
   void              LinkFVG(SOrderBlock &o, const SFVG &f, const bool late);
   long              TryCreateOB(const MqlRates &r[], const int i, const int size, const SBOS &bos);
   long              Commit(SOrderBlock &o, const datetime confirmTime);
   void              EnforceMaxActive(const int dir, const datetime t);
   void              Prune(void);
   void              ResolvePendingFVG(const MqlRates &r[], const int i, const int size);
   void              UpdateLifecycle(const MqlRates &bar);
   void              UpdateOne(const int k, const MqlRates &bar);
   bool              HasPending(const int dir, const datetime obTime) const;

public:
                     CSMCDetector(void);
   bool              Init(const SSMCSettings &s);
   void              Reset(void);

   //--- processing
   int               RequiredLookback(void) const { return m_lookback; }
   bool              ProcessBar(const MqlRates &r[], const int i, const int size);
   int               ProcessWindow(const MqlRates &r[], const int size);
   bool              OnTickPrice(const double price);
   void              SetHistoricalMode(const bool on) { m_historical = on; }
   datetime          LastProcessedTime(void) const { return m_lastProcessed; }

   //--- queries (read-only API for visualization / future trading)
   void              GetSettings(SSMCSettings &out) const { out = m_s; }
   int               OBCount(void) const { return ArraySize(m_obs); }
   bool              GetOB(const int idx, SOrderBlock &out) const;
   //--- single-field reads for hot loops that would otherwise copy the whole record
   long              OBIdAt(const int idx) const
     { return (idx >= 0 && idx < ArraySize(m_obs)) ? m_obs[idx].id : 0; }
   ENUM_SMC_OB_STATE OBStateAt(const int idx) const
     { return (idx >= 0 && idx < ArraySize(m_obs)) ? m_obs[idx].state : SMC_OB_EXPIRED; }
   int               LiveCount(const int dir) const;
   int               FindById(const long id) const;
   bool              HasOB(const int dir, const datetime obTime) const;
   int               GetLiveOBs(const int dir, SOrderBlock &out[]) const;
   int               PendingCount(void) const { return ArraySize(m_pending); }

   int               EventCount(void) const { return ArraySize(m_events); }
   bool              GetEvent(const int idx, SSMCEvent &e) const;
   void              ClearEvents(void) { ArrayResize(m_events, 0, 256); }

   void              GetStats(SSMCStats &st) const { st = m_stats; }
   string            StatsText(void) const;
  };

//+------------------------------------------------------------------+
CSMCDetector::CSMCDetector(void) : m_nextId(1), m_lastProcessed(0), m_lookback(0), m_historical(false)
  {
   ZeroMemory(m_s);
   ZeroMemory(m_stats);
  }

//+------------------------------------------------------------------+
bool CSMCDetector::Init(const SSMCSettings &s)
  {
   m_s = s;
   m_tag = (m_s.zoneSource == SMC_SOURCE_CANDLE_SERIES) ? "[ZOrder]" : "";
   if(m_s.swingLength < 1 || m_s.atrPeriod < 1 || m_s.maxOBToBOSBars < 1 ||
      m_s.maxActivePerDir < 1 || m_s.maxStored < m_s.maxActivePerDir * 2)
      return false;
   int R = m_s.swingLength, P = m_s.atrPeriod;
   //--- deepest read: swing left side (i+2R), swing ATR (i+R+P), OB ATR (i+maxDist+P), late FVG (i+2)
   m_lookback = (int)MathMax(MathMax(2 * R, R + P + 1), m_s.maxOBToBOSBars + P + 1) + 3;
   Reset();
   return true;
  }

//+------------------------------------------------------------------+
void CSMCDetector::Reset(void)
  {
   m_structure.Reset();
   ArrayResize(m_obs, 0, 64);
   ArrayResize(m_pending, 0);
   ArrayResize(m_events, 0, 256);
   ZeroMemory(m_stats);
   m_nextId = 1;
   m_lastProcessed = 0;
  }

//+------------------------------------------------------------------+
void CSMCDetector::Log(const ENUM_SMC_LOG_LEVEL level, const string msg) const
  {
   if(m_s.logLevel < level)
      return;
   //--- during the history scan only verbose mode prints per-item messages
   if(m_historical && m_s.logLevel < SMC_LOG_VERBOSE)
      return;
   PrintFormat("[SMC-OB]%s%s %s", m_tag, m_historical ? "[hist]" : "", msg);
  }

//+------------------------------------------------------------------+
void CSMCDetector::PushEvent(const ENUM_SMC_EVENT type, const long obId, const int dir,
                             const datetime t, const double p,
                             const datetime t2, const double p2, const bool flag)
  {
   int n = ArraySize(m_events);
   ArrayResize(m_events, n + 1, 256);
   m_events[n].type       = type;
   m_events[n].obId       = obId;
   m_events[n].dir        = dir;
   m_events[n].time       = t;
   m_events[n].price      = p;
   m_events[n].time2      = t2;
   m_events[n].price2     = p2;
   m_events[n].flag       = flag;
   m_events[n].historical = m_historical;
  }

//+------------------------------------------------------------------+
void CSMCDetector::Reject(const ENUM_SMC_REJECT code, const SBOS &bos)
  {
   switch(code)
     {
      case SMC_REJ_DIRECTION_DISABLED:  m_stats.rejDisabled++;     break;
      case SMC_REJ_INSUFFICIENT_DATA:   m_stats.rejData++;         break;
      case SMC_REJ_BOS_CANDLE_OPPOSITE: m_stats.rejBosOpposite++;  break;
      case SMC_REJ_NO_OPPOSITE_CANDLE:  m_stats.rejNoOpposite++;   break;
      case SMC_REJ_WEAK_MOVE:           m_stats.rejWeakMove++;     break;
      case SMC_REJ_WEAK_CANDLE:         m_stats.rejWeakCandle++;   break;
      case SMC_REJ_SMALL_BODY:          m_stats.rejSmallBody++;    break;
      case SMC_REJ_WEAK_RELATIVE:       m_stats.rejWeakRelative++; break;
      case SMC_REJ_LEG_VIOLATES_OB:     m_stats.rejLegViolation++; break;
      case SMC_REJ_ZERO_ZONE:           m_stats.rejZeroZone++;     break;
      case SMC_REJ_FVG_MISSING:         m_stats.rejFVGMissing++;   break;
      case SMC_REJ_OVERLAP:             m_stats.rejOverlap++;      break;
      case SMC_REJ_DUPLICATE:           m_stats.duplicates++;      break;
      case SMC_REJ_SERIES_TOO_LONG:     m_stats.rejSeriesTooLong++; break;
      default: break;
     }
   if(Logs(SMC_LOG_VERBOSE)) Log(SMC_LOG_VERBOSE, StringFormat("%s BOS @ %s (level %s) -> no OB: %s",
                                     SMC_DirText(bos.dir), TimeToString(bos.barTime),
                                     DoubleToString(bos.level, _Digits), SMC_RejectText(code)));
  }

//+------------------------------------------------------------------+
void CSMCDetector::LinkFVG(SOrderBlock &o, const SFVG &f, const bool late)
  {
   o.hasFVG       = true;
   o.fvgLate      = late;
   o.fvgPending   = false;
   o.fvgLeftTime  = f.leftTime;
   o.fvgRightTime = f.rightTime;
   o.fvgTop       = f.top;
   o.fvgBottom    = f.bottom;
  }

//+------------------------------------------------------------------+
bool CSMCDetector::ProcessBar(const MqlRates &r[], const int i, const int size)
  {
   if(i < 0 || i >= size)
      return false;
   datetime t = r[i].time;
   if(t <= m_lastProcessed)
      return false;                              // each bar processed exactly once
   m_lastProcessed = t;
   if(i + m_lookback >= size)
      return false;                              // warm-up: not enough history behind bar i

   m_stats.barsProcessed++;

   //--- 1-2. existing zones
   ResolvePendingFVG(r, i, size);
   UpdateLifecycle(r[i]);

   //--- 3. swings (m_swingBuf / m_bosBuf are members: the per-bar scratch stays allocated)
   int ns = m_structure.ConfirmSwings(r, i, size, m_s, m_swingBuf);
   for(int k = 0; k < ns; k++)
     {
      if(m_swingBuf[k].type == SMC_DIR_BULL) m_stats.swingHighs++;
      else                                   m_stats.swingLows++;
      PushEvent(SMC_EVT_SWING, 0, m_swingBuf[k].type, m_swingBuf[k].time, m_swingBuf[k].price, m_swingBuf[k].confirmTime);
     }

   //--- 4-5. structure breaks and order blocks
   int nb = m_structure.DetectBOS(r, i, size, m_s, m_bosBuf);
   for(int k = 0; k < nb; k++)
     {
      if(m_bosBuf[k].dir == SMC_DIR_BULL) m_stats.bosBull++;
      else                                m_stats.bosBear++;
      if(m_bosBuf[k].isChoch)             m_stats.choch++;

      long id = TryCreateOB(r, i, size, m_bosBuf[k]);
      PushEvent(SMC_EVT_BOS, id, m_bosBuf[k].dir, m_bosBuf[k].swingTime, m_bosBuf[k].level,
                m_bosBuf[k].barTime, m_bosBuf[k].closePrice, m_bosBuf[k].isChoch);
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Process a series-ordered window oldest -> newest.                 |
//+------------------------------------------------------------------+
int CSMCDetector::ProcessWindow(const MqlRates &r[], const int size)
  {
   int n = 0;
   for(int i = size - 1; i >= 0; i--)
      if(ProcessBar(r, i, size))
         n++;
   return n;
  }

//+------------------------------------------------------------------+
long CSMCDetector::TryCreateOB(const MqlRates &r[], const int i, const int size, const SBOS &bos)
  {
   int dir = bos.dir;
   if((dir == SMC_DIR_BULL && !m_s.enableBull) || (dir == SMC_DIR_BEAR && !m_s.enableBear))
     {
      Reject(SMC_REJ_DIRECTION_DISABLED, bos);
      return 0;
     }

   SDisplacement d;
   if(!m_disp.Evaluate(r, i, size, dir, m_s, d))
     {
      Reject(d.reject, bos);
      return 0;
     }

   int ob = d.obIndex;
   if(HasOB(dir, r[ob].time) || HasPending(dir, r[ob].time))
     {
      Reject(SMC_REJ_DUPLICATE, bos);
      return 0;
     }

   //--- ZOrder: extend back from the last opposite candle over the complete CONTIGUOUS
   //--- series of opposite-colour candles (stops at the first candle that is not opposite).
   //--- Reads stop at i + lookback, the deepest bar present in every data window, so the
   //--- history scan and live bar-by-bar processing always see the same series.
   bool series = (m_s.zoneSource == SMC_SOURCE_CANDLE_SERIES);
   int oldest = ob;
   if(series)
     {
      int deepest = i + m_lookback;
      while(oldest + 1 <= deepest && SMC_IsDirCandle(r[oldest + 1], -dir))
         oldest++;
      if(oldest + 1 > deepest)
        {
         Reject(SMC_REJ_SERIES_TOO_LONG, bos);   // start of the series not visible: never truncate
         return 0;
        }
     }

   SOrderBlock o;
   ZeroMemory(o);
   o.dir         = dir;
   o.obTime      = r[ob].time;
   o.candleOpen  = r[ob].open;
   o.candleHigh  = r[ob].high;
   o.candleLow   = r[ob].low;
   o.candleClose = r[ob].close;
   o.bosTime     = bos.barTime;
   o.bosLevel    = bos.level;
   o.swingTime   = bos.swingTime;
   o.isChoch     = bos.isChoch;
   o.legBars     = d.legBars;
   o.atr         = d.atr;
   o.netMove     = d.netMove;
   o.strongestBodyPct = d.strongestBodyPct;
   o.relStrength = d.relStrength;

   if(series)
     {
      o.isZOrder        = true;
      o.seriesCount     = oldest - ob + 1;
      o.seriesStartTime = r[oldest].time;
      if(m_s.zoneMode == SMC_ZONE_OPEN_LAST_EXTREME)
        {
         //--- first (oldest) candle Open to the extreme of the last (newest) candle:
         //--- bull = first candle Open .. last candle Low, bear = first candle Open .. last candle High
         double ext = (dir == SMC_DIR_BULL) ? r[ob].low : r[ob].high;
         o.top    = MathMax(r[oldest].open, ext);
         o.bottom = MathMin(r[oldest].open, ext);
        }
      else
        {
         //--- ZOrder zone: highest High to lowest Low of the whole series
         o.top    = r[ob].high;
         o.bottom = r[ob].low;
         for(int k = ob + 1; k <= oldest; k++)
           {
            o.top    = MathMax(o.top, r[k].high);
            o.bottom = MathMin(o.bottom, r[k].low);
           }
        }
     }
   else switch(m_s.zoneMode)
     {
      case SMC_ZONE_BODY:
         o.top    = MathMax(r[ob].open, r[ob].close);
         o.bottom = MathMin(r[ob].open, r[ob].close);
         break;
      case SMC_ZONE_OPEN_TO_EXTREME:
         if(dir == SMC_DIR_BULL) { o.top = r[ob].open; o.bottom = r[ob].low;  }   // bearish candle
         else                    { o.top = r[ob].high; o.bottom = r[ob].open; }   // bullish candle
         break;
      case SMC_ZONE_OPEN_LAST_EXTREME:
         //--- single candle: it is both the first and the last candle (bull Low - Open, bear Open - High)
         if(dir == SMC_DIR_BULL) { o.top = r[ob].open; o.bottom = r[ob].low;  }   // bearish candle
         else                    { o.top = r[ob].high; o.bottom = r[ob].open; }   // bullish candle
         break;
      default:
         o.top    = r[ob].high;
         o.bottom = r[ob].low;
         break;
     }
   if(o.top <= o.bottom)
     {
      Reject(SMC_REJ_ZERO_ZONE, bos);
      return 0;
     }
   o.mid = (o.top + o.bottom) / 2.0;

   if(m_s.fvgMode != SMC_FVG_OFF)
     {
      SFVG f;
      if(m_fvg.FindInLeg(r, i, size, dir, ob, m_s.fvgMinATR * d.atr, f))
         LinkFVG(o, f, false);
      else
         o.fvgPending = true;   // the BOS candle may be the middle of an FVG completed next bar

      if(m_s.fvgMode == SMC_FVG_REQUIRED && !o.hasFVG)
        {
         //--- NOT a confirmed OB: waits one closed bar for the FVG to complete
         int n = ArraySize(m_pending);
         ArrayResize(m_pending, n + 1);
         m_pending[n] = o;
         if(Logs(SMC_LOG_VERBOSE)) Log(SMC_LOG_VERBOSE, StringFormat("%s OB candidate @ %s pending FVG confirmation",
                                           SMC_DirText(dir), TimeToString(o.obTime)));
         return 0;
        }
     }

   long id = Commit(o, bos.barTime);
   if(id == 0)
      Reject(SMC_REJ_OVERLAP, bos);
   return id;
  }

//+------------------------------------------------------------------+
//| Apply overlap policy and store a confirmed OB. Returns id or 0.  |
//+------------------------------------------------------------------+
long CSMCDetector::Commit(SOrderBlock &o, const datetime confirmTime)
  {
   int n = ArraySize(m_obs);
   int supersede[];
   ArrayResize(supersede, 0);

   for(int k = 0; k < n; k++)
     {
      if(m_obs[k].dir != o.dir || !SMC_IsLiveState(m_obs[k].state))
         continue;
      double inter = MathMin(o.top, m_obs[k].top) - MathMax(o.bottom, m_obs[k].bottom);
      if(inter <= 0.0)
         continue;
      double h = MathMin(o.top - o.bottom, m_obs[k].top - m_obs[k].bottom);
      double pct = (h > 0.0) ? inter / h * 100.0 : 100.0;
      if(pct < m_s.overlapPct)
         continue;

      if(m_s.overlapMode == SMC_OVERLAP_SKIP_NEW)
        {
         if(Logs(SMC_LOG_VERBOSE)) Log(SMC_LOG_VERBOSE, StringFormat("%s OB @ %s skipped: %.0f%% overlap with #%I64d",
                                           SMC_DirText(o.dir), TimeToString(o.obTime), pct, m_obs[k].id));
         return 0;
        }
      o.overlapWithId = m_obs[k].id;
      if(m_s.overlapMode == SMC_OVERLAP_SUPERSEDE_OLD)
        {
         int s = ArraySize(supersede);
         ArrayResize(supersede, s + 1);
         supersede[s] = k;
        }
     }

   o.id          = m_nextId++;
   o.confirmTime = confirmTime;
   o.state       = SMC_OB_ACTIVE;
   o.endTime     = 0;

   for(int s = 0; s < ArraySize(supersede); s++)
     {
      int k = supersede[s];
      m_obs[k].state   = SMC_OB_SUPERSEDED;
      m_obs[k].endTime = confirmTime;
      m_stats.superseded++;
      PushEvent(SMC_EVT_OB_SUPERSEDED, m_obs[k].id, m_obs[k].dir, confirmTime, m_obs[k].mid, 0, 0.0, false);
      if(Logs(SMC_LOG_EVENTS)) Log(SMC_LOG_EVENTS, StringFormat("OB #%I64d superseded by #%I64d", m_obs[k].id, o.id));
     }

   ArrayResize(m_obs, n + 1, 64);
   m_obs[n] = o;
   if(o.dir == SMC_DIR_BULL) m_stats.obBull++;
   else                      m_stats.obBear++;
   if(o.hasFVG)              m_stats.fvgLinked++;

   PushEvent(SMC_EVT_OB_CREATED, o.id, o.dir, confirmTime, o.dir == SMC_DIR_BULL ? o.top : o.bottom,
             o.obTime, o.mid, o.hasFVG);
   if(Logs(SMC_LOG_EVENTS)) Log(SMC_LOG_EVENTS, StringFormat("%s OB #%I64d confirmed @ %s | candle %s | zone %s - %s | %s%s | leg %d | move %.2fxATR | FVG %s",
                                    SMC_DirText(o.dir), o.id, TimeToString(confirmTime), TimeToString(o.obTime),
                                    DoubleToString(o.bottom, _Digits), DoubleToString(o.top, _Digits),
                                    o.isChoch ? "CHoCH" : "BOS", o.overlapWithId > 0 ? " (overlap)" : "",
                                    o.legBars, o.atr > 0 ? o.netMove / o.atr : 0.0,
                                    o.hasFVG ? "yes" : (o.fvgPending ? "pending" : "no")));

   if(o.isZOrder && Logs(SMC_LOG_EVENTS))
      Log(SMC_LOG_EVENTS, StringFormat("ZOrder #%I64d series: %d candles %s .. %s", o.id, o.seriesCount,
                                       TimeToString(o.seriesStartTime), TimeToString(o.obTime)));

   EnforceMaxActive(o.dir, confirmTime);
   Prune();
   return o.id;
  }

//+------------------------------------------------------------------+
void CSMCDetector::EnforceMaxActive(const int dir, const datetime t)
  {
   while(true)
     {
      int live = 0, oldest = -1;
      for(int k = 0; k < ArraySize(m_obs); k++)
        {
         if(m_obs[k].dir != dir || !SMC_IsLiveState(m_obs[k].state))
            continue;
         live++;
         if(oldest < 0 || m_obs[k].id < m_obs[oldest].id)
            oldest = k;
        }
      if(live <= m_s.maxActivePerDir || oldest < 0)
         return;
      m_obs[oldest].state = SMC_OB_EXPIRED;
      m_obs[oldest].expiredTime = t;
      if(m_obs[oldest].endTime == 0)
         m_obs[oldest].endTime = t;
      m_stats.expired++;
      PushEvent(SMC_EVT_OB_EXPIRED, m_obs[oldest].id, dir, t, m_obs[oldest].mid);
      if(Logs(SMC_LOG_EVENTS)) Log(SMC_LOG_EVENTS, StringFormat("OB #%I64d expired (max active per direction)", m_obs[oldest].id));
     }
  }

//+------------------------------------------------------------------+
void CSMCDetector::Prune(void)
  {
   while(ArraySize(m_obs) > m_s.maxStored)
     {
      int victim = -1;
      for(int k = 0; k < ArraySize(m_obs); k++)
         if(!SMC_IsLiveState(m_obs[k].state)) { victim = k; break; }   // array is id-ordered
      if(victim < 0)
         return;
      long id = m_obs[victim].id;
      int dir = m_obs[victim].dir;
      int n = ArraySize(m_obs);
      for(int k = victim + 1; k < n; k++)
         m_obs[k - 1] = m_obs[k];
      ArrayResize(m_obs, n - 1, 64);
      PushEvent(SMC_EVT_OB_REMOVED, id, dir, 0, 0.0);
     }
  }

//+------------------------------------------------------------------+
//| FVG whose third candle is bar i and whose middle is the BOS bar. |
//+------------------------------------------------------------------+
void CSMCDetector::ResolvePendingFVG(const MqlRates &r[], const int i, const int size)
  {
   if(i + 2 >= size)
      return;
   SFVG f;

   //--- confluence mode: link to already confirmed OBs (zone never changes)
   for(int k = 0; k < ArraySize(m_obs); k++)
     {
      if(!m_obs[k].fvgPending || m_obs[k].confirmTime >= r[i].time)
         continue;
      m_obs[k].fvgPending = false;
      if(r[i + 1].time != m_obs[k].bosTime)
         continue;
      if(m_fvg.CheckAt(r, i, size, m_obs[k].dir, i + 1, m_s.fvgMinATR * m_obs[k].atr, f))
        {
         LinkFVG(m_obs[k], f, true);
         m_stats.fvgLinked++;
         PushEvent(SMC_EVT_OB_FVG_LINKED, m_obs[k].id, m_obs[k].dir, r[i].time, f.top, f.leftTime, f.bottom);
         if(Logs(SMC_LOG_EVENTS)) Log(SMC_LOG_EVENTS, StringFormat("FVG linked to OB #%I64d @ %s", m_obs[k].id, TimeToString(r[i].time)));
        }
     }

   //--- required mode: confirm or reject waiting candidates
   int np = ArraySize(m_pending);
   if(np == 0)
      return;
   SOrderBlock waiting[];
   ArrayResize(waiting, np);
   for(int k = 0; k < np; k++)
      waiting[k] = m_pending[k];
   ArrayResize(m_pending, 0);

   for(int k = 0; k < np; k++)
     {
      SBOS bos;
      ZeroMemory(bos);
      bos.dir = waiting[k].dir;
      bos.barTime = waiting[k].bosTime;
      bos.level = waiting[k].bosLevel;

      if(r[i + 1].time == waiting[k].bosTime &&
         m_fvg.CheckAt(r, i, size, waiting[k].dir, i + 1, m_s.fvgMinATR * waiting[k].atr, f))
        {
         LinkFVG(waiting[k], f, true);
         if(Commit(waiting[k], r[i].time) == 0)
            Reject(SMC_REJ_OVERLAP, bos);
        }
      else
         Reject(SMC_REJ_FVG_MISSING, bos);
     }
  }

//+------------------------------------------------------------------+
void CSMCDetector::UpdateLifecycle(const MqlRates &bar)
  {
   for(int k = 0; k < ArraySize(m_obs); k++)
      UpdateOne(k, bar);
  }

//+------------------------------------------------------------------+
void CSMCDetector::UpdateOne(const int k, const MqlRates &bar)
  {
   if(!SMC_IsLiveState(m_obs[k].state) || m_obs[k].confirmTime >= bar.time)
      return;

   long id = m_obs[k].id;
   int dir = m_obs[k].dir;
   m_obs[k].barsMonitored++;

   if(m_s.maxAgeBars > 0 && m_obs[k].barsMonitored > m_s.maxAgeBars)
     {
      m_obs[k].state = SMC_OB_EXPIRED;
      m_obs[k].expiredTime = bar.time;
      if(m_obs[k].endTime == 0)
         m_obs[k].endTime = bar.time;
      m_stats.expired++;
      PushEvent(SMC_EVT_OB_EXPIRED, id, dir, bar.time, m_obs[k].mid);
      if(Logs(SMC_LOG_EVENTS)) Log(SMC_LOG_EVENTS, StringFormat("OB #%I64d expired (age)", id));
      return;
     }

   double top = m_obs[k].top, bottom = m_obs[k].bottom, mid = m_obs[k].mid;
   bool touched, reachedMid, reachedFar, closeBeyond, wickBeyond;
   if(dir == SMC_DIR_BULL)
     {
      touched     = bar.low <= top;
      reachedMid  = bar.low <= mid;
      reachedFar  = bar.low <= bottom;
      closeBeyond = bar.close < bottom;
      wickBeyond  = bar.low < bottom;
     }
   else
     {
      touched     = bar.high >= bottom;
      reachedMid  = bar.high >= mid;
      reachedFar  = bar.high >= top;
      closeBeyond = bar.close > top;
      wickBeyond  = bar.high > top;
     }

   //--- retest: a fresh entry into the zone (previous bar was outside)
   if(m_s.retestEnabled && touched && !m_obs[k].touchingPrev)
     {
      m_obs[k].retestCount++;
      m_stats.retests++;
      bool first = (m_obs[k].retestCount == 1);
      double price = (dir == SMC_DIR_BULL) ? MathMax(bar.low, bottom) : MathMin(bar.high, top);
      if(first)
        {
         m_obs[k].firstRetestTime  = bar.time;
         m_obs[k].firstRetestPrice = price;
         if(m_obs[k].state == SMC_OB_ACTIVE)
            m_obs[k].state = SMC_OB_RETESTED;
        }
      PushEvent(SMC_EVT_OB_RETEST, id, dir, bar.time, price, 0, (double)m_obs[k].retestCount, first);
      if(Logs(SMC_LOG_EVENTS)) Log(SMC_LOG_EVENTS, StringFormat("%s OB #%I64d retest #%d @ %s", SMC_DirText(dir), id,
                                       m_obs[k].retestCount, TimeToString(bar.time)));
     }
   m_obs[k].touchingPrev = touched;

   //--- mitigation
   if(m_s.mitigationMode != SMC_MIT_OFF && m_obs[k].state != SMC_OB_MITIGATED)
     {
      bool mit = (m_s.mitigationMode == SMC_MIT_TOUCH)    ? touched :
                 (m_s.mitigationMode == SMC_MIT_MIDPOINT) ? reachedMid : reachedFar;
      if(mit)
        {
         m_obs[k].state = SMC_OB_MITIGATED;
         m_obs[k].mitigatedTime = bar.time;
         m_obs[k].endTime = bar.time;
         m_stats.mitigations++;
         PushEvent(SMC_EVT_OB_MITIGATED, id, dir, bar.time, dir == SMC_DIR_BULL ? bar.low : bar.high);
         if(Logs(SMC_LOG_EVENTS)) Log(SMC_LOG_EVENTS, StringFormat("%s OB #%I64d mitigated @ %s", SMC_DirText(dir), id, TimeToString(bar.time)));
        }
     }

   //--- invalidation (final)
   if(m_s.invalidationMode != SMC_INV_OFF)
     {
      bool inv = (m_s.invalidationMode == SMC_INV_CLOSE_BEYOND) ? closeBeyond : wickBeyond;
      if(inv)
        {
         m_obs[k].state = SMC_OB_INVALIDATED;
         m_obs[k].invalidatedTime = bar.time;
         if(m_obs[k].endTime == 0)
            m_obs[k].endTime = bar.time;
         m_obs[k].liveInside = false;
         m_stats.invalidations++;
         PushEvent(SMC_EVT_OB_INVALIDATED, id, dir, bar.time, bar.close);
         if(Logs(SMC_LOG_EVENTS)) Log(SMC_LOG_EVENTS, StringFormat("%s OB #%I64d invalidated @ %s", SMC_DirText(dir), id, TimeToString(bar.time)));
        }
     }
  }

//+------------------------------------------------------------------+
//| Tick-level "price inside zone" flag. Informational only: it never |
//| changes an OB's confirmed state (that is done on closed bars).   |
//+------------------------------------------------------------------+
bool CSMCDetector::OnTickPrice(const double price)
  {
   bool changed = false;
   for(int k = 0; k < ArraySize(m_obs); k++)
     {
      bool inside = SMC_IsLiveState(m_obs[k].state) && price <= m_obs[k].top && price >= m_obs[k].bottom;
      if(inside != m_obs[k].liveInside)
        {
         m_obs[k].liveInside = inside;
         changed = true;
        }
     }
   return changed;
  }

//+------------------------------------------------------------------+
bool CSMCDetector::GetOB(const int idx, SOrderBlock &out) const
  {
   if(idx < 0 || idx >= ArraySize(m_obs))
      return false;
   out = m_obs[idx];
   return true;
  }

int CSMCDetector::FindById(const long id) const
  {
   for(int k = ArraySize(m_obs) - 1; k >= 0; k--)
      if(m_obs[k].id == id)
         return k;
   return -1;
  }

bool CSMCDetector::HasOB(const int dir, const datetime obTime) const
  {
   for(int k = ArraySize(m_obs) - 1; k >= 0; k--)
      if(m_obs[k].dir == dir && m_obs[k].obTime == obTime)
         return true;
   return false;
  }

bool CSMCDetector::HasPending(const int dir, const datetime obTime) const
  {
   for(int k = 0; k < ArraySize(m_pending); k++)
      if(m_pending[k].dir == dir && m_pending[k].obTime == obTime)
         return true;
   return false;
  }

//--- how many live OBs a direction has, without copying any of them
int CSMCDetector::LiveCount(const int dir) const
  {
   int n = 0;
   for(int k = 0; k < ArraySize(m_obs); k++)
      if(SMC_IsLiveState(m_obs[k].state) && (dir == 0 || m_obs[k].dir == dir))
         n++;
   return n;
  }

int CSMCDetector::GetLiveOBs(const int dir, SOrderBlock &out[]) const
  {
   ArrayResize(out, 0);
   for(int k = 0; k < ArraySize(m_obs); k++)
     {
      if(!SMC_IsLiveState(m_obs[k].state) || (dir != 0 && m_obs[k].dir != dir))
         continue;
      int n = ArraySize(out);
      ArrayResize(out, n + 1);
      out[n] = m_obs[k];
     }
   return ArraySize(out);
  }

bool CSMCDetector::GetEvent(const int idx, SSMCEvent &e) const
  {
   if(idx < 0 || idx >= ArraySize(m_events))
      return false;
   e = m_events[idx];
   return true;
  }

//+------------------------------------------------------------------+
string CSMCDetector::StatsText(void) const
  {
   string text = StringFormat(
             "bars=%d | swings H/L=%d/%d | BOS bull/bear=%d/%d (CHoCH %d) | OB bull/bear=%d/%d | FVG linked=%d\n"
             "rejections: disabled=%d data=%d bosOpposite=%d noOpposite=%d weakMove=%d weakCandle=%d smallBody=%d weakRel=%d legViolation=%d zeroZone=%d fvgMissing=%d overlap=%d duplicate=%d\n"
             "lifecycle: retests=%d mitigated=%d invalidated=%d expired=%d superseded=%d | stored=%d",
             m_stats.barsProcessed, m_stats.swingHighs, m_stats.swingLows, m_stats.bosBull, m_stats.bosBear,
             m_stats.choch, m_stats.obBull, m_stats.obBear, m_stats.fvgLinked,
             m_stats.rejDisabled, m_stats.rejData, m_stats.rejBosOpposite, m_stats.rejNoOpposite,
             m_stats.rejWeakMove, m_stats.rejWeakCandle, m_stats.rejSmallBody, m_stats.rejWeakRelative,
             m_stats.rejLegViolation, m_stats.rejZeroZone, m_stats.rejFVGMissing, m_stats.rejOverlap,
             m_stats.duplicates, m_stats.retests, m_stats.mitigations, m_stats.invalidations,
             m_stats.expired, m_stats.superseded, ArraySize(m_obs));
   if(m_s.zoneSource == SMC_SOURCE_CANDLE_SERIES)
      text += StringFormat(" | seriesTooLong=%d", m_stats.rejSeriesTooLong);
   return text;
  }

#endif // SMC_OB_ENGINE_MQH
