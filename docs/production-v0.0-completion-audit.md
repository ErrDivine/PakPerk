# Production v0.0 completion audit

**Status:** repository implementation audited; public/store release not accepted

**Audit date:** 2026-08-03

**Last revalidated:** 2026-08-08

**Authority:** the [canonical implementation plan](../pakperk_production_v0_0_implementation_plan.md)
remains normative

This document maps the canonical phase exit criteria, cross-phase acceptance
scenarios, and Production Definition of Done to the evidence that exists in the
repository and to the evidence that must still be produced outside it. It is an
evidence index, not a replacement for the canonical plan, a release approval,
or permission to enable production feature flags.

## Classification and release boundary

- **R — repository-proven:** the implementation and deterministic, integration,
  contract, or reference-stack evidence exist in the repository.
- **P — protected/external:** completion requires credentials, deployed systems,
  protected environments, signed artifacts, physical devices, representative
  traffic, or an immutable result that source control cannot manufacture.
- **H — human approval:** completion requires accountable operator, legal,
  privacy, content, security, UX, or store judgment.

`R/P` means that the source implementation is present while the protected gate
is still open. It never means that the canonical requirement passed in
production. Checked-in workflow YAML, validators, fixtures, simulator runs,
reference Keycloak/PostgreSQL exercises, and a workflow dispatch without its
retrievable passing artifact are **R**, not **P**. A human statement, ticket
number, mutable URL, or hash of an assertion is not **H** evidence.

Phases 0–5 are accepted repository milestones under their scoped reports.
Phase 6 has a dark-launch repository implementation, but its production and
store exit criteria remain open. Consequently, Production v0.0 is **not
complete** and public account/comment flags and store release must remain
blocked until every applicable **P** and **H** item below has immutable evidence.
The known locally implementable gaps identified during this audit are reflected
in the repository. The final local current-tree canonical harness passed the
fresh-database Rust workspace, Flutter analysis and all 610 locked tests, every
Android debug and iOS simulator flavor, strict artifact inspection, 31 browser
tests, Helm validation, and the opt-in Collector export E2E. Fresh isolated
Keycloak/PostgreSQL reference runs also passed the complete account-deletion
worker/ledger/reconciliation and comments/moderation/IdP-outage matrices with
redaction and cleanup. That evidence does not prove the absence of every further
local defect and does not reduce or replace any protected execution or human
approval.

## Phase exit-criteria map

The phase reports establish historical phase acceptance only. Later production
gates do not retroactively reopen those repository milestones, and an accepted
phase does not satisfy Sections 22 or 23 by itself.

| Phase | Canonical exit criteria | Audit classification | Evidence boundary |
| --- | --- | --- | --- |
| 0 — baseline | Demo behavior and API fixtures unchanged; `scripts/check.sh` passes; OpenAPI covers existing routes; no account surface is public at the phase boundary | R | Accepted in the [Phase 0 report](phase-reports/phase-0.md). Current exact-source CI/security evidence is separately required for a release. |
| 1 — shell/startup | Read/You and reader state restore; connection back navigation works; navigation does not overlap chat; cold/warm/reduced-motion paths pass; no false account capability | R, with P/H production UX confirmation | Accepted in the [Phase 1 report](phase-reports/phase-1.md). Signed physical launch, safe-area, motion, and usability evidence remains in the mobile gates below. |
| 2 — Drift/prefetch | Migrated cache opens offline; sequential cache hits meet the target; rapid swipes share a request; bounds and saved-paper pin are enforced; prefetch never prepares | R, with P performance confirmation | Accepted in the [Phase 2 report](phase-reports/phase-2.md). The shared cache policy and accessible cache-miss skeleton are now covered by current mobile tests; signed-device measurements remain external. |
| 3 — accounts | Guest reading survives IdP outage; reference user registration/sign-in works; tokens avoid general storage/logs; one refresh; invalid refresh preserves public cache; profile versioning; coherent feature disable | R/P | Accepted at the reference/repository boundary in the [Phase 3 report](phase-reports/phase-3.md). Release-tenant registration, redirects, callbacks, signing, and installed-device behavior remain protected. |
| 4 — To Read | Immediate save/unsave; two clients converge; offline save drains; duplicate writes collapse; library never prepares; saved metadata survives eviction | R/P | Accepted at the deterministic/reference two-client boundary in the [Phase 4 report](phase-reports/phase-4.md). Two independently installed devices against protected staging remain required. |
| 5 — comments | Safety controls precede enablement; blocking is immediate/persistent; reports are idempotent; suspended users cannot post; UGC is absent from telemetry; audited moderator action; creation kill preserves reads | R/P/H | Accepted as a default-off repository capability in the [Phase 5 report](phase-reports/phase-5.md). Target moderation infrastructure, staffing, canaries, and Trust & Safety approval remain required. |
| 6 — release | Deletion completes and is monitored; restore reapplies deletion; no P0 issue remains; migration/rollback is exercised; startup/cache/crash targets pass; disclosures match reality; independent kill switches preserve reading | R/P/H — release exit not accepted | Repository implementation is recorded in the [Phase 6 report](phase-reports/phase-6.md) and [mobile Phase 6 report](phase-reports/phase-6-mobile.md). Every remaining protected live, physical, signing, real-restore, policy-approval, and store item is governed by the immutable-evidence inventory below. |

