//+------------------------------------------------------------------+
//|                                            SMC_CISD_SelfTest.mqh |
//|  SPDX-License-Identifier: MIT                                    |
//|  https://github.com/MrOwl1011/Smc_ZOB_CISD                       |
//|  Deterministic tests for the CISD engine.                        |
//|                                                                  |
//|  Synthetic bullish scenario (hand-computed, R=2, ATR 5):         |
//|   S2 swing low 98.0 (confirmed on S4)                            |
//|   R1..R4 bearish series, R3 low 97.5 sweeps 98.0, extreme 97.2   |
//|   G1 ends the series -> setup, level = series High 100.5         |
//|   G2 closes 100.8 > 100.5 -> bullish CISD confirmed              |
//|   H2 low 100.3 <= 100.5 -> retracement / entry                   |
//|   G2 also sweeps swing high 100.6 -> bearish setup at H2,        |
//|   failed on H3 (higher high) -> no bearish CISD                  |
//|  plus mirrored bearish scenario, "no sweep" variant, the three   |
//|  panel components switched off, no look-ahead prefix checks and  |
//|  real data on several timeframes.                                |
//+------------------------------------------------------------------+
#ifndef SMC_CISD_SELFTEST_MQH
#define SMC_CISD_SELFTEST_MQH

#include "SMC_CISD_Engine.mqh"

#define SMC_CT_BASE D'2024.01.01 00:00'

bool SMC_CISDSameFull(const SCISD &a, const SCISD &b)
  {
   return SMC_CISDSameSetup(a, b) && a.state == b.state && a.confirmTime == b.confirmTime &&
          MathAbs(a.confirmPrice - b.confirmPrice) < 1e-10 && a.retraceTime == b.retraceTime &&
          a.endTime == b.endTime && a.barsInState == b.barsInState;
  }

class CSMCCISDSelfTest
  {
private:
   int               m_pass;
   int               m_fail;
   string            m_group;
   int               iS2, iS4, iR1, iR3, iR4, iG1, iG2, iH2, iH3;

   void              Check(const bool cond, const string what);
   bool              Near(const double a, const double b) const { return MathAbs(a - b) < 1e-8; }
   void              Add(MqlRates &c[], const double o, const double h, const double l, const double cl);
   void              Scenario(const int variant, MqlRates &c[]);
   void              Mirror(MqlRates &c[]);
   int               Run(CSMCCISDEngine &e, const SCISDSettings &s, const MqlRates &c[], const int lastIndex);
   void              Settings(SCISDSettings &s);
   int               FindConfirmed(const CSMCCISDEngine &e, const int dir, SCISD &out);
   int               IndexOf(const MqlRates &r[], const int n, const datetime t) const;

   void              TestDirectional(const bool bearish);
   void              TestSweepRequired(void);
   void              TestComponents(void);
   void              TestNoLookAhead(void);
   void              TestActivationGate(void);
   void              TestRealData(const SCISDSettings &base, const ENUM_TIMEFRAMES tf, const int bars);

public:
   bool              RunAll(const SCISDSettings &base, const int realBars);
   bool              VerifyLive(const CSMCCISDEngine &live);
  };

//+------------------------------------------------------------------+
void CSMCCISDSelfTest::Check(const bool cond, const string what)
  {
   if(cond)
      m_pass++;
   else
     {
      m_fail++;
      PrintFormat("[SMC-CISD][TEST] FAIL  %s: %s", m_group, what);
     }
  }

void CSMCCISDSelfTest::Add(MqlRates &c[], const double o, const double h, const double l, const double cl)
  {
   int n = ArraySize(c);
   ArrayResize(c, n + 1, 64);
   ZeroMemory(c[n]);
   c[n].time  = (datetime)(SMC_CT_BASE + n * 300);
   c[n].open  = o;
   c[n].high  = h;
   c[n].low   = l;
   c[n].close = cl;
  }

