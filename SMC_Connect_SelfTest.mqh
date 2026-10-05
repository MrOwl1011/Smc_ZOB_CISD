//+------------------------------------------------------------------+
//|                                         SMC_Connect_SelfTest.mqh |
//|  SPDX-License-Identifier: MIT                                    |
//|  https://github.com/MrOwl1011/Smc_ZOB_CISD                       |
//|  Verification of the HTF OB -> LTF CISD workflow on real data.   |
//|   - live (bar-by-bar, multi-timeframe) == batch rebuild          |
//|   - truncated horizons: nothing decided earlier ever changes     |
//|   - retest = M1 re-entry into a live OB zone, CISD start aligned |
//|   - OB invalidation stops every sequence of that OB              |
//|   - CISD candle series may begin BEFORE the retest, but the      |
//|     confirmation close never may                                 |
//|   - Single / Multi RETEST x Single / Multi CISD (4 combinations) |
//|   - OB source filters, direction matching, concurrency           |
//+------------------------------------------------------------------+
#ifndef SMC_CONNECT_SELFTEST_MQH
#define SMC_CONNECT_SELFTEST_MQH

#include "SMC_Connect_Engine.mqh"

class CSMCConnSelfTest
  {
private:
   int               m_pass;
   int               m_fail;
   string            m_group;

   void              Check(const bool cond, const string what);
   int               IndexOf(const MqlRates &r[], const int n, const datetime t) const;
   int               FirstAtOrAfter(const MqlRates &r[], const int n, const datetime t) const;
   bool              SameSetup(const SConnSetup &a, const SConnSetup &b) const;
   bool              SameSeq(const SConnSeq &a, const SConnSeq &b) const;
   void              Build(CSMCConnection &c, const SConnSettings &s, CSMCDetector *stdDet, CSMCDetector *zDet,
                           const MqlRates &m1[], const int n1, const MqlRates &cr[], const int nc, const datetime horizon);
   int               MaxCISDPerSeq(const CSMCConnection &c) const;
   int               MaxSeqPerOB(const CSMCConnection &c) const;

public:
   bool              Verify(const CSMCConnection &live, CSMCDetector *stdDet, CSMCDetector *zDet);
  };

//+------------------------------------------------------------------+
void CSMCConnSelfTest::Check(const bool cond, const string what)
  {
   if(cond)
      m_pass++;
   else
     {
      m_fail++;
      PrintFormat("[SMC-CONN][TEST] FAIL  %s: %s", m_group, what);
     }
  }

int CSMCConnSelfTest::IndexOf(const MqlRates &r[], const int n, const datetime t) const
  {
   int lo = 0, hi = n - 1;
   while(lo <= hi)
     {
      int mid = (lo + hi) / 2;
      if(r[mid].time == t) return mid;
      if(r[mid].time > t)  lo = mid + 1;
      else                 hi = mid - 1;
     }
   return -1;
  }

//--- series-ordered array: index of the OLDEST bar with time >= t
int CSMCConnSelfTest::FirstAtOrAfter(const MqlRates &r[], const int n, const datetime t) const
  {
   int lo = 0, hi = n - 1, res = -1;
   while(lo <= hi)
     {
      int mid = (lo + hi) / 2;
      if(r[mid].time >= t) { res = mid; lo = mid + 1; }
      else                   hi = mid - 1;
     }
   return res;
  }

bool CSMCConnSelfTest::SameSetup(const SConnSetup &a, const SConnSetup &b) const
  {
   return a.id == b.id && a.kind == b.kind && a.obId == b.obId && a.dir == b.dir && a.availTime == b.availTime &&
          a.state == b.state && a.retestCount == b.retestCount && a.seqCount == b.seqCount &&
          a.cisdCount == b.cisdCount && a.retestTime == b.retestTime && a.cisdStartTime == b.cisdStartTime &&
          a.endTime == b.endTime && MathAbs(a.top - b.top) < 1e-10 && MathAbs(a.bottom - b.bottom) < 1e-10;
  }