## Section 22 cross-phase acceptance matrix

No scenario is declared production-passed by this audit. The **R** column
identifies behavior that can be trusted from the repository; the final column
identifies what still prevents canonical acceptance.

| Scenario | Repository-proven behavior | Classification and remaining evidence |
| --- | --- | --- |
| 22.1 Guest reader | Cached anonymous feed; stale cached abstract remains visible during revalidation; accessible paper-shaped cache-miss skeleton; 200-record bounded traversal with zero blank cards; Introduction prepares only after committed intent; exact Read/You reader restoration; guest comment reads; canonical arXiv action; offline Drift cache | R/P/H — fresh signed install, native launch continuity, controlled-latency physical traversal, OS-browser handoff, process-death offline relaunch, and visual-polish approval |
| 22.2 Save from guest | Sign-in rationale; credential-free pending intent; exactly-once handoff; AppAuth/JIT provisioning boundary; optimistic star; To Read projection; idempotent duplicate callback/retry | R/P — release IdP and exact installed-candidate guest-to-auth-to-save flow |
| 22.3 Cross-device library | Two logical clients converge through revision changes and tombstones; durable offline outbox and retry behavior | R/P — two distinct installed devices against the protected staging account |
| 22.4 Comment lifecycle | Guest/auth/onboarding/rules gates; stable client request ID; exact replay; optimistic-version edit and stale conflict; repeat-safe delete and public disappearance; mobile, service, PostgreSQL, and disposable reference-stack evidence | R/P — exact signed candidate, release tenant, and target staging service |
| 22.5 Safety | Separate comment report, user report, and block; repeat-safe report; immediate and durable filtering; audited hide/suspend/restore; creation kill preserves reads and safety actions | R/P/H — target moderator audience/allowlist, adapter credentials, live queues, alert/ticket canaries, staffed response targets, escalation exercise, and Trust & Safety approval |
| 22.6 Credential expiry | One safe 401 refresh/replay; proactive and concurrent single-flight; invalid refresh returns to guest; public cache/reader state remains; account-owned data is cleared or detached | R/P — real release-IdP expiry and invalidation on the installed candidate |
| 22.7 Account deletion | Consequence/recent-auth UI; immediate disablement; session/provider adapter; retry-safe worker and data purge; local cleanup; reference-provider E2E; independent ledger verification/reapply; fail-closed two-phase restore harness | R/P/H — real secret manager/provider, independent ledger, alert route, backup inventory, isolated PITR restore/replay, and privacy/recovery approvals |
| 22.8 Strict content policy | Metadata/save/comments/canonical arXiv remain; prototype-derived caches and offline fallbacks are masked in mobile and backend tests | R/P/H — exact signed strict candidate and deployed backend plus qualified content-rights approval |

