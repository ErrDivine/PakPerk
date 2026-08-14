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
flutter pub get --enforce-lockfile
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

The manual `signed-mobile-release` workflow uses separate fresh-runner trust
domains. A credential-free preparation job accepts only the reviewed full
lowercase `main` commit, emits and immutably uploads the configuration/evidence
binding before any candidate executable runs, and never binds a protected
environment. Independent Android and iOS signer jobs each re-download and
rederive that exact binding before exposing only their own signing-secret
family. A fresh credential-free job validates and assembles the two results
into the canonical signed candidate and provenance. Store-client preparation
is separately uncredentialed; fresh no-checkout Android and iOS upload jobs
receive only their own store credential, and an always-run credential-free
finalizer retains the closed per-platform result before failing any missing or
unsuccessful requested upload. Dispatch from `main` with the reviewed full
commit SHA; every source boundary rejects an exact-checkout or `origin/main`
ancestry mismatch. Configure these environment secrets:

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
each store and enter it in the workflow inputs. The credential-free preparation
gate requires checked-in build `2` to be greater than both values; it cannot
infer private store history when upload credentials are intentionally withheld.
The workflow always signs both platforms. `upload_to_stores=true` requests both
the Play-internal and TestFlight uploads; there is no single-platform shortcut
that can silently omit one requested outcome.

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

## Protected staged store rollout

The signed-candidate workflow stops at Google Play's `internal` track and
TestFlight. Public production mutation is a separate manual workflow,
`protected-mobile-store-rollout`, bound to the fixed `production-store` GitHub
environment. Configure that environment with required reviewers, restrict it to
`main`, and provide the four store credentials listed above with only the store
permissions needed to promote the exact Play release and manage the exact App
Store version. A YAML environment name is not evidence that those protections
were configured.

Before exposing store credentials, the protected gate must keep two identities
separate. An uncredentialed bootstrap checks out trusted tooling at the reviewed
`github.workflow_sha`; the immutable candidate source is a data-only input and
must never supply credentialed executable code. The bootstrap produces an
immutable store-client/control closure. Every executable in that closure has a
workflow-literal SHA-256 that the fresh Android and iOS mutation jobs verify
before use; those jobs perform no checkout, receive no candidate-provided
executable, clear shell/language/loader/proxy injection surfaces, and expose
only the credential for their own platform. Before any candidate artifact is
accepted or store credential is materialized, the bootstrap queries GitHub's
Actions API for the supplied run ID. It requires the exact repository,
`signed-mobile-release` workflow path, `workflow_dispatch` event, `main` branch,
source SHA, successful completed status and run attempt, plus the exact
all-success eight-job surface: credential-free preparation, isolated Android
and iOS signers, `production signed candidate`, uncredentialed store-client
bootstrap, isolated Android and iOS uploads, and the credential-free signed-
release finalizer. It then requires one non-expired, attempt-bound candidate,
handoff, and signed-release-outcome artifact with distinct server-issued IDs
and SHA-256 digests, and downloads those artifacts by immutable ID (with digest
mismatch as an error). The exact artifact names are
`pakperk-production-<version>-<build>-<sha>-<run-id>-<attempt>` and
`pakperk-production-store-handoff-<version>-<build>-<sha>-<run-id>-<attempt>`,
plus
`pakperk-production-store-outcome-<version>-<build>-<sha>-<run-id>-<attempt>`.
The handoff
is created only after Play independently reports the exact version code as a
completed singleton on `internal` and returns the server-side bundle SHA-256
matching the candidate AAB; App Store Connect must report the exact iOS
app/build/pre-release-version relationship in `VALID` processing state and a
single completed `buildUpload` whose direct `build` relationship is that Build
ID. Its direct `assetFile` must be a completed `ASSET` with UTI
`com.apple.ipa`, the candidate IPA's exact byte size, and a
`sourceFileChecksums.file` SHA-256 equal to the candidate IPA digest. The
gate validates the authenticated canonical Actions record, the
canonical candidate, provenance, and handoff bytes, the candidate and
provenance `sha256:` content IDs, production/strict flavor,
source/version/build/application identities, artifact signer bindings,
repository/workflow/job/stage, signed-release run ID and run attempt, local AAB
and IPA hashes, and both authoritative upload readbacks. The handoff uses a
distinct `store-handoff-v1:sha256:` content ID. The signed-release
source must equal its recorded workflow revision. A typed content ID without
the corresponding downloaded bytes, a control closure that differs from its
literal workflow hashes, a trusted bootstrap checkout that differs from
`github.workflow_sha`, or candidate-authored code receiving store credentials
blocks the gate.

