//+------------------------------------------------------------------+
//|                                              SMC_OB_SelfTest.mqh |
//|  Deterministic self tests for the detection engine.              |
//|                                                                  |
//|  Synthetic candles (hand-computed expectations):                 |
//|   - bullish BOS -> displacement -> OB -> FVG -> retest ->        |
//|     mitigation -> invalidation                                   |
//|   - mirrored bearish scenario                                    |
//|   - weak displacement rejected                                   |
//|   - FVG without BOS never creates an OB                          |
//|   - FVG completed by the bar after BOS (confluence / required)   |
//|   - second BOS from the same leg -> duplicate rejected           |
//|   - no OB visible before the BOS candle closes (prefix test)     |
//|  Real chart data:                                                |
//|   - batch history scan == live bar-by-bar processing             |
//|   - truncated-history runs == full run (no repaint / look-ahead) |
//|   - structural invariants                                        |
//+------------------------------------------------------------------+
#ifndef SMC_OB_SELFTEST_MQH
#define SMC_OB_SELFTEST_MQH

#include "SMC_OB_Engine.mqh"

#define SMC_T_BASE  D'2024.01.01 00:00'
#define SMC_T_STEP  3600

bool SMC_SameFull(const SOrderBlock &a, const SOrderBlock &b)
  {
   return SMC_SameIdentity(a, b, true) && a.state == b.state && a.retestCount == b.retestCount &&
          a.firstRetestTime == b.firstRetestTime && a.mitigatedTime == b.mitigatedTime &&
          a.invalidatedTime == b.invalidatedTime && a.endTime == b.endTime && a.fvgLate == b.fvgLate;
  }

class CSMCSelfTest
  {
private:
   int               m_pass;
   int               m_fail;
   string            m_group;
   //--- chronological indices of the named scenario candles
   int               iB, iC, iE, iF, iG, iH, iI, iJ, iL, iM;

   void              Check(const bool cond, const string what);
   bool              Near(const double a, const double b) const { return MathAbs(a - b) < 1e-8; }
   void              Add(MqlRates &c[], const double o, const double h, const double l, const double cl);
   void              Scenario(const int variant, MqlRates &c[]);
   void              Mirror(MqlRates &c[]);
   void              ToSeries(const MqlRates &c[], MqlRates &s[], const int dropNewest = 0);
   void              Settings(SSMCSettings &s);
   int               RunDetector(CSMCDetector &d, const SSMCSettings &s, const MqlRates &chron[], const int lastIndex);
   bool              FirstOB(const CSMCDetector &d, SOrderBlock &o);

   void              TestDirectional(const bool bearish);
   void              TestNoLookAhead(void);
   void              TestWeakDisplacement(void);
   void              TestFVGWithoutBOS(void);
   void              TestLateFVG(void);
   void              TestDuplicate(void);
   void              TestPrefixSynthetic(const bool zorder);
   void              TestRealData(const SSMCSettings &base, const int bars);

   //--- ZOrder Blocks
   void              ZSettings(SSMCSettings &s) { Settings(s); s.zoneSource = SMC_SOURCE_CANDLE_SERIES; }
   void              TestZOrderDirectional(const bool bearish);
   void              TestZOrderSeriesRules(void);
   void              TestZOrderRealData(const SSMCSettings &base, const int bars);
   void              TestCloseExtremeZones(const SSMCSettings &base, const int bars);

public:
   bool              Run(const SSMCSettings &base, const int realBars);
  };

//+------------------------------------------------------------------+
void CSMCSelfTest::Check(const bool cond, const string what)
  {
   if(cond)
      m_pass++;
   else
     {
      m_fail++;
      PrintFormat("[SMC-OB][TEST] FAIL  %s: %s", m_group, what);
     }
  }

void CSMCSelfTest::Add(MqlRates &c[], const double o, const double h, const double l, const double cl)
  {
   int n = ArraySize(c);
   ArrayResize(c, n + 1, 64);
   ZeroMemory(c[n]);
   c[n].time  = (datetime)(SMC_T_BASE + n * SMC_T_STEP);
   c[n].open  = o;
   c[n].high  = h;
   c[n].low   = l;
   c[n].close = cl;
  }

