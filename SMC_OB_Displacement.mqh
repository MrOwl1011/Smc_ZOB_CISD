//+------------------------------------------------------------------+
//|                                          SMC_OB_Displacement.mqh |
//|  SPDX-License-Identifier: MIT                                    |
//|  https://github.com/MrOwl1011/Smc_ZOB_CISD                       |
//|  Displacement Engine + last-opposite-candle identification.      |
//|                                                                  |
//|  Given a BOS on closed bar i in direction D:                     |
//|   1. Walk back j = i, i+1, ... i+maxOBToBOSBars and stop at the  |
//|      FIRST candle whose colour is opposite to D. That candle is  |
//|      the OB (index ob). Everything in [i, ob-1] is the leg, and  |
//|      by construction contains no opposite-colour candles.        |
//|      ob == i  -> BOS candle itself is opposite: rejected.        |
//|   2. ATR is measured at the OB candle (before the displacement), |
//|      so the displacement cannot inflate its own threshold.       |
//|   3. Filters (all must pass):                                    |
//|      netMove  = D * (Close[i] - Open[ob-1])  >= dispATRMult * ATR |
//|      strongest leg body (D-coloured)         >= dispCandleATRMult*ATR |
//|      that candle's body / range * 100        >= dispMinBodyPct   |
//|      strongest body / avg body(ob..ob+P-1)   >= dispMinRelStrength|
//|      optional: no leg bar trades beyond the OB far edge          |
//+------------------------------------------------------------------+
#ifndef SMC_OB_DISPLACEMENT_MQH
#define SMC_OB_DISPLACEMENT_MQH

#include "SMC_OB_MarketData.mqh"

class CSMCDisplacement
  {
public:
   bool              Evaluate(const MqlRates &r[], const int i, const int size,
                              const int dir, const SSMCSettings &s, SDisplacement &d) const;
  };

//+------------------------------------------------------------------+
bool CSMCDisplacement::Evaluate(const MqlRates &r[], const int i, const int size,
                                const int dir, const SSMCSettings &s, SDisplacement &d) const
  {
   ZeroMemory(d);
   d.reject  = SMC_REJ_NONE;
   d.obIndex = -1;

   //--- 1. last opposite candle before (or at) the BOS candle
   for(int j = i; j <= i + s.maxOBToBOSBars; j++)
     {
      if(j >= size)
        {
         d.reject = SMC_REJ_INSUFFICIENT_DATA;
         return false;
        }
      if(SMC_IsDirCandle(r[j], -dir))
        {
         d.obIndex = j;
         break;
        }
     }
   if(d.obIndex < 0)
     {
      d.reject = SMC_REJ_NO_OPPOSITE_CANDLE;
      return false;
     }
   if(d.obIndex == i)
     {
      d.reject = SMC_REJ_BOS_CANDLE_OPPOSITE;
      return false;
     }

   int ob = d.obIndex;
   d.legBars = ob - i;

   //--- 2. volatility reference measured before the displacement
   d.atr = SMC_ATR(r, ob, size, s.atrPeriod);
   double avgBody = SMC_AvgBody(r, ob, size, s.atrPeriod);
   if(d.atr <= 0.0 || avgBody < 0.0)
     {
      d.reject = SMC_REJ_INSUFFICIENT_DATA;
      return false;
     }

   //--- 3. leg metrics
   d.netMove = dir * (r[i].close - r[ob - 1].open);
   int best = -1;
   double legExtreme = (dir == SMC_DIR_BULL) ? DBL_MAX : -DBL_MAX;
   for(int k = i; k <= ob - 1; k++)
     {
      if(SMC_IsDirCandle(r[k], dir) && (best < 0 || SMC_Body(r[k]) > d.strongestBody))
        {
         best = k;
         d.strongestBody = SMC_Body(r[k]);
        }
      if(dir == SMC_DIR_BULL) legExtreme = MathMin(legExtreme, r[k].low);
      else                    legExtreme = MathMax(legExtreme, r[k].high);
     }
   d.strongestBodyPct = (best >= 0) ? SMC_BodyPct(r[best]) : 0.0;
   d.relStrength = (avgBody > 0.0) ? d.strongestBody / avgBody : (d.strongestBody > 0.0 ? 999.0 : 0.0);

   if(d.netMove < s.dispATRMult * d.atr)                  { d.reject = SMC_REJ_WEAK_MOVE;     return false; }
   if(best < 0 || d.strongestBody < s.dispCandleATRMult * d.atr) { d.reject = SMC_REJ_WEAK_CANDLE; return false; }
   if(d.strongestBodyPct < s.dispMinBodyPct)             { d.reject = SMC_REJ_SMALL_BODY;    return false; }
   if(d.relStrength < s.dispMinRelStrength)              { d.reject = SMC_REJ_WEAK_RELATIVE; return false; }

   if(s.rejectLegViolation)
     {
      bool violated = (dir == SMC_DIR_BULL) ? (legExtreme < r[ob].low) : (legExtreme > r[ob].high);
      if(violated)
        {
         d.reject = SMC_REJ_LEG_VIOLATES_OB;
         return false;
        }
     }
   return true;
  }

#endif // SMC_OB_DISPLACEMENT_MQH
