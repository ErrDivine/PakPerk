# Phase 6 mobile release-candidate evidence

**Code version:** `0.2.0+2`
**Evidence date:** 2026-08-01
**Scope:** Flutter client and native Android/iOS hosts

## Implemented

- Recent-auth account deletion uses a single-use, bodyless request with a
  pinned auth epoch and no 401 refresh/replay. It accepts only exact bounded
  response contracts and performs independent token/account-cache/comment
  snapshot cleanup after acceptance.
- Account deletion responses are streamed with a 16 KiB cap and fixed total
  deadline. Malformed/multi-value headers, oversized/dribbling bodies, and
  near-miss post-commit `503` responses fail closed.
- Legal/privacy/support/deletion pages are available in app with bundled
  offline text; feature-off routes remain safe.
- Telemetry is provider-neutral, redacted through closed event/attribute
  vocabularies, bounded to 16 KiB and two in-flight requests, never queued or
  retried, and sent only to exact `/v1/logs` endpoints.
- Public-cache hydration and secure session/deletion-guard inspection start
  concurrently. Cached content can become usable as soon as local hydration
  finishes, while session-dependent work remains fail-closed; a session-only
  retry preserves the mounted store/provider graph. Session inspection is
  single-flight, and timeout/repair paths serialize replacement work and close
  or drain abandoned Drift owners before repair so stale import/migration work
  cannot repopulate a repaired cache. Request-scoped store leases also make
  repair/replacement wait for in-flight session/deletion recovery before
  closing its store.
- Reduced-motion behavior is centralized across startup, paper-stage, and feed
  transitions and can react while the opening transition is active. Explicit
  navigation becomes immediate and animation-only haptics are suppressed.
  Vertical feed haptics occur once per settled page commit, never during drag,
  and platform haptic failure cannot block navigation.
- Reader labels physically scale without fit-to-box shrinking at 200% text;
  small-screen and semantic color-pair regressions enforce legibility and WCAG
  AA text contrast. External arXiv actions are derived from a normalized arXiv
  identifier and exact canonical HTTPS host/path rather than supplied model
  URLs.
- Dev/staging/prod native identities, callbacks, schemes, associated domains,
  ATS/network policies, backup controls, privacy manifest, and strict artifact
  asset policy are configured independently.
- Android and iOS release builds fail closed without protected distribution
  signing values. Android is pinned to min/compile/target API 24/36/36 and NDK
  28.2, and its verifier requires release signing plus 16 KiB-safe native
  layout. The iOS verifier requires Xcode/iOS SDK 26, exactly iOS 15.0, Apple
  Distribution signing, and an App Store profile. No signing secret is checked
  in.
- Native release resolution is bound to the arm64 macOS 26 runner, Xcode 26.6
  build 17F113, the hosted runner's `JAVA_HOME_17_arm64` Temurin 17.0.19+10
  JDK, and Flutter 3.44.8 at framework revision
  `058e0af2c2b57e369d905a03ac9748b0ebf543c6` with Dart 3.12.2. Gradle
  verification metadata pins one SHA-256 for every resolved artifact, and the
  release workflow creates and validates a CycloneDX 1.6 production-runtime
  Maven inventory. Both SwiftPM lockfiles pin AppAuth-iOS 2.0.0 to one reviewed
  full revision and checked-in license. Store tooling is frozen to Bundler
  2.6.9 and a checksum-complete Fastlane 2.235.0 dependency graph, but only
  after verifying and recording exact MRI Ruby 3.4.10 and RubyGems 4.0.17. The
  workflow verifies the downloaded Bundler gem before installation.

## Executed verification

At the Phase 6 implementation checkpoint, the full Flutter analyzer and 437
tests, the focused account-deletion/auth/error-mapper/telemetry/config suites,
all three Android debug flavors, all three iOS simulator flavors, strict asset
inspection of staging/production Android archives and the production iOS
`.app`, all nine Xcode configurations/three schemes, and native backup-exclusion
coverage on an iPhone 16 / iOS 18.5 simulator completed successfully.

The final release-hardening audit subsequently changed the deletion terminal-
failure copy and native release verifiers. On the resulting tree, Dart format
and direct Dart analysis with the CI-pinned Flutter 3.44.8 SDK passed, as did
Gradle-wrapper integrity, Android ELF/ZIP 16 KiB alignment fixtures and
existing debug-archive inspection, signed-JAR positive/unsigned/tampered/
multiply-signed regressions, deterministic icon regeneration, shell/plist/JSON
validation, and scoped diff checks. The available production debug APK/AAB
correctly fail the hardened release verifier because a debug certificate is
not release evidence.

