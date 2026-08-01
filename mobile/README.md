# PakPerk mobile

Flutter client for Pakperk, with native Android and iOS hosts. The API base URL
is configured at build time:

```sh
flutter run \
  --flavor dev \
  --dart-define=PAKPERK_ENV=development \
  --dart-define=PAKPERK_API_BASE_URL=http://localhost:8080 \
  --dart-define=PAKPERK_FULLTEXT_POLICY=prototype
```

Android emulators normally need `http://10.0.2.2:8080`. The app persists an
anonymous session identifier, the cached feed and prepared content, the full
paper navigation trail, each stage/scroll position, and chat-sheet state.

The app uses a stateful Read/You shell. Read keeps feed, linked-paper, stage,
and scroll restoration across tab switches. You remains a guest explanation
when accounts are disabled and owns sign-in/profile/onboarding state in an
account-enabled build. Startup opens local preferences and the first cached or
bundled feed before the production widget tree mounts, releases the native
splash, and starts exactly one feed revalidation after the first usable frame.
Network and identity-provider availability are therefore not launch
prerequisites.

For the optional Phase 3 development account flow, start the repository's
Compose `accounts` profile and run with the exact public-client values:

```sh
flutter run \
  --flavor dev \
  --dart-define=PAKPERK_ENV=development \
  --dart-define=PAKPERK_API_BASE_URL=http://localhost:8080 \
  --dart-define=PAKPERK_ACCOUNTS_ENABLED=true \
  --dart-define=PAKPERK_OIDC_ISSUER_URL=http://localhost:8081/realms/pakperk \
  --dart-define=PAKPERK_OIDC_CLIENT_ID=pakperk-mobile-dev \
  --dart-define=PAKPERK_OIDC_REDIRECT_URI=pakperk-auth-dev://oauth/callback \
  --dart-define=PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI=pakperk-auth-dev://oauth/logout \
  --dart-define='PAKPERK_OIDC_SCOPES=openid profile'
```

Every app launch requires an exact native/Dart pairing: `dev` with
`PAKPERK_ENV=development`, `staging` with `PAKPERK_ENV=staging`, and `prod`
with `PAKPERK_ENV=production`. Missing or crossed flavor configuration fails
before any network client is created. The complete release commands use the
checked-in files under `config/` and are documented in
[`../docs/mobile-release.md`](../docs/mobile-release.md).