//--- variant 0: base | 1: R3/R4 stay above swing low 98.0 (no liquidity sweep)
void CSMCCISDSelfTest::Scenario(const int variant, MqlRates &c[])
  {
   ArrayResize(c, 0);
   for(int k = 0; k < 20; k++)
      Add(c, 100.0, 100.5, 99.5, 100.0);                    // doji warm-up
                          Add(c, 100.0, 100.2, 98.8, 99.0);  // S1
   iS2 = ArraySize(c);    Add(c,  99.0,  99.3, 98.0, 99.1);  // S2 swing low 98.0
                          Add(c,  99.1, 100.0, 98.9, 99.8);  // S3
   iS4 = ArraySize(c);    Add(c,  99.8, 100.6, 99.5, 100.4); // S4 swing high 100.6
   iR1 = ArraySize(c);    Add(c, 100.4, 100.5, 99.4, 99.6);  // R1 bearish series start (High 100.5)
                          Add(c,  99.6,  99.7, 98.6, 98.8);  // R2
   iR3 = ArraySize(c);
   iR4 = iR3 + 1;
   iG1 = iR3 + 2;
   if(variant == 1)
     {
      Add(c, 98.8, 98.9, 98.2, 98.4);                        // R3 (no sweep)
      Add(c, 98.4, 98.5, 98.1, 98.3);                        // R4
      Add(c, 98.3, 99.0, 98.2, 98.9);                        // G1 ends series
     }
   else
     {
      Add(c, 98.8, 98.9, 97.5, 97.7);                        // R3 sweeps 98.0
      Add(c, 97.7, 97.9, 97.2, 97.4);                        // R4 extreme 97.2
      Add(c, 97.4, 99.0, 97.3, 98.9);                        // G1 ends series -> setup
     }
   iG2 = ArraySize(c);    Add(c,  98.9, 100.9, 98.8, 100.8); // G2 close > 100.5 -> CISD
                          Add(c, 100.8, 101.2, 100.6, 101.0);// H1
   iH2 = ArraySize(c);    Add(c, 101.0, 101.1, 100.3, 100.4);// H2 retracement
   iH3 = ArraySize(c);    Add(c, 100.4, 101.8, 100.3, 101.6);// H3
                          Add(c, 101.6, 102.2, 101.4, 102.0);// H4
                          Add(c, 102.0, 102.5, 101.8, 102.3);// H5
  }

void CSMCCISDSelfTest::Mirror(MqlRates &c[])
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

void CSMCCISDSelfTest::Settings(SCISDSettings &s)
  {
   ZeroMemory(s);
   s.timeframe         = PERIOD_M5;
   s.useSweep          = true;
   s.useConfirm        = true;
   s.useRetrace        = true;
   s.swingLength       = 2;
   s.swingMinATR       = 0.5;
   s.atrPeriod         = 5;
   s.swingMaxAge       = 100;
   s.sweepMode         = CISD_SWEEP_TRADE_THROUGH;
   s.sweepValidityBars = 10;
   s.levelMode         = CISD_LEVEL_SERIES_RANGE;
   s.maxSeriesCandles  = 10;
   s.maxConfirmBars    = 20;
   s.maxRetraceBars    = 50;
   s.maxStored         = 500;
   s.logLevel          = SMC_LOG_OFF;
  }

int CSMCCISDSelfTest::Run(CSMCCISDEngine &e, const SCISDSettings &s, const MqlRates &c[], const int lastIndex)
  {
   e.Init(s);
   MqlRates ser[];
   int n = lastIndex + 1;
   ArrayResize(ser, n);
   for(int j = 0; j < n; j++)
      ser[j] = c[lastIndex - j];
   return e.ProcessWindow(ser, n);
  }

int CSMCCISDSelfTest::FindConfirmed(const CSMCCISDEngine &e, const int dir, SCISD &out)
  {
   int found = 0;
   SCISD c;
   for(int k = 0; k < e.Count(); k++)
      if(e.Get(k, c) && c.dir == dir && SMC_CISDConfirmedState(c.state))
        {
         if(found == 0)
            out = c;
         found++;
        }
   return found;
  }

