//+------------------------------------------------------------------+
//|                                           SMC_Connect_Engine.mqh |
//|  SPDX-License-Identifier: MIT                                    |
//|  https://github.com/MrOwl1011/Smc_ZOB_CISD                       |
//|  HTF PD Array (Standard OB / ZOrder) -> LTF CISD workflow.       |
//|                                                                  |
//|  Three separate records:                                         |
//|   SConnSetup   one HTF Order Block: zone, validity, retest count |
//|   SConnSeq     one RETEST of that OB -> one CISD sequence, with  |
//|                its own CISD engine, id and state                 |
//|   SConnCISDHit one confirmed CISD of one sequence                |
//|                                                                  |
//|  Retest mode (per OB):                                           |
//|   SINGLE  only the first retest starts a CISD sequence           |
//|   MULTI   every re-entry into the zone starts a new sequence     |
//|  CISD mode (per sequence):                                       |
//|   SINGLE  first valid CISD only                                  |
//|   MULTI   every valid CISD of that sequence                      |
//|                                                                  |
//|  Order Block invalidation is absolute: as soon as the OB's death |
//|  is KNOWN, every live sequence of that OB stops - no new sweep,  |
//|  no new confirmation, no retracement. CISDs already confirmed are |
//|  preserved (sequence ends as COMPLETED).                         |
//|                                                                  |
//|  The CISD candle series may START BEFORE the retest: the engine  |
//|  runs in CISD_ACT_CONFIRM_AFTER mode, so only the confirmation   |
//|  close must fall at/after the activation candle. A setup whose   |
//|  close already changed delivery before activation is consumed, so |
//|  an old CISD is never re-attached to a later retest.             |
//|                                                                  |
//|  Time consistency (no repaint): every decision compares fixed    |
//|  timestamps - OB available at confirmTime + OB period, OB dead at |
//|  invalidation/expiry + OB period, retest known at M1 close, CISD |
//|  known at CISD candle close - so the history scan and live       |
//|  processing give identical results.                              |
//+------------------------------------------------------------------+
#ifndef SMC_CONNECT_ENGINE_MQH
#define SMC_CONNECT_ENGINE_MQH

#include "SMC_OB_Engine.mqh"
#include "SMC_CISD_Engine.mqh"

#define CONN_KIND_STANDARD 0
#define CONN_KIND_ZORDER   1

//--- which PD arrays may activate CISD validation
enum ENUM_CONN_OB_SOURCE
  {
   CONN_SRC_BOTH = 0,      // Both ZOrder Block + Order Block
   CONN_SRC_ZORDER = 1,    // ZOrder Block only
   CONN_SRC_OB = 2         // Order Block only
  };

//--- how many CISDs one monitoring sequence may produce
enum ENUM_CONN_CISD_MODE
  {
   CONN_CISD_SINGLE = 0,   // Single: first valid CISD only
   CONN_CISD_MULTI = 1     // Multi: every valid CISD
  };

//--- how many retests of one Order Block may start a CISD sequence
enum ENUM_CONN_RETEST_MODE
  {
   CONN_RETEST_SINGLE = 0, // Single: only the first retest
   CONN_RETEST_MULTI = 1   // Multi: every re-entry into the zone
  };

enum ENUM_CONN_STATE
  {
   CONN_OB_CREATED = 0,
   CONN_WAITING_FOR_RETEST,
   CONN_OB_RETESTED,
   CONN_CISD_MONITORING,
   CONN_CISD_SWEEP_DETECTED,
   CONN_CISD_CONFIRMED,
   CONN_RETRACEMENT,
   CONN_COMPLETED,
   CONN_INVALIDATED,
   CONN_EXPIRED
  };

enum ENUM_CONN_EVENT
  {
   CONN_EVT_RETEST = 0,
   CONN_EVT_ACTIVATED,
   CONN_EVT_SWEEP,
   CONN_EVT_CONFIRMED,
   CONN_EVT_RETRACED,
   CONN_EVT_COMPLETED,
   CONN_EVT_INVALIDATED,
   CONN_EVT_EXPIRED,
   CONN_EVT_OB_INVALIDATED
  };

struct SConnSettings
  {
   ENUM_TIMEFRAMES    obTF;
   ENUM_TIMEFRAMES    cisdTF;
   bool               useStandard;      // OB source: standard Order Blocks eligible
   bool               useZOrder;        // OB source: ZOrder Blocks eligible
   bool               multiRetest;      // false = Single retest, true = every retest starts a sequence
   bool               multiCISD;        // false = Single CISD per sequence, true = all of them
   bool               stopOnMitigation; // true = a mitigated OB stops CISD monitoring like an invalidated one
   bool               trendFilter;      // only accept a CISD that agrees with the OB-timeframe trend
   int                trendBars;        // displacement measured over this many OB-timeframe candles
   double             trendATRMult;     // displacement must reach this many ATR to count as a trend
   int                trendATRPeriod;   // ATR period for the trend measure
   int                mitigationMode;   // ENUM_SMC_MITIGATION_MODE used for the M1 mitigation check
   int                maxRetests;       // safety cap on sequences per Order Block
   SCISDSettings      cisd;             // template for every per-sequence CISD engine
   int                warmupBars;       // CISD bars fed before the start candle (liquidity, ATR, pre-retest series)
   int                maxMonitorBars;   // CISD bars a sequence may run after activation
   datetime           windowStart;      // OBs available before this are not monitored
   ENUM_SMC_LOG_LEVEL logLevel;
  };

//--- one HTF Order Block being watched
struct SConnSetup
  {
   long              id;
   int               kind;
   long              obId;
   int               dir;
   ENUM_TIMEFRAMES   obTF;
   ENUM_TIMEFRAMES   cisdTF;
   datetime          obTime;            // zone left edge (ZOrder: oldest series candle)
   datetime          obConfirmTime;
   datetime          availTime;         // OB confirmation candle closed
   double            top;
   double            bottom;
   datetime          deadKnown;         // OB invalidation / expiry known at (0 = not known)
   bool              deadByMitigation;  // deadKnown comes from the mitigation (stopOnMitigation)
   datetime          mitM1Time;         // first M1 candle that reached the mitigation level (0 = none)
   ENUM_CONN_STATE   state;             // CREATED / WAITING / RETESTED / INVALIDATED
   datetime          stateTime;
   bool              touching;          // price inside the zone on the last M1 candle
   int               retestCount;       // valid retests seen
   int               seqCount;          // CISD sequences started
   int               cisdCount;         // CISDs confirmed across all sequences
   datetime          retestTime;        // first retest
   double            retestPrice;
   datetime          cisdStartTime;     // first sequence activation point
   datetime          endTime;
  };

