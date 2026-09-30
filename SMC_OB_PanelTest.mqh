//+------------------------------------------------------------------+
//|                                             SMC_OB_PanelTest.mqh |
//|  Self tests for the control panel: click state machine, value    |
//|  clamping, reset, and (when a chart is available) the layout of  |
//|  Advanced / Easy / collapsed modes.                              |
//+------------------------------------------------------------------+
#ifndef SMC_OB_PANELTEST_MQH
#define SMC_OB_PANELTEST_MQH

#include "SMC_OB_Panel.mqh"

void SMC_PanelCheck(const bool cond, const string what, int &pass, int &fail)
  {
   if(cond)
      pass++;
   else
     {
      fail++;
      PrintFormat("[SMC-OB][TEST] FAIL  Control panel: %s", what);
     }
  }

int SMC_PanelObjectCount(const string prefix)
  {
   int n = 0;
   for(int k = ObjectsTotal(0) - 1; k >= 0; k--)
      if(StringFind(ObjectName(0, k), prefix) == 0)
         n++;
   return n;
  }

//+------------------------------------------------------------------+
//| Measure every text against the space it has:                     |
//|  - button / value text must fit inside the widget                |
//|  - labels must end before the panel's right padding              |
//|  - row labels ("<id>_l") must end before their control starts    |
//+------------------------------------------------------------------+
int SMC_PanelTextWidth(const string name)
  {
   string text = ObjectGetString(0, name, OBJPROP_TEXT);
   if(text == "")
      return 0;
   TextSetFont(ObjectGetString(0, name, OBJPROP_FONT), -(int)ObjectGetInteger(0, name, OBJPROP_FONTSIZE) * 10);
   uint w = 0, h = 0;
   TextGetSize(text, w, h);
   return (int)w;
  }

int SMC_PanelClippedText(const string prefix, const int panelX, const int verbose)
  {
   int bad = 0;
   int right = panelX + SMC_PNL_W - SMC_PNL_PAD;
   for(int k = ObjectsTotal(0) - 1; k >= 0; k--)
     {
      string n = ObjectName(0, k);
      if(StringFind(n, prefix) != 0)
         continue;
      ENUM_OBJECT type = (ENUM_OBJECT)ObjectGetInteger(0, n, OBJPROP_TYPE);
      int x = (int)ObjectGetInteger(0, n, OBJPROP_XDISTANCE);
      int w = SMC_PanelTextWidth(n);
      string why = "";

      if(type == OBJ_BUTTON || type == OBJ_EDIT)
        {
         int box = (int)ObjectGetInteger(0, n, OBJPROP_XSIZE);
         if(w > box - 4)
            why = StringFormat("text %dpx > widget %dpx", w, box - 4);
        }
      else if(type == OBJ_LABEL)
        {
         int limit = right;
         int len = StringLen(n);
         if(len > 2 && StringSubstr(n, len - 2) == "_l")
           {
            string base = StringSubstr(n, 0, len - 2);
            string ctrl = (ObjectFind(0, base + "_m") >= 0) ? base + "_m" : base;
            if(ObjectFind(0, ctrl) >= 0)
               limit = (int)ObjectGetInteger(0, ctrl, OBJPROP_XDISTANCE) - 4;
           }
         if(x + w > limit)
            why = StringFormat("label ends at %dpx, limit %dpx", x + w, limit);
        }
      if(why != "")
        {
         bad++;
         if(verbose > 0)
            PrintFormat("[SMC-OB][TEST] layout: %s '%s' %s", n, ObjectGetString(0, n, OBJPROP_TEXT), why);
        }
     }
   return bad;
  }