int CSMCCISDSelfTest::IndexOf(const MqlRates &r[], const int n, const datetime t) const
  {
   int lo = 0, hi = n - 1;                           // series order: time descending
   while(lo <= hi)
     {
      int mid = (lo + hi) / 2;
      if(r[mid].time == t) return mid;
      if(r[mid].time > t)  lo = mid + 1;
      else                 hi = mid - 1;
     }
   return -1;
  }

//+------------------------------------------------------------------+
void CSMCCISDSelfTest::TestDirectional(const bool bearish)
  {
   m_group = bearish ? "CISD bearish scenario" : "CISD bullish scenario";
   MqlRates c[];
   Scenario(0, c);
   if(bearish)
      Mirror(c);
   SCISDSettings s;
   Settings(s);
   CSMCCISDEngine e;
   Run(e, s, c, ArraySize(c) - 1);

   int dir = bearish ? SMC_DIR_BEAR : SMC_DIR_BULL;
   SCISD x;
   ZeroMemory(x);
   SCISDStats st;
   e.GetStats(st);
   int n = FindConfirmed(e, dir, x);
   Check(n == 1, StringFormat("exactly one confirmed CISD (got %d)", n));
   Check(FindConfirmed(e, -dir, x) == 0, "opposite setup failed: no opposite CISD");
   FindConfirmed(e, dir, x);
   Check(st.sweepsSellSide == 1 && st.sweepsBuySide == 1, "one sweep on each side");
   Check(x.hasSweep && x.sweepTime == c[iR3].time && Near(x.sweptSwingPrice, bearish ? 102.0 : 98.0) &&
         x.sweptSwingTime == c[iS2].time && Near(x.sweepPrice, bearish ? 102.5 : 97.5), "liquidity sweep: R3 took swing S2");
   Check(x.seriesStartTime == c[iR1].time && x.seriesEndTime == c[iR4].time && x.seriesCount == 4,
         StringFormat("series = complete contiguous run R1..R4 (got %d)", x.seriesCount));
   Check(Near(x.seriesHigh, bearish ? 102.8 : 100.5) && Near(x.seriesLow, bearish ? 99.5 : 97.2), "series High/Low");
   Check(Near(x.level, bearish ? 99.5 : 100.5), "level = series High (bull) / Low (bear)");
   Check(x.extremeTime == c[iR4].time && Near(x.extremePrice, bearish ? 102.8 : 97.2), "manipulation extreme on R4");
   Check(x.setupTime == c[iG1].time, "setup identified when G1 ended the series");
   Check(x.confirmTime == c[iG2].time && Near(x.confirmPrice, bearish ? 99.2 : 100.8), "confirmation close on G2");
   Check(x.state == CISD_ST_RETRACED && x.retraceTime == c[iH2].time, "retracement / entry on H2");
   Check(Near(x.sdRange, 3.3) && Near(SMC_CISDDeviationPrice(x, 2.0), bearish ? 92.9 : 107.1) &&
         Near(SMC_CISDDeviationPrice(x, -1.0), x.extremePrice), "standard deviation projections");
   Check(st.setupFailed == 1, "opposite setup failed on H3");
  }

//+------------------------------------------------------------------+
void CSMCCISDSelfTest::TestSweepRequired(void)
  {
   m_group = "CISD requires sweep + close";
   MqlRates c[];
   SCISDSettings s;
   Settings(s);
   CSMCCISDEngine e;
   SCISD x;
   SCISDStats st;

   //--- close beyond the series without a sweep is NOT a CISD
   Scenario(1, c);
   Run(e, s, c, ArraySize(c) - 1);
   e.GetStats(st);
   Check(FindConfirmed(e, SMC_DIR_BULL, x) == 0 && st.sweepsSellSide == 0 && st.noSweep >= 1,
         "series + close above it without liquidity sweep -> no bullish CISD");

   //--- a sweep alone is NOT a CISD
   Scenario(0, c);
   Run(e, s, c, iG1);
   e.GetStats(st);
   Check(st.sweepsSellSide == 1 && FindConfirmed(e, SMC_DIR_BULL, x) == 0 &&
         e.MachineState(SMC_DIR_BULL) == CISD_M_WAIT_FOR_CLOSE, "sweep + series without close -> setup only");
   Run(e, s, c, iR3);
   Check(e.MachineState(SMC_DIR_BULL) == CISD_M_LIQUIDITY_SWEEP, "machine at LIQUIDITY_SWEEP_LOW after R3");
  }