//+------------------------------------------------------------------+
//| variant 0: base  | 1: FVG completes on bar after BOS             |
//| 2: like 1 but the next bar does NOT complete the FVG             |
//| 3: base + older higher swing broken by a second bar (duplicate)  |
//| 4: base with C bullish (interrupts the red series before the OB) |
//+------------------------------------------------------------------+
void CSMCSelfTest::Scenario(const int variant, MqlRates &c[])
  {
   ArrayResize(c, 0);
   for(int k = 0; k < 20; k++)
      Add(c, 100.0, 100.5, 99.5, 100.0);                 // doji warm-up: no swings, ATR = 1.0
   if(variant == 3)
     {
      Add(c, 100.0, 103.1, 99.9, 100.2);                 // older swing high 103.1
      Add(c, 100.2, 100.4, 99.7, 100.0);
      Add(c, 100.0, 100.5, 99.6, 99.9);                  // high = filler high: filler cannot form a swing high
      for(int k = 0; k < 6; k++)
         Add(c, 100.0, 100.5, 99.5, 100.0);
     }
                                        Add(c, 100.0, 101.0,  99.6, 100.8);   // A
   iB = ArraySize(c);                   Add(c, 100.8, 102.0, 100.4, 101.5);   // B swing high 102.0
   iC = ArraySize(c);
   if(variant == 4)                     Add(c, 100.6, 101.6, 100.5, 101.4);   // C bullish: interrupts the red series
   else                                 Add(c, 101.5, 101.6, 100.5, 100.7);   // C
                                        Add(c, 100.7, 100.9,  99.8, 100.0);   // D (confirms B)
   iE = ArraySize(c);                   Add(c, 100.0, 100.2,  99.2,  99.4);   // E last bearish = OB
   iF = ArraySize(c);                   Add(c,  99.4, 101.4,  99.3, 101.3);   // F displacement
   iG = ArraySize(c);                   Add(c, 101.3, 103.2, (variant == 1 || variant == 2) ? 100.1 : 101.2, 103.0); // G BOS close > 102
   iH = ArraySize(c);
   if(variant == 3)                     Add(c, 103.0, 104.2, 102.9, 104.0);   // H2 breaks 103.1 with same leg
   else                                 Add(c, 103.0, 103.5, variant == 2 ? 101.3 : 102.4, 102.6); // H
   iI = ArraySize(c);                   Add(c, 102.6, 102.8, 101.0, 101.2);   // I
   iJ = ArraySize(c);                   Add(c, 101.2, 101.3, 100.0, 100.4);   // J first retest
                                        Add(c, 100.4, 101.5, 100.3, 101.4);   // K
   iL = ArraySize(c);                   Add(c, 101.4, 101.6,  99.6, 100.1);   // L mitigation (<= 99.7)
   iM = ArraySize(c);                   Add(c, 100.1, 100.3,  98.8,  99.0);   // M close < 99.2 invalidates
  }

void CSMCSelfTest::Mirror(MqlRates &c[])
  {
   for(int k = 0; k < ArraySize(c); k++)
     {
      double h = c[k].high, l = c[k].low;
      c[k].open  = 200.0 - c[k].open;
      c[k].close = 200.0 - c[k].close;
      c[k].high  = 200.0 - l;
      c[k].low   = 200.0 - h;
     }
  }

//--- chronological -> series order, optionally dropping the newest bars
void CSMCSelfTest::ToSeries(const MqlRates &c[], MqlRates &s[], const int dropNewest)
  {
   int n = ArraySize(c) - dropNewest;
   ArrayResize(s, MathMax(n, 0));
   for(int j = 0; j < n; j++)
      s[j] = c[n - 1 - j];
  }

void CSMCSelfTest::Settings(SSMCSettings &s)
  {
   ZeroMemory(s);
   s.swingLength        = 2;
   s.swingMinATR        = 0.5;
   s.bosMode            = SMC_BOS_CLOSE;
   s.bosBufferATR       = 0.0;
   s.atrPeriod          = 5;
   s.dispATRMult        = 1.5;
   s.dispCandleATRMult  = 1.0;
   s.dispMinBodyPct     = 60.0;
   s.dispMinRelStrength = 1.5;
   s.maxOBToBOSBars     = 5;
   s.rejectLegViolation = false;
   s.zoneMode           = SMC_ZONE_WICK;
   s.overlapMode        = SMC_OVERLAP_KEEP_ALL;
   s.overlapPct         = 50.0;
   s.maxActivePerDir    = 10;
   s.maxAgeBars         = 0;
   s.maxStored          = 1000;
   s.enableBull         = true;
   s.enableBear         = true;
   s.fvgMode            = SMC_FVG_CONFLUENCE;
   s.fvgMinATR          = 0.1;
   s.retestEnabled      = true;
   s.mitigationMode     = SMC_MIT_MIDPOINT;
   s.invalidationMode   = SMC_INV_CLOSE_BEYOND;
   s.logLevel           = SMC_LOG_OFF;
  }

//--- run on chronological bars [0 .. lastIndex]
int CSMCSelfTest::RunDetector(CSMCDetector &d, const SSMCSettings &s, const MqlRates &chron[], const int lastIndex)
  {
   d.Init(s);
   MqlRates ser[];
   ToSeries(chron, ser, ArraySize(chron) - 1 - lastIndex);
   return d.ProcessWindow(ser, ArraySize(ser));
  }

bool CSMCSelfTest::FirstOB(const CSMCDetector &d, SOrderBlock &o)
  {
   return d.GetOB(0, o);
  }

