# Phase 6 implementation and release-gate report

**Status:** repository implementation present; public/store release not accepted
**Report date:** 2026-08-02
**Last revalidated:** 2026-08-08
**Companion:** [mobile evidence](phase-6-mobile.md)

## Delivered repository boundaries

- Recent-auth `DELETE /v1/me`, non-provisioning deletion verification, immediate
  local disablement, retry-safe operation identity, private/no-store responses,
  and feature-dependent route registration.
- Dedicated least-privilege deletion worker with bounded Keycloak permission
  probe/session revocation/identity deletion, leased retries and terminal state,
  app-data purge/pseudonymization, aggregate backlog telemetry, and operator
  list/inspect/retry/cleanup commands.
- Independently stored, signed, environment-bound deletion records with
  encrypted provider coordinates; owner-only/no-symlink hardening; bounded
  verification/reapply; operator-evidenced final purge; key rotation history;
  and restore-safe JIT tombstones.
- Mobile destructive confirmation/reauthentication flow, callback cleanup,
  secure account-data removal, and hosted browser deletion page. See the
  companion report for native and accessibility coverage.
- Chart-managed API, paper/deletion workers, telemetry gateway, site, GROBID,
  metadata sync, one-shot migrations, OpenTelemetry Collector node agent,
  Services/Ingress/PDBs/NetworkPolicies, external Secret/PVC contracts,
  immutable images, least-privilege identities, and independent feature flags.
- A content-addressed, immutable production alert-policy ConfigMap with 17
  provider-neutral rules and fail-closed Helm validation of its exact SHA-256.
  A platform adapter is still required to supply infrastructure signals,
  receivers, routing, and live canary evidence.
- A second immutable ConfigMap binds the environment and enabled feature set to
  the alert-policy digest, six protected release-evidence content IDs, all four
  deployed image repository/digest identities, chart name/version/app version,
  and document/terms/community-guidelines/full-text policy versions. Production
  always requires legal, reviewer-flow, and strict-content-review evidence.
  Any production account surface requires account deletion and its provider-
  E2E/restore-drill evidence; comments additionally require moderation
  readiness. Guest-only production remains a valid chart dark-launch shape,
  not a release acceptance. Its
  versioned canonical release contract is retained in the ConfigMap alongside
  split image/chart/legal projections and the full binding digest.
- Process OTLP plus backend stdout collection/redaction/export; a closed,
  identifier-free mobile telemetry client/gateway; and 30-day operational
  retention configuration.
- Dependency/secret/CodeQL/container scanning, deterministic notices/CycloneDX
  generation, curated site packaging, and a manual protected workflow that
  accepts only an exact reviewed full commit reachable from `main`, scans the
  exact backend/site images and emits their CycloneDX SBOMs before publication,
  then produces a digest-only Helm promotion handoff.
- Environment-protected signed AAB/APK/IPA candidate automation with symbols,
  checksums, native Android runtime SBOM, optional internal-store upload, exact
  source checkout/ancestry checks, and a reviewed native toolchain/dependency
  boundary: SwiftPM AppAuth-iOS source revision and license, checksum-complete
  Gradle artifacts, MRI Ruby 3.4.10 with RubyGems 4.0.17, and frozen Bundler/
  Fastlane packages. Credential-free preparation publishes its immutable
  binding before candidate execution; Android and iOS signing and upload occur
  on separate fresh runners with only the corresponding secret family, while
  credential-free jobs assemble/finalize the canonical retained evidence.
- A separate manual `production-store` rollout contract that retrieves and
  validates the exact protected production candidate/provenance bytes before
  exposing platform-isolated store credentials; packages trusted tooling from
  the exact workflow revision in an uncredentialed bootstrap, then runs it from
  a literal-hashed closure in fresh no-checkout platform jobs, separately from
  candidate source; and refuses first-publication use. Play binds the highest
  completed fallback and exact
  pre/post state for every reviewed fraction, halt, completion, and protected
  post-completion fallback halt. App Store start proves an exact prior
  `READY_FOR_DISTRIBUTION` version, exact target pre-submit state, and exact
  post-submit `INACTIVE` phased resource; later operations bind exact phased
  state and re-observe mutations. Every selected platform receives a retained
  content-addressed succeeded/failed/not-run outcome before final failure, so
  partial success remains auditable. Repository validators plus hermetic Play,
  App Store, and receipt tests cover the contract; no store was mutated and no
  environment/store approval is inferred.
