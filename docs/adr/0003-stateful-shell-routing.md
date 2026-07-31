# ADR 0003: Stateful shell routing

**Status:** Accepted — implemented in Phase 1
**Date:** 2026-07-31

## Context

The demo's custom Navigator has a feed root and paper routes. Production adds a
Read destination and a You destination, each of which must retain its own stack
and restoration state. Deep links must open a paper without resetting the
selected destination, while paper-reader horizontal stages remain local UI state
rather than routes.

## Decision

Adopt `go_router` using `StatefulShellRoute.indexedStack` with Read and You
branches. The shell owns persistent bottom navigation and separate branch
navigators. Paper detail routes belong under Read; account and library routes
belong under You. Root chat and comments surfaces cover the shell as modal/full
screen routes.

The Read root retains the existing page-based linked-paper navigator inside its
branch. This deliberately preserves the demo's exact paper trail, stage, scroll,
and system-back restoration while `go_router` owns the production shell and
public routes. Route restoration IDs are stable, and each public paper/arXiv
invocation receives a fresh reader key so it begins on Abstract rather than
reusing a prior in-screen stage. The paper reader's Abstract, Introduction, and
Connections stage remains local interaction with its existing
committed-transition preparation boundary.

## Consequences

- Switching tabs preserves scroll position, nested navigation, and selected
  state instead of rebuilding destinations.
- Routes support `/read`, `/read/paper/:paperId`, public `/p/:paperId` and
  `/arxiv/:arxivId` entrypoints, `/read/paper/:paperId/comments`, `/you`,
  `/you/library`, and settings/account destinations without making comments a
  third primary tab.
- Router, deep-link, restoration, back-navigation, and feature-flag behavior
  require focused widget and integration tests.
- Disabled destinations must route coherently to an explanation or available
  guest surface, never leave dead navigation controls.
- The nested Read navigator is an intentional compatibility seam. It should be
  reconsidered only after a migration can prove identical connection/back and
  scroll restoration behavior.

## Security and operational implications

- A deep link never supplies authority; protected actions still require the
  resolved server principal.
- Route parameters are treated as untrusted identifiers and validated before
  loading data.
- Restoration data must not include tokens, private profile data, comment
  bodies, or other sensitive material.
- Stateful branch lifetime needs memory observation and cache-boundary testing
  on lower-end devices.
