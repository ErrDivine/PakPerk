use chrono::{TimeDelta, Utc};
use db::Database;
use domain::{
    ArxivIdentifier, AssistantAnswerStyle, AssistantRequest, AssistantScope, AssistantScopeKind,
    Author, PaperMetadata, SectionKind, content_hash,
};
use url::Url;
use uuid::Uuid;

struct SectionSpec {
    kind: &'static str,
    heading: Option<&'static str>,
}

struct BlockSpec {
    kind: &'static str,
    section: usize,
    text: &'static str,
}

fn metadata(base_id: &str) -> PaperMetadata {
    let now = Utc::now();
    PaperMetadata {
        arxiv_id: ArxivIdentifier {
            base_id: base_id.to_owned(),
            version: 1,
        },
        title: "Retrieval fixture".to_owned(),
        abstract_text: "A retrieval integration fixture.".to_owned(),
        authors: vec![Author::from("Ada Tester".to_owned())],
        primary_category: "cs.CL".to_owned(),
        categories: vec!["cs.CL".to_owned()],
        published_at: now - TimeDelta::days(1),
        updated_at: now,
        abs_url: Url::parse(&format!("https://arxiv.org/abs/{base_id}v1")).unwrap(),
        pdf_url: Url::parse(&format!("https://arxiv.org/pdf/{base_id}v1")).unwrap(),
        doi: None,
        journal_reference: None,
        comment: None,
        license_uri: Some(Url::parse("https://creativecommons.org/licenses/by/4.0/").unwrap()),
        metadata_fetched_at: now,
    }
}

/// Inserts a paper with one document generation and returns its id and the
/// block ids in ordinal order.
async fn seed(
    database: &Database,
    sections: &[SectionSpec],
    blocks: &[BlockSpec],
) -> (Uuid, Vec<Uuid>) {
    let paper = database
        .papers()
        .upsert_metadata(&metadata(&format!("retrieval.{}", Uuid::now_v7().simple())))
        .await
        .unwrap();
    sqlx::query(
        r"
        INSERT INTO document_generations (
            paper_id, generation, arxiv_version, schema_version, parser_id,
            parser_version, document_hash, metadata_snapshot, metadata_hash,
            created_at, updated_at
        ) VALUES (
            $1, 1, 1, 'document.v1', 'grobid', 'retrieval-test-v1', $2,
            jsonb_build_object('schema_version', 'paper-metadata-v1'), $2, now(), now()
        )
        ",
    )
    .bind(paper.id)
    .bind("a".repeat(64))
    .execute(database.pool())
    .await
    .unwrap();
    let mut section_ids = Vec::new();
    for (ordinal, section) in sections.iter().enumerate() {
        let id = Uuid::now_v7();
        sqlx::query(
            r"
            INSERT INTO paper_sections (
                id, paper_id, generation, ordinal, kind, heading, text, visible_in_app
            ) VALUES ($1, $2, 1, $3, $4, $5, $6, true)
            ",
        )
        .bind(id)
        .bind(paper.id)
        .bind(i32::try_from(ordinal).unwrap())
        .bind(section.kind)
        .bind(section.heading)
        .bind(section.heading.unwrap_or("Section text."))
        .execute(database.pool())
        .await
        .unwrap();
        section_ids.push(id);
    }
    let mut block_ids = Vec::new();
    for (ordinal, block) in blocks.iter().enumerate() {
        let id = Uuid::now_v7();
        let path = sections[block.section].heading.map_or_else(
            || format!("{}-{}", sections[block.section].kind, block.section),
            str::to_owned,
        );
        sqlx::query(
            r"
            INSERT INTO document_blocks (
                id, paper_id, generation, stable_key, ordinal, section_id, section_path,
                kind, text, content_hash, page_start, page_end, inline_spans, created_at
            ) VALUES (
                $1, $2, 1, $3, $4, $5, ARRAY[$6], $7, $8, $9, 1, 1, '[]'::jsonb, now()
            )
            ",
        )
        .bind(id)
        .bind(paper.id)
        .bind(format!("block:{ordinal}"))
        .bind(i32::try_from(ordinal).unwrap())
        .bind(section_ids[block.section])
        .bind(path)
        .bind(block.kind)
        .bind(block.text)
        .bind(content_hash(block.text))
        .execute(database.pool())
        .await
        .unwrap();
        block_ids.push(id);
    }
    (paper.id, block_ids)
}