//+------------------------------------------------------------------+
void CSMCSelfTest::TestDirectional(const bool bearish)
  {
   m_group = bearish ? "Bearish OB scenario" : "Bullish OB scenario";
   MqlRates c[];
   Scenario(0, c);
   if(bearish)
      Mirror(c);
   SSMCSettings s;
   Settings(s);
   CSMCDetector d;
   RunDetector(d, s, c, ArraySize(c) - 1);

   int dir = bearish ? SMC_DIR_BEAR : SMC_DIR_BULL;
   double top    = bearish ? 100.8 : 100.2;
   double bottom = bearish ?  99.8 :  99.2;
   SSMCStats st;
   d.GetStats(st);
   SOrderBlock o;

   Check(d.OBCount() == 1, StringFormat("expected 1 OB, got %d", d.OBCount()));
   Check((bearish ? st.bosBear : st.bosBull) == 1, "one BOS in OB direction");
   Check((bearish ? st.bosBull : st.bosBear) == 1, "one opposite BOS (CHoCH at M)");
   Check(st.choch == 1, "opposite break flagged as CHoCH");
   Check(st.rejWeakCandle == 1, "opposite BOS rejected by displacement candle filter");
   if(!FirstOB(d, o))
      return;
   Check(o.dir == dir, "direction");
   Check(o.obTime == c[iE].time, "OB = last opposite candle before displacement (E)");
   Check(o.bosTime == c[iG].time && o.confirmTime == c[iG].time, "confirmed on BOS candle close (G)");
   Check(o.swingTime == c[iB].time && Near(o.bosLevel, bearish ? 98.0 : 102.0), "broken swing is B");
   Check(Near(o.top, top) && Near(o.bottom, bottom), StringFormat("zone %.2f-%.2f", o.bottom, o.top));
   Check(o.legBars == 2, "leg = 2 candles");
   Check(o.hasFVG && !o.fvgLate && o.fvgLeftTime == c[iE].time, "FVG confluence inside leg");
   Check(Near(o.fvgTop, bearish ? 99.8 : 101.2) && Near(o.fvgBottom, bearish ? 98.8 : 100.2), "FVG bounds");
   Check(o.retestCount == 2 && o.firstRetestTime == c[iJ].time, StringFormat("retests=%d, first at J", o.retestCount));
   Check(o.mitigatedTime == c[iL].time, "mitigated at 50% on L");
   Check(o.invalidatedTime == c[iM].time && o.state == SMC_OB_INVALIDATED, "invalidated by close beyond on M");
   Check(o.endTime == c[iL].time, "zone right edge frozen at mitigation");
  }

//+------------------------------------------------------------------+
void CSMCSelfTest::TestNoLookAhead(void)
  {
   m_group = "No look-ahead";
   MqlRates c[];
   Scenario(0, c);
   SSMCSettings s;
   Settings(s);
   CSMCDetector d;

   RunDetector(d, s, c, iF);
   Check(d.OBCount() == 0, "no OB before the BOS candle has closed");

   RunDetector(d, s, c, iG);
   SOrderBlock o;
   Check(d.OBCount() == 1 && FirstOB(d, o) && o.state == SMC_OB_ACTIVE && o.retestCount == 0,
         "OB exists as ACTIVE right after BOS close, future retests unknown");

   RunDetector(d, s, c, iJ);
   Check(FirstOB(d, o) && o.state == SMC_OB_RETESTED && o.mitigatedTime == 0, "at J: retested, not yet mitigated");
  }

//+------------------------------------------------------------------+
void CSMCSelfTest::TestWeakDisplacement(void)
  {
   m_group = "Displacement filter";
   MqlRates c[];
   Scenario(0, c);
   SSMCSettings s;
   Settings(s);
   s.dispATRMult = 10.0;
   CSMCDetector d;
   RunDetector(d, s, c, ArraySize(c) - 1);
   SSMCStats st;
   d.GetStats(st);
   Check(st.bosBull == 1, "BOS still detected");
   Check(d.OBCount() == 0 && st.rejWeakMove >= 1, "weak net move rejected");

   Settings(s);
   s.dispMinBodyPct = 95.0;
   RunDetector(d, s, c, ArraySize(c) - 1);
   d.GetStats(st);
   Check(d.OBCount() == 0 && st.rejSmallBody >= 1, "small body % rejected");

   Settings(s);
   s.dispMinRelStrength = 5.0;
   RunDetector(d, s, c, ArraySize(c) - 1);
   d.GetStats(st);
   Check(d.OBCount() == 0 && st.rejWeakRelative >= 1, "weak relative strength rejected");

   Settings(s);
   s.maxOBToBOSBars = 1;
   RunDetector(d, s, c, ArraySize(c) - 1);
   d.GetStats(st);
   Check(d.OBCount() == 0 && st.rejNoOpposite >= 1, "OB farther than max OB->BOS distance rejected");

   Settings(s);
   s.enableBull = false;
   RunDetector(d, s, c, ArraySize(c) - 1);
   d.GetStats(st);
   Check(d.OBCount() == 0 && st.rejDisabled == 1, "bullish detection disabled");
  }

