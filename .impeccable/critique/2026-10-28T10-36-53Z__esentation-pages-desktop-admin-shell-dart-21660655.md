---
target: PC admin app
total_score: 27
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 2
target_identity: "file:C:\\Users\\Dave\\Desktop\\Shadownetwork\\lib\\features\\admin\\presentation\\pages\\desktop_admin_shell.dart"
target_fingerprint: "sha256:3fd6e4949d6d742739fe4096c3147f390c9712bf53ddd4dab7475bc58f125d4e"
target_path: "C:\\Users\\Dave\\Desktop\\Shadownetwork\\lib\\features\\admin\\presentation\\pages\\desktop_admin_shell.dart"
timestamp: 2026-10-28T10-36-53Z
slug: esentation-pages-desktop-admin-shell-dart-21660655
---
Method: dual-agent (A: /root/design_review; B: /root/evidence_review)

The current red, white and charcoal identity suits Shadow Network and complements the phone app. Keep it. The next pass should improve workflow continuity and first-run guidance. No blocking P0 failure was established.

Design health: 27/40, acceptable with targeted workflow repairs. These are expert-review judgments, not user-testing measurements.

| Heuristic | Score /4 | Main concern |
|---|---:|---|
| System status | 3 | Registry writes lack visible busy feedback |
| Real-world language | 3 | Approval still says next sync |
| User control | 2 | Section changes dispose registration drafts |
| Consistency | 3 | Cohesive controls; feedback varies by screen |
| Error prevention | 3 | Useful destructive-action and import safeguards |
| Recognition | 3 | Initial registration and its source need clearer guidance |
| Efficiency | 2 | Repeated cards/actions; few expert accelerators |
| Visual restraint | 3 | Calm design; empty-state counts occupy too much space |
| Error recovery | 2 | Password overlap and form-level transient validation |
| Help | 3 | Good contextual notes; operating guide not directly linked |
| Total | 27/40 | Acceptable |

Fix in this order:

1. [P1] Repair the backup password dialog. Confirmed in the installed app: At least 12 characters overlaps the Repeat password floating label. Add vertical separation, attach mismatch feedback to the repeat field, and verify focused/error/200%-text states. Source: lib/features/admin/presentation/widgets/admin_recovery_panel.dart:247. Suggested command: impeccable harden.

2. [P1] Put registration first when the registry is empty or the window is narrow. Confirmed at approximately 786x715: four zero-count cards and registry filters fill the first viewport; Paste Phone Registration JSON is below it. Give the empty state a visible Register a phone action that opens or scrolls to registration; compress or suppress irrelevant zero counts and filters. Source: lib/features/admin/presentation/pages/browser_admin_dashboard_page.dart:646 and lib/features/admin/presentation/widgets/admin_device_registry_panel.dart:182. Suggested command: impeccable adapt.

3. [P2] Preserve an unfinished registration across section changes. Source review shows navigation replaces the dashboard and disposes its controllers. Keep a session draft or retain the page; warn before an explicit discard. This was not reproduced by entering real registration data. Source: lib/features/admin/presentation/pages/desktop_admin_shell.dart:39 and browser_admin_dashboard_page.dart:61. Suggested command: impeccable harden.

4. [P2] Make saves visible and prevent silent ignored actions. The save guard rejects another write while controls remain enabled. Disable conflicting mutations while saving, show Saving, and announce success/failure. No slow-write timing was measured. Source: lib/features/admin/presentation/pages/browser_admin_dashboard_page.dart:92. Suggested command: impeccable harden.

5. [P2] Make approval's next step accurate. Replace Approved for next sync with Approved locally - share updated trust bundle. Repeat the next step in approval feedback. Keep the distinction between local approval, bundle export, and manual phone import; do not claim phones received it. Source: lib/features/admin/presentation/pages/browser_admin_dashboard_page.dart:254. Suggested command: impeccable clarify.

Keep the three clear destinations, search/status/role filters, status words alongside color, and honest local-storage/manual-import wording. They support the product's actual offline operation.

Cognitive load is moderate: grouping and progressive disclosure work, but empty-state statistics compete with starting work, and registration-to-phone-import requires remembering the handoff. The visual opening feels calm; password errors and lost drafts undermine that confidence.

Persona checks: First-time administrators need a visible first action and instructions for finding registration JSON on the phone. Frequent operators need uninterrupted drafts and efficient list scanning. Keyboard/low-vision operators benefit from labeled controls and enlarged-text support, but repeated action buttons need device-specific context and recovery feedback needs explicit announcements.

Next checks: Native keyboard/Narrator behavior and Windows high contrast are unverified, not proven broken. Test the fixed-size QR dialog in short windows. Consider compact dataset/run summaries and a visible operating-guide link after the workflow repairs.

Evidence: the independent detector returned exit 0 and an empty array. Its native reference says the detector does not apply to native apps, so this is not a Flutter accessibility pass. The review used source, the populated 1440x1000 synthetic fixture, and direct installed-app observations of the password dialog and narrow empty registry. No code, registrations, keys or backup data were changed.
