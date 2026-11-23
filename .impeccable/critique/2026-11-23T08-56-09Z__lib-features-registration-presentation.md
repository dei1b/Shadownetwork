---
target: DNSC login, signup, and Profile
total_score: 23
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 3
target_identity: "file:C:\\Users\\Dave\\Desktop\\Shadownetwork\\lib\\features\\registration\\presentation"
timestamp: 2026-11-23T08-56-09Z
slug: lib-features-registration-presentation
---
Method: dual-agent (A: 01a20796-1433-7b31-b9ce-027a54cfe7e0 · B: 01a20796-152c-7db3-b791-877b23262537)

# ShadowNetwork account and Profile critique

Reviewed on November 23, 2026 against `main` at `b638a676`. The scope is the Android flow students and campus responders reach from first run or Profile. Both entry points open the DNSC registration screen when enabled. The older branded login and signup pages are registered as named routes and link to each other. The normal Android entry points reviewed here lead to DNSC registration. [App routing](../lib/app/app.dart#L24) · [Profile entry](../lib/features/registration/presentation/profile_section.dart#L132)

## Overall assessment

The first-run flow protects access to SOS, and Profile distinguishes the online application from the phone’s offline approval. Those are specific to ShadowNetwork and worth keeping. The account screen reads like a generic form, and Profile makes users interpret approval stages before they can tell what they can do on their phone. The strongest improvement is a clear next action at every stage, using the existing typography and colors.

## Design health

**23/40.** These are design judgments from the source review. The independent detector returned zero findings on both Dart files. It targets web markup, so this result provides no Flutter design coverage. A current screen capture was unavailable during the review.

| Nielsen heuristic | Score out of 4 | Evidence |
| --- | ---: | --- |
| Visibility of system status | 2 | Cached review status can look current when refresh fails. |
| Match with the real world | 3 | Phone access is separate, but labels such as “awaiting publication” require interpretation. |
| User control and freedom | 2 | First-run Home and Back are disabled during sign-in and submission. |
| Consistency and standards | 2 | Legacy routes and the live form tell different stories about account access. |
| Error prevention | 3 | Inline checks and phone binding prevent common mistakes. |
| Recognition rather than recall | 2 | “Check status” does little to explain how to recover from approval for another phone. |
| Flexibility and efficiency | 2 | Guest access and draft saving help. Credential recovery and autofill are missing. |
| Aesthetic and minimalist design | 3 | Forms use simple sections. Profile’s account actions span several areas. |
| Error recovery | 2 | Failed Profile updates discard input and registration can offer retry advice without an action. |
| Help and documentation | 2 | Guest SOS is explained. Approval stages and their remedies need more context. |

## What works

- First run explains that SOS is available without an account and gives guests an explicit route to Home. [Registration page](../lib/features/registration/presentation/pilot_registration_page.dart#L413)
- Required fields display inline errors and focus the first missing field. Users can save a registration draft and see a cached review status offline. [Form validation](../lib/features/registration/presentation/pilot_registration_page.dart#L294) · [Cached status](../lib/features/registration/presentation/pilot_registration_page.dart#L100)
- Profile distinguishes approval for another phone from active access on this phone. Personal details are collapsed, and identity changes have a separate review path. [Profile states](../lib/features/registration/presentation/profile_section.dart#L182) · [Personal details](../lib/features/registration/presentation/profile_section.dart#L291)

## Priority findings

| Priority | Finding | Fix |
| --- | --- | --- |
| P1 | **A slow account request delays access to Home and SOS.** Sign-in and submission disable Back and the first-run Continue button while work runs. | Provide a safe route back to Home during slow requests. Preserve the draft, reconcile requests already sent, and make the exit label honest if authentication continues. Verify that leaving never silently signs a user into an account after they chose guest access. [Request locking and exit](../lib/features/registration/presentation/pilot_registration_page.dart#L401) |
| P1 | **The same form serves three distinct tasks.** Create account is the filled button even for returning students. There is no password reset, visibility toggle, or autofill setup. After signup the application form appears without a clear stage heading. | Give **Sign in** and **Create account** explicit modes with one primary button each. Add password reset, show/hide, and Android autofill. After account creation, identify the next step as **Request campus access** and explain when it enters review. [Live account form](../lib/features/registration/presentation/pilot_registration_page.dart#L449) |
| P1 | **Profile names the state without consistently explaining the next action.** “Approved · awaiting publication” and “Approved for a different phone” can both lead to **Check status**. The registration page can retain a cached review without identifying it as cached when refresh fails. | Put the practical outcome first. Use **Activate this phone** when approval can be downloaded. For a different phone, explain that the current device needs approval and point to campus help. Mark stale online review as **Last known**. Keep current local access and its role easy to find. [Profile states](../lib/features/registration/presentation/profile_section.dart#L182) · [Refresh handling](../lib/features/registration/presentation/pilot_registration_page.dart#L205) |
| P2 | **Failed Profile saves discard typed edits.** The dialog closes before the network update. Reopening after an error restores the stored values and drops the attempted change. | Keep the form and typed values available until the save is confirmed. Place the error and retry next to the save action. [Profile update](../lib/features/registration/presentation/profile_section.dart#L140) |
| P2 | **Registration startup tells users to retry without a retry button.** When initialization throws, the fields can be unavailable and the user sees an instruction to try again. | Add **Retry** in place and ensure it can restart a failed initialization. Retain a clear route to Home from first run. [Initialization and errors](../lib/features/registration/presentation/pilot_registration_page.dart#L81) |

## User walkthroughs

- **New student on campus.** “Create account” works as an entry point. The change from signed in to application form needs a milestone so the student knows a request still has to be submitted.
- **Returning student who forgot a password.** The sign-in screen reports the failure, but recovery requires leaving the flow. Put reset beside the password field and preserve the email they already entered.
- **Campus responder checking access before going offline.** Seeing the account approval and the phone role split across different rows makes it harder to tell whether this phone is ready. Put current offline capability next to the role and explain what requires internet.

## Smaller refinements

- Group **Personal details**, account settings, and sign-out under clear headings. Keep the immediate approval or phone action above them. [Profile layout](../lib/features/registration/presentation/profile_section.dart#L225)
- Confirm whether the older login/signup routes still have callers before redesigning them. They lead straight to the app shell after authentication, with a different flow from DNSC registration. [App routes](../lib/app/app.dart#L41) · [Legacy login](../lib/features/auth/presentation/pages/login_page.dart#L54)

## Fix sequence and acceptance checks

1. **Protect access to SOS.** Simulate a stalled sign-in and a stalled submission. Verify that a first-run user can reach Home and can later recover the draft or see the true submission result.
2. **Make sign-in recoverable.** A returning user can pick Sign in, correct credentials, or request a reset using the existing email. A first-time user sees the campus application as a distinct step.
3. **Make Profile actionable.** Verify signed-out approved devices, pending review, changes requested, published access for this phone or another phone, and expired or revoked access. Each state should explain the current capability and give one next action.
4. **Verify the mobile layouts.** Check portrait and landscape, the open software keyboard, 200% text, and TalkBack. Test failed saves and retry with an intermittent connection.
