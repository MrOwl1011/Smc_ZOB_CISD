//+------------------------------------------------------------------+
//|                                                 SMC_OB_Panel.mqh |
//|  On-chart control panel (collapsible, Easy / Advanced mode).     |
//|                                                                  |
//|  The panel only edits a state record and reports what the EA has |
//|  to do (re-layout, redraw, or rescan). It never touches the      |
//|  detector directly, so detection stays independent of the UI.   |
//+------------------------------------------------------------------+
#ifndef SMC_OB_PANEL_MQH
#define SMC_OB_PANEL_MQH

#include "SMC_OB_Types.mqh"

enum ENUM_SMC_PANEL_ACTION
  {
   SMC_PANEL_NONE = 0,     // nothing changed
   SMC_PANEL_LAYOUT,       // only the panel itself changed (collapse)
   SMC_PANEL_REDRAW,       // display option changed -> redraw chart objects
   SMC_PANEL_RESCAN,       // detection option changed -> rescan history
   SMC_PANEL_CISD,         // CISD component / CISD TF / connection switched -> rebuild CISD side only
   SMC_PANEL_TIMEFRAME,    // Order Block timeframe changed -> rescan OBs and everything depending on them
   SMC_PANEL_SAVECFG,      // save the current settings as a configuration profile
   SMC_PANEL_LOADCFG,      // load a configuration profile
   SMC_PANEL_TRADE         // trade execution switch / lot size changed (no detection change)
  };

struct SSMCPanelState
  {
   bool              collapsed;
   bool              easyMode;
   //--- display
   bool              showBull;
   bool              showBear;
   bool              showInactive;
   bool              showBOS;
   bool              showFVG;
   bool              showRetest;
   bool              showRetestStart;
   bool              showLabels;
   bool              showSwings;
   bool              fillZones;
   //--- CISD components
   bool              cisdSweep;
   bool              cisdConfirm;
   bool              cisdRetrace;
   //--- timeframes (ENUM_CISD_TF order: Chart, M1, M5, M15, M30, H1, H4, D1) and HTF OB -> CISD connection
   int               obTF;
   int               cisdTF;
   bool              connect;
   int               cisdMode;        // 0 = Single (first CISD), 1 = Multi (all CISDs) per sequence
   int               retestMode;      // 0 = Single (first retest only), 1 = Multi (every retest)
   bool              mitStopsCISD;    // a mitigated OB stops its CISD search (like invalidation)
   bool              trendFilter;     // only take CISDs that agree with the OB-timeframe trend
   //--- trade execution (entry at the confirmed setup, stop on the far side of the OB, 1:1 target)
   bool              tradeEnabled;
   double            lots;
   double            targetRR;        // take profit as a multiple of risk
   bool              breakEven;       // move the stop to entry once in profit
   int               bePoints;        // profit in points that arms it
   bool              oppExit;         // a retested opposite block closes the open trade
   //--- detection
   int               swingLength;
   double            dispATRMult;
   int               maxOBToBOSBars;
   int               maxActivePerDir;
   int               fvgMode;
   int               mitigationMode;
   int               invalidationMode;
   int               overlapMode;
  };

#define SMC_PNL_W       256
#define SMC_PNL_PAD     8
#define SMC_PNL_ROW     22
#define SMC_PNL_BG      C'24,28,36'
#define SMC_PNL_HDR     C'38,44,56'
#define SMC_PNL_BORDER  C'64,70,84'
#define SMC_PNL_TEXT    C'226,229,236'
#define SMC_PNL_MUTED   C'140,147,162'
#define SMC_PNL_ON      C'22,128,96'
#define SMC_PNL_OFF     C'52,57,68'
#define SMC_PNL_ACCENT  C'40,110,200'
#define SMC_PNL_FONT    "Segoe UI"

