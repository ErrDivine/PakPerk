# Assistant tools: minimal-change implementation plan

Status: proposal only; no implementation has been changed. Inspected on 2026-09-06.

## 1. Recommendation

Extend the existing **Assistant v2** with a bounded, server-executed tool loop. Start with three LLM-callable, read-only tools: `search_paper_evidence`, `get_paper_outline`, and `read_paper_blocks`. Add object and citation-context tools as a separate follow-up after the core loop is verified.

Keep the Rust modular monolith, PostgreSQL, current document model, final answer schema, citation validation, history/provenance persistence, and Flutter assistant presentation. Use the existing `/v1/papers/{paper_id}/assistant` endpoint. No new agent framework, MCP server, public tool API, database, vector store, or background queue is needed for the first increment.

This plan interprets “fetch more information” as retrieving additional evidence from the current prepared paper and declared scope. This follows the competition proposal's explicit current-paper boundary. Web browsing, other papers' full text, personal memory retrieval, and write tools would require separate scope and evidence contracts.

## 2. Where the assistant is implemented

There are two implementations, not one. The active mobile path depends on build flags; the checked-in defaults do not establish what any deployed build enables.

| Layer | Existing implementation | Responsibility |
| --- | --- | --- |
| Mobile path selection | [`mobile/lib/app/router.dart`](../mobile/lib/app/router.dart), `PaperChatRouteScreen.build` | Chooses `AssistantV2Sheet` when `assistantV2` is enabled, otherwise `PaperChatSheet` |
| Reader entry points | [`mobile/lib/features/paper_reader/paper_reader.dart`](../mobile/lib/features/paper_reader/paper_reader.dart), [`document_screen.dart`](../mobile/lib/features/document_reader/document_screen.dart) | Hands current paper, generation, scope, and question into the assistant flow |
| v2 UI | [`assistant_v2_sheet.dart`](../mobile/lib/features/chat/assistant_v2_sheet.dart) | Submits questions, displays claims, navigates evidence, supports feedback/provenance |
| v2 mobile transport | [`assistant_v2_api.dart`](../mobile/lib/core/document/assistant_v2_api.dart) | Calls `/assistant`, checks response generation/thread, retains auth-epoch and cancellation boundaries |
| v2 HTTP orchestration | [`backend/apps/api/src/routes/assistant_v2.rs`](../backend/apps/api/src/routes/assistant_v2.rs) | `assistant`, `generate_answer`, `validate_answer_boundary`; authorization, retrieval, inference, validation, persistence |
| v2 retrieval and storage | [`backend/crates/db/src/repository/assistant_v2.rs`](../backend/crates/db/src/repository/assistant_v2.rs) | `AssistantContextRepository`: scoped retrieval, owned threads, atomic exchanges, feedback, provenance, retention |
| Model interface | [`llm_provider/src/traits.rs`](../backend/crates/llm_provider/src/traits.rs) | `AssistantProvider::answer_with_evidence`; separate chat, embedding, and relationship interfaces |
| Model HTTP adapter | [`llm_provider/src/openai.rs`](../backend/crates/llm_provider/src/openai.rs) | `OpenAiCompatibleProvider` sends one structured answer request to the configured `chat/completions` endpoint |
| Prompt and output checks | [`prompt.rs`](../backend/crates/llm_provider/src/prompt.rs), [`validation.rs`](../backend/crates/llm_provider/src/validation.rs) | Untrusted-document framing, JSON answer schema, evidence checks and trusted metadata reconstruction |
| Shared contracts | [`domain/src/assistant_v2.rs`](../backend/crates/domain/src/assistant_v2.rs), [`llm_provider/src/types.rs`](../backend/crates/llm_provider/src/types.rs) | Request scope, claims, Unicode-scalar evidence ranges, completion and context limits |
| Legacy chat | [`routes/chat.rs`](../backend/apps/api/src/routes/chat.rs), [`chat_controller.dart`](../mobile/lib/features/chat/chat_controller.dart), [`chat_sheet.dart`](../mobile/lib/features/chat/chat_sheet.dart) | Existing `/chat` flow with hybrid chunk retrieval and a different answer contract |