fn request(
    paper_id: Uuid,
    question: &str,
    kind: AssistantScopeKind,
    sections: &[SectionKind],
) -> AssistantRequest {
    AssistantRequest {
        paper_id,
        generation: 1,
        question: question.to_owned(),
        scope: AssistantScope {
            kind,
            section_kinds: sections.to_vec(),
            object_ids: vec![],
            selection: None,
            passport_field: None,
        },
        answer_style: AssistantAnswerStyle::Concise,
        thread_id: None,
    }
}

async fn retrieved(database: &Database, request: &AssistantRequest) -> Vec<Uuid> {
    database
        .assistant_context()
        .retrieve(request)
        .await
        .unwrap()
        .blocks
        .into_iter()
        .map(|block| block.block_id)
        .collect()
}

const CLAIM: &str =
    "We show that prompt tuning becomes competitive with model tuning as models grow larger.";
const COSTS: &str =
    "Large language models are costly to adapt separately for every downstream task.";
const PRIOR: &str =
    "Prior work tunes all parameters, which stores a full model copy for every task.";
const LATER: &str =
    "A fourth introduction paragraph that should not be needed for orientation at all.";
const BATCH: &str =
    "The batch size sweep found that 2^16 tokens per batch worked best in our experiments.";
const CONCLUSION: &str =
    "In this paper we showed that prompt tuning is a competitive alternative to model tuning.";
const URL_NOTE: &str = "https://example.org/data/glue";
const SWEEP_NOTE: &str =
    "To improve this baseline, we performed a sweep over the batch size hyperparameter.";

async fn database() -> Option<Database> {
    let Ok(url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL assistant retrieval coverage");
        return None;
    };
    let database = Database::connect(&url, 8).await.unwrap();
    database.migrate_embedded().await.unwrap();
    Some(database)
}

fn body_sections() -> Vec<SectionSpec> {
    vec![
        SectionSpec {
            kind: "introduction",
            heading: Some("Introduction"),
        },
        SectionSpec {
            kind: "result",
            heading: Some("Results"),
        },
        SectionSpec {
            kind: "conclusion",
            heading: Some("Conclusion"),
        },
        SectionSpec {
            kind: "other",
            heading: None,
        },
    ]
}

/// Footnotes after the body text, as the parser now emits them.
fn trailing_footnote_layout() -> Vec<BlockSpec> {
    vec![
        BlockSpec {
            kind: "heading",
            section: 0,
            text: "Introduction",
        },
        BlockSpec {
            kind: "paragraph",
            section: 0,
            text: CLAIM,
        },
        BlockSpec {
            kind: "paragraph",
            section: 0,
            text: COSTS,
        },
        BlockSpec {
            kind: "paragraph",
            section: 0,
            text: PRIOR,
        },
        BlockSpec {
            kind: "paragraph",
            section: 0,
            text: LATER,
        },
        BlockSpec {
            kind: "heading",
            section: 1,
            text: "Results",
        },
        BlockSpec {
            kind: "paragraph",
            section: 1,
            text: BATCH,
        },
        BlockSpec {
            kind: "heading",
            section: 2,
            text: "Conclusion",
        },
        BlockSpec {
            kind: "paragraph",
            section: 2,
            text: CONCLUSION,
        },
        BlockSpec {
            kind: "footnote",
            section: 3,
            text: URL_NOTE,
        },
        BlockSpec {
            kind: "footnote",
            section: 3,
            text: SWEEP_NOTE,
        },
    ]
}

