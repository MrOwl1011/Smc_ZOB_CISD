//+------------------------------------------------------------------+
//|                                            SMC_OB_MarketData.mqh |
//|  Candle and volatility helpers. Every function reads only r[i]   |
//|  and OLDER bars (r[i+k]); none of them can look ahead.           |
//+------------------------------------------------------------------+
#ifndef SMC_OB_MARKETDATA_MQH
#define SMC_OB_MARKETDATA_MQH

#include "SMC_OB_Types.mqh"

double SMC_Body(const MqlRates &b)    { return MathAbs(b.close - b.open); }
double SMC_Range(const MqlRates &b)   { return b.high - b.low; }
bool   SMC_IsBullish(const MqlRates &b) { return b.close > b.open; }
bool   SMC_IsBearish(const MqlRates &b) { return b.close < b.open; }

//--- candle colour matches a direction (+1 bullish, -1 bearish); dojis match neither
bool SMC_IsDirCandle(const MqlRates &b, const int dir)
  {
   return dir == SMC_DIR_BULL ? SMC_IsBullish(b) : SMC_IsBearish(b);
  }

double SMC_BodyPct(const MqlRates &b)
  {
   double rng = SMC_Range(b);
   return rng > 0.0 ? SMC_Body(b) / rng * 100.0 : 0.0;
  }

//--- True range of bar i (needs the previous close at i+1)
double SMC_TrueRange(const MqlRates &r[], const int i, const int size)
  {
   if(i + 1 >= size)
      return SMC_Range(r[i]);
   double pc = r[i + 1].close;
   return MathMax(r[i].high, pc) - MathMin(r[i].low, pc);
  }

//--- Simple-average ATR over bars i .. i+period-1. Returns 0 if not enough data.
double SMC_ATR(const MqlRates &r[], const int i, const int size, const int period)
  {
   if(period <= 0 || i < 0 || i + period >= size)
      return 0.0;
   double sum = 0.0;
   for(int k = i; k < i + period; k++)
      sum += SMC_TrueRange(r, k, size);
   return sum / period;
  }

//--- Average candle body over bars i .. i+period-1. Returns -1 if not enough data.
double SMC_AvgBody(const MqlRates &r[], const int i, const int size, const int period)
  {
   if(period <= 0 || i < 0 || i + period > size)
      return -1.0;
   double sum = 0.0;
   for(int k = i; k < i + period; k++)
      sum += SMC_Body(r[k]);
   return sum / period;
  }

#endif // SMC_OB_MARKETDATA_MQH
