# Assistant tools: implementation and testing status

Updated: 2026-09-07. **Implemented behind a default-off flag; integration verification is blocked. Not release-ready.**

## Implementation

The existing Assistant v2 endpoint now has a native, bounded tool-selection branch. It supports six read-only operations, and every tool-enabled request starts with an outline of the authorized scope (the sections in reading order, each with the ID of its first block and its size) so that the model can choose what to read without spending a call on navigation:

| Tool | Purpose |
| --- | --- |
| `search_paper_evidence` | Positive-match lexical search over current-paper source blocks: any stemmed content word matches, and blocks that contain all of them rank first; headings are not searched (the outline lists them) |
| `get_paper_outline` | Bounded heading navigation, available only for paper/section scopes |
| `read_paper_range` | Up to six consecutive blocks in reading order from a known block, with the ID of the next block; paper/section scopes only |
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

Limits: three selection rounds, three calls per round, then one final answer request; at most ten accumulated and eight final blocks; 20,000 Unicode scalars per block and 100,000 in final evidence; 256 KiB cumulative tool-result JSON. There is no wall-clock deadline on the tool-enabled operation: the round/call budgets above bound the work, and a slow provider is allowed to finish instead of being cut off mid-inference. `LLM_TIMEOUT_SECONDS` remains the only time budget, covering one provider call and its retries. Repository reads have a two-second SQL statement timeout and do not hold transactions across model calls. Infrastructure failures remain errors rather than factual “not found” answers.

Tools only ever add evidence, so a tool step that the provider or model gets wrong does not fail the request: an unexpected response shape, an unknown tool, out-of-range arguments, repeated call identifiers or too many calls stop the loop, the answer is written from the evidence gathered so far (exactly the plain retrieval when nothing was read yet), and a fixed, content-free reason is logged as `assistant_tool_step_unusable`. A call that the request's scope rejects (an unknown or foreign block, for example) returns `status: rejected` to the model instead of failing the request. A stale generation, a database fault, provider unavailability and any breach of the evidence rules still fail. The provider accepts the per-call `index` that DeepSeek adds to a non-streamed response and no other extra field.

## Answer contract with quoted evidence

Prompt version `paper-assistant-v2-quoted-claims-v1` changes what the model writes, not what the API returns. The model returns `status` and `claims`; each claim cites `block_id` plus a `quote`, a passage copied verbatim from that block. The server finds the quote in the exact block that was supplied (runs of whitespace compare equal and typographic quotes and dashes are folded, the first occurrence wins) and stores its Unicode-scalar range, so a quote that is not in the block, or a block that was not supplied, is rejected as before. Explicit `start`/`end` ranges are still accepted for older prompts and provider doubles.

The rendered `answer` and the closed `limitations` notice are no longer taken from the model: the answer is the validated claim texts joined in order (or the fixed not-found sentence) and a `partial` answer carries the fixed notice, so nothing the model writes outside a claim can be shown. Measured on `deepseek-flash` with thinking off, the old contract (exact character ranges plus a verbatim `answer` and `limitations`) passed about one attempt in three.

## Configuration and rollback

Tool-selection steps use their own thinking mode, `ASSISTANT_LLM_TOOL_THINKING` (`LLM_TOOL_THINKING` for the main provider): selecting tools needs no reasoning, and DeepSeek rejects the next step of a tool loop with HTTP 400 unless the reasoning of every earlier step is sent back while thinking is on. It defaults to `disabled` whenever `ASSISTANT_LLM_THINKING` is set explicitly, so the final answer can keep reasoning while the selection steps do not. Set it explicitly for a provider whose thinking is on by default.

Keep `ASSISTANT_TOOLS_ENABLED=false` until integration tests pass. After verification, enabling requires:

```dotenv
DEEP_READER_ENABLED=true
ASSISTANT_V2_ENABLED=true
ASSISTANT_TOOLS_ENABLED=true
LLM_TIMEOUT_SECONDS=1800
```

`/chat` and `/assistant` have no route timeout, so `LLM_TIMEOUT_SECONDS` is what decides how long a reader can wait; raise it for slow local models. The existing provider must support native function calling and the existing structured final-answer format; the flag explicitly opts the configured compatible provider into tool use. Unsupported providers retain their original answer path. Mobile `AssistantV2Api.ask` and `sendChat` have no receive timeout; feedback and unrelated requests retain their existing limits. Deployments still bound these routes at the edge through `api.chatTimeoutSeconds`, which now drives only the ingress proxy timeouts. Existing mobile feature flags and deployment prerequisites still apply.

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
