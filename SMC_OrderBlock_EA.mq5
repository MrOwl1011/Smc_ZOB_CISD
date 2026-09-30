//+------------------------------------------------------------------+
//|                                            SMC_OrderBlock_EA.mq5 |
//|  Smart Money Concepts Order Block detection Expert Advisor.      |
//|                                                                  |
//|  Version 1.1: detection, visualization, state management,        |
//|  retest / mitigation tracking and an on-chart control panel.     |
//|  NO trades are placed.                                           |
//|                                                                  |
//|  Layers:                                                         |
//|   SMC_OB_Structure    swings + BOS            (Market Structure) |
//|   SMC_OB_Displacement displacement + OB candle (Displacement)    |
//|   SMC_OB_FVG          FVG confluence          (FVG)              |
//|   SMC_OB_Engine       OB store, overlap, life-cycle (OB/Retest)  |
//|   SMC_OB_Visual       chart objects           (Visualization)    |
//|   SMC_OB_Panel        control panel           (UI)               |
//|   SMC_OB_TradeHooks   placeholder, no orders  (Future Trading)   |
//|   SMC_OB_SelfTest     deterministic tests                        |
//+------------------------------------------------------------------+
#property copyright   "Zaid"
#property version     "1.50"
#property description "SMC Order Block detector: BOS + displacement + last opposite candle."
#property description "Non-repainting, closed-candle confirmation. Detection only - no trading."

#include "SMC_OB_Visual.mqh"
#include "SMC_OB_Panel.mqh"
#include "SMC_OB_TradeHooks.mqh"
#include "SMC_OB_SelfTest.mqh"
#include "SMC_OB_PanelTest.mqh"
#include "SMC_CISD_Visual.mqh"
#include "SMC_CISD_SelfTest.mqh"
#include "SMC_Connect_Visual.mqh"
#include "SMC_Connect_SelfTest.mqh"
#include "SMC_Config.mqh"

//--- Market structure
input group "=== Market Structure ==="
input int                        InpSwingLength        = 5;                     // Swing strength (bars each side)
input double                     InpSwingMinATR        = 0.5;                   // Min swing prominence (x ATR, 0 = off)
input ENUM_SMC_BOS_MODE          InpBOSMode            = SMC_BOS_CLOSE;         // BOS confirmation mode
input double                     InpBOSBufferATR       = 0.10;                  // BOS close buffer (x ATR, buffer mode)

//--- Displacement
input group "=== Displacement ==="
input int                        InpATRPeriod          = 14;                    // ATR period
input double                     InpDispATRMult        = 1.5;                   // Displacement ATR multiplier (net leg move)
input double                     InpDispCandleATRMult  = 0.8;                   // Min displacement strength (strongest body x ATR)
input double                     InpDispMinBodyPct     = 55.0;                  // Min candle body % of range
input double                     InpDispMinRelStrength = 1.5;                   // Min relative strength (body / avg body)
input int                        InpMaxOBToBOSBars     = 8;                     // Max distance OB -> BOS (bars)
input bool                       InpRejectLegViolation = false;                 // Reject if leg trades beyond OB far edge

//--- Order blocks
input group "=== Order Blocks ==="
input ENUM_SMC_TF_PAIR           InpTimeframePair      = SMC_TFP_H1_M5;         // Timeframes: HTF is the Order Block TF, CISD follows (panel default)
input bool                       InpEnableBull         = true;                  // Detect bullish OBs
input bool                       InpEnableBear         = true;                  // Detect bearish OBs
input int                        InpExtendBars         = 20;                    // OB extension (bars right of last bar)
input int                        InpMaxActivePerDir    = 10;                    // Max active OBs per direction
input int                        InpMaxAgeBars         = 0;                     // Expire OB after N bars (0 = never)
input ENUM_SMC_OVERLAP_MODE      InpOverlapMode        = SMC_OVERLAP_SKIP_NEW;  // Overlapping zones
input double                     InpOverlapPct         = 50.0;                  // Overlap threshold (% of smaller zone)

//--- FVG
input group "=== Fair Value Gap ==="
input ENUM_SMC_FVG_MODE          InpFVGMode            = SMC_FVG_CONFLUENCE;    // FVG confirmation
input double                     InpFVGMinATR          = 0.05;                  // FVG minimum size (x ATR)

//--- Retest / mitigation
input group "=== Retest / Mitigation ==="
input bool                       InpRetestEnabled      = true;                  // Retest detection
input ENUM_SMC_MITIGATION_MODE   InpMitigationMode     = SMC_MIT_MIDPOINT;      // Mitigation detection
input ENUM_SMC_INVALIDATION_MODE InpInvalidationMode   = SMC_INV_CLOSE_BEYOND;  // OB invalidation method

//--- CISD (independent module, own timeframe)
input group "=== CISD - Change in State of Delivery ==="
input bool                       InpEnableCISD         = true;                  // Enable CISD
input bool                       InpCISDSweep          = true;                  // Liquidity Sweep (panel default)
input bool                       InpCISDConfirm        = true;                  // Confirmation Close (panel default)
input bool                       InpCISDRetrace        = true;                  // Retracement / Entry (panel default)
input int                        InpCISDSwingLength    = 3;                     // Liquidity swing strength (bars each side)
input double                     InpCISDSwingMinATR    = 0.3;                   // Liquidity swing min prominence (x ATR)
input int                        InpCISDSwingMaxAge    = 150;                   // Swing stays liquidity for N bars (0 = always)
input ENUM_CISD_SWEEP_MODE       InpCISDSweepMode      = CISD_SWEEP_TRADE_THROUGH; // Sweep definition
input int                        InpCISDSweepValidity  = 10;                    // Sweep can feed a later series for N bars
input ENUM_CISD_LEVEL_MODE       InpCISDLevelMode      = CISD_LEVEL_SERIES_RANGE; // Confirmation level
input int                        InpCISDMaxSeries      = 12;                    // Max candles in the series
input int                        InpCISDMaxConfirmBars = 20;                    // Setup expires after N bars
input int                        InpCISDMaxRetraceBars = 50;                    // Retracement window (bars)
input int                        InpCISDScanDepth      = 1500;                  // CISD history scan depth (CISD bars)
input bool                       InpCISDShowSD         = true;                  // Show standard deviation levels
input string                     InpCISDSDLevels       = "1.0,1.5,2.0,2.5";     // Standard deviation levels
input bool                       InpCISDShowReversal   = false;                 // Show -2 / -2.5 SD reversal area
input int                        InpCISDMaxDrawn       = 30;                    // Max CISDs / sweeps drawn
input int                        InpCISDExtendBars     = 10;                    // CISD line extension (CISD bars)
input color                      InpCISDBullColor      = clrLimeGreen;          // Bullish CISD
input color                      InpCISDBearColor      = clrCrimson;            // Bearish CISD
input color                      InpCISDSeriesColor    = clrKhaki;              // CISD candle series
input color                      InpCISDSweepColor     = clrYellow;             // Liquidity sweep
input color                      InpCISDSDColor        = clrPlum;               // Standard deviation levels
input color                      InpCISDRetraceColor   = C'40,60,90';           // Retracement / entry area

//--- HTF PD Array (OB / ZOrder) -> LTF CISD workflow
input group "=== HTF OB -> LTF CISD ==="
input bool                       InpConnEnable         = true;                  // HTF OB -> CISD connection (panel default)
input ENUM_CONN_CISD_MODE        InpConnCISDMode       = CONN_CISD_SINGLE;      // CISD validation (panel default)
input int                        InpConnMaxCISDBars    = 100;                   // Bars to find a CISD after the retest (CISD TF)
input int                        InpConnWarmupBars     = 200;                   // CISD warm-up bars before the retest (liquidity)
input ENUM_CONN_RETEST_MODE      InpConnRetestMode     = CONN_RETEST_SINGLE;    // Retest mode (panel default)
input int                        InpConnMaxRetests     = 10;                    // Max CISD sequences per Order Block
input bool                       InpConnMitigationStops = false;                // Mitigation stops CISD search (panel default)
input bool                       InpTrendFilter        = true;                  // Trend filter: only CISDs with the OB-timeframe trend
input int                        InpTrendBars          = 20;                    // Trend filter: OB candles measured
input double                     InpTrendATRMult       = 1.5;                   // Trend filter: displacement needed, in ATR
input color                      InpConnColor          = clrHotPink;            // Retest / HTF-LTF link color

//--- trade execution: entry at a confirmed setup, stop on the far side of the OB, 1:1 target
input group "=== Trading ==="
input bool                       InpEnableTrading      = false;                 // Execute trades (panel default)
input double                     InpLots               = 0.01;                  // Lot size (panel default)
input bool                       InpOppositeBlockExit  = false;                  // Opposite block exit: a retested opposite OB closes the trade (panel default)
input double                     InpTargetRR           = 1.0;                   // Take profit, as a multiple of risk (1.0 = 1:1) (panel default)
input bool                       InpRideTrend          = false;                 // Ride the trend: hold to the nearest opposite OB, ignore the R:R target (panel default)
input bool                       InpEntryAlert         = true;                  // Entry alert with entry / SL / TP, works with trading off (panel default)
input bool                       InpBreakEven          = false;                 // Break even: move the stop to entry once in profit (panel default)
input int                        InpBreakEvenPoints    = 100;                   // Break even trigger: profit in points (panel default)
input long                       InpMagic              = 20260928;              // Magic number
input int                        InpSlippage           = 20;                    // Max slippage (points)

//--- configuration profiles
input group "=== Configuration ==="
input string                     InpConfigProfile      = "default";             // Configuration profile name
input bool                       InpConfigCommon       = false;                 // Store profiles in the common folder

//--- History
input group "=== History ==="
input int                        InpScanDepth          = 3000;                  // Historical scan depth (bars)

//--- Control panel
input group "=== Control Panel ==="
input bool                       InpShowControlPanel   = true;                  // Show control panel
input bool                       InpStartEasyMode      = false;                 // Start in Easy mode (OB zones only)
input bool                       InpStartCollapsed     = false;                 // Start collapsed
input int                        InpPanelX             = 10;                    // Panel X offset (px)
input int                        InpPanelY             = 30;                    // Panel Y offset (px)
input int                        InpPanelMaxHeight     = 0;                     // Panel max height in px (0 = fit chart)

//--- Visualization
input group "=== Visualization ==="
input bool                       InpShowInactive       = true;                  // Show mitigated/invalidated zones
input bool                       InpShowBOS            = true;                  // Show BOS / CHoCH markers
input bool                       InpShowSwings         = false;                 // Show swing points
input bool                       InpShowFVG            = true;                  // Show linked FVG zones
input bool                       InpShowRetest         = true;                  // Show first-retest markers
input bool                       InpShowRetestStart    = true;                  // Show where retest detection starts
input bool                       InpShowLabels         = true;                  // Show OB labels
input bool                       InpFillZones          = true;                  // Fill OB rectangles
input int                        InpMaxBOSDrawn        = 100;                   // Max BOS / swing markers kept
input int                        InpLabelFontSize      = 8;                     // Label font size
input color                      InpBullColor          = C'32,96,64';           // Bullish OB
input color                      InpBearColor          = C'112,40,40';          // Bearish OB
input color                      InpMitigatedColor     = C'90,90,40';           // Mitigated OB
input color                      InpInactiveColor      = C'70,70,70';           // Invalidated / expired OB
input color                      InpBullFVGColor       = clrMediumSeaGreen;     // Bullish FVG
input color                      InpBearFVGColor       = clrIndianRed;          // Bearish FVG
input color                      InpBOSBullColor       = clrDodgerBlue;         // Bullish BOS
input color                      InpBOSBearColor       = clrOrange;             // Bearish BOS
input color                      InpRetestColor        = clrGold;               // Retest marker
input color                      InpSwingColor         = clrSilver;             // Swing marker
input bool                       InpDeleteOnExit       = true;                  // Delete chart objects on removal