//--- one retest of that Order Block = one CISD monitoring sequence
struct SConnSeq
  {
   double            trendScore;    // score that passed the gate, 0 when the filter is off
   double            cisdLevel;     // confirmation level of the accepted CISD
   datetime          cisdSweepTime; // sweep carried by that CISD, 0 when none
   long              id;
   long              setupId;
   int               setupIdx;          // index into the setup array (stable: setups are never removed)
   long              obId;
   int               kind;
   int               dir;
   int               retestNo;          // 1-based retest index of the Order Block
   datetime          retestTime;
   double            retestPrice;
   datetime          cisdStartTime;     // first CISD-TF candle open at/after the retest
   datetime          activatedTime;
   int               cisdBars;
   ENUM_CONN_STATE   state;
   datetime          stateTime;
   datetime          sweepTime;
   double            sweepPrice;
   datetime          sweepSwingTime;
   double            sweepSwingPrice;
   bool              hasCISD;
   long              cisdId;            // first CISD of this sequence
   int               cisdCount;
   long              lastSeenCisdId;
   SCISD             cisd;              // first CISD (identity frozen at confirmation)
   datetime          retraceTime;
   double            retracePrice;
   datetime          endTime;
  };

//--- one confirmed CISD of one sequence
struct SConnCISDHit
  {
   long              setupId;
   long              seqId;
   long              obId;
   int               kind;
   int               dir;
   int               retestNo;
   long              cisdId;
   datetime          confirmTime;
   double            confirmPrice;
   datetime          retraceTime;
   double            retracePrice;
   ENUM_CISD_STATE   cisdState;
   SCISD             cisd;
  };

struct SConnEvent
  {
   ENUM_CONN_EVENT   type;
   long              setupId;
   long              seqId;
   long              obId;
   int               kind;
   int               dir;
   int               retestNo;
   long              cisdId;
   datetime          time;
   double            price;
   double            trendScore;    // signed displacement in ATR that passed the gate (0 when off)
   double            cisdLevel;     // level the confirmation closed through
   datetime          sweepTime;     // liquidity sweep that preceded it, 0 when none
   bool              historical;
  };

struct SConnStats
  {
   int               trendFiltered;    // CISDs rejected because they disagreed with the OB-timeframe trend
   int               registered;
   int               retests;                 // valid retests seen
   int               retestsIgnored;          // retests that started no sequence (Single mode / cap)
   int               sequences;
   int               activated;
   int               sweepStage;
   int               confirmedStd;
   int               confirmedZ;
   int               confirmedBull;
   int               confirmedBear;
   int               cisdHits;
   int               multiExtra;              // CISDs beyond the first one of a sequence
   int               retraced;
   int               completed;
   int               obInvalidated;
   int               invalidatedBeforeRetest;
   int               invalidatedMonitoring;
   int               expired;
   int               maxConcurrent;
  };

struct SConnCandidate
  {
   datetime          avail;
   int               kind;
   long              id;
  };

//+------------------------------------------------------------------+
string SMC_ConnStateText(const ENUM_CONN_STATE s)
  {
   switch(s)
     {
      case CONN_OB_CREATED:          return "OB_CREATED";
      case CONN_WAITING_FOR_RETEST:  return "WAITING_FOR_RETEST";
      case CONN_OB_RETESTED:         return "OB_RETESTED";
      case CONN_CISD_MONITORING:     return "CISD_MONITORING";
      case CONN_CISD_SWEEP_DETECTED: return "CISD_SWEEP_DETECTED";
      case CONN_CISD_CONFIRMED:      return "CISD_CONFIRMED";
      case CONN_RETRACEMENT:         return "RETRACEMENT";
      case CONN_COMPLETED:           return "COMPLETED";
      case CONN_INVALIDATED:         return "INVALIDATED";
      case CONN_EXPIRED:             return "EXPIRED";
     }
   return "?";
  }

string SMC_ConnKindText(const int kind) { return kind == CONN_KIND_ZORDER ? "ZOrder" : "OB"; }

bool SMC_ConnTerminal(const ENUM_CONN_STATE s)
  {
   return s == CONN_RETRACEMENT || s == CONN_COMPLETED || s == CONN_INVALIDATED || s == CONN_EXPIRED;
  }

bool SMC_ConnMonitoring(const ENUM_CONN_STATE s)
  {
   return s == CONN_CISD_MONITORING || s == CONN_CISD_SWEEP_DETECTED || s == CONN_CISD_CONFIRMED;
  }

//--- first bar open time >= t for a timeframe of 'ps' seconds (M1..D1 bars align to epoch multiples)
datetime SMC_ConnAlignUp(const datetime t, const int ps)
  {
   if(ps <= 0)
      return t;
   long rem = (long)t % ps;
   return rem == 0 ? t : (datetime)((long)t - rem + ps);
  }

//+------------------------------------------------------------------+
#define SMC_CONN_TREND_HISTORY 4000   // extra closed OB candles kept for historical trend queries

class CSMCConnection
  {
private:
   SConnSettings     m_s;
   CSMCDetector     *m_std;
   CSMCDetector     *m_z;
   SConnSetup        m_set[];
   SConnSeq          m_seq[];
   SConnCISDHit      m_hits[];
   CSMCCISDEngine   *m_eng[];           // parallel to m_seq
   MqlRates          m_buf[];           // chronological CISD-timeframe candles
   int               m_bufCap;
   MqlRates          m_obBuf[];         // OB-timeframe candles, chronological, for the trend filter
   int               m_obCap;
   MqlRates          m_win[];           // scratch: newest-first window shared by every sequence of one candle
   int               m_winBars;         // bars currently held in m_win (0 = not built for this candle)
   int               m_obIdx[];         // cached detector index per setup (validated by id before use)
   long              m_lastObId[2];
   datetime          m_lastM1;
   datetime          m_lastCISD;
   int               m_obPS;
   int               m_cisdPS;
   int               m_cisdLookback;
   SConnEvent        m_events[];
   SConnStats        m_st;
   long              m_nextSetupId;
   long              m_nextSeqId;
   bool              m_hist;

   void              Log(const ENUM_SMC_LOG_LEVEL level, const string msg) const;
   //--- true when Log() would print: lets callers skip building the message string
   bool              Logs(const ENUM_SMC_LOG_LEVEL level) const
     { return m_s.logLevel >= level && !(m_hist && m_s.logLevel < SMC_LOG_VERBOSE); }
   void              EventSeq(const ENUM_CONN_EVENT type, const int q, const datetime t, const double price);
   void              EventOB(const ENUM_CONN_EVENT type, const int k, const datetime t, const double price);
   datetime          DeadKnown(const SOrderBlock &o, bool &byMitigation) const;
   void              Collect(CSMCDetector *det, const int kind, const bool use, SConnCandidate &cand[]);
   void              Register(const SConnCandidate &c);
   void              FreeEngine(const int q);
   void              NewSequence(const int k, const MqlRates &bar);
   void              TerminalSeq(const int q, const ENUM_CONN_STATE st, const datetime t);
   void              Activate(const int q, const MqlRates &bar);
   void              Feed(const int q);
   void              Evaluate(const int q, const datetime closeTime);
   void              AddHit(const int q, const SCISD &c);
   void              UpdateHits(const int q);

public:
                     CSMCConnection(void);
                    ~CSMCConnection(void) { Reset(); }
   bool              Init(const SConnSettings &s, CSMCDetector *stdDet, CSMCDetector *zDet);
   void              Reset(void);

   void              SyncOBs(void);
   //--- OB-timeframe candles for the trend filter (fed by the EA, history scan and live)
   void              ProcessOBBar(const MqlRates &bar);
   int               ProcessOBWindow(const MqlRates &r[], const int size);
   bool              TrendOK(const int dir, const datetime when, double &score) const;
   bool              ProcessM1Bar(const MqlRates &bar);
   bool              ProcessCISDBar(const MqlRates &bar);
   int               ProcessM1Window(const MqlRates &r[], const int size, const datetime horizon);
   int               ProcessCISDWindow(const MqlRates &r[], const int size, const datetime horizon);

   void              SetHistoricalMode(const bool on) { m_hist = on; }
   datetime          LastM1Time(void) const { return m_lastM1; }
   datetime          LastCISDTime(void) const { return m_lastCISD; }
   int               CISDLookback(void) const { return m_cisdLookback; }
   void              GetSettings(SConnSettings &out) const { out = m_s; }

   int               Count(void) const { return ArraySize(m_set); }
   bool              Get(const int idx, SConnSetup &out) const;
   int               FindSetup(const long setupId) const;
   int               SeqCount(void) const { return ArraySize(m_seq); }
   bool              GetSeq(const int idx, SConnSeq &out) const;
   int               SeqsOfSetup(const long setupId, SConnSeq &out[]) const;
   int               HitCount(void) const { return ArraySize(m_hits); }
   bool              GetHit(const int idx, SConnCISDHit &out) const;
   int               HitsOfSeq(const long seqId, SConnCISDHit &out[]) const;
   int               HitsOfSetup(const long setupId, SConnCISDHit &out[]) const;
   int               ActiveCount(void) const;
   int               EventCount(void) const { return ArraySize(m_events); }
   bool              GetEvent(const int idx, SConnEvent &e) const;
   void              ClearEvents(void) { ArrayResize(m_events, 0, 64); }
   void              GetStats(SConnStats &st) const { st = m_st; }
   string            StatsText(void) const;
  };