- An opt-in reference-provider deletion acceptance harness and manual workflow
  for disposable local Keycloak/PostgreSQL services. It covers real PKCE,
  recent-auth rejection/acceptance, immediate disablement, worker/provider/data
  completion, refresh/session rejection, ledger verify/reapply, replay, and
  secret-safe cleanup. The workflow always retains a source-bound scope
  artifact that classifies real staging provider, ledger, backup, alert, and
  approval paths as unexecuted, so it cannot be presented as protected-
  environment evidence.
- An opt-in comments/moderation acceptance harness and environment-gated manual
  workflow restricted to the exact selected `main` tip. It uses hash-locked
  Python dependencies, digest-locked disposable services, separate mobile and
  operator PKCE audiences, fail-closed cleanup, and a closed sanitized evidence
  artifact. Its `manual_ci_disposable_reference` classification does not attest
  hosted environment protection, and its domain-separated `reference-sha256:`
  ID cannot populate production `moderationReadinessId`; target-environment operator,
  safety-action, adapter, alert/staffing, support/deletion/retention, and
  approval evidence remains separate.
- A manual, environment-gated public-edge workflow that always runs its trust
  gate, rejects any dispatch outside the exact selected `main` tip, accepts
  only named protected public coordinates, and performs proxy-free requests
  pinned to publicly resolved addresses. Its 16-scenario closed contract checks
  redirects, TLS/HSTS/security/cache headers, exact runtime configuration,
  distinct legal/support/deletion/license route markers, the site notices
  source marker, protected association identities, the API readiness
  response, and telemetry-gateway process readiness. It retains only owner-only
  sanitized outcomes/digests in an exact-source artifact and fails after upload
  when any observation fails. The domain-separated `public-edge-sha256:` ID
  cannot be substituted for a Helm approval manifest, and the requested image-
  handoff digest remains release-record context rather than observed deployment
  provenance.
- A manual, `main`-only staging backend load gate for an exact reviewed commit.
  Its bounded runner validates a 200-record guest preflight, guest feed/metadata
  latency, optional authenticated library/comments reads, explicitly capped
  serialized library mutations and cleanup, deterministic client fault
  profiles, and redacted owner-only aggregate evidence.
- Checked-in release-candidate Privacy, Terms, Community Guidelines, Support,
  open-source notices route, association documents, disclosures worksheet, and
  account-deletion route.
- Release, incident, moderation, deletion, observability, and backup/PITR/
  restore-replay runbooks plus an executable, fail-closed two-phase drill
  harness bound to a canonical protected restore attestation, exact database
  guard, reviewed worker digest, computed RPO/RTO, immutable ledger-record
  count plus domain-separated signed-record inventory digest, and
  content-addressed owner-only evidence. Its schema-2/v2 evidence contract
  requires verification/reapply/guard/context digest equality and forces the
  attested guard marker as the reapply audit actor. Finalize reopens the actual
  prior package and binds its content ID, exact attestation, chronology, and
  protected core counts, including the explicit zero-count case. A second,
  domain-separated database digest commits to the exact ordered local ledger
  identity tuples and joined deletion-job bindings without exposing provider
  subjects; reapply-after, finalize-before/final, and prior-package validation
  require its continuity. It closes same-count record-set substitution; protected
  storage inventory remains the separate proof of physical volume/object
  identity, especially when the environment-bound logical inventory is empty.
  Restore replay also rejects cross-wired ledger/job bindings, resolves a
  resurrected identity across authenticated UUID/fingerprint/provider
  coordinates, safely deletes a provider-matched row reissued under a new local
  UUID, resets stale completion when recreating a missing job, and requires a
  read-only finalize snapshot with zero surviving matched users.
  Standalone migration and every pooled worker connection also force and verify
  the exact `public, pg_catalog` search path before locks or mutations, overriding
  hostile URL startup options.