Server registration is in [`app.rs`](../backend/apps/api/src/app.rs). `ASSISTANT_V2_ENABLED` defaults off and requires `DEEP_READER_ENABLED`; mobile has the corresponding default-off `PAKPERK_ASSISTANT_V2_ENABLED` and Deep Reader dependency. The v2 server supports owner or anonymous principals; the current mobile v2 transport requires authentication. This extension should not change those distinctions.

### Current execution paths

```text
Legacy /chat
  validate session/policy/readiness -> embed question
  -> vector + keyword candidates -> RRF -> select up to 6 chunks
  -> ChatProvider.answer -> persist chat exchange

Assistant v2 /assistant
  authorize principal/policy/rate limit -> validate request
  -> AssistantContextRepository.retrieve -> open owned thread
  -> AssistantProvider.answer_with_evidence
  -> provider validation + validate_answer_boundary
  -> persist answer, claims, and provenance atomically -> existing UI
```

The v2 `paper_blocks` and `section_blocks` queries rank `document_blocks` using PostgreSQL `plainto_tsquery` and `ts_rank_cd`, then document ordinal. They do not call the embedding provider or RRF. They can return zero-score blocks because they order by rank without requiring a positive match. Other v2 scopes retrieve selections, linked objects, or Passport source blocks. The current cap is ten blocks, with provider limits of 20,000 Unicode scalars per block and 100,000 in total.

No tool definitions, tool-call dispatch, or iterative tool-result exchange exists in this assistant path. A structured final-answer schema alone is not tool calling.

## 3. Project context and proposal alignment

The review covered repository structure, architecture and feature contracts, mobile routing/transport, assistant and provider implementations, retrieval/storage, document schema and readers, worker indexing/reference paths, and relevant tests/evaluation and deployment configuration. This is a source review, not an execution of the entire test suite or verification of deployment/performance claims. Generated mobile sources, vendored dependencies, and release assets are not proposed edit targets.

| Existing subsystem | Relevance to tools | Planned treatment |
| --- | --- | --- |
| API and `llm_provider` | Request orchestration and model access | Main integration points |
| Worker, GROBID, document ingestion/model | Produces blocks, objects, inline references and source locations | Reuse prepared outputs; no new parsing work in a tool |
| PostgreSQL repositories and `retrieval` | Source authority; existing lexical/vector chunk retrieval | Reuse block repositories first; preserve chunk/block distinction |
| arXiv client and paper resolution | Cached/rate-gated metadata and reference resolution | No new network access in initial tools |
| Library, reading feed, discovery, recommendations | Queue First and explicit navigation | No tool mutations or automatic queue changes |
| Annotations, research memory, accounts/deletion | Private data ownership and Memory by Choice | No new memory ingestion; preserve assistant retention/export/deletion |
| Flutter/Drift/outbox | Reader UX, private cache and synchronization | Keep final response/UI contract; targeted request timeout only |
| Deployment, telemetry and evaluation | Flags, resource limits and release evidence | Small flag wiring and bounded metrics; preserve existing rollout gates |
| `site`, `docs-site`, demo and third-party assets | Supporting surfaces and fixtures | No first-increment product changes |

The source proposal is [`competition_file/附件3-项目实现方案模板.docx`](../competition_file/附件3-项目实现方案模板.docx), particularly chapter 1 “Evidence First”, chapter 2 “证据检索、问答与引用关系构建”, and chapter 3 “将 AI 输出纳入可确定校验的证据链”. Its text was extracted in memory; the Word file was not changed or rendered.

