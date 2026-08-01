# Phase 6 implementation and release-gate report

**Status:** repository implementation present; public/store release not accepted
**Report date:** 2026-08-01
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
  readiness. Guest-only production remains a valid dark-launch shape. Its
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
  Fastlane packages.
- An opt-in reference-provider deletion acceptance harness and manual workflow
  for disposable local Keycloak/PostgreSQL services. It covers real PKCE,
  recent-auth rejection/acceptance, immediate disablement, worker/provider/data
  completion, refresh/session rejection, ledger verify/reapply, replay, and
  secret-safe cleanup without claiming protected-environment evidence.
- A manual, `main`-only staging backend load gate for an exact reviewed commit.
  Its bounded runner validates a 200-record guest preflight, guest feed/metadata
  latency, optional authenticated library/comments reads, explicitly capped
  serialized library mutations and cleanup, deterministic client fault
  profiles, and redacted owner-only aggregate evidence.
- Published release-candidate Privacy, Terms, Community Guidelines, Support,
  open-source notices route, association documents, disclosures worksheet, and
  account-deletion route.
- Release, incident, moderation, deletion, observability, and backup/PITR/
  restore-replay runbooks plus an executable, fail-closed two-phase drill
  harness bound to an immutable expected ledger-record count, including an
  explicit zero-count case, so an empty or wrong ledger mount cannot pass.

Migration `0009_account_deletion.sql` adds deletion ledger/jobs/events/purge
audit and moderation-retention pseudonyms. Long-running processes keep embedded
migrations disabled in deployed values; the one-shot migration job binds its
execution to the reviewed backup ID and expected schema version.

## Repository verification recorded this run

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
  available. The target intentionally returns early without
  `TEST_DATABASE_URL`, while CI supplies the disposable database and executes
  the complete body.
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
  path absent. A live deployed sink, retention job, and alert route remain
  external evidence.
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
- The image-publication workflow validator and tamper cases passed for manual
  dispatch, permissions, exact-source trust, scan/SBOM-before-push ordering,
  immutable tags, and digest-only handoff. The protected workflow was not run,
  and no registry publication is inferred.
- All nine deterministic loopback backend-load contract tests passed, including
  response-identity binding, token/content redaction, mutation serialization
  and cleanup, threshold failures, and request caps. No staging endpoint was
  called; the protected staging workflow result remains required evidence.
- The reference deletion driver's five no-service contract tests and its
  hash-locked workflow validator passed. The destructive Docker/Keycloak suite
  and a protected staging/provider run were not executed in this verification.
- All 21 internal Rust packages are explicitly private (`publish = false`).
  `cargo-deny 0.20.2` passed the bans, licenses, and sources checks with private
  path dependencies allowed; intentional duplicate-version diagnostics remain
  warnings.
- The locked Rust workspace test and documentation suites passed locally with
  all features, as did format and warning-denying Clippy across all targets and
  features. The migration CI service runs the opt-in database extension/
  readiness test, then exercises unique isolated schemas for empty-to-latest,
  version-one-to-latest with a representative paper row, and repeated latest-
  schema no-op runs. Locally the database-backed migration and authenticated-
  router bodies intentionally skip without their explicit database URL, and
  the readiness test remains ignored; a green database-backed CI lane is still
  the evidence for those bodies.
- Final direct Dart formatting and analysis passed on the settled mobile source
  tree. The complete locked Flutter/widget and physical-device matrices remain
  unexecuted for those latest changes, as detailed in the companion report.
- Curated-site static security tests passed. CI and `scripts/check.sh` now feed
  an actual staging Helm render into the CSP/runtime-config assertion instead
  of accepting its no-manifest skip; the targeted local run passed all five
  static assertions. Browser-backed and container security checks must be run
  in an allowed environment; any skip/failure remains a release blocker.

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
  publication and signed-candidate workflows; disclosure/runbook artifacts.
- **Not yet proved externally:** protected staging deletion against the target
  provider with its real secret manager, ledger, alert route, and backup
  inventory; a real backup/PITR restore and deletion replay; live migration/
  rollback exercise; live OTLP retention, adapter, receivers, and canary pages;
  an actual protected staging load result; current advisory/container scans;
  protected image publication/digest promotion and production mobile signing;
  measured startup/cache/crash targets; physical-device QA; legal/content
  review; reviewer account/notes; current store forms; TestFlight/closed Play
  upload and review status.

Therefore Phase 6 is a dark-launch repository candidate, not a declaration that
production feature flags may be enabled. Every external item needs an owner,
timestamp, environment/build, immutable evidence location, and approval.

## Known risks and operator obligations

- The Collector filelog offset store is in-memory; a node-agent restart may
  replay bounded retained files. The sink must tolerate/deduplicate replay and
  operators must test node coverage/rotation.
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