bool CSMCConnSelfTest::SameSeq(const SConnSeq &a, const SConnSeq &b) const
  {
   if(a.id != b.id || a.setupId != b.setupId || a.obId != b.obId || a.dir != b.dir || a.retestNo != b.retestNo ||
      a.retestTime != b.retestTime || MathAbs(a.retestPrice - b.retestPrice) > 1e-10 ||
      a.cisdStartTime != b.cisdStartTime || a.activatedTime != b.activatedTime || a.state != b.state ||
      a.cisdBars != b.cisdBars || a.hasCISD != b.hasCISD || a.cisdId != b.cisdId || a.cisdCount != b.cisdCount ||
      a.sweepTime != b.sweepTime || a.retraceTime != b.retraceTime || a.endTime != b.endTime)
      return false;
   if(a.hasCISD && (!SMC_CISDSameSetup(a.cisd, b.cisd) || a.cisd.confirmTime != b.cisd.confirmTime))
      return false;
   return true;
  }

void CSMCConnSelfTest::Build(CSMCConnection &c, const SConnSettings &s, CSMCDetector *stdDet, CSMCDetector *zDet,
                             const MqlRates &m1[], const int n1, const MqlRates &cr[], const int nc, const datetime horizon)
  {
   c.Init(s, stdDet, zDet);
   c.SyncOBs();
   MqlRates obh[];
   ArraySetAsSeries(obh, true);
   int nob = CopyRates(_Symbol, s.obTF, 1, s.trendBars + s.trendATRPeriod + 3000, obh);
   if(nob > 0)
      c.ProcessOBWindow(obh, nob);
   c.ProcessM1Window(m1, n1, horizon);
   c.ProcessCISDWindow(cr, nc, horizon);
  }

int CSMCConnSelfTest::MaxCISDPerSeq(const CSMCConnection &c) const
  {
   int mx = 0;
   SConnSeq q;
   for(int i = 0; i < c.SeqCount(); i++)
      if(c.GetSeq(i, q))
         mx = MathMax(mx, q.cisdCount);
   return mx;
  }

int CSMCConnSelfTest::MaxSeqPerOB(const CSMCConnection &c) const
  {
   int mx = 0;
   SConnSetup s;
   for(int i = 0; i < c.Count(); i++)
      if(c.Get(i, s))
         mx = MathMax(mx, s.seqCount);
   return mx;
  }