class CSMCPanel
  {
private:
   long              m_chart;
   string            m_p;
   int               m_x;
   int               m_y;
   SSMCPanelState    m_st;
   SSMCPanelState    m_def;
   string            m_status;
   bool              m_cisdAvailable;  // show the CISD section
   string            m_cisdTF;         // CISD timeframe text
   string            m_profile;        // configuration profile name
   //--- scrolling viewport
   int               m_maxHeight;      // 0 = fit the chart
   int               m_scroll;         // body offset in pixels
   int               m_maxScroll;
   int               m_contentHeight;
   int               m_bodyTop;
   int               m_bodyBottom;
   int               m_chartHeight;    // chart height used by the last Build()
   bool              m_draw;           // false = measuring pass
   bool              m_clip;           // true = body coordinates (scrolled / clipped)

   void              Common(const string name);
   void              Rect(const string id, const int x, const int y, const int w, const int h, const color bg, const color border);
   void              Text(const string id, const int x, const int y, const string text, const color clr, const int size = 9);
   void              Btn(const string id, const int x, const int y, const int w, const int h,
                         const string text, const color bg, const color fg, const int size = 9);
   void              Value(const string id, const int x, const int y, const int w, const string text);
   void              Edit(const string id, const int x, const int y, const int w, const string text);
   void              Toggle(const string id, const int x, const int y, const int w, const string text, const bool on);
   void              Stepper(const string id, const int y, const string label, const string value);
   void              Cycle(const string id, const int y, const string label, const string value);
   void              Switch(const string id, const int y, const string label, const bool on);
   bool              Place(const int y, const int h, int &sy) const;
   int               LayoutBody(void);

   ENUM_SMC_PANEL_ACTION StepInt(int &v, const int delta, const int lo, const int hi);
   ENUM_SMC_PANEL_ACTION StepDbl(double &v, const double delta, const double lo, const double hi);
   ENUM_SMC_PANEL_ACTION Next(int &v, const int count);
   void              Sanitize(SSMCPanelState &s) const;

public:
                     CSMCPanel(void) : m_chart(0), m_x(10), m_y(30), m_cisdAvailable(false),
                                        m_maxHeight(0), m_scroll(0), m_maxScroll(0), m_contentHeight(0),
                                        m_bodyTop(0), m_bodyBottom(0), m_chartHeight(0), m_draw(true), m_clip(false) { ZeroMemory(m_st); ZeroMemory(m_def); }
   void              Init(const long chart, const string prefix, const int x, const int y, const SSMCPanelState &defaults);
   void              SetState(const SSMCPanelState &s) { m_st = s; Sanitize(m_st); }
   void              GetState(SSMCPanelState &s) const { s = m_st; }
   string            Prefix(void) const { return m_p; }
   void              SetCISDAvailable(const bool on, const string tfText) { m_cisdAvailable = on; m_cisdTF = tfText; }
   //--- configuration profile (the panel only holds the name; the EA reads / writes the file)
   void              SetProfile(const string name) { m_profile = (name == "" ? "default" : name); }
   string            Profile(void) const { return m_profile; }
   bool              OnEndEdit(const string objectName)
     {
      if(objectName != m_p + "cfg_name")
         return false;
      string t = ObjectGetString(m_chart, objectName, OBJPROP_TEXT);
      StringTrimLeft(t);
      StringTrimRight(t);
      m_profile = (t == "" ? "default" : t);
      ObjectSetString(m_chart, objectName, OBJPROP_TEXT, m_profile);
      return true;
     }
   void              SetMaxHeight(const int px) { m_maxHeight = (px > 0) ? MathMax(120, px) : 0; }
   int               ContentHeight(void) const { return m_contentHeight; }
   int               ScrollOffset(void) const { return m_scroll; }
   int               MaxScroll(void) const { return m_maxScroll; }
   //--- chart resized: the viewport has to be recomputed
   bool              NeedsRelayout(void) const
     { return m_maxHeight == 0 && (int)ChartGetInteger(m_chart, CHART_HEIGHT_IN_PIXELS) != m_chartHeight; }

   void              Build(void);
   void              Destroy(void) { ObjectsDeleteAll(m_chart, m_p); }
   void              SetStatus(const string text);
   ENUM_SMC_PANEL_ACTION OnClick(const string objectName);

   void              Save(const string key) const;
   bool              Load(const string key);
   static void       DeleteSaved(const string key) { GlobalVariablesDeleteAll(key); }

   static string     FVGText(const int v)  { return v == 0 ? "Off" : v == 1 ? "Confluence" : "Required"; }
   static string     MitText(const int v)  { return v == 0 ? "Off" : v == 1 ? "Touch" : v == 2 ? "50% of zone" : "Full zone"; }
   static string     InvText(const int v)  { return v == 0 ? "Off" : v == 1 ? "Close beyond" : "Wick beyond"; }
   static string     OvlText(const int v)  { return v == 0 ? "Keep all" : v == 1 ? "Skip new" : "Replace old"; }
   static string     SrcText(const int v)  { return v == 1 ? "ZOrder only" : v == 2 ? "OB only" : "Both"; }
   static string     ModeText(const int v) { return v == 1 ? "Multi" : "Single"; }
   static string     TFText(const int v)
     {
      string names[8] = {"Chart", "M1", "M5", "M15", "M30", "H1", "H4", "D1"};
      return names[(int)MathMax(0, MathMin(7, v))];
     }
  };

//+------------------------------------------------------------------+
void CSMCPanel::Init(const long chart, const string prefix, const int x, const int y, const SSMCPanelState &defaults)
  {
   m_chart = chart;
   m_p = prefix;
   m_x = x;
   m_y = y;
   m_def = defaults;
   Sanitize(m_def);
   m_st = m_def;
   m_status = "";
  }

//+------------------------------------------------------------------+
void CSMCPanel::Sanitize(SSMCPanelState &s) const
  {
   s.lots             = MathMax(0.01, MathMin(100.0, MathRound(s.lots * 100.0) / 100.0));
   s.targetRR         = MathMax(0.1, MathMin(20.0, MathRound(s.targetRR * 10.0) / 10.0));
   s.bePoints         = (int)MathMax(10, MathMin(100000, s.bePoints));
   s.swingLength      = (int)MathMax(1, MathMin(50, s.swingLength));
   s.dispATRMult      = MathMax(0.1, MathMin(10.0, MathRound(s.dispATRMult * 100.0) / 100.0));
   s.maxOBToBOSBars   = (int)MathMax(1, MathMin(100, s.maxOBToBOSBars));
   s.maxActivePerDir  = (int)MathMax(1, MathMin(200, s.maxActivePerDir));
   s.fvgMode          = (int)MathMax(0, MathMin(2, s.fvgMode));
   s.mitigationMode   = (int)MathMax(0, MathMin(3, s.mitigationMode));
   s.invalidationMode = (int)MathMax(0, MathMin(2, s.invalidationMode));
   s.overlapMode      = (int)MathMax(0, MathMin(2, s.overlapMode));
   s.obTF             = (int)MathMax(0, MathMin(7, s.obTF));
   s.cisdTF           = (int)MathMax(0, MathMin(7, s.cisdTF));
   s.cisdMode         = (int)MathMax(0, MathMin(1, s.cisdMode));
   s.retestMode       = (int)MathMax(0, MathMin(1, s.retestMode));
  }

