# SMC Order Block EA — Design

Detection-only Expert Advisor (v1). It places no orders.

## 1. Existing project review

| File | Verdict |
|---|---|
| `Experts/Zaid/Order Block/OB Detection.mq5` | Not reused. It scans bar 0, which is still forming, and uses future bars to confirm fractals, so it repaints. It groups a *series* of candles into one OB, has no BOS or displacement logic, and assigns to an `input`, which won't compile. |
| `Experts/Zaid/All EAs/Structure Detector.mq5` | Not reused. It reads `i-1..i-3` including the forming bar and has no state, so the same BOS fires repeatedly. |

Nothing was modified. The new EA lives in `Experts/Zaid/2026/SMC_OrderBlock_EA/`.

## 2. Definitions

Indexing: arrays are in series order. `r[0]` is the newest **closed** bar and `r[i+k]` is k bars older. Processing bar `i` reads only `r[i..]`. The forming bar is never copied (`CopyRates` starts at shift 1).

`ATR(i)` is the simple mean of True Range over bars `i..i+P-1`.

**Swing High** at candle `c`, with `R = swing strength`. It is confirmed when bar `i = c-R` closes, if all of these hold:
- `High[c] > High[c+j]` for j=1..R (older bars, strict)
- `High[c] >= High[c-j]` for j=1..R (newer bars)
- `High[c] − min(Low[c−R..c+R]) ≥ SwingMinATR × ATR(c)`

**Swing Low** is the mirror image.

**Bullish BOS** on closed bar `i`: take `S`, the most recent confirmed, unbroken swing high. The BOS fires when `Close[i] > S.price + buffer`, where buffer is 0 or `k×ATR` depending on mode. Every unbroken swing high below that close is then marked broken, so no swing can produce a second BOS. A break against the previous BOS direction is labelled CHoCH. **Bearish BOS** is the mirror image.

**Displacement and OB candle** for a BOS at bar `i` in direction D:
1. Walk back `j = i … i+MaxOBToBOS` and stop at the **first** candle with the opposite colour. That candle is the OB (`ob`). The candles `[i, ob−1]` form the leg, which has no opposite-colour candles. If `ob == i` the setup is rejected. Dojis never count as opposite.
2. `ATR` and average body are measured at `ob`, before the move, so the displacement can't inflate its own threshold.
3. The setup is valid only if all of these pass:
   - `D×(Close[i] − Open[ob−1]) ≥ DispATRMult × ATR` (net move)
   - strongest D-coloured body in the leg `≥ DispCandleATRMult × ATR`
   - that candle's `body/range ≥ MinBodyPct`
   - `strongest body / avg body(ob..ob+P−1) ≥ MinRelStrength`
   - optional: no leg bar trades beyond the OB's far edge

**Bullish OB:** a bullish BOS with valid displacement. The zone is the last bearish candle before the leg: High–Low (default), or Body, or Open–Low.
**Bearish OB:** the mirror image, using the last bullish candle.

**FVG:** three candles `m+1, m, m−1`, all closed, with the middle candle `m` inside the leg and coloured D.
- Bullish: `Low[m−1] > High[m+1]`
- Bearish: `High[m−1] < Low[m+1]`
- The gap must be `≥ FVGMinATR × ATR`.

The FVG engine only runs for a candidate that has **already** passed BOS and displacement, so an FVG can never create an OB. If the BOS candle is the middle candle, its third candle closes one bar later:
- **Confluence mode:** the FVG is linked then, and the zone doesn't change.
- **Required mode:** the candidate stays *pending* (not drawn, not confirmed) until that bar closes. It's then confirmed on that bar, or rejected.

**Retest start mark:** a thin dotted vertical line across each zone, at the close of the candle that confirmed the OB (`confirmTime + OB period`). Retest detection, including the HTF OB → CISD retests, starts there; price inside the zone before that moment is not a retest because the OB did not exist yet. Panel toggle **Retest start** (input `InpShowRetestStart`), hidden in Easy mode.

**Retest:** a closed bar enters the zone after the previous bar was outside it (bull: `Low ≤ top`; bear: `High ≥ bottom`). The first one sets `RETESTED` and draws a marker; later entries increment `retestCount`.

**Mitigation**, depending on mode: a touch, the 50% level (`mid`), or the far edge. It sets `MITIGATED`. The zone is still valid, so its box keeps extending; only invalidation, expiry or supersession stops it.