Migration `0009_account_deletion.sql` adds deletion ledger/jobs/events/purge
audit and moderation-retention pseudonyms. Follow-on additive migration
`0010_user_reports.sql` makes distinct account-level safety reports part of the
restore/deletion contract, so the release schema version is now `10`.
Long-running processes keep embedded migrations disabled in deployed values;
the one-shot migration job binds its execution to the reviewed backup ID and
that exact expected schema version.

## Repository verification recorded this run

- The final repository-closure audit replaced readable feed, library, comment,
  block, and moderation pagination payloads with bounded AES-256-GCM tokens.
  Tokens are versioned, randomized, and authenticated against an exact purpose
  plus category/account/viewer/status scope. A rotation-ordered owner-only
  keyring is shared by API replicas and moderator tooling; its documented
  append-then-promote two-rollout procedure keeps mixed replicas interoperable.
  A domain-separated, non-secret active-key epoch participates in first-page
  feed validators, so key promotion or same-ID rekeying invalidates stale
  `304` responses before retained decrypt-only keys are retired.
  Public comment regressions specifically reject a guest token for an account,
  an account token for a guest, and a token from another viewer whose block
  filter can produce a different result set. The complete locked Rust
  workspace test command, formatting, check, and warning-denying all-feature
  Clippy passed after this change. A fresh disposable PostgreSQL/pgvector
  database supplied `TEST_DATABASE_URL` and `DATABASE_URL`, so the opt-in
  database and authenticated-router bodies executed and passed. This is local
  disposable-database integration evidence, not protected staging, production,
  or exact-source CI evidence.
- Mobile closure checks now use one process-wide transport status for anonymous
  and authenticated requests. Only a raw response-bearing Dio result can mark
  the service online; local authentication/input failures cannot erase an
  offline result, and a post-`401` refresh failure preserves and forwards the
  real response through that observer. Authenticated handoffs are consumed
  exactly once even when their executor fails; comment safety intents survive
  authenticated thread rehydration, search at most three additional pages,
  and fail once with visible copy when their target is gone. Comment totals
  remain hidden for incomplete or cached pages, and two visible save controls
  observe the same saved-state stream.
  Acceptance UI is disabled when server policy versions differ from the exact
  bundled Terms or Community Guidelines marker, and signed staging/production
  evidence binds both markers to the protected public-document version. Legal
  document loads are stable across rebuilds. Subsequent account-scope hardening
  keys library/comment projections and drafts to the account, auth epoch, and
  paper as applicable; revokes mutation authority during account rebinding and
  authoritative suspended/deletion-pending responses; preserves only bound
  cache/draft access while authentication is offline-unknown; and permits
  read-only accounts to fetch published comments anonymously. On the final
  source tree, Flutter analysis and all 610 locked tests passed, including cold
  restored-identity rebinding, same-epoch account isolation, terminal deletion
  latching, async comment-intent guards, and fail-closed cache purging.
- The public deletion page now retains signed deletion authority through both
  the 400-day minimum and the no-recoverable-backup condition. The environment-
  relative bundled moderation support link resolves to the staging or
  production site origin. All 31 static and browser site tests passed against
  a staging Helm render.
- CI and `scripts/check.sh` now invoke a tested validator that runs `bash -n`
  independently for all 28 top-level shell scripts and rejects an empty,
  symlinked, or syntactically invalid input set. The validator's four
  regressions and the complete shell set passed.
- The full production Helm contract passed with the official checksum-verified
  Helm 3.18.6 binary. The regenerated OpenAPI contract and its 21 compatibility
  regressions passed. The signed-mobile workflow validator passed 36
  regressions; the candidate assembler, finalizer, authenticated-run verifier,
  and candidate validator passed 8, 15, 13, and 43 tests respectively. All nine
  bounded backend-load contract tests passed against their local content-
  redacted mock server.