//+------------------------------------------------------------------+
void CSMCSelfTest::TestFVGWithoutBOS(void)
  {
   m_group = "FVG alone";
   MqlRates c[];
   Scenario(0, c);
   SSMCSettings s;
   Settings(s);
   s.swingMinATR = 1000.0;     // no meaningful swings -> no BOS, but the FVG at F still exists
   CSMCDetector d;
   RunDetector(d, s, c, ArraySize(c) - 1);
   SSMCStats st;
   d.GetStats(st);
   Check(st.bosBull + st.bosBear == 0, "no BOS");
   Check(d.OBCount() == 0, "FVG never creates an OB by itself");
  }

//+------------------------------------------------------------------+
void CSMCSelfTest::TestLateFVG(void)
  {
   m_group = "FVG after BOS";
   MqlRates c[];
   Scenario(1, c);
   SSMCSettings s;
   Settings(s);
   CSMCDetector d;
   SOrderBlock o;

   //--- confluence: OB confirmed at G, FVG linked on H; zone unchanged
   RunDetector(d, s, c, iG);
   Check(d.OBCount() == 1 && FirstOB(d, o) && !o.hasFVG && o.fvgPending, "at G: OB confirmed, FVG pending");
   SOrderBlock atG = o;
   RunDetector(d, s, c, ArraySize(c) - 1);
   Check(FirstOB(d, o) && o.hasFVG && o.fvgLate && o.fvgLeftTime == c[iF].time, "FVG linked one bar later");
   Check(SMC_SameIdentity(atG, o, false), "zone identity unchanged by later FVG link");

   //--- required: candidate stays unconfirmed until the FVG completes
   s.fvgMode = SMC_FVG_REQUIRED;
   RunDetector(d, s, c, iG);
   Check(d.OBCount() == 0 && d.PendingCount() == 1, "at G: pending candidate, not a confirmed OB");
   RunDetector(d, s, c, iH);
   Check(d.OBCount() == 1 && FirstOB(d, o) && o.confirmTime == c[iH].time && o.hasFVG,
         "confirmed on H when FVG completes");

   //--- required but the FVG never forms
   Scenario(2, c);
   RunDetector(d, s, c, ArraySize(c) - 1);
   SSMCStats st;
   d.GetStats(st);
   Check(d.OBCount() == 0 && st.rejFVGMissing == 1, "rejected when required FVG does not form");
  }

//+------------------------------------------------------------------+
void CSMCSelfTest::TestDuplicate(void)
  {
   m_group = "Duplicate prevention";
   MqlRates c[];
   Scenario(3, c);
   SSMCSettings s;
   Settings(s);
   CSMCDetector d;
   RunDetector(d, s, c, iH);
   SSMCStats st;
   d.GetStats(st);
   Check(st.bosBull == 2, StringFormat("two bullish BOS from the same leg (got %d)", st.bosBull));
   Check(d.OBCount() == 1 && st.duplicates == 1, "second BOS did not duplicate the OB");
   Check(d.HasOB(SMC_DIR_BULL, c[iE].time), "OB keyed by candle time");

   //--- re-feeding already processed bars is a no-op
   MqlRates ser[];
   ToSeries(c, ser, ArraySize(c) - 1 - iH);
   int again = d.ProcessWindow(ser, ArraySize(ser));
   SSMCStats st2;
   d.GetStats(st2);
   Check(again == 0 && st2.barsProcessed == st.barsProcessed && d.OBCount() == 1, "reprocessing bars is ignored");
  }

//+------------------------------------------------------------------+
void CSMCSelfTest::TestPrefixSynthetic(const bool zorder)
  {
   m_group = zorder ? "ZOrder synthetic prefix stability" : "Synthetic prefix stability";
   MqlRates c[];
   Scenario(0, c);
   SSMCSettings s;
   if(zorder) ZSettings(s);
   else       Settings(s);
   CSMCDetector full;
   RunDetector(full, s, c, ArraySize(c) - 1);
   SOrderBlock a, b;
   for(int last = 0; last < ArraySize(c); last++)
     {
      CSMCDetector part;
      RunDetector(part, s, c, last);
      for(int k = 0; k < part.OBCount(); k++)
        {
         part.GetOB(k, a);
         int idx = full.FindById(a.id);
         Check(idx >= 0 && full.GetOB(idx, b) && SMC_SameIdentity(a, b, !a.fvgPending),
               StringFormat("OB #%I64d identical when history ends at bar %d", a.id, last));
        }
     }
  }

