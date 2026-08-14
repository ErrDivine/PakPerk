# Release, migration, rollback, and store-candidate runbook

**Owner:** release manager. **Approvers:** service owner, database owner,
privacy/safety owner, and mobile signing owner for store candidates.

Repository automation builds candidates and fails closed on missing evidence.
It does not establish live backups, approve production, sign with unavailable
keys, publish legal pages, upload store builds, or manufacture performance and
crash evidence.

## Candidate inputs

- A clean reviewed revision with `./scripts/check.sh` passing and every explicit
  skip resolved for the target environment.
- A successful protected `publish-release-images` workflow for that exact full
  revision. Promotion must consume `promotion-handoff.json`; copying a mutable
  tag or manually substituting an unscanned digest is not release evidence.
- Matching `0.2.0` Rust workspace, Helm `appVersion`, and mobile version name;
  the mobile build number must exceed both stores' highest uploaded value.
- Immutable backend/site/GROBID/Collector image digests and successful
  vulnerability/license/secret scans, generated CycloneDX SBOMs, notices, and
  checksums. Mobile evidence must include the production-runtime Maven SBOM,
  both matching SwiftPM locks, and the checksum-complete Gradle policy.
- Exact HTTPS origins, OIDC realm/clients/redirects, support contact, legal
  version, Play app-signing fingerprint, Apple team/bundle ID, reviewed egress
  CIDRs, ingress proxy source CIDRs, database roles, deletion-ledger claim,
  secret rotation version, OTLP endpoint, and verified backup ID.
- Protected target evidence for release-issuer key rotation/removal, exact
  library and comment operation replays, cross-replica shared limiting, and each
  independently controlled feature/kill switch, as specified below.