//+------------------------------------------------------------------+
//| Widgets                                                          |
//+------------------------------------------------------------------+
void CSMCPanel::Common(const string name)
  {
   ObjectSetInteger(m_chart, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(m_chart, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(m_chart, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(m_chart, name, OBJPROP_BACK, false);
   ObjectSetInteger(m_chart, name, OBJPROP_ZORDER, 1000);
  }

//--- screen position of a widget, or false when it is outside the scrolled viewport
bool CSMCPanel::Place(const int y, const int h, int &sy) const
  {
   if(!m_draw)
      return false;                                   // measuring pass
   if(!m_clip)
     {
      sy = y;
      return true;                                    // frame / header: absolute
     }
   sy = m_bodyTop + y - m_scroll;
   return (sy >= m_bodyTop - 1 && sy + h <= m_bodyBottom + 1);
  }

void CSMCPanel::Rect(const string id, const int x, const int y, const int w, const int h, const color bg, const color border)
  {
   int sy;
   if(!Place(y, h, sy))
      return;
   string n = m_p + id;
   if(!ObjectCreate(m_chart, n, OBJ_RECTANGLE_LABEL, 0, 0, 0))
      return;
   Common(n);
   ObjectSetInteger(m_chart, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(m_chart, n, OBJPROP_YDISTANCE, sy);
   ObjectSetInteger(m_chart, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(m_chart, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(m_chart, n, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(m_chart, n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(m_chart, n, OBJPROP_COLOR, border);
  }

void CSMCPanel::Text(const string id, const int x, const int y, const string text, const color clr, const int size)
  {
   int sy;
   if(!Place(y, 14, sy))
      return;
   string n = m_p + id;
   if(!ObjectCreate(m_chart, n, OBJ_LABEL, 0, 0, 0))
      return;
   Common(n);
   ObjectSetInteger(m_chart, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(m_chart, n, OBJPROP_YDISTANCE, sy);
   ObjectSetInteger(m_chart, n, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetString(m_chart, n, OBJPROP_TEXT, text);
   ObjectSetString(m_chart, n, OBJPROP_FONT, SMC_PNL_FONT);
   ObjectSetInteger(m_chart, n, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(m_chart, n, OBJPROP_COLOR, clr);
  }

void CSMCPanel::Btn(const string id, const int x, const int y, const int w, const int h,
                    const string text, const color bg, const color fg, const int size)
  {
   int sy;
   if(!Place(y, h, sy))
      return;
   string n = m_p + id;
   if(!ObjectCreate(m_chart, n, OBJ_BUTTON, 0, 0, 0))
      return;
   Common(n);
   ObjectSetInteger(m_chart, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(m_chart, n, OBJPROP_YDISTANCE, sy);
   ObjectSetInteger(m_chart, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(m_chart, n, OBJPROP_YSIZE, h);
   ObjectSetString(m_chart, n, OBJPROP_TEXT, text);
   ObjectSetString(m_chart, n, OBJPROP_FONT, SMC_PNL_FONT);
   ObjectSetInteger(m_chart, n, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(m_chart, n, OBJPROP_COLOR, fg);
   ObjectSetInteger(m_chart, n, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(m_chart, n, OBJPROP_BORDER_COLOR, bg);
   ObjectSetInteger(m_chart, n, OBJPROP_STATE, false);
  }

void CSMCPanel::Value(const string id, const int x, const int y, const int w, const string text)
  {
   int sy;
   if(!Place(y, SMC_PNL_ROW, sy))
      return;
   string n = m_p + id;
   if(!ObjectCreate(m_chart, n, OBJ_EDIT, 0, 0, 0))
      return;
   Common(n);
   ObjectSetInteger(m_chart, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(m_chart, n, OBJPROP_YDISTANCE, sy);
   ObjectSetInteger(m_chart, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(m_chart, n, OBJPROP_YSIZE, SMC_PNL_ROW);
   ObjectSetString(m_chart, n, OBJPROP_TEXT, text);
   ObjectSetString(m_chart, n, OBJPROP_FONT, SMC_PNL_FONT);
   ObjectSetInteger(m_chart, n, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(m_chart, n, OBJPROP_ALIGN, ALIGN_CENTER);
   ObjectSetInteger(m_chart, n, OBJPROP_READONLY, true);
   ObjectSetInteger(m_chart, n, OBJPROP_COLOR, SMC_PNL_TEXT);
   ObjectSetInteger(m_chart, n, OBJPROP_BGCOLOR, SMC_PNL_BG);
   ObjectSetInteger(m_chart, n, OBJPROP_BORDER_COLOR, SMC_PNL_BORDER);
  }

//--- editable text box (configuration profile name)
void CSMCPanel::Edit(const string id, const int x, const int y, const int w, const string text)
  {
   int sy;
   if(!Place(y, SMC_PNL_ROW, sy))
      return;
   string n = m_p + id;
   if(!ObjectCreate(m_chart, n, OBJ_EDIT, 0, 0, 0))
      return;
   Common(n);
   ObjectSetInteger(m_chart, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(m_chart, n, OBJPROP_YDISTANCE, sy);
   ObjectSetInteger(m_chart, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(m_chart, n, OBJPROP_YSIZE, SMC_PNL_ROW);
   ObjectSetString(m_chart, n, OBJPROP_TEXT, text);
   ObjectSetString(m_chart, n, OBJPROP_FONT, SMC_PNL_FONT);
   ObjectSetInteger(m_chart, n, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(m_chart, n, OBJPROP_ALIGN, ALIGN_LEFT);
   ObjectSetInteger(m_chart, n, OBJPROP_READONLY, false);
   ObjectSetInteger(m_chart, n, OBJPROP_COLOR, SMC_PNL_TEXT);
   ObjectSetInteger(m_chart, n, OBJPROP_BGCOLOR, SMC_PNL_BG);
   ObjectSetInteger(m_chart, n, OBJPROP_BORDER_COLOR, SMC_PNL_ACCENT);
  }

void CSMCPanel::Toggle(const string id, const int x, const int y, const int w, const string text, const bool on)
  {
   Btn(id, x, y, w, SMC_PNL_ROW, text, on ? SMC_PNL_ON : SMC_PNL_OFF, on ? clrWhite : SMC_PNL_MUTED);
  }

void CSMCPanel::Stepper(const string id, const int y, const string label, const string value)
  {
   int plusX  = m_x + SMC_PNL_W - SMC_PNL_PAD - 22;
   int valX   = plusX - 3 - 44;
   int minusX = valX - 3 - 22;
   Text(id + "_l", m_x + SMC_PNL_PAD, y + 4, label, SMC_PNL_TEXT);
   Btn(id + "_m", minusX, y, 22, SMC_PNL_ROW, "-", SMC_PNL_OFF, SMC_PNL_TEXT, 10);
   Value(id + "_v", valX, y, 44, value);
   Btn(id + "_p", plusX, y, 22, SMC_PNL_ROW, "+", SMC_PNL_OFF, SMC_PNL_TEXT, 10);
  }

void CSMCPanel::Cycle(const string id, const int y, const string label, const string value)
  {
   int w = 112;
   Text(id + "_l", m_x + SMC_PNL_PAD, y + 4, label, SMC_PNL_TEXT);
   Btn(id, m_x + SMC_PNL_W - SMC_PNL_PAD - w, y, w, SMC_PNL_ROW, value, SMC_PNL_OFF, SMC_PNL_TEXT);
  }

void CSMCPanel::Switch(const string id, const int y, const string label, const bool on)
  {
   int w = 52;
   Text(id + "_l", m_x + SMC_PNL_PAD, y + 4, label, SMC_PNL_TEXT);
   Btn(id, m_x + SMC_PNL_W - SMC_PNL_PAD - w, y, w, SMC_PNL_ROW, on ? "ON" : "OFF",
       on ? SMC_PNL_ON : SMC_PNL_OFF, on ? clrWhite : SMC_PNL_MUTED);
  }

//+------------------------------------------------------------------+
//| Layout                                                           |
//+------------------------------------------------------------------+
void CSMCPanel::Build(void)
  {
   Destroy();
   int x = m_x, y = m_y, w = SMC_PNL_W, pad = SMC_PNL_PAD, hdr = 28;

   //--- viewport: the body scrolls when the panel is taller than the chart (or than the set maximum)
   m_chartHeight = (int)ChartGetInteger(m_chart, CHART_HEIGHT_IN_PIXELS);
   int limit = (m_maxHeight > 0) ? m_maxHeight : ((m_chartHeight > 0 ? m_chartHeight : 600) - y - 12);
   int viewBody = (int)MathMax(SMC_PNL_ROW * 3, limit - hdr - 2 * pad);

   //--- measuring pass: how tall is the content?
   m_draw = false;
   m_clip = true;
   m_bodyTop = y + hdr + pad;
   m_bodyBottom = m_bodyTop + viewBody;
   m_contentHeight = LayoutBody();
   m_maxScroll = m_st.collapsed ? 0 : (int)MathMax(0, m_contentHeight - viewBody);
   m_scroll = (int)MathMax(0, MathMin(m_maxScroll, m_scroll));
   int bodyH = m_st.collapsed ? 0 : (int)MathMin(m_contentHeight, viewBody);
   m_bodyBottom = m_bodyTop + bodyH;

   //--- frame and header (never scrolled)
   m_draw = true;
   m_clip = false;
   Rect("bg", x, y, w, m_st.collapsed ? hdr : (hdr + 2 * pad + bodyH), SMC_PNL_BG, SMC_PNL_BORDER);
   Rect("hdr", x, y, w, hdr, SMC_PNL_HDR, SMC_PNL_BORDER);
   Text("title", x + pad, y + 6, "SMC Order Blocks", SMC_PNL_TEXT, 10);
   int bx = x + w - pad - 22;
   Btn("collapse", bx, y + 3, 22, 22, m_st.collapsed ? "+" : "-", SMC_PNL_OFF, SMC_PNL_TEXT, 11);
   if(!m_st.collapsed && m_maxScroll > 0)
     {
      bx -= 24;
      Btn("scroll_dn", bx, y + 3, 22, 22, "▼", m_scroll < m_maxScroll ? SMC_PNL_OFF : SMC_PNL_BG,
          m_scroll < m_maxScroll ? SMC_PNL_TEXT : SMC_PNL_MUTED, 9);
      bx -= 24;
      Btn("scroll_up", bx, y + 3, 22, 22, "▲", m_scroll > 0 ? SMC_PNL_OFF : SMC_PNL_BG,
          m_scroll > 0 ? SMC_PNL_TEXT : SMC_PNL_MUTED, 9);
      int thumbH = (int)MathMax(18, (double)bodyH * bodyH / MathMax(m_contentHeight, 1));
      int thumbY = m_bodyTop + (int)((double)(bodyH - thumbH) * m_scroll / MathMax(m_maxScroll, 1));
      Rect("sb_track", x + w - 5, m_bodyTop, 3, bodyH, SMC_PNL_OFF, SMC_PNL_OFF);
      Rect("sb_thumb", x + w - 5, thumbY, 3, thumbH, SMC_PNL_ACCENT, SMC_PNL_ACCENT);
     }

   if(m_st.collapsed)
     {
      ChartRedraw(m_chart);
      return;
     }

   //--- body: drawn in viewport coordinates, clipped and offset by m_scroll
   m_clip = true;
   LayoutBody();
   m_clip = false;
   ChartRedraw(m_chart);
  }

//+------------------------------------------------------------------+
//| Body layout in viewport coordinates; returns the content height. |
//+------------------------------------------------------------------+
int CSMCPanel::LayoutBody(void)
  {
   int x = m_x, w = SMC_PNL_W, pad = SMC_PNL_PAD;
   int half = (w - 3 * pad) / 2;
   int col2 = x + 2 * pad + half;
   int cy = 0;
   Btn("mode_easy", x + pad, cy, half, SMC_PNL_ROW, "Easy", m_st.easyMode ? SMC_PNL_ACCENT : SMC_PNL_OFF,
       m_st.easyMode ? clrWhite : SMC_PNL_MUTED);
   Btn("mode_adv", col2, cy, half, SMC_PNL_ROW, "Advanced", !m_st.easyMode ? SMC_PNL_ACCENT : SMC_PNL_OFF,
       !m_st.easyMode ? clrWhite : SMC_PNL_MUTED);
   cy += SMC_PNL_ROW + 6;

   Text("status", x + pad, cy, m_status, SMC_PNL_MUTED, 8);
   cy += 20;

   Text("sec_show", x + pad, cy, "SHOW", SMC_PNL_MUTED, 8);
   cy += 16;
   Toggle("t_bull", x + pad, cy, half, "Bullish OBs", m_st.showBull);
   Toggle("t_bear", col2, cy, half, "Bearish OBs", m_st.showBear);
   cy += SMC_PNL_ROW + 4;
   Cycle("c_obtf", cy, "Order Block TF", TFText(m_st.obTF) + " ▼");
   cy += SMC_PNL_ROW + 4;
   if(m_cisdAvailable)
     {
      cy += 4;
      Text("sec_cisd", x + pad, cy, "CISD  (" + m_cisdTF + ")", SMC_PNL_MUTED, 8);
      cy += 16;
      Cycle("c_cistf", cy, "CISD TF", TFText(m_st.cisdTF) + " ▼");     cy += SMC_PNL_ROW + 4;
      Switch("conn", cy, "HTF OB -> CISD", m_st.connect);               cy += SMC_PNL_ROW + 4;
      Cycle("c_cmode", cy, "CISD Validation", ModeText(m_st.cisdMode)); cy += SMC_PNL_ROW + 4;
      Cycle("c_rmode", cy, "Retest Mode", ModeText(m_st.retestMode));   cy += SMC_PNL_ROW + 4;
      Switch("mitstop", cy, "Mitigation stops CISD", m_st.mitStopsCISD); cy += SMC_PNL_ROW + 4;
      Switch("trendf", cy, "Trend filter", m_st.trendFilter);           cy += SMC_PNL_ROW + 4;
      Switch("cisd_sw", cy, "Liquidity Sweep", m_st.cisdSweep);      cy += SMC_PNL_ROW + 4;
      Switch("cisd_cf", cy, "Confirmation Close", m_st.cisdConfirm); cy += SMC_PNL_ROW + 4;
      Switch("cisd_rt", cy, "Retracement / Entry", m_st.cisdRetrace); cy += SMC_PNL_ROW + 6;
     }

   if(m_st.easyMode)
     {
      Text("hint", x + pad, cy + 2, "Easy mode: order block zones only", SMC_PNL_MUTED, 8);
      cy += 20;
     }
   else
     {
      Toggle("t_old", x + pad, cy, half, "Old zones", m_st.showInactive);
      Toggle("t_bos", col2, cy, half, "BOS / CHoCH", m_st.showBOS);
      cy += SMC_PNL_ROW + 4;
      Toggle("t_fvg", x + pad, cy, half, "FVG", m_st.showFVG);
      Toggle("t_rt", col2, cy, half, "Retests", m_st.showRetest);
      cy += SMC_PNL_ROW + 4;
      Toggle("t_lbl", x + pad, cy, half, "Labels", m_st.showLabels);
      Toggle("t_sw", col2, cy, half, "Swings", m_st.showSwings);
      cy += SMC_PNL_ROW + 4;
      Toggle("t_fill", x + pad, cy, half, "Fill zones", m_st.fillZones);
      Toggle("t_rs", col2, cy, half, "Retest start", m_st.showRetestStart);
      cy += SMC_PNL_ROW + 10;

      Text("sec_det", x + pad, cy, "DETECTION", SMC_PNL_MUTED, 8);
      cy += 16;
      Stepper("swing", cy, "Swing strength", IntegerToString(m_st.swingLength));        cy += SMC_PNL_ROW + 4;
      Stepper("disp", cy, "Displacement x ATR", DoubleToString(m_st.dispATRMult, 2));   cy += SMC_PNL_ROW + 4;
      Stepper("dist", cy, "Max OB to BOS bars", IntegerToString(m_st.maxOBToBOSBars));  cy += SMC_PNL_ROW + 4;
      Stepper("max", cy, "Max active OBs", IntegerToString(m_st.maxActivePerDir));      cy += SMC_PNL_ROW + 4;
      Cycle("c_fvg", cy, "FVG", FVGText(m_st.fvgMode));                                 cy += SMC_PNL_ROW + 4;
      Cycle("c_mit", cy, "Mitigation", MitText(m_st.mitigationMode));                   cy += SMC_PNL_ROW + 4;
      Cycle("c_inv", cy, "Invalidation", InvText(m_st.invalidationMode));               cy += SMC_PNL_ROW + 4;
      Cycle("c_ovl", cy, "Overlap", OvlText(m_st.overlapMode));                         cy += SMC_PNL_ROW + 8;
      Btn("reset", x + pad, cy, w - 2 * pad, SMC_PNL_ROW, "Reset to input values", SMC_PNL_OFF, SMC_PNL_TEXT);
      cy += SMC_PNL_ROW + 2;
     }

   //--- trade execution (always available, also in Easy mode)
   cy += 6;
   Text("sec_trade", x + pad, cy, "TRADING", SMC_PNL_MUTED, 8);
   cy += 16;
   Switch("trade", cy, "Trade execution", m_st.tradeEnabled);              cy += SMC_PNL_ROW + 4;
   Stepper("lots", cy, "Lot size", DoubleToString(m_st.lots, 2));          cy += SMC_PNL_ROW + 4;
   Stepper("rr", cy, "Take profit  1 :", DoubleToString(m_st.targetRR, 1));  cy += SMC_PNL_ROW + 4;
   Switch("be", cy, "Break even", m_st.breakEven);                          cy += SMC_PNL_ROW + 4;
   Stepper("bept", cy, "Break even points", IntegerToString(m_st.bePoints)); cy += SMC_PNL_ROW + 4;
   Switch("oppx", cy, "Opposite block exit", m_st.oppExit);                cy += SMC_PNL_ROW + 4;

   //--- configuration profiles (always available, also in Easy mode)
   cy += 6;
   Text("sec_cfg", x + pad, cy, "CONFIGURATION", SMC_PNL_MUTED, 8);
   cy += 16;
   Text("cfg_l", x + pad, cy + 4, "Profile", SMC_PNL_TEXT);
   Edit("cfg_name", x + w - pad - 112, cy, 112, m_profile);
   cy += SMC_PNL_ROW + 4;
   Btn("cfg_save", x + pad, cy, half, SMC_PNL_ROW, "Save Config", SMC_PNL_OFF, SMC_PNL_TEXT);
   Btn("cfg_load", col2, cy, half, SMC_PNL_ROW, "Load Config", SMC_PNL_OFF, SMC_PNL_TEXT);
   cy += SMC_PNL_ROW + 2;

   return cy;
  }

//+------------------------------------------------------------------+
void CSMCPanel::SetStatus(const string text)
  {
   m_status = text;
   string n = m_p + "status";
   if(ObjectFind(m_chart, n) >= 0)
      ObjectSetString(m_chart, n, OBJPROP_TEXT, text);
  }

//+------------------------------------------------------------------+
//| Click handling (pure state change; caller rebuilds and applies)  |
//+------------------------------------------------------------------+
ENUM_SMC_PANEL_ACTION CSMCPanel::StepInt(int &v, const int delta, const int lo, const int hi)
  {
   int nv = (int)MathMax(lo, MathMin(hi, v + delta));
   if(nv == v)
      return SMC_PANEL_NONE;
   v = nv;
   return SMC_PANEL_RESCAN;
  }

ENUM_SMC_PANEL_ACTION CSMCPanel::StepDbl(double &v, const double delta, const double lo, const double hi)
  {
   double nv = MathMax(lo, MathMin(hi, MathRound((v + delta) * 100.0) / 100.0));
   if(MathAbs(nv - v) < 1e-9)
      return SMC_PANEL_NONE;
   v = nv;
   return SMC_PANEL_RESCAN;
  }

ENUM_SMC_PANEL_ACTION CSMCPanel::Next(int &v, const int count)
  {
   v = (v + 1) % count;
   return SMC_PANEL_RESCAN;
  }

ENUM_SMC_PANEL_ACTION CSMCPanel::OnClick(const string objectName)
  {
   if(StringFind(objectName, m_p) != 0)
      return SMC_PANEL_NONE;
   //--- buttons are momentary: release the pressed state
   if(ObjectFind(m_chart, objectName) >= 0 && ObjectGetInteger(m_chart, objectName, OBJPROP_TYPE) == OBJ_BUTTON)
      ObjectSetInteger(m_chart, objectName, OBJPROP_STATE, false);

   string id = StringSubstr(objectName, StringLen(m_p));
   int iv;
   double dv;

   if(id == "collapse")  { m_st.collapsed = !m_st.collapsed; return SMC_PANEL_LAYOUT; }
   if(id == "scroll_up") { m_scroll = (int)MathMax(0, m_scroll - SMC_PNL_ROW * 3);           return SMC_PANEL_LAYOUT; }
   if(id == "scroll_dn") { m_scroll = (int)MathMin(m_maxScroll, m_scroll + SMC_PNL_ROW * 3); return SMC_PANEL_LAYOUT; }
   if(id == "mode_easy") { if(m_st.easyMode) return SMC_PANEL_NONE;  m_st.easyMode = true;  return SMC_PANEL_REDRAW; }
   if(id == "mode_adv")  { if(!m_st.easyMode) return SMC_PANEL_NONE; m_st.easyMode = false; return SMC_PANEL_REDRAW; }

   if(id == "t_bull") { m_st.showBull     = !m_st.showBull;     return SMC_PANEL_REDRAW; }
   if(id == "t_bear") { m_st.showBear     = !m_st.showBear;     return SMC_PANEL_REDRAW; }
   if(id == "cisd_sw") { m_st.cisdSweep   = !m_st.cisdSweep;    return SMC_PANEL_CISD; }
   if(id == "cisd_cf") { m_st.cisdConfirm = !m_st.cisdConfirm;  return SMC_PANEL_CISD; }
   if(id == "cisd_rt") { m_st.cisdRetrace = !m_st.cisdRetrace;  return SMC_PANEL_CISD; }
   if(id == "t_old")  { m_st.showInactive = !m_st.showInactive; return SMC_PANEL_REDRAW; }
   if(id == "t_bos")  { m_st.showBOS      = !m_st.showBOS;      return SMC_PANEL_REDRAW; }
   if(id == "t_fvg")  { m_st.showFVG      = !m_st.showFVG;      return SMC_PANEL_REDRAW; }
   if(id == "t_rt")   { m_st.showRetest   = !m_st.showRetest;   return SMC_PANEL_REDRAW; }
   if(id == "t_lbl")  { m_st.showLabels   = !m_st.showLabels;   return SMC_PANEL_REDRAW; }
   if(id == "t_sw")   { m_st.showSwings   = !m_st.showSwings;   return SMC_PANEL_REDRAW; }
   if(id == "t_fill") { m_st.fillZones    = !m_st.fillZones;    return SMC_PANEL_REDRAW; }
   if(id == "t_rs")   { m_st.showRetestStart = !m_st.showRetestStart; return SMC_PANEL_REDRAW; }

   ENUM_SMC_PANEL_ACTION a = SMC_PANEL_NONE;
   if(id == "swing_m" || id == "swing_p")
     { iv = m_st.swingLength;     a = StepInt(iv, id == "swing_p" ? 1 : -1, 1, 50);   m_st.swingLength = iv;     return a; }
   if(id == "disp_m" || id == "disp_p")
     { dv = m_st.dispATRMult;     a = StepDbl(dv, id == "disp_p" ? 0.1 : -0.1, 0.1, 10.0); m_st.dispATRMult = dv; return a; }
   if(id == "dist_m" || id == "dist_p")
     { iv = m_st.maxOBToBOSBars;  a = StepInt(iv, id == "dist_p" ? 1 : -1, 1, 100);  m_st.maxOBToBOSBars = iv;  return a; }
   if(id == "max_m" || id == "max_p")
     { iv = m_st.maxActivePerDir; a = StepInt(iv, id == "max_p" ? 1 : -1, 1, 200);   m_st.maxActivePerDir = iv; return a; }

   if(id == "c_fvg")  { iv = m_st.fvgMode;          a = Next(iv, 3); m_st.fvgMode = iv;          return a; }
   if(id == "c_mit")  { iv = m_st.mitigationMode;   a = Next(iv, 4); m_st.mitigationMode = iv;   return a; }
   if(id == "c_inv")  { iv = m_st.invalidationMode; a = Next(iv, 3); m_st.invalidationMode = iv; return a; }
   if(id == "c_ovl")  { iv = m_st.overlapMode;      a = Next(iv, 3); m_st.overlapMode = iv;      return a; }
   if(id == "c_obtf")  { iv = m_st.obTF;   Next(iv, 8); m_st.obTF = iv;   return SMC_PANEL_TIMEFRAME; }
   if(id == "c_cistf") { iv = m_st.cisdTF; Next(iv, 8); m_st.cisdTF = iv; return SMC_PANEL_CISD; }
   if(id == "conn")    { m_st.connect = !m_st.connect;                     return SMC_PANEL_CISD; }
   if(id == "c_cmode") { iv = m_st.cisdMode; Next(iv, 2); m_st.cisdMode = iv; return SMC_PANEL_CISD; }
   if(id == "c_rmode") { iv = m_st.retestMode; Next(iv, 2); m_st.retestMode = iv; return SMC_PANEL_CISD; }
   if(id == "mitstop") { m_st.mitStopsCISD = !m_st.mitStopsCISD;           return SMC_PANEL_CISD; }
   if(id == "trendf")  { m_st.trendFilter  = !m_st.trendFilter;            return SMC_PANEL_CISD; }
   if(id == "trade")   { m_st.tradeEnabled = !m_st.tradeEnabled;           return SMC_PANEL_TRADE; }
   if(id == "oppx")    { m_st.oppExit      = !m_st.oppExit;                return SMC_PANEL_TRADE; }
   if(id == "be")      { m_st.breakEven    = !m_st.breakEven;              return SMC_PANEL_TRADE; }
   if(id == "rr_m" || id == "rr_p")
     {
      double rv = m_st.targetRR;
      if(StepDbl(rv, id == "rr_p" ? 0.1 : -0.1, 0.1, 20.0) == SMC_PANEL_NONE)
         return SMC_PANEL_NONE;
      m_st.targetRR = rv;
      return SMC_PANEL_TRADE;
     }
   if(id == "bept_m" || id == "bept_p")
     {
      int bv = m_st.bePoints;
      if(StepInt(bv, id == "bept_p" ? 10 : -10, 10, 100000) == SMC_PANEL_NONE)
         return SMC_PANEL_NONE;
      m_st.bePoints = bv;
      return SMC_PANEL_TRADE;
     }
   if(id == "lots_m" || id == "lots_p")
     {
      double lv = m_st.lots;
      if(StepDbl(lv, id == "lots_p" ? 0.01 : -0.01, 0.01, 100.0) == SMC_PANEL_NONE)
         return SMC_PANEL_NONE;
      m_st.lots = lv;
      return SMC_PANEL_TRADE;
     }
   if(id == "cfg_save") return SMC_PANEL_SAVECFG;
   if(id == "cfg_load") return SMC_PANEL_LOADCFG;

   if(id == "reset")
     {
      bool collapsed = m_st.collapsed, easy = m_st.easyMode;
      m_st = m_def;
      m_st.collapsed = collapsed;
      m_st.easyMode = easy;
      return SMC_PANEL_RESCAN;
     }
   return SMC_PANEL_NONE;
  }

//+------------------------------------------------------------------+
//| Persistence (terminal global variables, per chart)               |
//+------------------------------------------------------------------+
void CSMCPanel::Save(const string key) const
  {
   GlobalVariableSet(key + "v", 1);
   GlobalVariableSet(key + "col", m_st.collapsed);
   GlobalVariableSet(key + "easy", m_st.easyMode);
   GlobalVariableSet(key + "bull", m_st.showBull);
   GlobalVariableSet(key + "bear", m_st.showBear);
   GlobalVariableSet(key + "old", m_st.showInactive);
   GlobalVariableSet(key + "bos", m_st.showBOS);
   GlobalVariableSet(key + "fvg", m_st.showFVG);
   GlobalVariableSet(key + "rt", m_st.showRetest);
   GlobalVariableSet(key + "lbl", m_st.showLabels);
   GlobalVariableSet(key + "sw", m_st.showSwings);
   GlobalVariableSet(key + "fill", m_st.fillZones);
   GlobalVariableSet(key + "rs", m_st.showRetestStart);
   GlobalVariableSet(key + "csw", m_st.cisdSweep);
   GlobalVariableSet(key + "ccf", m_st.cisdConfirm);
   GlobalVariableSet(key + "crt", m_st.cisdRetrace);
   GlobalVariableSet(key + "obtf", m_st.obTF);
   GlobalVariableSet(key + "cistf", m_st.cisdTF);
   GlobalVariableSet(key + "conn", m_st.connect);
   GlobalVariableSet(key + "cmode", m_st.cisdMode);
   GlobalVariableSet(key + "rmode", m_st.retestMode);
   GlobalVariableSet(key + "mstop", m_st.mitStopsCISD);
   GlobalVariableSet(key + "trendf", m_st.trendFilter);
   GlobalVariableSet(key + "trade", m_st.tradeEnabled);
   GlobalVariableSet(key + "lots", m_st.lots);
   GlobalVariableSet(key + "oppx", m_st.oppExit);
   GlobalVariableSet(key + "rr", m_st.targetRR);
   GlobalVariableSet(key + "be", m_st.breakEven);
   GlobalVariableSet(key + "bept", m_st.bePoints);
   GlobalVariableSet(key + "swing", m_st.swingLength);
   GlobalVariableSet(key + "disp", m_st.dispATRMult);
   GlobalVariableSet(key + "dist", m_st.maxOBToBOSBars);
   GlobalVariableSet(key + "max", m_st.maxActivePerDir);
   GlobalVariableSet(key + "cfvg", m_st.fvgMode);
   GlobalVariableSet(key + "cmit", m_st.mitigationMode);
   GlobalVariableSet(key + "cinv", m_st.invalidationMode);
   GlobalVariableSet(key + "covl", m_st.overlapMode);
  }

bool CSMCPanel::Load(const string key)
  {
   if(!GlobalVariableCheck(key + "v"))
      return false;
   m_st.collapsed        = GlobalVariableGet(key + "col") != 0;
   m_st.easyMode         = GlobalVariableGet(key + "easy") != 0;
   m_st.showBull         = GlobalVariableGet(key + "bull") != 0;
   m_st.showBear         = GlobalVariableGet(key + "bear") != 0;
   m_st.showInactive     = GlobalVariableGet(key + "old") != 0;
   m_st.showBOS          = GlobalVariableGet(key + "bos") != 0;
   m_st.showFVG          = GlobalVariableGet(key + "fvg") != 0;
   m_st.showRetest       = GlobalVariableGet(key + "rt") != 0;
   m_st.showLabels       = GlobalVariableGet(key + "lbl") != 0;
   m_st.showSwings       = GlobalVariableGet(key + "sw") != 0;
   m_st.fillZones        = GlobalVariableGet(key + "fill") != 0;
   m_st.showRetestStart  = GlobalVariableCheck(key + "rs") ? GlobalVariableGet(key + "rs") != 0 : m_def.showRetestStart;
   //--- settings saved by v1.10 have no ZOrder keys: keep the input defaults
   m_st.cisdSweep        = GlobalVariableCheck(key + "csw") ? GlobalVariableGet(key + "csw") != 0 : m_def.cisdSweep;
   m_st.cisdConfirm      = GlobalVariableCheck(key + "ccf") ? GlobalVariableGet(key + "ccf") != 0 : m_def.cisdConfirm;
   m_st.cisdRetrace      = GlobalVariableCheck(key + "crt") ? GlobalVariableGet(key + "crt") != 0 : m_def.cisdRetrace;
   m_st.obTF             = GlobalVariableCheck(key + "obtf") ? (int)GlobalVariableGet(key + "obtf") : m_def.obTF;
   m_st.cisdTF           = GlobalVariableCheck(key + "cistf") ? (int)GlobalVariableGet(key + "cistf") : m_def.cisdTF;
   m_st.connect          = GlobalVariableCheck(key + "conn") ? GlobalVariableGet(key + "conn") != 0 : m_def.connect;
   m_st.cisdMode         = GlobalVariableCheck(key + "cmode") ? (int)GlobalVariableGet(key + "cmode") : m_def.cisdMode;
   m_st.retestMode       = GlobalVariableCheck(key + "rmode") ? (int)GlobalVariableGet(key + "rmode") : m_def.retestMode;
   m_st.mitStopsCISD     = GlobalVariableCheck(key + "mstop") ? GlobalVariableGet(key + "mstop") != 0 : m_def.mitStopsCISD;
   m_st.trendFilter      = GlobalVariableCheck(key + "trendf") ? GlobalVariableGet(key + "trendf") != 0 : m_def.trendFilter;
   m_st.tradeEnabled     = GlobalVariableCheck(key + "trade") ? GlobalVariableGet(key + "trade") != 0 : m_def.tradeEnabled;
   m_st.lots             = GlobalVariableCheck(key + "lots") ? GlobalVariableGet(key + "lots") : m_def.lots;
   m_st.oppExit          = GlobalVariableCheck(key + "oppx") ? GlobalVariableGet(key + "oppx") != 0 : m_def.oppExit;
   m_st.targetRR         = GlobalVariableCheck(key + "rr") ? GlobalVariableGet(key + "rr") : m_def.targetRR;
   m_st.breakEven        = GlobalVariableCheck(key + "be") ? GlobalVariableGet(key + "be") != 0 : m_def.breakEven;
   m_st.bePoints         = GlobalVariableCheck(key + "bept") ? (int)GlobalVariableGet(key + "bept") : m_def.bePoints;
   m_st.swingLength      = (int)GlobalVariableGet(key + "swing");
   m_st.dispATRMult      = GlobalVariableGet(key + "disp");
   m_st.maxOBToBOSBars   = (int)GlobalVariableGet(key + "dist");
   m_st.maxActivePerDir  = (int)GlobalVariableGet(key + "max");
   m_st.fvgMode          = (int)GlobalVariableGet(key + "cfvg");
   m_st.mitigationMode   = (int)GlobalVariableGet(key + "cmit");
   m_st.invalidationMode = (int)GlobalVariableGet(key + "cinv");
   m_st.overlapMode      = (int)GlobalVariableGet(key + "covl");
   Sanitize(m_st);
   return true;
  }

#endif // SMC_OB_PANEL_MQH