**Invalidation**, depending on mode:
- Bull: `Close < bottom`, or `Low < bottom`.
- Bear: the mirror image.

It sets `INVALIDATED`, which is final.

**Expiry:** the zone is older than MaxAgeBars, or exceeds MaxActivePerDir (the oldest one goes first).

## 3. Pipeline per closed bar (`CSMCDetector::ProcessBar`)
1. Resolve FVGs completed by this bar (late link, or confirming pending candidates).
2. Update the lifecycle of OBs confirmed **before** this bar.
3. Confirm the swing at `i+R`.
4. Detect BOS on bar `i`.
5. Displacement → last opposite candle → dedup → zone → FVG → overlap policy → store.

The history scan and live updates call the same function, one bar at a time, oldest first.

## 4. Architecture / files
| File | Layer |
|---|---|
| `SMC_OB_Types.mqh` | enums, settings, records (`SSwing`, `SBOS`, `SOrderBlock`, `SSMCEvent`, stats) |
| `SMC_OB_MarketData.mqh` | candle and ATR helpers (no look-ahead) |
| `SMC_OB_Structure.mqh` | Market Structure Engine |
| `SMC_OB_Displacement.mqh` | Displacement Engine and OB-candle search |
| `SMC_OB_FVG.mqh` | FVG Engine |
| `SMC_OB_Engine.mqh` | Order Block, Retest and Mitigation engines, plus orchestrator and events |
| `SMC_OB_Visual.mqh` | Visualization (read-only consumer of state and events) |
| `SMC_OB_TradeHooks.mqh` | Future trading layer, hard-disabled, no orders |
| `SMC_OB_SelfTest.mqh` | deterministic synthetic and real-data tests |
| `SMC_OrderBlock_EA.mq5` | inputs, data feed, event dispatch |

Future entry, SL and TP logic goes in `CSMCTradeEngine`. It receives `SSMCEvent`s and has read-only access to `CSMCDetector` (`GetLiveOBs`, `GetOB`, `FindById`). Events from the history scan are flagged `historical` and ignored.

## 4b. Control panel (`SMC_OB_Panel.mqh`)
The panel is built from chart objects in the top-left corner. The **-/+** button in its header collapses and expands it.

**Scrolling (v1.42).** The body is a scrolling viewport. `Build()` measures the content, then draws it offset by `m_scroll` and clips every widget to the viewport, so a panel taller than the chart never overflows. When the content doesn't fit, the header shows **▲ / ▼** buttons (three rows per click) and a scrollbar appears on the right edge; both disappear when everything fits. The height limit is `Panel max height in px`, or the chart height when that input is 0, and the panel re-fits itself when the chart is resized.
- **Easy mode** shows only the Bullish OBs / Bearish OBs toggles, and the chart shows only live OB zones.
- **Advanced mode** adds:
  - display toggles: old zones, BOS/CHoCH, FVG, retests, labels, swings, fill, retest start
  - detection controls: swing strength, displacement × ATR, max OB→BOS bars, max active OBs, FVG mode, mitigation, invalidation, zone mode, overlap
  - **Reset to input values**

The panel only edits its own state and returns an action:
- `LAYOUT`: the panel is redrawn.
- `REDRAW`: chart objects are rebuilt from stored state. The detector doesn't run.
- `RESCAN`: the detector is re-initialised and history is rescanned. This is deterministic.

Panel settings are saved per chart in terminal global variables (`SMCPNL_<chartId>_*`), so they survive timeframe and symbol changes. They're cleared when the EA is removed, the chart is closed, or the inputs are edited, so edited inputs take effect. The Strategy Tester doesn't deliver chart clicks, so the panel is only interactive on a live chart.

## 4c. ZOrder Blocks (v1.20)
A ZOrder Block uses the same BOS, displacement and last-opposite-candle confirmation as the standard OB. The only difference is the zone.

