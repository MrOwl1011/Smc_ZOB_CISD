//+------------------------------------------------------------------+
//|                                                   SMC_OB_FVG.mqh |
//|  SPDX-License-Identifier: MIT                                    |
//|  https://github.com/MrOwl1011/Smc_ZOB_CISD                       |
//|  FVG Engine. Confluence only: it is invoked exclusively for an   |
//|  OB candidate that already passed BOS + displacement, so an FVG  |
//|  can never create an Order Block on its own.                     |
//|                                                                  |
//|  Three candles (m+1 oldest, m middle, m-1 newest):               |
//|    Bullish FVG: Low[m-1]  > High[m+1]  zone = [High[m+1], Low[m-1]] |
//|    Bearish FVG: High[m-1] < Low[m+1]   zone = [High[m-1], Low[m+1]] |
//|    size >= fvgMinATR * ATR                                       |
//|  The middle candle must belong to the displacement leg.          |
//+------------------------------------------------------------------+
#ifndef SMC_OB_FVG_MQH
#define SMC_OB_FVG_MQH

#include "SMC_OB_MarketData.mqh"

class CSMCFVG
  {
public:
   //--- single candle triple with middle m; needs m-1 >= i (already closed)
   bool              CheckAt(const MqlRates &r[], const int i, const int size, const int dir,
                             const int m, const double minSize, SFVG &f) const;
   //--- largest FVG whose three candles are all closed and whose middle is in the leg
   bool              FindInLeg(const MqlRates &r[], const int i, const int size, const int dir,
                               const int obIndex, const double minSize, SFVG &f) const;
  };

//+------------------------------------------------------------------+
bool CSMCFVG::CheckAt(const MqlRates &r[], const int i, const int size, const int dir,
                      const int m, const double minSize, SFVG &f) const
  {
   ZeroMemory(f);
   if(m - 1 < i || m + 1 >= size)
      return false;

   double top, bottom;
   if(dir == SMC_DIR_BULL)
     {
      bottom = r[m + 1].high;
      top    = r[m - 1].low;
     }
   else
     {
      top    = r[m + 1].low;
      bottom = r[m - 1].high;
     }
   double gap = top - bottom;
   if(gap <= 0.0 || gap < minSize)
      return false;
   if(!SMC_IsDirCandle(r[m], dir))
      return false;

   f.found     = true;
   f.leftTime  = r[m + 1].time;
   f.midTime   = r[m].time;
   f.rightTime = r[m - 1].time;
   f.top       = top;
   f.bottom    = bottom;
   return true;
  }

//+------------------------------------------------------------------+
bool CSMCFVG::FindInLeg(const MqlRates &r[], const int i, const int size, const int dir,
                        const int obIndex, const double minSize, SFVG &f) const
  {
   ZeroMemory(f);
   SFVG cand;
   for(int m = obIndex - 1; m >= i + 1; m--)
     {
      if(CheckAt(r, i, size, dir, m, minSize, cand) &&
         (!f.found || (cand.top - cand.bottom) > (f.top - f.bottom)))
         f = cand;
     }
   return f.found;
  }

#endif // SMC_OB_FVG_MQH