//+------------------------------------------------------------------+
CSMCConnection::CSMCConnection(void) : m_std(NULL), m_z(NULL), m_bufCap(0), m_obCap(0), m_winBars(0), m_lastM1(0), m_lastCISD(0),
                                       m_obPS(0), m_cisdPS(0), m_cisdLookback(0), m_nextSetupId(1),
                                       m_nextSeqId(1), m_hist(false)
  {
   m_lastObId[0] = m_lastObId[1] = 0;
   ZeroMemory(m_s);
   ZeroMemory(m_st);
  }

bool CSMCConnection::Init(const SConnSettings &s, CSMCDetector *stdDet, CSMCDetector *zDet)
  {
   Reset();
   m_s = s;
   m_std = stdDet;
   m_z = zDet;
   m_obPS = PeriodSeconds(m_s.obTF);
   m_cisdPS = PeriodSeconds(m_s.cisdTF);
   if(m_obPS <= 0 || m_cisdPS <= 0 || m_s.maxMonitorBars < 1)
      return false;
   if(m_s.maxRetests < 1)
      m_s.maxRetests = 1;
   CSMCCISDEngine probe;
   SCISDSettings cs = m_s.cisd;
   cs.timeframe = m_s.cisdTF;
   if(!probe.Init(cs))
      return false;
   m_cisdLookback = probe.RequiredLookback();
   m_s.warmupBars = MathMax(m_s.warmupBars, m_cisdLookback + 10);
   m_bufCap = m_s.warmupBars + m_cisdLookback + 5;
   if(m_s.trendBars < 1)
      m_s.trendBars = 20;
   if(m_s.trendATRPeriod < 1)
      m_s.trendATRPeriod = 14;
   //--- the window needed for a decision, plus history so a bulk feed (batch replay,
   //--- self-test) can still answer questions about earlier timestamps
   m_obCap = m_s.trendBars + m_s.trendATRPeriod + 5 + SMC_CONN_TREND_HISTORY;
   return true;
  }

void CSMCConnection::Reset(void)
  {
   for(int q = 0; q < ArraySize(m_eng); q++)
      FreeEngine(q);
   ArrayResize(m_set, 0, 64);
   ArrayResize(m_seq, 0, 64);
   ArrayResize(m_hits, 0, 64);
   ArrayResize(m_eng, 0, 64);
   ArrayResize(m_buf, 0, 64);
   ArrayResize(m_events, 0, 64);
   ArrayResize(m_obIdx, 0, 64);
   ArrayResize(m_obBuf, 0, 64);
   m_winBars = 0;
   ZeroMemory(m_st);
   m_lastObId[0] = m_lastObId[1] = 0;
   m_lastM1 = 0;
   m_lastCISD = 0;
   m_nextSetupId = 1;
   m_nextSeqId = 1;
  }

//+------------------------------------------------------------------+
void CSMCConnection::Log(const ENUM_SMC_LOG_LEVEL level, const string msg) const
  {
   if(m_s.logLevel < level || (m_hist && m_s.logLevel < SMC_LOG_VERBOSE))
      return;
   PrintFormat("[SMC-CONN][%s>%s]%s %s", SMC_TFText(m_s.obTF), SMC_TFText(m_s.cisdTF), m_hist ? "[hist]" : "", msg);
  }

void CSMCConnection::EventSeq(const ENUM_CONN_EVENT type, const int q, const datetime t, const double price)
  {
   int n = ArraySize(m_events);
   ArrayResize(m_events, n + 1, 64);
   m_events[n].type       = type;
   m_events[n].setupId    = m_seq[q].setupId;
   m_events[n].seqId      = m_seq[q].id;
   m_events[n].obId       = m_seq[q].obId;
   m_events[n].kind       = m_seq[q].kind;
   m_events[n].dir        = m_seq[q].dir;
   m_events[n].retestNo   = m_seq[q].retestNo;
   m_events[n].cisdId     = m_seq[q].cisdId;
   m_events[n].time       = t;
   m_events[n].price      = price;
   m_events[n].trendScore = m_seq[q].trendScore;
   m_events[n].cisdLevel  = m_seq[q].cisdLevel;
   m_events[n].sweepTime  = m_seq[q].cisdSweepTime;
   m_events[n].historical = m_hist;
  }

void CSMCConnection::EventOB(const ENUM_CONN_EVENT type, const int k, const datetime t, const double price)
  {
   int n = ArraySize(m_events);
   ArrayResize(m_events, n + 1, 64);
   ZeroMemory(m_events[n]);
   m_events[n].type       = type;
   m_events[n].setupId    = m_set[k].id;
   m_events[n].obId       = m_set[k].obId;
   m_events[n].kind       = m_set[k].kind;
   m_events[n].dir        = m_set[k].dir;
   m_events[n].time       = t;
   m_events[n].price      = price;
   m_events[n].historical = m_hist;
  }