- **Series:** start from the standard OB candle (`d.obIndex`) and walk back to older candles while they have the same opposite colour. The walk stops at the first candle that isn't opposite, so a doji or a candle in the displacement's direction ends it and the series is always contiguous. `obTime` is the newest candle of the series and `seriesStartTime` the oldest; `seriesCount` is the number of candles.
- **Zone:** from the highest High to the lowest Low of all candles in the series. The OB zone-mode input doesn't apply to ZOrders, except **Open-Last Ext**: bull = first (oldest) candle Open to last (newest) candle Low, bear = first candle Open to last candle High (single candle: bull Low-Open, bear Open-High, the same as Open-Extreme). A zone with zero height is rejected, as in the other modes.
- **Lookback:** the walk never reads older than `i + lookback`, the deepest bar available in every data window. If the start of the series isn't visible within that range, the ZOrder is rejected (`seriesTooLong`) rather than truncated. This keeps the history scan and live updates identical and adds no extra warm-up.
- **Architecture:** a second `CSMCDetector` runs with `zoneSource = SMC_SOURCE_CANDLE_SERIES` on the same bars. It has its own IDs, lifecycle, overlap, max-active limit, events and stats. The standard detector keeps the default `SMC_SOURCE_LAST_CANDLE`, so its code path and results are unchanged.
- **Reused settings:** retest, mitigation, invalidation, extension, FVG, overlap and max active.
- **Drawing:**
  - prefix `SMCZOB_`
  - colours: DeepSkyBlue for bullish, Magenta for bearish
  - dashed outline, unfilled by default
  - the rectangle starts at the oldest candle of the series
  - labels "ZOrder Bullish #id | N candles" and "ZOrder Bearish #id | N candles", placed on the opposite edge to the standard OB label

  BOS, swings and FVG boxes are left to the standard layer so they aren't drawn twice.
- **Inputs:** Enable ZOrder Blocks, Show Bullish/Bearish ZOrder, colours, border style, fill. The panel shows Bull/Bear ZOrder toggles in both modes.

## 4d. CISD — Change in State of Delivery (v1.30)
CISD is an independent module made of `SMC_CISD_Engine.mqh`, `SMC_CISD_Visual.mqh` and `SMC_CISD_SelfTest.mqh`. It shares no state with the OB or ZOrder engines. Its swing check is the same unmodified `CSMCStructure::ConfirmSwings` code, run as a separate instance.

**Timeframe.** The `CISD_Timeframe` input can be Current chart, M1, M5, M15, M30, H1, H4 or D1. All CISD data comes from `CopyRates(_Symbol, CISD_Timeframe, 1, …)`, and new bars are detected with `iTime(_Symbol, CISD_Timeframe, 0)`. Objects are placed by CISD-bar time, so they line up on any chart timeframe.

**State machine.** Shown for bullish; bearish is the mirror image. Each step uses closed CISD-timeframe bars.

| Stage | Rule |
|---|---|
| WAITING | Confirmed swing lows (strength R, prominence × ATR, max age) are sell-side liquidity. |
| LIQUIDITY_SWEEP_LOW | A closed bar has `Low < swing low`; in rejection mode it must also close back above. The swing is used up once taken. The deepest swing taken is recorded with the sweep time and price. |
| IDENTIFY_BEARISH_SERIES | On the bar that ends a bearish run (a closed non-bearish candle), the whole contiguous run is measured: start, end, count, High, Low, first open. The run is never truncated; if it's longer than *max series* the setup is skipped. The manipulation extreme is the lowest low from the start of the series through the ending bar. |
| Sweep association | The sweep must fall inside the series or on its ending bar. Alternatively, the sweep can come up to *sweep validity* bars before the series, as long as the series extreme is below the swept swing. Each sweep can produce only one confirmed CISD. |
| WAIT_FOR_BULLISH_CLOSE | The setup is stored (only one per direction; a newer one replaces it). It fails on a lower low or after *setup expiry* bars. |
| BULLISH_CISD_CONFIRMED | A closed bar has `Close > level`. The level is the series High by default, or the open of the first series candle (classic mode). |
| WAIT_FOR_RETRACEMENT | Retraced (entry signal) when a later bar has `Low <= level`. Invalidated when a bar closes below the extreme. Expired after *retracement window* bars. |

**Panel switches.** Each switch rebuilds and rescans only the CISD engine:
- **Liquidity Sweep:** ON requires a sweep and draws sweep markers. OFF processes no sweeps, so every completed series can become a setup.
- **Confirmation Close:** OFF stops the pipeline at SETUP, so no CISD is confirmed, retraced or projected.
- **Retracement / Entry:** OFF skips retracement tracking and hides the retracement area and entry markers.

**Standard deviation (analysis only).** `price(k) = level + dir · k · |level − extreme|`, so 0 is the CISD level and −1 is the manipulation extreme. The levels come from an input (default 1.0, 1.5, 2.0, 2.5). The −2 to −2.5 reversal area is optional. None of this affects confirmation.

