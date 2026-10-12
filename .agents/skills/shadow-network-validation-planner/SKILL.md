---
name: shadow-network-validation-planner
description: Plan Shadow Network field validation and interpret JSON or CSV session evidence for peer discovery, delivery success, transport fallback, latency, hop counts, and battery impact. Use for test protocols and results analysis.
---

# Shadow Network Validation Planner

## Use the Existing Evidence Pipeline

Read `CURRENT_STATE.md` and inspect the relevant code under `lib/features/validation` before proposing measurements. In particular:

- `domain/entities/validation_event.dart` defines recorded events and available metadata.
- `domain/services/validation_metrics_calculator.dart` defines the current summary calculations.
- `domain/services/validation_export_service.dart` defines JSON and CSV export formats.
- `data/repositories/sqlite_validation_metrics_repository.dart` persists session evidence.
- `test/validation_metrics_test.dart` exercises calculations and exports.

Work with actual session exports when supplied. Keep raw records intact and retain the session ID, message hash, peer ID, transport, and timestamps needed to reproduce results.

## Design Repeatable Trials

Choose scenarios that match the requested claim: direct BLE transfer, Wi-Fi Direct transfer, transport fallback, multi-hop Store-Carry-Forward, disconnected carry/reconnect, duplicate reception, TTL expiry, queue recovery after restart, or trust-based rejection.

For each scenario, record the device roles and topology, device models and Android versions, app revision, radio settings, distance/obstacles, duration, message workload, and expected observable result. Record charging state and starting battery for battery trials. Specify repetitions and acceptance criteria before collecting data; do not invent a threshold and present it as an existing capstone requirement.

Identify the sender and intended recipient separately from intermediate relays. Use mock runs to check logic and physical-device trials to support wireless, range, background execution, and battery claims.

## Interpret Metrics Carefully

- The current `deliverySuccessRate` uses successful sends divided by successful plus failed send attempts when transfer evidence exists. Its receive-only fallback uses delivered unique hashes intersected with received unique hashes. Explain which denominator applies rather than labeling either as end-to-end delivery automatically.
- For an end-to-end delivery claim, define a sender-side set of eligible unique message hashes and recipient-side delivery evidence within a stated observation window. Correlate across devices; record missing evidence explicitly.
- Separate recorded node transfer latency from propagation time. Cross-device timestamps need clock synchronization or a stated clock uncertainty.
- Keep hop distributions, transport usage, and fallback rates tied to the recorded event populations. Do not confuse retries or repeated events with additional unique delivered messages.
- Match discovery success to recorded discovery attempts. Distinguish finding an app peer from completing payload transfer.
- Battery calculations require usable elapsed time and uncharged samples; the current calculator returns no battery estimate if any sample is charging. Missing measurements are unavailable, not zero consumption.

Use CSV parsers for CSV exports and JSON parsers for JSON exports. When changing metric logic, verify the definitions and update focused validation tests and `CURRENT_STATE.md`.

## Deliver Traceable Results

For a test plan, provide setup, steps, expected observations, and evidence to capture. For results, include the source sessions, units, metric definitions, sample counts, exclusions, and limitations. Label simulated, measured, and proposed values distinctly. Never fill missing results with invented measurements.
