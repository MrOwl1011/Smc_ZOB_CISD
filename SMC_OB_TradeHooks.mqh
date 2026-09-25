//+------------------------------------------------------------------+
//|                                            SMC_OB_TradeHooks.mqh |
//|  Future Trading Engine placeholder.                              |
//|                                                                  |
//|  Version 1 intentionally places NO orders. This layer only       |
//|  receives detector events and has read-only access to detector   |
//|  state, so entry / SL / TP / sizing logic can be added here later |
//|  without touching any detection code.                            |
//+------------------------------------------------------------------+
#ifndef SMC_OB_TRADEHOOKS_MQH
#define SMC_OB_TRADEHOOKS_MQH

#include "SMC_OB_Engine.mqh"

class CSMCTradeEngine
  {
private:
   bool              m_enabled;

public:
                     CSMCTradeEngine(void) : m_enabled(false) {}

   //--- trading is hard-disabled in this version regardless of the argument
   void              Init(const bool requested) { m_enabled = false; if(requested) Print("[SMC-OB] Trading engine is not implemented in this version; no orders will be placed."); }
   bool              IsEnabled(void) const { return m_enabled; }

   //--- called for every detector event (after visualization)
   void              OnDetectorEvent(const SSMCEvent &e, const CSMCDetector &det)
     {
      if(!m_enabled || e.historical)
         return;                           // never act on history-scan events
      switch(e.type)
        {
         case SMC_EVT_OB_CREATED:     /* future: arm a pending setup for e.obId          */ break;
         case SMC_EVT_OB_RETEST:      /* future: entry trigger on first retest (e.flag)  */ break;
         case SMC_EVT_OB_MITIGATED:   /* future: manage / cancel setups for e.obId       */ break;
         case SMC_EVT_OB_INVALIDATED: /* future: cancel setups, close related positions  */ break;
         default: break;
        }
     }

   //--- called for every ZOrder detector event (same event types as above)
   void              OnZOrderEvent(const SSMCEvent &e, const CSMCDetector &zdet)
     {
      if(!m_enabled || e.historical)
         return;
      /* future: ZOrder-specific setups for e.obId */
     }

   //--- called for every CISD event (sweep, setup, confirmation, retracement ...).
   //--- The engine is passed as an opaque pointer-free id so this header stays independent;
   //--- future CISD entry logic receives e.type / e.id / e.price here.
   void              OnCISDEvent(const int type, const long id, const int dir, const datetime t, const double price, const bool historical)
     {
      if(!m_enabled || historical)
         return;
      /* future: CISD retracement entry (type == CISD_EVT_RETRACED) */
     }

   //--- HTF OB -> LTF CISD workflow events (retest, activation, sweep, confirmation, retracement ...).
   //--- A confirmed setup = HTF OB retest + LTF CISD; future entry logic starts here.
   void              OnConnectionEvent(const int type, const long setupId, const long obId, const int obKind,
                                       const int dir, const long cisdId, const datetime t, const double price,
                                       const bool historical)
     {
      if(!m_enabled || historical)
         return;
      /* future: entry on CONN_EVT_CONFIRMED / CONN_EVT_RETRACED */
     }

   //--- called once per new closed bar after detection has run
   void              OnNewBar(const CSMCDetector &det)
     {
      if(!m_enabled)
         return;
      /* future: SOrderBlock live[]; det.GetLiveOBs(0, live); ... */
     }
  };

#endif // SMC_OB_TRADEHOOKS_MQH