**Non-repainting.**
- Only closed bars are used, and each bar is processed once.
- Setup fields are fixed at creation, and confirmation fields are fixed at confirmation.
- The self-tests check that the history scan and bar-by-bar processing give identical results, that adding more history changes nothing, and that every setup is valid against the raw candles on M1/M5/M15/H1/H4.
- At deinit in the tester, the live multi-timeframe engine is compared with a batch run over the same CISD-timeframe candles.

**Objects.** CISD objects use the prefix `SMCCISD_`:
- `SWL`, `SWA`, `SWT`: sweep line, marker and label
- `SER`: series box
- `SUL`, `SUT`: setup level and label
- `LVL`, `LVT`: CISD level and label
- `CFA`: confirmation arrow
- `RTZ`, `RTA`, `RTT`: retracement area, marker and label
- `SD`, `SDT`, `SDR`: SD lines, labels and reversal area

Colours are LimeGreen (bullish), Crimson (bearish), Khaki (series), Yellow (sweeps) and Plum (SD).

No trades are placed. `CSMCTradeEngine::OnCISDEvent` is the hook for future CISD entries.

## 4e. HTF OB → LTF CISD workflow (v1.40)
This is a new module, made of `SMC_Connect_Engine.mqh`, `SMC_Connect_Visual.mqh` and `SMC_Connect_SelfTest.mqh`. It connects the existing detectors without changing how they work.

**Timeframes.**
- **Order Block TF** (new) feeds both `CSMCDetector`s, replacing `_Period` in the OB data feed.
- **CISD TF** feeds every CISD engine.
- **M1** is used only to timestamp retests.

All three are set from inputs and can be changed on the panel.

**Per-OB monitor.** Every Standard OB and ZOrder becomes one monitor, and each monitor has its own `CSMCCISDEngine`.

| State | Rule |
|---|---|
| OB_CREATED | The OB is confirmed on the OB timeframe. It becomes available at `confirmTime + OB period`, when its confirmation candle has closed. |
| WAITING_FOR_RETEST | Waiting for the first touch after the OB becomes available. |
| OB_RETESTED | The first closed M1 candle with `Low <= top && High >= bottom`. Retest time is that candle's open, and retest price is the zone-clipped extreme. |
| CISD_MONITORING | `CISD_Start = first CISD-TF candle open >= retest time`. The engine is warmed up on earlier candles (liquidity pools only). With `activationTime = CISD_Start` and `dirFilter = OB direction`, it records no sweep, series or confirmation before the start and nothing in the other direction. |
| CISD_SWEEP_DETECTED | A liquidity sweep inside the monitoring window. |
| CISD_CONFIRMED | The first same-direction CISD confirmation. It's preserved even if the OB is invalidated later. |
| RETRACEMENT / COMPLETED | The CISD retracement (entry), or confirmation without a retracement (switch off, or window ended). |
| INVALIDATED / EXPIRED | The OB became invalid before confirmation, or no CISD appeared within *window* CISD bars. |

**Time consistency.** OB invalidation is known at `invalidatedTime + OB period` (EXPIRED/SUPERSEDED: `endTime + OB period`). Each decision is made only against information already known at that candle's time. The connection never processes a candle past the point the OB detectors have reached (`ConnHorizon`), so the history scan and live ticks give identical results, and nothing decided earlier ever changes.

**Standalone CISD.** When the connection is ON, the standalone CISD engine is paused and its objects are removed. When OFF, standalone CISD behaves exactly as in v1.30. The three CISD switches apply to both.

**Objects.** Prefix `SMCCONN_S<setupId>_`:
- `RT`, `RTT`: retest marker and label
- `MON`, `MONT`: monitoring line and "CISD ACTIVE" label
- `SWL`, `SWA`, `SWT`: sweep
- `SER`, `LVL`, `CFA`: series, level and confirmation
- `LNK`, `LNT`: the retest → confirmation link, labelled "H1 OB#12 + M5 CISD#3 = SETUP"
- `RTA`, `RTX`: entry

**Order Block source (v1.41).** Chooses which PD arrays may activate CISD validation: Both, ZOrder Block only, or Order Block only. It filters which OBs get a monitor and nothing else; detection itself is unchanged. The older `InpConnUseStandard` / `InpConnUseZOrder` switches still apply on top of it.