Checked-in staging and production configs keep accounts, library, and comments
off. Signed candidates may enable them only through the protected environment
variables `PAKPERK_ACCOUNTS_ENABLED`, `PAKPERK_LIBRARY_ENABLED`, and
`PAKPERK_COMMENTS_ENABLED`; missing values stay false and the workflow records
the resolved booleans. See the
[protected feature-flag contract](../docs/mobile-release.md#protected-mobile-feature-flags).

The login uses the system browser and PKCE. Access tokens stay in memory;
refresh/session material is stored in platform secure storage rather than
SharedPreferences or Drift. Invalid refresh returns to guest state, while
ordinary provider/network failure keeps an offline/auth-unknown session.
Sign-out clears account-owned data without removing public cached papers or
reader restoration. See
[`../docs/account-authentication.md`](../docs/account-authentication.md) for
the exact callback, Android emulator, API, and storage contracts.

The native hosts accept `pakperk://paper/{paper_id}` and registered
`https://pakperk.app/p/...` or `/arxiv/...` links. Release builds also require
the external Apple and Android association files described in
[`../docs/mobile-app-links.md`](../docs/mobile-app-links.md).

The canonical launcher artwork is
`assets/brand/pakperk_app_icon.svg`. Do not hand-edit its generated PNGs. From
the repository root, install `rsvg-convert` and ImageMagick's `magick`, then
regenerate every opaque iOS AppIcon plus Android legacy and round icon with:

```sh
./scripts/generate_mobile_icons.sh
```

Android adaptive and themed launchers use the checked-in foreground and
monochrome vectors. The mobile tests and strict-artifact verifier reject the
stock Flutter launcher, missing density/round resources, or missing adaptive
and monochrome resources.

Set both the backend `FULLTEXT_POLICY` and the mobile
`PAKPERK_FULLTEXT_POLICY` to `strict` for a strict deployment. A strict mobile
build fails closed when the API is unreachable: it keeps cached metadata and
original arXiv links available, but does not restore device or bundled
Introduction, Connections, chat answers, or stale derived-capability flags.
Unknown mobile policy values are treated as `strict`.

The bundled assets contain real arXiv metadata and explicitly marked
demo-safe Introduction summaries plus manually reviewed Connections responses
so the principal reading path remains usable when the API is unavailable.
These prepared fallbacks are also visibly labeled in the reader as bundled
offline demo content, not live parsed results.
Online and deployed prepared content always comes from the persisted backend
PDF-processing pipeline and supersedes these mobile fallbacks.

After running the backend preprocessing and verification commands, refresh all
three bundled files from the ordinary public API:

```sh
../scripts/export_mobile_cache.sh
```

Run the checks with:

```sh
flutter analyze
flutter test
```

The normal suite includes headless specifications for all eight demo flows in
`test/e2e/demo_flows_test.dart` and the deterministic production-verification
subset in `test/e2e/production_verification_test.dart`. The latter exercises a
30-record cached launch, six deterministic cursor pages that cover exactly 200
papers while first-page revalidation remains stalled, 20 generated Flutter
drag/fling gestures, bounded live readers, a 500-paper/100-save Drift workload
(logical page size in headless CI and real SQLite/WAL/SHM file size in the
physical-device lane), packet-loss and single-flight behavior, same-UUID
outbox recovery, comment pagination, lifecycle-safe maintenance, foreground
memory-warning handling, reduced motion, and strict cache masking.

Those fixtures do not impersonate a real identity provider, staging backend,
second installed device, OS process kill, signed store candidate, or
representative performance window. With a physical Android or iOS target
attached, run the deterministic subset through Flutter's integration binding:

```sh
flutter test integration_test/production_verification_test.dart \
  --profile -d "$PAKPERK_MOBILE_DEVICE_ID"
```

Setting `PAKPERK_MOBILE_DEVICE_ID` makes the repository-level
`scripts/check.sh` include that physical-device probe after the complete
headless suite. The manually dispatched `mobile-device-integration` workflow
does the same on a protected self-hosted runner, reads the exact device ID only
from the protected `PAKPERK_MOBILE_DEVICE_ID` environment secret, rejects
emulators, and retains closed platform/version, frame, file-backed database,
and verification-scope evidence. Its dispatch is bound to an explicit reviewed
`main`-tip source revision and confirmation phrase. It explicitly records the
live OIDC, two-device, staging, account-deletion, store, and operational paths
that it did not execute. Its generated `WidgetTester` pointer sequences cover
Flutter's gesture and pagination paths but are not operator gestures or a
representative performance window. The separate `protected mobile acceptance`
workflow orchestrates those live paths through a SHA-256-pinned runner driver,
a root-owned content-addressed signed-candidate manifest, a content-addressed
signed-release provenance manifest, and a short-lived root-owned dedicated/
ephemeral runner-session attestation. It takes staging coordinates from
`config/staging.json`, requires the exact staging Android/iOS application ID,
and covers four distinct physical installations: Android gesture, Android
three-button, iPhone home-indicator, and physical-keyboard iPad/second sync. Its
canonical schema-v2 artifact binds the run challenge, actual APK/IPA hashes,
release-workflow identity, runner session, and challenge-keyed physical-device
identity hashes recomputed from root-attested commitments to 16 ordered
scenarios, exact assertion IDs, and closed integer metrics without retaining raw
device serials or stable commitments. Packaging creates the final tar
exclusively, binds its digest, and verifies it again immediately before upload.
Its actual protected run, root-side manifest/session provisioning, staging
tenant, test accounts, devices, and approval remain external release evidence.
Both lanes are documented in
[`../docs/mobile-release.md`](../docs/mobile-release.md).
