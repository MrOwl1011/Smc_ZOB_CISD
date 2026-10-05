//+------------------------------------------------------------------+
//|                                                SMC_OB_Visual.mqh |
//|  SPDX-License-Identifier: MIT                                    |
//|  https://github.com/MrOwl1011/Smc_ZOB_CISD                       |
//|  Visualization Engine. Read-only consumer of detector state and  |
//|  events: drawing can never influence detection.                  |
//|  Recent BOS / swing events are kept so the chart can be fully    |
//|  redrawn when display options change (no rescan needed).         |
//+------------------------------------------------------------------+
#ifndef SMC_OB_VISUAL_MQH
#define SMC_OB_VISUAL_MQH

#include "SMC_OB_Engine.mqh"

struct SSMCVisualSettings
  {
   string            prefix;
   bool              showBull;
   bool              showBear;
   bool              showInactive;     // mitigated / invalidated / expired / superseded zones
   bool              showBOS;
   bool              showSwings;
   bool              showFVG;
   bool              showRetest;
   bool              showRetestStart;  // small mark where retest detection begins
   bool              showLabels;
   bool              fillZones;
   string            bullLabel;        // "Bull OB" / "ZOrder Bullish"
   string            bearLabel;        // "Bear OB" / "ZOrder Bearish"
   ENUM_LINE_STYLE   liveStyle;        // border style of live zones (standard: STYLE_SOLID)
   int               zoneWidth;        // border width (standard: 1)
   int               periodSeconds;    // OB timeframe bar length for extension (0 = chart)
   int               extendBars;
   int               maxBOSDrawn;
   int               labelFontSize;
   color             bullColor;
   color             bearColor;
   color             mitigatedColor;
   color             inactiveColor;
   color             bullFVGColor;
   color             bearFVGColor;
   color             bosBullColor;
   color             bosBearColor;
   color             retestColor;
   color             swingColor;
  };

//+------------------------------------------------------------------+
//| Everything DrawOB() reads that can still change after an order    |
//| block is confirmed. Redrawing an unchanged zone would produce     |
//| byte-identical objects, so the draw is skipped instead.           |
//+------------------------------------------------------------------+
struct SSMCDrawCache
  {
   long              id;
   ENUM_SMC_OB_STATE state;
   datetime          right;            // extending right edge (moves with the last bar)
   datetime          endTime;
   datetime          fvgLeftTime;
   datetime          firstRetestTime;
   double            top, bottom, fvgTop, fvgBottom, firstRetestPrice;
   int               retestCount;
   int               seriesCount;
   long              overlapWithId;
   bool              hasFVG;
   bool              fvgLate;
  };

class CSMCVisualizer
  {
private:
   SSMCVisualSettings m_v;
   long              m_chart;
   SSMCEvent         m_bos[];          // newest maxBOSDrawn BOS events (oldest first)
   SSMCEvent         m_swings[];
   SSMCDrawCache     m_cache[];        // sorted by id: what is currently on the chart

   string            Name(const string kind, const long id) const { return m_v.prefix + kind + "_" + IntegerToString(id); }
   string            BOSKey(const SSMCEvent &e) const { return IntegerToString((long)e.time2) + "_" + IntegerToString(e.dir); }
   string            SwingName(const SSMCEvent &e) const { return m_v.prefix + "SW_" + IntegerToString((long)e.time) + "_" + IntegerToString(e.dir); }
   bool              Ensure(const string name, const ENUM_OBJECT type,
                            const datetime t1, const double p1, const datetime t2 = 0, const double p2 = 0.0);
   int               CacheFind(const long id) const;
   bool              CacheHit(const SOrderBlock &o, const datetime right);
   void              CacheDrop(const long id);
   void              DeleteObj(const string name) { if(ObjectFind(m_chart, name) >= 0) ObjectDelete(m_chart, name); }
   void              DeleteBOS(const SSMCEvent &e);
   void              Store(SSMCEvent &ring[], const SSMCEvent &e, const bool isBOS);

public:
                     CSMCVisualizer(void) : m_chart(0) {}
   void              Init(const SSMCVisualSettings &v, const long chartId = 0);
   //--- new display options invalidate every cached zone: they must all be drawn again
   void              SetSettings(const SSMCVisualSettings &v) { m_v = v; ArrayResize(m_cache, 0, 64); }
   void              DrawOB(const SOrderBlock &o, const datetime lastBarTime);
   void              DeleteOB(const long id);
   void              DrawBOS(const SSMCEvent &e);
   void              DrawSwing(const SSMCEvent &e);
   void              HandleEvents(const CSMCDetector &det, const datetime lastBarTime);
   void              RefreshLive(const CSMCDetector &det, const datetime lastBarTime);
   void              RedrawAll(const CSMCDetector &det, const datetime lastBarTime);
   void              Cleanup(void);
  };

