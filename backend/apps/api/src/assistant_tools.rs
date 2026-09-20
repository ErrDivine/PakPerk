//! Request-scoped, read-only tool orchestration. No model text is authority.

use std::collections::HashSet;

use db::{AssistantContextRepository, AssistantRetrievalContext, RetrievedAssistantBlock};
use domain::{AssistantRequest, AssistantScopeKind, AssistantTool, ChatTurn};
use llm_provider::{
    ASSISTANT_TOOL_MAX_CALLS_PER_ROUND, ASSISTANT_TOOL_MAX_ROUNDS, ASSISTANT_TOOL_RESULT_BYTES,
    AssistantCompletionRequest, AssistantProvider, AssistantTokenUsage, AssistantToolExchange,
    AssistantToolStepRequest, BlockEvidenceExcerpt, ProviderError,
};
use observability::{
    AssistantMetricOutcome, AssistantToolMetricKind, AssistantUsageAvailability,
    record_assistant_cost, record_assistant_tool,
};
use tokio::time::Instant;

const MAX_BLOCKS: usize = 10;
const FINAL_BLOCKS: usize = 8;

#[derive(Debug, thiserror::Error)]
pub(crate) enum ToolRunError {
    #[error(transparent)]
    Database(#[from] db::DbError),
    #[error(transparent)]
    Provider(#[from] ProviderError),
}

/// Drop records known usage even if a later provider/DB call fails or times out.
/// Missing calls remain unavailable; known counts are never called a full total.
#[derive(Default)]
pub(crate) struct ToolUsage {
    attempts: u64,
    reported: u64,
    input: u64,
    output: u64,
}

impl ToolUsage {
    pub(crate) fn begin_call(&mut self) {
        self.attempts += 1;
    }
    pub(crate) fn report(&mut self, usage: Option<AssistantTokenUsage>) {
        if let Some(usage) = usage {
            self.reported += 1;
            self.input = self.input.saturating_add(usage.input_tokens);
            self.output = self.output.saturating_add(usage.output_tokens);
        }
    }
}

impl Drop for ToolUsage {
    fn drop(&mut self) {
        if self.attempts > 0 {
            record_assistant_cost(
                if self.attempts == self.reported {
                    AssistantUsageAvailability::Reported
                } else {
                    AssistantUsageAvailability::Unavailable
                },
                (self.reported > 0).then_some((self.input, self.output)),
            );
        }
    }
}

pub(crate) fn completion_request(
    request: &AssistantRequest,
    context: &AssistantRetrievalContext,
    recent_turns: Vec<ChatTurn>,
) -> AssistantCompletionRequest {
    AssistantCompletionRequest {
        paper_title: context.paper_title.clone(),
        request: request.clone(),
        recent_turns,
        evidence: context
            .blocks
            .iter()
            .map(|block| BlockEvidenceExcerpt {
                block_id: block.block_id,
                paper_id: block.paper_id,
                generation: block.generation,
                section_heading: block.section_heading.clone(),
                page_start: block.page_start,
                text: block.text.clone(),
            })
            .collect(),
    }
}

#[allow(clippy::too_many_lines)]
pub(crate) async fn gather<P: AssistantProvider + ?Sized>(
    provider: &P,
    repository: &AssistantContextRepository,
    request: &AssistantRequest,
    context: &mut AssistantRetrievalContext,
    history: Vec<ChatTurn>,
    usage: &mut ToolUsage,
) -> Result<(), ToolRunError> {
    let mut evidence = EvidenceRegistry::new(request, context)?;
    context.blocks = evidence
        .blocks
        .iter()
        .map(|entry| entry.0.clone())
        .collect();
    let mut step_request = AssistantToolStepRequest {
        completion: completion_request(request, context, history),
        outline: repository.outline(request).await?,
        exchanges: vec![],
    };
    let mut seen = HashSet::new();
    let mut result_bytes = 0usize;
    for _ in 0..ASSISTANT_TOOL_MAX_ROUNDS {
        usage.begin_call();
        let step = provider.select_assistant_tools(&step_request).await?;
        usage.report(step.token_usage);
        if step.calls.len() > ASSISTANT_TOOL_MAX_CALLS_PER_ROUND {
            return Err(invalid_output().into());
        }
        // Validate the entire batch before executing anything, including doubles.
        let operations = step
            .calls
            .iter()
            .map(|call| {
                if !seen.insert(call.id.clone()) {
                    return Err(invalid_output());
                }
                call.operation()
            })
            .collect::<Result<Vec<_>, _>>()?;
        if operations.is_empty() {
            break;
        }
        let mut results = Vec::new();
        for operation in operations {
            let started = Instant::now();
            let result = repository.execute_tool(request, &operation).await;
            let kind = match operation {
                AssistantTool::SearchPaperEvidence(_) => AssistantToolMetricKind::Search,
                AssistantTool::GetPaperOutline(_) => AssistantToolMetricKind::Outline,
                AssistantTool::ReadPaperBlocks(_) | AssistantTool::ReadPaperRange(_) => {
                    AssistantToolMetricKind::Read
                }
                AssistantTool::GetObjectEvidence(_) => AssistantToolMetricKind::Object,
                AssistantTool::GetCitationContext(_) => AssistantToolMetricKind::Citation,
            };
            let outcome = match &result {
                Ok(value) if value.sources.is_empty() => AssistantMetricOutcome::NotFound,
                Ok(_) => AssistantMetricOutcome::Success,
                Err(db::DbError::AssistantContextNotReady) => {
                    AssistantMetricOutcome::ContextNotReady
                }
                Err(db::DbError::InvalidData(_)) => AssistantMetricOutcome::RejectedRequest,
                Err(_) => AssistantMetricOutcome::Failure,
            };
            record_assistant_tool(
                kind,
                outcome,
                started.elapsed(),
                result
                    .as_ref()
                    .map_or(0, |value| value.sources.len() as u64),
            );
            tracing::info!(
                metric.name = "assistant_tool",
                tool.name = operation.name(),
                tool.outcome = if result.is_ok() {
                    "completed"
                } else {
                    "rejected_or_failed"
                },
                tool.latency_ms = started.elapsed().as_millis(),
                "bounded assistant tool completed"
            );
            let mut result = result?;
            if !matches!(operation, AssistantTool::GetPaperOutline(_)) {
                let priority = if matches!(operation, AssistantTool::SearchPaperEvidence(_)) {
                    1
                } else {
                    2
                };
                for source in &mut result.sources {
                    if let Some(text) = &source.text {
                        let admitted = evidence.admit(
                            RetrievedAssistantBlock {
                                block_id: source.block_id,
                                paper_id: source.paper_id,
                                generation: source.generation,
                                section_heading: source.section_heading.clone(),
                                page_start: source.page_start,
                                text: text.clone(),
                            },
                            priority,
                        )?;
                        if !admitted {
                            source.text = None;
                            result.truncated = true;
                            result.status = "evidence_budget_exhausted";
                        }
                    }
                }
            }
            let serialized = serde_json::to_string(&result).map_err(|_| invalid_output())?;
            result_bytes = result_bytes
                .checked_add(serialized.len())
                .ok_or_else(invalid_output)?;
            if result_bytes > ASSISTANT_TOOL_RESULT_BYTES {
                return Err(invalid_output().into());
            }
            results.push(serialized);
        }
        step_request.exchanges.push(AssistantToolExchange {
            calls: step.calls,
            results,
        });
    }
    context.blocks = evidence.finish();
    Ok(())
}

struct EvidenceRegistry {
    paper_id: uuid::Uuid,
    generation: i32,
    blocks: Vec<(RetrievedAssistantBlock, u8)>,
}

impl EvidenceRegistry {
    fn new(
        request: &AssistantRequest,
        context: &AssistantRetrievalContext,
    ) -> Result<Self, ProviderError> {
        let mut registry = Self {
            paper_id: request.paper_id,
            generation: request.generation,
            blocks: vec![],
        };
        let mandatory = !matches!(
            request.scope.kind,
            AssistantScopeKind::Paper | AssistantScopeKind::Section
        );
        for block in context
            .blocks
            .iter()
            .take(if mandatory { FINAL_BLOCKS } else { 4 })
        {
            registry.admit(block.clone(), if mandatory { 3 } else { 0 })?;
        }
        if registry.blocks.is_empty() {
            return Err(invalid_output());
        }
        Ok(registry)
    }

    fn admit(
        &mut self,
        block: RetrievedAssistantBlock,
        priority: u8,
    ) -> Result<bool, ProviderError> {
        if block.paper_id != self.paper_id
            || block.generation != self.generation
            || block.text.trim().is_empty()
            || block.text.chars().count() > 20_000
        {
            return Err(invalid_output());
        }
        if let Some((existing, rank)) = self
            .blocks
            .iter_mut()
            .find(|(existing, _)| existing.block_id == block.block_id)
        {
            if existing.text != block.text
                || existing.section_heading != block.section_heading
                || existing.page_start != block.page_start
            {
                return Err(invalid_output());
            }
            *rank = (*rank).max(priority);
            return Ok(true);
        }
        if self.blocks.len() >= MAX_BLOCKS {
            return Ok(false);
        }
        self.blocks.push((block, priority));
        Ok(true)
    }

    fn finish(mut self) -> Vec<RetrievedAssistantBlock> {
        // Stable sort preserves repository order among equal priorities.
        self.blocks
            .sort_by_key(|(_, priority)| std::cmp::Reverse(*priority));
        let mut total = 0usize;
        self.blocks
            .into_iter()
            .filter_map(|(block, _)| {
                let length = block.text.chars().count();
                if total + length > 100_000 {
                    return None;
                }
                total += length;
                Some(block)
            })
            .take(FINAL_BLOCKS)
            .collect()
    }
}

fn invalid_output() -> ProviderError {
    ProviderError::InvalidResponse("assistant tool evidence or budget is invalid".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use domain::{AssistantAnswerStyle, AssistantScope};
    use uuid::Uuid;

    fn fixture() -> (AssistantRequest, AssistantRetrievalContext) {
        let paper_id = Uuid::now_v7();
        let request = AssistantRequest {
            paper_id,
            generation: 1,
            question: "What is supported?".into(),
            scope: AssistantScope {
                kind: AssistantScopeKind::Paper,
                section_kinds: vec![],
                object_ids: vec![],
                selection: None,
                passport_field: None,
            },
            answer_style: AssistantAnswerStyle::Concise,
            thread_id: None,
        };
        let context = AssistantRetrievalContext {
            paper_title: "Fixture".into(),
            parser_id: "grobid".into(),
            parser_version: "fixture".into(),
            blocks: (0..4)
                .map(|_| RetrievedAssistantBlock {
                    block_id: Uuid::now_v7(),
                    paper_id,
                    generation: 1,
                    text: "Initial evidence.".into(),
                    section_heading: None,
                    page_start: None,
                })
                .collect(),
        };
        (request, context)
    }

    #[test]
    fn newly_read_evidence_wins_without_exceeding_final_or_cumulative_budget() {
        let (request, context) = fixture();
        let mut registry = EvidenceRegistry::new(&request, &context).unwrap();
        let mut last = context.blocks[0].clone();
        for _ in 0..6 {
            last.block_id = Uuid::now_v7();
            assert!(registry.admit(last.clone(), 2).unwrap());
        }
        let expected = last.block_id;
        last.block_id = Uuid::now_v7();
        assert!(!registry.admit(last, 2).unwrap());
        let final_blocks = registry.finish();
        assert_eq!(final_blocks.len(), FINAL_BLOCKS);
        assert!(final_blocks.iter().any(|block| block.block_id == expected));
        // Every block the model read outranks every initial block: the initial
        // ones only fill the slots that remain (the cumulative cap left room for
        // six new blocks next to the four seeds).
        let is_seed = |block: &RetrievedAssistantBlock| {
            context
                .blocks
                .iter()
                .any(|seed| seed.block_id == block.block_id)
        };
        assert!(final_blocks[..6].iter().all(|block| !is_seed(block)));
        assert_eq!(
            final_blocks.iter().filter(|block| is_seed(block)).count(),
            FINAL_BLOCKS - 6
        );
    }

    #[test]
    fn registry_rejects_forged_scope_and_changed_source_for_same_identifier() {
        let (request, context) = fixture();
        for changed in 0..4 {
            let mut registry = EvidenceRegistry::new(&request, &context).unwrap();
            let mut block = context.blocks[0].clone();
            match changed {
                0 => block.paper_id = Uuid::now_v7(),
                1 => block.generation = 2,
                2 => block.text = "Changed text".into(),
                _ => block.page_start = Some(999),
            }
            assert!(registry.admit(block, 2).is_err());
        }
    }

    #[test]
    fn selected_block_stays_ahead_of_additional_evidence_and_is_not_truncated() {
        let (mut request, mut context) = fixture();
        context.blocks.truncate(1);
        context.blocks[0].text = "界🙂".repeat(10_000);
        request.scope.kind = AssistantScopeKind::Selection;
        let mut registry = EvidenceRegistry::new(&request, &context).unwrap();
        for _ in 0..8 {
            let mut block = context.blocks[0].clone();
            block.block_id = Uuid::now_v7();
            registry.admit(block, 2).unwrap();
        }
        let blocks = registry.finish();
        assert_eq!(blocks[0].block_id, context.blocks[0].block_id);
        assert_eq!(blocks.len(), 5);
        assert_eq!(blocks[0].text, context.blocks[0].text);
    }

    #[test]
    fn usage_preserves_known_cost_but_does_not_label_missing_calls_as_complete() {
        let mut usage = ToolUsage::default();
        usage.begin_call();
        usage.report(Some(AssistantTokenUsage {
            input_tokens: 12,
            output_tokens: 4,
        }));
        usage.begin_call();
        usage.report(None);
        usage.begin_call();
        usage.report(Some(AssistantTokenUsage {
            input_tokens: 20,
            output_tokens: 5,
        }));
        assert_eq!((usage.input, usage.output), (32, 9));
        assert_eq!((usage.attempts, usage.reported), (3, 2));
    }
}