//--- Diagnostics
input group "=== Diagnostics ==="
input ENUM_SMC_LOG_LEVEL         InpLogLevel           = SMC_LOG_EVENTS;        // Debug logging
input bool                       InpAlerts             = false;                 // Alert on live OB created / first retest
input bool                       InpRunSelfTest        = false;                 // Run self tests on init
input int                        InpSelfTestBars       = 2000;                  // Real-data bars for self test

#define SMC_PANEL_PREFIX "SMCPNL_"

//--- engine instances
//--- the only Order Block type: the zone is the complete opposite-candle series
CSMCDetector    g_detector;
CSMCVisualizer  g_visual;

//--- CISD module (own timeframe, own state)
CSMCCISDEngine     g_cisd;
CSMCCISDVisualizer g_cisdVisual;
ENUM_TIMEFRAMES    g_cisdTF          = PERIOD_CURRENT;
bool               g_cisdScanned     = false;
datetime           g_cisdLastBarOpen = 0;
int                g_cisdFailLogged  = 0;

//--- Order Block timeframe and HTF OB -> LTF CISD workflow
ENUM_TIMEFRAMES    g_obTF            = PERIOD_CURRENT;
CSMCConnection     g_conn;
CSMCConnVisualizer g_connVisual;
bool               g_connScanned     = false;
int                g_connFailLogged  = 0;
CSMCPanel       g_panel;
CSMCTradeEngine g_trade;

bool     g_scanned        = false;
//--- candle buffers reused by the per-bar paths (CopyRates keeps their capacity)
MqlRates g_obRates[];
MqlRates g_cisdRates[];
MqlRates g_connM1[];
MqlRates g_connRates[];
//--- last detector state the connection was synchronised with (see ProcessConnection)
datetime g_syncTime  = 0;
int      g_syncStd   = -1;
bool     g_draw           = true;
bool     g_usePanel       = false;
bool     g_persistPanel   = false;
datetime g_lastBarOpen    = 0;
datetime g_lastClosedBar  = 0;
int      g_scanFailLogged = 0;

string PanelKey(void) { return SMC_PANEL_PREFIX + IntegerToString(ChartID()) + "_"; }

//+------------------------------------------------------------------+
//| Panel defaults come from the inputs                              |
//+------------------------------------------------------------------+
void PanelDefaults(SSMCPanelState &p)
  {
   ZeroMemory(p);
   p.collapsed        = InpStartCollapsed;
   p.easyMode         = InpStartEasyMode;
   p.showBull         = true;
   p.showBear         = true;
   p.showInactive     = InpShowInactive;
   p.showBOS          = InpShowBOS;
   p.showFVG          = InpShowFVG;
   p.showRetest       = InpShowRetest;
   p.showRetestStart  = InpShowRetestStart;
   p.showLabels       = InpShowLabels;
   p.showSwings       = InpShowSwings;
   p.fillZones        = InpFillZones;
   p.cisdSweep        = InpCISDSweep;
   p.cisdConfirm      = InpCISDConfirm;
   p.cisdRetrace      = InpCISDRetrace;
   p.tfPair           = (int)InpTimeframePair;
   p.obTF             = SMC_PairOBIndex(p.tfPair);
   p.cisdTF           = SMC_PairCISDIndex(p.tfPair);
   p.connect          = InpConnEnable;
   p.cisdMode         = (int)InpConnCISDMode;
   p.retestMode       = (int)InpConnRetestMode;
   p.mitStopsCISD     = InpConnMitigationStops;
   p.trendFilter      = InpTrendFilter;
   p.tradeEnabled     = InpEnableTrading;
   p.lots             = InpLots;
   p.oppExit          = InpOppositeBlockExit;
   p.targetRR         = InpTargetRR;
   p.rideTrend        = InpRideTrend;
   p.entryAlert       = InpEntryAlert;
   p.breakEven        = InpBreakEven;
   p.bePoints         = InpBreakEvenPoints;
   p.swingLength      = InpSwingLength;
   p.dispATRMult      = InpDispATRMult;
   p.maxOBToBOSBars   = InpMaxOBToBOSBars;
   p.maxActivePerDir  = InpMaxActivePerDir;
   p.fvgMode          = (int)InpFVGMode;
   p.mitigationMode   = (int)InpMitigationMode;
   p.invalidationMode = (int)InpInvalidationMode;
   p.overlapMode      = (int)InpOverlapMode;
  }

//+------------------------------------------------------------------+
//| Detection settings = inputs, overridden by the panel state       |
//+------------------------------------------------------------------+
void BuildSettings(SSMCSettings &s)
  {
   SSMCPanelState p;
   g_panel.GetState(p);

   ZeroMemory(s);
   s.swingLength        = p.swingLength;
   s.swingMinATR        = InpSwingMinATR;
   s.bosMode            = InpBOSMode;
   s.bosBufferATR       = InpBOSBufferATR;
   s.atrPeriod          = InpATRPeriod;
   s.dispATRMult        = p.dispATRMult;
   s.dispCandleATRMult  = InpDispCandleATRMult;
   s.dispMinBodyPct     = InpDispMinBodyPct;
   s.dispMinRelStrength = InpDispMinRelStrength;
   s.maxOBToBOSBars     = p.maxOBToBOSBars;
   s.rejectLegViolation = InpRejectLegViolation;
   s.zoneSource         = SMC_SOURCE_CANDLE_SERIES;   // the only zone model in this EA
   s.zoneMode           = SMC_ZONE_OPEN_LAST_EXTREME;   // the only zone model in this EA
   s.overlapMode        = (ENUM_SMC_OVERLAP_MODE)p.overlapMode;
   s.overlapPct         = InpOverlapPct;
   s.maxActivePerDir    = p.maxActivePerDir;
   s.maxAgeBars         = InpMaxAgeBars;
   s.maxStored          = MathMax(500, p.maxActivePerDir * 20);
   s.enableBull         = InpEnableBull;
   s.enableBear         = InpEnableBear;
   s.fvgMode            = (ENUM_SMC_FVG_MODE)p.fvgMode;
   s.fvgMinATR          = InpFVGMinATR;
   s.retestEnabled      = InpRetestEnabled;
   s.mitigationMode     = (ENUM_SMC_MITIGATION_MODE)p.mitigationMode;
   s.invalidationMode   = (ENUM_SMC_INVALIDATION_MODE)p.invalidationMode;
   s.logLevel           = InpLogLevel;
  }

//+------------------------------------------------------------------+
//| Display settings = inputs, overridden by the panel state.        |
//| Easy mode shows the order block zones only.                      |
//+------------------------------------------------------------------+
void BuildVisualSettings(SSMCVisualSettings &v)
  {
   SSMCPanelState p;
   g_panel.GetState(p);

   v.prefix         = "SMCOB_";
   v.showBull       = p.showBull;
   v.showBear       = p.showBear;
   v.showInactive   = p.showInactive;
   v.showBOS        = p.showBOS;
   v.showSwings     = p.showSwings;
   v.showFVG        = p.showFVG;
   v.showRetest     = p.showRetest;
   v.showRetestStart = p.showRetestStart;
   v.showLabels     = p.showLabels;
   v.fillZones      = p.fillZones;
   if(p.easyMode)
     {
      v.showInactive = false;
      v.showBOS      = false;
      v.showSwings   = false;
      v.showFVG      = false;
      v.showRetest   = false;
      v.showRetestStart = false;
      v.showLabels   = false;
      v.fillZones    = true;
     }
   v.bullLabel      = "Bull OB";
   v.bearLabel      = "Bear OB";
   v.liveStyle      = STYLE_SOLID;
   v.zoneWidth      = 1;
   v.periodSeconds  = PeriodSeconds(g_obTF);
   v.extendBars     = InpExtendBars;
   v.maxBOSDrawn    = InpMaxBOSDrawn;
   v.labelFontSize  = InpLabelFontSize;
   v.bullColor      = InpBullColor;
   v.bearColor      = InpBearColor;
   v.mitigatedColor = InpMitigatedColor;
   v.inactiveColor  = InpInactiveColor;
   v.bullFVGColor   = InpBullFVGColor;
   v.bearFVGColor   = InpBearFVGColor;
   v.bosBullColor   = InpBOSBullColor;
   v.bosBearColor   = InpBOSBearColor;
   v.retestColor    = InpRetestColor;
   v.swingColor     = InpSwingColor;
  }

//+------------------------------------------------------------------+
//| CISD settings = inputs + the three panel components              |
//+------------------------------------------------------------------+
void BuildCISDSettings(SCISDSettings &s)
  {
   SSMCPanelState p;
   g_panel.GetState(p);
   ZeroMemory(s);
   s.timeframe         = g_cisdTF;
   s.useSweep          = p.cisdSweep;
   s.useConfirm        = p.cisdConfirm;
   s.useRetrace        = p.cisdRetrace;
   s.swingLength       = InpCISDSwingLength;
   s.swingMinATR       = InpCISDSwingMinATR;
   s.atrPeriod         = InpATRPeriod;
   s.swingMaxAge       = InpCISDSwingMaxAge;
   s.sweepMode         = InpCISDSweepMode;
   s.sweepValidityBars = InpCISDSweepValidity;
   s.levelMode         = InpCISDLevelMode;
   s.maxSeriesCandles  = InpCISDMaxSeries;
   s.maxConfirmBars    = InpCISDMaxConfirmBars;
   s.maxRetraceBars    = InpCISDMaxRetraceBars;
   s.maxStored         = 500;
   s.logLevel          = InpLogLevel;
  }

void BuildCISDVisualSettings(SCISDVisualSettings &v)
  {
   SSMCPanelState p;
   g_panel.GetState(p);
   ZeroMemory(v);
   v.prefix           = "SMCCISD_";
   v.showSweep        = p.cisdSweep;
   v.showConfirm      = p.cisdConfirm;
   v.showRetrace      = p.cisdRetrace;
   v.showSD           = InpCISDShowSD;
   v.showReversalZone = InpCISDShowReversal;
   SMC_ParseSDLevels(InpCISDSDLevels, v);
   v.maxDrawn         = InpCISDMaxDrawn;
   v.extendBars       = InpCISDExtendBars;
   v.fontSize         = InpLabelFontSize;
   v.bullColor        = InpCISDBullColor;
   v.bearColor        = InpCISDBearColor;
   v.seriesColor      = InpCISDSeriesColor;
   v.sweepColor       = InpCISDSweepColor;
   v.sdColor          = InpCISDSDColor;
   v.retraceColor     = InpCISDRetraceColor;
   v.inactiveColor    = InpInactiveColor;
  }

