---
name: mql5-smc-order-blocks
description: Use when implementing or reviewing an MQL5 Smart Money Concepts strategy with order blocks, CISD confirmation, market-structure or fair-value-gap logic, multi-timeframe mapping, chart objects, and guarded trade execution.
---

# MQL5 SMC Order Blocks

- Read `DESIGN.md` before changing detection or confirmation rules; it is the specification behind the self-tests.
- Read `SMC_OrderBlock_EA.mq5` for inputs and lifecycle wiring.
- Read `SMC_OB_{Types,Structure,Displacement,Engine}.mqh` for order-block detection and state.
- Read `SMC_CISD_Engine.mqh` and `SMC_Connect_Engine.mqh` for lower-timeframe confirmation and HTF/LTF mapping.
- Keep orders in `SMC_OB_TradeHooks.mqh`; keep drawing and panel work in the matching `*_Visual.mqh` or `*_Panel.mqh` file.
- Read `SMC_*_SelfTest.mqh` whenever a related module changes.

Use closed candles for signal decisions, prohibit trade creation from historical scans, reject unsupported timeframe combinations, and define invalidation, retest, confirmation, stop, and target before adding execution. Keep execution disabled by default in generated configurations unless explicitly requested, and treat every preset as untrusted for a new broker, symbol, spread regime, and account.

This MIT-licensed project can place orders when enabled. Retain the execution gate and risk controls; validate in Strategy Tester and on a demo account before live use. This is not financial advice.
