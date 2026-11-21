//! Live smoke test for an OpenAI-compatible assistant endpoint. Ignored by
//! default; it calls a real model. Configure it with:
//!
//! - `LIVE_LLM_BASE_URL` (or `LIVE_LLM_PROXY_URL`, which wins), e.g. `https://host/v1`
//! - `LIVE_LLM_MODEL`
//! - `LIVE_LLM_API_KEY`
//! - `LIVE_LLM_THINKING` (optional: default, enabled, disabled)
//! - `LIVE_LLM_ATTEMPTS` (optional, attempts per answerable question, default 3)
//!
//! It drives the same assistant-only provider the API builds from
//! `ASSISTANT_LLM_*`, against a synthetic paper, and reports whether each answer
//! passes the evidence validation (exact character ranges into the source
//! blocks).

use std::time::{Duration, Instant};

use domain::{
    AssistantAnswerStatus, AssistantRequest, AssistantScope, AssistantScopeKind, AssistantAnswerStyle,
};
use llm_provider::{
    AssistantCompletionRequest, AssistantProvider, BlockEvidenceExcerpt, OpenAiCompatibleConfig,
    OpenAiCompatibleProvider, ThinkingMode,
};
use secrecy::SecretString;
use url::Url;
use uuid::Uuid;

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.trim().is_empty())
}

fn evidence(paper_id: Uuid, heading: &str, page: u32, text: &str) -> BlockEvidenceExcerpt {
    BlockEvidenceExcerpt {
        block_id: Uuid::new_v4(),
        paper_id,
        generation: 1,
        section_heading: Some(heading.to_owned()),
        page_start: Some(page),
        text: text.to_owned(),
    }
}

fn request(
    paper_id: Uuid,
    question: &str,
    blocks: &[BlockEvidenceExcerpt],
) -> AssistantCompletionRequest {
    AssistantCompletionRequest {
        paper_title: "Low-Rank Adaptation of Large Language Models (test excerpt)".into(),
        request: AssistantRequest {
            paper_id,
            generation: 1,
            question: question.to_owned(),
            scope: AssistantScope {
                kind: AssistantScopeKind::Paper,
                section_kinds: vec![],
                object_ids: vec![],
                selection: None,
                passport_field: None,
            },
            answer_style: AssistantAnswerStyle::Concise,
            thread_id: None,
        },
        recent_turns: vec![],
        evidence: blocks.to_vec(),
    }
}

#[tokio::test]
#[ignore = "calls a live model endpoint; set LIVE_LLM_* and run with --ignored"]
async fn live_assistant_answers_pass_evidence_validation() {
    let base = env("LIVE_LLM_PROXY_URL")
        .or_else(|| env("LIVE_LLM_BASE_URL"))
        .expect("set LIVE_LLM_BASE_URL");
    let mut config = OpenAiCompatibleConfig::default();
    config.base_url = Url::parse(&base).expect("LIVE_LLM_BASE_URL must be a URL");
    config.api_key = Some(SecretString::from(
        env("LIVE_LLM_API_KEY").expect("set LIVE_LLM_API_KEY"),
    ));
    config.chat_model = env("LIVE_LLM_MODEL").expect("set LIVE_LLM_MODEL");
    config.thinking = env("LIVE_LLM_THINKING")
        .map(|value| value.parse::<ThinkingMode>().expect("LIVE_LLM_THINKING"))
        .unwrap_or_default();
    config.request_timeout = Duration::from_secs(180);
    config.maximum_retries = 0;
    let attempts = env("LIVE_LLM_ATTEMPTS")
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(3);
    println!(
        "model={} thinking={:?} attempts_per_answerable_question={attempts}",
        config.chat_model, config.thinking
    );
    let provider = OpenAiCompatibleProvider::new_assistant_only(config).expect("provider config");

    let paper_id = Uuid::new_v4();
    let blocks = vec![
        evidence(
            paper_id,
            "Abstract",
            1,
            "LoRA freezes the pretrained model weights and injects trainable rank decomposition \
             matrices into each layer of the Transformer architecture, which greatly reduces the \
             number of trainable parameters for downstream tasks.",
        ),
        evidence(
            paper_id,
            "Abstract",
            1,
            "Compared with fine-tuning GPT-3 175B with Adam, LoRA can reduce the number of \
             trainable parameters by 10,000 times and the GPU memory requirement by 3 times.",
        ),
        evidence(
            paper_id,
            "Introduction",
            2,
            "Unlike adapter layers, LoRA adds no additional inference latency because the \
             trainable matrices can be merged with the frozen weights when deployed.",
        ),
        evidence(
            paper_id,
            "Method",
            4,
            "For a pretrained weight matrix W0, the update is constrained by representing it as a \
             low-rank decomposition W0 + BA, where B and A are trainable and only the rank r is a \
             hyperparameter.",
        ),
    ];
    // (question, answerable from the blocks?)
    let questions = [
        ("What does LoRA freeze, and what does it train instead?", true),
        (
            "By how much does LoRA reduce trainable parameters and GPU memory?",
            true,
        ),
        (
            "Which learning rate was used for the RoBERTa experiments?",
            false,
        ),
    ];

    let (mut passed, mut total) = (0_usize, 0_usize);
    for (question, answerable) in questions {
        let tries = if answerable { attempts } else { 1 };
        println!("\nQ: {question}  (answerable: {answerable})");
        for attempt in 1..=tries {
            total += 1;
            let started = Instant::now();
            let outcome = provider
                .answer_with_evidence(&request(paper_id, question, &blocks))
                .await;
            let seconds = started.elapsed().as_secs_f32();
            match outcome {
                Ok(completion) => {
                    let answer = completion.answer;
                    let status_ok = if answerable {
                        answer.status != AssistantAnswerStatus::NotFound
                    } else {
                        answer.status == AssistantAnswerStatus::NotFound
                    };
                    if status_ok {
                        passed += 1;
                    }
                    println!(
                        "  #{attempt} {seconds:.1}s VALID status={:?} claims={} tokens={:?} status_as_expected={status_ok}",
                        answer.status,
                        answer.claims.len(),
                        completion
                            .token_usage
                            .map(|usage| (usage.input_tokens, usage.output_tokens)),
                    );
                    println!("     answer: {}", answer.answer.replace('\n', " "));
                    for claim in &answer.claims {
                        let spans = claim
                            .evidence
                            .iter()
                            .map(|reference| {
                                let index = blocks
                                    .iter()
                                    .position(|block| block.block_id == reference.block_id)
                                    .map_or_else(|| "?".to_owned(), |index| format!("B{}", index + 1));
                                format!("{index}[{}..{}]", reference.start, reference.end)
                            })
                            .collect::<Vec<_>>()
                            .join(", ");
                        println!("     claim ({:?}) evidence {spans}", claim.support);
                    }
                }
                Err(error) => {
                    println!("  #{attempt} {seconds:.1}s REJECTED: {error}");
                    println!("     debug: {error:?}");
                }
            }
        }
    }
    println!("\nRESULT: {passed}/{total} attempts were valid and matched the expected status");
    assert!(passed > 0, "no attempt passed");
}