//+------------------------------------------------------------------+
bool CSMCConnSelfTest::Verify(const CSMCConnection &live, CSMCDetector *stdDet, CSMCDetector *zDet)
  {
   m_pass = 0;
   m_fail = 0;
   SConnSettings s;
   live.GetSettings(s);
   s.logLevel = SMC_LOG_OFF;
   int cps = PeriodSeconds(s.cisdTF);
   m_group = StringFormat("HTF %s OB -> LTF %s CISD (chart %s)", SMC_TFText(s.obTF), SMC_TFText(s.cisdTF),
                          SMC_TFText((ENUM_TIMEFRAMES)_Period));

   Check(SMC_ConnAlignUp(D'2026.08.20 14:32', 300) == D'2026.08.20 14:35' &&
         SMC_ConnAlignUp(D'2026.08.20 14:30', 300) == D'2026.08.20 14:30' &&
         SMC_ConnAlignUp(D'2026.08.20 14:32', 3600) == D'2026.08.20 15:00', "retest -> first CISD candle alignment");

   if(live.LastM1Time() == 0 || live.LastCISDTime() == 0)
     {
      PrintFormat("[SMC-CONN][TEST] SKIP  %s: nothing processed", m_group);
      return false;
     }

   //--- the exact candles the live workflow consumed
   int m1From = iBarShift(_Symbol, PERIOD_M1, s.windowStart, false);
   int m1To   = iBarShift(_Symbol, PERIOD_M1, live.LastM1Time(), true);
   MqlRates m1[];
   ArraySetAsSeries(m1, true);
   int n1 = (m1From >= 0 && m1To >= 0) ? CopyRates(_Symbol, PERIOD_M1, m1To, m1From - m1To + 1, m1) : 0;
   int cFrom = iBarShift(_Symbol, s.cisdTF, s.windowStart, false) + s.warmupBars + 5;
   int cTo   = iBarShift(_Symbol, s.cisdTF, live.LastCISDTime(), true);
   MqlRates cr[];
   ArraySetAsSeries(cr, true);
   int nc = (cTo >= 0 && cFrom > cTo) ? CopyRates(_Symbol, s.cisdTF, cTo, cFrom - cTo + 1, cr) : 0;
   Check(n1 > 0 && nc > 0 && m1[0].time == live.LastM1Time() && cr[0].time == live.LastCISDTime(),
         StringFormat("history available (M1 %d, %s %d)", n1, SMC_TFText(s.cisdTF), nc));
   if(n1 <= 0 || nc <= 0)
      return false;

   datetime far = D'3000.01.01';
   CSMCConnection full;
   Build(full, s, stdDet, zDet, m1, n1, cr, nc, far);

   //--- 1. historical rebuild == real-time processing
   int mismSet = 0, mismSeq = 0;
   SConnSetup a, b;
   SConnSeq qa, qb;
   for(int k = 0; k < MathMin(full.Count(), live.Count()); k++)
      if(full.Get(k, a) && live.Get(k, b) && !SameSetup(a, b))
         mismSet++;
   for(int k = 0; k < MathMin(full.SeqCount(), live.SeqCount()); k++)
      if(full.GetSeq(k, qa) && live.GetSeq(k, qb) && !SameSeq(qa, qb))
        {
         if(mismSeq++ == 0)
            PrintFormat("[SMC-CONN][TEST] first sequence difference #%I64d (OB #%I64d R%d): batch %s act %s bars %d cisd %d confirm %s end %s"
                        " | live %s act %s bars %d cisd %d confirm %s end %s",
                        qa.id, qa.obId, qa.retestNo, SMC_ConnStateText(qa.state), TimeToString(qa.activatedTime),
                        qa.cisdBars, qa.cisdCount, TimeToString(qa.cisd.confirmTime), TimeToString(qa.endTime),
                        SMC_ConnStateText(qb.state), TimeToString(qb.activatedTime), qb.cisdBars, qb.cisdCount,
                        TimeToString(qb.cisd.confirmTime), TimeToString(qb.endTime));
        }
   PrintFormat("[SMC-CONN][TEST] coverage: M1 %s..%s (%d), %s %s..%s (%d); live processed M1 %s, CISD %s; window from %s",
               TimeToString(m1[n1 - 1].time), TimeToString(m1[0].time), n1, SMC_TFText(s.cisdTF),
               TimeToString(cr[nc - 1].time), TimeToString(cr[0].time), nc, TimeToString(live.LastM1Time()),
               TimeToString(live.LastCISDTime()), TimeToString(s.windowStart));
   Check(full.Count() == live.Count() && mismSet == 0,
         StringFormat("live %d OBs vs batch %d, %d differ", live.Count(), full.Count(), mismSet));
   Check(full.SeqCount() == live.SeqCount() && mismSeq == 0 && full.HitCount() == live.HitCount(),
         StringFormat("live %d sequences / %d CISDs vs batch %d / %d, %d differ",
                      live.SeqCount(), live.HitCount(), full.SeqCount(), full.HitCount(), mismSeq));

   //--- 2. truncated horizons: earlier decisions never change
   datetime hz0 = (datetime)(cr[0].time + cps);
   int changed = 0, missing = 0;
   double fracs[] = {0.5, 0.75, 0.9};
   for(int f = 0; f < ArraySize(fracs); f++)
     {
      datetime H = (datetime)(s.windowStart + (long)((hz0 - s.windowStart) * fracs[f]));
      CSMCConnection part;
      Build(part, s, stdDet, zDet, m1, n1, cr, nc, H);
      for(int k = 0; k < part.SeqCount(); k++)
        {
         if(!part.GetSeq(k, qa) || !full.GetSeq(k, qb) || qa.id != qb.id)
           { changed++; continue; }
         if(qa.retestTime != qb.retestTime || qa.cisdStartTime != qb.cisdStartTime || qa.retestNo != qb.retestNo)
            changed++;
         if(qa.hasCISD && (!qb.hasCISD || qa.cisdId != qb.cisdId || qa.cisd.confirmTime != qb.cisd.confirmTime))
            changed++;
         if(SMC_ConnTerminal(qa.state) && (qa.state != qb.state || qa.endTime != qb.endTime))
            changed++;
        }
      for(int k = 0; k < full.SeqCount(); k++)
        {
         full.GetSeq(k, qb);
         bool have = (k < part.SeqCount() && part.GetSeq(k, qa));
         if(qb.retestTime + 60 <= H && (!have || qa.retestTime != qb.retestTime))
            missing++;
         if(qb.hasCISD && qb.cisd.confirmTime + cps <= H && (!have || !qa.hasCISD))
            missing++;
        }
     }
   Check(changed == 0, StringFormat("%d retests / CISDs / final states changed when later data was added", changed));
   Check(missing == 0, StringFormat("%d retests / CISDs appeared retroactively", missing));

   //--- 3. rules re-checked against raw candles
   CSMCCISDEngine refEng;                                 // unrestricted CISD engine for comparison
   SCISDSettings cs = s.cisd;
   cs.timeframe = s.cisdTF;
   cs.activationTime = 0;
   cs.dirFilter = 0;
   cs.activationMode = CISD_ACT_ALL_AFTER;
   cs.logLevel = SMC_LOG_OFF;
   cs.maxStored = 1000000;
   refEng.Init(cs);
   refEng.ProcessWindow(cr, nc);

   int badRetest = 0, badStart = 0, badCISD = 0, badDir = 0, badDead = 0, badOrder = 0;
   int seqCount = 0, confStd = 0, confZ = 0, oldIgnored = 0, oppIgnored = 0, preRetestSeries = 0, deadOB = 0;
   SCISD c;
   SConnCISDHit hits[];
   for(int k = 0; k < full.SeqCount(); k++)
     {
      full.GetSeq(k, qa);
      seqCount++;
      int si = full.FindSetup(qa.setupId);
      if(si < 0 || !full.Get(si, a))
        { badRetest++; continue; }

      //--- the retest is a real M1 re-entry into the zone while the OB was alive
      int ri = IndexOf(m1, n1, qa.retestTime);
      bool ok = (ri >= 0 && m1[ri].low <= a.top && m1[ri].high >= a.bottom && qa.retestTime >= a.availTime);
      if(ri >= 0 && ri + 1 < n1 && m1[ri + 1].time >= a.availTime &&
         m1[ri + 1].low <= a.top && m1[ri + 1].high >= a.bottom)
         ok = false;                                      // previous candle was already inside: not a new retest
      if(a.deadKnown > 0 && a.deadKnown <= qa.retestTime)
         ok = false;
      if(!ok) badRetest++;

      if(qa.cisdStartTime != SMC_ConnAlignUp(qa.retestTime, cps) || qa.cisdStartTime < qa.retestTime)
         badStart++;
      if(qa.activatedTime > 0)
        {
         int fi = FirstAtOrAfter(cr, nc, qa.cisdStartTime);
         if(fi < 0 || cr[fi].time != qa.activatedTime)
            badStart++;
        }

      //--- OB invalidation is absolute
      if(a.deadKnown > 0)
        {
         deadOB++;
         if(a.deadKnown < (datetime)(cr[0].time + cps) && !SMC_ConnTerminal(qa.state))
            badDead++;                                    // a dead OB may not keep a live sequence
         if(qa.hasCISD && qa.cisd.confirmTime + cps > a.deadKnown)
            badDead++;                                    // confirmed after the OB was known dead
         if(qa.retraceTime > 0 && qa.retraceTime >= a.deadKnown)
            badDead++;                                    // retracement / entry after the OB died
        }

      datetime endT = qa.hasCISD ? qa.cisd.confirmTime : (qa.endTime > 0 ? qa.endTime : cr[0].time);
      for(int j = 0; j < refEng.Count(); j++)
        {
         if(!refEng.Get(j, c) || !SMC_CISDConfirmedState(c.state))
            continue;
         if(c.dir == qa.dir && c.confirmTime >= a.availTime && c.confirmTime < qa.cisdStartTime)
            oldIgnored++;
         if(qa.activatedTime > 0 && c.dir != qa.dir && c.confirmTime >= qa.cisdStartTime && c.confirmTime <= endT)
            oppIgnored++;
        }

      //--- every CISD of this sequence
      full.HitsOfSeq(qa.id, hits);
      if(ArraySize(hits) != qa.cisdCount)
         badCISD++;
      for(int h = 0; h < ArraySize(hits); h++)
        {
         if(hits[h].dir != qa.dir || hits[h].setupId != qa.setupId || hits[h].obId != qa.obId)
            badDir++;
         if(h > 0 && hits[h].confirmTime <= hits[h - 1].confirmTime)
            badOrder++;
         bool cok = (hits[h].confirmTime >= qa.cisdStartTime &&
                     (!hits[h].cisd.hasSweep || hits[h].cisd.sweepTime >= a.availTime) &&
                     (!s.cisd.useSweep || hits[h].cisd.hasSweep));
         int ci = IndexOf(cr, nc, hits[h].confirmTime);
         if(ci < 0 || qa.dir * (cr[ci].close - hits[h].cisd.level) <= 0)
            cok = false;
         if(!cok) badCISD++;
         if(hits[h].cisd.seriesStartTime < qa.cisdStartTime)
            preRetestSeries++;                            // series began before the retest: allowed
         if(hits[h].kind == CONN_KIND_ZORDER) confZ++;
         else                                 confStd++;
        }
     }
   Check(badRetest == 0, StringFormat("%d retests are not a valid M1 re-entry into a live OB", badRetest));
   Check(badStart == 0, StringFormat("%d CISD start / activation times are wrong", badStart));
   Check(badDir == 0, StringFormat("%d CISDs are attached to the wrong OB / direction", badDir));
   Check(badOrder == 0, StringFormat("%d CISDs of a sequence are out of order", badOrder));
   Check(badCISD == 0, StringFormat("%d CISDs confirmed before the retest or with an invalid close", badCISD));
   Check(badDead == 0, StringFormat("%d sequences kept running / confirmed after their OB was invalidated", badDead));
   //--- coverage only: with the trend filter on, the sample may legitimately contain none
   if(!s.trendFilter)
      Check(preRetestSeries > 0, StringFormat("candle series starting before the retest are used (%d)", preRetestSeries));
   else
      PrintFormat("[SMC-CONN][TEST] pre-retest series coverage skipped (trend filter on, %d seen)", preRetestSeries);

   //--- 4. Single / Multi RETEST x Single / Multi CISD
   SConnSettings base = s;
   base.useStandard = true;
   base.useZOrder   = true;
   SConnSettings srsc = base, srmc = base, mrsc = base, mrmc = base;
   srsc.multiRetest = false; srsc.multiCISD = false;
   srmc.multiRetest = false; srmc.multiCISD = true;
   mrsc.multiRetest = true;  mrsc.multiCISD = false;
   mrmc.multiRetest = true;  mrmc.multiCISD = true;
   CSMCConnection cSRSC, cSRMC, cMRSC, cMRMC;
   Build(cSRSC, srsc, stdDet, zDet, m1, n1, cr, nc, far);
   Build(cSRMC, srmc, stdDet, zDet, m1, n1, cr, nc, far);
   Build(cMRSC, mrsc, stdDet, zDet, m1, n1, cr, nc, far);
   Build(cMRMC, mrmc, stdDet, zDet, m1, n1, cr, nc, far);

   Check(MaxSeqPerOB(cSRSC) <= 1 && MaxSeqPerOB(cSRMC) <= 1,
         StringFormat("SINGLE retest: at most one sequence per OB (%d / %d)", MaxSeqPerOB(cSRSC), MaxSeqPerOB(cSRMC)));
   Check(MaxCISDPerSeq(cSRSC) <= 1 && MaxCISDPerSeq(cMRSC) <= 1,
         StringFormat("SINGLE CISD: at most one CISD per sequence (%d / %d)", MaxCISDPerSeq(cSRSC), MaxCISDPerSeq(cMRSC)));
   Check(MaxSeqPerOB(cMRSC) > 1 || MaxSeqPerOB(cMRMC) > 1,
         StringFormat("MULTI retest: some OB started several sequences (max %d)", MaxSeqPerOB(cMRMC)));
   Check(MaxCISDPerSeq(cSRMC) > 1 || MaxCISDPerSeq(cMRMC) > 1,
         StringFormat("MULTI CISD: some sequence recorded several CISDs (max %d)", MaxCISDPerSeq(cMRMC)));
   Check(cMRSC.SeqCount() >= cSRSC.SeqCount() && cMRMC.SeqCount() >= cSRMC.SeqCount(),
         "MULTI retest never produces fewer sequences than SINGLE");
   Check(cSRMC.HitCount() >= cSRSC.HitCount() && cMRMC.HitCount() >= cMRSC.HitCount(),
         "MULTI CISD never produces fewer CISDs than SINGLE");

   //--- the FIRST sequence of every OB is identical in all four modes (matched by OB id + retest number,
   //--- never by index: MULTI retest creates additional sequences in between)
   int firstDiff = 0, matched = 0;
   SConnSeq r1, r2;
   for(int k = 0; k < cSRSC.SeqCount(); k++)
     {
      if(!cSRSC.GetSeq(k, r1))
         continue;
      for(int mode = 0; mode < 3; mode++)
        {
         bool found = false;
         int cnt = (mode == 0) ? cSRMC.SeqCount() : (mode == 1 ? cMRSC.SeqCount() : cMRMC.SeqCount());
         for(int j = 0; j < cnt && !found; j++)
           {
            bool got = (mode == 0) ? cSRMC.GetSeq(j, r2) : (mode == 1 ? cMRSC.GetSeq(j, r2) : cMRMC.GetSeq(j, r2));
            if(!got || r2.obId != r1.obId || r2.kind != r1.kind || r2.retestNo != r1.retestNo)
               continue;
            found = true;
            matched++;
            if(r2.retestTime != r1.retestTime || r2.cisdStartTime != r1.cisdStartTime ||
               r2.activatedTime != r1.activatedTime)
               firstDiff++;
            if(mode == 1 && r1.hasCISD != r2.hasCISD)     // MR+SC keeps the same first CISD as SR+SC
               firstDiff++;
           }
         if(!found)
            firstDiff++;
        }
     }
   Check(firstDiff == 0, StringFormat("%d first sequences differ between modes (%d matched)", firstDiff, matched));

   //--- 5. OB source filters
   SConnSettings sZOnly = base, sOBOnly = base;
   sZOnly.useStandard = false;
   sOBOnly.useZOrder  = false;
   CSMCConnection zOnly, obOnly;
   Build(zOnly, sZOnly, stdDet, zDet, m1, n1, cr, nc, far);
   Build(obOnly, sOBOnly, stdDet, zDet, m1, n1, cr, nc, far);
   int badKind = 0;
   for(int k = 0; k < zOnly.Count(); k++)
      if(zOnly.Get(k, a) && a.kind != CONN_KIND_ZORDER)
         badKind++;
   for(int k = 0; k < obOnly.Count(); k++)
      if(obOnly.Get(k, a) && a.kind != CONN_KIND_STANDARD)
         badKind++;
   Check(badKind == 0, StringFormat("%d setups use the wrong Order Block source", badKind));
   Check(zOnly.Count() + obOnly.Count() == cSRSC.Count(),
         StringFormat("both sources (%d) = ZOrder only (%d) + OB only (%d)", cSRSC.Count(), zOnly.Count(), obOnly.Count()));

   //--- 6. option: mitigation stops the CISD search (checked on MULTI/MULTI, where it matters most)
   SConnSettings sMitOff = mrmc, sMitOn = mrmc;
   sMitOff.stopOnMitigation = false;
   sMitOn.stopOnMitigation  = true;
   CSMCConnection mitOff, mitOn;
   Build(mitOff, sMitOff, stdDet, zDet, m1, n1, cr, nc, far);
   Build(mitOn, sMitOn, stdDet, zDet, m1, n1, cr, nc, far);
   int obPS = PeriodSeconds(s.obTF);
   int mitStopped = 0, badMitDead = 0, badMitAfter = 0, offByMit = 0, badMitM1 = 0, m1Stops = 0;
   SOrderBlock ob;
   SConnSeq mq;
   SConnCISDHit mh[];
   for(int k = 0; k < mitOn.Count(); k++)
     {
      if(!mitOn.Get(k, a))
         continue;
      CSMCDetector *det = (a.kind == CONN_KIND_ZORDER) ? zDet : stdDet;
      int oi = (det != NULL) ? det.FindById(a.obId) : -1;
      if(oi < 0 || !det.GetOB(oi, ob))
         continue;
      //--- raw M1 candles: the search must stop no later than the close of the FIRST M1 candle
      //--- (at/after the OB became available) that reached the mitigation level
      if(s.mitigationMode != SMC_MIT_OFF)
        {
         bool bull = (a.dir == SMC_DIR_BULL);
         double mid = (a.top + a.bottom) / 2.0;
         datetime firstMit = 0;
         for(int i = FirstAtOrAfter(m1, n1, a.availTime); i >= 0 && firstMit == 0; i--)
           {
            bool hit;
            if(s.mitigationMode == SMC_MIT_TOUCH)         hit = bull ? (m1[i].low <= a.top) : (m1[i].high >= a.bottom);
            else if(s.mitigationMode == SMC_MIT_MIDPOINT) hit = bull ? (m1[i].low <= mid)   : (m1[i].high >= mid);
            else                                          hit = bull ? (m1[i].low <= a.bottom) : (m1[i].high >= a.top);
            if(hit)
               firstMit = m1[i].time;
           }
         if(firstMit > 0 && (a.deadKnown == 0 || a.deadKnown > (datetime)(firstMit + 60)))
            badMitM1++;                                    // kept searching after an M1 candle reached the level
         if(a.mitM1Time > 0 && a.mitM1Time != firstMit)
            badMitM1++;                                    // recorded the wrong M1 mitigation candle
         if(a.mitM1Time > 0)
            m1Stops++;
        }
      if(ob.mitigatedTime > 0)
        {
         datetime mitKnown = (datetime)(ob.mitigatedTime + obPS);
         if(a.deadKnown == 0 || a.deadKnown > mitKnown)
            badMitDead++;                                  // mitigation must end the search at its candle close
         if(a.deadByMitigation)
            mitStopped++;
        }
      if(a.deadKnown == 0)
         continue;
      //--- nothing may start, confirm or retrace after the stop time
      for(int q = 0; q < mitOn.SeqCount(); q++)
        {
         if(!mitOn.GetSeq(q, mq) || mq.setupId != a.id)
            continue;
         if(mq.retestTime >= a.deadKnown)
            badMitAfter++;
         mitOn.HitsOfSeq(mq.id, mh);
         for(int h = 0; h < ArraySize(mh); h++)
            if(mh[h].confirmTime + cps > a.deadKnown || (mh[h].retraceTime > 0 && mh[h].retraceTime >= a.deadKnown))
               badMitAfter++;
        }
     }
   for(int k = 0; k < mitOff.Count(); k++)
      if(mitOff.Get(k, a) && a.deadByMitigation)
         offByMit++;
   Check(badMitDead == 0, StringFormat("mitigation stops CISD ON: %d mitigated OBs kept searching past the mitigation close", badMitDead));
   Check(badMitAfter == 0, StringFormat("mitigation stops CISD ON: %d retests / CISDs / entries after the stop", badMitAfter));
   Check(badMitM1 == 0, StringFormat("mitigation stops CISD ON: %d OBs not stopped at the first M1 candle reaching the level", badMitM1));
   Check(m1Stops > 0, StringFormat("mitigation stops CISD ON: stops detected on M1 candles (%d)", m1Stops));
   Check(offByMit == 0, StringFormat("mitigation stops CISD OFF: %d OBs stopped by mitigation", offByMit));
   Check(mitOn.SeqCount() <= mitOff.SeqCount() && mitOn.HitCount() <= mitOff.HitCount(),
         StringFormat("mitigation stops CISD ON never adds sequences / CISDs (%d/%d vs %d/%d)",
                      mitOn.SeqCount(), mitOn.HitCount(), mitOff.SeqCount(), mitOff.HitCount()));
   Check(mitStopped > 0, StringFormat("mitigation stops CISD ON: OBs stopped by mitigation (%d)", mitStopped));

   //--- 7. trend filter: every accepted CISD must satisfy the rule, recomputed from raw candles
   MqlRates obr[];
   ArraySetAsSeries(obr, true);
   int nob = CopyRates(_Symbol, s.obTF, 1, s.trendBars + s.trendATRPeriod + 3000, obr);
   if(nob > s.trendBars + s.trendATRPeriod + 10)
     {
      SConnSettings sOff = mrmc, sOn = mrmc;
      sOff.trendFilter = false;
      sOn.trendFilter  = true;
      if(sOn.trendBars < 1)      { sOn.trendBars = 20; sOff.trendBars = 20; }
      if(sOn.trendATRPeriod < 1) { sOn.trendATRPeriod = 14; sOff.trendATRPeriod = 14; }
      if(sOn.trendATRMult <= 0)  { sOn.trendATRMult = 1.5; sOff.trendATRMult = 1.5; }
      CSMCConnection cOff, cOn;
      Build(cOff, sOff, stdDet, zDet, m1, n1, cr, nc, far);
      Build(cOn, sOn, stdDet, zDet, m1, n1, cr, nc, far);

      int obPS = PeriodSeconds(s.obTF);
      int badPass = 0, checked = 0;
      SConnCISDHit th;
      for(int k = 0; k < cOn.HitCount(); k++)
        {
         if(!cOn.GetHit(k, th))
            continue;
         //--- newest OB candle closed at the confirmation
         int last = -1;
         for(int j = 0; j < nob; j++)
            if((datetime)(obr[j].time + obPS) <= th.confirmTime)
              { last = j; break; }
         if(last < 0 || last + sOn.trendBars >= nob || last + sOn.trendATRPeriod >= nob)
            continue;
         double tr = 0.0;
         for(int j = 0; j < sOn.trendATRPeriod; j++)
           {
            double hh = obr[last + j].high, ll = obr[last + j].low, pc = obr[last + j + 1].close;
            tr += MathMax(hh - ll, MathMax(MathAbs(hh - pc), MathAbs(ll - pc)));
           }
         double atr = tr / sOn.trendATRPeriod;
         if(atr <= 0.0)
            continue;
         checked++;
         double sc = (obr[last].close - obr[last + sOn.trendBars].close) / atr;
         bool ok = (MathAbs(sc) >= sOn.trendATRMult) &&
                   ((th.dir == SMC_DIR_BULL) ? sc > 0 : sc < 0);
         if(!ok)
            badPass++;
        }
      SConnStats stOn;
      cOn.GetStats(stOn);
      Check(badPass == 0, StringFormat("trend filter: %d of %d accepted CISDs break the rule", badPass, checked));
      Check(cOn.HitCount() <= cOff.HitCount(),
            StringFormat("trend filter never adds CISDs (%d on vs %d off)", cOn.HitCount(), cOff.HitCount()));
      Check(cOn.HitCount() + stOn.trendFiltered >= cOff.HitCount(),
            StringFormat("trend filter accounts for every rejected CISD (%d + %d vs %d)",
                         cOn.HitCount(), stOn.trendFiltered, cOff.HitCount()));
      Check(checked > 0, StringFormat("trend filter: accepted CISDs verified against raw candles (%d)", checked));
      PrintFormat("[SMC-CONN][TEST] trend filter: %d CISDs with filter vs %d without (rejected %d), %d verified",
                  cOn.HitCount(), cOff.HitCount(), stOn.trendFiltered, checked);
     }

   SConnStats st, stSR, stMR;
   full.GetStats(st);
   cSRSC.GetStats(stSR);
   cMRMC.GetStats(stMR);
   Check(seqCount > 0, "retest sequences were created");
   Check(confStd + confZ > 0, "HTF OB + LTF CISD setups confirmed");
   if(st.retests >= 5)
      Check(st.maxConcurrent >= 2, StringFormat("independent sequences ran concurrently (max %d)", st.maxConcurrent));

   PrintFormat("[SMC-CONN][TEST] %s %s: %d OBs, %d sequences (%d retests, %d ignored), CISDs std %d / zorder %d, "
               "dead OBs %d, series before retest %d | old CISDs ignored %d, opposite ignored %d | %d checks passed, %d failed",
               m_group, m_fail == 0 ? "PASSED" : "FAILED", full.Count(), full.SeqCount(), st.retests, st.retestsIgnored,
               confStd, confZ, deadOB, preRetestSeries, oldIgnored, oppIgnored, m_pass, m_fail);
   PrintFormat("[SMC-CONN][TEST] modes: SR+SC %d seq / %d CISD | SR+MC %d / %d | MR+SC %d / %d | MR+MC %d / %d "
               "(max seq per OB %d, max CISD per sequence %d)",
               cSRSC.SeqCount(), cSRSC.HitCount(), cSRMC.SeqCount(), cSRMC.HitCount(), cMRSC.SeqCount(), cMRSC.HitCount(),
               cMRMC.SeqCount(), cMRMC.HitCount(), MaxSeqPerOB(cMRMC), MaxCISDPerSeq(cMRMC));
   PrintFormat("[SMC-CONN][TEST] mitigation stops CISD (MR+MC): OFF %d seq / %d CISD | ON %d seq / %d CISD (%d OBs stopped by mitigation, %d on an M1 candle)",
               mitOff.SeqCount(), mitOff.HitCount(), mitOn.SeqCount(), mitOn.HitCount(), mitStopped, m1Stops);
   return m_fail == 0;
  }

#endif // SMC_CONNECT_SELFTEST_MQH