| Proposal requirement | Present state | Plan |
| --- | --- | --- |
| 专用 tools 用于原文定位、证据检索 | No LLM tool loop | Native model tool calls executed through a closed server registry |
| 当前论文、当前版本、实际检索证据 | v2 already checks paper/generation and supplied blocks | Apply the same bounds to every tool result and final evidence set |
| 关键词与语义检索、RRF、至多 6 个证据块 | Implemented for legacy chunks; not the v2 block retrieval path | First increment uses existing block lexical retrieval and up to six final blocks; hybrid block retrieval remains a separate follow-up |
| 服务端核验 ID、页码、章节、字符范围 | v2 provider and API validators exist | Reuse them against the final tool-derived context |
| 真实引用上下文决定关系 | Worker/reference infrastructure exists | Optional citation tool exposes source context, never treats generated relation summaries as primary evidence |
| Queue First / Memory by Choice | Existing independent authority boundaries | Tools are read-only; no automatic save, enqueue, import, or memory write |

The proposed tools close the tool-calling gap, but do not make every sentence of the proposal an already-verified implementation fact. In particular, do not claim v2 hybrid retrieval, better answer accuracy, or production readiness until implemented and measured. Valid source IDs/ranges prove traceability, not that a claim logically follows from its cited text; human evaluation is still required.

## 4. Smallest useful tool set

Tool names and signatures below are proposed internal contracts. They are not new HTTP endpoints. The LLM supplies only task arguments; principal, paper ID, generation, original scope, deadline, and budgets come from a server-created immutable `AssistantToolContext`.

### 4.1 `search_paper_evidence`

Arguments: `{ query: string, section_kinds?: SectionKind[], limit?: integer }`.

- `query`: 1–500 Unicode scalars; no NUL. `limit`: 1–6, default 4. Section filters use the existing enum and may only narrow the original scope.
- Search prepared `document_blocks` within the current paper/generation. Reuse v2 lexical ranking, but add an explicit positive-match criterion for this new search method so unrelated leading paragraphs are not reported as search hits.
- Return source block IDs, canonical text, trusted section/page metadata, and a closed outcome such as `ok` or `no_matches`. The model can reformulate a query within its remaining call budget.
- Keep the original user question unchanged. A reformulated search query is a separate retrieval argument, never a replacement `AssistantRequest.question` saved in history.
- Do not return generated Passport prose, old assistant responses, or relation summaries as factual evidence.

This tool is the main improvement for a question whose needed evidence was missed by the initial one-shot selection.

### 4.2 `get_paper_outline`

Arguments: `{ limit?: integer }`, 1–40, default 20.

- Return bounded heading block IDs, section paths/kinds where actually available, and known page numbers. The response explicitly indicates truncation.
- Reuse the document-outline data model, but implement a bounded query for this tool. `DocumentReaderRepository::outline` currently fetches all headings; truncating after an unbounded fetch is not an adequate database-work limit.
- Limit results to the original scope. Disable this tool where an outline provides no useful permitted navigation, such as a single selected block.
- Treat outline entries as navigation metadata. Final material claims need source blocks admitted into the final evidence set.

This lets the model identify a relevant Results or Limitations section before searching or reading it.

### 4.3 `read_paper_blocks`

Arguments: `{ block_ids: UUID[], neighbors?: integer }`, 1–4 distinct IDs; `neighbors` is 0 or 1, default 0.

- Load exact blocks and, where permitted, immediate ordinal neighbors within the same allowed scope. Return no more than six blocks per call.
- IDs can come from initial evidence or earlier tool results. Every ID must also be verified in the database against paper, generation and scope; being syntactically valid or previously seen is not authorization.
- Return full canonical block text within the existing size limit. Never silently truncate text and then validate offsets against a different string. Oversized blocks yield a bounded `content_too_large` result; introducing offset-preserving text windows is deferred.
- A neighbor must independently pass the scope filter. A request concerning one section cannot read the next section merely because its block ordinal is adjacent.

This supports exact source localization and recovering nearby context around a retrieved paragraph without loading the full paper.

### 4.4 Follow-up tools, after the core is accepted

`get_object_evidence({ object_id, kind })` can reuse current figure/table/equation ownership checks and inline-span/context-block lookup. Return only existing, in-scope source blocks plus bounded object metadata and extraction status. A figure caption does not establish unseen plot values. Raw table grids or equation objects require a traceable block representation before their contents can become claims under the unchanged answer schema. Do not fabricate block IDs to accommodate them.