//+------------------------------------------------------------------+
void CSMCSelfTest::TestRealData(const SSMCSettings &base, const int bars)
  {
   m_group = StringFormat("Real data%s %s %s", base.zoneSource == SMC_SOURCE_CANDLE_SERIES ? " ZOrder" : "",
                          _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period));
   SSMCSettings s = base;
   s.logLevel  = SMC_LOG_OFF;
   s.maxStored = 1000000;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   int n = CopyRates(_Symbol, _Period, 1, bars, r);
   if(n < 300)
     {
      PrintFormat("[SMC-OB][TEST] SKIP  %s: only %d bars available", m_group, n);
      return;
     }

   //--- 1. batch scan
   CSMCDetector batch;
   batch.Init(s);
   batch.ProcessWindow(r, n);
   SSMCStats sb;
   batch.GetStats(sb);

   //--- 2. live simulation: one closed bar at a time with a minimal window
   CSMCDetector live;
   live.Init(s);
   int W = live.RequiredLookback() + 1;
   MqlRates win[];
   for(int t = n - 1; t >= 0; t--)
     {
      int size = MathMin(W, n - t);
      ArrayResize(win, size);
      for(int j = 0; j < size; j++)
         win[j] = r[t + j];
      live.ProcessBar(win, 0, size);
     }
   SSMCStats sl;
   live.GetStats(sl);
   Check(batch.OBCount() == live.OBCount(), StringFormat("batch %d OBs vs live %d OBs", batch.OBCount(), live.OBCount()));
   Check(sb.bosBull == sl.bosBull && sb.bosBear == sl.bosBear, "same BOS counts batch vs live");
   SOrderBlock a, b;
   int mism = 0;
   for(int k = 0; k < MathMin(batch.OBCount(), live.OBCount()); k++)
      if(batch.GetOB(k, a) && live.GetOB(k, b) && !SMC_SameFull(a, b))
         mism++;
   Check(mism == 0, StringFormat("%d OBs differ between batch and live processing", mism));

   //--- 3. truncated history must not change already confirmed OBs
   int cuts[] = {0, 0, 0, 0};
   cuts[0] = n / 5; cuts[1] = n / 2; cuts[2] = (3 * n) / 4; cuts[3] = 25;
   int repainted = 0, missing = 0;
   for(int ci = 0; ci < ArraySize(cuts); ci++)
     {
      int cut = cuts[ci];                         // drop the newest 'cut' bars
      int size = n - cut;
      MqlRates sub[];
      ArrayResize(sub, size);
      for(int j = 0; j < size; j++)
         sub[j] = r[cut + j];
      CSMCDetector part;
      part.Init(s);
      part.ProcessWindow(sub, size);
      datetime end = sub[0].time;

      for(int k = 0; k < part.OBCount(); k++)
        {
         part.GetOB(k, a);
         int idx = batch.FindById(a.id);
         if(idx < 0 || !batch.GetOB(idx, b) || !SMC_SameIdentity(a, b, !a.fvgPending))
            repainted++;
        }
      for(int k = 0; k < batch.OBCount(); k++)
        {
         batch.GetOB(k, b);
         if(b.confirmTime <= end && part.FindById(b.id) < 0)
            missing++;
        }
     }
   Check(repainted == 0, StringFormat("%d OBs changed when future bars were added", repainted));
   Check(missing == 0, StringFormat("%d OBs appeared retroactively in the past", missing));

   //--- 4. invariants
   int bad = 0, dups = 0;
   for(int k = 0; k < batch.OBCount(); k++)
     {
      batch.GetOB(k, a);
      if(!(a.obTime < a.confirmTime && a.bosTime <= a.confirmTime && a.top > a.bottom &&
           (a.firstRetestTime == 0 || a.firstRetestTime > a.confirmTime) && a.legBars >= 1 &&
           a.legBars <= s.maxOBToBOSBars))
         bad++;
      if(a.dir == SMC_DIR_BULL && !(a.candleClose < a.candleOpen)) bad++;
      if(a.dir == SMC_DIR_BEAR && !(a.candleClose > a.candleOpen)) bad++;
      for(int q = k + 1; q < batch.OBCount(); q++)
        {
         batch.GetOB(q, b);
         if(a.dir == b.dir && a.obTime == b.obTime)
            dups++;
        }
     }
   Check(bad == 0, StringFormat("%d OBs violate structural invariants", bad));
   Check(dups == 0, StringFormat("%d duplicate OBs", dups));

   PrintFormat("[SMC-OB][TEST] %s: %d bars, %d OBs (bull %d / bear %d), BOS %d/%d, retests %d, mitigated %d, invalidated %d",
               m_group, n, batch.OBCount(), sb.obBull, sb.obBear, sb.bosBull, sb.bosBear,
               sb.retests, sb.mitigations, sb.invalidations);
  }

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| ZOrder: same scenario; the red run C, D, E becomes one zone.     |
//|  bull zone = [min Low 99.2, max High 101.6], mid 100.4           |
//|  I touches 101.6 (first retest), J reaches 100.4 (mitigated),    |
//|  M closes 99.0 < 99.2 (invalidated)                              |
//+------------------------------------------------------------------+
void CSMCSelfTest::TestZOrderDirectional(const bool bearish)
  {
   m_group = bearish ? "ZOrder bearish scenario" : "ZOrder bullish scenario";
   MqlRates c[];
   Scenario(0, c);
   if(bearish)
      Mirror(c);
   SSMCSettings s;
   CSMCDetector z, std;
   ZSettings(s);
   RunDetector(z, s, c, ArraySize(c) - 1);
   Settings(s);
   RunDetector(std, s, c, ArraySize(c) - 1);

   SSMCStats sz, ss;
   z.GetStats(sz);
   std.GetStats(ss);
   Check(sz.swingHighs == ss.swingHighs && sz.swingLows == ss.swingLows &&
         sz.bosBull == ss.bosBull && sz.bosBear == ss.bosBear, "same swings and BOS as the standard OB");
   Check(z.OBCount() == 1 && std.OBCount() == 1,
         StringFormat("one ZOrder and one standard OB coexist (got %d / %d)", z.OBCount(), std.OBCount()));
   SOrderBlock o, so;
   if(!z.GetOB(0, o) || !std.GetOB(0, so))
      return;

   int dir = bearish ? SMC_DIR_BEAR : SMC_DIR_BULL;
   Check(o.isZOrder && o.dir == dir && !so.isZOrder && so.seriesCount == 0, "ZOrder flagged, standard OB unchanged");
   Check(o.obTime == c[iE].time && o.seriesStartTime == c[iC].time && o.seriesCount == 3,
         StringFormat("series = consecutive candles C, D, E (got %d)", o.seriesCount));
   Check(Near(o.top, bearish ? 100.8 : 101.6) && Near(o.bottom, bearish ? 98.4 : 99.2),
         StringFormat("zone = highest High / lowest Low of the series (%.2f - %.2f)", o.bottom, o.top));
   Check(Near(so.top, bearish ? 100.8 : 100.2) && Near(so.bottom, bearish ? 99.8 : 99.2),
         "standard OB is still the last candle only");
   Check(o.bosTime == so.bosTime && o.confirmTime == so.confirmTime && o.swingTime == so.swingTime &&
         o.legBars == so.legBars, "same BOS / displacement confirmation as the standard OB");
   Check(o.hasFVG && o.fvgLeftTime == c[iE].time, "FVG confluence reused");
   Check(o.retestCount == 1 && o.firstRetestTime == c[iI].time,
         StringFormat("first retest on I (wider zone), retests=%d", o.retestCount));
   Check(o.mitigatedTime == c[iJ].time && o.endTime == c[iJ].time, "mitigated at mid of the series zone on J");
   Check(o.invalidatedTime == c[iM].time && o.state == SMC_OB_INVALIDATED,
         "invalidated by close beyond the series extreme on M");
  }

