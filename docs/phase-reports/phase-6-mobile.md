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
- Dev/staging/prod native identities, callbacks, schemes, associated domains,
  ATS/network policies, backup controls, privacy manifest, and strict artifact
  asset policy are configured independently.
- Android and iOS release builds fail closed without protected distribution
  signing values. Android is pinned to min/compile/target API 24/36/36 and NDK
  28.2, and its verifier requires release signing plus 16 KiB-safe native
  layout. The iOS verifier requires Xcode/iOS SDK 26, exactly iOS 15.0, Apple
  Distribution signing, and an App Store profile. No signing secret is checked
  in.

## Executed verification

At the Phase 6 implementation checkpoint, the full Flutter analyzer and 437
tests, the focused account-deletion/auth/error-mapper/telemetry/config suites,
all three Android debug flavors, all three iOS simulator flavors, strict asset
inspection of staging/production Android archives and the production iOS
`.app`, all nine Xcode configurations/three schemes, and native backup-exclusion
coverage on an iPhone 16 / iOS 18.5 simulator completed successfully.

The final release-hardening audit subsequently changed the deletion terminal-
failure copy and native release verifiers. On the resulting tree, Dart format
and direct Dart analysis with the CI-pinned Flutter 3.44.8 SDK passed, as did Gradle-wrapper integrity,
Android ELF/ZIP 16 KiB alignment fixtures and existing debug-archive
inspection, signed-JAR positive/unsigned/tampered/multiply-signed regressions,
deterministic icon regeneration, shell/plist/JSON validation, and scoped diff
checks. The available production debug APK/AAB correctly fail the hardened
release verifier because a debug certificate is not release evidence.

Merged/built artifact inspection confirmed production ID
`app.pakperk.pakperk`, version `0.2.0 (2)`, callback `pakperk-auth`, HTTPS
`pakperk.app` links, no production cleartext/ATS exception, disabled Android
backup, packaged Apple privacy manifest, and no strict derived-content asset.

Negative gates were also exercised: Android release fails immediately without
all `PAKPERK_ANDROID_*` values; iOS production IPA resolution is manual Apple
Distribution signing and produces no IPA without a protected team/profile.
The full Flutter/widget suite and iOS scheme/build invocation after those final
hardening edits could not access the SDK/SwiftPM/CoreSimulator caches under the
managed sandbox, and the required out-of-sandbox reruns were rejected by the
execution quota. The next green CI run must therefore reconfirm those checks;
this report does not treat the earlier run as proof for the changed files.

## Release-blocking external evidence

This report does not claim Phase 6 production exit. The following require
credentials, deployed systems, physical devices, representative traffic, or a
store owner and remain pending:

- successful signed dev/staging/prod artifacts and artifact-derived
  association verification;
- deployed `/.well-known/` files and cold/warm physical-device link tests;
- TestFlight and closed Play-track uploads, monotonic store-history check,
  reviewer account/notes, privacy/data-safety and age-rating submissions;
- live OTLP retention/redaction inspection and the >=99.5% crash-free-session
  release-candidate gate;
- measured startup/opening/cache targets on documented reference devices;
- production OIDC callbacks, public legal/support contacts, end-to-end
  deletion/restore replay, and full physical-device acceptance scenarios.

See `docs/mobile-release.md`, `docs/store/mobile-privacy-review.md`,
`docs/store/ugc-content-review.md`, and `docs/mobile-app-links.md` for the
operator checklists. An owner must attach external evidence rather than editing
this report to imply unexecuted work passed.