//+------------------------------------------------------------------+
void CSMCVisualizer::Init(const SSMCVisualSettings &v, const long chartId)
  {
   m_v = v;
   m_chart = chartId;
   ArrayResize(m_bos, 0);
   ArrayResize(m_swings, 0);
   ArrayResize(m_cache, 0, 64);
  }

//+------------------------------------------------------------------+
bool CSMCVisualizer::Ensure(const string name, const ENUM_OBJECT type,
                            const datetime t1, const double p1, const datetime t2, const double p2)
  {
   //--- object calls are queued asynchronously, so ObjectMove() reports success for a name
   //--- that does not exist yet: ObjectFind() is the only reliable existence test
   if(ObjectFind(m_chart, name) < 0)
     {
      bool ok = (type == OBJ_RECTANGLE || type == OBJ_TREND)
                ? ObjectCreate(m_chart, name, type, 0, t1, p1, t2, p2)
                : ObjectCreate(m_chart, name, type, 0, t1, p1);
      if(!ok)
         return false;
      ObjectSetInteger(m_chart, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(m_chart, name, OBJPROP_HIDDEN, true);
      return true;
     }
   ObjectMove(m_chart, name, 0, t1, p1);
   if(type == OBJ_RECTANGLE || type == OBJ_TREND)
      ObjectMove(m_chart, name, 1, t2, p2);
   return true;
  }

//+------------------------------------------------------------------+
//| Cache lookup. Ids grow with every new order block, so the cache   |
//| stays sorted and can be searched in log2(n) steps.                |
//+------------------------------------------------------------------+
int CSMCVisualizer::CacheFind(const long id) const
  {
   int lo = 0, hi = ArraySize(m_cache) - 1;
   while(lo <= hi)
     {
      int mid = (lo + hi) >> 1;
      if(m_cache[mid].id == id)
         return mid;
      if(m_cache[mid].id < id) lo = mid + 1;
      else                     hi = mid - 1;
     }
   return -(lo + 1);                   // not found: -(insertion point + 1)
  }

//+------------------------------------------------------------------+
//| True when the chart already shows this exact zone. Otherwise the  |
//| cache is updated and the caller redraws.                          |
//+------------------------------------------------------------------+
bool CSMCVisualizer::CacheHit(const SOrderBlock &o, const datetime right)
  {
   SSMCDrawCache c;
   c.id               = o.id;
   c.state            = o.state;
   c.right            = right;
   c.endTime          = o.endTime;
   c.fvgLeftTime      = o.fvgLeftTime;
   c.firstRetestTime  = o.firstRetestTime;
   c.top              = o.top;
   c.bottom           = o.bottom;
   c.fvgTop           = o.fvgTop;
   c.fvgBottom        = o.fvgBottom;
   c.firstRetestPrice = o.firstRetestPrice;
   c.retestCount      = o.retestCount;
   c.seriesCount      = o.seriesCount;
   c.overlapWithId    = o.overlapWithId;
   c.hasFVG           = o.hasFVG;
   c.fvgLate          = o.fvgLate;

   int idx = CacheFind(o.id);
   if(idx >= 0)
     {
      if(m_cache[idx].state == c.state && m_cache[idx].right == c.right &&
         m_cache[idx].endTime == c.endTime && m_cache[idx].fvgLeftTime == c.fvgLeftTime &&
         m_cache[idx].firstRetestTime == c.firstRetestTime && m_cache[idx].top == c.top &&
         m_cache[idx].bottom == c.bottom && m_cache[idx].fvgTop == c.fvgTop &&
         m_cache[idx].fvgBottom == c.fvgBottom && m_cache[idx].firstRetestPrice == c.firstRetestPrice &&
         m_cache[idx].retestCount == c.retestCount && m_cache[idx].seriesCount == c.seriesCount &&
         m_cache[idx].overlapWithId == c.overlapWithId &&
         m_cache[idx].hasFVG == c.hasFVG && m_cache[idx].fvgLate == c.fvgLate)
         return true;                  // nothing that is drawn has changed
      m_cache[idx] = c;
      return false;
     }

   int at = -idx - 1;                  // keep the array sorted by id
   int n = ArraySize(m_cache);
   ArrayResize(m_cache, n + 1, 64);
   for(int k = n; k > at; k--)
      m_cache[k] = m_cache[k - 1];
   m_cache[at] = c;
   return false;
  }

//+------------------------------------------------------------------+
void CSMCVisualizer::CacheDrop(const long id)
  {
   int idx = CacheFind(id);
   if(idx < 0)
      return;
   int n = ArraySize(m_cache);
   for(int k = idx + 1; k < n; k++)
      m_cache[k - 1] = m_cache[k];
   ArrayResize(m_cache, n - 1, 64);
  }

//+------------------------------------------------------------------+
void CSMCVisualizer::DeleteBOS(const SSMCEvent &e)
  {
   DeleteObj(m_v.prefix + "BOS_" + BOSKey(e));
   DeleteObj(m_v.prefix + "BOST_" + BOSKey(e));
  }

//+------------------------------------------------------------------+
void CSMCVisualizer::Store(SSMCEvent &ring[], const SSMCEvent &e, const bool isBOS)
  {
   int n = ArraySize(ring);
   if(m_v.maxBOSDrawn <= 0)
      return;
   if(n >= m_v.maxBOSDrawn)
     {
      if(isBOS) DeleteBOS(ring[0]);
      else      DeleteObj(SwingName(ring[0]));
      for(int k = 1; k < n; k++)
         ring[k - 1] = ring[k];
      n--;
     }
   ArrayResize(ring, n + 1, 128);
   ring[n] = e;
  }

//+------------------------------------------------------------------+
void CSMCVisualizer::DrawOB(const SOrderBlock &o, const datetime lastBarTime)
  {
   bool dirVisible = (o.dir == SMC_DIR_BULL) ? m_v.showBull : m_v.showBear;
   bool visible = dirVisible && (SMC_IsLiveState(o.state) || m_v.showInactive);
   if(!visible)
     {
      DeleteOB(o.id);
      return;
     }

   //--- a zone keeps extending while it is still valid - mitigation included - and stops at the
   //--- CLOSE of the candle that invalidated, expired or superseded it: the zone was valid until
   //--- that candle closed, so on a lower chart timeframe it covers every minute of that candle.
   //--- (endTime is not used: the detector sets it at the first event, which may be mitigation.)
   int obPS = (m_v.periodSeconds > 0) ? m_v.periodSeconds : PeriodSeconds();
   datetime right;
   switch(o.state)
     {
      case SMC_OB_INVALIDATED: right = (datetime)(((o.invalidatedTime > 0) ? o.invalidatedTime : o.endTime) + obPS); break;
      case SMC_OB_EXPIRED:     right = (datetime)(((o.expiredTime > 0) ? o.expiredTime : o.endTime) + obPS);         break;
      case SMC_OB_SUPERSEDED:  right = (datetime)(o.endTime + obPS);                                               break;
      default:
         right = (datetime)(lastBarTime + (datetime)(m_v.extendBars * obPS));
         break;
     }
   //--- an unchanged zone would be redrawn with identical values on every tick
   if(CacheHit(o, right))
      return;

   color zoneColor = (o.dir == SMC_DIR_BULL) ? m_v.bullColor : m_v.bearColor;
   if(o.state == SMC_OB_MITIGATED)
      zoneColor = m_v.mitigatedColor;
   else if(!SMC_IsLiveState(o.state))
      zoneColor = m_v.inactiveColor;

   //--- zone (a ZOrder starts at the oldest candle of its series)
   datetime left = o.isZOrder ? o.seriesStartTime : o.obTime;
   string rect = Name("OB", o.id);
   if(Ensure(rect, OBJ_RECTANGLE, left, o.top, right, o.bottom))
     {
      ObjectSetInteger(m_chart, rect, OBJPROP_COLOR, zoneColor);
      ObjectSetInteger(m_chart, rect, OBJPROP_FILL, m_v.fillZones);
      ObjectSetInteger(m_chart, rect, OBJPROP_BACK, true);
      //--- border style and width never change: a zone is only extended, then stopped,
      //--- recoloured and relabelled when a closed candle mitigates / invalidates it
      ObjectSetInteger(m_chart, rect, OBJPROP_STYLE, m_v.liveStyle);
      ObjectSetInteger(m_chart, rect, OBJPROP_WIDTH, m_v.zoneWidth);
      ObjectSetString(m_chart, rect, OBJPROP_TOOLTIP,
                      StringFormat("%s #%I64d [%s]\n%s: %s\nZone: %s - %s\nConfirmed: %s (%s, level %s)\nLeg: %d bars, move %.2f x ATR, rel %.2f\nFVG: %s\nRetests: %d",
                                   o.dir == SMC_DIR_BULL ? m_v.bullLabel : m_v.bearLabel, o.id, SMC_StateText(o.state),
                                   o.isZOrder ? "Candles" : "Candle",
                                   o.isZOrder ? StringFormat("%s - %s (%d)", TimeToString(o.seriesStartTime),
                                                             TimeToString(o.obTime), o.seriesCount)
                                              : TimeToString(o.obTime),
                                   DoubleToString(o.bottom, _Digits), DoubleToString(o.top, _Digits),
                                   TimeToString(o.confirmTime), o.isChoch ? "CHoCH" : "BOS",
                                   DoubleToString(o.bosLevel, _Digits), o.legBars,
                                   o.atr > 0 ? o.netMove / o.atr : 0.0, o.relStrength,
                                   o.hasFVG ? (o.fvgLate ? "yes (linked next bar)" : "yes") : "no",
                                   o.retestCount));
     }
   else
      CacheDrop(o.id);                 // the zone is not on the chart: try again next time

   //--- retest-detection start: close of the candle that confirmed the OB. Price entering the
   //--- zone before this moment is not a retest, because the OB did not exist yet.
   string rs = Name("RS", o.id);
   if(m_v.showRetestStart)
     {
      datetime ts = (datetime)(o.confirmTime + obPS);
      if(Ensure(rs, OBJ_TREND, ts, o.top, ts, o.bottom))
        {
         ObjectSetInteger(m_chart, rs, OBJPROP_COLOR, zoneColor);
         ObjectSetInteger(m_chart, rs, OBJPROP_STYLE, STYLE_DOT);
         ObjectSetInteger(m_chart, rs, OBJPROP_WIDTH, 1);
         ObjectSetInteger(m_chart, rs, OBJPROP_RAY_RIGHT, false);
         ObjectSetString(m_chart, rs, OBJPROP_TOOLTIP,
                         StringFormat("%s #%I64d: retest detection starts @ %s", o.dir == SMC_DIR_BULL ? m_v.bullLabel : m_v.bearLabel,
                                      o.id, TimeToString(ts)));
        }
     }
   else
      DeleteObj(rs);

   //--- label
   string lbl = Name("OBL", o.id);
   if(m_v.showLabels)
     {
      string txt = StringFormat("%s #%I64d", o.dir == SMC_DIR_BULL ? m_v.bullLabel : m_v.bearLabel, o.id);
      if(o.isZOrder)               txt += " | " + IntegerToString(o.seriesCount) + " candles";
      if(o.hasFVG)                 txt += " | FVG";
      if(o.overlapWithId > 0)      txt += " | OVL";
      if(o.retestCount > 0)        txt += " | RT" + IntegerToString(o.retestCount);
      if(o.state != SMC_OB_ACTIVE && o.state != SMC_OB_RETESTED)
         txt += " | " + SMC_StateText(o.state);
      //--- standard OB labels sit below bull / above bear zones; ZOrder labels use the
      //--- opposite edge so both labels stay readable when the zones share an edge
      bool below = ((o.dir == SMC_DIR_BULL) != o.isZOrder);
      double lp = below ? o.bottom : o.top;
      if(Ensure(lbl, OBJ_TEXT, left, lp))
        {
         ObjectSetString(m_chart, lbl, OBJPROP_TEXT, txt);
         ObjectSetInteger(m_chart, lbl, OBJPROP_COLOR, zoneColor);
         ObjectSetInteger(m_chart, lbl, OBJPROP_FONTSIZE, m_v.labelFontSize);
         ObjectSetInteger(m_chart, lbl, OBJPROP_ANCHOR, below ? ANCHOR_LEFT_UPPER : ANCHOR_LEFT_LOWER);
        }
     }
   else
      DeleteObj(lbl);

   //--- FVG confluence
   string fvg = Name("FVG", o.id);
   if(m_v.showFVG && o.hasFVG)
     {
      if(Ensure(fvg, OBJ_RECTANGLE, o.fvgLeftTime, o.fvgTop, right, o.fvgBottom))
        {
         ObjectSetInteger(m_chart, fvg, OBJPROP_COLOR, o.dir == SMC_DIR_BULL ? m_v.bullFVGColor : m_v.bearFVGColor);
         ObjectSetInteger(m_chart, fvg, OBJPROP_FILL, false);
         ObjectSetInteger(m_chart, fvg, OBJPROP_BACK, true);
         ObjectSetInteger(m_chart, fvg, OBJPROP_STYLE, STYLE_DASHDOT);
         ObjectSetString(m_chart, fvg, OBJPROP_TOOLTIP, StringFormat("FVG of OB #%I64d: %s - %s", o.id,
                         DoubleToString(o.fvgBottom, _Digits), DoubleToString(o.fvgTop, _Digits)));
        }
     }
   else
      DeleteObj(fvg);

   //--- first retest marker
   string rt = Name("RT", o.id);
   if(m_v.showRetest && o.firstRetestTime > 0)
     {
      if(Ensure(rt, OBJ_ARROW, o.firstRetestTime, o.firstRetestPrice))
        {
         ObjectSetInteger(m_chart, rt, OBJPROP_ARROWCODE, o.dir == SMC_DIR_BULL ? 233 : 234);
         ObjectSetInteger(m_chart, rt, OBJPROP_COLOR, m_v.retestColor);
         ObjectSetInteger(m_chart, rt, OBJPROP_ANCHOR, o.dir == SMC_DIR_BULL ? ANCHOR_TOP : ANCHOR_BOTTOM);
         ObjectSetInteger(m_chart, rt, OBJPROP_WIDTH, 2);
         ObjectSetString(m_chart, rt, OBJPROP_TOOLTIP, StringFormat("First retest of OB #%I64d", o.id));
        }
     }
   else
      DeleteObj(rt);
  }

//+------------------------------------------------------------------+
void CSMCVisualizer::DeleteOB(const long id)
  {
   CacheDrop(id);
   DeleteObj(Name("OB", id));
   DeleteObj(Name("OBL", id));
   DeleteObj(Name("FVG", id));
   DeleteObj(Name("RT", id));
   DeleteObj(Name("RS", id));
  }

//+------------------------------------------------------------------+
void CSMCVisualizer::DrawBOS(const SSMCEvent &e)
  {
   string line = m_v.prefix + "BOS_" + BOSKey(e);
   string txt  = m_v.prefix + "BOST_" + BOSKey(e);
   color c = (e.dir == SMC_DIR_BULL) ? m_v.bosBullColor : m_v.bosBearColor;

   if(Ensure(line, OBJ_TREND, e.time, e.price, e.time2, e.price))
     {
      ObjectSetInteger(m_chart, line, OBJPROP_COLOR, c);
      ObjectSetInteger(m_chart, line, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(m_chart, line, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(m_chart, line, OBJPROP_BACK, true);
      ObjectSetString(m_chart, line, OBJPROP_TOOLTIP,
                      StringFormat("%s %s: close %s broke %s%s", SMC_DirText(e.dir), e.flag ? "CHoCH" : "BOS",
                                   DoubleToString(e.price2, _Digits), DoubleToString(e.price, _Digits),
                                   e.obId > 0 ? " -> OB #" + IntegerToString(e.obId) : " (no OB)"));
     }
   datetime midT = (datetime)(e.time + (e.time2 - e.time) / 2);
   if(Ensure(txt, OBJ_TEXT, midT, e.price))
     {
      ObjectSetString(m_chart, txt, OBJPROP_TEXT, e.flag ? "CHoCH" : "BOS");
      ObjectSetInteger(m_chart, txt, OBJPROP_COLOR, c);
      ObjectSetInteger(m_chart, txt, OBJPROP_FONTSIZE, m_v.labelFontSize);
      ObjectSetInteger(m_chart, txt, OBJPROP_ANCHOR, e.dir == SMC_DIR_BULL ? ANCHOR_LOWER : ANCHOR_UPPER);
     }
  }

//+------------------------------------------------------------------+
void CSMCVisualizer::DrawSwing(const SSMCEvent &e)
  {
   string name = SwingName(e);
   if(Ensure(name, OBJ_ARROW, e.time, e.price))
     {
      ObjectSetInteger(m_chart, name, OBJPROP_ARROWCODE, 159);
      ObjectSetInteger(m_chart, name, OBJPROP_COLOR, m_v.swingColor);
      ObjectSetInteger(m_chart, name, OBJPROP_ANCHOR, e.dir == SMC_DIR_BULL ? ANCHOR_BOTTOM : ANCHOR_TOP);
     }
  }

//+------------------------------------------------------------------+
void CSMCVisualizer::HandleEvents(const CSMCDetector &det, const datetime lastBarTime)
  {
   int n = det.EventCount();
   int bosTotal = 0, swingTotal = 0;
   SSMCEvent e;
   for(int k = 0; k < n; k++)
      if(det.GetEvent(k, e))
        {
         if(e.type == SMC_EVT_BOS)   bosTotal++;
         if(e.type == SMC_EVT_SWING) swingTotal++;
        }

   //--- only the newest items that would survive the ring buffer are kept
   int bosSkip   = (int)MathMax(0, bosTotal - m_v.maxBOSDrawn);
   int swingSkip = (int)MathMax(0, swingTotal - m_v.maxBOSDrawn);
   SOrderBlock o;

   for(int k = 0; k < n; k++)
     {
      if(!det.GetEvent(k, e))
         continue;
      switch(e.type)
        {
         case SMC_EVT_BOS:
            if(bosSkip > 0) { bosSkip--; break; }
            Store(m_bos, e, true);
            if(m_v.showBOS && m_v.maxBOSDrawn > 0) DrawBOS(e);
            break;
         case SMC_EVT_SWING:
            if(swingSkip > 0) { swingSkip--; break; }
            Store(m_swings, e, false);
            if(m_v.showSwings && m_v.maxBOSDrawn > 0) DrawSwing(e);
            break;
         case SMC_EVT_OB_REMOVED:
            DeleteOB(e.obId);
            break;
         default:
           {
            int idx = det.FindById(e.obId);
            if(idx >= 0 && det.GetOB(idx, o))
               DrawOB(o, lastBarTime);
           }
           break;
        }
     }
   RefreshLive(det, lastBarTime);
  }

//+------------------------------------------------------------------+
//| Redraw zones whose right edge still extends with time.           |
//+------------------------------------------------------------------+
void CSMCVisualizer::RefreshLive(const CSMCDetector &det, const datetime lastBarTime)
  {
   SOrderBlock o;
   for(int k = 0; k < det.OBCount(); k++)
      if(det.GetOB(k, o) && (o.endTime == 0 || SMC_IsLiveState(o.state)))
         DrawOB(o, lastBarTime);
  }

//+------------------------------------------------------------------+
//| Rebuild every object from current state (display options changed)|
//+------------------------------------------------------------------+
void CSMCVisualizer::RedrawAll(const CSMCDetector &det, const datetime lastBarTime)
  {
   ObjectsDeleteAll(m_chart, m_v.prefix);
   ArrayResize(m_cache, 0, 64);        // the chart is empty again
   if(m_v.showBOS)
      for(int k = 0; k < ArraySize(m_bos); k++)
         DrawBOS(m_bos[k]);
   if(m_v.showSwings)
      for(int k = 0; k < ArraySize(m_swings); k++)
         DrawSwing(m_swings[k]);
   SOrderBlock o;
   for(int k = 0; k < det.OBCount(); k++)
      if(det.GetOB(k, o))
         DrawOB(o, lastBarTime);
  }

//+------------------------------------------------------------------+
void CSMCVisualizer::Cleanup(void)
  {
   ObjectsDeleteAll(m_chart, m_v.prefix);
   ArrayResize(m_bos, 0);
   ArrayResize(m_swings, 0);
   ArrayResize(m_cache, 0, 64);
  }

#endif // SMC_OB_VISUAL_MQH