//+------------------------------------------------------------------+
void CSMCSelfTest::TestZOrderSeriesRules(void)
  {
   m_group = "ZOrder series rules";
   MqlRates c[];
   SSMCSettings s;
   SSMCStats st;
   SOrderBlock o;
   ZeroMemory(o);
   CSMCDetector z;

   //--- contiguity: the green candle C ends the red series
   Scenario(4, c);
   ZSettings(s);
   RunDetector(z, s, c, ArraySize(c) - 1);
   Check(z.OBCount() >= 1 && z.GetOB(0, o) && o.obTime == c[iE].time, "ZOrder created when the series is interrupted");
   Check(o.seriesCount == 2 && o.seriesStartTime == c[iE - 1].time,
         StringFormat("series stops at the opposite candle: D, E only (got %d)", o.seriesCount));
   Check(Near(o.top, 100.9) && Near(o.bottom, 99.2), StringFormat("zone covers D..E only (%.2f - %.2f)", o.bottom, o.top));

   //--- no look-ahead, no repaint
   Scenario(0, c);
   RunDetector(z, s, c, iF);
   Check(z.OBCount() == 0, "no ZOrder before the BOS candle closes");
   RunDetector(z, s, c, iG);
   Check(z.OBCount() == 1 && z.GetOB(0, o) && o.state == SMC_OB_ACTIVE && o.seriesCount == 3,
         "ZOrder confirmed at BOS close with its final series");
   SOrderBlock atG = o;
   RunDetector(z, s, c, ArraySize(c) - 1);
   Check(z.GetOB(0, o) && SMC_SameIdentity(atG, o, true), "series and zone unchanged by later bars");

   //--- displacement filter is shared with the standard OB
   ZSettings(s);
   s.dispATRMult = 10.0;
   RunDetector(z, s, c, ArraySize(c) - 1);
   z.GetStats(st);
   Check(z.OBCount() == 0 && st.rejWeakMove >= 1, "weak displacement creates no ZOrder");

   //--- duplicates: a second BOS from the same leg
   Scenario(3, c);
   ZSettings(s);
   RunDetector(z, s, c, iH);
   z.GetStats(st);
   Check(st.bosBull == 2 && z.OBCount() == 1 && st.duplicates == 1, "second BOS does not duplicate the ZOrder");
  }

