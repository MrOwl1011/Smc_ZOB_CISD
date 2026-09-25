//+------------------------------------------------------------------+
//|                                                 SMC_OB_Types.mqh |
//|  Shared enums, settings and data records for the SMC OB engine.   |
//|                                                                  |
//|  INDEXING CONVENTION (used by every engine in this project):     |
//|  All price arrays passed to the engines are in *series* order:   |
//|     r[0]      = newest CLOSED bar in the window                  |
//|     r[i + k]  = k bars OLDER than r[i]                           |
//|  An engine processing bar i may only read r[i], r[i+1], ...      |
//|  It never reads r[i-1] (the future). The forming bar is never    |
//|  passed in at all (data is copied starting at chart shift 1).    |
//+------------------------------------------------------------------+
#ifndef SMC_OB_TYPES_MQH
#define SMC_OB_TYPES_MQH

#define SMC_DIR_BULL  1
#define SMC_DIR_BEAR -1

//--- BOS confirmation mode
enum ENUM_SMC_BOS_MODE
  {
   SMC_BOS_CLOSE = 0,            // Closed candle closes beyond swing level
   SMC_BOS_CLOSE_ATR_BUFFER = 1  // Close beyond swing level + ATR buffer
  };

//--- Order Block zone calculation
enum ENUM_SMC_ZONE_MODE
  {
   SMC_ZONE_WICK = 0,            // Full candle range (High - Low)
   SMC_ZONE_BODY = 1,            // Candle body (Open - Close)
   SMC_ZONE_OPEN_TO_EXTREME = 2, // Open to extreme (bull: Low-Open, bear: Open-High)
   SMC_ZONE_OPEN_LAST_EXTREME = 3 // First candle Open to last candle extreme (bull: first Open - last Low, bear: first Open - last High)
  };

//--- Which candles form the zone
enum ENUM_SMC_ZONE_SOURCE
  {
   SMC_SOURCE_LAST_CANDLE = 0,   // Standard OB: last opposite candle
   SMC_SOURCE_CANDLE_SERIES = 1  // ZOrder Block: complete consecutive opposite-candle series
  };

//--- FVG usage
enum ENUM_SMC_FVG_MODE
  {
   SMC_FVG_OFF = 0,              // Disabled
   SMC_FVG_CONFLUENCE = 1,       // Confluence tag only (never required)
   SMC_FVG_REQUIRED = 2          // OB requires an FVG in its displacement
  };

//--- Mitigation rule
enum ENUM_SMC_MITIGATION_MODE
  {
   SMC_MIT_OFF = 0,              // Disabled
   SMC_MIT_TOUCH = 1,            // Any touch of the zone
   SMC_MIT_MIDPOINT = 2,         // Price reaches 50% of the zone
   SMC_MIT_FULL = 3              // Price wicks to the far edge of the zone
  };

//--- Invalidation rule
enum ENUM_SMC_INVALIDATION_MODE
  {
   SMC_INV_OFF = 0,              // Disabled
   SMC_INV_CLOSE_BEYOND = 1,     // Candle CLOSES beyond the far edge
   SMC_INV_WICK_BEYOND = 2       // Candle WICKS beyond the far edge
  };

//--- Overlap handling between same-direction live OBs
enum ENUM_SMC_OVERLAP_MODE
  {
   SMC_OVERLAP_KEEP_ALL = 0,      // Keep both (tag the overlap)
   SMC_OVERLAP_SKIP_NEW = 1,      // Keep older zone, reject the new one
   SMC_OVERLAP_SUPERSEDE_OLD = 2  // Keep newer zone, retire the older one
  };

enum ENUM_SMC_LOG_LEVEL
  {
   SMC_LOG_OFF = 0,              // Off
   SMC_LOG_EVENTS = 1,           // Events (OB created, retest, mitigation...)
   SMC_LOG_VERBOSE = 2           // Verbose (includes every rejection reason)
  };

//--- Life-cycle of an Order Block
enum ENUM_SMC_OB_STATE
  {
   SMC_OB_ACTIVE = 0,
   SMC_OB_RETESTED,
   SMC_OB_MITIGATED,
   SMC_OB_INVALIDATED,
   SMC_OB_EXPIRED,
   SMC_OB_SUPERSEDED
  };

enum ENUM_SMC_EVENT
  {
   SMC_EVT_SWING = 0,
   SMC_EVT_BOS,
   SMC_EVT_OB_CREATED,
   SMC_EVT_OB_FVG_LINKED,
   SMC_EVT_OB_RETEST,
   SMC_EVT_OB_MITIGATED,
   SMC_EVT_OB_INVALIDATED,
   SMC_EVT_OB_EXPIRED,
   SMC_EVT_OB_SUPERSEDED,
   SMC_EVT_OB_REMOVED
  };