- Trusted-proxy client-origin unit tests passed, including right-to-left chain,
  spoof resistance, malformed fallback, canonical CIDRs, and keyed address
  hashing.
- Every deletion request, including replay after response loss, now enforces
  recent authentication. A checked-in PostgreSQL integration target composes
  the real router, signed EdDSA JWT verification, loopback OIDC discovery/JWKS,
  two JIT profiles with current consent, and two independent router instances.
  It covers expiry plus provider signing-key removal after the bounded JWKS
  cache, save/remove/tombstone convergence, exact comment replay/edit/stale
  conflict/report/block filtering/delete, account/library/library-write/comment/
  comment-create feature gates, CORS, recent-auth deletion replay, and strict
  full-text masking while metadata, library state, and comments remain
  available. The target intentionally returns early only when
  `TEST_DATABASE_URL` is absent. This local audit supplied a fresh disposable
  database and executed the complete body; CI must repeat it for the exact
  release revision.
- Helm lint/render and positive/negative production-contract validation passed
  with the pinned Helm binary, including feature-dependent release-evidence
  requirements, exact packaged alert digest, production-only alert attachment,
  image/chart/legal-policy-bound content-addressed ConfigMaps, and maximum-
  length DNS names. The same suite rejects non-applicable Kubernetes names,
  labels, selectors, resource/PDB quantities, requests above limits, and OCI
  repositories above the runtime length bound; it also requires API shutdown
  grace beyond the larger request/chat timeout plus preStop and worker grace
  beyond lease ownership. Scheduled metadata input is validated as bounded
  canonical JSON, with exact 1,048,000-byte render parity and 1,048,001-byte
  rejection. Provider endpoints sharing fixed TCP/443 NetworkPolicy edges are
  restricted to that port, and the OIDC issuer is constrained to a query-free,
  fragment-free safe path beneath the exact origin. The alert-
  policy validator and its tamper regressions passed. Release-binding
  regressions individually changed each of the four
  image repositories and digests, a legal date, chart version, app version, and
  feature map and required a different content address every time. These checks
  validate the policy artifact and chart binding, not a deployed alert adapter,
  receiver, image, or external approval.
- During the operations audit, the backend stdout and direct-OTLP Collector
  harness passed twice against the pinned image for logs, traces, metrics, and
  resource attributes, with every configured protected field and source file
  path absent. A subsequent hostile-body regression against the same pinned
  Collector verified that arbitrary scalar and structured direct-OTLP log
  bodies become a static redaction marker, while the separate stdout pipeline
  replaces arbitrary scalar or structured messages with a constant marker and
  preserves only the exact content-free ledger alert for its ERROR severity/
  Rust namespace; fixed stdout service/environment resource upserts defeat
  spoofing. An exact
  closed-schema mobile event keeps its identity. The harness also rejects drift
  between the gateway and Collector mobile-event allowlists. A live deployed
  sink, retention job, and alert route remain external evidence.
- Secret initialization was structurally changed to copy/chmod before per-file
  ownership transfer using only `CAP_CHOWN`; the security workflow contains a
  real runtime-image capability smoke.
- Compose configuration and owner-only host-run development account keyring
  generation passed. Every external Compose dependency used by the deletion
  topology is tag-and-digest pinned, with a tamper regression that rejects a
  mutable tag. UID-incompatible container bind mounts are deliberately absent;
  the documented Keycloak account topology runs the Rust API on host.
- Release-metadata regressions passed; Flutter SDK packages without `version:`
  use exact resolved SDK version/revision metadata, and both checked-in SwiftPM
  lockfiles must agree on AppAuth-iOS 2.0.0 at its reviewed full revision with
  a checked-in license. Two same-input metadata generations were byte-identical
  and the generated inventory contained 494 components.
