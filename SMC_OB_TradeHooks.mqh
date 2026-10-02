//+------------------------------------------------------------------+
//|                                            SMC_OB_TradeHooks.mqh |
//|  Trade execution layer.                                          |
//|                                                                  |
//|  Detection never calls into the broker. This layer only receives  |
//|  detector / connection events and, when trading is switched on,   |
//|  places ONE market order per confirmed HTF OB + LTF CISD setup:   |
//|                                                                  |
//|    entry : market, at the CISD confirmation                      |
//|    stop  : the far side of the Order Block (below a bull block,  |
//|            above a bear block)                                   |
//|    target: reward:risk multiple of the stop distance (def 1:1)   |
//|    size  : fixed lots, or a percent of equity risked on the stop  |
//|                                                                  |
//|  Only one position at a time, and only on live events - history   |
//|  scan events are ignored.                                        |
//|                                                                  |
//|  Opposite Block Exit (optional): while a position is open, a new  |
//|  Order Block / ZOrder Block against it that price then retests    |
//|  closes the position - the market built and respected structure   |
//|  in the other direction.                                         |
//|                                                                  |
//|  Break even (optional): once the position is a set number of     |
//|  points in profit, the stop moves to the entry price, once.      |
//|                                                                  |
//|  Entry alert (optional): announces entry, stop and target at the  |
//|  moment a setup confirms. It works whether or not execution is on, |
//|  so the EA can be used purely as a signal tool.                   |
//|                                                                  |
//|  Ride the trend (optional): no fixed target at all. The position |
//|  is held until price reaches the nearest live Order Block facing  |
//|  the other way, which becomes a moving take profit. While this is |
//|  on, the reward:risk multiple is not used.                        |
//+------------------------------------------------------------------+
#ifndef SMC_OB_TRADEHOOKS_MQH
#define SMC_OB_TRADEHOOKS_MQH

#include <Trade\Trade.mqh>
#include "SMC_OB_Engine.mqh"

class CSMCTradeEngine
  {
private:
   CTrade            m_trade;
   bool              m_enabled;
   bool              m_oppExit;       // close on a retested opposite block
   double            m_rr;            // take profit as a multiple of risk
   bool              m_ride;          // hold to the nearest opposite block instead of a fixed target
   bool              m_alerts;        // announce every entry signal, with or without execution
   bool              m_riskPct;       // size from a percent of equity instead of fixed lots
   double            m_riskPercent;   // percent of equity risked per trade when m_riskPct is on
   bool              m_beEnabled;     // move the stop to entry once in profit
   int               m_bePoints;      // profit in points that arms it
   double            m_lots;
   long              m_magic;
   ENUM_TIMEFRAMES   m_obTF;          // for the alert text only
   bool              m_ready;
   bool              m_warned;        // "trading not allowed" logged once
   int               m_sent;          // orders accepted by the server
   int               m_closed;        // positions closed by the opposite block exit
   int               m_beMoved;       // stops moved to break even
   int               m_rideExits;     // positions closed at an opposite block
   int               m_alerted;       // entry alerts raised
   int               m_skipped;       // signals skipped (open position, invalid stop, rejected)
   string            m_last;          // last action, for the panel status line

   //--- the open position of this EA, if any
   bool              FindPosition(ulong &ticket, int &dir, datetime &opened) const
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong t = PositionGetTicket(i);
         if(t == 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != m_magic)
            continue;
         ticket = t;
         dir    = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SMC_DIR_BULL : SMC_DIR_BEAR;
         opened = (datetime)PositionGetInteger(POSITION_TIME);
         return true;
        }
      return false;
     }

   //--- one position per symbol + magic
   bool              HasPosition(void) const
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == m_magic)
            return true;
        }
      return false;
     }

   //--- Lots that put exactly riskMoney at risk over a stop of riskPrice.
   //--- Falls back to the fixed lot size when the symbol does not report what a
   //--- point is worth, so a broken quote can never silently size up.
   double            LotsForRisk(const double riskPrice, double &riskMoneyOut) const
     {
      riskMoneyOut = 0.0;
      if(riskPrice <= 0.0)
         return m_lots;
      double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(point <= 0.0 || tickVal <= 0.0 || tickSize <= 0.0)
        {
         Print("[SMC-TRADE] risk sizing unavailable for ", _Symbol, ": using the fixed lot size");
         return m_lots;
        }
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity <= 0.0)
         return m_lots;
      double riskMoney       = equity * m_riskPercent / 100.0;
      double valuePerPointLot = tickVal * (point / tickSize);     // account currency per point per 1.00 lot
      double riskPoints       = riskPrice / point;
      if(valuePerPointLot <= 0.0 || riskPoints <= 0.0)
         return m_lots;
      riskMoneyOut = riskMoney;
      return riskMoney / (riskPoints * valuePerPointLot);
     }

   //--- Shrink a size that the account cannot margin, rather than letting the
   //--- order be rejected.
   double            FitMargin(const double lots, const int dir) const
     {
      double v = lots;
      double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      if(step <= 0.0)
         step = 0.01;
      double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.9;   // keep a tenth spare
      double price = (dir == SMC_DIR_BULL) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                           : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      ENUM_ORDER_TYPE ot = (dir == SMC_DIR_BULL) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double need = 0.0;
      for(int guard = 0; guard < 50; guard++)
        {
         if(!OrderCalcMargin(ot, _Symbol, v, price, need))
            return v;                                   // cannot tell: leave it to the server
         if(need <= free || v <= step)
            return v;
         v = NormalizeDouble(v - step, 2);
        }
      return v;
     }

   double            NormLots(const double lots) const
     {
      double mn   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double mx   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      if(step <= 0.0)
         step = 0.01;
      double v = MathFloor(lots / step + 0.5) * step;
      if(mn > 0.0)
         v = MathMax(mn, v);
      if(mx > 0.0)
         v = MathMin(mx, v);
      return NormalizeDouble(v, 2);
     }