//--- when the end of the OB became known (0 = still valid as far as the detector knows)
datetime CSMCConnection::DeadKnown(const SOrderBlock &o, bool &byMitigation) const
  {
   datetime dead = 0;
   switch(o.state)
     {
      case SMC_OB_INVALIDATED: dead = (datetime)(o.invalidatedTime + m_obPS); break;
      case SMC_OB_EXPIRED:     dead = (datetime)(o.expiredTime + m_obPS);     break;   // not endTime: may be an earlier mitigation
      case SMC_OB_SUPERSEDED:  dead = (datetime)(o.endTime + m_obPS);         break;
      default:                 break;
     }
   //--- option: mitigation ends the CISD search too (known when the mitigating candle closes)
   byMitigation = false;
   if(m_s.stopOnMitigation && o.mitigatedTime > 0)
     {
      datetime mit = (datetime)(o.mitigatedTime + m_obPS);
      if(dead == 0 || mit < dead)
        {
         dead = mit;
         byMitigation = true;
        }
     }
   return dead;
  }

//+------------------------------------------------------------------+
void CSMCConnection::Collect(CSMCDetector *det, const int kind, const bool use, SConnCandidate &cand[])
  {
   if(det == NULL)
      return;
   long maxId = m_lastObId[kind];
   int n = det.OBCount();
   for(int k = 0; k < n; k++)
     {
      if(det.OBIdAt(k) <= m_lastObId[kind])          // id only: no struct copy for known OBs
         continue;
      SOrderBlock o;
      if(!det.GetOB(k, o))
         continue;
      maxId = MathMax(maxId, o.id);
      datetime avail = (datetime)(o.confirmTime + m_obPS);
      if(!use || avail < m_s.windowStart)
         continue;
      int n = ArraySize(cand);
      ArrayResize(cand, n + 1);
      cand[n].avail = avail;
      cand[n].kind  = kind;
      cand[n].id    = o.id;
     }
   m_lastObId[kind] = maxId;
  }

void CSMCConnection::Register(const SConnCandidate &c)
  {
   CSMCDetector *det = (c.kind == CONN_KIND_ZORDER) ? m_z : m_std;
   int idx = det.FindById(c.id);
   SOrderBlock o;
   if(idx < 0 || !det.GetOB(idx, o))
      return;
   SConnSetup x;
   ZeroMemory(x);
   x.id            = m_nextSetupId++;
   x.kind          = c.kind;
   x.obId          = o.id;
   x.dir           = o.dir;
   x.obTF          = m_s.obTF;
   x.cisdTF        = m_s.cisdTF;
   x.obTime        = o.isZOrder ? o.seriesStartTime : o.obTime;
   x.obConfirmTime = o.confirmTime;
   x.availTime     = c.avail;
   x.top           = o.top;
   x.bottom        = o.bottom;
   x.deadKnown     = DeadKnown(o, x.deadByMitigation);
   x.state         = CONN_OB_CREATED;
   x.stateTime     = c.avail;
   int n = ArraySize(m_set);
   ArrayResize(m_set, n + 1, 64);
   m_set[n] = x;
   m_st.registered++;
  }

//+------------------------------------------------------------------+
void CSMCConnection::SyncOBs(void)
  {
   //--- refresh what is known about the end of monitored OBs. The detector index of an OB
   //--- is cached and re-validated by id, so the linear search runs only when it moved.
   int ns = ArraySize(m_set);
   if(ArraySize(m_obIdx) < ns)
     {
      int from = ArraySize(m_obIdx);
      ArrayResize(m_obIdx, ns, 64);
      for(int k = from; k < ns; k++)
         m_obIdx[k] = -1;
     }
   for(int k = 0; k < ns; k++)
     {
      if(m_set[k].state == CONN_INVALIDATED)
         continue;
      CSMCDetector *det = (m_set[k].kind == CONN_KIND_ZORDER) ? m_z : m_std;
      if(det == NULL)
         continue;
      int idx = m_obIdx[k];
      if(idx < 0 || det.OBIdAt(idx) != m_set[k].obId)
        {
         idx = det.FindById(m_set[k].obId);
         m_obIdx[k] = idx;
        }
      //--- a live OB has no end yet, and a dead one never becomes live again: one copy is enough.
      //--- With stopOnMitigation a mitigated (still live) OB also ends the search.
      ENUM_SMC_OB_STATE ost = (idx >= 0) ? det.OBStateAt(idx) : SMC_OB_ACTIVE;
      if(idx >= 0 && m_set[k].deadKnown == 0 &&
         (!SMC_IsLiveState(ost) || (m_s.stopOnMitigation && ost == SMC_OB_MITIGATED)))
        {
         SOrderBlock o;
         if(det.GetOB(idx, o))
            m_set[k].deadKnown = DeadKnown(o, m_set[k].deadByMitigation);
        }
     }

   //--- register new OBs in deterministic (availability, kind, id) order
   SConnCandidate cand[];
   Collect(m_std, CONN_KIND_STANDARD, m_s.useStandard, cand);
   Collect(m_z, CONN_KIND_ZORDER, m_s.useZOrder, cand);
   int n = ArraySize(cand);
   for(int a = 1; a < n; a++)
     {
      SConnCandidate key = cand[a];
      int b = a - 1;
      while(b >= 0 && (cand[b].avail > key.avail || (cand[b].avail == key.avail &&
                       (cand[b].kind > key.kind || (cand[b].kind == key.kind && cand[b].id > key.id)))))
        {
         cand[b + 1] = cand[b];
         b--;
        }
      cand[b + 1] = key;
     }
   for(int a = 0; a < n; a++)
      Register(cand[a]);
  }

//+------------------------------------------------------------------+
//| OB-timeframe candles kept for the trend filter. Only closed bars  |
//| are pushed, so nothing here can look ahead.                       |
//+------------------------------------------------------------------+
void CSMCConnection::ProcessOBBar(const MqlRates &bar)
  {
   int n = ArraySize(m_obBuf);
   if(n > 0 && bar.time <= m_obBuf[n - 1].time)
      return;                                   // each candle once, chronological
   if(m_obCap > 0 && n >= m_obCap)
     {
      for(int k = 1; k < n; k++)
         m_obBuf[k - 1] = m_obBuf[k];
      n--;
     }
   ArrayResize(m_obBuf, n + 1, 64);
   m_obBuf[n] = bar;
  }

int CSMCConnection::ProcessOBWindow(const MqlRates &r[], const int size)
  {
   int n = 0;
   for(int i = size - 1; i >= 0; i--)                 // series order: oldest first
     {
      int before = ArraySize(m_obBuf);
      ProcessOBBar(r[i]);
      if(ArraySize(m_obBuf) != before || (before > 0 && m_obBuf[before - 1].time == r[i].time))
         n++;
     }
   return n;
  }