- The checked-in Gradle verification inventory covers every resolved artifact
  with one SHA-256 and no trust exception, including both hosted-runner AAPT2
  variants. Its structural/tamper checks passed. The frozen Fastlane 2.235.0 /
  Bundler 2.6.9 graph and every RubyGem checksum passed its validator. The
  signed-workflow contract also rejects anything except MRI Ruby 3.4.10 and
  RubyGems 4.0.17 before any gem/Bundler operation and records the resolved
  executable and versions. A current Android production-runtime CycloneDX 1.6
  artifact with 102 components passed the native SBOM validator. The validator
  binds an exact reviewed purl inventory to the Pub/Gradle/checksum-policy
  inputs and requires exact app identity/version, a closed dependency graph in
  which every component is reachable, exact component `bom-ref`/purl agreement,
  the release Flutter engine, and reviewed AppAuth/Tink identity, license, and
  checksums. The current artifact's graph contains the application root plus
  102 component nodes. These are repository and current-artifact checks; they
  do not prove a protected signed candidate.
- Flutter release resolution is also fail-closed on the exact reviewed SDK
  identity: Flutter 3.44.8 at framework revision
  `058e0af2c2b57e369d905a03ac9748b0ebf543c6` with Dart 3.12.2. The signed-
  mobile, security, and release-image workflows validate and retain that
  machine-readable identity before resolving Pub dependencies.
- The image-publication workflow's 47 validation tests passed. The signed-
  mobile workflow's 36 workflow-validator tests, 8 assembler tests, 15
  finalizer tests, 13 authenticated-run verifier tests, and 43 candidate-
  validator tests passed. Its exact eight-job surface is credential-free
  preparation; isolated Android and iOS signers; credential-free signed-
  candidate assembly; uncredentialed store-client bootstrap; isolated no-
  checkout Android and iOS uploads; and an always-run credential-free
  finalizer. Executable source gates fail non-`main`, tag, or mismatched exact-
  SHA dispatches rather than completing as skipped green jobs. The
  authenticated-run verifier requires distinct immutable candidate, store-
  handoff, and signed-release-outcome artifacts by server-issued ID and raw
  digest. Image building, uncredentialed archive scanning/SBOM creation, and
  protected publication remain isolated on three fresh runners. Neither
  protected workflow was run, so no registry publication, signed candidate, or
  store upload is inferred. GitHub deployment-branch/environment protection is
  still required to prevent dispatching historical refs that contain an older
  copy of either workflow.
- The repository contract for the protected physical-mobile acceptance lane
  passed 42 closed-evidence and 63 workflow-tamper regressions. The lane requires
  exact staging coordinates from the
  reviewed config, content-addressed signed-release provenance, a short-lived
  root-owned dedicated/ephemeral runner attestation, four distinct
  challenge-keyed physical identities, direct exclusive archive publication,
  pre-upload verification, and a digest-bound upload. No protected runner,
  staging account, or physical device was exercised locally.
- The restore harness passed 20 hermetic adversarial regressions for canonical
  schema-2 attestation and guard bindings, exact ledger counts and inventory
  digests, exact local ledger/job binding continuity, same-count substitution,
  hostile URL search-path, and reapply-drift rejection, private bounded worker
  output, source-concealment flags, bound actor override rejection, atomic
  cleanup, and content-addressed cross-file evidence tamper detection.
  Its v2 finalize and standalone verifier reopen the actual reapply package and
  require its phase, computed content ID, byte-identical attestation, protected
  snapshot continuity, prior-before-final chronology, and
  `restore_completed_at <= recorded_at <= restore_completed_at + 24h`. A real
  provider backup, independent ledger set, isolated database, and external
  content-ID anchor remain protected evidence.
- All nine deterministic loopback backend-load contract tests passed, including
  response-identity binding, token/content redaction, mutation serialization
  and cleanup, threshold failures, and request caps. A new structural validator
  and 55 validation tests lock the manual dispatch inputs and runtime allowlists,
  unconditional job,
  protected environment/variables, step-scoped token, bounded runner, evidence
  upload, and final enforcement; non-`main` dispatch now fails in the executable
  trust gate. No staging endpoint was called; the protected staging workflow
  result remains required evidence.