`get_citation_context({ reference_id, limit? })` can retrieve current-paper blocks whose inline citation spans target that reference. Validate the reference against the same paper/generation and intersect with the original scope. The existing `PaperRepository::citation_contexts(reference_id)` accepts only a reference ID and fetches all contexts; it must not be exposed directly as a scoped, bounded tool. Add the necessary guarded query. If legacy citation text cannot map exactly to a canonical document block, omit it from citable evidence. Do not fetch the cited paper or infer a relation from titles/similarity alone.

Defer web search, arbitrary URL/PDF fetching, cross-paper comparison, personal notes/memory search, computation/code execution, Library changes, and automatic saving. None is necessary to implement the proposal's current-paper retrieval and localization tools.

## 5. Integration design

Keep tool orchestration in the API application, using a small new module such as `backend/apps/api/src/assistant_tools.rs`. The provider adapter knows model protocols; the database knows source records; neither should own the other layer's responsibilities.

```text
Existing authorization, scope validation, initial retrieval, owned thread
  -> tool flag + provider capability check
       disabled/unsupported: existing generate_answer path
       enabled: bounded tool-selection loop
         LLM requests named tools -> server validates/executes
         -> bounded untrusted tool results -> optional second selection round
  -> freeze final evidence set
  -> existing structured answer generation with tools absent
  -> existing provider + API evidence checks against that SAME set
  -> existing atomic history/provenance persistence -> existing response/UI
```

### Provider seam

Extend `AssistantProvider` additively with a capability method defaulting to false and a tool-selection step method with a default unsupported result. Keep `answer_with_evidence` intact. This avoids adding another required supertrait to `ApiModelProvider` and breaking all existing provider doubles.

Add separate typed tool definitions, argument enums, tool-call IDs, results and step responses in `llm_provider`; use a separate provider envelope for tool selection. The existing answer envelope expects text content, whereas a tool-only response may have absent/null content. Do not loosen the existing final-answer parser to accommodate arbitrary tool output.

For the configured compatible adapter, implement tool selection using native function-tool declarations and assistant tool-call / tool-result message pairs. Validate the actual deployment endpoint's protocol support with mock-server tests and a bounded live check during implementation. The adapter family name alone does not prove a configured model supports tool calling. Use an explicit capability/configuration choice rather than probing on every user question.

Tool-selection responses may request tools or signal completion. Free prose from this phase is never displayed or persisted as an answer. After selection, make a fresh final `answer_with_evidence` call containing the unchanged question, bounded existing history, and the frozen evidence blocks. The existing final JSON schema and validation remain authoritative. This intentionally separates the new tool protocol from the already-working structured answer protocol.

### Evidence accumulation and finalization

Maintain an in-memory evidence registry keyed by `(paper_id, generation, block_id)`. Deduplicate results and require canonical text/metadata consistency. Admit at most ten unique blocks cumulatively; never evict and refill indefinitely. Reserve capacity for new tool results by seeding the tool-enabled branch with no more than four initial blocks. The disabled branch retains today's limits and behavior.

Freeze at most six final evidence blocks within the existing scalar limits. Prioritize mandatory selection/object evidence, exact requested block reads, then ranked search results, using deterministic tie-breaking. If mandatory evidence cannot fit, preserve the bounds and decline unsupported parts. Only this final set is supplied to generation, validated, and passed as `AssistantRetrievalContext` to `persist_exchange`; persisting the initial context after generating from new blocks would break the provenance chain.

A block merely seen in an earlier tool round is not automatically citable after final selection. Final generation receives no discarded tool-result transcript. Outline and object metadata are not independently citable through the current block-range schema.

Keep all existing hard readiness and authorization failures. If initial retrieval fails because no current document/scope evidence exists, return the existing error; tools must not initiate preparation to bypass it.

### Scope semantics

For paper scope, tools can search the current paper. For section scope, intersect every tool filter with the requested section kinds. For selection scope, retain the current behavior of using the selected block as context: existing retrieval checks the selected range but returns the complete block. Do not claim that existing validation restricts every citation to the selected characters. The initial tool increment must not expand selection scope to other blocks.