//+------------------------------------------------------------------+
//| Trend filter: displacement over trendBars OB candles, measured in |
//| ATR, using only candles that had closed at 'when'.                |
//|   score = (close - close[trendBars ago]) / ATR                    |
//| A signal passes when |score| >= trendATRMult and the sign matches. |
//+------------------------------------------------------------------+
bool CSMCConnection::TrendOK(const int dir, const datetime when, double &score) const
  {
   score = 0.0;
   if(!m_s.trendFilter)
      return true;
   int n = ArraySize(m_obBuf);
   //--- newest candle that had already closed at 'when'
   int last = -1;
   for(int k = n - 1; k >= 0; k--)
      if((datetime)(m_obBuf[k].time + m_obPS) <= when)
        {
         last = k;
         break;
        }
   if(last < m_s.trendBars || last < m_s.trendATRPeriod)
      return false;                              // not enough closed history: no trend evidence

   double tr = 0.0;
   int cnt = 0;
   for(int k = last; k > 0 && cnt < m_s.trendATRPeriod; k--, cnt++)
     {
      double h = m_obBuf[k].high, l = m_obBuf[k].low, pc = m_obBuf[k - 1].close;
      tr += MathMax(h - l, MathMax(MathAbs(h - pc), MathAbs(l - pc)));
     }
   if(cnt < 1)
      return false;
   double atr = tr / cnt;
   if(atr <= 0.0)
      return false;
   score = (m_obBuf[last].close - m_obBuf[last - m_s.trendBars].close) / atr;
   if(MathAbs(score) < m_s.trendATRMult)
      return false;                              // ranging
   return (dir == SMC_DIR_BULL) ? (score > 0.0) : (score < 0.0);
  }

//+------------------------------------------------------------------+
void CSMCConnection::FreeEngine(const int q)
  {
   if(q < 0 || q >= ArraySize(m_eng))
      return;
   if(CheckPointer(m_eng[q]) == POINTER_DYNAMIC)
      delete m_eng[q];
   m_eng[q] = NULL;
  }

void CSMCConnection::TerminalSeq(const int q, const ENUM_CONN_STATE st, const datetime t)
  {
   m_seq[q].state = st;
   m_seq[q].stateTime = t;
   m_seq[q].endTime = t;
   FreeEngine(q);
   switch(st)
     {
      case CONN_RETRACEMENT: EventSeq(CONN_EVT_RETRACED, q, t, m_seq[q].retracePrice); break;
      case CONN_COMPLETED:   EventSeq(CONN_EVT_COMPLETED, q, t, m_seq[q].cisd.confirmPrice); break;
      case CONN_INVALIDATED: EventSeq(CONN_EVT_INVALIDATED, q, t, 0.0); break;
      case CONN_EXPIRED:     EventSeq(CONN_EVT_EXPIRED, q, t, 0.0); break;
      default: break;
     }
   if(Logs(SMC_LOG_EVENTS)) Log(SMC_LOG_EVENTS, StringFormat("%s %s #%I64d retest #%d (seq #%I64d) -> %s @ %s", SMC_DirText(m_seq[q].dir),
                                    SMC_ConnKindText(m_seq[q].kind), m_seq[q].obId, m_seq[q].retestNo, m_seq[q].id,
                                    SMC_ConnStateText(st), TimeToString(t)));
  }

//+------------------------------------------------------------------+
void CSMCConnection::NewSequence(const int k, const MqlRates &bar)
  {
   SConnSeq s;
   ZeroMemory(s);
   s.id            = m_nextSeqId++;
   s.setupId       = m_set[k].id;
   s.setupIdx      = k;
   s.obId          = m_set[k].obId;
   s.kind          = m_set[k].kind;
   s.dir           = m_set[k].dir;
   s.retestNo      = m_set[k].retestCount;
   s.retestTime    = bar.time;
   s.retestPrice   = (m_set[k].dir == SMC_DIR_BULL) ? MathMax(bar.low, m_set[k].bottom)
                                                    : MathMin(bar.high, m_set[k].top);
   s.cisdStartTime = SMC_ConnAlignUp(bar.time, m_cisdPS);
   s.state         = CONN_OB_RETESTED;
   s.stateTime     = bar.time;

   int n = ArraySize(m_seq);
   ArrayResize(m_seq, n + 1, 64);
   ArrayResize(m_eng, n + 1, 64);
   m_seq[n] = s;
   m_eng[n] = NULL;

   m_set[k].seqCount++;
   if(m_set[k].retestTime == 0)
     {
      m_set[k].retestTime    = s.retestTime;
      m_set[k].retestPrice   = s.retestPrice;
      m_set[k].cisdStartTime = s.cisdStartTime;
     }
   m_st.sequences++;
   EventSeq(CONN_EVT_RETEST, n, bar.time, s.retestPrice);
   if(Logs(SMC_LOG_EVENTS)) Log(SMC_LOG_EVENTS, StringFormat("%s %s #%I64d RETEST #%d @ %s (%s) -> %s CISD sequence #%I64d from %s",
                                    SMC_DirText(s.dir), SMC_ConnKindText(s.kind), s.obId, s.retestNo,
                                    TimeToString(bar.time), DoubleToString(s.retestPrice, _Digits),
                                    SMC_TFText(m_s.cisdTF), s.id, TimeToString(s.cisdStartTime)));
  }

//+------------------------------------------------------------------+
//| M1 closed candle: OB validity, retests and new sequences          |
//+------------------------------------------------------------------+
bool CSMCConnection::ProcessM1Bar(const MqlRates &bar)
  {
   if(bar.time <= m_lastM1)
      return false;
   m_lastM1 = bar.time;
   for(int k = 0; k < ArraySize(m_set); k++)
     {
      if(m_set[k].state == CONN_INVALIDATED)
         continue;
      if(bar.time < m_set[k].availTime)
         continue;                                          // OB not confirmed yet at this candle

      //--- invalidation is absolute: the OB can never start another sequence. Its live sequences are
      //--- ended in the CISD path, which compares deadKnown with the candle close before evaluating
      //--- anything - that decision is timestamp based, so it does not depend on processing order.
      if(m_set[k].deadKnown > 0 && m_set[k].deadKnown <= bar.time)
        {
         m_set[k].state     = CONN_INVALIDATED;
         m_set[k].stateTime = m_set[k].deadKnown;
         m_set[k].endTime   = m_set[k].deadKnown;
         m_set[k].touching  = false;
         m_st.obInvalidated++;
         EventOB(CONN_EVT_OB_INVALIDATED, k, m_set[k].deadKnown, 0.0);
         if(Logs(SMC_LOG_EVENTS)) Log(SMC_LOG_EVENTS, StringFormat("%s %s #%I64d %s @ %s - CISD monitoring stopped",
                                          SMC_DirText(m_set[k].dir), SMC_ConnKindText(m_set[k].kind), m_set[k].obId,
                                          m_set[k].deadByMitigation ? "MITIGATED" : "INVALIDATED",
                                          TimeToString(m_set[k].deadKnown)));
         continue;
        }

      if(m_set[k].state == CONN_OB_CREATED)
        {
         m_set[k].state = CONN_WAITING_FOR_RETEST;
         m_set[k].stateTime = bar.time;
        }

      //--- a retest is a fresh entry into the zone (price must have left it first)
      bool touching = (bar.low <= m_set[k].top && bar.high >= m_set[k].bottom);
      if(touching && !m_set[k].touching)
        {
         m_set[k].retestCount++;
         m_set[k].state = CONN_OB_RETESTED;
         m_set[k].stateTime = bar.time;
         m_st.retests++;
         bool allow = (m_s.multiRetest || m_set[k].seqCount == 0) && (m_set[k].seqCount < m_s.maxRetests);
         if(allow)
            NewSequence(k, bar);
         else
           {
            m_st.retestsIgnored++;
            if(Logs(SMC_LOG_VERBOSE)) Log(SMC_LOG_VERBOSE, StringFormat("%s %s #%I64d retest #%d ignored (%s)", SMC_DirText(m_set[k].dir),
                                              SMC_ConnKindText(m_set[k].kind), m_set[k].obId, m_set[k].retestCount,
                                              m_s.multiRetest ? "retest cap reached" : "SINGLE retest mode"));
           }
        }
      m_set[k].touching = touching;

      //--- option: mitigation stops the CISD search. Checked on EVERY M1 candle - not only when the
      //--- OB-timeframe candle closes - so the search ends at the close of the first M1 candle that
      //--- reaches the mitigation level (same levels as the detector: touch / 50% / far edge).
      if(m_s.stopOnMitigation && m_s.mitigationMode != SMC_MIT_OFF && m_set[k].mitM1Time == 0)
        {
         bool bull = (m_set[k].dir == SMC_DIR_BULL);
         double mid = (m_set[k].top + m_set[k].bottom) / 2.0;
         bool mit;
         if(m_s.mitigationMode == SMC_MIT_TOUCH)
            mit = bull ? (bar.low <= m_set[k].top) : (bar.high >= m_set[k].bottom);
         else if(m_s.mitigationMode == SMC_MIT_MIDPOINT)
            mit = bull ? (bar.low <= mid) : (bar.high >= mid);
         else
            mit = bull ? (bar.low <= m_set[k].bottom) : (bar.high >= m_set[k].top);
         if(mit)
           {
            m_set[k].mitM1Time = bar.time;
            datetime known = (datetime)(bar.time + 60);        // close of this M1 candle
            if(m_set[k].deadKnown == 0 || known < m_set[k].deadKnown)
              {
               m_set[k].deadKnown        = known;
               m_set[k].deadByMitigation = true;
              }
           }
        }
     }
   return true;
  }