- The reference deletion driver's six no-service contract tests and its
  hash-locked workflow validator passed. Eight workflow-validation tests also
  enforce manual-only execution, least privilege, immutable scope upload, and
  the non-release classification. On a fresh isolated Docker project, the full
  Keycloak/PostgreSQL suite passed PKCE/recent-auth, immediate disablement,
  signed-ledger creation and exact replay, worker session/provider/data purge,
  restore-ledger reconciliation, log redaction, and scoped cleanup. This does
  not replace a protected staging/provider run.
- The live-comments workflow validator's 51 validation tests cover manual
  dispatch, unconditional exact-main source trust, least privilege,
  dependency/image pins, dedicated operator audience, evidence-only upload,
  bounded retention, disposable cleanup, and non-recoverable final enforcement.
  Separately, a fresh isolated Docker reference stack passed the three-user
  PKCE, audience/allowlist denials, create/edit/delete/report/block, moderator
  audit, creation-kill, unavailable-IdP guest-read, log-redaction, and cleanup
  matrix. No staging moderation-readiness approval is inferred.
- The public-edge evidence/verifier regressions passed 24 hermetic cases,
  including closed success/failure matrices, hostile JSON/header/body shapes,
  stable route markers, source mismatch, unsafe origins, private/multicast/
  transition IPv6 DNS answers, proxy/custom-CA authority, bounded reads, and
  private atomic evidence publication. Eighty-three workflow tamper regressions
  enforce unconditional non-main rejection, exact main-tip/source bindings,
  protected variable-only coordinates, least privilege, fail-closed evidence
  packaging/upload/result semantics, and truthful scope. The live workflow was
  not dispatched and no deployed URL, environment protection, legal approval,
  candidate custody, deployment provenance, physical link behavior, deletion
  completion, or telemetry export/sink delivery is inferred.
- API live/ready responses, including failed readiness, and telemetry-gateway
  live/ready responses now emit one exact `Cache-Control: no-store`; focused
  router tests (including a synthetic outer timeout), generated OpenAPI parity,
  and warning-denying targeted Clippy passed. This prevents a stale
  intermediary readiness success while keeping mobile telemetry best-effort
  and Collector/export/sink proof in its separate live-canary gate.
- All 23 internal Rust packages are explicitly private (`publish = false`).
  `cargo-deny 0.20.2` passed the bans, licenses, and sources checks with private
  path dependencies allowed; intentional duplicate-version diagnostics remain
  warnings.
- The locked Rust workspace test and documentation suites passed locally with
  all features, as did format and warning-denying Clippy across all targets and
  features. The migration CI service runs the opt-in database extension/
  readiness test, including a negative regression that relocates `pgcrypto`
  outside `public` and requires readiness to fail before restoring it, then
  exercises the real standalone migrator against unique disposable databases
  for hostile-path empty-to-latest, version-one-to-latest with a representative
  paper row, wrong-extension-namespace rejection, and repeated latest-schema
  no-op runs. Locally, a fresh disposable PostgreSQL/pgvector database
  ran the database-backed migration, deletion, comment, behavior, and
  authenticated-router bodies. The explicitly ignored extension/readiness test
  was also invoked with its exact ignored-test selector and passed. These are
  local disposable-database results; a current exact-source green CI lane and
  protected target-environment execution remain separate release evidence.
- On the final current-tree canonical run, direct Dart formatting, Flutter
  analysis, all 610 locked tests, every Android debug flavor, every iOS
  simulator flavor, and strict staging/production artifact inspection passed.
  The physical-device matrix remains unexecuted, as detailed in the companion
  report.