//+------------------------------------------------------------------+
//| Real data: ZOrder vs standard OB on identical settings           |
//+------------------------------------------------------------------+
void CSMCSelfTest::TestZOrderRealData(const SSMCSettings &base, const int bars)
  {
   m_group = StringFormat("ZOrder vs standard %s %s", _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period));
   SSMCSettings ss = base;
   ss.logLevel    = SMC_LOG_OFF;
   ss.maxStored   = 1000000;
   ss.overlapMode = SMC_OVERLAP_KEEP_ALL;      // no zone-size dependent skipping: 1:1 comparison
   ss.zoneMode    = SMC_ZONE_WICK;
   ss.zoneSource  = SMC_SOURCE_LAST_CANDLE;
   SSMCSettings zs = ss;
   zs.zoneSource  = SMC_SOURCE_CANDLE_SERIES;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   int n = CopyRates(_Symbol, _Period, 1, bars, r);
   if(n < 300)
     {
      PrintFormat("[SMC-OB][TEST] SKIP  %s: only %d bars available", m_group, n);
      return;
     }
   CSMCDetector std, z;
   std.Init(ss);
   z.Init(zs);
   std.ProcessWindow(r, n);
   z.ProcessWindow(r, n);
   SSMCStats a, b;
   std.GetStats(a);
   z.GetStats(b);
   Check(a.swingHighs == b.swingHighs && a.swingLows == b.swingLows && a.bosBull == b.bosBull &&
         a.bosBear == b.bosBear && a.choch == b.choch, "identical swings and BOS");
   Check(a.rejWeakMove == b.rejWeakMove && a.rejWeakCandle == b.rejWeakCandle && a.rejSmallBody == b.rejSmallBody &&
         a.rejWeakRelative == b.rejWeakRelative && a.rejNoOpposite == b.rejNoOpposite &&
         a.rejBosOpposite == b.rejBosOpposite && a.rejLegViolation == b.rejLegViolation,
         "identical displacement decisions");

   SOrderBlock zo, so;
   int unmatched = 0, notContaining = 0, badSeries = 0, badRange = 0, dups = 0, multi = 0, maxCount = 0;
   for(int k = 0; k < z.OBCount(); k++)
     {
      z.GetOB(k, zo);
      //--- standard counterpart from the same BOS
      bool found = false;
      for(int q = 0; q < std.OBCount() && !found; q++)
        {
         std.GetOB(q, so);
         if(so.dir == zo.dir && so.obTime == zo.obTime && so.bosTime == zo.bosTime && so.confirmTime == zo.confirmTime)
           {
            found = true;
            if(so.top > zo.top + 1e-10 || so.bottom < zo.bottom - 1e-10)
               notContaining++;
           }
        }
      if(!found)
         unmatched++;
      for(int q = k + 1; q < z.OBCount(); q++)
        {
         z.GetOB(q, so);
         if(so.dir == zo.dir && so.obTime == zo.obTime)
            dups++;
        }

      //--- rebuild the series from the raw candles
      int newest = -1, oldest = -1;
      for(int j = 0; j < n; j++)
        {
         if(r[j].time == zo.obTime)          newest = j;
         if(r[j].time == zo.seriesStartTime) oldest = j;
        }
      if(newest < 0 || oldest < newest || oldest - newest + 1 != zo.seriesCount)
        {
         badSeries++;
         continue;
        }
      bool ok = true;
      double hi = -DBL_MAX, lo = DBL_MAX;
      for(int j = newest; j <= oldest; j++)
        {
         if(!SMC_IsDirCandle(r[j], -zo.dir))
            ok = false;                                // every candle opposite colour
         hi = MathMax(hi, r[j].high);
         lo = MathMin(lo, r[j].low);
        }
      if(oldest + 1 < n && SMC_IsDirCandle(r[oldest + 1], -zo.dir))
         ok = false;                                   // series must be complete
      if(newest - 1 >= 0 && SMC_IsDirCandle(r[newest - 1], -zo.dir))
         ok = false;                                   // must end right before the displacement
      if(!ok)
         badSeries++;
      if(!Near(hi, zo.top) || !Near(lo, zo.bottom))
         badRange++;
      if(zo.seriesCount > 1)
         multi++;
      maxCount = MathMax(maxCount, zo.seriesCount);
     }
   int stdMissing = 0;
   for(int q = 0; q < std.OBCount(); q++)
     {
      std.GetOB(q, so);
      if(!z.HasOB(so.dir, so.obTime))
         stdMissing++;
     }

   Check(unmatched == 0, StringFormat("%d ZOrders without a standard OB from the same BOS", unmatched));
   Check(stdMissing <= b.rejSeriesTooLong,
         StringFormat("%d standard OBs without a ZOrder (series too long: %d)", stdMissing, b.rejSeriesTooLong));
   Check(notContaining == 0, StringFormat("%d ZOrders do not contain their standard OB zone", notContaining));
   Check(badSeries == 0, StringFormat("%d ZOrders with a non-contiguous or incomplete series", badSeries));
   Check(badRange == 0, StringFormat("%d ZOrders whose zone is not the series High/Low", badRange));
   Check(dups == 0, StringFormat("%d duplicate ZOrders", dups));
   Check(multi > 0, "multi-candle series found in real data");

   PrintFormat("[SMC-OB][TEST] %s: %d bars, standard OBs %d, ZOrders %d (multi-candle %d, longest %d candles, series too long %d)",
               m_group, n, std.OBCount(), z.OBCount(), multi, maxCount, b.rejSeriesTooLong);
  }