For figure/table/equation and Passport-field scopes, allow only their existing source-block relationships, not arbitrary same-paper blocks. Disable irrelevant tools instead of silently widening the scope. A broader question needs an explicit new request in a broader scope.

## 6. Reliability limits and failure behavior

Use a small static allowlist and typed deserialization with unknown fields rejected. There is no dynamic function lookup, shell execution, arbitrary SQL, or model-provided endpoint. Validate arguments again at dispatch even when the provider advertises strict schemas.

Proposed initial budgets, to be validated against latency measurements:

- At most two tool-selection model rounds, four total tool executions, and one final answer request: three logical model requests maximum.
- At most two requested tools in one round; execute sequentially initially. Reject an oversized batch before executing it. Every attempted execution counts, including invalid arguments and no-match results.
- At most 8 KiB argument JSON per call; bounded response bytes as well as scalar counts; at most 256 KiB cumulative serialized tool results. All limits include repeated results, not only unique blocks.
- At most ten accumulated blocks and six final blocks; per-block 20,000 scalars and final total at most 100,000 scalars, matching or tightening existing validation. Enforce bounds before materializing or serializing large results where possible.
- One absolute end-to-end deadline, including database work, adapter retries/backoff, tool rounds, final generation, validation and persistence. Bound SQL execution time and do not hold a transaction open while waiting on the model.

`no_matches` is different from `not_ready`, stale generation, policy denial, timeout, or provider failure. Genuine insufficient evidence may produce the existing `not_found`/`partial` answer contract. Infrastructure errors must not become “Not found in this paper.” Unknown names, malformed arguments, oversized payloads, duplicate call IDs and invalid message ordering are rejected through bounded, content-free error handling. Scope violations never return foreign data.

For configured unsupported providers, choose the original v2 path before tool execution. For runtime provider/protocol failures, return the existing error mapping rather than automatically replaying another full inference path. This avoids hidden duplicate cost. When the planned round/call budget is exhausted normally, proceed to the final generation using admitted evidence if time remains; deadline exhaustion returns the existing timeout failure.

Use request-scoped futures, no detached tool tasks, and propagate cancellation through awaited operations. The API deadline must stop further tool dispatch. Do not promise that an upstream provider can cancel already-accepted inference or billing when the client disconnects.

Recheck current generation on source reads and preserve the transactional generation/thread check in `persist_exchange`. Recheck applicable content policy before final publication in the tool-enabled branch. Test generation replacement and account deletion while model work is in flight; nothing should return or persist under a stale or invalid authority.

### Mobile timeout is a necessary compatibility detail

The shared authenticated Dio instance in `mobile/lib/app/account_providers.dart` has a 20-second receive timeout. `AssistantV2Api.ask` currently inherits it. Backend middleware already recognizes `/assistant` as a long-running chat request, with a separately configured timeout.

Plan a narrowly scoped `receiveTimeout` override in `AssistantV2Api.ask`, retaining the same shared Dio, auth epoch, cancellation and no-automatic-retry policies. A candidate budget is a 50-second tool-enabled server operation deadline, a server route/proxy allowance above it, and a 65-second mobile receive timeout; these are proposed values, not measured targets. Validate actual deployment settings and final-generation time reservations before enabling the flag. Do not change all API request timeouts or simply multiply the existing provider timeout by the number of rounds.

## 7. Privacy, provenance and observability

Tools read shared, policy-permitted paper artifacts only. Existing assistant question/answer retention is preserved; raw tool conversations, chain-of-thought, search queries and tool argument/result bodies are not added to persistent history, logs, exports or telemetry.

Reuse current answer provenance: exact final source block IDs, parser/version, provider/model ID and final prompt version. Add an explicit tools prompt/version identifier for the enabled path. If retaining `tool_round_count`, `tool_call_count` or `tools_enabled` in provenance, use the existing bounded integer/boolean `ProvenanceParameters` contract and verify its schema and mobile parsing; do not insert an arbitrary transcript or string-valued trace. No new trace table or retention migration is planned.