- Curated-site static and browser security tests passed all 31 cases against an
  actual staging Helm render, including the CSP/runtime-config assertion and
  distinct report-user/report-comment/block copy. The opt-in Collector
  container E2E also passed twice in separate local runs against the pinned
  image. That remains local process/stdout/export/redaction evidence, separate
  from a deployed sink, retention job, alert route, and protected canaries.

The security workflow uses CVSS-4-capable scanner versions. The reachable
`quick-xml` advisory found during final audit was remediated by upgrading to
0.41.0, and JWT verification now uses AWS-LC instead of RustCrypto RSA. The
locked SQLx metadata still contains optional MySQL-only `rsa` and therefore the
exact `RUSTSEC-2023-0071` exception; a preceding
`cargo tree --locked --workspace --all-features --target all` guard fails if
any workspace target can reach `rsa`. That guard produced no reachable package
locally. Current advisory-database and container scans require the protected,
networked security workflow; a green run of guarded `cargo audit`, `cargo deny
advisories`, and the image scanners remains release evidence, not an inferred
pass from the repository validators.

## Exit-criterion status

- **Implemented, repository-testable:** deletion state machine/monitoring
  surfaces; reference-provider deletion harness; restore reapply mechanism;
  independent kill switches; migration and rollback procedure; telemetry
  validation/redaction topology; immutable alert/evidence contracts; bounded
  staging-load harness; security/source/native SBOM automation; exact-SHA image
  publication and signed-candidate workflows; disposable comments/moderation
  workflow and sanitized evidence contract; source-bound public-edge workflow
  and sanitized evidence contract; disclosure/runbook artifacts.
- **Not yet proved externally:** protected staging deletion against the target
  provider with its real secret manager, ledger, alert route, and backup
  inventory; a real backup/PITR restore and deletion replay; live migration/
  rollback exercise; live OTLP retention, adapter, receivers, and canary pages;
  an actual protected staging load result; complete protected staging
  moderation readiness for the target operator/adapter/alerts/staffing matrix;
  a successful protected public-edge run for the exact dark-deployed candidate;
  current advisory/container scans;
  protected image publication/digest promotion and production mobile signing;
  protected production-store rollout execution and store audit reconciliation;
  measured startup/cache/crash targets; physical-device QA; legal/content
  review; reviewer account/notes; current store forms; TestFlight/closed Play
  upload and review status.

Therefore Phase 6 is a dark-launch repository candidate, not a declaration that
production feature flags may be enabled. Every external item needs an owner,
timestamp, environment/build, immutable evidence location, and approval.

## Known risks and operator obligations

- The Collector filelog offsets and exporter retry queue use separate bounded,
  Pod-scoped `emptyDir` stores. A container restart within that Pod preserves
  both, but Pod replacement, rescheduling, or node loss may replay bounded
  retained files. The sink must tolerate/deduplicate replay and operators must
  test node coverage, rotation, and queue saturation.
- Ingress proxy CIDRs must match source addresses actually observed by the API,
  while the controller trusts forwarded addresses only from platform load
  balancers. An internet-wide trusted range is forbidden.
- Final deletion-ledger files outlive recoverable backups and require historical
  signing/decryption keys. Cleanup never deletes final records; final purge is
  one-operation, evidence-checked, and operator-controlled.
- Android upload-key evidence is not the installed Play identity. Association
  files use the protected Play App Signing certificate fingerprint.
- Store history, signing keys, infrastructure retention, contacts, and legal/
  moderation staffing are intentionally external and cannot be inferred from
  this repository.
- A rollout outcome receipt proves which bounded API attempt succeeded, failed,
  or was not run, including dependency-skipped and partial-success cases; it
  does not prove that either store approved or fully propagated a release.
  Store-side history and the exact-candidate observation window remain
  required. A pre-completion halt is terminal and uses a higher fix-forward
  build; Android alone also has the protected post-completion fallback halt
  described in the release runbook.
- Public-edge evidence observes the site notices source marker and expected
  public response contracts. Platform owners must still compare actual Pod
  image IDs and the immutable release-binding ConfigMap with the protected
  promotion handoff; the requested candidate digest is not edge-observed.
