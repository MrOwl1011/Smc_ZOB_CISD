//+------------------------------------------------------------------+
//|                                           SMC_Connect_Visual.mqh |
//|  HTF OB -> LTF CISD relationship objects (prefix "SMCCONN_").    |
//|                                                                  |
//|  One block per RETEST SEQUENCE (Multi retest draws R1, R2, R3     |
//|  from the same Order Block): retest marker, "CISD ACTIVE" line,   |
//|  liquidity sweep, then every CISD of that sequence with a link    |
//|  line back to its retest. Standard OB, ZOrder and standalone CISD |
//|  objects are not touched.                                        |
//+------------------------------------------------------------------+
#ifndef SMC_CONNECT_VISUAL_MQH
#define SMC_CONNECT_VISUAL_MQH

#include "SMC_Connect_Engine.mqh"

struct SConnVisualSettings
  {
   string            prefix;
   bool              showSweep;         // CISD panel switches
   bool              showConfirm;
   bool              showRetrace;
   int               maxDrawn;          // newest sequences drawn
   int               extendBars;
   int               fontSize;
   color             linkColor;
   color             bullColor;
   color             bearColor;
   color             seriesColor;
   color             sweepColor;
   color             retraceColor;
   color             inactiveColor;
  };

//--- what a drawn sequence looks like on the chart: an unchanged sequence would be
//--- redrawn with identical objects, so it is skipped instead
struct SConnDrawSig
  {
   long              id;
   int               state, obState, hits, retestCount, seqCount, cisdCount;
   datetime          retestTime, cisdStartTime, activatedTime, endTime, obEndTime;
   datetime          confirmTime, sweepTime, lastHitTime, lastRetraceTime, right;
   double            retestPrice, top, bottom;
   bool              seen;
  };

class CSMCConnVisualizer
  {
private:
   SConnVisualSettings m_v;
   long              m_chart;
   SConnDrawSig      m_seq[];          // sequences currently on the chart (sorted by id)

   int               FindSeq(const long id) const;
   bool              SeqChanged(const SConnDrawSig &sig, int &oldHits, bool &shapeChanged);
   void              DeleteSeqObjects(const long id, const int hits);
   void              DeleteObj(const string name)
     { if(ObjectFind(m_chart, name) >= 0) ObjectDelete(m_chart, name); }
   bool              Ensure(const string name, const ENUM_OBJECT type, const datetime t1, const double p1,
                            const datetime t2 = 0, const double p2 = 0.0);

   void              Seg(const string name, const datetime t1, const double p1, const datetime t2, const double p2,
                         const color c, const ENUM_LINE_STYLE style, const int width, const string tip);
   void              Box(const string name, const datetime t1, const double p1, const datetime t2, const double p2,
                         const color c, const string tip);
   void              Arrow(const string name, const datetime t, const double p, const int code, const color c,
                           const ENUM_ARROW_ANCHOR anchor, const string tip);
   void              Label(const string name, const datetime t, const double p, const string text, const color c,
                           const ENUM_ANCHOR_POINT anchor);
   void              DrawSeq(const SConnSetup &s, const SConnSeq &q, const SConnCISDHit &hits[],
                             const int cisdPS, const datetime lastTime);

public:
                     CSMCConnVisualizer(void) : m_chart(0) { ZeroMemory(m_v); }
   void              Init(const SConnVisualSettings &v, const long chart = 0)
     { m_v = v; m_chart = chart; ArrayResize(m_seq, 0, 64); }
   //--- new display options change how everything is drawn: start from an empty chart
   void              SetSettings(const SConnVisualSettings &v)
     { ObjectsDeleteAll(m_chart, m_v.prefix); m_v = v; ArrayResize(m_seq, 0, 64); }
   void              RedrawAll(const CSMCConnection &conn);
   void              Cleanup(void) { ObjectsDeleteAll(m_chart, m_v.prefix); ArrayResize(m_seq, 0, 64); }
  };