/// Replays exchanges recorded by the local proxy (`LIVE_LLM_REPLAY=<jsonl>`)
/// through the validator without any network access or key.
#[test]
#[ignore = "replays recorded exchanges; set LIVE_LLM_REPLAY"]
fn replay_recorded_exchanges_through_the_validator() {
    let path = env("LIVE_LLM_REPLAY").expect("set LIVE_LLM_REPLAY");
    let text = std::fs::read_to_string(path).expect("readable replay file");
    let (mut valid, mut total) = (0_usize, 0_usize);
    for (index, line) in text.lines().enumerate() {
        let record: serde_json::Value = serde_json::from_str(line).expect("jsonl record");
        let user = record["request"]["messages"][1]["content"]
            .as_str()
            .expect("user message");
        let question = user
            .strip_prefix("Question:\n")
            .and_then(|rest| rest.split("\n\n").next())
            .expect("question");
        let begin = user.find("_BEGIN\n").expect("data begin") + "_BEGIN\n".len();
        let end = user.rfind("\nPAKPERK_DATA_").expect("data end");
        let data: serde_json::Value = serde_json::from_str(&user[begin..end]).expect("data json");
        let paper_id: Uuid = data["paper_id"].as_str().unwrap().parse().unwrap();
        let blocks = data["blocks"]
            .as_array()
            .unwrap()
            .iter()
            .map(|block| BlockEvidenceExcerpt {
                block_id: block["block_id"].as_str().unwrap().parse().unwrap(),
                paper_id,
                generation: 1,
                section_heading: block["section_heading"].as_str().map(str::to_owned),
                page_start: block["page_start"].as_u64().map(|page| page as u32),
                text: block["text"].as_str().unwrap().to_owned(),
            })
            .collect::<Vec<_>>();
        let completion = request(paper_id, question, &blocks);
        let envelope: serde_json::Value =
            serde_json::from_str(record["response"].as_str().unwrap()).expect("envelope");
        let content = envelope["choices"][0]["message"]["content"]
            .as_str()
            .unwrap_or("");
        total += 1;
        match llm_provider::validate_assistant_output(content, &completion, Uuid::new_v4(), None, None)
        {
            Ok(answer) => {
                valid += 1;
                println!(
                    "#{} VALID status={:?} claims={} | {question}",
                    index + 1,
                    answer.status,
                    answer.claims.len()
                );
                println!("     answer: {}", answer.answer.replace('\n', " "));
            }
            Err(error) => println!("#{} REJECTED: {error} | {question}", index + 1),
        }
    }
    println!("\nREPLAY: {valid}/{total} recorded responses pass the validator");
}
