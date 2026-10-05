//+------------------------------------------------------------------+
//|                                             SMC_OB_Structure.mqh |
//|  SPDX-License-Identifier: MIT                                    |
//|  https://github.com/MrOwl1011/Smc_ZOB_CISD                       |
//|  Market Structure Engine: swing confirmation and BOS detection.  |
//|                                                                  |
//|  Swing High at candle c (R = swingLength), confirmed when bar    |
//|  i = c - R has CLOSED:                                           |
//|     High[c] >  High[c+j]  for j = 1..R   (older bars, strict)    |
//|     High[c] >= High[c-j]  for j = 1..R   (newer bars)            |
//|     High[c] - min(Low[c-R..c+R]) >= swingMinATR * ATR(c)         |
//|  Swing Low is the mirror image.                                  |
//|                                                                  |
//|  Bullish BOS on closed bar i:                                    |
//|     S = most recent confirmed, unbroken swing high (time < bar i)|
//|     Close[i] > S.price + buffer   (buffer = k*ATR in buffer mode)|
//|  All unbroken swing highs below that close are consumed, so one  |
//|  swing can never produce a second BOS.                           |
//+------------------------------------------------------------------+
#ifndef SMC_OB_STRUCTURE_MQH
#define SMC_OB_STRUCTURE_MQH

#include "SMC_OB_MarketData.mqh"

class CSMCStructure
  {
private:
   SSwing            m_highs[];     // chronological (oldest first)
   SSwing            m_lows[];
   int               m_trend;       // last BOS direction, 0 = unknown
   int               m_maxSwings;

   void              Push(SSwing &arr[], const SSwing &sw);
   int               LatestUnbroken(const SSwing &arr[], const datetime before) const;
   bool              IsSwing(const MqlRates &r[], const int c, const int size,
                             const int type, const SSMCSettings &s) const;
   bool              BreakSide(const MqlRates &r[], const int i, const int size,
                               const int dir, const double buffer, SBOS &bos);

public:
                     CSMCStructure(void) : m_trend(0), m_maxSwings(300) {}
   void              Reset(void);
   int               Trend(void) const { return m_trend; }
   int               ConfirmSwings(const MqlRates &r[], const int i, const int size,
                                   const SSMCSettings &s, SSwing &out[]);
   int               DetectBOS(const MqlRates &r[], const int i, const int size,
                               const SSMCSettings &s, SBOS &out[]);
   int               SwingCount(const int type) const;
   bool              GetSwing(const int type, const int idx, SSwing &out) const;
  };

//+------------------------------------------------------------------+
void CSMCStructure::Reset(void)
  {
   ArrayResize(m_highs, 0);
   ArrayResize(m_lows, 0);
   m_trend = 0;
  }

//+------------------------------------------------------------------+
void CSMCStructure::Push(SSwing &arr[], const SSwing &sw)
  {
   int n = ArraySize(arr);
   if(n >= m_maxSwings)
     {
      //--- drop the oldest swing (chronological array)
      for(int k = 1; k < n; k++)
         arr[k - 1] = arr[k];
      n--;
      ArrayResize(arr, n);
     }
   ArrayResize(arr, n + 1, 64);
   arr[n] = sw;
  }

//+------------------------------------------------------------------+
int CSMCStructure::LatestUnbroken(const SSwing &arr[], const datetime before) const
  {
   for(int k = ArraySize(arr) - 1; k >= 0; k--)
      if(!arr[k].broken && arr[k].time < before)
         return k;
   return -1;
  }