//+------------------------------------------------------------------+
void CSMCCISDSelfTest::TestComponents(void)
  {
   m_group = "CISD panel components";
   MqlRates c[];
   Scenario(0, c);
   SCISDSettings s;
   CSMCCISDEngine e;
   SCISD x;
   SCISDStats st;

   //--- Retracement / Entry OFF
   Settings(s);
   s.useRetrace = false;
   Run(e, s, c, ArraySize(c) - 1);
   e.GetStats(st);
   Check(FindConfirmed(e, SMC_DIR_BULL, x) == 1 && x.state == CISD_ST_CONFIRMED && x.retraceTime == 0 && st.retraced == 0,
         "retracement OFF: CISD confirmed, no retracement tracked");

   //--- Confirmation Close OFF
   Settings(s);
   s.useConfirm = false;
   Run(e, s, c, ArraySize(c) - 1);
   e.GetStats(st);
   bool setupKept = false;
   for(int k = 0; k < e.Count(); k++)
      if(e.Get(k, x) && x.dir == SMC_DIR_BULL && x.state == CISD_ST_SETUP && x.seriesStartTime == c[iR1].time)
         setupKept = true;
   Check(st.confirmedBull + st.confirmedBear == 0 && st.retraced == 0 && setupKept,
         "confirmation OFF: sweep + series tracked as setup, nothing confirmed");

   //--- Liquidity Sweep OFF
   Settings(s);
   s.useSweep = false;
   Run(e, s, c, ArraySize(c) - 1);
   e.GetStats(st);
   int confirmed = 0, withSweep = 0;
   bool mainFound = false;
   for(int k = 0; k < e.Count(); k++)
      if(e.Get(k, x) && SMC_CISDConfirmedState(x.state))
        {
         confirmed++;
         if(x.hasSweep) withSweep++;
         if(x.dir == SMC_DIR_BULL && x.seriesStartTime == c[iR1].time && x.confirmTime == c[iG2].time)
            mainFound = true;
        }
   Check(st.sweepsSellSide + st.sweepsBuySide == 0 && withSweep == 0, "sweep OFF: no sweeps processed");
   Check(mainFound && confirmed > 1, StringFormat("sweep OFF: sweep no longer required, %d CISDs coexist", confirmed));

   //--- unique ids / no duplicate series
   int dups = 0;
   SCISD y;
   for(int a = 0; a < e.Count(); a++)
      for(int b = a + 1; b < e.Count(); b++)
         if(e.Get(a, x) && e.Get(b, y) && (x.id == y.id || (x.dir == y.dir && x.seriesEndTime == y.seriesEndTime)))
            dups++;
   Check(dups == 0, "unique ids, one setup per series");
  }

//+------------------------------------------------------------------+
void CSMCCISDSelfTest::TestNoLookAhead(void)
  {
   m_group = "CISD no look-ahead";
   MqlRates c[];
   Scenario(0, c);
   SCISDSettings s;
   Settings(s);
   CSMCCISDEngine full, part;
   Run(full, s, c, ArraySize(c) - 1);
   SCISD x;
   Run(part, s, c, iG1);
   Check(FindConfirmed(part, SMC_DIR_BULL, x) == 0, "no CISD before the confirmation candle closes");

   int bad = 0;
   SCISD a, b;
   for(int last = 0; last < ArraySize(c); last++)
     {
      Run(part, s, c, last);
      for(int k = 0; k < part.Count(); k++)
        {
         part.Get(k, a);
         int idx = full.FindById(a.id);
         if(idx < 0 || !full.Get(idx, b) || !SMC_CISDSameSetup(a, b))
            bad++;
         else if(SMC_CISDConfirmedState(a.state) && (a.confirmTime != b.confirmTime || !Near(a.confirmPrice, b.confirmPrice)))
            bad++;
        }
     }
   Check(bad == 0, StringFormat("%d CISD setups/confirmations changed when later bars were added", bad));
  }