bool ValidateCISDInputs(void)
  {
   if(!InpEnableCISD)
      return true;
   string err = "";
   if(InpCISDSwingLength < 1 || InpCISDSwingLength > 50)         err += "CISD swing strength must be 1..50. ";
   if(InpCISDSwingMinATR < 0.0)                                  err += "CISD swing prominence must be >= 0. ";
   if(InpCISDSwingMaxAge < 0)                                    err += "CISD swing age must be >= 0. ";
   if(InpCISDSweepValidity < 0 || InpCISDSweepValidity > 500)    err += "CISD sweep validity must be 0..500. ";
   if(InpCISDMaxSeries < 1 || InpCISDMaxSeries > 50)             err += "CISD max series must be 1..50. ";
   if(InpCISDMaxConfirmBars < 1 || InpCISDMaxConfirmBars > 1000) err += "CISD setup expiry must be 1..1000. ";
   if(InpCISDMaxRetraceBars < 1 || InpCISDMaxRetraceBars > 5000) err += "CISD retracement window must be 1..5000. ";
   if(InpCISDScanDepth < 200)                                    err += "CISD scan depth must be >= 200. ";
   if(InpCISDMaxDrawn < 0 || InpCISDMaxDrawn > 500)              err += "CISD max drawn must be 0..500. ";
   if(InpCISDExtendBars < 0)                                     err += "CISD extension must be >= 0. ";
   if(InpConnMaxCISDBars < 1 || InpConnMaxCISDBars > 10000)      err += "HTF OB -> CISD window must be 1..10000 bars. ";
   if(InpConnWarmupBars < 50 || InpConnWarmupBars > 5000)        err += "HTF OB -> CISD warm-up must be 50..5000 bars. ";
   if(InpConnMaxRetests < 1 || InpConnMaxRetests > 100)          err += "Max CISD sequences per OB must be 1..100. ";
   SCISDVisualSettings tmp;
   ZeroMemory(tmp);
   if(InpCISDShowSD && SMC_ParseSDLevels(InpCISDSDLevels, tmp) == 0)
      err += "SD levels must be a comma-separated list, e.g. 1.0,1.5,2.0,2.5. ";
   if(err != "")
     {
      Print("[SMC-CISD] Invalid inputs: ", err);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
bool ValidateInputs(void)
  {
   string err = "";
   if(InpSwingLength < 1 || InpSwingLength > 50)          err += "Swing strength must be 1..50. ";
   if(InpSwingMinATR < 0.0)                               err += "Swing prominence must be >= 0. ";
   if(InpBOSBufferATR < 0.0)                              err += "BOS buffer must be >= 0. ";
   if(InpATRPeriod < 1 || InpATRPeriod > 500)             err += "ATR period must be 1..500. ";
   if(InpDispATRMult < 0.0 || InpDispCandleATRMult < 0.0) err += "Displacement multipliers must be >= 0. ";
   if(InpDispMinBodyPct < 0.0 || InpDispMinBodyPct > 100.0) err += "Body % must be 0..100. ";
   if(InpDispMinRelStrength < 0.0)                        err += "Relative strength must be >= 0. ";
   if(InpMaxOBToBOSBars < 1 || InpMaxOBToBOSBars > 100)   err += "Max OB->BOS distance must be 1..100. ";
   if(InpExtendBars < 0)                                  err += "OB extension must be >= 0. ";
   if(InpMaxActivePerDir < 1 || InpMaxActivePerDir > 200) err += "Max active OBs must be 1..200. ";
   if(InpMaxAgeBars < 0)                                  err += "OB age must be >= 0. ";
   if(InpOverlapPct < 0.0 || InpOverlapPct > 100.0)       err += "Overlap % must be 0..100. ";
   if(InpFVGMinATR < 0.0)                                 err += "FVG min size must be >= 0. ";
   if(InpScanDepth < 100)                                 err += "Scan depth must be >= 100. ";
   if(InpMaxBOSDrawn < 0)                                 err += "Max BOS markers must be >= 0. ";
   if(!InpEnableBull && !InpEnableBear)                   err += "Enable at least one OB direction. ";
   if(err != "")
     {
      Print("[SMC-OB] Invalid inputs: ", err);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
int OnInit(void)
  {
   if(!ValidateInputs() || !ValidateCISDInputs())
      return INIT_PARAMETERS_INCORRECT;

   bool tester = (bool)MQLInfoInteger(MQL_TESTER);
   g_draw = !(tester && !MQLInfoInteger(MQL_VISUAL_MODE));
   g_usePanel = g_draw && InpShowControlPanel;
   g_persistPanel = g_usePanel && !tester;

   //--- panel state first: detection and display settings derive from it
   SSMCPanelState defaults;
   PanelDefaults(defaults);
   g_panel.Init(0, SMC_PANEL_PREFIX, InpPanelX, InpPanelY, defaults);
   g_panel.SetMaxHeight(InpPanelMaxHeight);
   g_panel.SetProfile(InpConfigProfile);
   if(g_persistPanel && g_panel.Load(PanelKey()))
      Print("[SMC-OB] Restored control panel settings for this chart");
   SyncTimeframesFromPanel();          // OB / CISD timeframes come from the panel state

   SSMCSettings s;
   BuildSettings(s);
   if(!g_detector.Init(s))
     {
      Print("[SMC-OB] Detector initialisation failed");
      return INIT_PARAMETERS_INCORRECT;
     }

   SSMCVisualSettings v;
   BuildVisualSettings(v);
   g_visual.Init(v, 0);
   g_visual.Cleanup();
   g_trade.Init(InpEnableTrading, InpLots, InpMagic, InpSlippage,
                InpTargetRR, InpBreakEven, InpBreakEvenPoints, InpRideTrend, InpEntryAlert);
   ApplyTradeSettings();               // a restored panel state overrides the inputs

   if(InpRunSelfTest)
     {
      CSMCSelfTest test;
      test.Run(s, InpSelfTestBars);
      SMC_RunPanelTests(g_draw);
     }

   if(g_usePanel)
      g_panel.Build();

   g_scanned = false;
   g_lastBarOpen = 0;
   g_scanFailLogged = 0;
   EventSetTimer(2);
   TryInitialScan();
   if(InpEnableCISD && !InitCISD())
      return INIT_PARAMETERS_INCORRECT;
   InitConnection();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   DeinitCISD();
   DeinitConnection();
   if(InpLogLevel >= SMC_LOG_EVENTS)
      Print("[SMC-OB] Final statistics:\n", g_detector.StatsText());
   if(InpDeleteOnExit)
     {
      g_visual.Cleanup();
     }
   g_panel.Destroy();

   //--- keep panel settings across timeframe/symbol changes; forget them when the EA
   //--- is removed, the chart closed, or the inputs are edited (inputs win)
   if(g_persistPanel && (reason == REASON_REMOVE || reason == REASON_CHARTCLOSE || reason == REASON_PARAMETERS))
      CSMCPanel::DeleteSaved(PanelKey());
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick(void)
  {
   g_trade.ManageOpenPosition();       // break-even stop, if armed
   g_trade.RideOpenPosition(g_detector);   // opposite-block target, if riding
   if(InpEnableCISD && !ConnActive())
      ProcessCISD();                   // standalone CISD (connection OFF), independent of the OB pipeline
   if(!g_scanned && !TryInitialScan())
      return;
   ProcessNewBars();
   if(ConnActive())
      ProcessConnection();             // after the OB detectors are up to date

   if(g_draw)
     {
      //--- the tick-level "price inside zone" flag is still maintained, but the chart is not
      //--- redrawn on ticks: zones change only when a closed candle changes them
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      g_detector.OnTickPrice(bid);
     }
  }

//+------------------------------------------------------------------+
void OnTimer(void)
  {
   if(InpEnableCISD && !ConnActive())
      ProcessCISD();
   if(!g_scanned && !TryInitialScan())
      return;
   ProcessNewBars();
   if(ConnActive())
      ProcessConnection();
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(!g_usePanel)
      return;
   if(id == CHARTEVENT_CHART_CHANGE)
     {
      if(g_panel.NeedsRelayout())      // chart resized: refit the scrolling viewport
        {
         g_panel.Build();
         UpdatePanelStatus();
        }
      return;
     }
   if(id == CHARTEVENT_OBJECT_ENDEDIT)
     {
      if(g_panel.OnEndEdit(sparam))    // configuration profile name typed in the panel
        {
         g_panel.SetStatus(StringFormat("Profile: %s", g_panel.Profile()));
         ChartRedraw();
        }
      return;
     }
   if(id != CHARTEVENT_OBJECT_CLICK || StringFind(sparam, SMC_PANEL_PREFIX) != 0)
      return;
   ApplyPanelAction(g_panel.OnClick(sparam));
  }

//+------------------------------------------------------------------+
//| Apply a panel change: re-layout, redraw objects, or rescan.      |
//+------------------------------------------------------------------+
void ApplyPanelAction(const ENUM_SMC_PANEL_ACTION action)
  {
   if(action == SMC_PANEL_NONE)
      return;
   if(g_persistPanel)
      g_panel.Save(PanelKey());

   if(action == SMC_PANEL_REDRAW)
     {
      SSMCVisualSettings v;
      BuildVisualSettings(v);
      g_visual.SetSettings(v);
      g_visual.RedrawAll(g_detector, g_lastClosedBar);
     }
   else if(action == SMC_PANEL_RESCAN || action == SMC_PANEL_TIMEFRAME)
     {
      //--- OB detection / OB timeframe changed ("Reset to input values" may also restore TFs and CISD switches)
      SyncTimeframesFromPanel();
      Rescan();
      if(InpEnableCISD)
        {
         SCISDSettings cur;
         g_cisd.GetSettings(cur);
         SSMCPanelState p;
         g_panel.GetState(p);
         if(cur.timeframe != g_cisdTF || cur.useSweep != p.cisdSweep || cur.useConfirm != p.cisdConfirm ||
            cur.useRetrace != p.cisdRetrace)
            RebuildCISD();
        }
      RebuildConnection();             // monitors depend on the rescanned OBs
     }
   else if(action == SMC_PANEL_CISD)
     {
      SyncTimeframesFromPanel();
      RebuildCISD();                   // OB / ZOrder engines are not touched
      RebuildConnection();
     }
   else if(action == SMC_PANEL_TRADE)
      { /* nothing to rebuild: applied below */ }
   else if(action == SMC_PANEL_SAVECFG)
      SaveConfigProfile();
   else if(action == SMC_PANEL_LOADCFG)
      LoadConfigProfile();

   ApplyTradeSettings();               // also after "Reset to input values" / a loaded profile
   if(g_usePanel)
      g_panel.Build();
   UpdatePanelStatus();
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Rebuild the detector with the current settings and rescan.       |
//| Deterministic: same settings + same history = same order blocks. |
//+------------------------------------------------------------------+
void Rescan(void)
  {
   SSMCSettings s;
   BuildSettings(s);
   if(!g_detector.Init(s))
     {
      Print("[SMC-OB] Rescan aborted: invalid settings");
      return;
     }
   SSMCVisualSettings v;
   BuildVisualSettings(v);
   g_visual.SetSettings(v);
   g_visual.Cleanup();
   g_scanned = false;
   g_scanFailLogged = 0;
   TryInitialScan();
  }

//+------------------------------------------------------------------+
//| Scan history once data is available.                             |
//+------------------------------------------------------------------+
bool TryInitialScan(void)
  {
   if(g_scanned)
      return true;

   int need = g_detector.RequiredLookback() + 10;
   int bars = Bars(_Symbol, g_obTF);
   int count = MathMin(InpScanDepth + g_detector.RequiredLookback(), bars - 1);
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int got = (count >= need) ? CopyRates(_Symbol, g_obTF, 1, count, rates) : 0;
   if(got < need)
     {
      if(g_scanFailLogged++ == 0)
         PrintFormat("[SMC-OB] Waiting for history: %d bars available, %d required (error %d)", bars, need, GetLastError());
      return false;
     }

   ulong t0 = GetMicrosecondCount();
   g_detector.Reset();
   g_detector.SetHistoricalMode(true);
   g_detector.ProcessWindow(rates, got);
   g_detector.SetHistoricalMode(false);

   g_lastClosedBar = rates[0].time;
   g_lastBarOpen   = 0;                // force a new-bar check on the next tick
   g_scanned       = true;
   g_connScanned   = false;            // HTF OB -> CISD monitors follow the (re)scanned OBs

   HandleEvents();
   PrintFormat("[SMC-OB] History scan: %d bars %s %s, %d OBs stored in %.1f ms",
               got, _Symbol, EnumToString(g_obTF), g_detector.OBCount(),
               (GetMicrosecondCount() - t0) / 1000.0);
   if(InpLogLevel >= SMC_LOG_EVENTS)
      Print("[SMC-OB] ", g_detector.StatsText());
   return true;
  }

//+------------------------------------------------------------------+
//| Process every bar that has closed since the last processed bar.  |
//+------------------------------------------------------------------+
void ProcessNewBars(void)
  {
   datetime open0 = iTime(_Symbol, g_obTF, 0);
   if(open0 == 0 || open0 == g_lastBarOpen)
      return;

   datetime last = g_detector.LastProcessedTime();
   int shift = iBarShift(_Symbol, g_obTF, last, false);
   if(shift < 0)
      return;
   int newBars = shift - 1;             // closed bars newer than the last processed one
   if(newBars > InpScanDepth)
     {
      Print("[SMC-OB] Large data gap detected - rescanning history");
      g_visual.Cleanup();
      g_scanned = false;
      TryInitialScan();
      return;
     }
   if(newBars <= 0)
     {
      g_lastBarOpen = open0;
      return;
     }

   int count = newBars + g_detector.RequiredLookback() + 2;
   ArraySetAsSeries(g_obRates, true);
   int got = CopyRates(_Symbol, g_obTF, 1, count, g_obRates);
   if(got <= 0)
      return;                          // retry on next tick

   g_detector.ProcessWindow(g_obRates, got);
   g_conn.ProcessOBWindow(g_obRates, got);     // trend filter context
   g_lastBarOpen   = open0;
   g_lastClosedBar = g_obRates[0].time;

   HandleEvents();
   g_trade.OnNewBar(g_detector);
  }

//+------------------------------------------------------------------+
void HandleEvents(void)
  {
   if(g_draw)
     {
      g_visual.HandleEvents(g_detector, g_lastClosedBar);
     }

   SSMCEvent e;
   int n = g_detector.EventCount();
   for(int k = 0; k < n; k++)
     {
      if(!g_detector.GetEvent(k, e))
         continue;
      g_trade.OnDetectorEvent(e, g_detector);
      if(InpAlerts && !e.historical)
        {
         if(e.type == SMC_EVT_OB_CREATED)
            Alert(StringFormat("%s %s: %s Order Block #%I64d confirmed", _Symbol,
                               EnumToString(g_obTF), SMC_DirText(e.dir), e.obId));
         else if(e.type == SMC_EVT_OB_RETEST && e.flag)
            Alert(StringFormat("%s %s: first retest of %s OB #%I64d", _Symbol,
                               EnumToString(g_obTF), SMC_DirText(e.dir), e.obId));
        }
     }
   g_detector.ClearEvents();


   if(g_draw)
     {
      UpdatePanelStatus();
      ChartRedraw();
     }
  }

//+------------------------------------------------------------------+
string TradeStatusText(void)
  {
   if(!g_trade.IsEnabled())
      return "";
   return StringFormat("     TRADING %.2f lots %s%s (%d sent%s)", g_trade.Lots(),
                       g_trade.RideTrend() ? "ride" : StringFormat("1:%.1f", g_trade.TargetRR()),
                       g_trade.BreakEven() ? StringFormat(" BE %d", g_trade.BreakEvenPoints()) : "",
                       g_trade.Sent(),
                       g_trade.Closed() > 0 ? StringFormat(", %d closed", g_trade.Closed()) : "");
  }

//+------------------------------------------------------------------+
//| Push the panel's trade switch / lot size to the trade engine.    |
//+------------------------------------------------------------------+
void ApplyTradeSettings(void)
  {
   SSMCPanelState p;
   g_panel.GetState(p);
   g_trade.SetEnabled(p.tradeEnabled);
   g_trade.SetLots(p.lots);
   g_trade.SetOppositeExit(p.oppExit);
   g_trade.SetTargetRR(p.targetRR);
   g_trade.SetRideTrend(p.rideTrend);
   g_trade.SetAlerts(p.entryAlert);
   g_trade.SetOBTimeframe(g_obTF);
   g_trade.SetBreakEven(p.breakEven, p.bePoints);
  }

//+------------------------------------------------------------------+
void UpdatePanelStatus(void)
  {
   if(!g_usePanel)
      return;
   int nb = g_detector.LiveCount(SMC_DIR_BULL);
   int ns = g_detector.LiveCount(SMC_DIR_BEAR);
   g_panel.SetStatus(StringFormat("Live OBs:  %d bull  |  %d bear%s", nb, ns, TradeStatusText()));
  }

//+------------------------------------------------------------------+
//|                        CISD MODULE WIRING                        |
//|  Every CISD computation uses g_cisdTF candles only.              |
//+------------------------------------------------------------------+
bool InitCISD(void)
  {
   SCISDSettings cs;
   BuildCISDSettings(cs);
   if(!g_cisd.Init(cs))
     {
      Print("[SMC-CISD] Initialisation failed");
      return false;
     }
   SCISDVisualSettings cv;
   BuildCISDVisualSettings(cv);
   g_cisdVisual.Init(cv, 0);
   g_cisdVisual.Cleanup();

   if(InpRunSelfTest)
     {
      CSMCCISDSelfTest test;
      test.RunAll(cs, InpSelfTestBars);
      TestCISDPanelWiring();
     }

   g_cisdScanned = false;
   g_cisdLastBarOpen = 0;
   g_cisdFailLogged = 0;
   PrintFormat("[SMC-CISD] Enabled on %s candles (chart %s): sweep %s, confirmation %s, retracement %s",
               SMC_TFText(g_cisdTF), SMC_TFText((ENUM_TIMEFRAMES)_Period),
               cs.useSweep ? "ON" : "OFF", cs.useConfirm ? "ON" : "OFF", cs.useRetrace ? "ON" : "OFF");
   if(ConnActive())
      Print("[SMC-CISD] Standalone CISD paused: HTF OB -> CISD connection is ON (CISD runs per retested OB)");
   else
      TryCISDScan();
   return true;
  }

//+------------------------------------------------------------------+
void RebuildCISD(void)
  {
   if(!InpEnableCISD)
      return;
   SCISDSettings cs;
   BuildCISDSettings(cs);
   if(!g_cisd.Init(cs))
      return;
   SCISDVisualSettings cv;
   BuildCISDVisualSettings(cv);
   g_cisdVisual.SetSettings(cv);
   g_cisdVisual.Cleanup();
   g_cisdScanned = false;
   g_cisdFailLogged = 0;
   PrintFormat("[SMC-CISD] Components changed: sweep %s, confirmation %s, retracement %s - rescanning %s",
               cs.useSweep ? "ON" : "OFF", cs.useConfirm ? "ON" : "OFF", cs.useRetrace ? "ON" : "OFF", SMC_TFText(g_cisdTF));
   if(!ConnActive())
      TryCISDScan();                   // with the connection ON, CISD only runs inside OB monitors
  }

//+------------------------------------------------------------------+
bool TryCISDScan(void)
  {
   if(g_cisdScanned)
      return true;
   int need = g_cisd.RequiredLookback() + 10;
   int bars = Bars(_Symbol, g_cisdTF);
   int count = MathMin(InpCISDScanDepth + g_cisd.RequiredLookback(), bars - 1);
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   ResetLastError();
   int got = (count >= need) ? CopyRates(_Symbol, g_cisdTF, 1, count, rates) : 0;
   if(got < need)
     {
      if(g_cisdFailLogged++ == 0)
         PrintFormat("[SMC-CISD] Waiting for %s history: %d bars available, %d required (error %d)",
                     SMC_TFText(g_cisdTF), bars, need, GetLastError());
      return false;
     }

   g_cisd.Reset();
   g_cisd.SetHistoricalMode(true);
   g_cisd.ProcessWindow(rates, got);
   g_cisd.SetHistoricalMode(false);
   g_cisdLastBarOpen = 0;
   g_cisdScanned = true;
   HandleCISDEvents();
   PrintFormat("[SMC-CISD] History scan: %d %s bars (chart %s), %d CISD records",
               got, SMC_TFText(g_cisdTF), SMC_TFText((ENUM_TIMEFRAMES)_Period), g_cisd.Count());
   if(InpLogLevel >= SMC_LOG_EVENTS)
      Print("[SMC-CISD] ", g_cisd.StatsText());
   return true;
  }

//+------------------------------------------------------------------+
//| New closed bars on the CISD timeframe (not the chart timeframe). |
//+------------------------------------------------------------------+
void ProcessCISD(void)
  {
   if(!g_cisdScanned)
     {
      TryCISDScan();
      return;
     }
   datetime open0 = iTime(_Symbol, g_cisdTF, 0);
   if(open0 == 0 || open0 == g_cisdLastBarOpen)
      return;
   int shift = iBarShift(_Symbol, g_cisdTF, g_cisd.LastProcessedTime(), false);
   if(shift < 0)
      return;
   int newBars = shift - 1;
   if(newBars > InpCISDScanDepth)
     {
      Print("[SMC-CISD] Large data gap detected - rescanning CISD history");
      g_cisdVisual.Cleanup();
      g_cisdScanned = false;
      TryCISDScan();
      return;
     }
   if(newBars <= 0)
     {
      g_cisdLastBarOpen = open0;
      return;
     }
   ArraySetAsSeries(g_cisdRates, true);
   int got = CopyRates(_Symbol, g_cisdTF, 1, newBars + g_cisd.RequiredLookback() + 2, g_cisdRates);
   if(got <= 0)
      return;                          // retry on next tick
   g_cisd.ProcessWindow(g_cisdRates, got);
   g_cisdLastBarOpen = open0;
   HandleCISDEvents();
  }

//+------------------------------------------------------------------+
void HandleCISDEvents(void)
  {
   if(g_draw)
      g_cisdVisual.RedrawAll(g_cisd);
   SCISDEvent e;
   int n = g_cisd.EventCount();
   for(int k = 0; k < n; k++)
     {
      if(!g_cisd.GetEvent(k, e))
         continue;
      g_trade.OnCISDEvent((int)e.type, e.id, e.dir, e.time, e.price, e.historical);
      if(InpAlerts && !e.historical)
        {
         string side = (e.dir == SMC_DIR_BULL) ? "Bullish" : "Bearish";
         if(e.type == CISD_EVT_CONFIRMED)
            Alert(StringFormat("%s CISD %s: %s CISD #%I64d confirmed", _Symbol, SMC_TFText(g_cisdTF), side, e.id));
         else if(e.type == CISD_EVT_RETRACED)
            Alert(StringFormat("%s CISD %s: %s CISD #%I64d retracement / entry", _Symbol, SMC_TFText(g_cisdTF), side, e.id));
        }
     }
   g_cisd.ClearEvents();
  }

//+------------------------------------------------------------------+
void DeinitCISD(void)
  {
   if(!InpEnableCISD)
      return;
   if(InpLogLevel >= SMC_LOG_EVENTS)
      Print("[SMC-CISD] Final statistics: ", g_cisd.StatsText());
   if(InpRunSelfTest && g_cisdScanned)
     {
      CSMCCISDSelfTest test;
      test.VerifyLive(g_cisd);
      if(g_draw)
         VerifyObjectIsolation();
     }
   if(InpDeleteOnExit)
      g_cisdVisual.Cleanup();
  }

//+------------------------------------------------------------------+
//| Self test: the three panel switches drive the CISD settings only |
//+------------------------------------------------------------------+
void TestCISDPanelWiring(void)
  {
   int pass = 0, fail = 0;
   SSMCPanelState saved;
   g_panel.GetState(saved);
   string ids[3] = {"cisd_sw", "cisd_cf", "cisd_rt"};
   for(int k = 0; k < 3; k++)
     {
      SCISDSettings c0, c1;
      SCISDVisualSettings v0, v1;
      SSMCSettings o0, o1;
      BuildCISDSettings(c0);
      BuildCISDVisualSettings(v0);
      BuildSettings(o0);
      ENUM_SMC_PANEL_ACTION a = g_panel.OnClick(SMC_PANEL_PREFIX + ids[k]);
      BuildCISDSettings(c1);
      BuildCISDVisualSettings(v1);
      BuildSettings(o1);
      bool sw = (c1.useSweep != c0.useSweep), cf = (c1.useConfirm != c0.useConfirm), rt = (c1.useRetrace != c0.useRetrace);
      bool onlyThis = (k == 0 && sw && !cf && !rt) || (k == 1 && !sw && cf && !rt) || (k == 2 && !sw && !cf && rt);
      bool visual = (v1.showSweep == c1.useSweep && v1.showConfirm == c1.useConfirm && v1.showRetrace == c1.useRetrace);
      bool obSame = (o0.swingLength == o1.swingLength && o0.dispATRMult == o1.dispATRMult && o0.fvgMode == o1.fvgMode &&
                     o0.mitigationMode == o1.mitigationMode && o0.zoneSource == o1.zoneSource);
      if(a == SMC_PANEL_CISD && onlyThis && visual && obSame)
         pass++;
      else
        {
         fail++;
         PrintFormat("[SMC-CISD][TEST] FAIL  panel wiring: %s (action %d, only=%d, visual=%d, obSame=%d)",
                     ids[k], (int)a, onlyThis, visual, obSame);
        }
     }
   g_panel.SetState(saved);
   PrintFormat("[SMC-CISD][TEST] Panel wiring %s: %d checks passed, %d failed", fail == 0 ? "ALL PASSED" : "FAILURES", pass, fail);
  }

//+------------------------------------------------------------------+
int CountObjectsWithPrefix(const string prefix)
  {
   int n = 0;
   for(int k = ObjectsTotal(0) - 1; k >= 0; k--)
      if(StringFind(ObjectName(0, k), prefix) == 0)
         n++;
   return n;
  }

void VerifyObjectIsolation(void)
  {
   string pf[4] = {"SMCOB_", "SMCZOB_", "SMCCISD_", SMC_PANEL_PREFIX};
   int overlaps = 0;
   for(int a = 0; a < 4; a++)
      for(int b = 0; b < 4; b++)
         if(a != b && StringFind(pf[a], pf[b]) == 0)
            overlaps++;
   int ob = CountObjectsWithPrefix(pf[0]), z = CountObjectsWithPrefix(pf[1]);
   int cd = CountObjectsWithPrefix(pf[2]), pn = CountObjectsWithPrefix(pf[3]);
   g_cisdVisual.Cleanup();
   int ob2 = CountObjectsWithPrefix(pf[0]), z2 = CountObjectsWithPrefix(pf[1]);
   int cd2 = CountObjectsWithPrefix(pf[2]), pn2 = CountObjectsWithPrefix(pf[3]);
   bool ok = (overlaps == 0 && cd > 0 && cd2 == 0 && ob2 == ob && z2 == z && pn2 == pn);
   PrintFormat("[SMC-CISD][TEST] Object isolation %s: OB %d, ZOrder %d, CISD %d, panel %d -> after CISD cleanup OB %d, ZOrder %d, CISD %d, panel %d",
               ok ? "PASSED" : "FAILED", ob, z, cd, pn, ob2, z2, cd2, pn2);
  }

//+------------------------------------------------------------------+
//|              HTF OB -> LTF CISD CONNECTION WIRING                |
//|  OB detectors run on g_obTF, CISD on g_cisdTF, retests on M1.    |
//+------------------------------------------------------------------+
void SyncTimeframesFromPanel(void)
  {
   SSMCPanelState p;
   g_panel.GetState(p);
   g_obTF   = SMC_CISDTimeframe((ENUM_CISD_TF)p.obTF);
   g_cisdTF = SMC_CISDTimeframe((ENUM_CISD_TF)p.cisdTF);
   g_panel.SetCISDAvailable(InpEnableCISD, SMC_TFText(g_cisdTF));
  }

bool ConnActive(void)
  {
   if(!InpEnableCISD)
      return false;
   SSMCPanelState p;
   g_panel.GetState(p);
   return p.connect;
  }

void BuildConnSettings(SConnSettings &s, const datetime windowStart)
  {
   SSMCPanelState p;
   g_panel.GetState(p);
   ZeroMemory(s);
   s.obTF           = g_obTF;
   s.cisdTF         = g_cisdTF;
   //--- a single Order Block type, always the source
   s.useStandard    = true;
   s.useZOrder      = false;
   s.multiCISD      = (p.cisdMode == (int)CONN_CISD_MULTI);
   s.multiRetest    = (p.retestMode == (int)CONN_RETEST_MULTI);
   s.maxRetests     = InpConnMaxRetests;
   s.stopOnMitigation = p.mitStopsCISD;
   s.trendFilter      = p.trendFilter;
   s.trendBars        = InpTrendBars;
   s.trendATRMult     = InpTrendATRMult;
   s.trendATRPeriod   = InpATRPeriod;
   s.mitigationMode   = p.mitigationMode;     // same level as the OB detector (Touch / 50% / Full)
   SCISDSettings cs;
   BuildCISDSettings(cs);              // same CISD rules and panel switches as standalone CISD
   s.cisd           = cs;
   s.warmupBars     = InpConnWarmupBars;
   s.maxMonitorBars = InpConnMaxCISDBars;
   s.windowStart    = windowStart;
   s.logLevel       = InpLogLevel;
  }

void BuildConnVisualSettings(SConnVisualSettings &v)
  {
   SSMCPanelState p;
   g_panel.GetState(p);
   ZeroMemory(v);
   v.prefix        = "SMCCONN_";
   v.showSweep     = p.cisdSweep;
   v.showConfirm   = p.cisdConfirm;
   v.showRetrace   = p.cisdRetrace;
   v.maxDrawn      = InpCISDMaxDrawn;
   v.extendBars    = InpCISDExtendBars;
   v.fontSize      = InpLabelFontSize;
   v.linkColor     = InpConnColor;
   v.bullColor     = InpCISDBullColor;
   v.bearColor     = InpCISDBearColor;
   v.seriesColor   = InpCISDSeriesColor;
   v.sweepColor    = InpCISDSweepColor;
   v.retraceColor  = InpCISDRetraceColor;
   v.inactiveColor = InpInactiveColor;
  }

//--- latest time up to which OB knowledge is complete
datetime ConnHorizon(void)
  {
   int ps = PeriodSeconds(g_obTF);
   datetime last = g_detector.LastProcessedTime();
   datetime open0 = iTime(_Symbol, g_obTF, 0);
   if(last > 0 && open0 > 0 && (datetime)(last + ps) >= open0)
      return TimeCurrent();            // detectors processed the latest closed OB bar
   return (datetime)(last + ps);       // OB data lagging: wait
  }

//+------------------------------------------------------------------+
void InitConnection(void)
  {
   g_syncTime = 0;
   g_syncStd  = -1;
   SConnVisualSettings v;
   BuildConnVisualSettings(v);
   g_connVisual.Init(v, 0);
   g_connVisual.Cleanup();
   g_connScanned = false;
   g_connFailLogged = 0;
   if(InpRunSelfTest && InpEnableCISD)
     {
      TestConnPanelWiring();
      TestConfigProfiles();
     }
   if(ConnActive())
     {
      SConnSettings info;
      BuildConnSettings(info, 0);
      PrintFormat("[SMC-CONN] HTF OB -> LTF CISD ON: OB %s, CISD %s, chart %s | source standard %s / ZOrder %s | CISD validation %s",
                  SMC_TFText(g_obTF), SMC_TFText(g_cisdTF), SMC_TFText((ENUM_TIMEFRAMES)_Period),
                  info.useStandard ? "ON" : "OFF", info.useZOrder ? "ON" : "OFF", info.multiCISD ? "MULTI" : "SINGLE");
      TryConnScan();
     }
  }

void RebuildConnection(void)
  {
   g_conn.Reset();
   g_syncTime = 0;                     // the rebuilt engine must be synchronised again
   g_syncStd  = -1;
   SConnVisualSettings v;
   BuildConnVisualSettings(v);
   g_connVisual.SetSettings(v);
   g_connVisual.Cleanup();
   g_connScanned = false;
   g_connFailLogged = 0;
   if(ConnActive())
     {
      PrintFormat("[SMC-CONN] Rebuilding HTF OB -> LTF CISD: OB %s, CISD %s", SMC_TFText(g_obTF), SMC_TFText(g_cisdTF));
      TryConnScan();
     }
   ChartRedraw();
  }

//+------------------------------------------------------------------+
bool TryConnScan(void)
  {
   if(g_connScanned)
      return true;
   if(!g_scanned)
      return false;                    // OB detectors first
   int cisdBars = Bars(_Symbol, g_cisdTF);
   int m1Bars = Bars(_Symbol, PERIOD_M1);
   if(cisdBars < InpConnWarmupBars + 50 || m1Bars < 100)
     {
      if(g_connFailLogged++ == 0)
         PrintFormat("[SMC-CONN] Waiting for history: %s %d bars, M1 %d bars", SMC_TFText(g_cisdTF), cisdBars, m1Bars);
      return false;
     }
   int depth = MathMin(InpCISDScanDepth, cisdBars - InpConnWarmupBars - 20);
   datetime ws = iTime(_Symbol, g_cisdTF, depth);
   int m1Shift = iBarShift(_Symbol, PERIOD_M1, ws, false);
   if(ws == 0 || m1Shift < 1)
      return false;
   if(m1Shift > 150000)
     {
      m1Shift = 150000;
      ws = iTime(_Symbol, PERIOD_M1, m1Shift);
     }

   SConnSettings cs;
   BuildConnSettings(cs, ws);
   if(!g_conn.Init(cs, GetPointer(g_detector), NULL))
     {
      Print("[SMC-CONN] Initialisation failed");
      return false;
     }
   SConnSettings eff;
   g_conn.GetSettings(eff);
   MqlRates m1[], cr[];
   ArraySetAsSeries(m1, true);
   ArraySetAsSeries(cr, true);
   int n1 = CopyRates(_Symbol, PERIOD_M1, 1, m1Shift, m1);
   int cShift = iBarShift(_Symbol, g_cisdTF, ws, false);
   int nc = (cShift > 0) ? CopyRates(_Symbol, g_cisdTF, 1, cShift + eff.warmupBars + 5, cr) : 0;
   if(n1 <= 0 || nc <= eff.warmupBars)
     {
      if(g_connFailLogged++ == 0)
         PrintFormat("[SMC-CONN] Waiting for M1 / %s data (M1 %d, CISD %d, error %d)", SMC_TFText(g_cisdTF), n1, nc, GetLastError());
      return false;
     }

   ulong t0 = GetMicrosecondCount();
   datetime hz = ConnHorizon();
   g_conn.SetHistoricalMode(true);
   g_conn.SyncOBs();
   //--- OB-timeframe candles for the trend filter (same window the detectors scanned)
   MqlRates obh[];
   ArraySetAsSeries(obh, true);
   int nob = CopyRates(_Symbol, g_obTF, 1, InpTrendBars + InpATRPeriod + 5 + InpScanDepth, obh);
   if(nob > 0)
      g_conn.ProcessOBWindow(obh, nob);
   g_conn.ProcessM1Window(m1, n1, hz);
   g_conn.ProcessCISDWindow(cr, nc, hz);
   g_conn.SetHistoricalMode(false);
   g_connScanned = true;
   HandleConnEvents();
   PrintFormat("[SMC-CONN] History scan: OB %s -> CISD %s, window from %s (%d M1 + %d %s bars), %d OB monitors in %.1f ms",
               SMC_TFText(g_obTF), SMC_TFText(g_cisdTF), TimeToString(ws), n1, nc, SMC_TFText(g_cisdTF),
               g_conn.Count(), (GetMicrosecondCount() - t0) / 1000.0);
   if(InpLogLevel >= SMC_LOG_EVENTS)
      Print("[SMC-CONN] ", g_conn.StatsText());
   return true;
  }

//+------------------------------------------------------------------+
//| Live: new OBs, M1 retests, then CISD-timeframe candles.          |
//+------------------------------------------------------------------+
void ProcessConnection(void)
  {
   if(!g_connScanned)
     {
      TryConnScan();
      return;
     }
   //--- SyncOBs() reads confirmed order blocks and their end times, and both change only when
   //--- the detectors process a new bar (OnTickPrice() touches nothing it reads), so the scan
   //--- is skipped while the detectors stand still. Same input -> same monitors.
   datetime dt = g_detector.LastProcessedTime();
   int cStd = g_detector.OBCount();
   if(dt != g_syncTime || cStd != g_syncStd)
     {
      g_conn.SyncOBs();
      g_syncTime = dt;
      g_syncStd  = cStd;
     }
   datetime hz = ConnHorizon();
   bool changed = false;

   bool m1ok = true;
   datetime lastM1 = iTime(_Symbol, PERIOD_M1, 1);
   if(lastM1 > g_conn.LastM1Time())
     {
      int shift = iBarShift(_Symbol, PERIOD_M1, g_conn.LastM1Time(), false);
      if(shift < 0 || shift > 150000)
        {
         Print("[SMC-CONN] Large data gap detected - rescanning HTF OB -> CISD");
         RebuildConnection();
         return;
        }
      ArraySetAsSeries(g_connM1, true);
      int got = CopyRates(_Symbol, PERIOD_M1, 1, MathMax(shift, 1), g_connM1);
      if(got <= 0)
         m1ok = false;                 // retry next tick; CISD must not run ahead of retests
      else if(g_conn.ProcessM1Window(g_connM1, got, hz) > 0)
         changed = true;
     }

   datetime lastC = iTime(_Symbol, g_cisdTF, 1);
   if(m1ok && lastC > g_conn.LastCISDTime())
     {
      int shift = iBarShift(_Symbol, g_cisdTF, g_conn.LastCISDTime(), false);
      if(shift >= 0)
        {
         ArraySetAsSeries(g_connRates, true);
         int got = CopyRates(_Symbol, g_cisdTF, 1, MathMax(shift, 1), g_connRates);
         if(got > 0 && g_conn.ProcessCISDWindow(g_connRates, got, hz) > 0)
            changed = true;
        }
     }
   if(changed || g_conn.EventCount() > 0)
      HandleConnEvents();
  }

//+------------------------------------------------------------------+
//| A confirmed HTF OB + LTF CISD setup: hand the block's edges to    |
//| the trade engine (stop = far side of that block, target 1:1).     |
//+------------------------------------------------------------------+
void TradeConfirmedSetup(const SConnEvent &e)
  {
   if(!g_trade.IsEnabled() && !g_trade.Alerts())
      return;                          // neither trading nor alerting: nothing to do
   SOrderBlock ob;
   int idx = g_detector.FindById(e.obId);
   bool found = (idx >= 0 && g_detector.GetOB(idx, ob));
   if(!found)
     {
      PrintFormat("[SMC-TRADE] confirmed setup skipped: Order Block #%I64d not found", e.obId);
      return;
     }
   g_trade.OnSignal(e.dir, ob.top, ob.bottom, e.obId, e.cisdId);
  }

//+------------------------------------------------------------------+
void HandleConnEvents(void)
  {
   if(g_draw)
      g_connVisual.RedrawAll(g_conn);
   SConnEvent e;
   int n = g_conn.EventCount();
   for(int k = 0; k < n; k++)
     {
      if(!g_conn.GetEvent(k, e))
         continue;
      g_trade.OnConnectionEvent((int)e.type, e.setupId, e.obId, e.kind, e.dir, e.cisdId, e.time, e.price, e.historical);
      if(e.type == CONN_EVT_CONFIRMED && !e.historical)
         TradeConfirmedSetup(e);
      if(!InpAlerts || e.historical)
         continue;
      string side = (e.dir == SMC_DIR_BULL) ? "Bullish" : "Bearish";
      if(e.type == CONN_EVT_RETEST)
         Alert(StringFormat("%s: %s %s %s #%I64d retested -> %s CISD monitoring", _Symbol, SMC_TFText(g_obTF), side,
                            SMC_ConnKindText(e.kind), e.obId, SMC_TFText(g_cisdTF)));
      else if(e.type == CONN_EVT_CONFIRMED)
         Alert(StringFormat("%s: %s %s %s #%I64d R%d + %s CISD #%I64d CONFIRMED", _Symbol, SMC_TFText(g_obTF), side,
                            SMC_ConnKindText(e.kind), e.obId, e.retestNo, SMC_TFText(g_cisdTF), e.cisdId));
      else if(e.type == CONN_EVT_RETRACED)
         Alert(StringFormat("%s: %s setup (OB #%I64d, CISD #%I64d) retracement / entry", _Symbol, side, e.obId, e.cisdId));
     }
   g_conn.ClearEvents();
  }

//+------------------------------------------------------------------+
void DeinitConnection(void)
  {
   if(g_connScanned)
     {
      if(InpLogLevel >= SMC_LOG_EVENTS)
         Print("[SMC-CONN] Final statistics: ", g_conn.StatsText());
      if(InpRunSelfTest)
        {
         CSMCConnSelfTest test;
         test.Verify(g_conn, GetPointer(g_detector), NULL);
         if(g_draw)
           {
            VerifyRetestStartMarks();
            VerifyConnObjectIsolation();
           }
        }
     }
   if(InpDeleteOnExit)
      g_connVisual.Cleanup();
   g_conn.Reset();
  }

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Retest-start marks: one per drawn zone, at the close of the OB's  |
//| confirmation candle, which is also where the HTF OB -> CISD      |
//| connection starts looking for retests.                           |
//+------------------------------------------------------------------+
void VerifyRetestStartMarks(void)
  {
   int ps = PeriodSeconds(g_obTF);
   int zones = 0, missing = 0, badTime = 0, stray = 0, connChecked = 0, connBad = 0;
   SSMCPanelState p;
   g_panel.GetState(p);
   for(int layer = 0; layer < 1; layer++)
     {
      string pf = "SMCOB_";
      int kind  = CONN_KIND_STANDARD;
      int n = g_detector.OBCount();
      SOrderBlock o;
      for(int k = 0; k < n; k++)
        {
         if(!g_detector.GetOB(k, o))
            continue;
         string rs = pf + "RS_" + IntegerToString(o.id);
         bool zoneDrawn = ObjectFind(0, pf + "OB_" + IntegerToString(o.id)) >= 0;
         bool markDrawn = ObjectFind(0, rs) >= 0;
         if(!zoneDrawn)
           {
            if(markDrawn) stray++;                     // a mark without its zone
            continue;
           }
         zones++;
         if(p.showRetestStart && !p.easyMode)
           {
            if(!markDrawn) { missing++; continue; }
            datetime expect = (datetime)(o.confirmTime + ps);
            if((datetime)ObjectGetInteger(0, rs, OBJPROP_TIME, 0) != expect ||
               (datetime)ObjectGetInteger(0, rs, OBJPROP_TIME, 1) != expect)
               badTime++;
            //--- the mark must sit exactly where the connection's retest detection starts
            SConnSetup su;
            for(int j = 0; j < g_conn.Count(); j++)
               if(g_conn.Get(j, su) && su.kind == kind && su.obId == o.id)
                 {
                  connChecked++;
                  if(su.availTime != expect)
                     connBad++;
                 }
           }
         else if(markDrawn)
            stray++;                                    // hidden by the panel but still drawn
        }
     }
   bool ok = (zones > 0 && missing == 0 && badTime == 0 && stray == 0 && connBad == 0);
   PrintFormat("[SMC-OB][TEST] Retest start marks %s: %d zones, missing %d, wrong time %d, stray %d | "
               "matched to CISD retest detection %d (wrong %d)",
               ok ? "PASSED" : "FAILED", zones, missing, badTime, stray, connChecked, connBad);
  }

void VerifyConnObjectIsolation(void)
  {
   string pf[5] = {"SMCOB_", "SMCZOB_", "SMCCISD_", SMC_PANEL_PREFIX, "SMCCONN_"};
   int overlaps = 0;
   for(int a = 0; a < 5; a++)
      for(int b = 0; b < 5; b++)
         if(a != b && StringFind(pf[a], pf[b]) == 0)
            overlaps++;
   int before[5], after[5];
   for(int k = 0; k < 5; k++)
      before[k] = CountObjectsWithPrefix(pf[k]);
   g_connVisual.Cleanup();
   for(int k = 0; k < 5; k++)
      after[k] = CountObjectsWithPrefix(pf[k]);
   bool ok = (overlaps == 0 && before[4] > 0 && after[4] == 0 && after[0] == before[0] && after[1] == before[1] &&
              after[2] == before[2] && after[3] == before[3]);
   PrintFormat("[SMC-CONN][TEST] Object isolation %s: OB %d, ZOrder %d, CISD %d, panel %d, HTF/LTF %d -> after cleanup %d/%d/%d/%d/%d",
               ok ? "PASSED" : "FAILED", before[0], before[1], before[2], before[3], before[4],
               after[0], after[1], after[2], after[3], after[4]);
  }

//+------------------------------------------------------------------+
//| Self test: timeframe selectors and connection switch wiring      |
//+------------------------------------------------------------------+
void TestConnPanelWiring(void)
  {
   int pass = 0, fail = 0;
   SSMCPanelState saved, p;
   g_panel.GetState(saved);
   ENUM_TIMEFRAMES cisd0 = g_cisdTF;

   ENUM_SMC_PANEL_ACTION a = g_panel.OnClick(SMC_PANEL_PREFIX + "c_tfp");
   g_panel.GetState(p);
   SyncTimeframesFromPanel();
   SSMCVisualSettings v;
   BuildVisualSettings(v);
   //--- the pair moves both timeframes at once and can never be mismatched
   bool pairOk = (a == SMC_PANEL_TIMEFRAME &&
                  p.obTF == SMC_PairOBIndex(p.tfPair) && p.cisdTF == SMC_PairCISDIndex(p.tfPair) &&
                  g_obTF == SMC_CISDTimeframe((ENUM_CISD_TF)p.obTF) &&
                  g_cisdTF == SMC_CISDTimeframe((ENUM_CISD_TF)p.cisdTF) &&
                  PeriodSeconds(g_obTF) > PeriodSeconds(g_cisdTF) &&
                  v.periodSeconds == PeriodSeconds(g_obTF));
   //--- and it cycles through all three, back to where it started
   for(int k = 0; k < 2; k++)
     {
      g_panel.OnClick(SMC_PANEL_PREFIX + "c_tfp");
      g_panel.GetState(p);
      pairOk = pairOk && p.obTF == SMC_PairOBIndex(p.tfPair) && p.cisdTF == SMC_PairCISDIndex(p.tfPair);
     }
   SyncTimeframesFromPanel();
   if(pairOk)
      pass++;
   else { fail++; Print("[SMC-CONN][TEST] FAIL  panel wiring: timeframe pair selector"); }

   g_panel.GetState(p);
   SyncTimeframesFromPanel();
   SCISDSettings cs;
   BuildCISDSettings(cs);
   SConnSettings s;
   BuildConnSettings(s, 0);
   if(cs.timeframe == SMC_CISDTimeframe((ENUM_CISD_TF)p.cisdTF) && s.cisdTF == cs.timeframe &&
      s.obTF == g_obTF && s.cisd.timeframe == cs.timeframe)
      pass++;
   else { fail++; Print("[SMC-CONN][TEST] FAIL  panel wiring: CISD timeframe follows the pair"); }

   bool before = ConnActive();
   a = g_panel.OnClick(SMC_PANEL_PREFIX + "conn");
   if(a == SMC_PANEL_CISD && ConnActive() != before)
      pass++;
   else { fail++; Print("[SMC-CONN][TEST] FAIL  panel wiring: connection switch"); }
   g_panel.OnClick(SMC_PANEL_PREFIX + "conn");         // back ON for the checks below


   //--- CISD validation switches between Single and Multi
   BuildConnSettings(s, 0);
   bool mode0 = s.multiCISD;
   a = g_panel.OnClick(SMC_PANEL_PREFIX + "c_cmode");
   BuildConnSettings(s, 0);
   bool modeOk = (a == SMC_PANEL_CISD && s.multiCISD != mode0 && s.multiRetest == (p.retestMode == 1));
   g_panel.OnClick(SMC_PANEL_PREFIX + "c_cmode");
   BuildConnSettings(s, 0);
   modeOk = modeOk && (s.multiCISD == mode0);
   if(modeOk)
      pass++;
   else { fail++; Print("[SMC-CONN][TEST] FAIL  panel wiring: CISD validation mode"); }

   //--- "Trend filter" switch toggles only its engine flag
   BuildConnSettings(s, 0);
   bool tf0 = s.trendFilter, tfMulti = s.multiCISD;
   a = g_panel.OnClick(SMC_PANEL_PREFIX + "trendf");
   BuildConnSettings(s, 0);
   bool tfOk = (a == SMC_PANEL_CISD && s.trendFilter != tf0 && s.multiCISD == tfMulti &&
                s.trendBars == InpTrendBars && MathAbs(s.trendATRMult - InpTrendATRMult) < 1e-9);
   g_panel.OnClick(SMC_PANEL_PREFIX + "trendf");
   BuildConnSettings(s, 0);
   tfOk = tfOk && (s.trendFilter == tf0);
   if(tfOk)
      pass++;
   else { fail++; Print("[SMC-CONN][TEST] FAIL  panel wiring: trend filter switch"); }

   //--- trade execution switch and lot stepper reach the trade engine, and nothing else
   BuildConnSettings(s, 0);
   bool trFilter0 = s.trendFilter;
   bool trEnabled0 = g_trade.IsEnabled();
   double trLots0 = g_trade.Lots();
   a = g_panel.OnClick(SMC_PANEL_PREFIX + "trade");
   ApplyTradeSettings();
   BuildConnSettings(s, 0);
   bool trOk = (a == SMC_PANEL_TRADE && g_trade.IsEnabled() != trEnabled0 && s.trendFilter == trFilter0);
   a = g_panel.OnClick(SMC_PANEL_PREFIX + "lots_p");
   ApplyTradeSettings();
   trOk = trOk && (a == SMC_PANEL_TRADE && MathAbs(g_trade.Lots() - (trLots0 + 0.01)) < 1e-9);
   a = g_panel.OnClick(SMC_PANEL_PREFIX + "lots_m");
   ApplyTradeSettings();
   trOk = trOk && MathAbs(g_trade.Lots() - trLots0) < 1e-9;
   //--- the minimum is 0.01: stepping down from there changes nothing
   for(int k = 0; k < 200; k++)
      g_panel.OnClick(SMC_PANEL_PREFIX + "lots_m");
   ApplyTradeSettings();
   trOk = trOk && MathAbs(g_trade.Lots() - 0.01) < 1e-9 &&
          g_panel.OnClick(SMC_PANEL_PREFIX + "lots_m") == SMC_PANEL_NONE;
   //--- the opposite block exit is an independent switch
   bool opp0 = g_trade.OppositeExit();
   double lotsNow = g_trade.Lots();
   bool enNow = g_trade.IsEnabled();
   a = g_panel.OnClick(SMC_PANEL_PREFIX + "oppx");
   ApplyTradeSettings();
   trOk = trOk && (a == SMC_PANEL_TRADE && g_trade.OppositeExit() != opp0 &&
                   g_trade.IsEnabled() == enNow && MathAbs(g_trade.Lots() - lotsNow) < 1e-9);
   g_panel.OnClick(SMC_PANEL_PREFIX + "oppx");
   ApplyTradeSettings();
   trOk = trOk && (g_trade.OppositeExit() == opp0);

   //--- reward:risk and break-even reach the engine, independently of each other
   double rr0 = g_trade.TargetRR();
   bool be0 = g_trade.BreakEven();
   int bept0 = g_trade.BreakEvenPoints();
   a = g_panel.OnClick(SMC_PANEL_PREFIX + "rr_p");
   ApplyTradeSettings();
   trOk = trOk && (a == SMC_PANEL_TRADE && MathAbs(g_trade.TargetRR() - (rr0 + 0.1)) < 1e-9 &&
                   g_trade.BreakEven() == be0);
   g_panel.OnClick(SMC_PANEL_PREFIX + "rr_m");
   ApplyTradeSettings();
   trOk = trOk && MathAbs(g_trade.TargetRR() - rr0) < 1e-9;
   a = g_panel.OnClick(SMC_PANEL_PREFIX + "be");
   ApplyTradeSettings();
   trOk = trOk && (a == SMC_PANEL_TRADE && g_trade.BreakEven() != be0 &&
                   MathAbs(g_trade.TargetRR() - rr0) < 1e-9);
   g_panel.OnClick(SMC_PANEL_PREFIX + "be");
   a = g_panel.OnClick(SMC_PANEL_PREFIX + "bept_p");
   ApplyTradeSettings();
   trOk = trOk && (a == SMC_PANEL_TRADE && g_trade.BreakEvenPoints() == bept0 + 10);
   g_panel.OnClick(SMC_PANEL_PREFIX + "bept_m");
   ApplyTradeSettings();
   trOk = trOk && g_trade.BreakEvenPoints() == bept0 && g_trade.BreakEven() == be0;

   //--- ride the trend is its own switch and does not disturb the others
   bool ride0 = g_trade.RideTrend();
   double rrNow = g_trade.TargetRR();
   a = g_panel.OnClick(SMC_PANEL_PREFIX + "ride");
   ApplyTradeSettings();
   trOk = trOk && (a == SMC_PANEL_TRADE && g_trade.RideTrend() != ride0 &&
                   MathAbs(g_trade.TargetRR() - rrNow) < 1e-9);
   g_panel.OnClick(SMC_PANEL_PREFIX + "ride");
   ApplyTradeSettings();
   trOk = trOk && (g_trade.RideTrend() == ride0);

   //--- the entry alert is independent of execution
   bool al0 = g_trade.Alerts();
   bool en1 = g_trade.IsEnabled();
   a = g_panel.OnClick(SMC_PANEL_PREFIX + "alert");
   ApplyTradeSettings();
   trOk = trOk && (a == SMC_PANEL_TRADE && g_trade.Alerts() != al0 && g_trade.IsEnabled() == en1);
   g_panel.OnClick(SMC_PANEL_PREFIX + "alert");
   ApplyTradeSettings();
   trOk = trOk && (g_trade.Alerts() == al0);

   g_panel.OnClick(SMC_PANEL_PREFIX + "trade");        // back to the starting state
   g_panel.SetState(saved);
   ApplyTradeSettings();
   trOk = trOk && (g_trade.IsEnabled() == trEnabled0) && MathAbs(g_trade.Lots() - trLots0) < 1e-9 &&
          (g_trade.OppositeExit() == saved.oppExit);
   if(trOk)
      pass++;
   else { fail++; Print("[SMC-CONN][TEST] FAIL  panel wiring: trade execution switch / lot size"); }

   //--- "Mitigation stops CISD" switch toggles only its engine flag
   BuildConnSettings(s, 0);
   bool mit0 = s.stopOnMitigation, multi0 = s.multiCISD, retestMode0 = s.multiRetest;
   a = g_panel.OnClick(SMC_PANEL_PREFIX + "mitstop");
   BuildConnSettings(s, 0);
   bool mitOk = (a == SMC_PANEL_CISD && s.stopOnMitigation != mit0 && s.multiCISD == multi0 && s.multiRetest == retestMode0);
   g_panel.OnClick(SMC_PANEL_PREFIX + "mitstop");
   BuildConnSettings(s, 0);
   mitOk = mitOk && (s.stopOnMitigation == mit0);
   if(mitOk)
      pass++;
   else { fail++; Print("[SMC-CONN][TEST] FAIL  panel wiring: mitigation stops CISD switch"); }

   //--- retest mode switches independently of the CISD mode
   BuildConnSettings(s, 0);
   bool retest0 = s.multiRetest, cisdMode0 = s.multiCISD;
   a = g_panel.OnClick(SMC_PANEL_PREFIX + "c_rmode");
   BuildConnSettings(s, 0);
   bool retestOk = (a == SMC_PANEL_CISD && s.multiRetest != retest0 && s.multiCISD == cisdMode0 &&
                    s.maxRetests == InpConnMaxRetests);
   g_panel.OnClick(SMC_PANEL_PREFIX + "c_rmode");
   BuildConnSettings(s, 0);
   retestOk = retestOk && (s.multiRetest == retest0);
   if(retestOk)
      pass++;
   else { fail++; Print("[SMC-CONN][TEST] FAIL  panel wiring: retest mode"); }

   a = g_panel.OnClick(SMC_PANEL_PREFIX + "cisd_cf");
   g_panel.GetState(p);
   BuildConnSettings(s, 0);
   SConnVisualSettings cv;
   BuildConnVisualSettings(cv);
   if(a == SMC_PANEL_CISD && s.cisd.useConfirm == p.cisdConfirm && cv.showConfirm == p.cisdConfirm &&
      s.cisd.activationTime == 0 && s.cisd.dirFilter == 0)
      pass++;
   else { fail++; Print("[SMC-CONN][TEST] FAIL  panel wiring: CISD switches inside the connection"); }

   g_panel.SetState(saved);
   SyncTimeframesFromPanel();
   //--- the wiring test must leave the panel exactly as it found it
   g_panel.GetState(p);
   if(p.cisdMode == saved.cisdMode && p.connect == saved.connect &&
      p.tfPair == saved.tfPair && p.obTF == saved.obTF && p.cisdTF == saved.cisdTF &&
      p.cisdSweep == saved.cisdSweep &&
      p.cisdConfirm == saved.cisdConfirm && p.cisdRetrace == saved.cisdRetrace)
      pass++;
   else { fail++; Print("[SMC-CONN][TEST] FAIL  panel wiring: panel state not restored after the test"); }
   PrintFormat("[SMC-CONN][TEST] Panel wiring %s: %d checks passed, %d failed", fail == 0 ? "ALL PASSED" : "FAILURES", pass, fail);
  }

//+------------------------------------------------------------------+
//|                     CONFIGURATION PROFILES                       |
//|  Runtime settings are saved / loaded from the panel. EA inputs    |
//|  are stored for reference only - MQL5 inputs are read-only at     |
//|  runtime, so a difference is reported instead of applied.        |
//+------------------------------------------------------------------+
string BuildInputSnapshot(void)
  {
   string s = "";
   s += "input.SwingMinATR=" + DoubleToString(InpSwingMinATR, 2) + "\r\n";
   s += "input.BOSMode=" + IntegerToString((int)InpBOSMode) + "\r\n";
   s += "input.BOSBufferATR=" + DoubleToString(InpBOSBufferATR, 2) + "\r\n";
   s += "input.ATRPeriod=" + IntegerToString(InpATRPeriod) + "\r\n";
   s += "input.DispCandleATRMult=" + DoubleToString(InpDispCandleATRMult, 2) + "\r\n";
   s += "input.DispMinBodyPct=" + DoubleToString(InpDispMinBodyPct, 1) + "\r\n";
   s += "input.DispMinRelStrength=" + DoubleToString(InpDispMinRelStrength, 2) + "\r\n";
   s += "input.RejectLegViolation=" + IntegerToString(InpRejectLegViolation ? 1 : 0) + "\r\n";
   s += "input.EnableBull=" + IntegerToString(InpEnableBull ? 1 : 0) + "\r\n";
   s += "input.EnableBear=" + IntegerToString(InpEnableBear ? 1 : 0) + "\r\n";
   s += "input.ExtendBars=" + IntegerToString(InpExtendBars) + "\r\n";
   s += "input.MaxAgeBars=" + IntegerToString(InpMaxAgeBars) + "\r\n";
   s += "input.OverlapPct=" + DoubleToString(InpOverlapPct, 1) + "\r\n";
   s += "input.FVGMinATR=" + DoubleToString(InpFVGMinATR, 3) + "\r\n";
   s += "input.RetestEnabled=" + IntegerToString(InpRetestEnabled ? 1 : 0) + "\r\n";
   s += "input.ScanDepth=" + IntegerToString(InpScanDepth) + "\r\n";
   s += "input.EnableCISD=" + IntegerToString(InpEnableCISD ? 1 : 0) + "\r\n";
   s += "input.CISDSwingLength=" + IntegerToString(InpCISDSwingLength) + "\r\n";
   s += "input.CISDSwingMinATR=" + DoubleToString(InpCISDSwingMinATR, 2) + "\r\n";
   s += "input.CISDSweepMode=" + IntegerToString((int)InpCISDSweepMode) + "\r\n";
   s += "input.CISDSweepValidity=" + IntegerToString(InpCISDSweepValidity) + "\r\n";
   s += "input.CISDLevelMode=" + IntegerToString((int)InpCISDLevelMode) + "\r\n";
   s += "input.CISDMaxSeries=" + IntegerToString(InpCISDMaxSeries) + "\r\n";
   s += "input.CISDMaxConfirmBars=" + IntegerToString(InpCISDMaxConfirmBars) + "\r\n";
   s += "input.CISDMaxRetraceBars=" + IntegerToString(InpCISDMaxRetraceBars) + "\r\n";
   s += "input.CISDScanDepth=" + IntegerToString(InpCISDScanDepth) + "\r\n";
   s += "input.CISDShowSD=" + IntegerToString(InpCISDShowSD ? 1 : 0) + "\r\n";
   s += "input.CISDSDLevels=" + InpCISDSDLevels + "\r\n";
   s += "input.ConnMaxCISDBars=" + IntegerToString(InpConnMaxCISDBars) + "\r\n";
   s += "input.ConnWarmupBars=" + IntegerToString(InpConnWarmupBars) + "\r\n";
   s += "input.ConnMaxRetests=" + IntegerToString(InpConnMaxRetests) + "\r\n";
   s += "input.PanelMaxHeight=" + IntegerToString(InpPanelMaxHeight) + "\r\n";
   return s;
  }

int ReportInputDifferences(const string &keys[], const string &vals[])
  {
   string snap = BuildInputSnapshot();
   int diff = 0;
   for(int i = 0; i < ArraySize(keys); i++)
     {
      if(StringFind(snap, "input." + keys[i] + "=" + vals[i] + "\r\n") >= 0)
         continue;
      if(diff < 5)
         PrintFormat("[SMC-CFG] input %s: profile says '%s' - inputs cannot be changed at runtime, "
                     "adjust it in the EA properties if you want it applied", keys[i], vals[i]);
      diff++;
     }
   return diff;
  }

void SaveConfigProfile(void)
  {
   SSMCPanelState p;
   g_panel.GetState(p);
   SSMCConfigResult res;
   if(SMC_ConfigSave(g_panel.Profile(), p, BuildInputSnapshot(), InpConfigCommon, res))
     {
      g_panel.SetStatus(StringFormat("Config '%s' saved", g_panel.Profile()));
      Print("[SMC-CFG] ", res.message);
     }
   else
     {
      g_panel.SetStatus(StringFormat("Config save FAILED (%s)", g_panel.Profile()));
      Print("[SMC-CFG] save failed: ", res.message);
     }
  }

void LoadConfigProfile(void)
  {
   SSMCPanelState p;
   g_panel.GetState(p);                 // start from the current state: missing keys keep their value
   string keys[], vals[];
   SSMCConfigResult res;
   if(!SMC_ConfigLoad(g_panel.Profile(), p, InpConfigCommon, keys, vals, res))
     {
      g_panel.SetStatus(StringFormat("Config load FAILED (%s)", g_panel.Profile()));
      Print("[SMC-CFG] load failed: ", res.message);
      return;
     }
   g_panel.SetState(p);                 // validates and clamps every value
   SyncTimeframesFromPanel();
   Rescan();                            // detection settings may have changed
   RebuildCISD();
   RebuildConnection();
   int diff = ReportInputDifferences(keys, vals);
   g_panel.SetStatus(StringFormat("Config '%s' loaded%s", g_panel.Profile(),
                                  diff > 0 ? StringFormat(" (%d inputs differ)", diff) : ""));
   PrintFormat("[SMC-CFG] %s%s", res.message,
               diff > 0 ? StringFormat(" | %d EA inputs differ from the profile (read-only at runtime)", diff) : "");
  }

//+------------------------------------------------------------------+
//| Self test: save / load round trip, unknown keys, validation      |
//+------------------------------------------------------------------+
void TestConfigProfiles(void)
  {
   int pass = 0, fail = 0;
   SSMCPanelState saved, a, b, c;
   g_panel.GetState(saved);
   SSMCConfigResult res;
   string keys[], vals[];
   string p1 = "__selftest", p2 = "__selftest_partial";

   //--- round trip: everything comes back exactly
   a = saved;
   a.cisdMode = 1; a.retestMode = 1; a.swingLength = 7; a.dispATRMult = 2.25;
   a.showBull = false; a.cisdSweep = false; a.obTF = 5; a.cisdTF = 2; a.connect = true; a.maxActivePerDir = 13;
   a.mitStopsCISD = true; a.trendFilter = false;
   a.tradeEnabled = true; a.lots = 0.07; a.oppExit = false;
   a.targetRR = 2.5; a.breakEven = true; a.bePoints = 250; a.rideTrend = true; a.entryAlert = false;
   if(SMC_ConfigSave(p1, a, BuildInputSnapshot(), InpConfigCommon, res))
      pass++;
   else { fail++; PrintFormat("[SMC-CFG][TEST] FAIL  save: %s", res.message); }

   b = saved;                           // deliberately different starting point
   b.cisdMode = 0; b.retestMode = 0; b.swingLength = 3; b.mitStopsCISD = false; b.trendFilter = true;
   b.tradeEnabled = false; b.lots = 0.55; b.oppExit = true;
   b.targetRR = 1.0; b.breakEven = false; b.bePoints = 100; b.rideTrend = false; b.entryAlert = true;
   if(SMC_ConfigLoad(p1, b, InpConfigCommon, keys, vals, res))
      pass++;
   else { fail++; PrintFormat("[SMC-CFG][TEST] FAIL  load: %s", res.message); }
   if(b.cisdMode == a.cisdMode && b.retestMode == a.retestMode &&
      b.swingLength == a.swingLength && MathAbs(b.dispATRMult - a.dispATRMult) < 1e-9 &&
      b.showBull == a.showBull && b.cisdSweep == a.cisdSweep && b.obTF == a.obTF && b.cisdTF == a.cisdTF &&
      b.maxActivePerDir == a.maxActivePerDir && b.mitStopsCISD == a.mitStopsCISD &&
      b.trendFilter == a.trendFilter && b.tradeEnabled == a.tradeEnabled &&
      MathAbs(b.lots - a.lots) < 1e-9 && b.oppExit == a.oppExit &&
      MathAbs(b.targetRR - a.targetRR) < 1e-9 && b.breakEven == a.breakEven &&
      b.bePoints == a.bePoints && b.rideTrend == a.rideTrend &&
      b.entryAlert == a.entryAlert && ArraySize(keys) > 0)
      pass++;
   else { fail++; Print("[SMC-CFG][TEST] FAIL  round trip: values differ after load"); }

   //--- a partial / newer file: known keys apply, missing keys keep their value, unknown keys are ignored
   int h = FileOpen(SMC_ConfigPath(p2), FILE_WRITE | FILE_TXT | FILE_ANSI | (InpConfigCommon ? FILE_COMMON : 0));
   if(h != INVALID_HANDLE)
     {
      FileWriteString(h, "version=1\r\ncisdMode=1\r\nsomeFutureSetting=42\r\n");
      FileClose(h);
     }
   c = saved;
   c.cisdMode = 0;
   c.swingLength = 11;
   if(SMC_ConfigLoad(p2, c, InpConfigCommon, keys, vals, res) && c.cisdMode == 1 && c.swingLength == 11 &&
      res.unknown == 1)
      pass++;
   else { fail++; Print("[SMC-CFG][TEST] FAIL  partial file: missing / unknown keys not handled safely"); }

   //--- out-of-range values are clamped when applied
   c = saved;
   c.swingLength = 999;
   c.cisdMode = 7;
   c.retestMode = -3;
   g_panel.SetState(c);
   g_panel.GetState(c);
   if(c.swingLength == 50 && c.cisdMode == 1 && c.retestMode == 0)
      pass++;
   else { fail++; Print("[SMC-CFG][TEST] FAIL  loaded values are not validated"); }

   //--- missing profile fails cleanly without touching the state
   if(!SMC_ConfigLoad("__does_not_exist", c, InpConfigCommon, keys, vals, res) && !res.ok)
      pass++;
   else { fail++; Print("[SMC-CFG][TEST] FAIL  missing profile did not report failure"); }

   g_panel.SetState(saved);
   SyncTimeframesFromPanel();
   FileDelete(SMC_ConfigPath(p1), InpConfigCommon ? FILE_COMMON : 0);
   FileDelete(SMC_ConfigPath(p2), InpConfigCommon ? FILE_COMMON : 0);
   PrintFormat("[SMC-CFG][TEST] Configuration profiles %s: %d checks passed, %d failed",
               fail == 0 ? "ALL PASSED" : "FAILURES", pass, fail);
  }
//+------------------------------------------------------------------+