//+------------------------------------------------------------------+
//| Create the object once and move it afterwards instead of deleting |
//| and recreating the whole picture on every candle.                 |
//+------------------------------------------------------------------+
bool CSMCConnVisualizer::Ensure(const string name, const ENUM_OBJECT type, const datetime t1, const double p1,
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
//| Sequences are kept sorted by id, so lookups are log2(n).          |
//+------------------------------------------------------------------+
int CSMCConnVisualizer::FindSeq(const long id) const
  {
   int lo = 0, hi = ArraySize(m_seq) - 1;
   while(lo <= hi)
     {
      int mid = (lo + hi) >> 1;
      if(m_seq[mid].id == id)
         return mid;
      if(m_seq[mid].id < id) lo = mid + 1;
      else                   hi = mid - 1;
     }
   return -(lo + 1);
  }

//--- true when this sequence must be drawn again; always marks it as seen
bool CSMCConnVisualizer::SeqChanged(const SConnDrawSig &sig, int &oldHits, bool &shapeChanged)
  {
   oldHits = 0;
   shapeChanged = true;
   int idx = FindSeq(sig.id);
   if(idx >= 0)
     {
      oldHits = m_seq[idx].hits;
      //--- which objects exist depends on these; the rest only moves them
      shapeChanged = (m_seq[idx].hits != sig.hits || m_seq[idx].state != sig.state ||
                      m_seq[idx].obState != sig.obState || m_seq[idx].confirmTime != sig.confirmTime ||
                      m_seq[idx].sweepTime != sig.sweepTime || m_seq[idx].endTime != sig.endTime ||
                      m_seq[idx].activatedTime != sig.activatedTime ||
                      m_seq[idx].lastRetraceTime != sig.lastRetraceTime);
      bool same = (m_seq[idx].state == sig.state && m_seq[idx].obState == sig.obState &&
                   m_seq[idx].hits == sig.hits && m_seq[idx].retestCount == sig.retestCount &&
                   m_seq[idx].seqCount == sig.seqCount && m_seq[idx].cisdCount == sig.cisdCount &&
                   m_seq[idx].retestTime == sig.retestTime && m_seq[idx].cisdStartTime == sig.cisdStartTime &&
                   m_seq[idx].activatedTime == sig.activatedTime && m_seq[idx].endTime == sig.endTime &&
                   m_seq[idx].obEndTime == sig.obEndTime && m_seq[idx].confirmTime == sig.confirmTime &&
                   m_seq[idx].sweepTime == sig.sweepTime && m_seq[idx].lastHitTime == sig.lastHitTime &&
                   m_seq[idx].lastRetraceTime == sig.lastRetraceTime && m_seq[idx].right == sig.right &&
                   m_seq[idx].retestPrice == sig.retestPrice && m_seq[idx].top == sig.top &&
                   m_seq[idx].bottom == sig.bottom);
      m_seq[idx] = sig;
      m_seq[idx].seen = true;
      return !same;
     }
   int at = -idx - 1;
   int n = ArraySize(m_seq);
   ArrayResize(m_seq, n + 1, 64);
   for(int k = n; k > at; k--)
      m_seq[k] = m_seq[k - 1];
   m_seq[at] = sig;
   m_seq[at].seen = true;
   return true;
  }

void CSMCConnVisualizer::DeleteSeqObjects(const long id, const int hits)
  {
   string p = m_v.prefix + "Q" + IntegerToString(id) + "_";
   DeleteObj(p + "RT");
   DeleteObj(p + "RTT");
   DeleteObj(p + "MON");
   DeleteObj(p + "MONT");
   for(int h = 0; h < hits; h++)
     {
      string z = p + "H" + IntegerToString(h) + "_";
      DeleteObj(z + "SER");
      DeleteObj(z + "LVL");
      DeleteObj(z + "CFA");
      DeleteObj(z + "LNK");
      DeleteObj(z + "LNT");
      DeleteObj(z + "RTA");
      DeleteObj(z + "RTX");
     }
   DeleteObj(p + "SWL");
   DeleteObj(p + "SWA");
   DeleteObj(p + "SWT");
  }

//+------------------------------------------------------------------+
void CSMCConnVisualizer::Seg(const string name, const datetime t1, const double p1, const datetime t2, const double p2,
                             const color c, const ENUM_LINE_STYLE style, const int width, const string tip)
  {
   if(!Ensure(name, OBJ_TREND, t1, p1, t2, p2))
      return;
   ObjectSetInteger(m_chart, name, OBJPROP_COLOR, c);
   ObjectSetInteger(m_chart, name, OBJPROP_STYLE, style);
   ObjectSetInteger(m_chart, name, OBJPROP_WIDTH, width);
   ObjectSetInteger(m_chart, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(m_chart, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(m_chart, name, OBJPROP_HIDDEN, true);
   ObjectSetString(m_chart, name, OBJPROP_TOOLTIP, tip);
  }

void CSMCConnVisualizer::Box(const string name, const datetime t1, const double p1, const datetime t2, const double p2,
                             const color c, const string tip)
  {
   if(!Ensure(name, OBJ_RECTANGLE, t1, p1, t2, p2))
      return;
   ObjectSetInteger(m_chart, name, OBJPROP_COLOR, c);
   ObjectSetInteger(m_chart, name, OBJPROP_FILL, false);
   ObjectSetInteger(m_chart, name, OBJPROP_BACK, true);
   ObjectSetInteger(m_chart, name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(m_chart, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(m_chart, name, OBJPROP_HIDDEN, true);
   ObjectSetString(m_chart, name, OBJPROP_TOOLTIP, tip);
  }

void CSMCConnVisualizer::Arrow(const string name, const datetime t, const double p, const int code, const color c,
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

void CSMCConnVisualizer::Label(const string name, const datetime t, const double p, const string text, const color c,
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
void CSMCConnVisualizer::DrawSeq(const SConnSetup &s, const SConnSeq &q, const SConnCISDHit &hits[],
                                 const int cisdPS, const datetime lastTime)
  {
   bool bull = (q.dir == SMC_DIR_BULL);
   bool dead = (q.state == CONN_INVALIDATED || q.state == CONN_EXPIRED);
   color dc = bull ? m_v.bullColor : m_v.bearColor;
   color lc = dead ? m_v.inactiveColor : m_v.linkColor;
   string p = m_v.prefix + "Q" + IntegerToString(q.id) + "_";
   string obtf = SMC_TFText(s.obTF), tf = SMC_TFText(s.cisdTF);
   string kind = SMC_ConnKindText(q.kind);
   string rTag = StringFormat("R%d", q.retestNo);
   int nHits = ArraySize(hits);

   //--- right edge of the monitoring line: the only part that follows the last candle
   datetime to = q.hasCISD ? (datetime)(q.cisd.confirmTime + cisdPS)
                 : (q.endTime > 0 ? q.endTime : (datetime)(lastTime + m_v.extendBars * cisdPS));

   SConnDrawSig sig;
   sig.id              = q.id;
   sig.state           = (int)q.state;
   sig.obState         = (int)s.state;
   sig.hits            = nHits;
   sig.retestCount     = s.retestCount;
   sig.seqCount        = s.seqCount;
   sig.cisdCount       = s.cisdCount;
   sig.retestTime      = q.retestTime;
   sig.cisdStartTime   = q.cisdStartTime;
   sig.activatedTime   = q.activatedTime;
   sig.endTime         = q.endTime;
   sig.obEndTime       = s.endTime;
   sig.confirmTime     = q.hasCISD ? q.cisd.confirmTime : 0;
   sig.sweepTime       = q.sweepTime;
   sig.lastHitTime     = (nHits > 0) ? hits[nHits - 1].confirmTime : 0;
   sig.lastRetraceTime = (nHits > 0) ? hits[nHits - 1].retraceTime : 0;
   sig.right           = to;
   sig.retestPrice     = q.retestPrice;
   sig.top             = s.top;
   sig.bottom          = s.bottom;
   sig.seen            = true;

   int oldHits = 0;
   bool shapeChanged = true;
   if(!SeqChanged(sig, oldHits, shapeChanged))
      return;                          // identical objects are already on the chart
   //--- only a different set of objects needs a clean slate; a line that merely
   //--- extends is moved in place by Ensure()
   if(shapeChanged)
      DeleteSeqObjects(q.id, MathMax(oldHits, nHits));

   string tip = StringFormat("%s %s %s #%I64d  retest #%d (sequence #%I64d) [%s]\nZone %s - %s\nRetest %s @ %s\n"
                             "CISD %s monitoring from %s\nOB retests: %d, sequences: %d, CISDs: %d%s",
                             obtf, bull ? "Bullish" : "Bearish", kind, q.obId, q.retestNo, q.id,
                             SMC_ConnStateText(q.state), DoubleToString(s.bottom, _Digits), DoubleToString(s.top, _Digits),
                             TimeToString(q.retestTime), DoubleToString(q.retestPrice, _Digits), tf,
                             TimeToString(q.cisdStartTime), s.retestCount, s.seqCount, s.cisdCount,
                             s.state == CONN_INVALIDATED ? StringFormat("\nOB %s @ %s - CISD search stopped",
                                                                        s.deadByMitigation ? "MITIGATED" : "INVALIDATED",
                                                                        TimeToString(s.endTime)) : "");

   //--- OB retest
   Arrow(p + "RT", q.retestTime, q.retestPrice, 108, lc, bull ? ANCHOR_TOP : ANCHOR_BOTTOM, tip);
   Label(p + "RTT", q.retestTime, q.retestPrice, StringFormat("RETEST %s %s %s#%I64d", rTag, obtf, kind, q.obId), lc,
         bull ? ANCHOR_LEFT_UPPER : ANCHOR_LEFT_LOWER);

   //--- monitoring window (retest -> first confirmation / end / now)
   if(to > q.retestTime)
     {
      Seg(p + "MON", q.retestTime, q.retestPrice, to, q.retestPrice, lc, STYLE_DASH, 1, tip);
      if(!q.hasCISD)
         Label(p + "MONT", to, q.retestPrice,
               dead ? StringFormat("%s %s", rTag, SMC_ConnStateText(q.state))
                    : (q.activatedTime > 0 ? StringFormat("%s CISD ACTIVE %s", rTag, tf)
                                           : StringFormat("%s CISD from %s", rTag, TimeToString(q.cisdStartTime, TIME_MINUTES))),
               lc, ANCHOR_LEFT);
     }

   //--- liquidity sweep of this sequence
   if(m_v.showSweep && q.sweepTime > 0)
     {
      string st = StringFormat("%s sweep %s @ %s (swing %s)", bull ? "Sell-side" : "Buy-side", TimeToString(q.sweepTime),
                               DoubleToString(q.sweepPrice, _Digits), DoubleToString(q.sweepSwingPrice, _Digits));
      Seg(p + "SWL", q.sweepSwingTime, q.sweepSwingPrice, q.sweepTime, q.sweepSwingPrice, m_v.sweepColor, STYLE_DOT, 1, st);
      Arrow(p + "SWA", q.sweepTime, q.sweepPrice, 159, m_v.sweepColor, bull ? ANCHOR_TOP : ANCHOR_BOTTOM, st);
      Label(p + "SWT", q.sweepTime, q.sweepPrice, bull ? "SSL sweep" : "BSL sweep", m_v.sweepColor,
            bull ? ANCHOR_LEFT_UPPER : ANCHOR_LEFT_LOWER);
     }

   //--- every CISD of this sequence
   for(int h = 0; h < nHits; h++)
     {
      string z = p + "H" + IntegerToString(h) + "_";
      string nth = (nHits > 1) ? StringFormat(" (%d/%d)", h + 1, nHits) : "";
      bool early = (hits[h].cisd.seriesStartTime < q.cisdStartTime);
      string htip = StringFormat("%s\nCISD #%I64d%s confirmed %s @ %s [%s]%s", tip, hits[h].cisdId, nth,
                                 TimeToString(hits[h].confirmTime), DoubleToString(hits[h].confirmPrice, _Digits),
                                 SMC_CISDStateText(hits[h].cisdState),
                                 early ? "\nCandle series began before the OB retest" : "");
      if(m_v.showConfirm)
        {
         Box(z + "SER", hits[h].cisd.seriesStartTime, hits[h].cisd.seriesHigh,
             (datetime)(hits[h].cisd.seriesEndTime + cisdPS), hits[h].cisd.seriesLow, m_v.seriesColor, htip);
         Seg(z + "LVL", hits[h].cisd.seriesStartTime, hits[h].cisd.level,
             (datetime)(hits[h].confirmTime + m_v.extendBars * cisdPS), hits[h].cisd.level, dc, STYLE_SOLID, 2, htip);
         Arrow(z + "CFA", hits[h].confirmTime, hits[h].confirmPrice, bull ? 233 : 234, dc,
               bull ? ANCHOR_TOP : ANCHOR_BOTTOM, htip);
         Seg(z + "LNK", q.retestTime, q.retestPrice, hits[h].confirmTime, hits[h].confirmPrice, m_v.linkColor,
             h == 0 ? STYLE_SOLID : STYLE_DOT, 2, htip);
         Label(z + "LNT", hits[h].confirmTime, hits[h].confirmPrice,
               StringFormat("%s %s#%I64d %s + %s CISD#%I64d = SETUP%s", obtf, kind, q.obId, rTag, tf, hits[h].cisdId, nth),
               m_v.linkColor, bull ? ANCHOR_LEFT_LOWER : ANCHOR_LEFT_UPPER);
        }
      if(m_v.showRetrace && hits[h].retraceTime > 0)
        {
         Arrow(z + "RTA", hits[h].retraceTime, hits[h].retracePrice, 159, m_v.retraceColor,
               bull ? ANCHOR_TOP : ANCHOR_BOTTOM, htip);
         Label(z + "RTX", hits[h].retraceTime, hits[h].retracePrice, "Entry", dc,
               bull ? ANCHOR_LEFT_UPPER : ANCHOR_LEFT_LOWER);
        }
     }
  }

//+------------------------------------------------------------------+
void CSMCConnVisualizer::RedrawAll(const CSMCConnection &conn)
  {
   for(int k = 0; k < ArraySize(m_seq); k++)
      m_seq[k].seen = false;
   SConnSettings s;
   conn.GetSettings(s);
   int ps = PeriodSeconds(s.cisdTF);
   datetime lastTime = (datetime)(conn.LastCISDTime() + ps);

   SConnSetup ob;
   SConnSeq q;
   SConnCISDHit hits[];
   int drawn = 0;
   for(int i = conn.SeqCount() - 1; i >= 0 && drawn < m_v.maxDrawn; i--)
     {
      if(!conn.GetSeq(i, q))
         continue;
      int k = conn.FindSetup(q.setupId);
      if(k < 0 || !conn.Get(k, ob))
         continue;
      conn.HitsOfSeq(q.id, hits);
      DrawSeq(ob, q, hits, ps, lastTime);
      drawn++;
     }

   //--- sequences that dropped out of the drawn window leave the chart
   for(int k = ArraySize(m_seq) - 1; k >= 0; k--)
      if(!m_seq[k].seen)
        {
         DeleteSeqObjects(m_seq[k].id, m_seq[k].hits);
         ArrayRemove(m_seq, k, 1);
        }
   ChartRedraw(m_chart);
  }

#endif // SMC_CONNECT_VISUAL_MQH