#[tokio::test]
async fn a_question_that_shares_no_words_with_the_text_still_gets_the_openings_and_the_conclusion()
{
    let Some(database) = database().await else {
        return;
    };
    let (paper_id, ids) = seed(&database, &body_sections(), &trailing_footnote_layout()).await;

    let question = request(
        paper_id,
        "What is the main claim of this paper",
        AssistantScopeKind::Paper,
        &[],
    );
    let blocks = retrieved(&database, &question).await;

    // The opening of the introduction and the conclusion, in that order.
    assert_eq!(blocks, [ids[1], ids[2], ids[3], ids[8]]);
}

#[tokio::test]
async fn keyword_matches_come_first_and_footnotes_are_matched_but_never_pad() {
    let Some(database) = database().await else {
        return;
    };
    let (paper_id, ids) = seed(&database, &body_sections(), &trailing_footnote_layout()).await;

    let question = request(
        paper_id,
        "What batch size was used?",
        AssistantScopeKind::Paper,
        &[],
    );
    let blocks = retrieved(&database, &question).await;

    // Both blocks that mention batch size lead (a footnote may match by keyword).
    let leading = blocks[..2].to_vec();
    assert!(
        leading.contains(&ids[6]) && leading.contains(&ids[10]),
        "{blocks:?}"
    );
    // The URL footnote matches nothing and must not be used as padding.
    assert!(!blocks.contains(&ids[9]));
    // No heading-only block is ever returned as filler.
    assert!(!blocks.contains(&ids[0]) && !blocks.contains(&ids[5]) && !blocks.contains(&ids[7]));
    // Orientation follows the matches without duplicating them.
    assert!(blocks.contains(&ids[1]) && blocks.contains(&ids[8]));
    let mut unique = blocks.clone();
    unique.sort();
    unique.dedup();
    assert_eq!(unique.len(), blocks.len());
}

#[tokio::test]
async fn a_question_made_only_of_stop_words_falls_back_to_orientation() {
    let Some(database) = database().await else {
        return;
    };
    let (paper_id, ids) = seed(&database, &body_sections(), &trailing_footnote_layout()).await;

    let question = request(paper_id, "What is this?", AssistantScopeKind::Paper, &[]);
    assert_eq!(
        retrieved(&database, &question).await,
        [ids[1], ids[2], ids[3], ids[8]]
    );
}

#[tokio::test]
async fn section_scope_stays_inside_the_requested_sections() {
    let Some(database) = database().await else {
        return;
    };
    let (paper_id, ids) = seed(&database, &body_sections(), &trailing_footnote_layout()).await;

    let question = request(
        paper_id,
        "What batch size was used?",
        AssistantScopeKind::Section,
        &[SectionKind::Result],
    );
    assert_eq!(retrieved(&database, &question).await, [ids[6]]);

    let outside = request(
        paper_id,
        "What is the main claim of this paper",
        AssistantScopeKind::Section,
        &[SectionKind::Conclusion],
    );
    assert_eq!(retrieved(&database, &outside).await, [ids[8]]);
}

