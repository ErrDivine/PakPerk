# PakPerk mobile

Flutter client for Pakperk, with native Android and iOS hosts. The API base URL
is configured at build time:

```sh
flutter run \
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
  --dart-define=PAKPERK_API_BASE_URL=http://localhost:8080 \
  --dart-define=PAKPERK_ACCOUNTS_ENABLED=true \
  --dart-define=PAKPERK_OIDC_ISSUER_URL=http://localhost:8081/realms/pakperk \
  --dart-define=PAKPERK_OIDC_CLIENT_ID=pakperk-mobile-dev \
  --dart-define=PAKPERK_OIDC_REDIRECT_URI=pakperk-auth://oauth/callback \
  --dart-define=PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI=pakperk-auth://oauth/logout \
  --dart-define='PAKPERK_OIDC_SCOPES=openid profile'
```

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

The normal suite includes a headless end-to-end specification for all eight
demo flows in `test/e2e/demo_flows_test.dart`. With an Android or iOS test
target attached, run the same scenarios through Flutter's device integration
binding:

```sh
flutter test integration_test/demo_flows_test.dart
```

Setting `PAKPERK_RUN_DEVICE_INTEGRATION_TESTS=1` makes the repository-level
`scripts/check.sh` include that device run.