//+------------------------------------------------------------------+
//--- activationTime / dirFilter used by the HTF OB -> LTF CISD workflow
void CSMCCISDSelfTest::TestActivationGate(void)
  {
   m_group = "CISD activation gate";
   MqlRates c[];
   Scenario(0, c);
   SCISDSettings s;
   CSMCCISDEngine e;
   SCISD x;
   SCISDStats st;

   Settings(s);
   s.activationTime = c[iR1].time;
   Run(e, s, c, ArraySize(c) - 1);
   Check(FindConfirmed(e, SMC_DIR_BULL, x) == 1 && x.seriesStartTime >= s.activationTime && x.sweepTime >= s.activationTime,
         "activation at series start: CISD found, every event at/after activation");

   Settings(s);
   s.activationTime = c[iR1 + 1].time;
   Run(e, s, c, ArraySize(c) - 1);
   Check(FindConfirmed(e, SMC_DIR_BULL, x) == 0, "series that began before activation is ignored");

   Settings(s);
   s.activationTime = c[iG1].time;
   Run(e, s, c, ArraySize(c) - 1);
   e.GetStats(st);
   Check(FindConfirmed(e, SMC_DIR_BULL, x) == 0 && st.sweepsSellSide == 0, "sweep before activation is ignored");

   Settings(s);
   s.activationTime = c[iR1].time;
   s.dirFilter = SMC_DIR_BEAR;
   Run(e, s, c, ArraySize(c) - 1);
   e.GetStats(st);
   Check(FindConfirmed(e, SMC_DIR_BULL, x) == 0 && st.sweepsSellSide == 0 && st.setupsBull == 0,
         "bearish-only engine ignores the bullish CISD");

   Settings(s);
   s.dirFilter = SMC_DIR_BULL;
   Run(e, s, c, ArraySize(c) - 1);
   e.GetStats(st);
   Check(FindConfirmed(e, SMC_DIR_BULL, x) == 1 && st.sweepsBuySide == 0 && st.setupsBear == 0,
         "bullish-only engine keeps the bullish CISD and skips bearish work");
  }