//--- Why a BOS did not produce an Order Block
enum ENUM_SMC_REJECT
  {
   SMC_REJ_NONE = 0,
   SMC_REJ_DIRECTION_DISABLED,
   SMC_REJ_INSUFFICIENT_DATA,
   SMC_REJ_BOS_CANDLE_OPPOSITE,
   SMC_REJ_NO_OPPOSITE_CANDLE,
   SMC_REJ_WEAK_MOVE,
   SMC_REJ_WEAK_CANDLE,
   SMC_REJ_SMALL_BODY,
   SMC_REJ_WEAK_RELATIVE,
   SMC_REJ_LEG_VIOLATES_OB,
   SMC_REJ_ZERO_ZONE,
   SMC_REJ_FVG_MISSING,
   SMC_REJ_OVERLAP,
   SMC_REJ_DUPLICATE,
   SMC_REJ_SERIES_TOO_LONG
  };

//+------------------------------------------------------------------+
//| Detection settings (decoupled from EA inputs so the engine can be |
//| driven by tests or other EAs with their own parameters).          |
//+------------------------------------------------------------------+
struct SSMCSettings
  {
   //--- market structure
   int                        swingLength;        // bars each side of a swing
   double                     swingMinATR;        // min swing prominence (x ATR)
   ENUM_SMC_BOS_MODE          bosMode;
   double                     bosBufferATR;
   //--- displacement
   int                        atrPeriod;
   double                     dispATRMult;        // net leg move >= x ATR
   double                     dispCandleATRMult;  // strongest body >= x ATR
   double                     dispMinBodyPct;     // strongest candle body % of range
   double                     dispMinRelStrength; // strongest body / avg prior body
   int                        maxOBToBOSBars;     // max leg length OB -> BOS
   bool                       rejectLegViolation; // leg may not trade beyond OB far edge
   //--- order block
   ENUM_SMC_ZONE_MODE         zoneMode;
   ENUM_SMC_ZONE_SOURCE       zoneSource;         // standard OB (default) or ZOrder series
   ENUM_SMC_OVERLAP_MODE      overlapMode;
   double                     overlapPct;
   int                        maxActivePerDir;
   int                        maxAgeBars;         // 0 = never expire
   int                        maxStored;
   bool                       enableBull;
   bool                       enableBear;
   //--- FVG
   ENUM_SMC_FVG_MODE          fvgMode;
   double                     fvgMinATR;
   //--- retest / mitigation
   bool                       retestEnabled;
   ENUM_SMC_MITIGATION_MODE   mitigationMode;
   ENUM_SMC_INVALIDATION_MODE invalidationMode;
   //--- misc
   ENUM_SMC_LOG_LEVEL         logLevel;
  };

//+------------------------------------------------------------------+
//| Confirmed swing point                                            |
//+------------------------------------------------------------------+
struct SSwing
  {
   int               type;          // SMC_DIR_BULL = swing high, SMC_DIR_BEAR = swing low
   datetime          time;          // swing candle open time
   double            price;
   datetime          confirmTime;   // bar whose close confirmed the swing
   bool              broken;
   datetime          brokenTime;
  };

//+------------------------------------------------------------------+
//| Break of structure                                               |
//+------------------------------------------------------------------+
struct SBOS
  {
   int               dir;
   datetime          barTime;       // closed candle that broke structure
   double            closePrice;
   double            level;         // broken swing price
   datetime          swingTime;
   bool              isChoch;       // break against prior structure direction
  };

//+------------------------------------------------------------------+
//| Displacement evaluation result                                   |
//+------------------------------------------------------------------+
struct SDisplacement
  {
   ENUM_SMC_REJECT   reject;
   int               obIndex;       // series index of last opposite candle
   int               legBars;       // candles from OB (exclusive) to BOS (inclusive)
   double            atr;           // ATR measured at the OB candle (pre-displacement)
   double            netMove;
   double            strongestBody;
   double            strongestBodyPct;
   double            relStrength;
  };

//+------------------------------------------------------------------+
//| Fair Value Gap                                                   |
//+------------------------------------------------------------------+
struct SFVG
  {
   bool              found;
   datetime          leftTime;      // candle 1
   datetime          midTime;       // candle 2 (displacement candle)
   datetime          rightTime;     // candle 3
   double            top;
   double            bottom;
  };