First classify each selected platform as an update or its first public
production version from the independent store history. Do not infer that state
from Git. The protected staged workflow is update-only. For a normal update:

1. Dispatch `signed-mobile-release` for `production` with
   `upload_to_stores=true`. Wait for the exact AAB to reach Play `internal` and
   the exact IPA/build to finish TestFlight processing. Retain its run ID,
   candidate ID, provenance ID, verified store-handoff ID, and
   protected-environment approval. A successful upload process without the
   verified handoff is not rollout-eligible.
   Immediately before each binary send, the workflow fsyncs an owner-only
   attempt journal bound to the candidate/provenance IDs, exact AAB or IPA
   digest and byte size, destination, run attempt, source, version, and build.
   The iOS verification must match both values from that pre-send journal and
   retain the App Store BuildUpload and BuildUploadFile resource IDs. It retains an
   always-run `mobile-store-upload-attempt-<run-id>-<attempt>` artifact. A
   journal without authoritative store readback is
   `unknown_reconcile_required`, even when the upload client lost only its
   success response.
2. Reconcile the two portal records with the signed manifest. Confirm the
   privacy, age-rating, reviewer-flow, physical-device, performance, crash,
   legal, and safety gates for this exact build. For Play, identify an eligible
   prior completed production release that can remain the fallback throughout
   the update; no prior fallback means this is a first publication and the
   staged workflow is prohibited. For iOS `start`, identify the exact prior
   public version; the trusted App Store Connect client must resolve exactly
   one matching iOS record in current
   [`appVersionState`](https://developer.apple.com/documentation/appstoreconnectapi/appversionstate)
   `READY_FOR_DISTRIBUTION`, and the exact target version must be
   `PREPARE_FOR_SUBMISSION` or `READY_FOR_REVIEW`. No matching prior public
   version means this is a first publication and the staged workflow refuses
   it.
3. Dispatch `protected-mobile-store-rollout` from `main` with operation
   `start`, the exact signed-release identities (including the store-handoff
   ID), platform scope, a sanitized
   change ID, and confirmation `MUTATE_PRODUCTION_MOBILE_STORES`. Android
   `start` also requires `android_previous_production_version_code`, expected
   fraction `none`, and target fraction `0.01`; iOS `start` requires
   `ios_previous_public_version`. Android promotes only that version code from
   `internal` to a one-percent `production` rollout. After the exact App Store
   update preflight, iOS submits only that TestFlight build for review with
   automatic phased release enabled, then requires the exact target phased
   resource to be `INACTIVE` before it records submission success.
4. Keep Android at one percent for the approved observation window. Before
   every `advance`, require no release-blocking alert, the exact-candidate
   performance checks, at least 99.5% crash-free sessions, and release-owner
   approval. The reviewed Android fractions are `0.02`, `0.05`, `0.10`,
   `0.20`, and `0.50`; `complete` is the only operation that accepts `1.00`.
   Apple's seven-day percentage progression is automatic, so an iOS
   `advance` observes and retains the current phased-release state rather than
   forcing a percentage; an `advance` succeeds only from exact `ACTIVE`, while
   pause/complete are re-observed after the API mutation. Apple documents the
   phased update schedule and pause
   behavior in [App Store Connect Help](https://developer.apple.com/help/app-store-connect/update-your-app/release-a-version-update-in-phases/).
5. Immediately before each live commit/PATCH/submission, write and `fsync` an
   owner-only attempt journal containing the exact reviewed store pre-state and
   `unknown_reconcile_required`. Only an authoritative postflight may replace
   that classification in the receipt with `succeeded_verified`; any error
   after the send begins remains `unknown_reconcile_required` until an operator
   reconciles the portal. Other closed classifications are `not_attempted`,
   `rejected_pre_mutation`, and `proven_not_committed`. In a combined rollout,
   the receipt requires the canonical journal and postflight to cross-match
   their pre-state/resource identities. A result without that journal, or with
   duplicate/non-finite/non-canonical JSON, remains
   `unknown_reconcile_required`. Apple is not attempted unless Android has this
   fully journal-bound `succeeded_verified` state, not merely a successful step
   exit. Upload the receipt before the workflow reports a final
   failure, and reconcile every unknown state before any retry.
6. Reconcile every platform outcome with the stores' independent audit/history
   record. Each content-addressed record binds trusted-tooling revision,
   candidate source, signed candidate/provenance/handoff, authenticated
   signed-release run/job/artifact IDs and digests, workflow revision,
   version/build, requested transition, sanitized change ID,
   pre/post state, and result. A workflow receipt is not store approval,
   propagation, crash evidence, or proof that an environment reviewer actually
   inspected the portal.

The rollout workflow enforces that sequence with exactly four trust domains:
an uncredentialed bootstrap, an Android-only-secret mutation job, an
iOS-only-secret mutation job, and a credential-free `always()` finalizer. For a
`both` transition, the iOS job downloads by immutable artifact ID and validates
the Android outcome and journal as `succeeded_verified` before any Apple
mutation. Each selected platform cleans up its secret and uploads an immutable
outcome even when the mutation fails; the finalizer then emits the canonical
schema-v4 aggregate and fails on a missing or unsuccessful selected outcome.
That aggregate binds the authenticated signed run, candidate, provenance,
handoff, source, version/build, and requested transition, including exact
unselected and dependency-skip semantics. GitHub's raw 64-hex upload-artifact
digest is retained in evidence only after canonical conversion to
`sha256:<hex>` and cross-checking against the server result.

Google and Apple allow staged/phased distribution only for updates. Google
states that a first production release is published to 100% of selected
countries and offers no rollout-percentage control; use a separately approved
first-Play-publication procedure, not `protected-mobile-store-rollout`. Retain
the exact no-prior-production pre-state, candidate/provenance and signed-release
bindings, countries, review/managed-publication state, 100% publication action
and UTC time, observed post-state/availability, independent portal audit, and
store-owner approval. See [Play's first-release and update procedure](https://support.google.com/googleplay/android-developer/answer/9859348).

Apple phased release likewise does not apply to the first public version. For a
first iOS publication, exclude iOS from the staged workflow and use a separately
approved manual-release procedure. Retain the exact no-prior-public-version
pre-state; candidate/provenance and signed-release bindings; app/version/build
and submission identity; submission time and review outcome; the selected
`Manually release this version` setting; the `Pending Developer Release` state
before release; owner approval; the exact `Release This Version` action/time and
observed post-release availability, or the deliberately withheld state and
decision.
That record must not claim an Apple phased state. See [App Store version release
options](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/select-an-app-store-version-release-option/).
When one platform is an update and the other is a first public version, scope
the protected staged workflow only to the update and retain the separate
first-publication evidence in the same release ledger. Fastlane's reviewed store
operations are documented for [Google Play](https://docs.fastlane.tools/actions/upload_to_play_store/)
and the [App Store](https://docs.fastlane.tools/actions/upload_to_app_store/).

A pre-completion `halt` is terminal for that candidate in Pakperk automation.
It halts the exact Play staged update and pauses the exact Apple phased update.
Users who already received the Android update keep it. Apple explicitly permits
any user to download a phased update manually even while automatic distribution
is paused, so a pause is not an exposure cutoff. Disable affected backend
creation/writes with the independent feature switches when that reduces harm,
preserve safe guest reads, record the manual-download residual exposure, and fix
forward with a higher build through every signed-candidate and protected gate.

After an Android update reaches 100%, a separate protected Play full-release
halt can make the exact eligible prior completed version available again to new
and eligible users, but it does not downgrade devices that installed the bad
version. Record the exact prior fallback plus Play pre/post state and owner
decision. Google does not permit this for a track's first release. There is no
equivalent iOS rollback; use feature switches and a higher fix-forward build.
See [Play's full-release halt constraints](https://support.google.com/googleplay/android-developer/answer/16285429).
Server rollback uses compatible images/feature switches and never an automatic
SQL downgrade.

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
outside log masks. This is a privacy/non-retention control, not a credential
isolation boundary: the selected Flutter command and reviewed candidate test
necessarily use that identifier and already have authorized access to the
attached physical device. Do not place account credentials or a privileged
device-management token in this fixture lane, and do not claim the raw selector
was hidden from the candidate process. Dispatch also requires an explicit full
lowercase `source_revision` equal to the selected `main` revision and fetched
`origin/main` tip, plus the exact confirmation phrase. This prevents a green
fixture probe from being attached to a different source revision.

The separate manually dispatched `protected mobile acceptance` workflow is the
automated entrypoint for the live staging/device lane. It accepts only an exact
main-tip source revision plus exact `sha256:` candidate and signed-release
provenance content IDs, runs exclusively in the protected
`mobile-device-verification` environment. Its exact-source checkout is a
**data-only** boundary: workflow-owned, isolated Python reads only the bounded
staging configuration and release version, and no script, binary, shell startup
file, package hook, or other executable from the candidate checkout may run in
the protected session. The workflow never writes candidate-derived data to
`GITHUB_ENV`; it pins both `BASH_ENV` and `ENV` to `/dev/null` for the job and
again for the credentialed driver step, fixes `PATH` to `/usr/bin:/bin`, and
uses absolute system-tool paths.

All acceptance validation and packaging instead use the fixed root-owned
`/opt/pakperk/bin/pakperk-mobile-acceptance-validator.py`; live device control
uses the fixed root-owned
`/opt/pakperk/bin/pakperk-mobile-acceptance-driver`. Before either is invoked,
the workflow requires `/`, `/opt`, `/opt/pakperk`, and `/opt/pakperk/bin` to be
root-owned and non-writable outside root, then verifies each tool through one
no-follow open descriptor, stable inode metadata, one link, root ownership,
non-writable mode, and its protected SHA-256. The driver must also be
executable. Configure these exact protected-environment variables:

- `PAKPERK_MOBILE_RUNNER_SESSION_ID`;
- `PAKPERK_MOBILE_ACCEPTANCE_VALIDATOR_SHA256`;
- `PAKPERK_MOBILE_ACCEPTANCE_DRIVER_SHA256`;
- `PAKPERK_ANDROID_SIGNER_SHA256`;
- `PAKPERK_IOS_TEAM_ID`;
- `PAKPERK_IOS_SIGNER_SHA256`.

The pinned validator and driver must use absolute, reviewed paths for any
Android SDK or other runner tools outside `/usr/bin:/bin`.

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
Coordinates are read as data from the reviewed `mobile/config/staging.json`;
mutable coordinate and package/bundle-ID variables are not accepted. The source
step rejects duplicate/non-finite JSON, control characters, non-round-tripping
or unsafe HTTPS coordinates, symlink/race changes, and an invalid strict flavor
or release version. It writes one exclusive, owner-only canonical schema-2
source binding under `RUNNER_TEMP`, containing only the exact source revision,
environment, app version/build, API origin, app-link origin, OIDC issuer, and
OIDC client ID.
Only the bounded ASCII version/build and binding path become step outputs; none
becomes a shell startup setting. The credentialed request builder reopens that
binding and uses its coordinates for the driver request. The root-owned
validator independently reloads it, requires it to match the candidate/
provenance source and version/build, and uses the same coordinates for final
evidence validation.

The credential-free `signed-candidate` assembler job emits canonical candidate
and provenance files and their content IDs, but it cannot install them into a
self-hosted runner's protected filesystem. After authenticated artifact
retrieval, a runner administrator must
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
root-installing this attestation and the pinned validator/driver, provisioning a
dedicated runner, proving that no earlier or untrusted job/process shares the
credentialed session, isolating the host and attached devices, and destroying
its disposable state afterward remain external protected runner-administrator
controls. Repository validation, `BASH_ENV`/`ENV` pinning, labels, and a claimed
`ephemeral: true` attestation do not by themselves prove runner-group access,
single-job/JIT registration, process isolation, or host cleanup; retain the
platform/provisioning evidence and administrator approval for the release.

The protected runner exposes four distinct installed-device secrets to the
root-owned, digest-pinned driver: an Android gesture-navigation phone, an
Android three-button phone, an iPhone with a home indicator, and a physical-
keyboard iPad that is also the independent second synchronization installation.
Test accounts and passwords are environment secrets and are never written into
the request or evidence.

The driver must automate every path below against disposable staging accounts
and emit the closed `mobile-acceptance-evidence.json` contract:

1. Fresh-install the reviewed signed APK and IPA with prior app data absent,
   remain a guest, reach cached Read without login, read published comments, and
   open the exact canonical arXiv URL through the OS browser rather than an
   embedded web view.
2. Cold launch from populated local cache and collect the cached first-readable-
   frame p95, healthy-local-initialization opening-transition duration, and
   native-launch continuity measurements.
3. Vertically swipe through at least 20 papers under controlled latency and
   packet loss; record blank cards and sequential cache hits.
4. Confirm Introduction preparation begins only after explicit horizontal
   intent.
5. Switch Read -> You -> Read and restore the exact paper, stage, and offsets.
6. Complete system-browser OIDC with PKCE against the release tenant.
7. Save, terminate/relaunch the installed app, reconnect, and verify sync.
8. On Device A save, take A offline, converge the save to an independently
   installed Device B, remove it on B, reconnect A, require A to receive the
   removal tombstone, and require both projections to converge absent.
9. From a guest post intent, complete release-tenant sign-in, choose a handle on
   an incomplete profile, accept the current Terms and Community Guidelines,
   create with one stable client request ID, replay to the same comment, edit,
   reject one stale edit, delete, and verify public-list absence.
10. Submit the same comment report twice with one idempotency identity, require
    one canonical durable report, then block the author and confirm immediate
    and server-persisted hiding.
11. Expire a real access token, verify one successful refresh, and continue the
    original action.
12. In a separate disposable session, invalidate the real refresh credential at
    the release IdP, force refresh, require guest transition, make the refresh
    record unreadable and account-owned rows inaccessible, while preserving the
    public cache and exact paper/stage/offset state.
13. Reauthenticate for account deletion and verify immediate deactivation,
    session revocation, provider cleanup, and the deletion status path.
14. Read and save offline, terminate the process, relaunch while the network is
    still disabled, read the cached abstract before any reconnect, then verify
    same-UUID outbox recovery and one server mutation after connectivity returns.
15. Repeat cold/warm startup with reduced motion and verify stationary bounded
    transitions.
16. Use the strict signed flavor and verify metadata/save/comments/original
    arXiv links remain while every cached derived fallback stays masked.
17. On Android and iOS, exercise the exact source-bound staging app-link origin's
    deployed `/p/*` and `/arxiv/*` app/universal links from cold, warm, and
    already-running states, require Abstract to open, and prove hostile origins
    fail closed to Read without a paper request.
18. On signed installed devices, prove Android backup is disabled and an
    extraction restores no app data; prove iOS backup exclusions and
    `completeUntilFirstUserAuthentication` protection; and verify device-bound,
    non-synchronizable secure-credential attributes with no persisted access
    credential.
19. Measure a populated signed-device database plus WAL/SHM files and require at
    most 500 cached paper records and at most 64 MiB of physical cache storage,
    while at least one saved-paper pin remains intact.
20. Exercise light and dark appearance on Android and iOS, preserving reader
    state and finding no unreadable, clipped, or invisible critical action.
21. Exercise root-navigation safe areas and system Back across Android gesture,
    Android three-button, and iPhone home-indicator modes.
22. Exercise physical-keyboard Tab, Shift-Tab, Enter, and Escape paths on Android
    and iPad, including 200% text and minimum target coverage.

The root-owned validator requires exact source, app version/build, candidate,
validator, and driver digests; the signed-release provenance, canonical source
binding, and ephemeral runner-session bindings; the staging API/app-link/OIDC/
client coordinates; the four ordered physical-device roles; distinct installation and
physical-identity hashes; sanitized hardware model and OS versions; and all 22
ordered schema-v3 scenarios above. A scenario passes only with its exact
device-role assignment, exact ordered assertion-ID list (141 markers in total),
and closed integer threshold/equality metrics (78 rules in total); a generic
positive count is not accepted. The driver request carries schema `3`, the exact
scenario count, assertion count, metric count, and SHA-256 of the canonical
ordered role/assertion/metric-rule contract. The pinned driver must reject a
different contract rather than translating or accepting an older schema.
In particular, `cold_cache_launch.metrics` must
contain the exact integer keys `populated_cache_records`,
`cached_first_readable_frame_p95_ms`, and `opening_transition_ms`. The latter two
must be positive and no greater than 1,500 ms and 700 ms respectively; the
legacy single-sample `first_readable_frame_ms` key is rejected. The protected
driver request carries those same two exact range rules so the digest-pinned
producer and validator share one fail-closed contract. Every Android role must
identify an installation
of the provenance-bound APK; every iOS role must identify the provenance-bound
IPA. Each device must also echo the exact staging application, signer, and Apple
team binding for its platform.

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
request, evidence, logs, or artifacts. Passing these markers is not a substitute
for the separate accountable visual, accessibility, mobile-platform, identity,
privacy, and release approvals.

Evidence schema v3 is also bound to a fresh cryptographic challenge, GitHub run
ID and attempt, and whole-second UTC not-before time. Validation limits the run
to six hours, rejects stale/replayed completion, duplicate or noncanonical JSON,
non-finite numbers, extra fields, credential-shaped strings, symlinks,
oversized evidence, partial scenarios, and failed paths. The validator packages
the exact already-read canonical evidence plus canonical
`mobile-acceptance-tooling.json` and `SHA256SUMS`, in that order, by directly
creating the final archive with exclusive-open semantics. The tooling manifest
has exact schema `1`, classification `protected mobile acceptance tooling`, and
closed validator/driver objects containing the fixed filenames and the
protected SHA-256 values. `SHA256SUMS` covers both the evidence and tooling
members. The validator checks the final inode, owner, mode `0400`, link count,
size, and SHA-256; immediately before upload it reopens the archive, requires the
closed member order and metadata, verifies both checksums, and compares both
archived tool digests with the protected expected variables. The local tar
digest is bound into the artifact name; the final step also requires the upload
action's separate artifact-container digest. The owner-only driver log is
trapped and discarded, while device serials, credentials, handles, and
comment/query text are excluded.

A release owner must dispatch this workflow for the exact installed signed
candidate and attach its immutable artifact plus the protected-environment
approval. The checked-in orchestration and validators do not prove that the
root-installed tools, isolated runner session, staging tenant, accounts, or
devices were available, and an undispatched workflow, repository test,
simulator, or operator statement does not complete this lane.

## Telemetry and release-candidate gates

Production telemetry uses only the exact HTTPS `/v1/logs` OTLP endpoint. The
mobile exporter sends no authorization header, cookie, user/device/session ID,
paper ID, handle, content, token, raw exception message, or stack. Events and
attributes pass a closed vocabulary; payloads are at most 16 KiB, requests
have a two-second deadline, responses are cancelled without buffering, at most
two exports are in flight, and saturation/failure drops data without queueing
or retrying.

Global error capture sends that exporter only a bounded error category. It
delegates framework presentation with redacted details and never passes the raw
exception or stack to a prior platform handler. A prior handler that accepts the
bounded category keeps ownership of the failure. Otherwise the original engine
callback is marked handled only long enough to prevent its raw arguments from
being printed; the app raises the bounded category with `StackTrace.empty` on
the same error zone, and that replacement remains genuinely uncaught. Zone and
pre-capture bootstrap failures use the same replacement. Do not swallow the
replacement: doing so can leave the process in a corrupted state and makes
crash-free evidence misleading. Apple/Google diagnostics may retain a native
crash record under platform policy, but must not receive an application
exception message, token, content value, or Dart stack from this boundary.
Review the exact signed artifact's platform diagnostics and store disclosures
before release.

Do not declare a release candidate passed until the evidence bundle contains:

- at least 20 cached first-readable-frame samples, with p95 at or below 1.5
  seconds on named reference devices and staging;
- at least 20 opening-transition samples, with the measured transition at or
  below 700 ms when local initialization is healthy;
- no blank card across at least 20 warm sequential next-paper requests and at
  least 95% cache hits;
- at least 20 frame samples and a recorded sample window;
- at least 99.5% crash-free sessions for the exact signed candidate;
- the measured sample/window, collector query or store report, build number,
  device/OS matrix, and approver.

Use an aggregate, privacy-reviewed crash denominator supplied by the staged
distribution/diagnostics system. Do not add a persistent device, account, or
session identifier to mobile telemetry to manufacture this metric. Until a
signed TestFlight/closed-Play candidate has at least a 24-hour observation
window and 200 aggregate exact-candidate sessions across the two bound store
diagnostic sources, and that window is approved as representative by the
release owner, the crash gate is **not passed**. These are the Production v0.0
minimums; an owner may require a longer window or larger denominator but may not
waive them in the manifest.

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
  age-rating forms, monotonic store versions, review status, and either the
  protected update-transition evidence or the separately approved
  first-publication evidence defined above. Update evidence includes separation
  of trusted tooling from candidate source, eligible Play fallback, exact
  per-platform pre/post states and unconditional outcomes, partial-success
  reconciliation, Apple manual-download exposure, and any Android-only
  full-release halt; first-publication evidence includes the exact Play 100%
  state and Apple manual-release state/action. Apple's
  [updated age-rating questionnaire](https://developer.apple.com/news/upcoming-requirements/?id=07242025a)
  has required answers since January 31, 2026;
- verified Android developer identity and package/signing-key registration.
  [Regional enforcement begins September 30, 2026](https://developer.android.com/developer-verification/guides)
  for participating stores in Brazil, Indonesia, Singapore, and Thailand,
  followed by broader rollout;
- staging performance/crash evidence plus backup-restore/deletion replay
  evidence owned by operations.

Do not mark an external item complete from a source build or simulator test.
