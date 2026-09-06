# Test Pakperk on a physical phone

This guide teaches the ordinary developer loop on a real Android phone and a
real iPhone. It separates three things that are easy to confuse:

- **running the app while you debug it**;
- **running Pakperk's deterministic on-device test harness**; and
- **collecting protected release evidence**.

A successful debug launch is useful development evidence. It is not a signed
release, store acceptance, or the protected four-device acceptance run described
in [Mobile release](mobile-release.md).

## Pick the connection you actually need

| Phone and goal | Recommended connection |
| --- | --- |
| Android phone, guest app, backend on this computer | USB plus `adb reverse` to `http://localhost:8080` |
| Android phone, local accounts too | Reverse API port 8080 and identity port 8081; reverse the public-site and telemetry ports only if the tested flow uses them |
| iPhone, UI or bundled-offline work | Run the dev flavor; the backend may remain unreachable |
| iPhone, live API work | Use a reachable development or staging API with trusted HTTPS |
| Either platform, deterministic app behavior | Run the integration driver; its network, identity, and persistence collaborators are controlled fakes |
| Either platform, realistic identity/two-device/server behavior | Use the protected staging acceptance process, not the deterministic harness |

The asymmetry is intentional. Android's development tooling can reverse a USB
port from the phone to the computer. This repository has no equivalent iPhone
reverse-tunnel setup. On a physical iPhone, `localhost` means the iPhone, not
the Mac.

Unless a paragraph explicitly says otherwise, treat each shell block below as
an independent block that starts at the repository root. Blocks that need the
Flutter project begin with `cd mobile`; do not carry a previous block's working
directory into the next one.

## Before connecting a phone

Start at the repository root. Enter `mobile/`, then confirm the pinned Flutter
installation and host tooling:

```bash
cd mobile
flutter --version
dart --version
flutter doctor -v
flutter pub get --enforce-lockfile
```

The current release evidence is built with Flutter 3.44.8 and Dart 3.12.2.
Pakperk requires Android 7.0/API 24 or newer and iOS 15 or newer. The Android
project compiles and targets API 36, uses Java 17, and pins NDK 28.2.13676358.
Install a JDK 17 and make it visible to Flutter. On a new Android workstation,
also accept the installed SDK licences before expecting a build to work:

```bash
flutter doctor --android-licenses
flutter doctor -v
```

Use a data-capable USB cable, unlock the phone, and keep the screen awake during
the first pairing. A charge-only cable is a surprisingly common reason that no
device appears.

List what Flutter can currently see:

```bash
flutter devices
```

Copy the exact device ID. The examples use an environment variable so every
command targets the intended physical phone:

```bash
export PAKPERK_MOBILE_DEVICE_ID='COPY_THE_DEVICE_ID_HERE'
```

Do not use a broad name such as `android` or `ios` when more than one simulator,
emulator, or phone is connected.

## Android: pair and run the app

### 1. Enable USB debugging