#[tokio::test]
async fn footnotes_stored_before_the_body_by_older_parses_do_not_become_the_opening() {
    let Some(database) = database().await else {
        return;
    };
    // Papers parsed before footnotes moved to the end carry them first, as
    // ordinary paragraphs of an unlabelled section.
    let sections = vec![
        SectionSpec {
            kind: "other",
            heading: None,
        },
        SectionSpec {
            kind: "introduction",
            heading: Some("Introduction"),
        },
        SectionSpec {
            kind: "conclusion",
            heading: Some("Conclusion"),
        },
    ];
    let blocks = vec![
        BlockSpec {
            kind: "paragraph",
            section: 0,
            text: SWEEP_NOTE,
        },
        BlockSpec {
            kind: "paragraph",
            section: 0,
            text: "The T5 SuperGLUE submission used a more complex setup, first mixing tasks.",
        },
        BlockSpec {
            kind: "paragraph",
            section: 0,
            text: URL_NOTE,
        },
        BlockSpec {
            kind: "heading",
            section: 1,
            text: "Introduction",
        },
        BlockSpec {
            kind: "paragraph",
            section: 1,
            text: CLAIM,
        },
        BlockSpec {
            kind: "paragraph",
            section: 1,
            text: COSTS,
        },
        BlockSpec {
            kind: "heading",
            section: 2,
            text: "Conclusion",
        },
        BlockSpec {
            kind: "paragraph",
            section: 2,
            text: CONCLUSION,
        },
    ];
    let (paper_id, ids) = seed(&database, &sections, &blocks).await;

    let question = request(
        paper_id,
        "What is the main claim of this paper",
        AssistantScopeKind::Paper,
        &[],
    );
    assert_eq!(
        retrieved(&database, &question).await,
        [ids[4], ids[5], ids[7]]
    );
}

#[tokio::test]
async fn a_paper_without_a_recognised_introduction_opens_with_its_first_prose() {
    let Some(database) = database().await else {
        return;
    };
    // GROBID sometimes loses the "1 Introduction" heading; that division is then
    // an unlabelled first section that must still be the opening.
    let sections = vec![
        SectionSpec {
            kind: "other",
            heading: None,
        },
        SectionSpec {
            kind: "method",
            heading: Some("Method"),
        },
    ];
    let blocks = vec![
        BlockSpec {
            kind: "paragraph",
            section: 0,
            text: CLAIM,
        },
        BlockSpec {
            kind: "paragraph",
            section: 0,
            text: COSTS,
        },
        BlockSpec {
            kind: "heading",
            section: 1,
            text: "Method",
        },
        BlockSpec {
            kind: "paragraph",
            section: 1,
            text: PRIOR,
        },
    ];
    let (paper_id, ids) = seed(&database, &sections, &blocks).await;

    let question = request(paper_id, "What is this?", AssistantScopeKind::Paper, &[]);
    assert_eq!(
        retrieved(&database, &question).await,
        [ids[0], ids[1], ids[3]]
    );
}

#[tokio::test]
async fn a_document_of_only_short_blocks_still_yields_evidence() {
    let Some(database) = database().await else {
        return;
    };
    let sections = vec![SectionSpec {
        kind: "other",
        heading: None,
    }];
    let blocks = vec![
        BlockSpec {
            kind: "paragraph",
            section: 0,
            text: "Short one.",
        },
        BlockSpec {
            kind: "paragraph",
            section: 0,
            text: "Short two.",
        },
    ];
    let (paper_id, ids) = seed(&database, &sections, &blocks).await;

    let question = request(
        paper_id,
        "Explain the experiment.",
        AssistantScopeKind::Paper,
        &[],
    );
    assert_eq!(retrieved(&database, &question).await, [ids[0], ids[1]]);
}

#[tokio::test]
async fn a_document_of_only_footnotes_and_headings_prefers_headings_then_footnotes() {
    let Some(database) = database().await else {
        return;
    };
    let sections = vec![
        SectionSpec {
            kind: "introduction",
            heading: Some("Introduction"),
        },
        SectionSpec {
            kind: "other",
            heading: None,
        },
    ];
    let blocks = vec![
        BlockSpec {
            kind: "heading",
            section: 0,
            text: "Introduction",
        },
        BlockSpec {
            kind: "footnote",
            section: 1,
            text: URL_NOTE,
        },
    ];
    let (paper_id, ids) = seed(&database, &sections, &blocks).await;

    let question = request(paper_id, "What is this?", AssistantScopeKind::Paper, &[]);
    assert_eq!(retrieved(&database, &question).await, [ids[0], ids[1]]);
}
