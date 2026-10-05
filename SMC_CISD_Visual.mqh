//+------------------------------------------------------------------+
//|                                              SMC_CISD_Visual.mqh |
//|  SPDX-License-Identifier: MIT                                    |
//|  https://github.com/MrOwl1011/Smc_ZOB_CISD                       |
//|  CISD chart objects (prefix "SMCCISD_"). Read-only consumer of   |
//|  the CISD engine; independent from OB / ZOrder visualization.    |
//|  Objects are placed by CISD-timeframe bar time, so they line up  |
//|  on any chart timeframe.                                         |
//+------------------------------------------------------------------+
#ifndef SMC_CISD_VISUAL_MQH
#define SMC_CISD_VISUAL_MQH

#include "SMC_CISD_Engine.mqh"

#define SMC_CISD_MAX_SD 8

struct SCISDVisualSettings
  {
   string            prefix;
   bool              showSweep;         // panel: Liquidity Sweep
   bool              showConfirm;       // panel: Confirmation Close
   bool              showRetrace;       // panel: Retracement / Entry
   bool              showSD;
   bool              showReversalZone;
   double            sdLevels[SMC_CISD_MAX_SD];
   int               sdCount;
   int               maxDrawn;
   int               extendBars;
   int               fontSize;
   color             bullColor;
   color             bearColor;
   color             seriesColor;
   color             sweepColor;
   color             sdColor;
   color             retraceColor;
   color             inactiveColor;
  };

//--- parse "1.0,1.5,2.0,2.5" into the settings array
int SMC_ParseSDLevels(const string text, SCISDVisualSettings &v)
  {
   string parts[];
   int n = StringSplit(text, ',', parts);
   v.sdCount = 0;
   for(int k = 0; k < n && v.sdCount < SMC_CISD_MAX_SD; k++)
     {
      StringTrimLeft(parts[k]);
      StringTrimRight(parts[k]);
      if(parts[k] == "")
         continue;
      double x = StringToDouble(parts[k]);
      if(x != 0.0)
         v.sdLevels[v.sdCount++] = x;
     }
   return v.sdCount;
  }

//--- what a drawn CISD record looks like on the chart: redrawing an unchanged
//--- record would recreate identical objects, so it is skipped instead
struct SCISDDrawSig
  {
   long              id;
   int               state;
   datetime          seriesEnd, setupTime, confirmTime, retraceTime, right;
   double            level, seriesHigh, seriesLow, confirmPrice, retracePrice, sdRange;
   bool              seen;
  };

class CSMCCISDVisualizer
  {
private:
   SCISDVisualSettings m_v;
   long              m_chart;
   SCISDDrawSig      m_rec[];          // records currently on the chart (sorted by id)
   long              m_sweep[];        // sweep ids currently on the chart (sorted)
   bool              m_sweepSeen[];    // parallel to m_sweep

   int               FindRec(const long id) const;
   bool              RecChanged(const SCISDDrawSig &sig, bool &shapeChanged);
   void              DropRec(const int idx);
   bool              SweepDrawn(const long id);
   void              DeleteRecordObjects(const long id);
   void              DeleteSweepObjects(const long id);
   void              DeleteObj(const string name)
     { if(ObjectFind(m_chart, name) >= 0) ObjectDelete(m_chart, name); }
   bool              Ensure(const string name, const ENUM_OBJECT type, const datetime t1, const double p1,
                            const datetime t2 = 0, const double p2 = 0.0);

   string            Name(const string kind, const long id, const string extra = "") const
     { return m_v.prefix + kind + IntegerToString(id) + extra; }
   void              Line(const string name, const datetime t1, const double p, const datetime t2,
                          const color c, const ENUM_LINE_STYLE style, const int width, const string tip);
   void              Box(const string name, const datetime t1, const double p1, const datetime t2, const double p2,
                         const color c, const bool fill, const ENUM_LINE_STYLE style, const string tip);
   void              Arrow(const string name, const datetime t, const double p, const int code, const color c,
                           const ENUM_ARROW_ANCHOR anchor, const string tip);
   void              Label(const string name, const datetime t, const double p, const string text, const color c,
                           const ENUM_ANCHOR_POINT anchor);
   void              DrawSweep(const SCISDSweep &s);
   void              DrawRecord(const SCISD &c, const int periodSec, const datetime lastTime);

public:
                     CSMCCISDVisualizer(void) : m_chart(0) { ZeroMemory(m_v); }
   void              Init(const SCISDVisualSettings &v, const long chart = 0)
     { m_v = v; m_chart = chart; Forget(); }
   //--- new display options change how everything is drawn: start from an empty chart
   void              SetSettings(const SCISDVisualSettings &v)
     { ObjectsDeleteAll(m_chart, m_v.prefix); m_v = v; Forget(); }
   void              RedrawAll(const CSMCCISDEngine &engine);
   void              Cleanup(void) { ObjectsDeleteAll(m_chart, m_v.prefix); Forget(); }
   void              Forget(void)
     { ArrayResize(m_rec, 0, 64); ArrayResize(m_sweep, 0, 64); ArrayResize(m_sweepSeen, 0, 64); }
  };