//+------------------------------------------------------------------+
//| CISD-timeframe closed candle: activation and per-sequence engines |
//+------------------------------------------------------------------+
bool CSMCConnection::ProcessCISDBar(const MqlRates &bar)
  {
   if(bar.time <= m_lastCISD)
      return false;
   m_lastCISD = bar.time;

   int n = ArraySize(m_buf);
   if(n >= m_bufCap)
     {
      for(int j = 1; j < n; j++)               // drop the oldest candle
         m_buf[j - 1] = m_buf[j];
      n--;
     }
   ArrayResize(m_buf, n + 1, 64);
   m_buf[n] = bar;
   m_winBars = 0;                             // the shared window belongs to the previous candle

   datetime tc = (datetime)(bar.time + m_cisdPS);
   for(int q = 0; q < ArraySize(m_seq); q++)
     {
      ENUM_CONN_STATE st = m_seq[q].state;
      if(SMC_ConnTerminal(st))
         continue;
      int k = m_seq[q].setupIdx;
      datetime dead = (k >= 0 && k < ArraySize(m_set)) ? m_set[k].deadKnown : 0;

      //--- OB invalidation stops the sequence in every mode, before anything else is evaluated.
      //--- 'dead' is the close of the OB-timeframe candle that invalidated the OB, so the OB is
      //--- still valid for every candle closing up to that moment - including the last one that
      //--- closes together with it (e.g. M1 15:44 for an M15 15:30 candle). It stops after that.
      if(dead > 0 && dead < tc)
        {
         if(m_seq[q].hasCISD)
           {
            m_st.completed++;                              // confirmed CISDs are preserved
            TerminalSeq(q, CONN_COMPLETED, dead);
           }
         else
           {
            if(st == CONN_OB_RETESTED) m_st.invalidatedBeforeRetest++;
            else                       m_st.invalidatedMonitoring++;
            TerminalSeq(q, CONN_INVALIDATED, dead);
           }
         continue;
        }

      if(st == CONN_OB_RETESTED)
        {
         if(bar.time < m_seq[q].cisdStartTime)
            continue;
         Activate(q, bar);
        }
      else
        {
         Feed(q);
         Evaluate(q, tc);
        }
     }
   m_st.maxConcurrent = MathMax(m_st.maxConcurrent, ActiveCount());
   return true;
  }

//+------------------------------------------------------------------+
void CSMCConnection::Activate(const int q, const MqlRates &bar)
  {
   CSMCCISDEngine *e = new CSMCCISDEngine;
   SCISDSettings cs = m_s.cisd;
   cs.timeframe      = m_s.cisdTF;
   cs.activationTime = m_seq[q].cisdStartTime;       // confirmation must be at/after the retest
   cs.activationMode = CISD_ACT_CONFIRM_AFTER;       // the candle series itself may start earlier
   cs.dirFilter      = m_seq[q].dir;                 // CISD direction must match the OB
   cs.logLevel       = SMC_LOG_OFF;
   if(!e.Init(cs))
     {
      delete e;
      m_st.expired++;
      TerminalSeq(q, CONN_EXPIRED, (datetime)(bar.time + m_cisdPS));
      return;
     }
   m_eng[q] = e;

   //--- warm-up: liquidity pools, ATR and any candle series that began before the retest
   int n = ArraySize(m_buf);
   int size = MathMin(n, m_s.warmupBars + 1);
   MqlRates win[];
   ArrayResize(win, size, 64);
   for(int j = 0; j < size; j++)
      win[j] = m_buf[n - 1 - j];
   e.ProcessWindow(win, size);

   m_seq[q].state         = CONN_CISD_MONITORING;
   m_seq[q].stateTime     = bar.time;
   m_seq[q].activatedTime = bar.time;
   m_seq[q].cisdBars      = 0;
   m_st.activated++;
   EventSeq(CONN_EVT_ACTIVATED, q, bar.time, bar.open);
   if(Logs(SMC_LOG_VERBOSE)) Log(SMC_LOG_VERBOSE, StringFormat("sequence #%I64d (OB #%I64d retest #%d) monitoring from %s", m_seq[q].id,
                                     m_seq[q].obId, m_seq[q].retestNo, TimeToString(bar.time)));
   Evaluate(q, (datetime)(bar.time + m_cisdPS));
  }

void CSMCConnection::Feed(const int q)
  {
   if(m_eng[q] == NULL)
      return;
   //--- every sequence sees the same newest-first window of this candle: build it once and reuse it
   if(m_winBars <= 0)
     {
      int n = ArraySize(m_buf);
      int size = MathMin(n, m_cisdLookback + 1);
      if(ArraySize(m_win) < size)
         ArrayResize(m_win, size, 64);
      for(int j = 0; j < size; j++)
         m_win[j] = m_buf[n - 1 - j];
      m_winBars = size;
     }
   m_eng[q].ProcessBar(m_win, 0, m_winBars);
  }