Record bounded tool-name enums, closed outcomes, latency and result counts through existing observability. No block IDs or questions as metric labels. Aggregate provider-reported usage across selection and answer calls, including failures where available; never record final-answer-only tokens as total tool-run cost. Missing usage remains explicitly unavailable, not zero or an estimate. Keep final-completion identity distinct from aggregate cost accounting.

Existing ownership, private/no-store responses, feedback lookup, account export/delete and expiry cleanup continue to operate on the unchanged answer representation.

## 8. Expected file changes during later implementation

The following is a future change map, not changes made by this planning task.

| File / group | Minimal planned change |
| --- | --- |
| New `backend/apps/api/src/assistant_tools.rs` | Registry, immutable execution context, budgets, dispatcher, loop, evidence finalization |
| `backend/apps/api/src/lib.rs` | Register the internal module |
| `backend/apps/api/src/routes/assistant_v2.rs` | Add flagged branch; return final context with completion; reuse validation/persistence; aggregate accounting |
| `backend/crates/llm_provider/src/traits.rs`, `types.rs`, `lib.rs` | Add optional tool-selection capability and export typed contracts; preserve existing answer interfaces |
| New `backend/crates/llm_provider/src/tools.rs` plus `openai.rs` / `prompt.rs` | Native tool envelope/payload handling, closed definitions and tool-phase prompt; distinct enabled final prompt version |
| `backend/crates/llm_provider/src/deterministic.rs` | Scripted/deterministic tool behavior for tests; preserve existing demo answer behavior |
| `backend/crates/db/src/repository/assistant_v2.rs` | Add bounded, generation/scope-checked search/outline/read methods; reuse source conversion and persistence |
| `backend/apps/api/src/config.rs` and provider construction in `app.rs` as needed | Default-off `ASSISTANT_TOOLS_ENABLED`, dependency on v2, validated budgets/capability configuration |
| `.env.example`, `docker-compose.yml`, Helm values/schema/API template | Pass the default-off setting consistently; no default feature enablement |
| `mobile/lib/core/document/assistant_v2_api.dart` | Assistant-only receive timeout override; no new request/answer fields or UI |
| Existing observability module and relevant tests | Content-free tool phases/outcomes and full-run usage accounting |
| Focused backend/provider/DB/mobile tests and evaluation fixtures | Tool behavior, source boundaries, compatibility and regressions |

Keep `routes/chat.rs`, legacy chat retrieval, worker parsing/indexing, domain answer DTOs, OpenAPI wire shapes, database migrations, Library/memory mutation code, and mobile evidence rendering unchanged in the first increment. Regenerate OpenAPI only if an actual public contract change becomes necessary; none is planned. Do not create a new workspace crate merely to hold three tools.

The optional object/citation tools add guarded source queries to this same boundary. They do not justify changing the worker or source schema solely to make unavailable data appear available.

## 9. Delivery sequence and acceptance criteria

### Increment A: core tool loop

1. Add typed native tool-selection support with default unsupported behavior for existing providers. Verify envelope parsing and protocol sequencing with mock HTTP responses.
2. Implement the three read-only tools and immutable scope/budget enforcement. Test against PostgreSQL with same-paper, foreign-paper and stale-generation fixtures.
3. Wire the flagged v2 branch and final-context persistence. Preserve the original path when disabled. Add request deadline and targeted mobile timeout handling.
4. Add bounded observability and deployment flag wiring. Run focused compatibility and behavioral checks. Leave the flag off by default.

Acceptance requires a scripted model to choose a search query, receive real repository results, request a source block, then produce a validated answer whose evidence was absent from the initial seed. This demonstrates actual LLM-directed tool use rather than a renamed fixed retrieval pipeline.

### Increment B: structured-object and citation-context tools

Add the two follow-up tools only after verifying exact current-generation block mappings. Exercise a table/equation context and a real inline citation example. Missing mappings or caption-only extraction must produce an explicit bounded limitation/no-evidence result, not invented content.

