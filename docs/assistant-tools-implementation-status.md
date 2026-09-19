# Assistant tools: implementation and testing status

Updated: 2026-09-07. **Implemented behind a default-off flag; integration verification is blocked. Not release-ready.**

## Implementation

The existing Assistant v2 endpoint now has a native, bounded tool-selection branch. It supports five read-only operations:

| Tool | Purpose |
| --- | --- |
| `search_paper_evidence` | Positive-match lexical search over current-paper source blocks |
| `get_paper_outline` | Bounded heading navigation, available only for paper/section scopes |
| `read_paper_blocks` | Exact canonical source text and optional in-scope adjacent blocks |
| `get_object_evidence` | Existing source blocks linked to figures, tables, or equations, with extraction status |
| `get_citation_context` | Current-paper passages citing a verified reference; no remote paper fetch |

Integration points:

- `backend/apps/api/src/assistant_tools.rs`: selection loop, evidence registry, budgets, usage accounting.
- `backend/crates/domain/src/assistant_tools.rs`: closed typed arguments.
- `backend/crates/llm_provider/src/tools.rs` and `openai.rs`: native function-call protocol and separate final-answer request.
- `backend/crates/db/src/repository/assistant_v2/tools.rs`: bounded, generation-checked source queries.
- `backend/apps/api/src/routes/assistant_v2.rs`: flagged orchestration with existing validation and persistence.

Paper, generation, and original scope come from the server request, not model arguments. Queries cannot expand that scope. Selection endpoints are checked against canonical Unicode-scalar text lengths. Persistence locks active account state so deletion accepted during inference prevents saving the exchange. These database boundary changes still require execution of the integration tests below.

The original final answer, evidence navigation, history, feedback, and provenance formats remain in place. Tool transcripts and raw arguments/results are not persisted or logged. The final evidence set is persisted, and the final prompt version is tagged `paper-assistant-tools-v1`. No migration, worker, vector index, external browsing, memory write, or queue mutation was added.

Limits: two selection rounds, two calls per round, then one final answer request; at most ten accumulated and six final blocks; 20,000 Unicode scalars per block and 100,000 in final evidence; 256 KiB cumulative tool-result JSON. The total tool-enabled operation deadline is 50 seconds, with at most 20 seconds for selection/tools. Repository reads have a two-second SQL statement timeout and do not hold transactions across model calls. Provider retries remain inside the operation deadline. Infrastructure failures remain errors rather than factual “not found” answers.

## Configuration and rollback

Keep `ASSISTANT_TOOLS_ENABLED=false` until integration tests pass. After verification, enabling requires:

```dotenv
DEEP_READER_ENABLED=true
ASSISTANT_V2_ENABLED=true
ASSISTANT_TOOLS_ENABLED=true
CHAT_REQUEST_TIMEOUT_SECONDS=65
```

Configuration rejects a tool-enabled route timeout below 55 seconds. The existing provider must support native function calling and the existing structured final-answer format; the flag explicitly opts the configured compatible provider into tool use. Unsupported providers retain their original answer path. Mobile `AssistantV2Api.ask` alone has a 65-second receive timeout; feedback and unrelated requests retain their existing limits. Existing mobile feature flags and deployment prerequisites still apply.

Helm has `features.assistantTools` and dependency validation. Disable the tools flag and restart/redeploy to roll back the tool branch. No database rollback is needed for these changes.

## Test results

| Check | Observed result |
| --- | --- |
| Provider unit and mock HTTP tests | 40 unit + 4 integration tests passed; rerun on 2026-09-07 |
| API unit suite | 196 passed, 2 failed on Windows; all 5 new orchestration tests passed |
| Rust Clippy, all targets for API/DB/provider/domain | Passed; only existing warnings in account-deletion code and an unrelated authenticated-API test |
| Focused Flutter transport/scope/widget tests | 22 passed in the preceding implementation session; mobile code has not changed since that run |
| PostgreSQL integration | Rerun on 2026-09-07: all 6 tests failed during existing migration 12, before tool queries execute; none counted as passing |
| Formatting and whitespace | `cargo fmt` applied; `git diff --check` passed |
| Live model / answer-quality evaluation / Helm rendering | Not performed; no production-readiness or accuracy claim |

The two API failures are `visual_assets::tests::reads_a_bounded_raster_and_returns_its_digest` and `visual_assets::tests::rejects_traversal_oversize_and_executable_markup`. Existing `same_file_identity` returns false on non-Unix platforms, producing `InvalidKey`. That security check was not weakened to make tests pass.

The PostgreSQL 16 test instance failed with `null character not permitted` at migration 12. Historical migrations use `position(chr(0) IN ...) = 0`; PostgreSQL rejects `chr(0)` itself. Migration checksums are enforced by SQLx and readiness checks. Historical files have **not** been rewritten and checksum validation has **not** been bypassed. Repair requires an explicit migration-compatibility decision before continuing database verification.

Reproduction commands, from `backend` (use a disposable PostgreSQL database with the required extensions):

```powershell
$env:AWS_LC_SYS_PREBUILT_NASM = '1' # Windows: crate-provided assembly when NASM is absent
cargo test -p llm_provider --offline
cargo test -p pakperk-api --lib --offline
cargo clippy -p pakperk-api -p db -p llm_provider -p domain --all-targets --no-deps --offline
$env:TEST_DATABASE_URL = 'postgres://USER:PASSWORD@127.0.0.1:PORT/DISPOSABLE_DATABASE'
cargo test -p pakperk-api --test postgres_chat_api --offline
```

From `mobile`:

```powershell
flutter test test/core/assistant_v2_api_contract_test.dart test/core/assistant_v2_scope_test.dart test/widgets/assistant_v2_sheet_test.dart
```

The implementation runs used a separate disposable Cargo target directory, not the pre-existing `backend/target`. PostgreSQL tests that return early without `TEST_DATABASE_URL` are skips, not verification.

Cleanup completed: the disposable PostgreSQL server was stopped; `.assistant-tools-target`, `.assistant-tools-test`, `mobile/build`, and `mobile/.dart_tool` generated during this work were removed. These are reproducible test/build artifacts, not recoverable deliverables. Source changes, user competition documents, and the pre-existing `backend/target` were preserved.

## Remaining acceptance gates

1. Approve and repair the pre-existing migration blocker with an explicit checksum-compatible upgrade policy; verify both clean initialization and applicable upgrade paths.
2. Execute the new PostgreSQL tests: five-tool source reads, foreign/stale data rejection, oversized blocks, Unicode selections, section/selection neighbor isolation, search-then-read HTTP flow with newly discovered persisted evidence, and deletion-before-publication rejection. They compile but have not passed against PostgreSQL.
3. Complete executed coverage for figure/table and Passport scopes, policy/generation races, provider failures, and tools-off/unsupported-provider compatibility. Existing tests and source review alone do not close these gates.
4. Rerun relevant suites after any fixes; run visual-asset regressions on a supported Unix environment and validate Helm rendering.
5. Before rollout, compare tools off/on using the same papers/questions and a configured live model: supported-claim quality, abstention, retrieval success, latency, and aggregate token usage. Lexical block search is not hybrid retrieval, and source traceability alone does not prove claim correctness.