//+------------------------------------------------------------------+
//--- record one confirmed CISD of this sequence
void CSMCConnection::AddHit(const int q, const SCISD &c)
  {
   int k = m_seq[q].setupIdx;
   int n = ArraySize(m_hits);
   ArrayResize(m_hits, n + 1, 64);
   ZeroMemory(m_hits[n]);
   m_hits[n].setupId      = m_seq[q].setupId;
   m_hits[n].seqId        = m_seq[q].id;
   m_hits[n].obId         = m_seq[q].obId;
   m_hits[n].kind         = m_seq[q].kind;
   m_hits[n].dir          = m_seq[q].dir;
   m_hits[n].retestNo     = m_seq[q].retestNo;
   m_hits[n].cisdId       = c.id;
   m_hits[n].confirmTime  = c.confirmTime;
   m_hits[n].confirmPrice = c.confirmPrice;
   m_hits[n].cisdState    = c.state;
   m_hits[n].cisd         = c;

   bool first = !m_seq[q].hasCISD;
   m_seq[q].cisdCount++;
   if(k >= 0 && k < ArraySize(m_set))
      m_set[k].cisdCount++;
   m_st.cisdHits++;
   if(first)
     {
      m_seq[q].hasCISD   = true;
      m_seq[q].cisdId    = c.id;
      m_seq[q].cisd      = c;
      m_seq[q].state     = CONN_CISD_CONFIRMED;
      m_seq[q].stateTime = c.confirmTime;
      if(c.hasSweep)
        {
         m_seq[q].sweepTime       = c.sweepTime;
         m_seq[q].sweepPrice      = c.sweepPrice;
         m_seq[q].sweepSwingTime  = c.sweptSwingTime;
         m_seq[q].sweepSwingPrice = c.sweptSwingPrice;
        }
      if(m_seq[q].kind == CONN_KIND_ZORDER) m_st.confirmedZ++;
      else                                  m_st.confirmedStd++;
      if(m_seq[q].dir == SMC_DIR_BULL)      m_st.confirmedBull++;
      else                                  m_st.confirmedBear++;
     }
   else
      m_st.multiExtra++;

   EventSeq(CONN_EVT_CONFIRMED, q, c.confirmTime, c.confirmPrice);
   if(Logs(SMC_LOG_EVENTS)) Log(SMC_LOG_EVENTS, StringFormat("CONFIRMED %s setup%s: %s %s #%I64d retest #%d + %s CISD #%I64d close %s @ %s%s",
                                    SMC_DirText(m_seq[q].dir),
                                    first ? "" : StringFormat(" (CISD %d of this sequence)", m_seq[q].cisdCount),
                                    SMC_TFText(m_s.obTF), SMC_ConnKindText(m_seq[q].kind), m_seq[q].obId,
                                    m_seq[q].retestNo, SMC_TFText(m_s.cisdTF), c.id,
                                    DoubleToString(c.confirmPrice, _Digits), TimeToString(c.confirmTime),
                                    c.seriesStartTime < m_seq[q].cisdStartTime ? " (series began before the retest)" : ""));
  }

//--- refresh the life-cycle (retracement) of every CISD recorded for this sequence
void CSMCConnection::UpdateHits(const int q)
  {
   CSMCCISDEngine *e = m_eng[q];
   if(e == NULL)
      return;
   SCISD c;
   for(int h = 0; h < ArraySize(m_hits); h++)
     {
      if(m_hits[h].seqId != m_seq[q].id)
         continue;
      int idx = e.FindById(m_hits[h].cisdId);
      if(idx < 0 || !e.Get(idx, c))
         continue;
      m_hits[h].cisd      = c;                        // identity unchanged; life-cycle only
      m_hits[h].cisdState = c.state;
      if(c.state == CISD_ST_RETRACED && m_hits[h].retraceTime == 0)
        {
         m_hits[h].retraceTime  = c.retraceTime;
         m_hits[h].retracePrice = c.retracePrice;
         if(m_s.multiCISD)
           {
            m_st.retraced++;                          // Single reports this from TerminalSeq()
            EventSeq(CONN_EVT_RETRACED, q, c.retraceTime, c.retracePrice);
            if(Logs(SMC_LOG_EVENTS)) Log(SMC_LOG_EVENTS, StringFormat("sequence #%I64d CISD #%I64d retracement / entry @ %s", m_seq[q].id, c.id,
                                             TimeToString(c.retraceTime)));
           }
        }
      if(m_hits[h].cisdId == m_seq[q].cisdId)
         m_seq[q].cisd = c;
     }
  }

//+------------------------------------------------------------------+
void CSMCConnection::Evaluate(const int q, const datetime closeTime)
  {
   CSMCCISDEngine *e = m_eng[q];
   if(e == NULL)
      return;
   m_seq[q].cisdBars++;
   SCISD c;

   //--- new same-direction confirmations; SINGLE stops after the first one
   if(!m_seq[q].hasCISD || m_s.multiCISD)
     {
      for(int j = 0; j < e.Count(); j++)
        {
         if(!e.Get(j, c) || c.dir != m_seq[q].dir || !SMC_CISDConfirmedState(c.state) || c.id <= m_seq[q].lastSeenCisdId)
            continue;
         m_seq[q].lastSeenCisdId = c.id;
         double tscore = 0.0;
         if(!TrendOK(m_seq[q].dir, c.confirmTime, tscore))
           {
            m_st.trendFiltered++;                 // valid CISD, rejected by the trend filter
            if(Logs(SMC_LOG_VERBOSE))
               Log(SMC_LOG_VERBOSE, StringFormat("%s %s #%I64d + CISD #%I64d rejected by the trend filter "
                                                 "(score %.2f, needs %s%.2f)", SMC_DirText(m_seq[q].dir),
                                                 SMC_ConnKindText(m_seq[q].kind), m_seq[q].obId, c.id, tscore,
                                                 m_seq[q].dir == SMC_DIR_BULL ? "+" : "-", m_s.trendATRMult));
            continue;
           }
         m_seq[q].trendScore = tscore;        // kept for the trade layer's confidence score
         m_seq[q].cisdLevel  = c.level;
         m_seq[q].cisdSweepTime = c.hasSweep ? c.sweepTime : 0;
         AddHit(q, c);
         if(!m_s.multiCISD)
            break;
        }
     }

   if(!m_seq[q].hasCISD)
     {
      if(e.SweepCount() > 0)
        {
         SCISDSweep sw;
         e.GetSweep(e.SweepCount() - 1, sw);
         m_seq[q].sweepTime       = sw.time;
         m_seq[q].sweepPrice      = sw.price;
         m_seq[q].sweepSwingTime  = sw.swingTime;
         m_seq[q].sweepSwingPrice = sw.swingPrice;
         if(m_seq[q].state == CONN_CISD_MONITORING)
           {
            m_seq[q].state = CONN_CISD_SWEEP_DETECTED;
            m_seq[q].stateTime = sw.time;
            m_st.sweepStage++;
            EventSeq(CONN_EVT_SWEEP, q, sw.time, sw.price);
           }
        }
      if(m_seq[q].cisdBars >= m_s.maxMonitorBars)
        {
         m_st.expired++;
         TerminalSeq(q, CONN_EXPIRED, closeTime);
        }
      return;
     }

   UpdateHits(q);

   //--- MULTI CISD: keep collecting from this sequence until the window ends
   if(m_s.multiCISD)
     {
      if(m_seq[q].cisdBars >= m_s.maxMonitorBars)
        {
         m_st.completed++;
         TerminalSeq(q, CONN_COMPLETED, closeTime);
        }
      return;
     }

   //--- SINGLE CISD: confirmed -> retracement / completion
   if(!m_s.cisd.useRetrace)
     {
      m_st.completed++;
      TerminalSeq(q, CONN_COMPLETED, closeTime);
      return;
     }
   if(m_seq[q].cisd.state == CISD_ST_RETRACED)
     {
      m_seq[q].retraceTime  = m_seq[q].cisd.retraceTime;
      m_seq[q].retracePrice = m_seq[q].cisd.retracePrice;
      m_st.retraced++;
      TerminalSeq(q, CONN_RETRACEMENT, m_seq[q].retraceTime);
     }
   else if(m_seq[q].cisd.endTime != 0)
     {
      m_st.completed++;
      TerminalSeq(q, CONN_COMPLETED, closeTime);
     }
  }