//+------------------------------------------------------------------+
//| Order Block record.                                              |
//| Identity fields (dir, obTime, top, bottom, confirmTime, BOS info) |
//| are written ONCE at confirmation and never modified afterwards.  |
//| Only life-cycle fields (state, retest, mitigation...) change.    |
//+------------------------------------------------------------------+
struct SOrderBlock
  {
   //--- identity (immutable after confirmation)
   long              id;
   int               dir;
   datetime          obTime;        // OB candle open time (dedup key with dir)
   datetime          confirmTime;   // closed bar that confirmed the OB
   double            top;
   double            bottom;
   double            mid;
   double            candleOpen;
   double            candleHigh;
   double            candleLow;
   double            candleClose;
   datetime          bosTime;
   double            bosLevel;
   datetime          swingTime;
   bool              isChoch;
   int               legBars;
   double            atr;
   double            netMove;
   double            strongestBodyPct;
   double            relStrength;
   long              overlapWithId; // 0 = none
   bool              isZOrder;      // zone built from the complete opposite-candle series
   int               seriesCount;   // ZOrder: candles in the series (obTime = newest)
   datetime          seriesStartTime; // ZOrder: oldest candle of the series
   //--- FVG confluence (may be linked one bar after confirmation)
   bool              hasFVG;
   bool              fvgLate;
   bool              fvgPending;
   datetime          fvgLeftTime;
   datetime          fvgRightTime;
   double            fvgTop;
   double            fvgBottom;
   //--- life-cycle
   ENUM_SMC_OB_STATE state;
   int               barsMonitored;
   int               retestCount;
   bool              touchingPrev;
   datetime          firstRetestTime;
   double            firstRetestPrice;
   datetime          mitigatedTime;
   datetime          invalidatedTime;
   datetime          endTime;       // right edge freeze time (0 = still extending)
   datetime          expiredTime;   // bar on which the OB expired (endTime may hold an earlier mitigation time)
   bool              liveInside;    // tick-level, informational only
  };

//+------------------------------------------------------------------+
//| Engine event (consumed by visualization and trading layers)       |
//+------------------------------------------------------------------+
struct SSMCEvent
  {
   ENUM_SMC_EVENT    type;
   long              obId;
   int               dir;
   datetime          time;
   double            price;
   datetime          time2;
   double            price2;
   bool              flag;          // BOS: isChoch
   bool              historical;    // produced during initial history scan
  };

//+------------------------------------------------------------------+
//| Diagnostics counters                                             |
//+------------------------------------------------------------------+
struct SSMCStats
  {
   int               barsProcessed;
   int               swingHighs;
   int               swingLows;
   int               bosBull;
   int               bosBear;
   int               choch;
   int               rejDisabled;
   int               rejData;
   int               rejBosOpposite;
   int               rejNoOpposite;
   int               rejWeakMove;
   int               rejWeakCandle;
   int               rejSmallBody;
   int               rejWeakRelative;
   int               rejLegViolation;
   int               rejZeroZone;
   int               rejFVGMissing;
   int               rejOverlap;
   int               duplicates;
   int               rejSeriesTooLong;
   int               obBull;
   int               obBear;
   int               fvgLinked;
   int               retests;
   int               mitigations;
   int               invalidations;
   int               expired;
   int               superseded;
  };

//+------------------------------------------------------------------+
string SMC_RejectText(const ENUM_SMC_REJECT r)
  {
   switch(r)
     {
      case SMC_REJ_NONE:                return "none";
      case SMC_REJ_DIRECTION_DISABLED:  return "direction disabled";
      case SMC_REJ_INSUFFICIENT_DATA:   return "insufficient data";
      case SMC_REJ_BOS_CANDLE_OPPOSITE: return "BOS candle is opposite colour (no displacement)";
      case SMC_REJ_NO_OPPOSITE_CANDLE:  return "no opposite candle within max OB->BOS distance";
      case SMC_REJ_WEAK_MOVE:           return "displacement net move below ATR threshold";
      case SMC_REJ_WEAK_CANDLE:         return "strongest displacement body below ATR threshold";
      case SMC_REJ_SMALL_BODY:          return "strongest displacement candle body % too small";
      case SMC_REJ_WEAK_RELATIVE:       return "displacement weak relative to prior candles";
      case SMC_REJ_LEG_VIOLATES_OB:     return "displacement leg traded beyond OB far edge";
      case SMC_REJ_ZERO_ZONE:           return "zero-height zone";
      case SMC_REJ_FVG_MISSING:         return "FVG required but not formed";
      case SMC_REJ_OVERLAP:             return "overlaps existing live OB";
      case SMC_REJ_DUPLICATE:           return "duplicate OB";
      case SMC_REJ_SERIES_TOO_LONG:     return "ZOrder series start not within lookback";
     }
   return "unknown";
  }

string SMC_StateText(const ENUM_SMC_OB_STATE s)
  {
   switch(s)
     {
      case SMC_OB_ACTIVE:      return "ACTIVE";
      case SMC_OB_RETESTED:    return "RETESTED";
      case SMC_OB_MITIGATED:   return "MITIGATED";
      case SMC_OB_INVALIDATED: return "INVALIDATED";
      case SMC_OB_EXPIRED:     return "EXPIRED";
      case SMC_OB_SUPERSEDED:  return "SUPERSEDED";
     }
   return "?";
  }

string SMC_DirText(const int dir) { return dir == SMC_DIR_BULL ? "Bull" : "Bear"; }

//--- "Live" = still relevant to price (monitored for retest/invalidation)
bool SMC_IsLiveState(const ENUM_SMC_OB_STATE s)
  {
   return s == SMC_OB_ACTIVE || s == SMC_OB_RETESTED || s == SMC_OB_MITIGATED;
  }

#endif // SMC_OB_TYPES_MQH