//+------------------------------------------------------------------+
void CSMCCISDSelfTest::TestRealData(const SCISDSettings &base, const ENUM_TIMEFRAMES tf, const int bars)
  {
   m_group = StringFormat("CISD real data %s %s", _Symbol, SMC_TFText(tf));
   SCISDSettings s = base;
   s.timeframe = tf;
   s.logLevel  = SMC_LOG_OFF;
   s.maxStored = 1000000;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   int n = CopyRates(_Symbol, tf, 1, bars, r);
   if(n < 300)
     {
      PrintFormat("[SMC-CISD][TEST] SKIP  %s: only %d bars available (err %d)", m_group, n, GetLastError());
      return;
     }

   //--- batch vs live (one closed bar at a time with a minimal window)
   CSMCCISDEngine batch, live;
   batch.Init(s);
   live.Init(s);
   batch.ProcessWindow(r, n);
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
   SCISD a, b;
   int mism = (batch.Count() == live.Count()) ? 0 : 1;
   for(int k = 0; k < MathMin(batch.Count(), live.Count()); k++)
      if(batch.Get(k, a) && live.Get(k, b) && !SMC_CISDSameFull(a, b))
         mism++;
   Check(mism == 0 && batch.SweepCount() == live.SweepCount(),
         StringFormat("batch vs live mismatch (%d/%d records, %d differ)", batch.Count(), live.Count(), mism));

   //--- truncated history: nothing already detected may change or appear retroactively
   int cuts[] = {0, 0, 25};
   cuts[0] = n / 2;
   cuts[1] = n / 4;
   int repaint = 0, missing = 0;
   for(int ci = 0; ci < ArraySize(cuts); ci++)
     {
      int size = n - cuts[ci];
      MqlRates sub[];
      ArrayResize(sub, size);
      for(int j = 0; j < size; j++)
         sub[j] = r[cuts[ci] + j];
      CSMCCISDEngine part;
      part.Init(s);
      part.ProcessWindow(sub, size);
      datetime end = sub[0].time;
      for(int k = 0; k < part.Count(); k++)
        {
         part.Get(k, a);
         int idx = batch.FindById(a.id);
         if(idx < 0 || !batch.Get(idx, b) || !SMC_CISDSameSetup(a, b) ||
            (SMC_CISDConfirmedState(a.state) && a.confirmTime != b.confirmTime))
            repaint++;
        }
      for(int k = 0; k < batch.Count(); k++)
        {
         batch.Get(k, b);
         if(b.setupTime <= end && part.FindById(b.id) < 0)
            missing++;
        }
     }
   Check(repaint == 0, StringFormat("%d CISDs changed when future bars were added", repaint));
   Check(missing == 0, StringFormat("%d CISDs appeared retroactively", missing));

   //--- rules re-checked against raw candles of this timeframe
   int badSeries = 0, badSweep = 0, badConfirm = 0, badRetrace = 0, confirmed = 0, retraced = 0, bull = 0, bear = 0;
   for(int k = 0; k < batch.Count(); k++)
     {
      batch.Get(k, a);
      int dir = a.dir;
      int newest = IndexOf(r, n, a.seriesEndTime), oldest = IndexOf(r, n, a.seriesStartTime), setup = IndexOf(r, n, a.setupTime);
      bool ok = (newest >= 0 && oldest >= newest && setup == newest - 1 && oldest - newest + 1 == a.seriesCount);
      if(ok)
        {
         double hi = -DBL_MAX, lo = DBL_MAX;
         for(int j = newest; j <= oldest; j++)
           {
            if(!SMC_IsDirCandle(r[j], -dir)) ok = false;
            hi = MathMax(hi, r[j].high);
            lo = MathMin(lo, r[j].low);
           }
         if(oldest + 1 < n && SMC_IsDirCandle(r[oldest + 1], -dir)) ok = false;   // complete
         if(SMC_IsDirCandle(r[setup], -dir)) ok = false;                          // ended on setup bar
         if(!Near(hi, a.seriesHigh) || !Near(lo, a.seriesLow)) ok = false;
         double lvl = (s.levelMode == CISD_LEVEL_SERIES_OPEN) ? r[oldest].open : (dir == SMC_DIR_BULL ? hi : lo);
         if(!Near(lvl, a.level)) ok = false;
        }
      if(!ok) badSeries++;

      if(s.useSweep)
        {
         int si = IndexOf(r, n, a.sweepTime);
         if(!a.hasSweep || si < 0 || a.sweepTime > a.setupTime || a.sweptSwingTime >= a.sweepTime ||
            (dir == SMC_DIR_BULL ? !(r[si].low < a.sweptSwingPrice) : !(r[si].high > a.sweptSwingPrice)))
            badSweep++;
        }
      else if(a.hasSweep)
         badSweep++;

      if(!SMC_CISDConfirmedState(a.state))
         continue;
      confirmed++;
      if(dir == SMC_DIR_BULL) bull++; else bear++;
      int ci2 = IndexOf(r, n, a.confirmTime);
      bool cok = (ci2 >= 0 && ci2 <= setup && dir * (r[ci2].close - a.level) > 0);
      for(int j = setup - 1; cok && j > ci2; j--)                              // first close beyond, no deeper extreme
         if(dir * (r[j].close - a.level) > 0 || (dir == SMC_DIR_BULL ? r[j].low < a.extremePrice : r[j].high > a.extremePrice))
            cok = false;
      if(!cok) badConfirm++;

      if(a.retraceTime > 0)
        {
         retraced++;
         int ri = IndexOf(r, n, a.retraceTime);
         bool rok = (ri >= 0 && ri < ci2 && (dir == SMC_DIR_BULL ? r[ri].low <= a.level : r[ri].high >= a.level));
         for(int j = ci2 - 1; rok && j > ri; j--)
            if(dir == SMC_DIR_BULL ? r[j].low <= a.level : r[j].high >= a.level)
               rok = false;
         if(!rok) badRetrace++;
        }
     }
   Check(badSeries == 0, StringFormat("%d setups with wrong series / level", badSeries));
   Check(badSweep == 0, StringFormat("%d setups with an invalid liquidity sweep", badSweep));
   Check(badConfirm == 0, StringFormat("%d CISDs with an invalid confirmation close", badConfirm));
   Check(badRetrace == 0, StringFormat("%d CISDs with an invalid retracement", badRetrace));

   SCISDStats st;
   batch.GetStats(st);
   PrintFormat("[SMC-CISD][TEST] %s: %d bars, sweeps %d/%d, setups %d, CISD bull %d / bear %d, retraced %d, invalidated %d",
               m_group, n, st.sweepsSellSide, st.sweepsBuySide, st.setupsBull + st.setupsBear, bull, bear, retraced, st.invalidated);
  }

