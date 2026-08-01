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
- Process OTLP plus backend stdout collection/redaction/export; a closed,
  identifier-free mobile telemetry client/gateway; and 30-day operational
  retention configuration.
- Dependency/secret/CodeQL/container scanning, deterministic notices/CycloneDX
  generation, curated site packaging, and environment-protected signed
  AAB/APK/IPA candidate automation with symbols/checksums and optional internal
  store upload.
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
  JIT profile/consent, library, comments, CORS, kill switches, expiration, and
  deletion replay behavior across two router instances. The full workspace
  compiled and passed locally; the target intentionally returns early without
  `TEST_DATABASE_URL`, while CI supplies the disposable database.
- Helm lint/render and positive/negative production-contract validation passed
  with the pinned Helm binary. During the operations audit, the backend stdout
  and direct-OTLP Collector harness passed twice against the pinned image for
  logs, traces, metrics, and resource attributes, with every configured
  protected field and source file path absent. A live deployed sink and its
  retention job remain external evidence.
- Secret initialization was structurally changed to copy/chmod before per-file
  ownership transfer using only `CAP_CHOWN`; the security workflow contains a
  real runtime-image capability smoke.
- Compose configuration and owner-only host-run development account keyring
  generation passed. UID-incompatible container bind mounts are deliberately
  absent; the documented Keycloak account topology runs the Rust API on host.
- Release-metadata regressions passed; Flutter SDK packages without `version:`
  use exact resolved SDK version/revision metadata. Two same-input metadata
  generations were byte-identical.
- All 21 internal Rust packages are explicitly private (`publish = false`).
  `cargo-deny 0.20.2` passed the bans, licenses, and sources checks with private
  path dependencies allowed; intentional duplicate-version diagnostics remain
  warnings.
- The migration CI service runs the opt-in database extension/readiness test,
  then exercises unique isolated schemas for empty-to-latest, version-one-to-
  latest with a representative paper row, and repeated latest-schema no-op
  runs. The migration unit suite compiles and passes in no-database mode, where
  the database-backed body is intentionally skipped. That body and the ignored
  readiness test were not rerun locally after the execution-approval quota was
  rejected, so the next green CI run remains required evidence.
- Curated-site static security tests passed. CI and `scripts/check.sh` now feed
  an actual staging Helm render into the CSP/runtime-config assertion instead
  of accepting its no-manifest skip; the targeted local run passed all five
  static assertions. Browser-backed and container/full repository checks must
  be rerun in an allowed environment; any skip/failure remains a release
  blocker.

The security workflow uses CVSS-4-capable scanner versions. The reachable
`quick-xml` advisory found during final audit was remediated by upgrading to
0.41.0, and JWT verification now uses AWS-LC instead of RustCrypto RSA. The
locked SQLx metadata still contains optional MySQL-only `rsa` and therefore the
exact `RUSTSEC-2023-0071` exception; a preceding
`cargo tree --locked --workspace --all-features --target all` guard fails if
any workspace target can reach `rsa`. That guard produced no reachable package
locally. The post-remediation advisory-database checks were not rerun after the
tool/network approval quota was rejected; a green security workflow running
both guarded `cargo audit` and `cargo deny advisories` is still release
evidence, not an inferred pass.

## Exit-criterion status

- **Implemented, repository-testable:** deletion state machine/monitoring
  surfaces; restore reapply mechanism; independent kill switches; migration and
  rollback procedure; telemetry validation/redaction topology; security/SBOM
  automation; signed-candidate workflow; disclosure/runbook source artifacts.
- **Not yet proved externally:** end-to-end deletion against the target provider;
  a real backup/PITR restore and deletion replay; live migration/rollback
  exercise; live OTLP retention/alerts; load/security testing; measured startup,
  cache, and representative crash targets; protected production signing;
  physical-device QA; legal/content review; reviewer account/notes; current
  store forms; TestFlight/closed Play upload and review status.

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