The protected mobile workflow requires an exact `main` revision, root-imported
content-addressed candidate and signed-release provenance manifests, pinned
root-owned validator and driver bytes, a short-lived root-owned
dedicated/ephemeral runner-session attestation, and four exact physical roles:
Android gesture, Android three-button, iPhone home-indicator, and
physical-keyboard iPad/second sync. The candidate checkout is a data-only input:
no candidate-provided program executes in the credentialed runner session. Its
schema-v2 artifact requires all 16 ordered scenarios with their exact role
assignments, 70 ordered assertion IDs, 37 closed integer metrics, exact platform
artifact/application/signer/team bindings, four challenge-keyed physical-
identity hashes recomputed from distinct root-attested commitments, and a fresh
run challenge/ID/attempt/time window. Its orchestration and validators are
repository evidence. Only authenticated root-side provenance/session import and
a passing protected artifact for the installed candidate, together with the
environment approval, can satisfy the corresponding **P** rows. See the
[mobile release runbook](mobile-release.md).

## Section 23 Production Definition of Done

### Product

| Requirement | Audit classification | Open evidence |
| --- | --- | --- |
| Read/You shell is stable and intuitive | R/P/H | Signed-device navigation/restoration and accountable usability judgment |
| Anonymous reading remains first-class | R/P | Deployed outage and installed offline paths |
| Opening motion is polished, bounded, and accessible | R/P/H | Physical timing/continuity, reduced-motion checks, and visual approval |
| Save/To Read works online, offline, and across devices | R/P | Protected two-device installed flow |
| Public comments include complete safety controls | R/P/H | Protected moderation-readiness matrix and Trust & Safety approval |
| Account page includes sign-out and deletion | R/P | Real-provider installed deletion flow |
| Empty/loading/error/offline states are designed | R/P/H | Physical accessibility/visual review; repository feed skeleton closes the prior source gap |
| No future communication feature is implied as available | R/H | Final product/store copy review; repository reviewer notes explicitly disclaim direct messaging/follows/presence |

### Mobile engineering

| Requirement | Audit classification | Open evidence |
| --- | --- | --- |
| Bulk cache is in Drift | R | None beyond exact-source CI |
| Tokens are restricted to memory/platform secure storage | R/P | Signed-device platform storage and backup inspection |
| OIDC uses system browser and PKCE | R/P | Release tenant, registered callback, and physical flow |
| Auth refresh is single-flight | R | Protected expiry path remains part of Section 22.6 |
| Prefetch never triggers preparation | R | None beyond exact-source CI |
| Cache is bounded and saved papers are pinned | R/P | Signed-device size/cache-hit measurements |
| Bottom navigation and contextual composers do not overlap | R/P | Android gesture/three-button and iOS home-indicator devices |
| Light/dark/reduced-motion/text-scale paths pass | R/P/H | Physical matrix and visual/accessibility approval; compact Save/Comments/arXiv also has 320-pixel, 200% text, semantics, target-size, and keyboard-order tests |
| Deep links and restoration pass | R/P | Deployed associations plus physical cold/warm links and callbacks |
| Production flavors contain no secrets | R/P | Exact signed-artifact inspection and current secret/security scans |

### Backend engineering

| Requirement | Audit classification | Open evidence |
| --- | --- | --- |
| API is split into maintainable routes/middleware | R | None beyond exact-source CI/review |
| OIDC JWT validation is strict | R/P | Protected release-issuer rotation/removal: a replacement-key token is accepted, a removed-key token is rejected after the configured cache bound, and token expiry/refresh is exercised |
| Authorization never trusts client user IDs | R | None beyond exact-source CI and protected abuse checks |
| Library and comment writes are idempotent | R/P | Protected staging replays of the exact same library operation and exact same comment operation with the same idempotency identities, stable outcomes, and one durable side effect each |
| Shared rate limits work across instances | R/P | Protected cross-replica quota exhaustion with stable HTTP 429, `RATE_LIMITED`, and delta-seconds `Retry-After` evidence |
| Comments are filtered, moderated, reportable, and blockable | R/P/H | Target moderation-readiness evidence |
| Account deletion is idempotent and monitored | R/P/H | Target deletion E2E, live alerts, and privacy approval |
| OpenAPI is generated and checked | R | Generated parity and base-compatibility gates must pass for the release revision |
| Existing paper pipeline tests pass unchanged | R | Exact-source CI must remain green with no target-environment skip |
| Full-text policy remains enforced | R/P/H | Signed/deployed strict candidate and qualified review |

### Operations and security

