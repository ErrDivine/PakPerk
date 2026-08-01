# Mobile release procedure

This is the release contract for Pakperk mobile `0.2.0+2`. Production v0.0 is
a milestone name; it does not permit lowering the package or store build
version.

## Artifact identity matrix

| Environment | Android application ID | iOS bundle ID | OIDC callback | App-link host |
| --- | --- | --- | --- | --- |
| development | `app.pakperk.pakperk.dev` | `app.pakperk.pakperk.dev` | `pakperk-auth-dev` | loopback HTTP only |
| staging | `app.pakperk.pakperk.staging` | `app.pakperk.pakperk.staging` | `pakperk-auth-staging` | `staging.pakperk.app` |
| production | `app.pakperk.pakperk` | `app.pakperk.pakperk` | `pakperk-auth` | `pakperk.app` |

Debug builds must not default to production. Staging and production permit
HTTPS only. Android backup/restore is disabled for every flavor. iOS excludes
Documents, Preferences, Application Support, SQLite sidecars, and descendants
from backup and applies `completeUntilFirstUserAuthentication` data protection
on devices.

## Current platform submission contract

The final artifact, not a Gradle or Xcode default, must prove these values:

- Android uses minimum API 24 and compile/target API 36. Google Play requires
  Android 16/API 36 for new phone/tablet apps and updates beginning
  [August 31, 2026](https://developer.android.com/google/play/requirements/target-sdk).
- Android native compilation is pinned to NDK `28.2.13676358`; changing that
  input requires rebuilding and re-running both archive alignment checks.
- Because Pakperk packages native shared libraries, both APK and AAB must have
  every `arm64-v8a` and present `x86_64` ELF `LOAD` segment aligned to at least
  16 KiB. The APK must also pass `zipalign -c -P 16 -v 4`. Google Play's
  [16 KiB compatibility requirement](https://developer.android.com/guide/practices/page-sizes)
  has applied since November 1, 2025 to new apps and updates targeting API 35
  or later.
- iOS uses a deployment target of 15.0. Apple identifies iOS 15 as the lower
  bound of Xcode 26's supported App Store upload range in its
  [Xcode system requirements](https://developer.apple.com/xcode/system-requirements).
  Since [April 28, 2026](https://developer.apple.com/news/upcoming-requirements/?id=02032026a),
  uploaded iOS apps must be built with Xcode 26 or later and the iOS 26 SDK or
  later.

`verify_android_release_artifacts.sh` emits and requires minimum 24,
compile/target 36, one numerically newest complete Build-Tools installation,
16 KiB APK ZIP alignment, and 16 KiB native ELF alignment. It rejects
debuggable/test-only archives, the Android debug certificate, multiple APK
signers, and APKs without both v2 and v3/v3.1 signatures. Its AAB check trusts
the extracted signer only in a temporary truststore so a normal self-signed
Android upload certificate is accepted, while strict JAR integrity, complete
signing, modern algorithms, and APK/AAB fingerprint parity remain mandatory.

`verify_ios_release_artifact.sh` emits the Xcode, SDK, platform, and minimum-OS
metadata from the signed IPA and requires Xcode/iOS SDK 26+, exactly iOS 15.0, an
unexpired App Store provisioning profile (not development, ad hoc, or
enterprise), profile-authorized signed entitlements, an exact application
identifier, the environment's exact ATS policy, and the source-equivalent,
tracking-false app privacy manifest. A local simulator build currently records
Xcode 26.6 (`DTXcode=2660`) and SDK 26.5; that is source/simulator evidence only,
not a substitute for the signed `iphoneos` IPA gate or App Store acceptance.

## Reproducible checks and builds

Use Flutter `3.44.8` at framework revision
`058e0af2c2b57e369d905a03ac9748b0ebf543c6` with its bundled Dart `3.12.2`, the
exact stable SDK identity checked before dependency resolution in release
workflows and the full local check. A different local SDK is development
evidence only; release metadata generation fails closed when its resolved SDK
differs from the workflow pin.

Native Android dependency resolution and release builds use the hosted arm64
macOS runner's `JAVA_HOME_17_arm64` only after it reports Eclipse Adoptium
Temurin `17.0.19+10`; Ubuntu security evidence independently uses
`JAVA_HOME_17_X64`. Both retain `java -version`, and runner drift blocks release.
Before any gem installation or Bundler execution, the signed candidate requires
MRI Ruby `3.4.10` (`RUBY_ENGINE=ruby`) with RubyGems `4.0.17` and records the
resolved executable and versions. Store upload uses Bundler `2.6.9` downloaded
from RubyGems, verified against its reviewed SHA-256 before local installation,
then a frozen Fastlane `2.235.0` graph whose every gem has a lockfile checksum.

Launcher PNGs are deterministic outputs of the canonical
`mobile/assets/brand/pakperk_app_icon.svg`. With `rsvg-convert` and
ImageMagick's `magick` installed, regenerate them from the repository root
before a branded release whenever the SVG changes:

```sh
./scripts/generate_mobile_icons.sh
```

Do not edit generated PNGs directly. The generator enforces dimensions and
opacity; source tests require Android legacy, round, adaptive, and themed
monochrome declarations and a complete opaque iOS AppIcon catalog.

Run from `mobile/` with the repository-locked dependency graph:

```sh
flutter pub get
flutter analyze
flutter test

flutter build apk --debug --flavor dev --dart-define-from-file=config/dev.json
flutter build apk --debug --flavor staging --dart-define-from-file=config/staging.json
flutter build apk --debug --flavor prod --dart-define-from-file=config/prod.json

flutter build ios --simulator --debug --flavor dev --dart-define-from-file=config/dev.json
flutter build ios --simulator --debug --flavor staging --dart-define-from-file=config/staging.json
flutter build ios --simulator --debug --flavor prod --dart-define-from-file=config/prod.json
```

For every staging or production artifact, inspect the built artifact rather
than trusting source configuration:

```sh
dart run tool/verify_strict_artifact_assets.dart PATH_TO_APK_AAB_IPA_OR_APP
```

The verifier requires metadata, legal fallbacks, and native launcher assets.
It rejects every bundled prototype-derived asset by path, content hash, or
unapproved asset path, as well as stock Flutter launchers or incomplete Android
legacy/round/adaptive/monochrome and iOS packaged icon sets. The development
flavor intentionally retains reviewed demo-derived fallbacks and is not a
strict artifact. Signed-artifact verification additionally requires the iOS
1024x1024 marketing rendition to be opaque.

`PAKPERK_TERMS_DOCUMENT_VERSION` and
`PAKPERK_COMMUNITY_GUIDELINES_DOCUMENT_VERSION` in each flavor configuration
are build-time bindings to the publication markers in the bundled acceptance
documents. A mismatched build configuration is rejected, a server advertising
a newer version disables acceptance until an updated app is installed, and the
signed-release evidence records both exact versions. Staging and production
signing also require both bundled versions to equal the protected
`PAKPERK_PUBLIC_DOCUMENT_VERSION` used by public-edge verification.

Run the native iOS protection test on an available simulator (replace the
destination ID):

```sh
xcodebuild test -quiet \
  -project ios/Runner.xcodeproj \
  -scheme dev \
  -configuration Debug-dev \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -disableAutomaticPackageResolution
```

The simulator verifies recursive backup exclusion. The same test retains an
additional file-protection-class assertion when it runs on a physical device,
because the simulator filesystem does not expose iOS data-protection classes.

## Protected signing inputs

Never commit signing material or substitute a debug/personal identity.

The manual `signed-mobile-release` workflow binds its single job to the chosen
protected GitHub environment. Dispatch it from `main` with the reviewed full
commit SHA; the job rejects any checkout that is not that exact lowercase SHA
or is not reachable from `origin/main` before it reads protected inputs.
Configure these environment secrets:

- Android build signing: `PAKPERK_ANDROID_KEYSTORE_BASE64`,
  `PAKPERK_ANDROID_STORE_PASSWORD`, `PAKPERK_ANDROID_KEY_ALIAS`, and
  `PAKPERK_ANDROID_KEY_PASSWORD`.
- Installed Play identity for staging/production association files:
  `PAKPERK_ANDROID_APP_SIGNING_SHA256`.
- Apple signing: `PAKPERK_IOS_DISTRIBUTION_CERTIFICATE_BASE64`,
  `PAKPERK_IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`,
  `PAKPERK_IOS_PROVISIONING_PROFILE_BASE64`,
  `PAKPERK_DEVELOPMENT_TEAM`, and
  `PAKPERK_IOS_PROVISIONING_PROFILE_SPECIFIER`.
- Store upload, required only when `upload_to_stores=true`:
  `PAKPERK_GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64`,
  `PAKPERK_APP_STORE_CONNECT_ISSUER_ID`,
  `PAKPERK_APP_STORE_CONNECT_KEY_ID`, and
  `PAKPERK_APP_STORE_CONNECT_PRIVATE_KEY_BASE64`.

Environment reviewers must independently read the highest uploaded build in
each store and enter it in the workflow inputs. The job requires checked-in
build `2` to be greater than both values; it cannot infer private store history
when upload credentials are intentionally withheld.

Android release builds require all of:

- `PAKPERK_ANDROID_STORE_FILE`
- `PAKPERK_ANDROID_STORE_PASSWORD`
- `PAKPERK_ANDROID_KEY_ALIAS`
- `PAKPERK_ANDROID_KEY_PASSWORD`

An untracked `android/key.properties` with the keys shown in
`android/key.properties.example` is the local equivalent. Gradle fails any
release task when values are absent or partial. Produce signed candidates with:

```sh
flutter build appbundle --release --flavor dev --dart-define-from-file=config/dev.json
flutter build appbundle --release --flavor staging --dart-define-from-file=config/staging.json
flutter build appbundle --release --flavor prod --dart-define-from-file=config/prod.json
```

iOS `Release-*` configurations force manual Apple Distribution signing and
require protected settings supplied by CI or the gitignored
`ios/Flutter/LocalSigning.xcconfig`:

- `PAKPERK_DEVELOPMENT_TEAM`
- `CODE_SIGN_STYLE = Manual`
- `CODE_SIGN_IDENTITY = Apple Distribution`
- `PROVISIONING_PROFILE_SPECIFIER`

The checked-in example contains placeholders only. Build signed candidates:

```sh
flutter build ipa --release --flavor dev --dart-define-from-file=config/dev.json
flutter build ipa --release --flavor staging --dart-define-from-file=config/staging.json
flutter build ipa --release --flavor prod --dart-define-from-file=config/prod.json
```

Before either upload, compare `0.2.0+2` with the highest uploaded store version
and build number. Increment the checked-in package version if it is not
strictly newer; store history is external and cannot be inferred from Git.

## Association and signed-artifact gate

The workflow extracts the Android package/version and **upload-key** certificate
from both locally signed artifacts and requires the AAB and APK to match. That
certificate is upload authorization evidence only: with Play App Signing,
Google signs installed APKs with the distinct app-signing certificate. Read its
SHA-256 fingerprint from the protected Play Console record and store it as
`PAKPERK_ANDROID_APP_SIGNING_SHA256`; never substitute the upload-key digest in
`assetlinks.json`. The workflow extracts the Apple team/bundle identity from
the signed IPA/profile. Render the protected association files, then run the
repository verifier described in `docs/mobile-app-links.md`:

```sh
PAKPERK_RELEASE_ENV=production \
PAKPERK_ANDROID_PACKAGE=app.pakperk.pakperk \
PAKPERK_ANDROID_SHA256="$PLAY_APP_SIGNING_SHA256" \
PAKPERK_APPLE_TEAM_ID="$APPLE_TEAM_ID" \
PAKPERK_APPLE_BUNDLE_ID=app.pakperk.pakperk \
./scripts/verify_mobile_associations.sh \
  assetlinks.json apple-app-site-association
```

Release is blocked unless both deployed `/.well-known/` URLs return HTTP 200
directly, use `application/json`, exactly match those signed identities, and
open valid `/p/*` and `/arxiv/*` links on physical devices. Redirects,
wildcards, stale fingerprints, or placeholder values fail the gate.

Retain both Android identities in evidence: the verifier's
`android_upload_sha256` proves which protected key produced the candidate, and
`android_play_app_signing_sha256` proves which certificate the installed Play
app will present to Android link verification.

The signed Android evidence must also retain `android_min_sdk=24`,
`android_compile_sdk=36`, `android_target_sdk=36`, the selected Build-Tools
version, `android_apk_zip_alignment=16384`, and the per-archive native-library
counts plus `android_native_elf_load_alignment=16384`. The signed Apple
evidence must retain the emitted Xcode/SDK/minimum-OS values, provisioning
profile expiration, entitlement result, and packaged privacy-manifest result.

### Protected mobile feature flags

The checked-in production config keeps accounts, library, and comments off.
The checked-in staging fixture enables them so ordinary debug builds exercise
the complete feature composition, but it is never used unchanged for a signed
candidate. For both staging and production, the signed-candidate workflow
materializes a temporary build config and defaults every protected feature to
off unless these GitHub environment variables explicitly enable it:

- `PAKPERK_ACCOUNTS_ENABLED`
- `PAKPERK_LIBRARY_ENABLED`
- `PAKPERK_COMMENTS_ENABLED`

Each value must be exactly `true` or `false`; an absent value resolves to
`false`. Library or comments cannot be enabled unless accounts is also true.
Define them on the protected `staging` and `production` environments, require
release reviewers/branch restrictions there, and change them only through the
release approval record. They are non-secret variables, never dispatch inputs
or repository defaults. The workflow retains their three booleans in
`mobile-feature-flags.json` and builds both platforms from that same generated
config. Keep the independently controlled backend read/write/creation flags
compatible; a mobile flag does not authorize a server capability.

## Mobile verification lanes

The ordinary CI and signed-candidate workflow run `dart format`,
`flutter analyze`, and the complete `flutter test` suite. That suite includes
the headless deterministic production harness. It proves local state-machine,
cache, outbox, paging, policy, and bounded-widget invariants with controlled
fixtures; it is not physical-device or deployed-service evidence.

The manually dispatched `mobile-device-integration` workflow runs the same
deterministic harness in profile mode on an explicitly selected physical
Android or iOS device. The protected runner rejects emulators and retains a
closed platform/OS-version record, at least 20 engine frame samples, a
30-record cached first page plus six deterministic cursor pages covering
exactly 200 records, 10 generated Flutter drags and 10 generated Flutter
flings, a file-backed 500-paper/100-save SQLite measurement including its
WAL/SHM files, and a machine-readable scope file. It never uploads the raw
Flutter log, device ID, or user-assigned device name; the dispatch ID is masked
in workflow output. Generated `WidgetTester` gestures exercise Flutter's
pointer, gesture-arena, scrolling, and page-commit paths on the selected
device, but do not count as operator/OS-driver gestures under representative
network conditions. Its performance JSON is classified as a fixture workload
and must not be used as staging p95 or signed-candidate evidence. Configure
required reviewers and deployment-branch restrictions on the fixed
`mobile-device-verification` GitHub environment before attaching a runner; the
YAML name alone does not make an environment protected. Store the exact Flutter
device identifier only as that environment's `PAKPERK_MOBILE_DEVICE_ID` secret;
never pass it as a workflow-dispatch input because run metadata retains inputs
outside log masks. Dispatch also requires an explicit full lowercase
`source_revision` equal to the selected `main` revision and fetched
`origin/main` tip, plus the exact confirmation phrase. This prevents a green
fixture probe from being attached to a different source revision.

The separate manually dispatched `protected mobile acceptance` workflow is the
automated entrypoint for the live staging/device lane. It accepts only an exact
main-tip source revision plus exact `sha256:` candidate and signed-release
provenance content IDs, runs exclusively in the protected
`mobile-device-verification` environment, and invokes the fixed
`/opt/pakperk/bin/pakperk-mobile-acceptance-driver` only after all of `/`,
`/opt`, `/opt/pakperk`, and `/opt/pakperk/bin` are root-owned and non-writable
outside root and an open-descriptor identity/digest check matches
`PAKPERK_MOBILE_ACCEPTANCE_DRIVER_SHA256`. The workflow fixes its command path
to `/usr/bin:/bin`; the pinned driver must use absolute, reviewed paths for any
Android SDK or other runner tools outside those system directories.

The candidate content ID must resolve to a canonical, root-owned manifest at
`/opt/pakperk/mobile-candidates/<digest>.json`. That manifest binds the source,
staging environment, app version/build, strict flavor, Android and iOS install-
artifact hashes, the exact staging application ID
`app.pakperk.pakperk.staging`, signer digests, Apple team ID, and its provenance
content ID. The provenance must independently resolve beneath
`/opt/pakperk/mobile-release-provenance/<digest>.json` and exactly bind the AAB,
APK, and IPA SHA-256 values to repository `ErrDivine/PakPerk`, workflow
`.github/workflows/mobile-release.yml`, job `signed-candidate`, the reviewed
workflow/source SHA, GitHub run ID/attempt, and stage `artifacts_verified`.
Coordinates are read from the reviewed `mobile/config/staging.json`; mutable
coordinate and package/bundle-ID variables are not accepted.

The signed-release job emits canonical candidate and provenance files and their
content IDs, but it cannot install them into a self-hosted runner's protected
filesystem. After authenticated artifact retrieval, a runner administrator must
verify the canonical-file digests and import them with root ownership, one link,
and no group/world write permission into the fixed content-addressed roots. The
non-root runner still needs read access; mode `0444` is the simple reviewed
installation choice because these manifests contain identities and hashes, not
credentials. This authenticated root-side import is an external operational
boundary, not an action performed or proven by the repository workflow.

The protected environment variable `PAKPERK_MOBILE_RUNNER_SESSION_ID` must also
name a canonical root-owned attestation at
`/opt/pakperk/mobile-runner-sessions/<digest>.json`. Its closed schema binds the
exact integer `schema: 1`, classification
`dedicated ephemeral mobile acceptance runner session`, source revision, opaque
session and host-identity hashes, runner class
`dedicated-macos-physical-mobile`, exact `dedicated: true` and `ephemeral: true`
flags, a closed `physical_identities` map with one distinct root-keyed commitment
for each required role, and a creation/expiry interval no longer than eight
hours. The same protected-parent, root-owner, one-link, non-writable, canonical-
digest rules apply. The validator rejects an expired attestation. Creating and
root-installing this attestation, isolating the host for the session, and
destroying its disposable state afterward remain runner-administrator
responsibilities.

The protected runner exposes four distinct installed-device secrets to the
root-owned, digest-pinned driver: an Android gesture-navigation phone, an
Android three-button phone, an iPhone with a home indicator, and a physical-
keyboard iPad that is also the independent second synchronization installation.
Test accounts and passwords are environment secrets and are never written into
the request or evidence.

The driver must automate every path below against disposable staging accounts
and emit the closed `mobile-acceptance-evidence.json` contract:

1. Cold launch from populated local cache and collect first-readable-frame and
   native-launch continuity measurements.
2. Vertically swipe through at least 20 papers under controlled latency and
   packet loss; record blank cards and sequential cache hits.
3. Confirm Introduction preparation begins only after explicit horizontal
   intent.
4. Switch Read -> You -> Read and restore the exact paper, stage, and offsets.
5. Complete system-browser OIDC with PKCE against the release tenant.
6. Save, terminate/relaunch the installed app, reconnect, and verify sync.
7. Verify the same save on a second independently installed test device.
8. Post, edit, and delete a comment against staging.
9. Report and block another dedicated test account, confirming immediate and
   server-persisted hiding.
10. Expire the real access token, verify one refresh, and continue the action.
11. Reauthenticate for account deletion and verify immediate deactivation,
    session revocation, provider cleanup, and the deletion status path.
12. Read and save offline, terminate/relaunch if part of the test matrix, then
    verify same-UUID outbox recovery after connectivity returns.
13. Repeat cold/warm startup with reduced motion and verify stationary bounded
    transitions.
14. Use the strict signed flavor and verify metadata/save/comments/original
    arXiv links remain while every cached derived fallback stays masked.

The validator requires exact source, app version/build, candidate and driver
digests; the signed-release provenance and ephemeral runner-session bindings;
the staging API/OIDC/client coordinates read from `mobile/config/staging.json`;
the four ordered physical-device roles; distinct installation and physical-
identity hashes; sanitized hardware model and OS versions; and all 16 ordered
scenarios. Those are the 14 paths above plus root-navigation safe-area/system-
back coverage across the required navigation modes and physical-keyboard Tab/
Shift-Tab/Enter/Escape coverage. A scenario passes only with its exact device-
role assignment, exact ordered assertion-ID list (70 markers in total), and
closed integer threshold/equality metrics (37 rules in total); a generic
positive count is not accepted. Every Android role must identify an
installation of the provenance-bound APK; every iOS role must identify the
provenance-bound IPA. Each device must also echo the exact staging application,
signer, and Apple team binding for its platform.

For each role, the driver derives a run-specific `device_identity_hash` without
retaining a serial or other raw identifier. It first computes a stable secret as
`HMAC-SHA256(root_owned_device_identity_key, platform || NUL || raw_id)`, then
places that stable secret as the role's root-attested commitment, and computes
`HMAC-SHA256(run_challenge, stable_secret)` for evidence. The validator performs
the second computation itself and never copies the stable commitments into the
request binding or retained evidence. Because the role is not part of the
derivation, reusing one physical device for two roles produces the same
commitment and is rejected. The public challenge makes retained hashes
change across runs, while the root-owned key prevents one from becoming a
direct serial-number oracle. Evidence still intentionally identifies the
runner session and can therefore be correlated when one attestation is reused.
All four hashes and all four installation hashes must be distinct. Raw device
identifiers stay only in protected process environment and must not appear in
request, evidence, logs, or artifacts.

Evidence schema v2 is also bound to a fresh cryptographic challenge, GitHub run
ID and attempt, and whole-second UTC not-before time. Validation limits the run
to six hours, rejects stale/replayed completion, duplicate or noncanonical JSON,
non-finite numbers, extra fields, credential-shaped strings, symlinks,
oversized evidence, partial scenarios, and failed paths. The validator packages
the exact already-read canonical bytes and checksum by directly creating the
final archive with exclusive-open semantics. It checks the final inode, owner,
mode `0400`, link count, size, and SHA-256, then repeats the structural and
digest checks immediately before upload. The local tar digest is bound into the
artifact name; the final step also requires the upload action's separate
artifact-container digest. The owner-only driver log is trapped and discarded,
while device serials, credentials, handles, and comment/query text are excluded.

A release owner must dispatch this workflow for the exact installed signed
candidate and attach its immutable artifact plus the protected-environment
approval. The checked-in orchestration and validators do not prove that the
runner-managed driver, staging tenant, accounts, or devices were available, and
an undispatched workflow, repository test, simulator, or operator statement
does not complete this lane.

## Telemetry and release-candidate gates

Production telemetry uses only the exact HTTPS `/v1/logs` OTLP endpoint. The
mobile exporter sends no authorization header, cookie, user/device/session ID,
paper ID, handle, content, token, raw exception message, or stack. Events and
attributes pass a closed vocabulary; payloads are at most 16 KiB, requests
have a two-second deadline, responses are cancelled without buffering, at most
two exports are in flight, and saturation/failure drops data without queueing
or retrying.

Global error capture sends that exporter only a bounded error category. It
delegates framework presentation with redacted details, preserves any prior
platform handler's handled/unhandled result, returns `false` when no handler
exists, and rethrows uncaught zone failures. Do not change those fatal paths to
`true` or swallow them: doing so suppresses OS crash diagnostics, can leave the
process in a corrupted state, and makes crash-free evidence misleading. The
tradeoff is intentional: Apple/Google OS diagnostics may retain a native crash
record or runtime stack under platform policy, while Pakperk's OTLP exporter
never receives the raw error. Review the exact signed artifact's platform
diagnostics and store disclosures before release.

Do not declare a release candidate passed until the evidence bundle contains:

- cached first-readable-frame p95 at or below 1.5 seconds on named reference
  devices and staging;
- opening transition at or below 700 ms when local initialization is healthy;
- no blank card in the warm cached next-paper test and at least 95% sequential
  next-paper cache hits;
- at least 99.5% crash-free sessions for the exact signed candidate;
- the measured sample/window, collector query or store report, build number,
  device/OS matrix, and approver.

Use an aggregate, privacy-reviewed crash denominator supplied by the staged
distribution/diagnostics system. Do not add a persistent device, account, or
session identifier to mobile telemetry to manufacture this metric. Until a
signed TestFlight/closed-Play candidate has a representative observation
window approved by the release owner, the crash gate is **not passed**.

## External release blockers

Repository checks cannot complete these actions. A release owner must attach
evidence for each before enabling production flags:

- protected Android and Apple signing credentials and successful signed
  dev/staging/production artifacts;
- registered OIDC clients/redirects and production associated domains;
- deployed association and legal/support URLs with monitored contact details;
- live OTLP collector retention and redaction verification;
- physical-device account, comments/report/block, deletion, strict-content,
  offline, callback, and deep-link QA;
- reviewer account and store review notes without real-user data;
- TestFlight and closed Play-track upload, current App Privacy/Data Safety and
  age-rating forms, monotonic store versions, and review status. Apple's
  [updated age-rating questionnaire](https://developer.apple.com/news/upcoming-requirements/?id=07242025a)
  has required answers since January 31, 2026;
- verified Android developer identity and package/signing-key registration.
  [Regional enforcement begins September 30, 2026](https://developer.android.com/developer-verification/guides)
  for participating stores in Brazil, Indonesia, Singapore, and Thailand,
  followed by broader rollout;
- staging performance/crash evidence plus backup-restore/deletion replay
  evidence owned by operations.

Do not mark an external item complete from a source build or simulator test.