A strict repository-closure audit then made account deletion discoverable at
**You > Settings > Delete account** for authenticated/recoverable sessions and
made save/removal outbox draining plus Undo independent of widget disposal or
haptic and semantics platform failures. Direct Dart format and analysis passed
on that resulting tree. Focused widget coverage passed for the shared
save-control Undo path before the final widget-lifecycle hardening; the new
Settings visibility/routing and haptic-failure regression cases are checked in
for the next complete Flutter CI lane. This report does not infer a full
post-change widget or device run.

The subsequent startup/accessibility hardening described above is newer than
that direct-analysis checkpoint. Checked-in regressions cover concurrent local
hydration/session inspection, session-only retries without provider-tree
replacement, superseded store closure/draining around retry/repair, repair or
replacement waiting for leased session store use, active reduced-motion
changes, one settled page-commit haptic, unavailable haptics, canonical arXiv
links, contrast, and 200% stage labels. Direct Dart formatting and analysis
passed on the settled current tree. The complete locked Flutter/widget suite
has not run on those newest changes, so the direct static pass is not presented
as widget or device evidence.

Repository supply-chain validators and tamper regressions passed for the exact
mobile-release source/toolchain contract, including the pre-dependency MRI Ruby
3.4.10 / RubyGems 4.0.17 gate, checksum-complete Gradle metadata, and the
Fastlane lock. The current generated Android production-runtime CycloneDX 1.6
artifact contains 102 components and passed the native SBOM validator. Its
exact reviewed purl inventory is content-bound to the Pub/Gradle/checksum-policy
inputs; the artifact must have the exact application identity/version, a closed
dependency graph with every component reachable, component `bom-ref`/purl
agreement, the release Flutter engine, and reviewed AppAuth/Tink identities,
licenses, and checksums. Its graph has the application root plus 102 component
nodes. Deterministic source metadata generation also includes the exact SwiftPM
AppAuth component. None of these static/current-artifact results is a signed
protected mobile candidate or a store upload.

Merged/built artifact inspection confirmed production ID
`app.pakperk.pakperk`, version `0.2.0 (2)`, callback `pakperk-auth`, HTTPS
`pakperk.app` links, no production cleartext/ATS exception, disabled Android
backup, packaged Apple privacy manifest, and no strict derived-content asset.

Negative gates were also exercised: Android release fails immediately without
all `PAKPERK_ANDROID_*` values; iOS production IPA resolution is manual Apple
Distribution signing and produces no IPA without a protected team/profile.
The complete Flutter/widget suite and iOS scheme/build/device matrix have not
been rerun on the latest startup/accessibility tree. The next green CI and
device runs must therefore reconfirm those checks; this report does not treat
the earlier checkpoint as proof for the changed files.

## Current-tree verification still required

- Run the complete locked Flutter unit/widget suite; direct Dart formatting and
  analysis have already passed on the settled startup lifecycle patch.
- Rebuild all Android debug flavors and all iOS simulator schemes, then rerun
  strict asset/native-protection checks on artifacts built from the same source
  revision.
- Exercise cold/warm/deep-link startup, timeout/retry/repair, runtime reduced-
  motion changes, 200% text, settled haptics, and canonical arXiv actions on
  representative physical devices.

## Release-blocking external evidence

This report does not claim Phase 6 production exit. The following require
credentials, deployed systems, physical devices, representative traffic, or a
store owner and remain pending:

- successful signed dev/staging/prod artifacts and artifact-derived
  association verification;
- a successful protected exact-SHA signed-mobile workflow using the reviewed
  JDK/Xcode/Flutter/Ruby/RubyGems/Bundler/Fastlane graph and its generated
  native SBOM;
- deployed `/.well-known/` files and cold/warm physical-device link tests;
- TestFlight and closed Play-track uploads, monotonic store-history check,
  reviewer account/notes, privacy/data-safety and age-rating submissions;
- live OTLP retention/redaction inspection and the >=99.5% crash-free-session
  release-candidate gate;
- measured startup/opening/cache targets on documented reference devices;
- production OIDC callbacks, public legal/support contacts, end-to-end
  deletion/restore replay, protected staging backend load evidence, and full
  physical-device acceptance scenarios.

See `docs/mobile-release.md`, `docs/store/mobile-privacy-review.md`,
`docs/store/ugc-content-review.md`, and `docs/mobile-app-links.md` for the
operator checklists. An owner must attach external evidence rather than editing
this report to imply unexecuted work passed.
