//+------------------------------------------------------------------+
//|                                           SMC_OB_Confidence.mqh |
//|  Confidence score for a confirmed HTF OB + LTF CISD setup.       |
//|                                                                  |
//|  0 to 100, from information the detection engines already        |
//|  produced by the time the CISD confirms. Nothing here looks      |
//|  forward, so the score cannot repaint.                           |
//|                                                                  |
//|  Phase 1 of its life is measurement only: the score is computed  |
//|  and written to a log, and it does NOT change position size or   |
//|  any trading decision. The weights below are a starting point,   |
//|  to be replaced once enough live scores exist to regress against |
//|  realised R.                                                     |
//+------------------------------------------------------------------+
#ifndef SMC_OB_CONFIDENCE_MQH
#define SMC_OB_CONFIDENCE_MQH

#include "SMC_OB_Types.mqh"

//--- every component kept separately, so a score can be taken apart afterwards
struct SSMCConfidence
  {
   double            total;          // 0 .. 100
   double            trend;          // 20
   double            quality;        // 15
   double            impulse;        // 10
   double            freshness;      // 10
   double            retest;         //  8
   double            height;         //  8
   double            fvg;            //  7
   double            cisd;           //  7
   double            spread;         //  6
   double            session;        //  5
   double            sweep;          //  4
   //--- the raw readings behind them, for the regression later
   double            trendScore;
   double            relStrength;
   double            bodyPct;
   double            impulseATR;
   double            ageBars;
   int               retestNo;
   double            zoneATR;
   double            confirmBeyondATR;
   double            spreadPctOfR;
   int               hour;
   double            sweepAgeBars;
  };

//--- 0 at lo, 1 at hi, flat outside
double SMC_Norm(const double v, const double lo, const double hi)
  {
   if(hi <= lo)
      return 0.0;
   return MathMax(0.0, MathMin(1.0, (v - lo) / (hi - lo)));
  }

//--- 1 inside the band, decaying to 0 one band-width outside it
double SMC_Band(const double v, const double lo, const double hi)
  {
   if(v >= lo && v <= hi)
      return 1.0;
   double w = MathMax(hi - lo, 1e-9);
   double d = (v < lo) ? (lo - v) : (v - hi);
   return MathMax(0.0, 1.0 - d / w);
  }

//--- London pays most, New York next, Asia least. Server hours.
double SMC_SessionWeight(const int hour)
  {
   if(hour >= 8 && hour <= 15)
      return 1.0;
   if(hour >= 16 && hour <= 23)
      return 0.8;
   return 0.4;
  }

