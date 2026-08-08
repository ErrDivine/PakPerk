# Production v0.0 Phase 1 report

**Phase:** Application shell, design system, and startup
**Status:** Complete
**Completed:** 2026-07-31
**Starting commit:** `44cc93f`

This report records Phase 1 implementation and automated evidence. It does not
claim that account, library, comment, Drift-cache, moderation, operations, or
store-release phases are complete.

## Application shell and routing

- Added `go_router` 17.3.0 and a `StatefulShellRoute.indexedStack` with exactly
  two Material 3 destinations: Read and You.
- Added the Section 2.4 tablet adaptation on 2026-08-03. Compact widths retain
  the bottom `NavigationBar`; widths of 600 logical pixels and above use a
  leading, safe-area-aware `NavigationRail` with visible Read/You labels. Both
  presentations call the same branch/reselection/restoration path, and the
  rail is ordered so active nested routes cannot hide it from the semantics
  tree.
- Retained the existing linked-paper page navigator inside Read so paper trails,
  horizontal stage, scroll offsets, preparation intent, and Back behavior keep
  their exact restoration semantics.
- Persisted the selected branch. Switching branches preserves the Read paper
  and You nested route; reselecting Read pops a nested paper without resetting
  the feed index.
- Moved paper chat above the shell into a root route. It owns one keyboard inset
  and bottom safe area, covers the navigation bar, and restores an open chat
  without issuing another preparation request.
- Added a root comments route. Phase 1 exposes no composer; internal and public
  links resolve validated paper metadata and show a paper-specific, explicitly
  disabled surface.
- Added honest guest You, settings, auth, library, comments, deletion, legal,
  community, and support surfaces. Disabled account controls perform no
  credential or write operation.

## Deep links

- Added validated UUID entrypoints for `pakperk://paper/...` and
  `https://pakperk.app/p/...`, including paper-comments links.
- Added modern and legacy arXiv parsing, safe encoded-slash transport, and
  `/arxiv/:arxivId` resolution through the existing exact-ID API route.
- Public paper/arXiv invocations receive fresh reader keys and always start on
  Abstract. A connection opened from either public entrypoint is pushed above
  its source; Back returns to the source Connections stage without polluting the
  restored Read stack.
- Absolute URLs accept only the exact production HTTPS origin. Credentials,
  alternate ports, HTTP, queries, fragments, traversal, extra segments,
  malformed UUID/arXiv values, and hostile origins fail closed before a paper
  request.
- Registered Android custom/app links and iOS custom/universal links. The
  remaining external domain association and signed-device procedure is recorded
  in [`mobile-app-links.md`](../mobile-app-links.md).

## Startup and persistence handoff

- Added an explicit `bootstrapping -> localReady ->
  authenticatedSessionChecked -> ready` controller with recoverable timeout,
  retry, and public-cache repair states.
- App construction no longer waits for the network. Session identity,
  restoration, and the first device-cached feed are read concurrently; an empty
  device cache falls back to the bundled feed. Cached content is masked by the
  configured full-text policy before the data-backed widget tree mounts.
- The feed controller is seeded synchronously and performs no constructor
  request when startup supplied a snapshot. Exactly one revalidation begins
  after the first usable Flutter frame. Startup never calls paper preparation.
- Repair clears rebuildable feed/paper/derived/chat preferences while preserving
  the anonymous identity and navigation restoration. Phase 3 will extend that
  boundary to secure account credentials.
- Added generated light/dark Android and iOS launch resources and a static
  centered paper mark via `flutter_native_splash` 2.4.8.
- Added a real-content opening transition: 620 ms cold, 280 ms deep-link, 140 ms
  reduced-motion cross-fade, and no replay for warm/resumed state. The animation
  ends on the actual cached Read tree rather than a mock screen.

## Design system and accessibility

- Extracted paper/moss/ochre light and dark palettes, typography, spacing,
  radii, elevations, sizes, motion, semantic status roles, and skeleton roles.
- Added themes for buttons, cards, chips, navigation, bottom sheets, fields,
  snackbars, and dialogs, with padded Material target sizes.
- Automated coverage checks foreground contrast, selected destination/stage
  semantics, minimum targets, guest honesty, 200% text scaling, reduced motion,
  keyboard insets, and error/offline live regions.
- Abstract body copy uses `Text` rather than `SelectableText`. Flutter's
  selection recognizer intercepted the reader's required horizontal stage
  gesture under the production shell; text selection is not a Production v0.0
  requirement, while deterministic stage paging is.

## Checks run

The repository-integrated command passed:

```bash
./scripts/check.sh
```

That includes Rust formatting, Clippy with warnings denied, workspace unit and
documentation tests, OpenAPI generation/compatibility checks, Flutter
formatting and analysis, and all 123 Flutter tests. Additional native checks
passed:

```text
flutter build apk --debug
flutter build ios --simulator --debug
plutil -lint mobile/ios/Runner/Info.plist mobile/ios/Runner/Runner.entitlements
xmllint --noout mobile/android/app/src/main/AndroidManifest.xml ...
```

The Android build produced `app-debug.apk`; the iOS build produced a simulator
`Runner.app`. Both host manifests parse successfully.

## Exit-criteria evidence

- **Read/You preservation:** controller, widget, platform restoration, branch
  reselection, and system-back tests preserve branch route, feed index, stage,
  preparation intent, and scroll state.
- **Adaptive primary navigation:** a focused widget regression moves the same
  mounted shell from a 390-pixel phone viewport to a 1024-pixel tablet
  viewport, verifies exactly two destinations, selected-branch continuity,
  top/bottom safe-area geometry, and selected destination semantics.
- **Connection restoration:** original feed/restoration tests remain green;
  added UUID and arXiv public-route round trips preserve the source Connections
  view.
- **Composer geometry:** root chat tests assert the navigation bar is covered,
  exactly one keyboard inset is applied, and the composer remains visible.
- **Startup modes:** cold, shortened deep-link, warm, reduced-motion, timeout,
  migration-failure, retry, repair, stale-attempt, and first-frame refresh tests
  pass. Transition constants are bounded at 700 ms.
- **No false account behavior:** Guest You and every Phase 1 future-feature
  route state that its service is disabled; comments expose no `TextField` and
  sign-in has no callback while accounts are off.

## Deferred physical and release verification

- Native-to-Flutter flash continuity, launch timing on defined reference
  devices, Android gesture versus three-button navigation, iPhone home
  indicator, and hardware-keyboard behavior require physical-device runs.
- `pakperk.app` must publish final signed Android asset links and the Apple app
  site association before universal links are release-ready.
- App icons still require final release-brand generation and store review in
  Phase 6; Phase 1 covers native launch assets only.
- SharedPreferences arXiv fallback lookup is linear and startup uses the feed
  row as stored. Phase 2 replaces bulk storage with indexed Drift tables and
  will merge independently newer cached paper rows during normal repository
  revalidation.
- Live PostgreSQL assertions still require CI or `TEST_DATABASE_URL`; this phase
  changes no backend schema or server behavior.