//+------------------------------------------------------------------+
//| Real data: "Open-Last Extreme" zones for OB and ZOrder            |
//|  bull = first (oldest) candle Open .. last (newest) candle Low    |
//|  bear = first candle Open .. last candle High                     |
//| Only the zone may differ from Wick mode: swings, BOS and every    |
//| displacement decision stay identical.                             |
//+------------------------------------------------------------------+
void CSMCSelfTest::TestCloseExtremeZones(const SSMCSettings &base, const int bars)
  {
   m_group = StringFormat("Open-Last Extreme zones %s %s", _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period));
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int n = CopyRates(_Symbol, _Period, 1, bars, r);
   if(n < 300)
     {
      PrintFormat("[SMC-OB][TEST] SKIP  %s: only %d bars available", m_group, n);
      return;
     }
   int total = 0, zeroRej = 0, multi = 0;
   for(int layer = 0; layer < 2; layer++)
     {
      SSMCSettings wick = base;
      wick.logLevel    = SMC_LOG_OFF;
      wick.maxStored   = 1000000;
      wick.overlapMode = SMC_OVERLAP_KEEP_ALL;         // zone size must not change which OBs are kept
      wick.zoneMode    = SMC_ZONE_WICK;
      wick.zoneSource  = (layer == 0) ? SMC_SOURCE_LAST_CANDLE : SMC_SOURCE_CANDLE_SERIES;
      SSMCSettings ce = wick;
      ce.zoneMode      = SMC_ZONE_OPEN_LAST_EXTREME;
      CSMCDetector dw, dc;
      dw.Init(wick);
      dc.Init(ce);
      dw.ProcessWindow(r, n);
      dc.ProcessWindow(r, n);
      SSMCStats a, b;
      dw.GetStats(a);
      dc.GetStats(b);
      string what = (layer == 0) ? "OB" : "ZOrder";
      Check(a.swingHighs == b.swingHighs && a.swingLows == b.swingLows && a.bosBull == b.bosBull && a.bosBear == b.bosBear &&
            a.rejWeakMove == b.rejWeakMove && a.rejSmallBody == b.rejSmallBody && a.rejNoOpposite == b.rejNoOpposite,
            what + ": identical structure and displacement decisions");

      int bad = 0;
      SOrderBlock o;
      for(int k = 0; k < dc.OBCount(); k++)
        {
         dc.GetOB(k, o);
         int newest = -1, oldest = -1;
         datetime first = o.isZOrder ? o.seriesStartTime : o.obTime;
         for(int j = 0; j < n; j++)
           {
            if(r[j].time == o.obTime) newest = j;
            if(r[j].time == first)    oldest = j;
           }
         if(newest < 0 || oldest < newest) { bad++; continue; }
         double ext = (o.dir == SMC_DIR_BULL) ? r[newest].low : r[newest].high;
         double top = MathMax(r[oldest].open, ext), bottom = MathMin(r[oldest].open, ext);
         if(!Near(top, o.top) || !Near(bottom, o.bottom) || !Near((top + bottom) / 2.0, o.mid))
            bad++;
         if(oldest > newest)
            multi++;
        }
      Check(bad == 0, StringFormat("%s: %d zones differ from first-candle open / last-candle extreme", what, bad));
      //--- every Wick-mode OB exists in this mode unless its new zone has zero height
      Check(dc.OBCount() + b.rejZeroZone >= dw.OBCount() && dc.OBCount() <= dw.OBCount(),
            StringFormat("%s: same OBs as Wick mode (%d vs %d, zero-height zones %d)", what, dc.OBCount(), dw.OBCount(), b.rejZeroZone));
      total += dc.OBCount();
      zeroRej += b.rejZeroZone;
     }
   Check(multi > 0, "multi-candle ZOrder series checked");
   PrintFormat("[SMC-OB][TEST] %s: %d zones checked (multi-candle %d), zero-height zones rejected %d",
               m_group, total, multi, zeroRej);
  }

//+------------------------------------------------------------------+
bool CSMCSelfTest::Run(const SSMCSettings &base, const int realBars)
  {
   m_pass = 0;
   m_fail = 0;
   ulong t0 = GetMicrosecondCount();

   TestDirectional(false);
   TestDirectional(true);
   TestNoLookAhead();
   TestWeakDisplacement();
   TestFVGWithoutBOS();
   TestLateFVG();
   TestDuplicate();
   TestPrefixSynthetic(false);
   TestRealData(base, realBars);

   //--- ZOrder Blocks (standard tests above are unchanged)
   TestZOrderDirectional(false);
   TestZOrderDirectional(true);
   TestZOrderSeriesRules();
   TestPrefixSynthetic(true);
   SSMCSettings zbase = base;
   zbase.zoneSource = SMC_SOURCE_CANDLE_SERIES;
   TestRealData(zbase, realBars);
   TestZOrderRealData(base, realBars);
   TestCloseExtremeZones(base, realBars);

   PrintFormat("[SMC-OB][TEST] %s: %d checks passed, %d failed (%.1f ms)",
               m_fail == 0 ? "ALL PASSED" : "FAILURES", m_pass, m_fail,
               (GetMicrosecondCount() - t0) / 1000.0);
   return m_fail == 0;
  }

#endif // SMC_OB_SELFTEST_MQH
