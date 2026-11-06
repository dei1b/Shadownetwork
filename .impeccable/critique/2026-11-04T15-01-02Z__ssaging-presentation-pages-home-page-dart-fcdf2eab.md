---
target: "Mobile UI: responder, registered resident, unregistered resident"
total_score: 20
max_score: 40
na_heuristics:
p0_count: 1
p1_count: 3
target_identity: "file:C:\\Users\\Dave\\Desktop\\Shadownetwork\\lib\\features\\messaging\\presentation\\pages\\home_page.dart"
target_fingerprint: "sha256:57a3f3c588be9ccdf3e0feb01d58b9a59948dffdf8cad48b6ccea5399c5c2326"
target_path: "C:\\Users\\Dave\\Desktop\\Shadownetwork\\lib\\features\\messaging\\presentation\\pages\\home_page.dart"
timestamp: 2026-11-04T15-01-02Z
slug: ssaging-presentation-pages-home-page-dart-fcdf2eab
---
# Shadow Network mobile critique

Method: dual-agent (A: 01a1a710-00c2-7dc3-a567-bb79cc115092; B: 01a1a710-01bd-7392-88c9-476272998bf7).

## Design health: 20/40 (Acceptable)
| Heuristic | Score | Evidence |
|---|---:|---|
| System status | 2 | Honest send confirmation; stale location and mismatched alert count. |
| Real-world match | 2 | Barangay handoff is concrete; Civilian and legitimate are less clear. |
| Control and freedom | 2 | Back works; dismissing the SOS sheet discards input. |
| Consistency | 2 | Navigation is labeled; decorative feed controls look actionable. |
| Error prevention | 2 | Empty SOS is blocked; Medical is selected by default. |
| Recognition | 2 | Numbered registration steps; SOS status hard to find later. |
| Efficiency | 2 | Responder shortcut; resident SOS reach varies with list length. |
| Minimalism | 2 | Plain shell; two red panels compete on responder Dashboard. |
| Error recovery | 1 | Save errors stay inline; bad approval can block entry. |
| Help | 3 | Registration and privacy guidance are useful; pending delivery needs a next step. |

## Role walkthroughs
- Responder: Dashboard prioritizes SOS Alerts, with map and receipt data that fit the job. Two strong red panels compete, the count does not match the opened list, and Message sender follows technical evidence.
- Registered resident: Home offers SOS, map, and chats; approval feels secondary. The term Verified Civilian is less helpful than Phone approved, and there is no clear persistent SOS delivery state on the resident card.
- Unregistered resident: Home still supports broadcast, but the reassurance appears inside Phone registration. After scanning admin approval, feedback reports the bundle import, not whether this phone is approved.

## Priorities
1. P0 conditional, harden: Unreadable approval can stop the composer before it appears (home_page.dart:424; trust_bundle_store.dart:15). Allow broadcast when approval cannot be read; keep approval-required targeting unavailable and give recovery guidance.
2. P1, layout: Every Nearby card and the map precede the original SOS button (home_page.dart:608). Keep the section and button design. Provide a reliably reachable SOS entry if the list grows.
3. P1, clarify: The sheet can show a stale location after Update and residents lose the pending delivery explanation after dismissal (home_page.dart:448, 456, 3768). Show the coordinates actually attached or No GPS location, and persist a plain-language send status in Messages.
4. P1, distill: Dashboard's legitimate alert count can disagree with the SOS list (home_page.dart:741). Use the same filter, distinguish loading from zero, and place Message sender before technical diagnostics (sos_detail_sheet.dart:195).
5. P2, onboard: Show the local device's resolved outcome after scanning approval (trust_bundle_import_page.dart:186), and say SOS is available before registering on Home.

## Strengths and smaller issues
The original SOS button, Panabo offline map, plain registration steps, accurate saved-versus-delivered confirmation, and evidence-rich responder receipts give the app a clear local emergency identity. Secondary findings: 30dp map controls without names, idle scanning copy that does not reflect actual scan state, and inert search and All affordances. Keep the current red-and-white theme and avoid broad redesign.

## Questions to consider
- Which goes first: reliable resident SOS or responder alert triage?
- Keep changes to behavior and wording, or include spacing and touch-target fixes?