**CISD validation mode (v1.41).** Applies per Order Block:
- **Single** (default, the original behaviour): the first valid CISD after the retest is kept and that OB stops searching.
- **Multi:** every valid CISD after the retest is kept. The monitor keeps running until the window ends or the OB is invalidated, and each CISD keeps its own retracement state. CISDs already confirmed are preserved when the OB dies.

**Retest mode (v1.50).** A retest is a fresh M1 re-entry into the zone (price must leave it first). Each retest that is allowed to run creates a **sequence** (`SConnSeq`) with its own CISD engine, ID and state.
- **Single:** only the first retest of an OB starts a sequence; later retests are counted and logged but start nothing.
- **Multi:** every re-entry starts a new sequence, up to *Max CISD sequences per Order Block*.

Retest mode and CISD mode are independent, so all four combinations work: SR+SC, SR+MC, MR+SC, MR+MC.

**Data model (v1.50).** Three records, so Multi retest and Multi CISD can coexist:
- `SConnSetup` — one Order Block: zone, validity, `retestCount`, `seqCount`, `cisdCount`, zone occupancy.
- `SConnSeq` — one retest: `retestNo`, retest time/price, CISD start, activation, sweep, state, its CISDs.
- `SConnCISDHit` — one confirmed CISD, keyed by sequence ID *and* setup ID.

Sequences never share state, so one Order Block's CISDs can't affect another's.

**Order Block invalidation (v1.50).** The moment an OB's death is known (`invalidatedTime`/`expiredTime` + OB period), every live sequence of that OB stops: no new sweep, no new confirmation, no retracement or entry. Sequences that already had a confirmation end as `COMPLETED` and keep their CISDs; the rest end as `INVALIDATED`. This applies in every retest/CISD mode, and it's checked both on M1 (finest resolution) and before any CISD candle is evaluated. An invalidated OB can never start a new sequence.

The OB is still valid for every candle that closes up to and including that moment, including the last lower-timeframe candle that closes together with the invalidating candle (M1 15:44 for an M15 candle opening at 15:30). A CISD confirmed on that candle counts. Monitoring stops from the next candle on (`dead < candle close`).

**Mitigation stops CISD (option).** The input `InpConnMitigationStops` sets the default for the panel switch **Mitigation stops CISD**, which is saved in config profiles as `mitStopsCISD`. The default is OFF, where a mitigated OB is still valid and keeps being monitored. When ON, mitigation ends the CISD search exactly like invalidation. Mitigation is checked on **every closed M1 candle** (same Touch / 50% / Full level as the OB detector), not only when the OB-timeframe candle closes. The search ends at the close of the first M1 candle that reaches the level, or at the OB-timeframe mitigation / invalidation if that is known earlier. The same last-candle rule applies, and confirmed CISDs are kept. The log and tooltip say `MITIGATED - CISD monitoring stopped`. The OB zone drawing doesn't change.

**Pre-retest candle series (v1.50).** Series detection and OB association are separate. Each sequence's engine runs with `activationMode = CISD_ACT_CONFIRM_AFTER`, so a sweep and a bearish/bullish series may begin *before* the retest and still confirm afterwards. Only the confirmation close must fall at/after the activation candle. A setup whose close already changed delivery before activation is consumed (`SETUP_FAILED`), so a CISD completed before the retest can never be re-attached to it. Warm-up candles before the retest are fed to every sequence so those earlier series are visible.

Multi draws every CISD of a sequence, with extra link lines dotted and labelled "(2/3)", and each retest of the same OB is drawn separately as R1, R2, R3.

## 4f. Configuration profiles (v1.50)
`SMC_Config.mqh` saves and loads user configuration as `key=value` text in `MQL5\Files\SMC_OrderBlock_EA\<profile>.cfg` (or the common folder).

- **Panel:** a **Profile** name box plus **Save Config** / **Load Config**. Typing a new name and pressing Enter is "Save As".
- **Saved:** every runtime-adjustable setting — timeframes, connection on/off, OB source, CISD mode, retest mode, the three CISD switches, display toggles, and the panel's detection values — plus a read-only snapshot of the EA inputs.
- **Not saved:** market state (OB/CISD IDs, retests, prices, setup history).
- **Loading** starts from the current state, so missing keys keep their value and unknown keys (from a newer build) are ignored and counted. Everything is clamped by `SetState()`, then the OB, CISD and connection layers are rebuilt — no restart needed. Success or failure is shown in the panel status line and the log.
- **EA inputs are read-only at runtime in MQL5.** Values saved under `input.*` are compared on load and any difference is reported, telling you to change it in the EA properties. It's never silently ignored.