bool SMC_RunPanelTests(const bool chartAvailable)
  {
   int pass = 0, fail = 0;
   string P = "SMCPNLTEST_";

   SSMCPanelState d;
   ZeroMemory(d);
   d.showBull = true;  d.showBear = true;  d.showBOS = true;  d.showLabels = true;
   d.swingLength = 5;  d.dispATRMult = 1.5; d.maxOBToBOSBars = 8; d.maxActivePerDir = 10;
   d.fvgMode = 1;      d.mitigationMode = 2; d.invalidationMode = 1;
   d.cisdSweep = true; d.cisdConfirm = true; d.cisdRetrace = true;
   d.obTF = 5; d.cisdTF = 2; d.connect = true;          // H1 OB, M5 CISD, connected

   CSMCPanel p;
   p.Init(0, P, 300, 30, d); p.SetScale(100);
   p.SetCISDAvailable(true, "M5");
   p.SetMaxHeight(3000);                                // layout checks below need the whole panel visible
   SSMCPanelState s;

   //--- routing
   SMC_PanelCheck(p.OnClick("SMCOB_OB_1") == SMC_PANEL_NONE, "foreign object ignored", pass, fail);
   SMC_PanelCheck(p.OnClick(P + "unknown") == SMC_PANEL_NONE, "unknown button ignored", pass, fail);

   //--- collapse / expand
   SMC_PanelCheck(p.OnClick(P + "collapse") == SMC_PANEL_LAYOUT, "collapse -> layout only", pass, fail);
   p.GetState(s);
   SMC_PanelCheck(s.collapsed, "collapsed", pass, fail);
   p.OnClick(P + "collapse");
   p.GetState(s);
   SMC_PanelCheck(!s.collapsed, "expanded again", pass, fail);

   //--- modes
   SMC_PanelCheck(p.OnClick(P + "mode_easy") == SMC_PANEL_REDRAW, "easy mode -> redraw", pass, fail);
   p.GetState(s);
   SMC_PanelCheck(s.easyMode, "easy mode on", pass, fail);
   SMC_PanelCheck(p.OnClick(P + "mode_easy") == SMC_PANEL_NONE, "easy mode twice is a no-op", pass, fail);
   SMC_PanelCheck(p.OnClick(P + "mode_adv") == SMC_PANEL_REDRAW, "advanced mode -> redraw", pass, fail);

   //--- display toggles never rescan
   SMC_PanelCheck(p.OnClick(P + "t_bull") == SMC_PANEL_REDRAW, "bull toggle -> redraw", pass, fail);
   SMC_PanelCheck(p.OnClick(P + "t_bos") == SMC_PANEL_REDRAW, "BOS toggle -> redraw", pass, fail);
   p.GetState(s);
   SMC_PanelCheck(!s.showBull && !s.showBOS && s.showBear, "toggles flipped independently", pass, fail);
   p.GetState(s);

   //--- CISD components: independent switches, CISD-only action
   SMC_PanelCheck(p.OnClick(P + "cisd_sw") == SMC_PANEL_CISD, "CISD liquidity sweep -> CISD action", pass, fail);
   p.GetState(s);
   SMC_PanelCheck(!s.cisdSweep && s.cisdConfirm && s.cisdRetrace, "sweep switch flips only the sweep", pass, fail);
   SMC_PanelCheck(p.OnClick(P + "cisd_cf") == SMC_PANEL_CISD, "CISD confirmation -> CISD action", pass, fail);
   p.GetState(s);
   SMC_PanelCheck(!s.cisdSweep && !s.cisdConfirm && s.cisdRetrace, "confirmation switch flips only confirmation", pass, fail);
   SMC_PanelCheck(p.OnClick(P + "cisd_rt") == SMC_PANEL_CISD, "CISD retracement -> CISD action", pass, fail);
   p.GetState(s);

   //--- timeframe selectors and HTF OB -> CISD connection
   SMC_PanelCheck(p.OnClick(P + "c_obtf") == SMC_PANEL_TIMEFRAME, "OB TF -> timeframe action (OB rescan)", pass, fail);
   p.GetState(s);
   SMC_PanelCheck(s.obTF == 6 && s.cisdTF == 2, "OB TF H1 -> H4, CISD TF unchanged", pass, fail);
   SMC_PanelCheck(p.OnClick(P + "c_cistf") == SMC_PANEL_CISD, "CISD TF -> CISD action", pass, fail);
   p.GetState(s);
   SMC_PanelCheck(s.cisdTF == 3 && s.obTF == 6, "CISD TF M5 -> M15, OB TF unchanged", pass, fail);
   for(int k = 0; k < 7; k++)
      p.OnClick(P + "c_cistf");
   p.GetState(s);
   SMC_PanelCheck(s.cisdTF == 2, "timeframe selector cycles through all 8 choices", pass, fail);
   SMC_PanelCheck(p.OnClick(P + "conn") == SMC_PANEL_CISD, "connection switch -> CISD action", pass, fail);
   p.GetState(s);
   SMC_PanelCheck(!s.connect && s.cisdTF == 2 && !s.cisdSweep, "connection switch flips only the connection", pass, fail);

   //--- OB source and CISD validation mode
   p.GetState(s);
   p.GetState(s);
   p.GetState(s);
   SMC_PanelCheck(p.OnClick(P + "c_cmode") == SMC_PANEL_CISD, "CISD validation -> CISD action", pass, fail);
   p.GetState(s);
   p.OnClick(P + "c_cmode");
   p.GetState(s);
   SMC_PanelCheck(s.cisdMode == 0, "CISD validation cycles back to Single", pass, fail);

   //--- retest mode is independent of the CISD mode
   SMC_PanelCheck(p.OnClick(P + "c_rmode") == SMC_PANEL_CISD, "retest mode -> CISD action", pass, fail);
   p.GetState(s);
   SMC_PanelCheck(s.retestMode == 1 && s.cisdMode == 0, "retest Single -> Multi, CISD mode unchanged", pass, fail);
   p.OnClick(P + "c_cmode");
   p.GetState(s);
   SMC_PanelCheck(s.cisdMode == 1 && s.retestMode == 1, "both modes can be Multi at the same time", pass, fail);
   p.OnClick(P + "c_rmode");
   p.OnClick(P + "c_cmode");
   p.GetState(s);
   SMC_PanelCheck(s.retestMode == 0 && s.cisdMode == 0, "both modes cycle back to Single", pass, fail);

   //--- configuration buttons report their own actions
   SMC_PanelCheck(p.OnClick(P + "cfg_save") == SMC_PANEL_SAVECFG, "Save Config -> save action", pass, fail);
   SMC_PanelCheck(p.OnClick(P + "cfg_load") == SMC_PANEL_LOADCFG, "Load Config -> load action", pass, fail);
   p.GetState(s);
   SMC_PanelCheck(s.retestMode == 0 && s.cisdMode == 0 && s.swingLength == 5,
                  "configuration buttons change no setting themselves", pass, fail);
   p.SetProfile("my_setup");
   SMC_PanelCheck(p.Profile() == "my_setup", "profile name can be set", pass, fail);
   p.SetProfile("");
   SMC_PanelCheck(p.Profile() == "default", "empty profile name falls back to default", pass, fail);

   //--- detection steppers rescan and clamp
   SMC_PanelCheck(p.OnClick(P + "swing_p") == SMC_PANEL_RESCAN, "swing + -> rescan", pass, fail);
   SMC_PanelCheck(p.OnClick(P + "disp_m") == SMC_PANEL_RESCAN, "displacement - -> rescan", pass, fail);
   p.GetState(s);
   SMC_PanelCheck(s.swingLength == 6 && MathAbs(s.dispATRMult - 1.4) < 1e-9, "stepper values", pass, fail);
   s.swingLength = 50; s.dispATRMult = 0.1; s.maxOBToBOSBars = 1;
   p.SetState(s);
   SMC_PanelCheck(p.OnClick(P + "swing_p") == SMC_PANEL_NONE, "swing clamped at 50", pass, fail);
   SMC_PanelCheck(p.OnClick(P + "disp_m") == SMC_PANEL_NONE, "displacement clamped at 0.1", pass, fail);
   SMC_PanelCheck(p.OnClick(P + "dist_m") == SMC_PANEL_NONE, "OB->BOS distance clamped at 1", pass, fail);

   //--- cycles wrap
   for(int k = 0; k < 3; k++)
      p.OnClick(P + "c_fvg");
   for(int k = 0; k < 4; k++)
      p.OnClick(P + "c_mit");
   p.GetState(s);
   SMC_PanelCheck(s.fvgMode == 1 && s.mitigationMode == 2, "cycle buttons wrap around", pass, fail);
   p.OnClick(P + "c_ovl");
   p.GetState(s);
   SMC_PanelCheck(s.overlapMode == 1, "overlap cycles to next value", pass, fail);

   //--- sanitize loaded / external state
   s.swingLength = 999; s.fvgMode = 9; s.dispATRMult = -3;
   p.SetState(s);
   p.GetState(s);
   SMC_PanelCheck(s.swingLength == 50 && s.fvgMode == 2 && s.dispATRMult >= 0.1, "out-of-range state sanitized", pass, fail);

   //--- reset restores inputs but keeps layout choices
   p.OnClick(P + "collapse");
   p.OnClick(P + "mode_easy");
   SMC_PanelCheck(p.OnClick(P + "reset") == SMC_PANEL_RESCAN, "reset -> rescan", pass, fail);
   p.GetState(s);
   SMC_PanelCheck(s.swingLength == 5 && s.showBull && s.showBOS && s.overlapMode == 0 && s.fvgMode == 1 &&
                  s.cisdSweep && s.cisdConfirm && s.cisdRetrace && s.obTF == 5 && s.cisdTF == 2 && s.connect &&
                  s.cisdMode == 0 && s.retestMode == 0,
                  "reset restores input values", pass, fail);
   SMC_PanelCheck(s.collapsed && s.easyMode, "reset keeps collapsed / easy choice", pass, fail);

   //--- layout (needs a real or visual-tester chart)
   if(chartAvailable)
     {
      s.collapsed = false; s.easyMode = false;
      p.SetState(s);
      p.Build();
      SMC_PanelCheck(ObjectFind(0, P + "c_ovl") >= 0 && ObjectFind(0, P + "reset") >= 0 &&
                     ObjectFind(0, P + "swing_p") >= 0, "advanced layout has detection controls", pass, fail);
      SMC_PanelCheck(ObjectFind(0, P + "cisd_sw") >= 0 && ObjectFind(0, P + "cisd_cf") >= 0 &&
                     ObjectFind(0, P + "cisd_rt") >= 0 && ObjectFind(0, P + "sec_cisd") >= 0,
                     "advanced layout has the three CISD switches", pass, fail);
      SMC_PanelCheck(ObjectFind(0, P + "c_obtf") >= 0 && ObjectFind(0, P + "c_cistf") >= 0 && ObjectFind(0, P + "conn") >= 0,
                     "advanced layout has OB TF, CISD TF and connection controls", pass, fail);
      SMC_PanelCheck(ObjectFind(0, P + "c_cmode") >= 0 && ObjectFind(0, P + "c_rmode") >= 0,
                     "advanced layout has CISD validation and retest mode", pass, fail);
      SMC_PanelCheck(ObjectFind(0, P + "cfg_name") >= 0 && ObjectFind(0, P + "cfg_save") >= 0 &&
                     ObjectFind(0, P + "cfg_load") >= 0 && ObjectFind(0, P + "sec_cfg") >= 0,
                     "advanced layout has the configuration controls", pass, fail);
      int advanced = SMC_PanelObjectCount(P);

      int clipped = SMC_PanelClippedText(P, 300, 1);
      SMC_PanelCheck(clipped == 0, StringFormat("%d advanced-layout texts do not fit their widget", clipped), pass, fail);

      s.easyMode = true;
      p.SetState(s);
      p.Build();
      clipped = SMC_PanelClippedText(P, 300, 1);
      SMC_PanelCheck(clipped == 0, StringFormat("%d easy-layout texts do not fit their widget", clipped), pass, fail);
      SMC_PanelCheck(ObjectFind(0, P + "t_bull") >= 0 && ObjectFind(0, P + "c_ovl") < 0 &&
                     ObjectFind(0, P + "cisd_rt") >= 0 && ObjectFind(0, P + "c_obtf") >= 0 && ObjectFind(0, P + "conn") >= 0 &&
                     ObjectFind(0, P + "cfg_save") >= 0,
                     "easy layout shows only OB and ZOrder toggles", pass, fail);
      int easy = SMC_PanelObjectCount(P);

      s.collapsed = true;
      p.SetState(s);
      p.Build();
      SMC_PanelCheck(ObjectFind(0, P + "collapse") >= 0 && ObjectFind(0, P + "t_bull") < 0 &&
                     ObjectFind(0, P + "cisd_sw") < 0 && ObjectFind(0, P + "c_obtf") < 0 &&
                     ObjectFind(0, P + "c_cmode") < 0 && ObjectFind(0, P + "cfg_save") < 0,
                     "collapsed layout shows header only", pass, fail);
      int collapsed = SMC_PanelObjectCount(P);
      SMC_PanelCheck(advanced > easy && easy > collapsed, StringFormat("object counts %d > %d > %d", advanced, easy, collapsed), pass, fail);

      //--- scrolling viewport
      s.collapsed = false;
      s.easyMode = false;
      p.SetState(s);
      p.SetMaxHeight(240);
      p.Build();
      SMC_PanelCheck(p.ContentHeight() > 240 && p.MaxScroll() > 0 && ObjectFind(0, P + "scroll_up") >= 0 &&
                     ObjectFind(0, P + "scroll_dn") >= 0 && ObjectFind(0, P + "sb_thumb") >= 0,
                     "small viewport -> scroll buttons and scrollbar", pass, fail);
      SMC_PanelCheck(ObjectFind(0, P + "t_bull") >= 0 && ObjectFind(0, P + "reset") < 0,
                     "rows below the viewport are clipped", pass, fail);
      SMC_PanelCheck(SMC_PanelClippedText(P, 300, 0) == 0, "scrolled layout text still fits", pass, fail);

      int guard = 0;
      while(p.ScrollOffset() < p.MaxScroll() && guard++ < 60)
        {
         p.OnClick(P + "scroll_dn");
         p.Build();
        }
      SMC_PanelCheck(p.ScrollOffset() == p.MaxScroll() && ObjectFind(0, P + "reset") >= 0 &&
                     ObjectFind(0, P + "t_bull") < 0, "scrolled to the bottom: last row shown, first row clipped", pass, fail);
      guard = 0;
      while(p.ScrollOffset() > 0 && guard++ < 60)
        {
         p.OnClick(P + "scroll_up");
         p.Build();
        }
      SMC_PanelCheck(p.ScrollOffset() == 0 && ObjectFind(0, P + "t_bull") >= 0 && ObjectFind(0, P + "reset") < 0,
                     "scrolled back to the top", pass, fail);

      p.SetMaxHeight(3000);
      p.Build();
      SMC_PanelCheck(p.MaxScroll() == 0 && ObjectFind(0, P + "scroll_dn") < 0 && ObjectFind(0, P + "reset") >= 0,
                     "tall viewport -> everything visible, no scrolling", pass, fail);

      p.Destroy();
      SMC_PanelCheck(SMC_PanelObjectCount(P) == 0, "destroy removes all panel objects", pass, fail);
     }

   PrintFormat("[SMC-OB][TEST] Control panel %s: %d checks passed, %d failed%s",
               fail == 0 ? "ALL PASSED" : "FAILURES", pass, fail, chartAvailable ? "" : " (layout checks skipped: no chart)");
   return fail == 0;
  }

#endif // SMC_OB_PANELTEST_MQH