//+------------------------------------------------------------------+
//| Score one confirmed setup.                                       |
//|   ob          the order block the signal belongs to              |
//|   trendScore  signed displacement in ATR that passed the gate    |
//|   retestNo    which retest produced this signal                  |
//|   cisdLevel   the level the confirmation closed through          |
//|   confirmPx   the confirming close                               |
//|   sweepTime   0 when no liquidity sweep preceded the CISD        |
//|   signalTime  confirmation time                                  |
//|   riskPrice   entry to stop distance, in price                   |
//+------------------------------------------------------------------+
SSMCConfidence SMC_Confidence(const SOrderBlock &ob, const double trendScore, const int retestNo,
                              const double cisdLevel, const double confirmPx, const datetime sweepTime,
                              const datetime signalTime, const double riskPrice,
                              const int obPeriodSeconds, const int cisdPeriodSeconds)
  {
   SSMCConfidence c;
   ZeroMemory(c);
   double atr   = (ob.atr > 0.0) ? ob.atr : 1.0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   //--- raw readings
   c.trendScore  = trendScore;
   c.relStrength = ob.relStrength;
   c.bodyPct     = ob.strongestBodyPct;
   c.impulseATR  = MathAbs(ob.netMove) / atr;
   c.ageBars     = (obPeriodSeconds > 0) ? (double)(signalTime - ob.confirmTime) / obPeriodSeconds : 0.0;
   c.retestNo    = retestNo;
   c.zoneATR     = (ob.top - ob.bottom) / atr;
   c.confirmBeyondATR = (cisdLevel > 0.0) ? MathAbs(confirmPx - cisdLevel) / atr : 0.0;
   c.spreadPctOfR     = (riskPrice > 0.0)
                        ? ((double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * point) / riskPrice : 1.0;
   MqlDateTime dt;
   TimeToStruct(signalTime, dt);
   c.hour = dt.hour;
   c.sweepAgeBars = (sweepTime > 0 && cisdPeriodSeconds > 0)
                    ? (double)(signalTime - sweepTime) / cisdPeriodSeconds : -1.0;

   //--- weighted components
   c.trend     = 20.0 * SMC_Norm(MathAbs(c.trendScore), 1.5, 3.0);
   c.quality   = 15.0 * (0.6 * SMC_Norm(c.relStrength, 1.5, 3.0) + 0.4 * SMC_Norm(c.bodyPct, 55.0, 75.0));
   c.impulse   = 10.0 * SMC_Norm(c.impulseATR, 1.5, 3.0);
   c.freshness = 10.0 * (1.0 - SMC_Norm(c.ageBars, 10.0, 60.0));
   c.retest    =  8.0 * (retestNo <= 1 ? 1.0 : (retestNo == 2 ? 0.5 : 0.0));
   c.height    =  8.0 * SMC_Band(c.zoneATR, 0.4, 1.2);
   c.fvg       =  7.0 * (ob.hasFVG ? (ob.fvgLate ? 0.5 : 1.0) : 0.0);
   c.cisd      =  7.0 * SMC_Norm(c.confirmBeyondATR, 0.0, 0.3);
   c.spread    =  6.0 * (1.0 - SMC_Norm(c.spreadPctOfR, 0.005, 0.03));
   c.session   =  5.0 * SMC_SessionWeight(c.hour);
   c.sweep     =  4.0 * ((c.sweepAgeBars < 0.0) ? 0.0 : (c.sweepAgeBars <= 10.0 ? 1.0 : 0.6));

   c.total = c.trend + c.quality + c.impulse + c.freshness + c.retest + c.height +
             c.fvg + c.cisd + c.spread + c.session + c.sweep;
   return c;
  }

//--- the band the score falls in, named the way the framework names it
string SMC_ConfidenceBand(const double score)
  {
   if(score >= 90.0)
      return "maximum";
   if(score >= 75.0)
      return "normal";
   if(score >= 60.0)
      return "reduced";
   return "below threshold";
  }

//--- one journal line, every component visible
string SMC_ConfidenceText(const SSMCConfidence &c)
  {
   return StringFormat("score %.1f (%s) | trend %.1f quality %.1f impulse %.1f fresh %.1f retest %.1f "
                       "height %.1f fvg %.1f cisd %.1f spread %.1f session %.1f sweep %.1f",
                       c.total, SMC_ConfidenceBand(c.total), c.trend, c.quality, c.impulse, c.freshness,
                       c.retest, c.height, c.fvg, c.cisd, c.spread, c.session, c.sweep);
  }

//--- one CSV row per scored setup, so the weights can be fitted against realised R later
void SMC_ConfidenceLog(const string file, const SSMCConfidence &c, const long obId, const int dir,
                       const datetime signalTime, const double entry, const double sl, const double tp)
  {
   int h = FileOpen(file, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(h == INVALID_HANDLE)
      return;
   if(FileSize(h) == 0)
      FileWrite(h, "time", "symbol", "ob_id", "dir", "entry", "sl", "tp", "score", "band",
                "trend", "quality", "impulse", "freshness", "retest", "height", "fvg", "cisd",
                "spread", "session", "sweep", "trend_score", "rel_strength", "body_pct", "impulse_atr",
                "age_bars", "retest_no", "zone_atr", "confirm_beyond_atr", "spread_pct_of_r", "hour",
                "sweep_age_bars");
   FileSeek(h, 0, SEEK_END);
   FileWrite(h, TimeToString(signalTime, TIME_DATE | TIME_MINUTES), _Symbol, obId,
             dir == SMC_DIR_BULL ? "BUY" : "SELL",
             DoubleToString(entry, _Digits), DoubleToString(sl, _Digits), DoubleToString(tp, _Digits),
             DoubleToString(c.total, 1), SMC_ConfidenceBand(c.total),
             DoubleToString(c.trend, 2), DoubleToString(c.quality, 2), DoubleToString(c.impulse, 2),
             DoubleToString(c.freshness, 2), DoubleToString(c.retest, 2), DoubleToString(c.height, 2),
             DoubleToString(c.fvg, 2), DoubleToString(c.cisd, 2), DoubleToString(c.spread, 2),
             DoubleToString(c.session, 2), DoubleToString(c.sweep, 2),
             DoubleToString(c.trendScore, 3), DoubleToString(c.relStrength, 3),
             DoubleToString(c.bodyPct, 2), DoubleToString(c.impulseATR, 3),
             DoubleToString(c.ageBars, 1), c.retestNo, DoubleToString(c.zoneATR, 3),
             DoubleToString(c.confirmBeyondATR, 3), DoubleToString(c.spreadPctOfR, 4), c.hour,
             DoubleToString(c.sweepAgeBars, 1));
   FileClose(h);
  }

#endif // SMC_OB_CONFIDENCE_MQH