**Trading hook.** `CSMCTradeEngine::OnConnectionEvent` receives the setup ID, OB ID and type, direction, CISD ID, time and price. No orders are placed.

## 4g. Performance rules
These keep the EA light. Every one leaves outputs unchanged: a build with and without them gives byte-identical logs, statistics and chart objects.

- **Messages are built only when they will print.** Every `Log(level, StringFormat(...))` is guarded by `Logs(level)`, which uses the same condition as `Log()`.
- **The connection syncs only when the detectors move.** `SyncOBs()` reads confirmed OBs and their end times, which change only when a new OB bar is processed. `OnTickPrice()` touches only `liveInside`. So `ProcessConnection()` skips the sync while `LastProcessedTime()` and both OB counts are unchanged. `RebuildConnection()` / `InitConnection()` reset that fingerprint.
- **OB lookups are cached.** Each setup caches its detector index and re-checks it by id with `OBIdAt()`, so the linear `FindById()` search runs only if the index moved. A dead OB is copied once, when it dies.
- **One window per candle.** All live CISD sequences are fed the same newest-first window. It is built once per candle in `m_win` and reused.
- **Scratch arrays are reused.** Per-bar swing/BOS arrays and the EA's `CopyRates` buffers are members or globals, so they are not reallocated on every bar.
- **Unchanged zones are not redrawn.** Each visualizer keeps a sorted per-record signature of everything its drawing reads. An unchanged record costs no object calls. If only a record's position changed (an extending edge), its objects are moved. Objects are deleted only when a record's object set changes, or when it leaves the drawn window. `SetSettings()` / `Cleanup()` / `RedrawAll()` of the OB layer clear the signatures.
- **Order-block zones are never redrawn on ticks.** A zone extends with each closed candle while it is valid, including after mitigation. Mitigation changes only its colour and label. Invalidation, expiry or supersession stop the box at the **close** of that candle and change its colour and label, so on a lower chart timeframe the box covers every minute of the invalidating candle. Its border style and width stay as drawn.
- **Check object existence with `ObjectFind()`.** Object calls are queued asynchronously, and `ObjectMove()` reports success for a name that does not exist yet. So `Ensure()` must use `ObjectFind()` before deciding between create and move.

## 5. Duplicates and overlaps
- **Unique ID:** a sequential `id`, plus the natural key `(direction, OB candle time)`. A second BOS whose leg traces back to the same candle is rejected as a duplicate.
- **Once per bar:** each bar is processed exactly once, guarded by the last processed bar time, so feeding the same bars again does nothing.
- **Overlap:** measured as `intersection / smaller zone height` against live zones in the same direction, compared with `OverlapPct`. Three policies are available:
  - `SKIP_NEW` (default): the first confirmed zone wins and history stays stable.
  - `SUPERSEDE_OLD`: the old zone becomes `SUPERSEDED`. Its location never changes.
  - `KEEP_ALL`: both zones are kept and tagged `OVL`.

  Zones are **never merged**, because merging would rewrite history.

## 6. Repainting / look-ahead risks and how they are handled
| Risk | Mitigation |
|---|---|
| Using the forming bar | Data is always copied from shift 1. Lifecycle state changes only on closed bars. The tick-level `liveInside` flag is informational and is not drawn. |
| Swing confirmed with future bars | A swing is recorded only when its R-th right-hand bar has closed. BOS uses swings dated before the break bar. |
| Displayed OB changing later | Identity fields are written once at confirmation. Only lifecycle fields change afterwards. |
| FVG needing the bar after BOS | Confluence: linked one bar later, zone untouched. Required: the candidate stays pending and invisible. |
| ATR inflated by the displacement | ATR is measured at the OB candle. |
| Batch scan differing from live | The same `ProcessBar` runs over a fixed lookback. The self test compares batch results with a bar-by-bar minimal-window simulation. |
| History growing and changing old OBs | The self test compares full-history OBs against runs with history truncated at 4 cut points. Identity must match, and no OB may appear retroactively. |
| Timeframe or parameter change | `OnDeinit` removes objects and `OnInit` rescans deterministically. |