//+------------------------------------------------------------------+
//| Compare a live (bar-by-bar, multi-timeframe) engine with a batch |
//| run over the same CISD-timeframe candles.                        |
//+------------------------------------------------------------------+
bool CSMCCISDSelfTest::VerifyLive(const CSMCCISDEngine &live)
  {
   m_pass = 0;
   m_fail = 0;
   SCISDSettings s;
   live.GetSettings(s);
   m_group = StringFormat("CISD live vs batch %s (chart %s)", SMC_TFText(s.timeframe), SMC_TFText((ENUM_TIMEFRAMES)_Period));
   int from = iBarShift(_Symbol, s.timeframe, live.FirstBarTime(), true);
   int to   = iBarShift(_Symbol, s.timeframe, live.LastProcessedTime(), true);
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int n = (from >= 0 && to >= 0) ? CopyRates(_Symbol, s.timeframe, to, from - to + 1, r) : 0;
   Check(n > 0 && r[n - 1].time == live.FirstBarTime() && r[0].time == live.LastProcessedTime(),
         StringFormat("history range available (%d bars)", n));
   if(n <= 0)
      return false;
   CSMCCISDEngine batch;
   batch.Init(s);
   batch.ProcessWindow(r, n);
   SCISD a, b;
   int mism = 0;
   for(int k = 0; k < MathMin(batch.Count(), live.Count()); k++)
      if(batch.Get(k, a) && live.Get(k, b) && !SMC_CISDSameFull(a, b))
         mism++;
   SCISDStats sl, sb;
   live.GetStats(sl);
   batch.GetStats(sb);
   Check(batch.Count() == live.Count() && mism == 0 && batch.SweepCount() == live.SweepCount(),
         StringFormat("live %d records vs batch %d, %d differ", live.Count(), batch.Count(), mism));
   PrintFormat("[SMC-CISD][TEST] %s %s: %d %s bars, live CISD %d/%d, batch CISD %d/%d, %d checks passed, %d failed",
               m_group, m_fail == 0 ? "PASSED" : "FAILED", n, SMC_TFText(s.timeframe),
               sl.confirmedBull, sl.confirmedBear, sb.confirmedBull, sb.confirmedBear, m_pass, m_fail);
   return m_fail == 0;
  }

//+------------------------------------------------------------------+
bool CSMCCISDSelfTest::RunAll(const SCISDSettings &base, const int realBars)
  {
   m_pass = 0;
   m_fail = 0;
   TestDirectional(false);
   TestDirectional(true);
   TestSweepRequired();
   TestComponents();
   TestNoLookAhead();
   TestActivationGate();
   ENUM_TIMEFRAMES tfs[] = {PERIOD_M1, PERIOD_M5, PERIOD_M15, PERIOD_H1, PERIOD_H4};
   for(int k = 0; k < ArraySize(tfs); k++)
      TestRealData(base, tfs[k], realBars);
   PrintFormat("[SMC-CISD][TEST] %s: %d checks passed, %d failed", m_fail == 0 ? "ALL PASSED" : "FAILURES", m_pass, m_fail);
   return m_fail == 0;
  }

#endif // SMC_CISD_SELFTEST_MQH
