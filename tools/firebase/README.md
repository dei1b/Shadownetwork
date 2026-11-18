# DNSC Firebase emulator setup

Use Node.js, Java, and the Firebase CLI from the repository root. The demo project uses local Authentication and Firestore. It needs no Firebase login, cloud project, or billing account. Use synthetic records.

```powershell
firebase.cmd emulators:exec --only auth,firestore --project demo-shadownetwork-dnsc "node tools/firebase/pilot-smoke.mjs"
```

The test checks that a student can submit an application, a reviewer can read it, and a different student is denied access.

The pilot uses text-only applications and manual review. The Windows reviewer workflow is a separate implementation step.

[Firebase demo projects](https://firebase.google.com/docs/emulator-suite/connect_auth)

## Try registration on Android

From the repository root, start the local services.

```powershell
firebase.cmd emulators:start --only auth,firestore --project demo-shadownetwork-dnsc
```

In a second terminal, run a debug build on the Android emulator.

```powershell
flutter run --dart-define=DNSC_EMULATOR_HOST=10.0.2.2
```

For a USB-connected test phone, forward ports 9099 and 8080 with `adb reverse tcp:PORT tcp:PORT`, then use `DNSC_EMULATOR_HOST=127.0.0.1`.

Open DNSC test registration during onboarding or from Profile. Create a synthetic test account and fill in the student details. Save the draft, reopen the page, and submit. An unconfirmed submission can be retried using the same draft. If you restart the Firebase emulators without preserving their data, create a new test account.

Registration binds a submission to the phone's signed registration record. Server challenge verification and Windows review are separate implementation steps.

## Live Firebase build

Live registration uses HTTPS and checks the configured project ID. Create the default Firestore database, enable Email/Password Authentication, and deploy the Firestore rules to the intended project. The text-only registration flow uses Authentication and Firestore and can run on Spark.

```powershell
flutter build apk --release --dart-define=DNSC_FIREBASE_PROJECT=shadownetwork-b2086
```

## Review applications in PC Admin

Open **Devices → Requests** and sign in with an existing Email/Password Firebase account with the `admin: true` custom claim. The project owner grants reviewer claims through a privileged Firebase account. Use a separate student test account to submit applications.

Expand an application to review its student details and signed phone ID. Select **Review and approve**, choose **Student** or **Campus responder**, and select **Approve and publish**. The approval records the role and publishes signed access to that phone. A correction request or rejection requires a reason. Firebase checks the status and revision, and each decision appends an audit entry. Refresh after a conflicting update.

On Android, open DNSC registration to check the result automatically. **Check review status** lets you refresh manually. After a correction request, edit the requested details and submit again using the same phone keys.

## Publish and activate signed access

Run publication on the PC that holds the existing administrator signing identity. If approval succeeds and publication needs a retry, open the approved request and select **Publish signed access**. Firestore commits the new directory and the applicant's Published status together.

For an Android build that can bootstrap trust on a fresh phone, set `DNSC_ISSUER_FINGERPRINT` to the full public fingerprint shown in **Backup & recovery** on the trusted signing PC. An Android phone with a previously pinned issuer can use that verified issuer. The signed directory also identifies its Firebase project.

GitHub Actions reads the Firebase project from `android/app/google-services.json` and the campus issuer fingerprint from the repository variable `DNSC_ISSUER_FINGERPRINT`. The issuer fingerprint identifies the PC Admin directory key. The APK signing certificate uses its own repository variable.

Before publishing, PC Admin verifies the existing signed directory and checks that the local registry includes its users and revocations. If the registry is stale, restore the latest backup before trying again. If another reviewer publishes during the current attempt, refresh and retry against the new directory.

After publication, the applicant opens DNSC registration on the registered phone. It loads the last known review and checks for changes online. Android also checks for directory updates when the app resumes and every two minutes in the foreground. Offline phones use their saved verified trust state until it expires. Keep the signing identity backup available to recover the publisher.

For offline enrollment or an administrator-provided approval code, open **Profile → Settings → Advanced → Backup registration**. The enrollment QR contains the phone ID and public keys. The reviewing administrator enters the owner details. The phone can scan, paste, or enter an approval code on the same page.

For a Windows build, pass the project ID and the existing Firebase client API key as Dart defines. The API key identifies the Firebase project. Reviewer access comes from the signed-in account claim.

```powershell
flutter build windows --release -t lib/admin_desktop_main.dart --dart-define=DNSC_FIREBASE_PROJECT=shadownetwork-b2086 "--dart-define=DNSC_FIREBASE_API_KEY=$clientApiKey"
```