//+------------------------------------------------------------------+
int CSMCConnection::ProcessM1Window(const MqlRates &r[], const int size, const datetime horizon)
  {
   int n = 0;
   for(int i = size - 1; i >= 0; i--)
     {
      if(r[i].time <= m_lastM1)
         continue;
      if(r[i].time + 60 > horizon)
         break;
      if(ProcessM1Bar(r[i]))
         n++;
     }
   return n;
  }

int CSMCConnection::ProcessCISDWindow(const MqlRates &r[], const int size, const datetime horizon)
  {
   int n = 0;
   for(int i = size - 1; i >= 0; i--)
     {
      if(r[i].time <= m_lastCISD)
         continue;
      if(r[i].time + m_cisdPS > horizon || r[i].time + m_cisdPS > m_lastM1 + 60)
         break;                                          // OB / retest knowledge must cover the candle
      if(ProcessCISDBar(r[i]))
         n++;
     }
   return n;
  }

//+------------------------------------------------------------------+
bool CSMCConnection::Get(const int idx, SConnSetup &out) const
  {
   if(idx < 0 || idx >= ArraySize(m_set))
      return false;
   out = m_set[idx];
   return true;
  }

int CSMCConnection::FindSetup(const long setupId) const
  {
   for(int k = ArraySize(m_set) - 1; k >= 0; k--)
      if(m_set[k].id == setupId)
         return k;
   return -1;
  }

bool CSMCConnection::GetSeq(const int idx, SConnSeq &out) const
  {
   if(idx < 0 || idx >= ArraySize(m_seq))
      return false;
   out = m_seq[idx];
   return true;
  }

//--- count first, then fill: one allocation instead of one per match
int CSMCConnection::SeqsOfSetup(const long setupId, SConnSeq &out[]) const
  {
   int total = ArraySize(m_seq), n = 0;
   for(int q = 0; q < total; q++)
      if(m_seq[q].setupId == setupId)
         n++;
   ArrayResize(out, n, 16);
   int at = 0;
   for(int q = 0; q < total && at < n; q++)
      if(m_seq[q].setupId == setupId)
         out[at++] = m_seq[q];
   return n;
  }

bool CSMCConnection::GetHit(const int idx, SConnCISDHit &out) const
  {
   if(idx < 0 || idx >= ArraySize(m_hits))
      return false;
   out = m_hits[idx];
   return true;
  }

//--- count first, then fill: one allocation instead of one per match
int CSMCConnection::HitsOfSeq(const long seqId, SConnCISDHit &out[]) const
  {
   int total = ArraySize(m_hits), n = 0;
   for(int k = 0; k < total; k++)
      if(m_hits[k].seqId == seqId)
         n++;
   ArrayResize(out, n, 16);
   int at = 0;
   for(int k = 0; k < total && at < n; k++)
      if(m_hits[k].seqId == seqId)
         out[at++] = m_hits[k];
   return n;
  }

//--- count first, then fill: one allocation instead of one per match
int CSMCConnection::HitsOfSetup(const long setupId, SConnCISDHit &out[]) const
  {
   int total = ArraySize(m_hits), n = 0;
   for(int k = 0; k < total; k++)
      if(m_hits[k].setupId == setupId)
         n++;
   ArrayResize(out, n, 16);
   int at = 0;
   for(int k = 0; k < total && at < n; k++)
      if(m_hits[k].setupId == setupId)
         out[at++] = m_hits[k];
   return n;
  }

int CSMCConnection::ActiveCount(void) const
  {
   int n = 0;
   for(int q = 0; q < ArraySize(m_seq); q++)
      if(SMC_ConnMonitoring(m_seq[q].state))
         n++;
   return n;
  }

bool CSMCConnection::GetEvent(const int idx, SConnEvent &e) const
  {
   if(idx < 0 || idx >= ArraySize(m_events))
      return false;
   e = m_events[idx];
   return true;
  }

string CSMCConnection::StatsText(void) const
  {
   int waiting = 0, dead = 0;
   for(int k = 0; k < ArraySize(m_set); k++)
     {
      if(m_set[k].state == CONN_INVALIDATED)        dead++;
      else if(m_set[k].state != CONN_OB_RETESTED)   waiting++;
     }
   return StringFormat("source std/zorder=%s/%s retest=%s cisd=%s | OBs=%d (waiting %d, invalidated %d) | "
                       "retests=%d (ignored %d) sequences=%d activated=%d sweep=%d | CONFIRMED std/zorder=%d/%d bull/bear=%d/%d | "
                       "CISDs=%d (extra %d) | retraced=%d completed=%d | invalidated beforeCISD/monitoring=%d/%d expired=%d | "
                       "active now=%d max concurrent=%d",
                       m_s.useStandard ? "ON" : "OFF", m_s.useZOrder ? "ON" : "OFF",
                       m_s.multiRetest ? "MULTI" : "SINGLE", m_s.multiCISD ? "MULTI" : "SINGLE",
                       m_st.registered, waiting, dead, m_st.retests, m_st.retestsIgnored, m_st.sequences,
                       m_st.activated, m_st.sweepStage, m_st.confirmedStd, m_st.confirmedZ, m_st.confirmedBull,
                       m_st.confirmedBear, m_st.cisdHits, m_st.multiExtra, m_st.retraced, m_st.completed,
                       m_st.invalidatedBeforeRetest, m_st.invalidatedMonitoring, m_st.expired,
                       ActiveCount(), m_st.maxConcurrent) +
          (m_s.stopOnMitigation ? " | mitigation stops CISD=ON" : "") +
          (m_s.trendFilter ? StringFormat(" | trend filter=ON (%d bars, %.2f ATR), rejected %d",
                                          m_s.trendBars, m_s.trendATRMult, m_st.trendFiltered) : "");
  }

#endif // SMC_CONNECT_ENGINE_MQH