//+------------------------------------------------------------------+
//| Create the object once and move it afterwards. Deleting and       |
//| recreating every candle produced the same picture at a much       |
//| higher cost.                                                      |
//+------------------------------------------------------------------+
bool CSMCCISDVisualizer::Ensure(const string name, const ENUM_OBJECT type, const datetime t1, const double p1,
                                const datetime t2, const double p2)
  {
   //--- object calls are queued asynchronously, so ObjectMove() reports success for a name
   //--- that does not exist yet: ObjectFind() is the only reliable existence test
   if(ObjectFind(m_chart, name) < 0)
      return (type == OBJ_RECTANGLE || type == OBJ_TREND)
             ? ObjectCreate(m_chart, name, type, 0, t1, p1, t2, p2)
             : ObjectCreate(m_chart, name, type, 0, t1, p1);
   ObjectMove(m_chart, name, 0, t1, p1);
   if(type == OBJ_RECTANGLE || type == OBJ_TREND)
      ObjectMove(m_chart, name, 1, t2, p2);
   return true;
  }

//+------------------------------------------------------------------+
void CSMCCISDVisualizer::Line(const string name, const datetime t1, const double p, const datetime t2,
                              const color c, const ENUM_LINE_STYLE style, const int width, const string tip)
  {
   if(!Ensure(name, OBJ_TREND, t1, p, t2, p))
      return;
   ObjectSetInteger(m_chart, name, OBJPROP_COLOR, c);
   ObjectSetInteger(m_chart, name, OBJPROP_STYLE, style);
   ObjectSetInteger(m_chart, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(m_chart, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(m_chart, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(m_chart, name, OBJPROP_HIDDEN, true);
   ObjectSetString(m_chart, name, OBJPROP_TOOLTIP, tip);
  }

void CSMCCISDVisualizer::Box(const string name, const datetime t1, const double p1, const datetime t2, const double p2,
                             const color c, const bool fill, const ENUM_LINE_STYLE style, const string tip)
  {
   if(!Ensure(name, OBJ_RECTANGLE, t1, p1, t2, p2))
      return;
   ObjectSetInteger(m_chart, name, OBJPROP_COLOR, c);
   ObjectSetInteger(m_chart, name, OBJPROP_FILL, fill);
   ObjectSetInteger(m_chart, name, OBJPROP_BACK, true);
   ObjectSetInteger(m_chart, name, OBJPROP_STYLE, style);
   ObjectSetInteger(m_chart, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(m_chart, name, OBJPROP_HIDDEN, true);
   ObjectSetString(m_chart, name, OBJPROP_TOOLTIP, tip);
  }

void CSMCCISDVisualizer::Arrow(const string name, const datetime t, const double p, const int code, const color c,
                               const ENUM_ARROW_ANCHOR anchor, const string tip)
  {
   if(!Ensure(name, OBJ_ARROW, t, p))
      return;
   ObjectSetInteger(m_chart, name, OBJPROP_ARROWCODE, code);
   ObjectSetInteger(m_chart, name, OBJPROP_COLOR, c);
   ObjectSetInteger(m_chart, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(m_chart, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(m_chart, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(m_chart, name, OBJPROP_HIDDEN, true);
   ObjectSetString(m_chart, name, OBJPROP_TOOLTIP, tip);
  }

void CSMCCISDVisualizer::Label(const string name, const datetime t, const double p, const string text, const color c,
                               const ENUM_ANCHOR_POINT anchor)
  {
   if(!Ensure(name, OBJ_TEXT, t, p))
      return;
   ObjectSetString(m_chart, name, OBJPROP_TEXT, text);
   ObjectSetInteger(m_chart, name, OBJPROP_COLOR, c);
   ObjectSetInteger(m_chart, name, OBJPROP_FONTSIZE, m_v.fontSize);
   ObjectSetInteger(m_chart, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(m_chart, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(m_chart, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
//| Records are kept sorted by id, so lookups are log2(n).            |
//+------------------------------------------------------------------+
int CSMCCISDVisualizer::FindRec(const long id) const
  {
   int lo = 0, hi = ArraySize(m_rec) - 1;
   while(lo <= hi)
     {
      int mid = (lo + hi) >> 1;
      if(m_rec[mid].id == id)
         return mid;
      if(m_rec[mid].id < id) lo = mid + 1;
      else                   hi = mid - 1;
     }
   return -(lo + 1);
  }

//--- true when this record must be drawn again; always marks it as seen
bool CSMCCISDVisualizer::RecChanged(const SCISDDrawSig &sig, bool &shapeChanged)
  {
   shapeChanged = true;
   int idx = FindRec(sig.id);
   if(idx >= 0)
     {
      //--- which objects exist depends on these; the rest only moves them
      shapeChanged = (m_rec[idx].state != sig.state || m_rec[idx].confirmTime != sig.confirmTime ||
                      m_rec[idx].retraceTime != sig.retraceTime || m_rec[idx].sdRange != sig.sdRange);
      bool same = (m_rec[idx].state == sig.state && m_rec[idx].seriesEnd == sig.seriesEnd &&
                   m_rec[idx].setupTime == sig.setupTime && m_rec[idx].confirmTime == sig.confirmTime &&
                   m_rec[idx].retraceTime == sig.retraceTime && m_rec[idx].right == sig.right &&
                   m_rec[idx].level == sig.level && m_rec[idx].seriesHigh == sig.seriesHigh &&
                   m_rec[idx].seriesLow == sig.seriesLow && m_rec[idx].confirmPrice == sig.confirmPrice &&
                   m_rec[idx].retracePrice == sig.retracePrice && m_rec[idx].sdRange == sig.sdRange);
      m_rec[idx] = sig;
      m_rec[idx].seen = true;
      return !same;
     }
   int at = -idx - 1;
   int n = ArraySize(m_rec);
   ArrayResize(m_rec, n + 1, 64);
   for(int k = n; k > at; k--)
      m_rec[k] = m_rec[k - 1];
   m_rec[at] = sig;
   m_rec[at].seen = true;
   return true;
  }

void CSMCCISDVisualizer::DropRec(const int idx)
  {
   int n = ArraySize(m_rec);
   for(int k = idx + 1; k < n; k++)
      m_rec[k - 1] = m_rec[k];
   ArrayResize(m_rec, n - 1, 64);
  }

//--- sweeps never change once detected: draw each one once
bool CSMCCISDVisualizer::SweepDrawn(const long id)
  {
   int lo = 0, hi = ArraySize(m_sweep) - 1;
   while(lo <= hi)
     {
      int mid = (lo + hi) >> 1;
      if(m_sweep[mid] == id)
        {
         m_sweepSeen[mid] = true;
         return true;
        }
      if(m_sweep[mid] < id) lo = mid + 1;
      else                  hi = mid - 1;
     }
   int n = ArraySize(m_sweep);
   ArrayResize(m_sweep, n + 1, 64);
   ArrayResize(m_sweepSeen, n + 1, 64);
   for(int k = n; k > lo; k--)
     {
      m_sweep[k]     = m_sweep[k - 1];
      m_sweepSeen[k] = m_sweepSeen[k - 1];
     }
   m_sweep[lo]     = id;
   m_sweepSeen[lo] = true;
   return false;
  }

void CSMCCISDVisualizer::DeleteRecordObjects(const long id)
  {
   string kinds[] = {"SER", "SUL", "SUT", "LVL", "LVT", "CFA", "RTZ", "RTA", "RTT", "SDR"};
   for(int k = 0; k < ArraySize(kinds); k++)
      DeleteObj(Name(kinds[k], id));
   for(int k = 0; k < SMC_CISD_MAX_SD; k++)
     {
      string extra = "_" + IntegerToString(k);
      DeleteObj(Name("SD", id, extra));
      DeleteObj(Name("SDT", id, extra));
     }
  }

void CSMCCISDVisualizer::DeleteSweepObjects(const long id)
  {
   DeleteObj(Name("SWL", id));
   DeleteObj(Name("SWA", id));
   DeleteObj(Name("SWT", id));
  }

//+------------------------------------------------------------------+
void CSMCCISDVisualizer::DrawSweep(const SCISDSweep &s)
  {
   if(SweepDrawn(s.id))
      return;                          // already on the chart, unchanged by definition
   bool bull = (s.dir == SMC_DIR_BULL);
   string tip = StringFormat("%s liquidity sweep #%I64d\nSwept swing %s @ %s\nSweep bar %s @ %s",
                             bull ? "Sell-side" : "Buy-side", s.id, TimeToString(s.swingTime),
                             DoubleToString(s.swingPrice, _Digits), TimeToString(s.time), DoubleToString(s.price, _Digits));
   Line(Name("SWL", s.id), s.swingTime, s.swingPrice, s.time, m_v.sweepColor, STYLE_DOT, 1, tip);
   Arrow(Name("SWA", s.id), s.time, s.price, 159, m_v.sweepColor, bull ? ANCHOR_TOP : ANCHOR_BOTTOM, tip);
   Label(Name("SWT", s.id), s.time, s.price, bull ? "SSL sweep" : "BSL sweep", m_v.sweepColor,
         bull ? ANCHOR_LEFT_UPPER : ANCHOR_LEFT_LOWER);
  }

//+------------------------------------------------------------------+
void CSMCCISDVisualizer::DrawRecord(const SCISD &c, const int periodSec, const datetime lastTime)
  {
   bool bull = (c.dir == SMC_DIR_BULL);
   bool confirmed = SMC_CISDConfirmedState(c.state);
   bool active = (c.state == CISD_ST_CONFIRMED && c.endTime == 0) || c.state == CISD_ST_RETRACED;
   color dirColor = bull ? m_v.bullColor : m_v.bearColor;
   color lvlColor = (c.state == CISD_ST_INVALIDATED || c.state == CISD_ST_EXPIRED) ? m_v.inactiveColor : dirColor;
   string tf = SMC_TFText(c.timeframe);
   datetime ext = (datetime)(m_v.extendBars * periodSec);
   //--- right edge of the retracement area: the only part that follows the last candle
   datetime right = (c.retraceTime > 0) ? (datetime)(c.retraceTime + periodSec)
                    : (c.endTime > 0 ? c.endTime : (datetime)(lastTime + ext));

   SCISDDrawSig sig;
   sig.id           = c.id;
   sig.state        = (int)c.state;
   sig.seriesEnd    = c.seriesEndTime;
   sig.setupTime    = c.setupTime;
   sig.confirmTime  = c.confirmTime;
   sig.retraceTime  = c.retraceTime;
   sig.right        = right;
   sig.level        = c.level;
   sig.seriesHigh   = c.seriesHigh;
   sig.seriesLow    = c.seriesLow;
   sig.confirmPrice = c.confirmPrice;
   sig.retracePrice = c.retracePrice;
   sig.sdRange      = c.sdRange;
   sig.seen         = true;
   bool shapeChanged = true;
   if(!RecChanged(sig, shapeChanged))
      return;                          // identical objects are already on the chart
   //--- only a different set of objects needs a clean slate; a zone that merely
   //--- extends is moved in place by Ensure()
   if(shapeChanged)
      DeleteRecordObjects(c.id);

   //--- candle series (reference range)
   string tip = StringFormat("CISD #%I64d %s %s [%s]\nSeries: %d %s candles %s .. %s\nRange: %s - %s\nLevel: %s%s",
                             c.id, bull ? "Bullish" : "Bearish", tf, SMC_CISDStateText(c.state), c.seriesCount,
                             bull ? "bearish" : "bullish", TimeToString(c.seriesStartTime), TimeToString(c.seriesEndTime),
                             DoubleToString(c.seriesLow, _Digits), DoubleToString(c.seriesHigh, _Digits),
                             DoubleToString(c.level, _Digits),
                             c.hasSweep ? StringFormat("\nSweep: %s @ %s (swing %s)", TimeToString(c.sweepTime),
                                                       DoubleToString(c.sweepPrice, _Digits), DoubleToString(c.sweptSwingPrice, _Digits)) : "");
   Box(Name("SER", c.id), c.seriesStartTime, c.seriesHigh, (datetime)(c.seriesEndTime + periodSec), c.seriesLow,
       m_v.seriesColor, false, STYLE_DOT, tip);

   if(!confirmed)
     {
      //--- setup only: dashed candidate level, clearly not a confirmed CISD
      Line(Name("SUL", c.id), c.seriesStartTime, c.level, (datetime)(c.setupTime + ext), dirColor, STYLE_DASH, 1, tip);
      Label(Name("SUT", c.id), c.seriesStartTime, c.level, StringFormat("CISD setup %s", tf), dirColor,
            bull ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER);
      return;
     }

   //--- confirmation close + CISD level
   if(m_v.showConfirm)
     {
      Line(Name("LVL", c.id), c.seriesStartTime, c.level, (datetime)(c.confirmTime + ext), lvlColor, STYLE_SOLID, 2, tip);
      Label(Name("LVT", c.id), c.seriesStartTime, c.level,
            StringFormat("%s CISD %s #%I64d", bull ? "Bull" : "Bear", tf, c.id), lvlColor,
            bull ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER);
      Arrow(Name("CFA", c.id), c.confirmTime, c.confirmPrice, bull ? 233 : 234, dirColor,
            bull ? ANCHOR_TOP : ANCHOR_BOTTOM,
            StringFormat("CISD #%I64d confirmation close %s @ %s", c.id, DoubleToString(c.confirmPrice, _Digits),
                         TimeToString(c.confirmTime)));
     }

   //--- retracement / entry area
   if(m_v.showRetrace && c.state != CISD_ST_INVALIDATED)
     {
      double zTop = bull ? c.level : c.seriesHigh;
      double zBot = bull ? c.seriesLow : c.level;
      Box(Name("RTZ", c.id), c.confirmTime, zTop, right, zBot, m_v.retraceColor, true, STYLE_SOLID,
          StringFormat("CISD #%I64d retracement area %s - %s", c.id, DoubleToString(zBot, _Digits), DoubleToString(zTop, _Digits)));
      if(c.retraceTime > 0)
        {
         Arrow(Name("RTA", c.id), c.retraceTime, c.retracePrice, 159, m_v.retraceColor,
               bull ? ANCHOR_TOP : ANCHOR_BOTTOM,
               StringFormat("CISD #%I64d retracement / entry @ %s", c.id, DoubleToString(c.retracePrice, _Digits)));
         Label(Name("RTT", c.id), c.retraceTime, c.retracePrice, "Entry", dirColor,
               bull ? ANCHOR_LEFT_UPPER : ANCHOR_LEFT_LOWER);
        }
     }

   //--- standard deviation projections (analysis only)
   if(active && c.sdRange > 0.0)
     {
      datetime t2 = (datetime)(c.confirmTime + ext);
      if(m_v.showSD)
         for(int k = 0; k < m_v.sdCount; k++)
           {
            double price = SMC_CISDDeviationPrice(c, m_v.sdLevels[k]);
            string key = "_" + IntegerToString(k);
            Line(Name("SD", c.id, key), c.confirmTime, price, t2, m_v.sdColor, STYLE_DOT, 1,
                 StringFormat("CISD #%I64d SD %.2f = %s", c.id, m_v.sdLevels[k], DoubleToString(price, _Digits)));
            Label(Name("SDT", c.id, key), t2, price, StringFormat("SD %.1f", m_v.sdLevels[k]), m_v.sdColor, ANCHOR_LEFT);
           }
      if(m_v.showReversalZone)
        {
         double a = SMC_CISDDeviationPrice(c, -2.0), b = SMC_CISDDeviationPrice(c, -2.5);
         Box(Name("SDR", c.id), c.confirmTime, MathMax(a, b), t2, MathMin(a, b), m_v.sdColor, false, STYLE_DASH,
             StringFormat("CISD #%I64d -2 / -2.5 SD reversal area", c.id));
        }
     }
  }

//+------------------------------------------------------------------+
//| Full redraw from engine state (cheap: newest maxDrawn items).    |
//+------------------------------------------------------------------+
void CSMCCISDVisualizer::RedrawAll(const CSMCCISDEngine &engine)
  {
   for(int k = 0; k < ArraySize(m_rec); k++)
      m_rec[k].seen = false;
   for(int k = 0; k < ArraySize(m_sweepSeen); k++)
      m_sweepSeen[k] = false;
   SCISDSettings s;
   engine.GetSettings(s);
   int ps = PeriodSeconds(s.timeframe);
   datetime lastTime = engine.LastProcessedTime();

   if(m_v.showSweep && s.useSweep)
     {
      SCISDSweep sw;
      int from = MathMax(0, engine.SweepCount() - m_v.maxDrawn);
      for(int k = from; k < engine.SweepCount(); k++)
         if(engine.GetSweep(k, sw))
            DrawSweep(sw);
     }

   //--- newest records that are setups or confirmed CISDs
   SCISD c;
   int drawn = 0;
   for(int k = engine.Count() - 1; k >= 0 && drawn < m_v.maxDrawn; k--)
     {
      if(!engine.Get(k, c) || c.state == CISD_ST_SETUP_FAILED || c.state == CISD_ST_SETUP_REPLACED)
         continue;
      DrawRecord(c, ps, lastTime);
      drawn++;
     }

   //--- anything that dropped out of the drawn window leaves the chart
   for(int k = ArraySize(m_rec) - 1; k >= 0; k--)
      if(!m_rec[k].seen)
        {
         DeleteRecordObjects(m_rec[k].id);
         DropRec(k);
        }
   for(int k = ArraySize(m_sweep) - 1; k >= 0; k--)
      if(!m_sweepSeen[k])
        {
         DeleteSweepObjects(m_sweep[k]);
         ArrayRemove(m_sweep, k, 1);
         ArrayRemove(m_sweepSeen, k, 1);
        }
   ChartRedraw(m_chart);
  }

#endif // SMC_CISD_VISUAL_MQH