//+------------------------------------------------------------------+
bool CSMCStructure::IsSwing(const MqlRates &r[], const int c, const int size,
                            const int type, const SSMCSettings &s) const
  {
   int R = s.swingLength;
   if(c - R < 0 || c + R >= size)
      return false;

   double extreme = (type == SMC_DIR_BULL) ? r[c].high : r[c].low;
   double opposite = (type == SMC_DIR_BULL) ? r[c].low : r[c].high;

   for(int j = 1; j <= R; j++)
     {
      if(type == SMC_DIR_BULL)
        {
         if(r[c + j].high >= extreme) return false;   // older bars strictly lower
         if(r[c - j].high >  extreme) return false;   // newer bars not higher
         opposite = MathMin(opposite, MathMin(r[c + j].low, r[c - j].low));
        }
      else
        {
         if(r[c + j].low <= extreme) return false;
         if(r[c - j].low <  extreme) return false;
         opposite = MathMax(opposite, MathMax(r[c + j].high, r[c - j].high));
        }
     }

   if(s.swingMinATR > 0.0)
     {
      double atr = SMC_ATR(r, c, size, s.atrPeriod);
      if(atr <= 0.0)
         return false;
      if(MathAbs(extreme - opposite) < s.swingMinATR * atr)
         return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Evaluate candidate c = i + R using bars up to i (closed).        |
//+------------------------------------------------------------------+
int CSMCStructure::ConfirmSwings(const MqlRates &r[], const int i, const int size,
                                 const SSMCSettings &s, SSwing &out[])
  {
   ArrayResize(out, 0);
   int c = i + s.swingLength;
   if(c + s.swingLength >= size)
      return 0;

   for(int t = 0; t < 2; t++)
     {
      int type = (t == 0) ? SMC_DIR_BULL : SMC_DIR_BEAR;
      if(!IsSwing(r, c, size, type, s))
         continue;

      int n = (type == SMC_DIR_BULL) ? ArraySize(m_highs) : ArraySize(m_lows);
      datetime lastTime = 0;
      if(n > 0)
         lastTime = (type == SMC_DIR_BULL) ? m_highs[n - 1].time : m_lows[n - 1].time;
      if(lastTime >= r[c].time)
         continue;                                   // already recorded

      SSwing sw;
      ZeroMemory(sw);
      sw.type        = type;
      sw.time        = r[c].time;
      sw.price       = (type == SMC_DIR_BULL) ? r[c].high : r[c].low;
      sw.confirmTime = r[i].time;
      sw.broken      = false;

      if(type == SMC_DIR_BULL) Push(m_highs, sw);
      else                     Push(m_lows, sw);

      int k = ArraySize(out);
      ArrayResize(out, k + 1);
      out[k] = sw;
     }
   return ArraySize(out);
  }

//+------------------------------------------------------------------+
bool CSMCStructure::BreakSide(const MqlRates &r[], const int i, const int size,
                              const int dir, const double buffer, SBOS &bos)
  {
   double close = r[i].close;
   datetime t = r[i].time;
   int idx;
   SSwing ref;

   if(dir == SMC_DIR_BULL)
     {
      idx = LatestUnbroken(m_highs, t);
      if(idx < 0 || !(close > m_highs[idx].price + buffer))
         return false;
      ref = m_highs[idx];
      for(int k = ArraySize(m_highs) - 1; k >= 0; k--)
         if(!m_highs[k].broken && m_highs[k].time < t && close > m_highs[k].price + buffer)
           {
            m_highs[k].broken = true;
            m_highs[k].brokenTime = t;
           }
     }
   else
     {
      idx = LatestUnbroken(m_lows, t);
      if(idx < 0 || !(close < m_lows[idx].price - buffer))
         return false;
      ref = m_lows[idx];
      for(int k = ArraySize(m_lows) - 1; k >= 0; k--)
         if(!m_lows[k].broken && m_lows[k].time < t && close < m_lows[k].price - buffer)
           {
            m_lows[k].broken = true;
            m_lows[k].brokenTime = t;
           }
     }

   ZeroMemory(bos);
   bos.dir        = dir;
   bos.barTime    = t;
   bos.closePrice = close;
   bos.level      = ref.price;
   bos.swingTime  = ref.time;
   bos.isChoch    = (m_trend == -dir);
   m_trend        = dir;
   return true;
  }

//+------------------------------------------------------------------+
int CSMCStructure::DetectBOS(const MqlRates &r[], const int i, const int size,
                             const SSMCSettings &s, SBOS &out[])
  {
   ArrayResize(out, 0);
   double buffer = 0.0;
   if(s.bosMode == SMC_BOS_CLOSE_ATR_BUFFER)
      buffer = s.bosBufferATR * SMC_ATR(r, i, size, s.atrPeriod);

   SBOS bos;
   for(int t = 0; t < 2; t++)
     {
      int dir = (t == 0) ? SMC_DIR_BULL : SMC_DIR_BEAR;
      if(BreakSide(r, i, size, dir, buffer, bos))
        {
         int k = ArraySize(out);
         ArrayResize(out, k + 1);
         out[k] = bos;
        }
     }
   return ArraySize(out);
  }

//+------------------------------------------------------------------+
int CSMCStructure::SwingCount(const int type) const
  {
   return type == SMC_DIR_BULL ? ArraySize(m_highs) : ArraySize(m_lows);
  }

bool CSMCStructure::GetSwing(const int type, const int idx, SSwing &out) const
  {
   if(idx < 0 || idx >= SwingCount(type))
      return false;
   out = (type == SMC_DIR_BULL) ? m_highs[idx] : m_lows[idx];
   return true;
  }

#endif // SMC_OB_STRUCTURE_MQH