On the phone, enable **Developer options**, then enable **USB debugging**. The
exact menu names vary by manufacturer. Android's official
[hardware-device guide](https://developer.android.com/studio/run/device)
describes the current paths and platform-specific driver requirements.

Connect the unlocked phone. When Android asks whether to allow USB debugging
from this computer, inspect the fingerprint and approve it. Choose “Always allow
from this computer” only on a computer you trust.

On macOS, an extra USB driver is normally unnecessary. Windows can need the
manufacturer's OEM USB driver. Linux can need `plugdev` membership and suitable
udev rules.

### 2. Verify the Android tool sees an authorized device

```bash
adb devices -l
flutter devices
```

The `adb` row must say `device`, not `unauthorized` or `offline`.

If it says `unauthorized`, unlock the phone and respond to the trust prompt. If
the prompt never appears, revoke USB debugging authorizations in Developer
options, disconnect the cable, reconnect, and inspect the new fingerprint. If
it says `offline`, reconnect the phone before considering an `adb` server
restart. Avoid resetting several attached devices when only one cable is bad.

### 3. Start the local guest backend

From the repository root, complete the guest setup in the
[developer guide](developer-guide.md#run-pakperk-locally), then verify:

```bash
curl --fail http://localhost:8080/health/ready
```

### 4. Reverse the API port over USB

```bash
adb -s "$PAKPERK_MOBILE_DEVICE_ID" reverse tcp:8080 tcp:8080
adb -s "$PAKPERK_MOBILE_DEVICE_ID" reverse --list
```

The first `8080` is the port the app opens on the phone; the second is the API
port on the development computer. Keep the app URL as
`http://localhost:8080`. The dev Android network policy permits cleartext only
for `localhost`, `127.0.0.1`, and the emulator-only `10.0.2.2` address. A random
LAN `http://192.168...` URL is therefore both the wrong documented path and
blocked by the app's policy.

### 5. Launch the guest app

Start this block from the repository root:

```bash
cd mobile
flutter run -d "$PAKPERK_MOBILE_DEVICE_ID" \
  --flavor dev \
  --dart-define=PAKPERK_ENV=development \
  --dart-define=PAKPERK_API_BASE_URL=http://localhost:8080 \
  --dart-define=PAKPERK_FULLTEXT_POLICY=prototype
```

This minimal command leaves accounts and other optional product capabilities
off. The installed app is `PakPerk Dev` with Android application ID
`app.pakperk.pakperk.dev`.

After the feed appears, verify the USB mapping from another terminal:

```bash
adb -s "$PAKPERK_MOBILE_DEVICE_ID" reverse --list
curl --fail http://localhost:8080/v1/feed | jq '.items | length'
```

Keep `flutter run` attached, open the DevTools link it prints, select the
**Network** view, refresh the feed, and confirm a successful `GET /v1/feed`.
The API's default compact logs do not print every request path, so grepping
Compose logs for this URL is not a valid test.

A fresh migrated database has no papers, while the app can show its bundled
demo feed. When the test needs server-backed papers, stop the app, run
`./scripts/seed_demo.sh` from the repository root, verify that
`curl --fail http://localhost:8080/v1/feed | jq '.items | length'` is greater
than zero, and relaunch. Run `./scripts/preprocess_demo.sh` only when the test
also needs live prepared Introduction or Connections content.

If the app reports a connection error,
re-run `adb reverse --list`; reversing a port is device-specific and can be lost
when the phone disconnects or restarts.

### 6. Add local accounts only for an account task

Follow [Account authentication](account-authentication.md#reference-development-provider)
first. Use its complete `config/dev.json` backend command—not the account-only
command—so the host API also enables `LIBRARY_ENABLED`,
`LIBRARY_WRITES_ENABLED`, `COMMENTS_ENABLED`, and
`COMMENT_CREATION_ENABLED`. That workflow runs the API on the development
computer and exposes the reference issuer on port 8081. Reverse both ports:

```bash
adb -s "$PAKPERK_MOBILE_DEVICE_ID" reverse tcp:8080 tcp:8080
adb -s "$PAKPERK_MOBILE_DEVICE_ID" reverse tcp:8081 tcp:8081
```

The full checked-in dev profile also points at a public site on port 3000 and a
telemetry endpoint on port 4318. Reverse those ports only when those services
are running and the flow under test needs them:

```bash
adb -s "$PAKPERK_MOBILE_DEVICE_ID" reverse tcp:3000 tcp:3000
adb -s "$PAKPERK_MOBILE_DEVICE_ID" reverse tcp:4318 tcp:4318
```

Then launch the full dev composition:

```bash
cd mobile
flutter run -d "$PAKPERK_MOBILE_DEVICE_ID" \
  --flavor dev \
  --dart-define-from-file=config/dev.json
```

`config/dev.json` turns on accounts, Library, and comments in the app. The API
must enable the matching account, Library read/write, and comment read/creation
switches. A mobile flag does not turn on its backend route, and an enabled
backend route does not make an incompatible mobile build safe.

## iPhone: sign, pair, and run the app

Physical iPhone development requires macOS and Xcode. Flutter's current
[iOS setup guide](https://docs.flutter.dev/platform-integration/ios/setup)
covers Xcode installation, command-line tools, device trust, and signing. A free
personal Apple developer account can sign an app for development on your own
device, subject to Apple's limitations; distribution still needs the protected
Pakperk signing setup.

### 1. Pair the iPhone with Xcode

1. Connect the unlocked iPhone to the Mac with a data-capable cable.
2. Accept **Trust This Computer** on the iPhone and complete any matching Xcode
   pairing prompt.
3. Add your Apple ID in Xcode's Accounts settings if it is not already present.
4. On the iPhone, enable **Developer Mode** under **Settings > Privacy &
   Security**, restart when prompted, and confirm after restart. Apple documents
   why this is required in [Enabling Developer Mode on a
   device](https://developer.apple.com/documentation/Xcode/enabling-developer-mode-on-a-device).
5. Confirm that Xcode and then Flutter can see the device:

   ```bash
   cd mobile
   flutter devices
   ```

The first Flutter debug launch can ask for Local Network access. Allow it while
developing so hot reload, DevTools, and the Dart VM service can connect. Flutter
explains that prompt in its [iOS debugging
guide](https://docs.flutter.dev/platform-integration/ios/ios-debugging).

### 2. Provide a development team without committing it

Create the gitignored file `mobile/ios/Flutter/LocalSigning.xcconfig` with only
this development setting:

```text
PAKPERK_DEVELOPMENT_TEAM = YOUR_APPLE_TEAM_ID
```

Use the Team ID, not the Apple ID email address. Do not copy distribution
certificate names or provisioning-profile values into source control. The
checked-in `LocalSigning.xcconfig.example` documents protected release signing
and includes manual distribution settings; those extra settings are not needed
for an ordinary debug build.

The dev flavor expects bundle identifier `app.pakperk.pakperk.dev`. If Apple's
signing service says that identifier is unavailable to your personal team, the
problem is not the USB connection. Obtain access to the Pakperk development
team, or coordinate a deliberate development bundle-identifier change with the
maintainer. Silently changing only one Xcode field would break the repository's
flavor, callback, and release assumptions.

### 3. Choose offline UI work or a live HTTPS API

The dev iOS configuration allows cleartext HTTP only for `localhost`, and
`localhost` on the phone is the phone. The repository does not provide a USB
reverse tunnel for iOS.

For UI, navigation, animation, or bundled-offline work, the dev app can still
run with the default local URL even though the Mac API is unreachable:

```bash
cd mobile
flutter run -d "$PAKPERK_MOBILE_DEVICE_ID" \
  --flavor dev \
  --dart-define=PAKPERK_ENV=development \
  --dart-define=PAKPERK_API_BASE_URL=http://localhost:8080 \
  --dart-define=PAKPERK_FULLTEXT_POLICY=prototype
```

Expect the app to use its labeled bundled demo content and to report live
network unavailability honestly. Do not interpret that launch as an API test.

For live guest API work, use a development server the iPhone can reach through
trusted HTTPS:

```bash
cd mobile
flutter run -d "$PAKPERK_MOBILE_DEVICE_ID" \
  --flavor dev \
  --dart-define=PAKPERK_ENV=development \
  --dart-define=PAKPERK_API_BASE_URL=https://YOUR-DEV-API-HOST \
  --dart-define=PAKPERK_FULLTEXT_POLICY=prototype
```

Do not work around this with a broad App Transport Security exception or by
disabling certificate validation. A stable HTTPS staging deployment is the
right environment for live OIDC: the issuer in discovery, browser redirect,
token, API validation configuration, and app defines must be exactly the same
public issuer.

If the protected staging services and signing identity are available, run the
repository's complete staging composition:

```bash
cd mobile
flutter run -d "$PAKPERK_MOBILE_DEVICE_ID" \
  --flavor staging \
  --dart-define-from-file=config/staging.json
```

That command assumes the real staging API, identity provider, public site,
telemetry origin, associated-domain files, and compatible backend flags exist.
It does not create them.

## Use hot reload without confusing it with a restart

While `flutter run` is attached:

- press `r` for hot reload after ordinary Dart UI changes;
- press `R` for a full hot restart when initialization or dependency setup
  changed; and
- stop and relaunch after changing flavors, native Android/iOS files, signing,
  entitlements, or `--dart-define` values.

Hot reload preserves much of the running state. That is helpful for iteration
but unsuitable for proving cold-start, database migration, authentication
restore, or process-death behavior.

## Run deterministic tests on the phone

The integration driver exercises a repeatable set of Flutter behaviors with
controlled collaborators. Its gesture sequences are generated by Flutter's
`WidgetTester`; its lifecycle and memory-warning events are controlled test
stimuli. They exercise app code deterministically, not a human operator's touch,
an OS process kill, or real memory pressure. The suite also covers large cached
feeds, pagination, bounded readers, SQLite workload, packet loss, outbox
recovery, comment pagination, reduced motion, and strict cache masking.

For an ordinary developer run using the dev identity:

```bash
cd mobile
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/production_verification_test.dart \
  --flavor dev \
  --dart-define-from-file=config/dev.json \
  --profile \
  -d "$PAKPERK_MOBILE_DEVICE_ID"
```

For a shorter demonstration-flow run:

```bash
cd mobile
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/demo_flows_test.dart \
  --flavor dev \
  --dart-define-from-file=config/dev.json \
  -d "$PAKPERK_MOBILE_DEVICE_ID"
```

The repository's canonical physical-device probe uses the production flavor:

```bash
cd mobile
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/production_verification_test.dart \
  --flavor prod \
  --dart-define-from-file=config/prod.json \
  --profile \
  -d "$PAKPERK_MOBILE_DEVICE_ID"
```

On Android this profile build uses development/debug signing. On iOS it needs a
development team and provisioning profile authorized for the production bundle
identifier and Associated Domains entitlement; a personal team may not have
that access. Neither profile build is release-signing evidence. A dev-flavor
result is still useful developer feedback, but it is not a substitute for the
canonical production-flavor probe.

Setting `PAKPERK_MOBILE_DEVICE_ID` before `./scripts/check.sh` makes the complete
repository check include that canonical probe. It is intentionally expensive.

The deterministic driver does **not** test a real identity provider, live
backend, second installed device, OS process kill, account deletion, real model
provider, store candidate, or representative human performance window. Those
belong to the protected staging and release workflows.

## Run the iOS native data-protection test

On a connected iPhone with development signing configured:

```bash
cd mobile
xcodebuild test -quiet \
  -project ios/Runner.xcodeproj \
  -scheme dev \
  -configuration Debug-dev \
  -destination "platform=iOS,id=$PAKPERK_MOBILE_DEVICE_ID" \
  -disableAutomaticPackageResolution
```

This is a native test in addition to, not a replacement for, the Flutter suite.

## Perform a useful manual pass

Record the app flavor, source revision, phone model, OS version, connection
shape, and backend revision before testing. Then check the surfaces affected by
your change, including:

1. The home icon and display name identify `PakPerk Dev`, `PakPerk Staging`, or
   Pakperk production as expected.
2. Cold launch, background/foreground, and a full relaunch behave correctly.
3. The feed loads; the DevTools Network view shows a successful `/v1/feed`
   request when this is a live-backend run.
4. Vertical scrolling, horizontal paper gestures, taps, back navigation, and
   interruption mid-gesture behave naturally.
5. Airplane mode or a severed backend connection produces an honest offline
   state, and reconnecting recovers without duplicate actions.
6. Dark appearance, larger text, reduced motion, screen-reader focus, and a
   physical keyboard where relevant remain usable.
7. Account login returns from the system browser to the correct custom callback
   scheme. Library and comments appear only when both app and backend enable
   them.
8. A `pakperk://` link opens the expected destination. The dev iOS build does
   not claim a production associated domain, so the custom scheme is the
   reliable local check.

The first checked-in demo paper has ID
`387fc70a-a95a-4c45-aa9d-f6252934da33`. With the dev app installed, launch its
custom URL explicitly. Android:

```bash
adb -s "$PAKPERK_MOBILE_DEVICE_ID" shell am start -W \
  -a android.intent.action.VIEW \
  -d 'pakperk://paper/387fc70a-a95a-4c45-aa9d-f6252934da33' \
  app.pakperk.pakperk.dev
```

iPhone:

```bash
xcrun devicectl device process launch \
  --device "$PAKPERK_MOBILE_DEVICE_ID" \
  --terminate-existing \
  --payload-url 'pakperk://paper/387fc70a-a95a-4c45-aa9d-f6252934da33' \
  app.pakperk.pakperk.dev
```

The expected result is the Attention Is All You Need paper, which is present in
the checked-in bundled feed even when the backend is unavailable. This proves
custom-scheme routing; it does not prove universal links or server data.

Do not log access tokens, passwords, paper full text, prompts, comments,
reports, or identity attributes while collecting evidence.

## Reset only when the test requires a clean install

The following commands delete app-owned state on the selected phone. Sign out
first when the test account matters, and confirm the application ID before
running them.

Android dev flavor:

```bash
adb -s "$PAKPERK_MOBILE_DEVICE_ID" shell pm clear app.pakperk.pakperk.dev
```

iPhone dev flavor:

```bash
xcrun devicectl device uninstall app \
  --device "$PAKPERK_MOBILE_DEVICE_ID" \
  app.pakperk.pakperk.dev
```

Uninstalling an iOS app does not guarantee that every Keychain item disappears.
Treat authentication restoration as a separate test and use provider-side
account cleanup only through the documented deletion process.

## Troubleshooting map

| Symptom | What it usually means | First check |
| --- | --- | --- |
| No Android row | Cable, driver, or Developer options problem | `adb devices -l` |
| Android says `unauthorized` | RSA trust prompt was not approved | Unlock phone and inspect prompt |
| Feed works in browser but not Android app | USB reverse is absent or attached to another device | `adb -s "$PAKPERK_MOBILE_DEVICE_ID" reverse --list` |
| LAN HTTP URL is blocked on Android | Dev policy permits only documented loopback hosts | Use `adb reverse` and `http://localhost:8080` |
| Xcode sees iPhone but Flutter cannot launch | Developer Mode, team, certificate, or profile problem | `flutter doctor -v` and Xcode signing details |
| iPhone cannot reach Mac API | Phone-local `localhost` is not Mac-local | Use reachable trusted HTTPS |
| App exits at startup | Flavor/environment or capability dependency mismatch | Inspect `flutter run` output and supplied defines |
| Account browser succeeds but app stays signed out | Issuer/client/callback mismatch | Compare public issuer and flavor-specific callback exactly |
| Test passes but live login fails | Deterministic harness used controlled fakes | Run the protected live staging scenario |

The official [Flutter Android setup
guide](https://docs.flutter.dev/platform-integration/android/setup), Android
[`adb` reference](https://developer.android.com/tools/adb), and [Flutter iOS
setup guide](https://docs.flutter.dev/platform-integration/ios/setup) are the
best references when the operating-system tooling itself changes. The
Pakperk-specific flavor, policy, signing, and test commands above come from this
repository and should change with the implementation.