| Requirement | Audit classification | Open evidence |
| --- | --- | --- |
| Staging mirrors production auth and data flow | R/P | Actual deployed topology/config/image identities and end-to-end smoke evidence |
| Migration job and expand/contract process exist | R/P | Source/process exists; staging execution and rollback result remain protected |
| Backup and restore drill passed | R/P/H | Hermetic 20-test harness is repository evidence; a real isolated restore, RPO/RTO result, deletion replay, and approvals remain open |
| Deletion ledger survives restore | R/P/H | Logical inventory/reapply/finalize contracts are repository evidence; protected storage identity, current-ledger inventory, real replay, and privacy approval remain open |
| OTLP telemetry is live and redacted | R/P | Live sink, retention, redaction, replay, and receiver canaries |
| Security/dependency/container scans pass | R/P/H | Current exact-source/image scans and approved disposition of every finding |
| SBOM and license inventory exist | R/P | Generators/notices exist; exact protected image/mobile artifacts and checksums remain required |
| Feature kill switches are tested | R/P | Repository behavior exists; every independently controlled feature/kill switch still needs a dark-deployed before/after result under a valid dependency combination |
| Incident, moderation, and deletion runbooks exist | R/H | Runbooks exist; named staffed ownership and exercise approvals remain human |

### Store and policy

| Requirement | Audit classification | Open evidence |
| --- | --- | --- |
| Privacy policy is accurate | R/P/H | Exact deployed data/processors/retention, published version, and privacy/legal approval |
| Terms and Community Guidelines are published | R/P/H | Public HTTPS responses, exact versions, and legal approval |
| Support contact is published | R/P/H | Public route and monitored reachable contact with owner |
| In-app report and block are functional | R/P | Exact signed candidate against staging |
| In-app account deletion is functional | R/P | Exact signed candidate through real provider completion |
| Web deletion request is functional | R/P | Public-edge route and real-provider completion/status path |
| Data Safety/App Privacy disclosures match actual SDKs | R/P/H | Signed archive inventories, deployed processors, current questionnaires, and approvers |
| Reviewer account/instructions are prepared | R/P/H | Sanitized exact-candidate notes and protected disposable-account lifecycle |
| Full-text display/retention received appropriate review | R/P/H | Qualified approval bound to exact policy and candidate |
| Package/build versions increase monotonically | R/P/H | Checked-in version gate plus both stores' private history and upload receipts |

## Section 2.4 optional P1 disposition

The repository now includes the practical broad-launch P1 items for My
Comments, post-onboarding display-name editing, tablet `NavigationRail`
adaptation, and local saved-paper sort/search/category filtering. These remain
subject to the same installed-device and UX approval gates as their P0 parent
surfaces.

The following P1 items are deliberately deferred, as Section 2.4 permits for
the first internal/TestFlight/closed-track release: machine-readable account
export, a network remote-flag service beyond protected build/environment flags,
an optional third-party crash provider beyond the privacy-safe telemetry
interface and store diagnostics, a moderation web UI beyond the authenticated
admin CLI fallback, and cloud read-progress synchronization. They do not block
P0 release acceptance. Reassess their data model, privacy/disclosure, abuse,
offline-conflict, operations, and migration impact before broad launch; do not
represent them as shipped capabilities in product or store copy.

## Required immutable evidence for every open P/H gate

Every protected evidence object must be stored in the approved immutable release
system and be retrievable by its content ID. Unless a stricter closed workflow
schema applies, its canonical manifest must include:

- SHA-256 content ID of the manifest bytes and SHA-256 digests of every attached
  artifact;
- exact 40-character source revision, app version/build, Helm chart/app version,
  and every deployed or candidate image/artifact digest in scope;
- target environment and sanitized exact service/issuer/application identities;
- UTC start/end window, result, measured assertions or sample counts, and explicit
  failures or limitations;
- tool, scanner, driver, policy, configuration, and workflow identities/digests;
- accountable owner and approver roles, approval timestamp, and a protected
  environment/store audit record bound to the manifest digest;
- an explicit statement that credentials, tokens, cookies, device serials,
  personal data, raw UGC, and unbounded logs are absent.

An approval is valid only when the approver can retrieve and verify the exact
manifest and artifacts. The following inventory is the minimum known set for
the remaining release gates identified by this audit; it is not an exhaustive
substitute for the canonical plan, current store/provider requirements, or a
newly applicable risk review. Any additional applicable gate remains blocking
until it has equally bound, retrievable evidence.