### Increment C: optional hybrid retrieval alignment

Do not mix this larger retrieval improvement into the minimal tool-loop increment. Legacy indexed `paper_chunks` and v2 `document_blocks` have different IDs and boundaries. Reusing vector candidate IDs as block IDs would be invalid; same-section membership alone is not an exact evidence mapping.

If later required, first inspect and prove a deterministic chunk-to-block mapping for the same generation using canonical source boundaries/text. RRF can then rank mapped candidates, but final claims still cite actual blocks. If exact mapping cannot be established, evaluate a dedicated block embedding/index migration separately. Keep lexical tools functional when vector preparation is unavailable. Until this follow-up is implemented and evaluated, describe v2 tools as block lexical retrieval plus structured source navigation, not hybrid RAG.

### Required verification for implementation

| Check | Passing behavior |
| --- | --- |
| Flag disabled / unsupported provider | Existing v2 request/answer contract and model-call path remain valid; legacy `/chat` unaffected |
| Useful tool chain | LLM-selected search/read finds non-seed evidence; final claim/source/provenance resolve to the same exact blocks |
| Scope matrix | Paper, section, selection, object and Passport scopes cannot expand through parameters, guessed IDs or neighbors |
| Stale data / ownership | Generation change, cross-principal thread and deletion races reject publication/persistence appropriately |
| Tool protocol | Null-content tool response, multiple calls, malformed JSON, unknown tool, duplicate IDs and invalid sequences handled deterministically |
| Resource limits | Endless tool requests, huge results, slow SQL/provider and retries stop within shared budgets; no background dispatch after termination |
| Evidence validation | Invented IDs/pages/headings, whitespace-only ranges and ranges outside canonical Unicode-scalar text are rejected; emoji/CJK offsets work |
| Prompt injection | Instructions in blocks, headings, captions, history and tool results cannot authorize new tools/scope or bypass final source checks |
| Empty vs failed retrieval | No-match answers abstain; unavailable/stale/policy failures remain errors, not factual absence claims |
| Privacy / accounting | No raw tool I/O or private text in logs; usage includes selection rounds; retention/export/delete behavior remains compatible |
| Mobile regression | Existing evidence jump, feedback, stale-generation rejection, auth-epoch fence and cancellation still work; timeout is assistant-specific |

Use `llm_provider/tests/mock_server_boundaries.rs`, API `tests/postgres_chat_api.rs`, the existing DB document/Passport tests and a focused new assistant-tools test module, plus mobile `assistant_v2_sheet_test.dart` and transport contract coverage as starting points. PostgreSQL tests that skip without `TEST_DATABASE_URL` are not passing integration evidence: run them with a disposable configured database during implementation.

Compare tools off/on on the same questions, model settings and paper generations. Include direct lookup, methods, limitations, multi-section questions, objects, citation context and unanswerable questions. Measure evidence retrieval success, human-judged claim support, abstention quality, latency, model requests and reported token usage. Require zero accepted cross-paper/stale/forged evidence in boundary tests and demonstrable improvement on missed-evidence cases without regression on simple questions. Set operational latency/cost targets from measurements before rollout rather than inventing successful benchmark numbers.

The existing `evaluation/deep-reader-v1` corpus is explicitly synthetic and not release evidence. Add content-safe test scenarios without changing protected `not_ready` statuses to imply human, live-model or signed-device validation occurred.

## 10. Rollback and scope of this planning task

Rollback is disabling `ASSISTANT_TOOLS_ENABLED` and restarting/redeploying through the existing configuration flow; flag changes are not assumed to be hot-reloaded. Existing v2 history and source-linked answers remain readable because their wire and storage formats are unchanged. No database rollback is required for the first increment. Existing Deep Reader production rollout prerequisites still apply.

This task creates only this Markdown file. It does not enable features, modify source/configuration, change the competition document, invoke model providers, install packages, build applications or run mutating tests. No build, render or temporary extraction artifacts were generated, so no cleanup is required. The pre-existing untracked `competition_file/` directory is preserved.
