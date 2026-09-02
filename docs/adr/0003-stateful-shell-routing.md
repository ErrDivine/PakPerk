# ADR 0003: Stateful shell routing

**Status:** Accepted — core decision implemented in Phase 1; Library branch added later
**Date:** 2026-07-31

## Context

The demo's custom Navigator had a feed root and paper routes. Phase 1 added Read
and You destinations, each of which had to retain its own stack and restoration
state. Deep links had to open a paper in Read without discarding the retained
state of the other destinations, while paper-reader horizontal stages remained
local UI state rather than routes.

## Decision

The Phase 1 decision was to adopt `go_router` using
`StatefulShellRoute.indexedStack` with Read and You branches. The shell owned
persistent primary navigation and separate branch navigators. Paper detail
routes belonged under Read; account and then-current library routes belonged
under You. Root-level paper chat and comments routes covered the shell as
modal/full-screen routes.

## Current implementation

Later Library work extended the indexed stack without replacing the core
decision. The visible primary destinations are now Read, Library, and You, each
with its own stateful branch navigator. The shell uses a bottom navigation bar on
narrow layouts and a navigation rail on wider layouts. Read owns paper routes,
Library owns `/library`, and account, settings, and account-owned management
routes remain under You. The old `/you/library` location is a compatibility
redirect to `/library`. Root-level paper chat and comments routes still use the
root navigator and cover the shell as full-screen routes.

Persisted branch indexes deliberately retain the original `Read = 0, You = 1`
mapping and assign `Library = 2`, while the visible shell order is Read, Library,
You. Keeping persistence identity separate from display order prevents an older
restored You session from reopening in Library.

The Read root retains the existing page-based linked-paper navigator inside its
branch. This deliberately preserves the demo's exact paper trail, stage, scroll,
and system-back restoration while `go_router` owns the production shell and
public routes. Page restoration IDs are stable, and each new public paper/arXiv
invocation receives a fresh reader-state key rather than reusing a prior
in-screen stage. Ordinary public links begin on Abstract; the validated internal
map intent may explicitly begin on Connections. The paper reader's Abstract,
Introduction, and Connections stages remain local interactions with the existing
committed-transition preparation boundary.

## Consequences

- Switching primary destinations preserves scroll position, nested navigation,
  and selected state instead of rebuilding destinations.
- Routes support `/read`, `/read/paper/:paperId`, public `/p/:paperId` and
  `/arxiv/:arxivId` entrypoints, `/read/paper/:paperId/chat`,
  `/read/paper/:paperId/comments`, `/library`, the compatibility redirect
  `/you/library`, `/you`, and settings/account destinations without making chat
  or comments additional primary destinations.
- Opening a saved paper from Library intentionally pushes a Read route above the
  retained Library branch, so normal back navigation returns to the exact saved
  list route.
- Router, deep-link, restoration, back-navigation, and feature-flag behavior
  require focused widget and integration tests.
- Disabled destinations must route coherently to an explanation or available
  guest surface, never leave dead navigation controls.
- The nested Read navigator is an intentional compatibility seam. It should be
  reconsidered only after a migration can prove identical Connections,
  back-navigation, and scroll-restoration behavior.

## Security and operational implications

- A deep link never supplies authority; protected actions still require the
  resolved server principal.
- Route parameters are treated as untrusted identifiers and validated before
  loading data.
- Restoration data must not include tokens, private profile data, comment
  bodies, or other sensitive material.
- Stateful branch lifetime needs memory observation and cache-boundary testing
  on lower-end devices.
