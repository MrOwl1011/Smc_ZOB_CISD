//+------------------------------------------------------------------+
//|                                                    SMC_Theme.mqh |
//|  SPDX-License-Identifier: MIT                                    |
//|  https://github.com/MrOwl1011/Smc_ZOB_CISD                       |
//|  Chart theme: midnight background, no grid, mint / rose candles. |
//|  The chart's own colours are saved the first time the theme is   |
//|  applied and put back when the EA is removed.                    |
//+------------------------------------------------------------------+
#ifndef SMC_THEME_MQH
#define SMC_THEME_MQH

#define SMC_TH_BG        C'9,12,20'       // midnight ink
#define SMC_TH_FG        C'120,130,153'   // axis text, slate
#define SMC_TH_BULL      C'0,229,255'     // cyber blue
#define SMC_TH_BEAR      C'255,84,118'    // rose
#define SMC_TH_LINE      C'150,160,190'
#define SMC_TH_VOLUME    C'70,80,110'
#define SMC_TH_ASK       C'255,184,77'    // amber
#define SMC_TH_BID       C'124,140,255'   // periwinkle

class CSMCTheme
  {
private:
   long              m_chart;
   string            m_key;

   static int        Count(void) { return 14; }
   static long       Prop(const int i)
     {
      switch(i)
        {
         case 0:  return CHART_COLOR_BACKGROUND;
         case 1:  return CHART_COLOR_FOREGROUND;
         case 2:  return CHART_COLOR_GRID;
         case 3:  return CHART_SHOW_GRID;
         case 4:  return CHART_COLOR_CANDLE_BULL;
         case 5:  return CHART_COLOR_CANDLE_BEAR;
         case 6:  return CHART_COLOR_CHART_UP;
         case 7:  return CHART_COLOR_CHART_DOWN;
         case 8:  return CHART_COLOR_CHART_LINE;
         case 9:  return CHART_COLOR_VOLUME;
         case 10: return CHART_COLOR_ASK;
         case 11: return CHART_COLOR_BID;
         case 12: return CHART_COLOR_STOP_LEVEL;
         default: return CHART_SHOW_PERIOD_SEP;
        }
     }
   long              Value(const int i) const
     {
      switch(i)
        {
         case 0:  return SMC_TH_BG;
         case 1:  return SMC_TH_FG;
         case 2:  return SMC_TH_BG;
         case 3:  return 0;                 // no grid
         case 4:  return SMC_TH_BULL;
         case 5:  return SMC_TH_BEAR;
         case 6:  return SMC_TH_BULL;
         case 7:  return SMC_TH_BEAR;
         case 8:  return SMC_TH_LINE;
         case 9:  return SMC_TH_VOLUME;
         case 10: return SMC_TH_ASK;
         case 11: return SMC_TH_BID;
         case 12: return C'255,84,118';
         default: return 0;                 // no period separators
        }
     }

public:
   void              Init(const long chart) { m_chart = chart; m_key = "SMCTHEME_" + IntegerToString(chart) + "_"; }

   void              Apply(void)
     {
      //--- remember the user's look once; a timeframe change re-inits the EA and must not overwrite it
      if(!GlobalVariableCheck(m_key + "saved"))
        {
         for(int i = 0; i < Count(); i++)
            GlobalVariableSet(m_key + IntegerToString(i), (double)ChartGetInteger(m_chart, (ENUM_CHART_PROPERTY_INTEGER)Prop(i)));
         // candle mode (not a colour): make sure candles are shown
         GlobalVariableSet(m_key + "mode", (double)ChartGetInteger(m_chart, CHART_MODE));
         GlobalVariableSet(m_key + "saved", 1);
        }
      for(int i = 0; i < Count(); i++)
         ChartSetInteger(m_chart, (ENUM_CHART_PROPERTY_INTEGER)Prop(i), Value(i));
      ChartSetInteger(m_chart, CHART_MODE, CHART_CANDLES);
      ChartRedraw(m_chart);
     }

   void              Restore(void)
     {
      if(!GlobalVariableCheck(m_key + "saved"))
         return;
      for(int i = 0; i < Count(); i++)
         if(GlobalVariableCheck(m_key + IntegerToString(i)))
            ChartSetInteger(m_chart, (ENUM_CHART_PROPERTY_INTEGER)Prop(i), (long)GlobalVariableGet(m_key + IntegerToString(i)));
      if(GlobalVariableCheck(m_key + "mode"))
         ChartSetInteger(m_chart, CHART_MODE, (long)GlobalVariableGet(m_key + "mode"));
      GlobalVariablesDeleteAll(m_key);
      ChartRedraw(m_chart);
     }
  };

#endif // SMC_THEME_MQH