| Gate | Exact immutable evidence required | Owner/approval and reference |
| --- | --- | --- |
| Current CI and security | Exact revision; all required CI job outcomes; target-environment database/integration bodies with no unexplained skip; scanner names/versions and advisory-database timestamps; findings, exceptions, expiry, and artifact checksums | Release/security owners; [release runbook](runbooks/release.md) |
| Protected image publication, SBOM, and licenses | Exact source; protected workflow approval; backend/site image repositories and OCI digests; scan results; CycloneDX and notices digests; provenance; verified `promotion-handoff.json` and `SHA256SUMS`; registry publication outcome | Release/security owners; [release runbook](runbooks/release.md) |
| Dark deployment and staging/production parity | Rendered release-binding ConfigMap and values digest; actual Pod `imageID` values; chart/version; auth, database-role, NetworkPolicy, feature-map, retention, and secret-version identifiers; protected staging smoke results; platform approval | Platform/service/database owners; [release runbook](runbooks/release.md) |
| Protected auth, replay, shared-limit, and switch exercise | Exact source, deployment, release issuer/discovery/JWKS identities, configured JWKS cache bound, old/replacement key IDs, accepted replacement-key result, and removed-key rejection after the bound; same-operation/same-idempotency-identity library and comment replay results with one durable side effect each; at least two independently identified serving replicas, quota/window/action identity, requests routed through both replicas, stable cross-replica HTTP 429 + `RATE_LIMITED` + delta-seconds `Retry-After`, and reset result; before/after rendered values and observed allowed/disabled behavior for `ACCOUNTS_ENABLED`, `LIBRARY_ENABLED`, `LIBRARY_WRITES_ENABLED`, `COMMENTS_ENABLED`, `COMMENT_CREATION_ENABLED`, and `ACCOUNT_DELETION_ENABLED` under valid dependency combinations, including fail-closed invalid-combination results; sanitized assertion counts, UTC window, cleanup, and owner approvals | Identity/service/database/platform/release owners, plus privacy/safety for authenticated UGC; [protected exercise runbook](runbooks/release.md#protected-auth-write-and-switch-exercise) |
| Public edge and associations | Passing exact-source `public-edge-sha256:` artifact; target environment; promotion-handoff candidate ID; public-site source marker; HTTPS/TLS/HSTS/header/document/runtime/readiness results; deployed Android/Apple association identities; workflow approval; separate comparison of Pod image IDs to promotion handoff | Platform/release owners; [release runbook](runbooks/release.md#public-edge-technical-evidence) and [app-links runbook](mobile-app-links.md) |
| Migration and rollback exercise | Source and migration-image digest; backup evidence ID; starting/ending schema and app versions; migration Job status/log digest; DDL-role proof; expand/compatibility/rollback-or-forward sequence; data-integrity checks; feature-switch states; UTC window and database/release approvals | Database and release owners; [release runbook](runbooks/release.md#expandcontract-deployment) |
| Protected staging load | Closed aggregate JSON and checksum; exact source and deployment topology; scenario/sample counts; p50/p95/p99/error rates; configured thresholds/fault profile; database saturation/telemetry references; synthetic-fixture and cleanup result; protected workflow approval | Service/database/release owners, plus privacy/safety when authenticated; [load runbook](runbooks/backend-load-testing.md) |
| Live telemetry, retention, and alerts | Collector/gateway/adapter image and config/policy digests; enabled rule IDs; receiver ownership; valid/hostile mobile probes; safe canary present and protected sentinels absent; live sink query; 30-day expiry test; agent restart replay/coverage; successful page/ticket canaries and UTC window | Platform/observability/privacy owners; [observability runbook](runbooks/observability.md) |
| Account deletion E2E | Valid production-form `accountDeletionE2eId`; exact candidate/deployment/provider identities; recent-auth rejection then acceptance; request/operation ID in sanitized form; immediate disablement; session revocation; provider absence; application-data purge/pseudonymization counts; one signed external-ledger record/job; retry result; alert canary; real secret-manager/ledger/backup-inventory references | Privacy/on-call owner approval; [account-deletion runbook](runbooks/account-deletion.md) |
| Backup/PITR and deletion replay | Valid externally anchored `restoreDrillId`; canonical schema-2 protected attestation and digest; backup ID, recovery/latest-recoverable/observation timestamps; exact database guard; PostgreSQL/Keycloak/physical-storage inventory; exact current ledger count and domain-separated logical signed-record inventory digest; source and worker digest; schema version; content-addressed v2 reapply and finalize packages; finalize and standalone verification reopen the actual prior package and require its reapply phase, computed content ID, byte-identical attestation, protected `migration`/`papers`/`core_jobs`/`ledger_records` continuity plus the domain-separated exact local ledger-identity/job-binding digest, prior-before-final chronology, and `restore_completed_at <= recorded_at <= restore_completed_at + 24h`; strict cross-file digest equality; exact `public, pg_catalog` session binding and exact `public` namespace placement for `vector`, `pg_trgm`, and `pgcrypto` verified before snapshots or migration/replay mutations despite URL startup options; attested/guard-bound change marker forced as the database audit actor; zero unfinished/terminal jobs and resurrected users; retained public-data counts; computed RPO/RTO; operator/change record | Database recovery and privacy approvals; [backup/restore runbook](runbooks/backup-restore.md) |
| Moderation readiness | Valid `moderationReadinessId`; exact deployed candidate; operator issuer/audience/recent-auth/allowlist and rejection matrix; live comment/user-report/comment-report/block queues; inspect/hide/restore/resolve/suspend/reinstate audit UUIDs; kill-switch and high-risk/outage fallback; guest reads; alert/ticket canaries; staffed response targets and escalation result | Trust & Safety approval; [moderation runbook](runbooks/moderation.md#acceptance-and-production-readiness-evidence) |
| Signed mobile candidate, IdP, and links | Protected Android AAB/APK and Apple IPA digests; signing/profile identities and expiry; upload-key and Play app-signing fingerprints; bundle/package/version/build; toolchain versions; SDK/minimum OS/API/alignment/entitlement/privacy-manifest results; native SBOM/notices/symbol/checksum digests; protected feature map; release OIDC registrations/redirects; deployed association checks | Mobile signing, identity, platform, and release approvals; [mobile release runbook](mobile-release.md) |
| Protected physical mobile acceptance | Passing closed three-member tar containing canonical schema-v2 `mobile-acceptance-evidence.json`, canonical `mobile-acceptance-tooling.json`, and `SHA256SUMS` for the exact root-imported candidate/provenance manifests and source; protected environment approval; short-lived root-owned runner-session attestation; protected validator and driver digests; local tar digest plus immutable upload artifact ID and server digest; fresh run challenge/ID/attempt/time binding; four distinct installation hashes and four challenge-keyed physical-identity hashes derived from distinct root-attested commitments for Android gesture, Android three-button, iPhone home-indicator, and physical-keyboard iPad/second-sync roles; all 16 ordered scenarios with exact role assignments, 70 assertion IDs, and 37 closed integer metric rules; exact platform artifact/application/signer/team and staging API/issuer/client bindings; sanitized-data markers | Mobile QA/release approval; [mobile release runbook](mobile-release.md) |
| Mobile performance and crash window | Exact signed build and device/OS matrix; cold/warm first-readable-frame samples; opening duration; sequential cache-hit and blank-card counts; frame sample/window; aggregate privacy-reviewed crash denominator and source query/store report; at least 99.5% crash-free sessions; observation window and approver | Mobile QA/release/privacy owners; [mobile release runbook](mobile-release.md#telemetry-and-release-candidate-gates) |
| Legal, privacy, support, and publication | Valid `legalReviewId`; exact published Privacy/Terms/Guidelines/Support versions and direct HTTPS checks; monitored support-contact result; actual enabled features, SDKs/processors, collection, retention, deletion/backup behavior, jurisdictions/contracts, and public URLs; reviewer identity/role, approval timestamp, and manifest digest | Privacy/legal owner; [privacy worksheet](store/mobile-privacy-review.md) and [release runbook](runbooks/release.md#release-evidence-binding-scope) |
| Strict content rights | Valid `strictContentReviewId`; exact strict backend/mobile configuration and candidate; metadata/save/comments/arXiv availability; displayed/retained Introduction behavior; cache/offline masking results; actual retention/display policy; qualified reviewer decision, scope, date, and approval | Legal/content owner; [content policy](content-policy.md) and [UGC review](store/ugc-content-review.md) |
| Reviewer flow | Valid `reviewerFlowId`; exact signed candidate; disposable verified-email account lifecycle and expiry owner without credentials in evidence; completed sanitized guest/sign-in/save/comment/report/block/deletion/web-deletion/strict-content steps; physical acceptance, deletion, SBOM, and policy evidence references; store-ready notes | Store release owner; [reviewer-notes template](store/reviewer-notes-template.md) |
| Store submission, staged rollout, and approval | App Store Connect/TestFlight and Play closed-track upload receipts; authenticated GitHub Actions run/job IDs plus immutable artifact IDs and server digests; exact artifact digest/version/build; Play remote bundle SHA-256; Apple exact completed BuildUpload-to-Build/assetFile resource linkage with IPA UTI, byte size, and remote SHA-256; highest prior store versions and monotonic comparison; signed-archive SDK/privacy reports; completed current App Privacy, Data Safety, age-rating, deletion-URL, developer-identity, package/signing registrations; reviewer notes/account reference; trusted rollout-tooling revision bound separately from candidate source, with the signed-release source equal to its recorded workflow revision; protected receipts bound to the downloaded candidate/provenance and signed-release run, retaining every selected platform's success/failure/not-run outcome before final failure. **Updates:** exact eligible prior completed Play production fallback, reviewed Play pre/post state for one-percent start and every advance/halt/complete, any Android-only post-completion full-release halt; for iOS start, an exact prior public `appVersionState=READY_FOR_DISTRIBUTION`, exact target pre-submit state, and exact post-submit `INACTIVE` phased resource; every later Apple phased state/decision; the exact-candidate crash/performance window; and the manual-download exposure accepted for an Apple pause. **First public versions:** no staged/phased claim; a separately approved 100% Play first-publication record and an App Store first-version record containing exact submission/review state, selected manual-release setting, pre/post release or deliberately withheld state, UTC action time, portal audit, and owner approval. All paths require independent store audit/history, review outcome, partial-success reconciliation, and store/privacy/legal/mobile-signing approvals | Store, privacy/legal, and mobile signing owners; [privacy worksheet](store/mobile-privacy-review.md), [UGC review](store/ugc-content-review.md), and [protected rollout runbook](mobile-release.md#protected-staged-store-rollout) |

The disposable `live comments acceptance` and `live account deletion` workflows
remain valuable reference-stack evidence, but their classifications explicitly
exclude target protected staging and they cannot supply
`moderationReadinessId` or `accountDeletionE2eId`. Their local JWKS, replay, and
shared-limit assertions also cannot satisfy the protected auth/write/switch
gate. Likewise, the restore harness proves a fail-closed mechanism, not that a
provider backup was restored.

## Evidence references

- [Phase 0](phase-reports/phase-0.md), [Phase 1](phase-reports/phase-1.md),
  [Phase 2](phase-reports/phase-2.md), [Phase 3](phase-reports/phase-3.md),
  [Phase 4](phase-reports/phase-4.md), and [Phase 5](phase-reports/phase-5.md)
  repository reports
- [Phase 6 implementation/release-gate report](phase-reports/phase-6.md) and
  [mobile Phase 6 evidence](phase-reports/phase-6-mobile.md)
- [Release](runbooks/release.md), [account deletion](runbooks/account-deletion.md),
  [backup/restore](runbooks/backup-restore.md),
  [moderation](runbooks/moderation.md),
  [observability](runbooks/observability.md),
  [backend load](runbooks/backend-load-testing.md), and
  [incident response](runbooks/incident-response.md) runbooks
- [Mobile release](mobile-release.md), [mobile app links](mobile-app-links.md),
  [content policy](content-policy.md), [privacy worksheet](store/mobile-privacy-review.md),
  [UGC review](store/ugc-content-review.md), and
  [reviewer-notes template](store/reviewer-notes-template.md)

Until all applicable protected artifacts and approvals above are retrievable and
bound to one exact release candidate, the authoritative outcome remains:
**repository implementation present; public/store release not accepted**.