- An approved strict-content review and the external evidence listed under
  [mobile release blockers](../mobile-release.md#external-release-blockers).

## Release-evidence binding scope

The chart's six `releaseEvidence` values are content IDs for protected,
canonical evidence manifests, not change numbers, workflow run IDs, ticket
URLs, or hashes of an operator's assertion. Each manifest must identify its
owner and approver, UTC verification window, target environment, exact source
revision and deployed/candidate build identities, evidence-artifact digests,
outcome, and approval timestamp. A digest has no evidentiary value unless the
protected release system can retrieve and verify those bytes.

| Chart value | Required scope | Owner |
| --- | --- | --- |
| `legalReviewId` | Exact published legal/support versions, actual enabled data/processors and retention, public URL checks, and approval | privacy/legal owner |
| `reviewerFlowId` | Disposable reviewer-account lifecycle and sanitized exact-candidate reviewer steps for guest, account, safety, and deletion paths | store release owner |
| `strictContentReviewId` | Exact strict backend/mobile policy, displayed and retained introduction behavior, metadata-only behavior, and qualified content-rights approval | legal/content owner |
| `moderationReadinessId` | Protected live comment/user-report/comment-report/block/admin and kill-switch flow; dedicated operator audience/allowlist rejection matrix; moderation fallback; sanitized output; staffed response targets; support/deletion/retention dependencies; and alert/ticket canary | Trust & Safety owner |
| `accountDeletionE2eId` | Protected staging recent-auth request through provider/session/app-data completion using the real secret manager, independent ledger, and alert route | privacy/on-call owner |
| `restoreDrillId` | Isolated PostgreSQL/Keycloak restore, exact current-ledger count, external inventory digest, local ledger/job-binding digest continuity, exact `public, pg_catalog` mutation-session binding, attested change marker used as the reapply audit actor, schema-2/v2 reapply/finalize packages with the actual prior package reverified for ID/attestation/chronology/core-count continuity, RPO/RTO, and recovery/privacy approvals | database and privacy owners |

The five approval IDs other than `restoreDrillId` use the closed schema-1
contract in `scripts/production_approval_evidence.py`. A protected evidence
producer must call its `build_evidence(...)` API with measured artifacts and an
accountable approval; the command-line interface deliberately cannot turn
unchecked prose or a workflow run number into an approval. Validate every
retrieved canonical manifest independently, then build and re-open one bundle:

`restoreDrillId` is the verified schema-2 finalize package's exact
`archive_sha256` from `PACKAGE_SHA256.json`. Retain and verify the same file's
domain-separated `pakperk-restore-evidence-v2:sha256:` content ID and its actual
prior-reapply package chain alongside it. The Helm-compatible archive digest
does not replace that stronger external anchor or package verification.

```bash
python3 scripts/production_approval_evidence.py validate \
  protected/legal-review.json --gate legalReviewId

approval_manifests=(
  --manifest "legalReviewId=protected/legal-review.json"
  --manifest "reviewerFlowId=protected/reviewer-flow.json"
  --manifest "strictContentReviewId=protected/strict-content-review.json"
  --manifest "moderationReadinessId=protected/moderation-readiness.json"
  --manifest "accountDeletionE2eId=protected/account-deletion-e2e.json"
)
umask 077
install -d -m 0700 protected
python3 scripts/production_approval_evidence.py bundle \
  "${approval_manifests[@]}" \
  --rendered-manifest protected/rendered-production.yaml \
  --output protected/production-approval-bundle.json
python3 scripts/production_approval_evidence.py predeploy \
  protected/production-approval-bundle.json \
  "${approval_manifests[@]}" \
  --rendered-manifest protected/rendered-production.yaml
```

Each manifest binds the exact source, images, chart, signed mobile candidate,
independent restore-drill ID, and a domain-separated release-configuration
digest computed with these five not-yet-produced approval fields blank. This is
intentional: making an approval ID depend on the final Helm release binding,
which itself contains that ID, would be an impossible hash cycle. After the
five IDs exist, render the final protected chart with those exact values. The
bundle command requires that render, recomputes the normalized configuration,
image and full release-binding digests, checks all ConfigMap approval mirrors,
and then binds the full rendered-manifest bytes.

The bundle also requires one byte-for-byte-equivalent approval binding across
all five manifests and cross-checks the reviewer flow's legal, strict-content,
and deletion references. Retain the rendered manifest, five manifests, bundle,
protected audit records, and artifact checksums together. `predeploy` reopens
all of them and must succeed before applying the rendered manifest. The chart
cannot retrieve the protected approval files, so its syntax checks are not a
substitute for this step. Schema validation proves that the record is closed
and internally bound; it does not perform the live exercise or supply the
accountable human decision.

These bindings cover server deployment obligations whose applicability follows
the production feature map. They deliberately do **not** turn Helm into the
release ledger for image publication/security scans, public-edge checks,
staging load, migration/rollback exercise, live telemetry retention/alert
routing, the protected auth/write/switch exercise, signed mobile candidates,
physical-device performance/crash windows, or store submission/review. Those
gates bind to an exact candidate in the protected release record and in their
named workflow/store evidence. A dark Helm rollout does not satisfy them, and
their absence still blocks public/store release even when `helm template`
succeeds.

## Operational gate evidence bundle

Migration/rollback, live telemetry/retention/alerts, and signed-mobile
performance/crash observation use the canonical schema-1 contracts in
`scripts/operational_gate_evidence.py`. They are deliberately independent of
the Helm approval IDs:

| Gate | Content ID | Closed protected scope |
| --- | --- | --- |
| `migration_expand_contract` | `pakperk-migration-exercise-v1:sha256:` | Staging schema 9 to 10; verified restore evidence; reviewed migration image; one migration Job and DDL role; old/new compatibility; switch reconciliation; integrity; schema-compatible code rollback and re-forward; database/release approvals |
| `live_telemetry_retention` | `pakperk-live-telemetry-v1:sha256:` | Distinct production and staging-copy Collector/gateway/adapter/configuration/receiver/retention identities for one image candidate; reviewed parity diff; production safe-canary delivery and exact 30-day retention boundary; staging valid/hostile/redaction/restart/page/ticket checks; platform/observability/privacy approvals |
| `mobile_performance_crash` | `pakperk-mobile-performance-v1:sha256:` | Exact signed APK/IPA and version/build; reviewed device/OS matrix; at least 20 cached-frame and opening samples with p95 at most 1,500 ms and opening at most 700 ms; at least 20 sequential requests with 95% hits and no blank cards; at least 20 frame samples; at least 24 hours and 200 aggregate exact-candidate sessions with 99.5% crash-free; mobile/release/privacy approvals |

Each protected producer must emit canonical data, retain its raw source records
outside Git, and pass both the manifest's expected content ID and a separately
approved exact binding. The binding fixes source, target environment, passing
`deployment-binding-v1:` ID, candidate/configuration digests, and the exact
producer/driver/adapter tool versions and digests. Before sealing a manifest,
use `build_approval_subject_id(...)` to derive its stable domain-separated
execution-subject ID, then require every named owner to approve that exact ID
within 14 days after cleanup. Approval records cannot reuse the cleanup audit
reference. A forward fix may be retained as additional incident evidence, but
it does not replace the schema-compatible rollback required for this additive
9-to-10 release gate. Validate the three results:

For telemetry, use the same immutable Collector, gateway, and adapter images in
production and the staging canary copy. Bind their configurations, alert-policy
imports, receiver inventories, and retention policies separately; production
and staging environment identities are not interchangeable. Reopen both named
`deployment-binding-v1:` records in the protected ledger; the production ID
must equal the manifest's expected binding, and the staging ID is carried in
the staging-copy subject. The parity record must show that staging changes only
the reviewed environment filters/routes and does not weaken the six inputs, 17
rules, redaction, or 30-day policy.
The two receiver inventories must route all 17 rules across both `page` and
`ticket`, with no ownerless receiver; a zero-receiver inventory is not a pass.
Send a privacy-safe canary through the dark production deployment and require it in
the production sink. Seed the bound production retention-canary commitments,
observe every one initially and again from day 29 until before day 30, then
observe zero of those same commitments between day 30 and day 31. The UTC
timestamps and age metrics must reconcile exactly. Valid/hostile mobile probes,
restart replay/coverage, and page/ticket delivery remain staging-copy canaries;
they do not silently substitute for production delivery or retention evidence.

```bash
python3 scripts/operational_gate_evidence.py validate \
  protected/migration-exercise.json \
  --gate migration_expand_contract \
  --expected-id "$MIGRATION_EVIDENCE_ID" \
  --expected-binding protected/migration-expected-binding.json
python3 scripts/operational_gate_evidence.py validate \
  protected/live-telemetry.json \
  --gate live_telemetry_retention \
  --expected-id "$TELEMETRY_EVIDENCE_ID" \
  --expected-binding protected/telemetry-expected-binding.json
python3 scripts/operational_gate_evidence.py validate \
  protected/mobile-performance.json \
  --gate mobile_performance_crash \
  --expected-id "$MOBILE_PERFORMANCE_EVIDENCE_ID" \
  --expected-binding protected/mobile-performance-expected-binding.json
```

After all three pass for one source revision, build and independently reopen
the exact bundle:

```bash
operational_manifests=(
  --manifest migration_expand_contract=protected/migration-exercise.json
  --manifest live_telemetry_retention=protected/live-telemetry.json
  --manifest mobile_performance_crash=protected/mobile-performance.json
)
python3 scripts/operational_gate_evidence.py bundle \
  "${operational_manifests[@]}" \
  --output protected/operational-gates-bundle.json
python3 scripts/operational_gate_evidence.py validate-bundle \
  protected/operational-gates-bundle.json \
  "${operational_manifests[@]}"
```

Retain the three manifests, expected bindings, raw-system references, byte
digests/content IDs, owner approvals, and the
`pakperk-operational-gates-v1:sha256:` bundle in the immutable release ledger.
The bundle enforces a common source revision; the release ledger must also
reconcile every deployment/candidate/configuration identity. This repository
validator runs no migration, sink query, retention wait, alert delivery,
physical performance probe, store query, or human approval. Its tests are
**R** evidence only; each protected manifest and decision remains **P/H**.

## Release-image publication trust boundary

`publish-release-images` uses three fresh GitHub-hosted runners. The `build`
job has `contents: read` only, has no protected environment, and is the only job
that checks out or executes candidate source or resolved build dependencies. It
builds the exact `sha-<source_revision>` backend and site tags and freezes each
image with `docker save`. Its archive IDs, hashes, and metadata are deliberately
classified as an **untrusted build handoff**: a surviving candidate process can
change any same-runner output, so no scan or publication decision trusts that
job's observations. The raw handoff is uploaded with compression disabled and
passed onward only by the upload service's immutable artifact ID and digest.

The `scan` job is a separate, uncredentialed runner with `permissions: {}`, no
checkout, and no candidate-authored program or container execution. It
downloads the raw build artifact by ID with digest mismatch failure, rejects a
non-canonical/duplicate-key manifest and any extra, symlinked, linked,
non-runner-owned, mutable, empty, or oversized member, rehashes both archives,
loads but never runs them, and derives the exact expected tag-to-image-ID
mapping again. It makes the input tree read-only before four pinned Trivy
operations consume the downloaded archive bytes: two blocking vulnerability
scans and two CycloneDX image SBOM generations. Because candidate processes
cannot cross the job boundary, they cannot race the scan reports, SBOMs,
post-scan archive hashes, trusted manifest, or upload.

After rehashing both archives again, the fresh scan job creates canonical
`release-image-handoff.json`. Its closed schema binds the target environment,
source revision, exact repositories and tags, derived image IDs, Docker archive
names and SHA-256 digests, every scan/SBOM/toolchain/dependency/notices digest,
and the untrusted build artifact ID, artifact digest, and manifest digest. The
closed handoff surface is made read-only and uploaded with compression disabled
under a second immutable artifact ID/digest. Both intermediate artifacts are
retained for one day and are not deployment approval.

The protected `publish` job starts on a third fresh runner, depends only on the
completed scan job, and alone has `packages: write` plus the selected protected
environment. It has no checkout and executes no candidate-authored program or
container. With `PATH` fixed and `BASH_ENV`/`ENV` pinned to `/dev/null`, it
downloads the scanned handoff by artifact ID, checks both scan-artifact and
upstream build-artifact provenance plus source/environment bindings, rejects
non-canonical or duplicate-key manifests and any extra/symlink/mutable file,
and rehashes every archive and evidence member. It then loads the two Docker
archives without running them and requires the loaded tag-to-image-ID mapping
to equal the scanned manifest before registry authentication.

`GITHUB_TOKEN` is bound only to the exact push step. That step pushes only the
two reconstructed commit tags and requires exactly one registry-reported digest
per push. The final canonical `promotion-handoff.json` contains those registry
digests plus the scanned-artifact ID, scanned-artifact container digest, and
scanned-manifest digest. `SHA256SUMS` covers the promotion handoff, scanned and
untrusted-build manifests, scans, SBOMs, toolchain record, dependency inventory,
and notices in the 90-day publication artifact. Promotion must verify those
bytes and use the digest-only Helm values; it must never rebuild, retag, or
substitute a local daemon digest.

Environment reviewers must treat fresh-job isolation as part of the approval
boundary. Do not merge `build` and `scan`, convert `scan` or `publish` to a
self-hosted runner that can retain a candidate process or Docker daemon, add a
checkout or candidate hook to either fresh job, grant a token permission or
protected environment to `scan`, grant `packages: write` to `build`, download
either handoff by mutable artifact name, or expose the registry token before
the archive and loaded image-ID checks.

The manual `live comments acceptance` workflow is a disposable reference-stack
regression lane, not protected staging. Its evidence has a closed safety schema
and the non-assertive environment classification
`manual_ci_disposable_reference`; it does not attest GitHub environment
protection. Its domain-separated `reference-sha256:` ID is intentionally
invalid for production `moderationReadinessId`; do not copy its artifact
checksum or Actions run ID into that field. The target-environment record must
satisfy the complete
[moderation readiness matrix](moderation.md#acceptance-and-production-readiness-evidence)
for the exact deployed candidate before comment creation can be enabled.

## Public-edge technical evidence

Run the manual `public edge verification` workflow against the dark-deployed
staging or production candidate before enabling features or submitting a store
build. Dispatch it from `main` with all four required inputs:

- `source_revision`: the reviewed full lowercase commit SHA, which must equal
  the selected workflow revision, checked-out `HEAD`, and fetched
  `origin/main` tip;
- `target_environment`: exactly `staging` or `production`;
- `candidate_id`: `sha256:` followed by the exact digest of
  `promotion-handoff.json` recorded in the protected image-publication
  artifact's verified `SHA256SUMS`; and
- `confirmation`: exactly `RUN_PUBLIC_EDGE_VERIFICATION`.

Configure these non-secret variables on each named GitHub environment. They
are protected release coordinates, not dispatch-controlled hosts:

```text
PAKPERK_SITE_ORIGIN
PAKPERK_API_ORIGIN
PAKPERK_TELEMETRY_ORIGIN
PAKPERK_OIDC_ISSUER
PAKPERK_WEB_OIDC_CLIENT_ID
PAKPERK_SUPPORT_EMAIL
PAKPERK_PUBLIC_DOCUMENT_VERSION
PAKPERK_ANDROID_PACKAGE
PAKPERK_ANDROID_SHA256
PAKPERK_APPLE_TEAM_ID
PAKPERK_APPLE_BUNDLE_ID
```

The verifier makes proxy-free, credential-free, redirect-disabled requests to
publicly resolved 80/443 addresses with bounded DNS, connect, total-request,
header, and body limits. It checks exact HTTP-to-HTTPS redirects; TLS and HSTS;
the runtime configuration; distinct stable HTML routes and their security/cache
headers; the notices source-revision marker; Android and Apple association
identities; a complete gzip public-feed stream with valid trailer integrity,
bounded decompression, the closed JSON envelope, the exact public cache policy,
and `Vary: Accept-Encoding`; the API readiness response contract; and
telemetry-gateway process readiness. A failed observation still produces a
closed, owner-only sanitized failure statement, then the workflow fails after
retaining the exact-source artifact. Raw bodies, headers, transport errors,
cookies, credentials, support address, and operator identity are not retained.

The artifact's `public-edge-sha256:` content ID is deliberately not a Helm
`releaseEvidence` approval ID. The requested candidate ID is release-record
context and is not observed at the edge. The public notices marker observes the
site source revision only; it does not prove the API image, Pod image IDs, Helm
release, or whole deployment provenance. Before promotion, a platform owner
must separately compare actual Pod `imageID` values and the immutable rendered
release-binding ConfigMap/digest with the protected promotion handoff and
release record.

This technical lane also does not approve legal text or disclosures, attest
GitHub environment reviewer/branch settings, prove signed-candidate custody,
exercise physical-device universal links, complete authenticated account
deletion, or prove Collector/export/sink delivery. Retain those approvals and
protected live canaries separately; reference the retrievable public-edge
artifact digest, workflow run/time, target, and outcome from the release
ledger.

## Dark-deployment provenance evidence

After the exact digest-only Helm candidate is dark deployed and settled, use
`scripts/deployment_binding_evidence.py` to replace the former manual image-ID
comparison with a closed `deployment-binding-v1:sha256:` record. The builder
cross-checks four independent inputs:

1. The canonical `promotion-handoff.json` from the protected image publication
   artifact.
2. The one live immutable `release-evidence` ConfigMap selected by the release
   record, exported with `kubectl get configmap NAME -o json`.
3. A namespace PodList exported after the rollout settles. Every selected
   Pakperk Pod must be Running and Ready, every regular and init-container spec
   image must equal its release binding, every runtime `imageID` must expose the
   same pullable repository and digest, and replica counts must exactly match
   the reviewed expectation. Each Deployment Pod must have one ReplicaSet
   controller owner, each Collector Pod one DaemonSet owner, and all Pods for a
   component must share the same owner UID after the rollout settles. Completed
   migration/metadata-sync Pods are ignored; an active or failed transient job
   makes the capture fail closed.
4. A canonical, owner-only observation JSON containing only the environment,
   source revision, capture time, release namespace/instance, a one-way cluster
   identity, exact expected replicas and reviewed defaulted Pod specs, digests
   of the rendered values/auth/
   database-role/NetworkPolicy/retention/secret-version reviews, the reviewed
   ingress-controller repository/digest/configuration/reference, an exact-image
   protected staging-smoke reference, and the platform-owner approval
   reference. All five smoke outcomes must be `passed`.

Capture files in a fresh owner-only directory. Do not place kubeconfig data,
tokens, Secret objects, raw logs, public UGC, Pod logs, or operator identity in
the observation:

```bash
evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/pakperk-deployment-binding.XXXXXX")"
chmod 0700 "$evidence_dir"
umask 077

kubectl --namespace "$PAKPERK_RELEASE_NAMESPACE" get configmap \
  "$PAKPERK_RELEASE_EVIDENCE_CONFIG_MAP" --output json \
  >"$evidence_dir/release-config-map.json"
kubectl --namespace "$PAKPERK_RELEASE_NAMESPACE" get pods --output json \
  >"$evidence_dir/pods.json"
```

The observation is canonical ASCII JSON with one trailing newline and exactly
these top-level members: `schema` (`1`), `environment`, `source_revision`,
`captured_at`, `release_namespace`, `release_instance`, `cluster_identity`,
`expected_replicas`, `expected_pod_specs`, `controls`, `ingress`,
`staging_smoke`, and `approval`.
Use all seven replica keys (`api`, `paper-worker`, `deletion-worker`,
`telemetry-gateway`, `site`, `grobid`, `otel-collector`); use zero for the
deletion worker only when account deletion is disabled. `expected_pod_specs`
uses the same seven keys and the domain-separated SHA-256 returned by
the `pod-spec-id` command for each reviewed, API-defaulted Pod spec:

```bash
python3 scripts/deployment_binding_evidence.py pod-spec-id \
  --component api \
  --pod "$evidence_dir/reviewed-api-pod.json"
```

Only the assigned `nodeName` is excluded. For the `otel-collector` DaemonSet,
the validator also recognizes and removes only Kubernetes' exact generated
single-node `metadata.name In [...]` affinity; every other affinity shape stays
bound or fails closed, while controller-added tolerations remain bound. Use an
empty value only for a zero-replica deletion worker. Review those raw specs
against the rendered controller templates and admission policy inside the
protected platform boundary before hashing them.
The validator then requires every selected Pod to match, so a changed command,
environment, security context, injected container, volume, or service identity
cannot pass with the same evidence. Raw specs never enter the retained
artifact.

`controls` must contain the six `*_sha256` keys defined by `CONTROL_KEYS` in the
script. `ingress` must contain `controller_repository`, `controller_digest`,
`configuration_sha256`, and `review_reference`. `staging_smoke` binds the same
source, backend digest, and site digest and contains exactly the five checks
defined by `SMOKE_CHECK_KEYS`. `approval` is exactly
`{"role":"platform_owner","reference":"sha256:..."}`. Generate canonical
bytes with a duplicate-key-rejecting protected producer; do not normalize an
unreviewed input after the fact.

Build the sanitized artifact, then reopen it against the same captures before
retention:

```bash
python3 scripts/deployment_binding_evidence.py build \
  --promotion-handoff protected/promotion-handoff.json \
  --release-config-map "$evidence_dir/release-config-map.json" \
  --pods "$evidence_dir/pods.json" \
  --observation "$evidence_dir/observation.json" \
  --output "$evidence_dir/deployment-binding-evidence.json"

python3 scripts/deployment_binding_evidence.py verify \
  --promotion-handoff protected/promotion-handoff.json \
  --release-config-map "$evidence_dir/release-config-map.json" \
  --pods "$evidence_dir/pods.json" \
  --observation "$evidence_dir/observation.json" \
  --evidence "$evidence_dir/deployment-binding-evidence.json"
```

Retain the evidence file and a checksum in the protected release record. The
artifact keeps component counts, release identities, control digests, and a
digest of each Pod set; it excludes raw Kubernetes objects, namespace/instance
text, Pod/node names, cluster credentials, and operator identity. Its
`release.config_map_sha256` binds the exact capture bytes while
`release.release_binding_sha256` independently re-derives the immutable Helm
contract. A successful local validation does not attest a cluster capture,
staging smoke, ingress review, or platform approval; those facts remain
protected execution and human gates.

## Pre-deploy and pre-enable gates

1. Freeze the revision and attach CI/security results. Verify every GitHub
   Action is pinned to a real reviewed commit, not only a mutable tag comment.
   Run `publish-release-images` from `main` with the reviewed full commit SHA
   and target protected environment. Require both vulnerability scans, both
   image SBOMs, and the digest-only Helm handoff artifact before deployment.
2. Verify the backup using [backup-restore.md](backup-restore.md). Put its
   evidence ID in `migration.confirmBackupId`.
3. Render the exact protected values with `helm lint` and `helm template`; run
   `scripts/validate_helm_release.sh`. Compare rendered hosts, identities,
   grants, images, NetworkPolicies, retention, feature flags, and commands to
   the change record. Confirm no worker poll interval reaches its lease, the
   deletion retry base is below its maximum, ledger retention covers security
   retention, each termination grace budget covers its maximum request/lease,
   and the trusted-proxy list contains at most 64 canonical ranges. Verify the
   four tag-free, at-most-255-character OCI repositories, distinct lowercase
   external FQDNs, Kubernetes names/labels/selectors, resources whose requests
   do not exceed limits, and PDB values came from the protected release
   manifest. The repository staging fixture is never deployable.
   After the dark rollout settles, build and verify the
   `deployment-binding-v1:sha256:` artifact above; do not enable public traffic
   or feature writes from a manual visual comparison alone.
4. Confirm the migration role alone can perform DDL; application roles cannot.
   Confirm worker, API, and synchronization roles use distinct Secret keys.
   Each runtime role must have only `USAGE` on `public` plus column-level
   `SELECT (version, success, checksum)` on `public._sqlx_migrations` for the
   shared readiness check; it must have no migration-history write privilege.
   Exercise readiness through every exact role after the migration: a missing,
   failed, old, gapped, or checksum-divergent embedded history must fail closed.
5. Confirm the deletion worker's `manage-users`-only service account readiness,
   current independent ledger, and alert coverage before enabling deletion.
6. Apply the reviewed `deploy/helm/ingress-nginx-production-values.yaml` to the
   pinned TLS controller release. Its exact HSTS and gzip settings are release
   requirements, including `application/json` and the 256-byte compression
   threshold. Verify Nginx real-IP trust and API-observed ingress source ranges
   before relying on comment origin limits. Do not infer a public-edge pass
   from Helm rendering or the configured hosts; the protected public-edge run
   must also observe a complete, boundedly decompressed JSON
   `/v1/feed?limit=100` response with `Vary: Accept-Encoding`; magic bytes or a
   corrupt/truncated gzip stream do not pass.

## Protected auth, write, and switch exercise

Run this gate against the exact dark-deployed candidate and its release-shaped
topology in protected staging. Use only approved synthetic papers, disposable
accounts, and bounded non-production quotas. Identity, service, database,
platform, and release owners approve the run; privacy/safety also approves any
authenticated UGC. Keep credentials, bearer tokens, raw network addresses, raw
comment bodies, and provider key material out of evidence.

The closed evidence package must bind the source revision, deployed image IDs,
rendered release values, database identity, serving-replica topology, release
issuer/discovery/JWKS identities, UTC window, assertion counts, cleanup result,
and approvers. It must prove all of these behaviors:

1. Perform an identity-owner-approved signing-key rotation on the configured
   release issuer. Record only the old and replacement `kid` values and the
   configured `OIDC_JWKS_CACHE_TTL_SECONDS`. Accept an unexpired access token
   signed by the replacement key, and prove the still-current old-key token is
   accepted immediately before removal. Remove the old key from JWKS, wait
   beyond the configured cache bound, record a positive remaining token
   lifetime at the probe, and prove that same otherwise-unexpired old-key token
   is rejected with HTTP 401 `UNAUTHENTICATED`. Separately prove an expired token
   returns HTTP 401 `TOKEN_EXPIRED` and that the protected mobile expiry path
   performs one successful refresh. In a separate disposable mobile session,
   invalidate the real refresh credential at the release IdP, force one refresh,
   and bind the schema-v3 physical result showing guest transition, inaccessible
   account-owned rows, an unreadable refresh record, preserved public cache and
   exact reader state, and continued guest reading. Restoring or retiring
   provider keys is an identity-owner action and must be recorded without
   retaining credential/key bytes. The release IdP must issue the synthetic
   old-key token with enough remaining validity to exceed the configured cache
   bound, bounded post-removal wait, and probe overhead. If the exact release
   issuer/candidate cannot do so, this gate remains blocked: natural token
   expiry cannot prove signing-key removal because key lookup precedes claims-
   expiry validation.
2. Send one library mutation twice with byte-equivalent intent, the same
   `Idempotency-Key`, and the same body `operation_id`; then send one comment
   creation twice with the same paper, normalized body, and
   `client_request_id`. Require HTTP 200 for both library responses with the
   same canonical paper/state/revision, then HTTP 201 followed by replay HTTP
   200 for the same canonical comment ID/status/body digest. Require exactly one
   durable library operation/side effect and one durable comment. Record only
   IDs or digests approved for evidence, aggregate row counts, statuses, and
   assertion results; never raw UGC.
3. Identify at least two simultaneously serving API replicas through protected
   platform attribution. Within one configured shared quota/window, route
   accepted requests through both replicas, exhaust the chosen safe action
   bucket through one replica, and route the next request through the other.
   Require HTTP 429, the exact `RATE_LIMITED` error code, a valid delta-seconds
   `Retry-After`, and success after the attested reset. Record the action,
   configured quota/window, per-replica aggregate counts, shared database
   identity, and reset result. Bind every accepted, exhausting, limited, and
   reset request to one `protected-rate-scope-sha256:` commitment produced by
   the reviewed protected driver from the exact bucket/scope; it must differ
   from every serving-replica identity. Do not retain a raw IP, account
   identifier, or unhashed database scope key. Use a bounded repeatable action;
   account deletion is not eligible because one accepted operation makes later
   identity-scoped retries free and blocks ordinary new operations for that
   account. HTTP 202 is a successful post-reset result for an accepted paper-
   preparation request.
4. Starting from the approved baseline, change only one switch at a time and
   retain the rendered before/after value plus observed allowed and disabled
   paths for `ACCOUNTS_ENABLED`, `LIBRARY_ENABLED`,
   `LIBRARY_WRITES_ENABLED`, `COMMENTS_ENABLED`,
   `COMMENT_CREATION_ENABLED`, and `ACCOUNT_DELETION_ENABLED`. Exercise only
   valid dependency combinations, restore and verify the baseline between
   cases, and retain fail-closed validation for invalid combinations. In
   particular, library-write disablement preserves library reads, disabling
   comment creation preserves comment/safety reads and actions, disabling
   accounts preserves guest reading, and production accounts cannot be
   accepted with account deletion disabled.

A repository test, one process with two repository objects, a load-balancer
request that cannot identify the serving replica, a fresh UUID on every write,
or a rendered flag without an observed request result does not satisfy this
protected gate.

Use the manual `protected service exercise` workflow to produce the canonical
result. Dispatch it from the exact reviewed `main` tip with these four inputs:

- `source_revision`: the full lowercase reviewed commit SHA;
- `candidate_id`: the exact `sha256:<digest>` protected candidate ID;
- `deployment_evidence_id`: the passing
  `deployment-binding-v1:sha256:<digest>` for that candidate; and
- `confirmation`: exactly `RUN_PROTECTED_SERVICE_EXERCISE`.

The `protected-staging-service-exercise` environment must use an ephemeral,
root-controlled Linux runner labeled `pakperk-protected-service-exercise` and
define these non-secret protected variables:

```text
PAKPERK_PROTECTED_SERVICE_RUNNER_SESSION_ID=sha256:<root session-attestation digest>
PAKPERK_PROTECTED_SERVICE_DRIVER_SHA256=<64 lowercase hex>
PAKPERK_PROTECTED_SERVICE_VALIDATOR_SHA256=<64 lowercase hex>
PAKPERK_PROTECTED_SERVICE_WORKFLOW_SHA256=<64 lowercase hex>
```

The runner-session ID is the raw SHA-256 of one canonical ASCII JSON document
with one trailing newline, stored as
`/opt/pakperk/protected-service-runner-sessions/<digest>.json`. Its exact keys
are `schema_version` (`1`), `classification`
(`dedicated ephemeral protected service exercise runner session`), the exact
`source_revision`, `protected_environment`
(`protected-staging-service-exercise`), `purpose`
(`protected_service_exercise`), `runner_labels` (exactly `Linux`,
`pakperk-protected-service-exercise`, and `self-hosted` in that order), a
non-placeholder `host_identity_sha256`, exact booleans `dedicated: true` and
`ephemeral: true`, and canonical UTC `issued_at`/`expires_at` timestamps. The
lifetime must be positive and at most eight hours, and at validation at least
six hours must remain so the attestation covers the workflow timeout. It must
contain no hostname, address, credential, operator identity, or other personal
data. Set `PAKPERK_PROTECTED_SERVICE_RUNNER_SESSION_ID` to
`sha256:<digest>` only after placing those exact bytes in the content-addressed
root.

Install the reviewed driver as
`/opt/pakperk/bin/pakperk-protected-service-exercise-driver` and the exact
reviewed validator as
`/opt/pakperk/bin/pakperk-protected-service-exercise-validator.py`. Every parent
directory through `/opt/pakperk/bin` and the runner-session root must be a
root-owned directory not writable by group/other. The two tools and session
manifest must be root-owned, non-group/other-writable, single-link regular
files; only the driver is executable. Set the three tooling
digests from those installed bytes and the checked workflow, not from a mutable
path or a previous run. The candidate checkout is a data-only request producer:
it must not install, source, or execute candidate code in the privileged driver
boundary. The root-owned driver reaches credentials only through its separately
reviewed root-owned broker/integration; GitHub secrets and repository code do
not cross that boundary. It must classify every attempted mutation and perform
unconditional cleanup.

Before protected execution, the pinned root-owned validator reopens the session
manifest, checks its content-address, exact source/purpose/labels/host binding,
file safety, and live validity window. The driver request binds the exact schema
version, 29 assertion IDs, 20 measurement IDs, six switches, six invalid
combinations, and the repository's domain-separated request-contract digest.
The workflow then creates a fresh challenge, invokes the driver in an empty
environment, validates the returned document again through that validator,
uploads only the canonical sanitized JSON, and fails if session import,
exercise, evidence validation, or upload is not successful. The schema-1 result
has the content ID
`protected-service-exercise-sha256:<digest>`, a separately computed approval
subject to avoid a content/approval hash cycle, the exact 29 ordered assertions,
20 closed measurements, all six switch cases, six invalid dependency cases,
and six accountable owner approvals. Validate retained bytes again with:

```bash
python3 scripts/protected_service_exercise_evidence.py validate \
  protected/pakperk-protected-service-evidence.json
```

Retain the canonical JSON, its byte digest/content ID, workflow run and attempt,
immutable artifact ID and server digest, protected-environment approval log,
runner-session attestation, installed driver/validator/workflow digests, and
cleanup record together. The 90-day Actions artifact is a transport handoff,
not the immutable release ledger: anchor its content ID and artifact coordinates
in the approved protected evidence system. A passing repository validator or
checked workflow is only **R** evidence; the live issuer, replicas, database,
switches, artifact, and approvals remain **P/H** until this exact run succeeds.

## Expand/contract deployment

1. Use additive/nullable tables, columns, indexes, and dual-compatible code for
   the expand release. Never combine destructive contraction with the first
   code rollout that stops using a field.
2. Run the chart migration Job once, with the reviewed image digest, distinct
   migration database role, `RUN_MIGRATIONS=false` everywhere else, expected
   embedded migration version `10`, and a bounded non-placeholder backup
   evidence ID. The scheduled metadata manifest must be valid JSON containing
   1 to 2,000 canonical arXiv IDs within the chart's 1,048,000-byte ConfigMap
   boundary, and its bounded five-field Cron expression must render
   successfully. Save Job logs/status without secrets. A failed or timed-out
   migration blocks rollout.
3. Roll out the deletion worker and verify readiness, then paper worker,
   metadata sync, telemetry gateway/Collector, API, and site. Keep the
   account-backed surface (including deletion), library writes, and comment
   creation dark until their dependencies and smoke checks pass. Production
   account enablement requires deletion to be enabled at the same time.
4. Dispatch `public edge verification` for this exact dark-deployed target and
   attach its passing artifact to the release ledger. A missing/failed artifact,
   a source marker mismatch, or any redirect/header/config/document/association/
   readiness mismatch blocks feature enablement and store submission.
5. Exercise guest cached reading first, then authenticated profile/library,
   comments/report/block/moderation, deletion request/status/web callback, paper
   preparation, telemetry redaction/export, and association links. Complete the
   [protected auth, write, and switch exercise](#protected-auth-write-and-switch-exercise)
   for the same candidate. Capture only the bounded, sanitized results defined
   by each evidence contract.
6. Reconcile all six switch results with the final rendered feature
   map. Do not infer a switch pass from a healthy baseline smoke, and do not
   reuse evidence after any relevant image, issuer, quota, topology, or feature
   map change. Account deletion remains enabled whenever production accounts are
   enabled, including a comments-disabled library release.
7. Observe error rate, readiness, database saturation, queue/backlog age,
   moderation SLA, deletion failures, OTLP drops, and ingress errors through the
   release observation window. Record the exact window and approver.

Contraction is a separate release only after every serving/worker version is
compatible, the compatibility window and rollback retention have elapsed, and
another verified backup exists. Exercise the migration and rollback sequence in
staging; a rendered command is not evidence of execution.

## Rollback

Prefer a forward code rollback to the last schema-compatible image plus feature
kill switches. Do not run destructive down migrations. If the new schema is
backward compatible, roll back API/site/workers and preserve the expanded
schema. If data corruption or an incompatible migration requires restore,
declare an incident, isolate writes, follow [backup-restore.md](backup-restore.md),
mount the current deletion ledger, and reapply deletions before traffic.

Never restore only PostgreSQL while leaving deletion obligations behind. A
store action never downgrades an already installed mobile binary: increment the
build and ship a corrected candidate. The separately approved Android-only
full-release halt described below is a distribution fallback for new/eligible
users, not an installed-binary rollback.

## Signed mobile/store handoff

Run the manual `signed-mobile-release` workflow. Its signing and upload jobs are
environment-gated, while preparation, assembly, bootstrap, and finalization
remain credential-free. It validates flavor configuration, signing/profile
identity, AAB/APK/IPA metadata,
entitlements/links, strict bundled assets, symbols, notices, SBOM, and evidence
hashes. Credential-free preparation publishes the immutable configuration
binding before candidate execution; independent fresh Android and iOS signers
rederive it and receive only their own signing family. A credential-free
assembler creates the combined candidate/provenance, an uncredentialed
bootstrap packages the frozen store client and literal-hashed controls, fresh
no-checkout platform upload jobs receive only their own store credential, and
an always-run credential-free finalizer retains both requested outcomes. The
workflow is fixed to the macOS 26 runner contract, Xcode 26.6 build
17F113, Flutter 3.44.8 framework revision
`058e0af2c2b57e369d905a03ac9748b0ebf543c6` with Dart 3.12.2, Temurin
17.0.19+10 from `JAVA_HOME_17_arm64`, MRI Ruby 3.4.10, RubyGems 4.0.17, and a
frozen Bundler 2.6.9/Fastlane 2.235.0 graph with RubyGems checksums. The Ruby
engine and exact runtime are verified and recorded before any gem installation
or Bundler execution. Bundler itself is downloaded by exact version, SHA-256
verified, and installed locally; absence of any exact toolchain fails the
candidate. Dispatch from `main` with the reviewed full commit SHA;
the workflow rejects an exact-checkout or `origin/main` ancestry mismatch, and
the retained signed-release source must equal its recorded workflow revision.
The Android upload-key digest proves candidate custody; association
files use the distinct protected Play App Signing digest. See
[mobile-release.md](../mobile-release.md).

Public promotion is a second protected handoff. An uncredentialed bootstrap
checks out and binds trusted tooling to the reviewed `github.workflow_sha`,
separately from the data-only immutable candidate source, and packages an
immutable store-client/control closure. Fresh platform mutation jobs perform no
checkout and verify every executable against workflow-literal SHA-256 values
before they materialize only that platform's credential; candidate-authored
tooling never receives store credentials. Before candidate artifacts or
credentials, the bootstrap must authenticate the supplied run through the
GitHub Actions API as the exact successful, completed `workflow_dispatch` of
`.github/workflows/mobile-release.yml` from `main`, with matching source SHA,
run attempt and repository, plus the exact all-success eight-job surface:
credential-free preparation, isolated Android and iOS signers, `production
signed candidate`, uncredentialed store-client bootstrap, isolated Android and
iOS uploads, and the credential-free signed-release finalizer. It
accepts only the unique non-expired attempt-bound candidate, handoff, and final
signed-release-outcome artifacts, records their distinct server IDs/digests,
and downloads by immutable artifact ID.
Dispatch `protected-mobile-store-rollout` only after its reviewers retrieve the
exact production signed-release artifact and reconcile its canonical candidate
and provenance IDs, run ID/attempt, version/build, signed-release workflow
revision, and portal records. A staged Play update also
requires an exact eligible prior completed production fallback. An iOS `start`
requires the exact prior public version in current `appVersionState`
`READY_FOR_DISTRIBUTION`, the exact target in a reviewed pre-submit state, and
an exact `INACTIVE` phased resource after submission; absence of that prior
record refuses first publication. Retain reviewed store pre/post state and an
unconditional outcome for every selected platform,
including failed or not-run operations, before the job reports a final failure;
partial success must be reconciled before retry.

Do not use staged/phased evidence for a first public store version. Follow the
separate mobile procedures for a 100% first Play publication and an App Store
first-version submission with the selected manual-release setting, exact
`Pending Developer Release`/release-or-withheld pre/post state, UTC action time,
portal audit, and store-owner approval. If only one platform is an update, scope
the protected staged workflow to that platform and retain the other platform's
first-publication record separately.

For updates, start Play at one percent; Apple's phased percentage schedule
advances automatically. Gate every advance on the exact-build crash/performance
window and release approval, then reconcile each content-addressed outcome with
the stores' independent audit records. A pre-completion halt is terminal for
that candidate in Pakperk automation. An Apple pause affects automatic updates
only and does not stop a manual App Store download, so disable harmful server
writes where applicable, disclose that residual exposure, retain the incident/
change record, increment the build, and fix forward. After Play reaches 100%, a
separate protected Android-only full-release halt may restore the exact prior
eligible release for new/eligible users; it does not downgrade installed users,
has no Apple equivalent, and is unavailable for the first Play production
release. See
[the protected staged-rollout procedure](../mobile-release.md#protected-staged-store-rollout).

Store owners must supply a disposable reviewer account with verified email, no
public handle, no current Terms or Community Guidelines acceptance, no
real-user data, no privileged role, and a rotation/expiry owner so the exact
candidate exercises onboarding. Review notes describe guest reading, sign-in,
report/block, account deletion, web deletion URL, strict metadata/full-text
behavior, and any
staging-only coordinates. Credentials stay in store portals, never Git/issues.
Start from the sanitized
[store reviewer-notes template](../store/reviewer-notes-template.md) and keep
every bracketed evidence field release-blocking until the exact candidate is
verified. Follow its bounded lifecycle: create, walk through, delete, verify
application/provider absence, rotate credentials, and retain only sanitized
hashes, timestamps, evidence references, and owner approval.

The production signed-release upload writes an owner-only, fsynced attempt
journal before each Play/TestFlight binary send and retains an unconditional
`mobile-store-upload-attempt-<run-id>-<attempt>` artifact. Play readback must
bind the exact server-side bundle SHA-256 to the candidate AAB; Apple readback
must bind the exact app, build and pre-release-version resource IDs, iOS
platform, and completed BuildUpload relationship. Its singular IPA asset must
be a completed `ASSET`/`com.apple.ipa` file whose SHA-256 and byte size equal
the candidate and the pre-send journal; retain the BuildUpload ID and asset
BuildUploadFile ID in the immutable handoff. If a journal exists without that
authoritative readback, treat the upload as `unknown_reconcile_required` and
reconcile the portal before retry.

TestFlight/closed Play upload, protected update rollout or separately approved
first-publication execution and store-side audit reconciliation, physical-device
deep links/callbacks/deletion, current Data Safety/App Privacy/age-rating forms,
review status, measured startup/cache targets, and a representative crash-free
observation window are external gates. Mark each with evidence or leave the
release blocked.

For `protected-mobile-store-rollout`, record the immutable
`store-handoff-v1:sha256:<digest>` emitted by the successful production signed
release. Do not dispatch from a run that omitted store uploads or lacks the
separate verified handoff artifact. A retained attempt journal marked
`unknown_reconcile_required` means the request may have reached the store;
inspect the exact Play/App Store resource and resolve the release ledger before
retrying. In a `both` transition, do not permit the Apple request unless the
Android result and journal gate is already `succeeded_verified`. The workflow
implements this as an uncredentialed bootstrap, isolated Android and iOS jobs
with only their respective secret families, and a credential-free `always()`
finalizer. The iOS job must download and validate the immutable Android outcome
for `both`; each selected platform uploads its own outcome ID and server digest
after unconditional secret cleanup, including on failure. Retain the final
schema-v4 aggregate that binds the signed run, candidate/provenance/handoff,
source, version/build, transition, and exact success/unselected/dependency-skip
semantics. Normalize the upload action's raw 64-hex artifact digest to
`sha256:<hex>` before comparing or recording it.