public:
                     CSMCTradeEngine(void) : m_enabled(false), m_oppExit(false), m_rr(1.0), m_ride(false), m_alerts(true), m_riskPct(false), m_riskPercent(0.5),
                                             m_beEnabled(false), m_bePoints(100), m_lots(0.01), m_obTF(PERIOD_CURRENT), m_magic(0), m_ready(false),
                                             m_warned(false), m_sent(0), m_closed(0), m_beMoved(0), m_rideExits(0), m_alerted(0),
                                             m_skipped(0), m_last("") {}

   //--- called once from OnInit
   void              Init(const bool enabled, const double lots, const long magic, const int slippage,
                           const double rr, const bool beEnabled, const int bePoints,
                           const bool ride, const bool alerts, const bool riskPct, const double riskPercent)
     {
      m_enabled = enabled;
      m_lots    = (lots > 0.0 ? lots : 0.01);
      m_rr        = (rr > 0.0 ? rr : 1.0);
      m_beEnabled = beEnabled;
      m_bePoints  = (bePoints > 0 ? bePoints : 100);
      m_ride      = ride;
      m_alerts    = alerts;
      m_riskPct     = riskPct;
      m_riskPercent = (riskPercent > 0.0 ? riskPercent : 0.5);
      m_magic   = magic;
      m_trade.SetExpertMagicNumber((ulong)magic);
      m_trade.SetDeviationInPoints((ulong)MathMax(0, slippage));
      m_trade.SetTypeFillingBySymbol(_Symbol);
      m_trade.LogLevel(LOG_LEVEL_ERRORS);
      m_ready = true;
      m_sent = 0;
      m_closed = 0;
      m_beMoved = 0;
      m_rideExits = 0;
      m_alerted = 0;
      m_skipped = 0;
      m_last = "";
     }

   void              SetEnabled(const bool on) { if(on != m_enabled) { m_enabled = on; Print("[SMC-TRADE] execution ", on ? "ON" : "OFF"); } }
   void              SetLots(const double lots) { if(lots > 0.0) m_lots = lots; }
   void              SetOBTimeframe(const ENUM_TIMEFRAMES tf) { m_obTF = tf; }
   void              SetTargetRR(const double rr) { if(rr > 0.0) m_rr = rr; }
   void              SetBreakEven(const bool on, const int points)
     {
      if(on != m_beEnabled)
         Print("[SMC-TRADE] break even ", on ? "ON" : "OFF");
      m_beEnabled = on;
      if(points > 0)
         m_bePoints = points;
     }
   void              SetRideTrend(const bool on)
     {
      if(on != m_ride)
         Print("[SMC-TRADE] ride the trend ", on ? "ON (no fixed target)" : "OFF");
      m_ride = on;
     }
   void              SetRiskPercent(const bool on, const double pct)
     {
      if(on != m_riskPct)
         Print("[SMC-TRADE] position sizing: ", on ? "percent of equity" : "fixed lots");
      m_riskPct = on;
      if(pct > 0.0)
         m_riskPercent = pct;
     }
   bool              RiskPercentMode(void) const { return m_riskPct; }
   double            RiskPercent(void) const { return m_riskPercent; }

   void              SetAlerts(const bool on)
     {
      if(on != m_alerts)
         Print("[SMC-TRADE] entry alerts ", on ? "ON" : "OFF");
      m_alerts = on;
     }
   bool              Alerts(void) const { return m_alerts; }
   int               Alerted(void) const { return m_alerted; }
   bool              RideTrend(void) const { return m_ride; }
   int               RideExits(void) const { return m_rideExits; }
   double            TargetRR(void) const { return m_rr; }
   bool              BreakEven(void) const { return m_beEnabled; }
   int               BreakEvenPoints(void) const { return m_bePoints; }
   int               BreakEvenMoved(void) const { return m_beMoved; }
   void              SetOppositeExit(const bool on) { if(on != m_oppExit) { m_oppExit = on; Print("[SMC-TRADE] opposite block exit ", on ? "ON" : "OFF"); } }
   bool              OppositeExit(void) const { return m_oppExit; }
   int               Closed(void) const { return m_closed; }
   bool              IsEnabled(void) const { return m_enabled; }
   double            Lots(void) const { return m_lots; }
   int               Sent(void) const { return m_sent; }
   int               Skipped(void) const { return m_skipped; }
   string            LastAction(void) const { return m_last; }
   string            StatusText(void) const
     {
      return StringFormat("trading %s | %s | %s | break even %s (%d pts) | opposite exit %s | "
                          "alerts %s | sent %d | closed %d | be %d | ride exits %d | skipped %d%s",
                          m_enabled ? "ON" : "OFF",
                          m_riskPct ? StringFormat("risk %.2f%%", m_riskPercent) : StringFormat("lots %.2f", m_lots),
                          m_ride ? "ride the trend" : StringFormat("1:%.2f", m_rr),
                          m_alerts ? "ON" : "OFF",
                          m_beEnabled ? "ON" : "OFF", m_bePoints, m_oppExit ? "ON" : "OFF",
                          m_sent, m_closed, m_beMoved, m_rideExits, m_skipped,
                          m_last == "" ? "" : " | " + m_last);
     }

   //--- Announce a confirmed setup with its levels. Raised at the moment the
   //--- trade would open, whether or not execution is switched on.
   void              EntryAlert(const int dir, const double entry, const double sl, const double tp,
                                const long obId, const bool traded)
     {
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      string side = (dir == SMC_DIR_BULL) ? "BUY" : "SELL";
      string target = (tp > 0.0) ? StringFormat("TP %.*f", digits, tp) : "TP at the opposite block";
      string text = StringFormat("%s %s  %s  entry %.*f  SL %.*f  %s  (OB #%I64d)%s",
                                 _Symbol, SMC_TFText(m_obTF), side,
                                 digits, entry, digits, sl, target, obId,
                                 traded ? "" : " [signal only]");
      m_alerted++;
      Alert(text);
      Print("[SMC-TRADE][ALERT] ", text);
     }

   //--- A confirmed HTF OB + LTF CISD setup: enter at market, stop on the far
   //--- side of the Order Block, target the same distance (1:1).
   bool              OnSignal(const int dir, const double obTop, const double obBottom,
                              const long obId, const long cisdId)
     {
      if(!m_ready || (!m_enabled && !m_alerts))
         return false;                            // nothing to do: no orders, no alerts
      if(obTop <= obBottom)
         return false;

      int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double stops  = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
      double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(ask <= 0.0 || bid <= 0.0)
         return false;

      double entry, sl, tp, risk;
      if(dir == SMC_DIR_BULL)
        {
         entry = ask;
         sl    = obBottom;                       // other side of the block
         risk  = entry - sl;
         tp    = m_ride ? 0.0 : entry + risk * m_rr;   // riding: the opposite block is the target
        }
      else
        {
         entry = bid;
         sl    = obTop;
         risk  = sl - entry;
         tp    = m_ride ? 0.0 : entry - risk * m_rr;
        }
      sl = NormalizeDouble(sl, digits);
      tp = (tp > 0.0) ? NormalizeDouble(tp, digits) : 0.0;

      if(risk <= 0.0 || risk <= stops)
        {
         if(m_enabled)
           {
            m_skipped++;
            m_last = StringFormat("skip OB #%I64d: stop too close (%.1f points)", obId, risk / (point > 0 ? point : 1));
           }
         return false;                            // an unusable stop is not worth announcing
        }

      //--- from here the setup is valid. Announce it before anything can stop the order,
      //--- so the alert is identical whether or not the EA is allowed to trade.
      bool willTrade = m_enabled &&
                       TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) && MQLInfoInteger(MQL_TRADE_ALLOWED) &&
                       !HasPosition();
      if(m_alerts)
         EntryAlert(dir, entry, sl, tp, obId, willTrade);

      if(!m_enabled)
         return false;
      if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
        {
         if(!m_warned)
           {
            m_warned = true;
            Print("[SMC-TRADE] trading is not allowed for this terminal / EA: no orders will be sent");
           }
         return false;
        }
      if(HasPosition())
        {
         m_skipped++;
         m_last = StringFormat("skip OB #%I64d: a position is already open", obId);
         return false;
        }

      double riskMoney = 0.0;
      double lots = m_riskPct ? NormLots(LotsForRisk(risk, riskMoney)) : NormLots(m_lots);
      lots = FitMargin(lots, dir);
      if(lots < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN) - 1e-9)
        {
         m_skipped++;
         m_last = StringFormat("skip OB #%I64d: risk %.2f is below one minimum lot", obId, riskMoney);
         Print("[SMC-TRADE] ", m_last);
         return false;
        }
      string cm   = StringFormat("SMC OB#%I64d CISD#%I64d", obId, cisdId);
      bool   ok   = (dir == SMC_DIR_BULL) ? m_trade.Buy(lots, _Symbol, 0.0, sl, tp, cm)
                                          : m_trade.Sell(lots, _Symbol, 0.0, sl, tp, cm);
      if(ok)
        {
         m_sent++;
         if(m_riskPct)
            PrintFormat("[SMC-TRADE] sizing: equity %.2f, risk %.2f%% = %.2f, stop %.1f points -> %.2f lots",
                        AccountInfoDouble(ACCOUNT_EQUITY), m_riskPercent, riskMoney,
                        risk / (point > 0 ? point : 1), lots);
         m_last = (tp > 0.0)
               ? StringFormat("%s %.2f @ %.*f sl %.*f tp %.*f (OB #%I64d)",
                              dir == SMC_DIR_BULL ? "BUY" : "SELL", lots, digits, entry, digits, sl, digits, tp, obId)
               : StringFormat("%s %.2f @ %.*f sl %.*f riding the trend (OB #%I64d)",
                              dir == SMC_DIR_BULL ? "BUY" : "SELL", lots, digits, entry, digits, sl, obId);
         Print("[SMC-TRADE] ", m_last);
        }
      else
        {
         m_skipped++;
         m_last = StringFormat("order rejected: retcode %d (%s)", m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
         Print("[SMC-TRADE] ", m_last);
        }
      return ok;
     }

   //--- Break-even: once the open position is m_bePoints in profit, the stop is
   //--- moved to the entry price. Runs once per position; a stop already at or
   //--- beyond entry is left alone.
   bool              ManageOpenPosition(void)
     {
      if(!m_enabled || !m_beEnabled || !m_ready)
         return false;
      ulong    ticket = 0;
      int      posDir = 0;
      datetime opened = 0;
      if(!FindPosition(ticket, posDir, opened))
         return false;
      if(!PositionSelectByTicket(ticket))
         return false;

      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      if(point <= 0.0)
         return false;
      int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double entry  = NormalizeDouble(PositionGetDouble(POSITION_PRICE_OPEN), digits);
      double sl     = PositionGetDouble(POSITION_SL);
      double tp     = PositionGetDouble(POSITION_TP);
      double price  = PositionGetDouble(POSITION_PRICE_CURRENT);
      double profit = (posDir == SMC_DIR_BULL) ? (price - entry) : (entry - price);
      if(profit < m_bePoints * point)
         return false;                            // not far enough in profit yet
      //--- already at or beyond entry: nothing to do
      if(sl != 0.0 && ((posDir == SMC_DIR_BULL && sl >= entry) || (posDir == SMC_DIR_BEAR && sl <= entry)))
         return false;
      //--- respect the broker's minimum distance from the current price
      double stops = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
      if(MathAbs(price - entry) <= stops)
         return false;

      if(!m_trade.PositionModify(ticket, entry, tp))
        {
         m_last = StringFormat("break even failed: retcode %d (%s)",
                               m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
         Print("[SMC-TRADE] ", m_last);
         return false;
        }
      m_beMoved++;
      m_last = StringFormat("stop moved to break even at %.*f (%.0f points in profit)",
                            digits, entry, profit / point);
      Print("[SMC-TRADE] ", m_last);
      return true;
     }

   //--- Ride the trend: the nearest live Order Block facing the other way becomes
   //--- the target. Its near edge is written as the position's take profit, and it
   //--- is updated whenever a closer block appears. If price is already past that
   //--- edge the position is closed at market.
   bool              RideOpenPosition(const CSMCDetector &det)
     {
      if(!m_enabled || !m_ride || !m_ready)
         return false;
      ulong    ticket = 0;
      int      posDir = 0;
      datetime opened = 0;
      if(!FindPosition(ticket, posDir, opened))
         return false;
      if(!PositionSelectByTicket(ticket))
         return false;

      int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double entry  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl     = PositionGetDouble(POSITION_SL);
      double tp     = PositionGetDouble(POSITION_TP);
      double price  = PositionGetDouble(POSITION_PRICE_CURRENT);
      int    want   = (posDir == SMC_DIR_BULL) ? SMC_DIR_BEAR : SMC_DIR_BULL;

      //--- nearest live opposite block ahead of the trade
      SOrderBlock obs[];
      int n = det.GetLiveOBs(want, obs);
      double target = 0.0;
      long   tid = 0;
      for(int i = 0; i < n; i++)
        {
         //--- a bearish block is resistance: its lower edge is the first touch from below
         double edge = (posDir == SMC_DIR_BULL) ? obs[i].bottom : obs[i].top;
         if(posDir == SMC_DIR_BULL && edge <= entry)
            continue;                              // not ahead of the trade
         if(posDir == SMC_DIR_BEAR && edge >= entry)
            continue;
         if(target == 0.0 ||
            (posDir == SMC_DIR_BULL && edge < target) || (posDir == SMC_DIR_BEAR && edge > target))
           {
            target = edge;
            tid = obs[i].id;
           }
        }
      if(target == 0.0)
         return false;                             // nothing opposite ahead yet: keep riding
      target = NormalizeDouble(target, digits);

      //--- already there: take it at market
      if((posDir == SMC_DIR_BULL && price >= target) || (posDir == SMC_DIR_BEAR && price <= target))
        {
         if(!m_trade.PositionClose(ticket))
            return false;
         m_rideExits++;
         m_last = StringFormat("closed %s at opposite Order Block #%I64d (%.*f)",
                               posDir == SMC_DIR_BULL ? "BUY" : "SELL", tid, digits, target);
         Print("[SMC-TRADE] ", m_last);
         return true;
        }
      //--- otherwise park the target there, respecting the broker's minimum distance
      double stops = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
      if(MathAbs(target - price) <= stops)
         return false;
      if(MathAbs(tp - target) < point / 2.0)
         return false;                             // already set there
      if(!m_trade.PositionModify(ticket, sl, target))
         return false;
      m_last = StringFormat("target set at opposite Order Block #%I64d (%.*f)", tid, digits, target);
      return true;
     }

   //--- Opposite Block Exit: a block created against the open position, and now
   //--- retested by price, closes that position.
   bool              OnOppositeBlockRetest(const SSMCEvent &e, const CSMCDetector &det, const bool zorder)
     {
      if(!m_enabled || !m_oppExit || !m_ready || e.historical)
         return false;
      if(e.type != SMC_EVT_OB_RETEST)
         return false;
      ulong    ticket = 0;
      int      posDir = 0;
      datetime opened = 0;
      if(!FindPosition(ticket, posDir, opened))
         return false;
      if(e.dir == posDir)
         return false;                            // same side as the trade: not an exit
      int idx = det.FindById(e.obId);
      SOrderBlock ob;
      if(idx < 0 || !det.GetOB(idx, ob))
         return false;
      if(ob.confirmTime <= opened)
         return false;                            // the block is older than the trade
      if(!m_trade.PositionClose(ticket))
        {
         m_last = StringFormat("close failed: retcode %d (%s)", m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
         Print("[SMC-TRADE] ", m_last);
         return false;
        }
      m_closed++;
      m_last = StringFormat("closed %s on retested opposite %s #%I64d",
                            posDir == SMC_DIR_BULL ? "BUY" : "SELL",
                            zorder ? "ZOrder Block" : "Order Block", e.obId);
      Print("[SMC-TRADE] ", m_last);
      return true;
     }

   //--- detector events: entries come from the confirmed setup; retests can exit
   void              OnDetectorEvent(const SSMCEvent &e, const CSMCDetector &det) { OnOppositeBlockRetest(e, det, false); }
   void              OnZOrderEvent(const SSMCEvent &e, const CSMCDetector &zdet) { OnOppositeBlockRetest(e, zdet, true); }
   void              OnCISDEvent(const int type, const long id, const int dir, const datetime t,
                                 const double price, const bool historical) { }
   void              OnConnectionEvent(const int type, const long setupId, const long obId, const int obKind,
                                       const int dir, const long cisdId, const datetime t, const double price,
                                       const bool historical) { }
   void              OnNewBar(const CSMCDetector &det) { }
  };

#endif // SMC_OB_TRADEHOOKS_MQH
