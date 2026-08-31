use base64::{Engine as _, engine::general_purpose::STANDARD};
use chrono::{TimeDelta, Utc};
use db::{Database, DbError, DocumentBlockQuery, DocumentPersistOutcome, VersionDiffSourceSide};
use domain::{
    ArxivIdentifier, Author, DOCUMENT_SCHEMA_VERSION, DefinitionConfidenceStatus,
    DefinitionSourceType, DefinitionStatus, DocumentBlock, DocumentBlockKind, DocumentEquation,
    DocumentFigure, DocumentTable, DocumentTerm, EquationConfidenceStatus, FigureExtractionStatus,
    InlineSpan, InlineSpanKind, IntroductionDetection, NormalizedDocument, PaperMetadata,
    ParsedPaper, ParsedParagraph, ParsedSection, SectionKind, SourceLocator,
    TABLE_STRUCTURE_SCHEMA_VERSION, TableCell, TableExtractionStatus, TableStructure,
    TermDefinition, TermKind, TermOccurrence, VersionDiffItemKind, content_hash, normalize_term,
    stable_block_key,
};
use url::Url;
use uuid::Uuid;

#[tokio::test]
#[allow(clippy::too_many_lines)]
async fn postgres_document_reader_is_dual_write_and_generation_safe() {
    let Ok(database_url) = std::env::var("TEST_DATABASE_URL") else {
        eprintln!("TEST_DATABASE_URL is absent; skipped PostgreSQL document-reader coverage");
        return;
    };
    let database = Database::connect(&database_url, 8)
        .await
        .unwrap()
        .with_cursor_codec(test_cursor_codec());
    database.migrate_embedded().await.unwrap();

    let unique = Uuid::now_v7().simple().to_string();
    let base_id = format!("document.{unique}");
    let now = Utc::now();
    let papers = database.papers();
    let paper = papers
        .upsert_metadata(&metadata(&base_id, 1, now))
        .await
        .unwrap();

    papers
        .persist_parsed_document(
            paper.id,
            1,
            &legacy_document(),
            &["introduction".to_owned()],
            IntroductionDetection {
                confidence: 0.99,
                used_fallback: false,
            },
            "grobid-integration-v1",
        )
        .await
        .unwrap();

    let document = normalized_document(paper.id, 1);
    let repository = database.documents();
    let mut unverified_version = document.clone();
    unverified_version.arxiv_version = 2;
    assert!(matches!(
        repository.persist_document(&unverified_version).await,
        Err(DbError::StaleGeneration)
    ));
    let unpublished_manifests: i64 =
        sqlx::query_scalar("SELECT count(*) FROM document_generations WHERE paper_id = $1")
            .bind(paper.id)
            .fetch_one(database.pool())
            .await
            .unwrap();
    assert_eq!(unpublished_manifests, 0);
    assert_eq!(
        repository.persist_document(&document).await.unwrap(),
        DocumentPersistOutcome::Inserted
    );
    assert_eq!(
        repository.persist_document(&document).await.unwrap(),
        DocumentPersistOutcome::Unchanged
    );
    assert!(papers.introduction(paper.id).await.unwrap().is_some());

    let linked_blocks: i64 = sqlx::query_scalar(
        r"
        SELECT count(*)
        FROM document_blocks AS block
        JOIN paper_sections AS section ON section.id = block.section_id
        WHERE block.paper_id = $1
          AND block.generation = 1
          AND section.paper_id = block.paper_id
          AND section.generation = block.generation
        ",
    )
    .bind(paper.id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(linked_blocks, 3);

    let outline = repository.outline(paper.id).await.unwrap().unwrap();
    assert_eq!(outline.generation, 1);
    assert_eq!(outline.provenance.arxiv_version, 1);
    assert_eq!(outline.provenance.parser_id, "grobid");
    assert_eq!(outline.value.len(), 1);
    assert_eq!(outline.value[0].heading, "1 Introduction");

    let first_page = repository
        .blocks(
            paper.id,
            DocumentBlockQuery {
                cursor: None,
                section: Some("  1 Introduction  ".to_owned()),
                limit: 1,
            },
        )
        .await
        .unwrap()
        .unwrap();
    assert_eq!(first_page.value.items.len(), 1);
    assert_eq!(first_page.value.items[0].ordinal, 0);
    let first_cursor = first_page.value.next_cursor.unwrap();
    let second_page = repository
        .blocks(
            paper.id,
            DocumentBlockQuery {
                cursor: Some(first_cursor.clone()),
                section: Some("1 Introduction".to_owned()),
                limit: 1,
            },
        )
        .await
        .unwrap()
        .unwrap();
    assert_eq!(second_page.value.items[0].ordinal, 1);
    assert!(matches!(
        repository
            .blocks(
                paper.id,
                DocumentBlockQuery {
                    cursor: Some(first_cursor),
                    section: Some("Methods".to_owned()),
                    limit: 1,
                },
            )
            .await,
        Err(DbError::Cursor(_))
    ));

    let figures = repository.figures(paper.id).await.unwrap().unwrap();
    assert_eq!(figures.value.len(), 1);
    assert_eq!(
        repository
            .figure(paper.id, document.figures[0].id)
            .await
            .unwrap()
            .unwrap()
            .value
            .unwrap()
            .asset_key
            .as_deref(),
        Some("papers/fixture/figure-1.webp")
    );
    let mut generated_figure = figures.value[0].clone();
    generated_figure.asset_key = Some(format!(
        "generated/{}/g1/{}/set-{}/large.png",
        paper.id,
        generated_figure.id,
        "a".repeat(64)
    ));
    generated_figure.width = Some(1_200);
    generated_figure.height = Some(600);
    generated_figure.extraction_status = FigureExtractionStatus::Ready;
    repository
        .publish_figure_asset_state(&generated_figure)
        .await
        .unwrap();
    let published = repository
        .figure(paper.id, generated_figure.id)
        .await
        .unwrap()
        .unwrap()
        .value
        .unwrap();
    assert_eq!(published.asset_key, generated_figure.asset_key);
    assert_eq!(
        (published.width, published.height),
        (Some(1_200), Some(600))
    );

    let mut caption_only = generated_figure.clone();
    caption_only.asset_key = None;
    caption_only.width = None;
    caption_only.height = None;
    caption_only.extraction_status = FigureExtractionStatus::CaptionOnly;
    repository
        .publish_figure_asset_state(&caption_only)
        .await
        .unwrap();
    let cleared = repository
        .figure(paper.id, caption_only.id)
        .await
        .unwrap()
        .unwrap()
        .value
        .unwrap();
    assert_eq!(cleared.asset_key, None);
    assert_eq!((cleared.width, cleared.height), (None, None));
    assert_eq!(
        cleared.extraction_status,
        FigureExtractionStatus::CaptionOnly
    );
    assert_eq!(
        repository
            .tables(paper.id)
            .await
            .unwrap()
            .unwrap()
            .value
            .len(),
        1
    );
    let visual_references = repository
        .visual_object_references(
            paper.id,
            &[
                document.figures[0].id,
                document.tables[0].id,
                document.equations[0].id,
            ],
        )
        .await
        .unwrap()
        .unwrap();
    assert_eq!(visual_references.generation, 1);
    assert_eq!(visual_references.value.len(), 3);
    for reference in &visual_references.value {
        assert_eq!(reference.block_id, document.blocks[2].id);
        assert!(
            reference
                .context
                .contains(reference.marker.as_deref().unwrap())
        );
        assert_eq!(reference.page_number, Some(1));
    }
    assert_eq!(
        repository
            .table(paper.id, document.tables[0].id)
            .await
            .unwrap()
            .unwrap()
            .value
            .unwrap()
            .plain_text,
        "Metric | Value\nAccuracy | 0.95"
    );
    assert_eq!(
        repository
            .equations(paper.id)
            .await
            .unwrap()
            .unwrap()
            .value
            .len(),
        1
    );
    let terms = repository
        .terms(paper.id, Some(document.blocks[1].id))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(terms.value.len(), 1);
    assert_eq!(terms.value[0].occurrences[0].start_offset, 4);
    assert_eq!(terms.value[0].occurrences[0].end_offset, 13);
    assert_eq!(terms.value[0].definitions.len(), 1);

    // The compatibility writer replaces its legacy sections. Cascades remove
    // linked blocks, so publication must detect the incomplete manifest and
    // republish rather than treating the identical document hash as a no-op.
    papers
        .persist_parsed_document(
            paper.id,
            1,
            &legacy_document(),
            &["introduction".to_owned()],
            IntroductionDetection {
                confidence: 0.99,
                used_fallback: false,
            },
            "grobid-integration-v1",
        )
        .await
        .unwrap();
    assert_eq!(
        repository.persist_document(&document).await.unwrap(),
        DocumentPersistOutcome::Replaced
    );
    assert_eq!(
        repository
            .blocks(paper.id, DocumentBlockQuery::default())
            .await
            .unwrap()
            .unwrap()
            .value
            .items
            .len(),
        3
    );

    let mut version_two = metadata(&base_id, 2, now + TimeDelta::seconds(1));
    version_two.published_at = now - TimeDelta::days(1);
    papers.upsert_metadata(&version_two).await.unwrap();
    assert!(repository.provenance(paper.id).await.unwrap().is_none());
    let superseded_shared_artifacts: (i64, i64, i64, i64) = sqlx::query_as(
        r"
        SELECT
            (SELECT count(*) FROM paper_figures
             WHERE paper_id = $1 AND generation = 1 AND superseded_at IS NOT NULL),
            (SELECT count(*) FROM paper_tables
             WHERE paper_id = $1 AND generation = 1 AND superseded_at IS NOT NULL),
            (SELECT count(*) FROM paper_equations
             WHERE paper_id = $1 AND generation = 1 AND superseded_at IS NOT NULL),
            (SELECT count(*) FROM paper_terms
             WHERE paper_id = $1 AND generation = 1 AND superseded_at IS NOT NULL)
        ",
    )
    .bind(paper.id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(
        superseded_shared_artifacts,
        (1, 1, 1, 1),
        "a version transition must supersede every old shared enrichment"
    );
    assert!(matches!(
        repository.persist_document(&document).await,
        Err(DbError::StaleGeneration)
    ));
    assert!(matches!(
        repository
            .publish_figure_asset_state(&generated_figure)
            .await,
        Err(DbError::StaleGeneration)
    ));
    let retained_generation_one: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM document_blocks WHERE paper_id = $1 AND generation = 1",
    )
    .bind(paper.id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    assert_eq!(retained_generation_one, 3);

    papers
        .persist_parsed_document(
            paper.id,
            2,
            &legacy_document(),
            &["introduction".to_owned()],
            IntroductionDetection {
                confidence: 0.99,
                used_fallback: false,
            },
            "grobid-integration-v1",
        )
        .await
        .unwrap();
    let mut document_two = normalized_document(paper.id, 2);
    document_two.arxiv_version = 2;
    document_two.blocks[1].text = "The β-catenin method works better.".to_owned();
    document_two.blocks[1].content_hash = content_hash(&document_two.blocks[1].text);
    document_two.figures[0].content_hash = content_hash("fixture-figure-binary-v2");
    repository.persist_document(&document_two).await.unwrap();

    let version_repository = database.version_diffs();
    let first_diff = version_repository
        .compare_and_persist(paper.id, 1, 2)
        .await
        .unwrap();
    for expected in [
        VersionDiffItemKind::Metadata,
        VersionDiffItemKind::Block,
        VersionDiffItemKind::Figure,
    ] {
        assert!(first_diff.items.iter().any(|item| item.kind == expected));
    }
    let first_ids = first_diff
        .items
        .iter()
        .map(|item| item.id)
        .collect::<Vec<_>>();
    let repeated = version_repository
        .compare_and_persist(paper.id, 1, 2)
        .await
        .unwrap();
    assert_eq!(
        repeated
            .items
            .iter()
            .map(|item| item.id)
            .collect::<Vec<_>>(),
        first_ids
    );
    let source_targets = version_repository
        .source_targets(repeated.id)
        .await
        .unwrap();
    let modified_block = repeated
        .items
        .iter()
        .find(|item| item.kind == VersionDiffItemKind::Block)
        .unwrap();
    let block_targets = source_targets
        .iter()
        .filter(|target| target.diff_item_id == modified_block.id)
        .collect::<Vec<_>>();
    assert_eq!(block_targets.len(), 2);
    assert!(block_targets.iter().any(|target| {
        target.side == VersionDiffSourceSide::Old
            && target.generation == 1
            && target.object_id == modified_block.old_object_id.unwrap()
            && target.page_start == Some(1)
            && target
                .source_locator
                .as_ref()
                .and_then(|value| value.page_number)
                == Some(1)
    }));
    assert!(block_targets.iter().any(|target| {
        target.side == VersionDiffSourceSide::New
            && target.generation == 2
            && target.object_id == modified_block.new_object_id.unwrap()
            && target.page_start == Some(1)
            && target
                .source_locator
                .as_ref()
                .and_then(|value| value.page_number)
                == Some(1)
    }));

    // Section rows do not persist their own structured source locator. The
    // navigation resolver must derive one from the earliest located block in
    // the exact retained paper/generation/section scope.
    let old_section_id: Uuid = sqlx::query_scalar(
        "SELECT id FROM paper_sections WHERE paper_id = $1 AND generation = 1 ORDER BY ordinal LIMIT 1",
    )
    .bind(paper.id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    let new_section_id: Uuid = sqlx::query_scalar(
        "SELECT id FROM paper_sections WHERE paper_id = $1 AND generation = 2 ORDER BY ordinal LIMIT 1",
    )
    .bind(paper.id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    let section_item_id = Uuid::now_v7();
    let section_ordinal: i32 = sqlx::query_scalar(
        "SELECT COALESCE(max(ordinal), -1) + 1 FROM paper_version_diff_items WHERE diff_id = $1",
    )
    .bind(repeated.id)
    .fetch_one(database.pool())
    .await
    .unwrap();
    sqlx::query(
        r"
        INSERT INTO paper_version_diff_items (
            id, diff_id, ordinal, kind, old_object_id, new_object_id,
            change_type, similarity, diff_payload, confidence_status
        ) VALUES ($1, $2, $3, 'section', $4, $5, 'modified', 1.0, '{}'::jsonb, 'supported')
        ",
    )
    .bind(section_item_id)
    .bind(repeated.id)
    .bind(section_ordinal)
    .bind(old_section_id)
    .bind(new_section_id)
    .execute(database.pool())
    .await
    .unwrap();
    let section_targets = version_repository
        .source_targets(repeated.id)
        .await
        .unwrap();
    let section_targets = section_targets
        .iter()
        .filter(|target| target.diff_item_id == section_item_id)
        .collect::<Vec<_>>();
    assert_eq!(section_targets.len(), 2);
    assert!(section_targets.iter().any(|target| {
        target.side == VersionDiffSourceSide::Old
            && target.object_id == old_section_id
            && target.generation == 1
            && target.page_start == Some(1)
            && target
                .source_locator
                .as_ref()
                .and_then(|value| value.page_number)
                == Some(1)
    }));
    assert!(section_targets.iter().any(|target| {
        target.side == VersionDiffSourceSide::New
            && target.object_id == new_section_id
            && target.generation == 2
            && target.page_start == Some(1)
            && target
                .source_locator
                .as_ref()
                .and_then(|value| value.page_number)
                == Some(1)
    }));

    sqlx::query("DELETE FROM papers WHERE id = $1")
        .bind(paper.id)
        .execute(database.pool())
        .await
        .unwrap();
}

#[allow(clippy::too_many_lines)]
fn normalized_document(paper_id: Uuid, generation: i32) -> NormalizedDocument {
    let heading = block(
        paper_id,
        generation,
        0,
        0,
        DocumentBlockKind::Heading,
        "1 Introduction",
        Some(0),
    );
    let paragraph = block(
        paper_id,
        generation,
        1,
        1,
        DocumentBlockKind::Paragraph,
        "The β-catenin method works.",
        Some(0),
    );
    let mut second_paragraph = block(
        paper_id,
        generation,
        2,
        1,
        DocumentBlockKind::Paragraph,
        "Figure 1 and Table 1 support Equation 1.",
        Some(1),
    );
    let term_id = Uuid::now_v7();
    let figure = DocumentFigure {
        id: Uuid::now_v7(),
        paper_id,
        generation,
        label: "Figure 1".to_owned(),
        ordinal: 0,
        caption: "Architecture overview.".to_owned(),
        page_number: Some(1),
        asset_key: Some("papers/fixture/figure-1.webp".to_owned()),
        width: Some(800),
        height: Some(600),
        extraction_status: FigureExtractionStatus::Ready,
        content_hash: content_hash("fixture-figure-binary-v1"),
        source_locator: Some(locator("fig-1", None)),
    };
    let table = DocumentTable {
        id: Uuid::now_v7(),
        paper_id,
        generation,
        label: "Table 1".to_owned(),
        ordinal: 0,
        caption: "Evaluation results.".to_owned(),
        page_number: Some(2),
        structure: TableStructure {
            schema_version: TABLE_STRUCTURE_SCHEMA_VERSION.to_owned(),
            rows: vec![
                vec![cell("Metric", true), cell("Value", true)],
                vec![cell("Accuracy", false), cell("0.95", false)],
            ],
        },
        plain_text: "Metric | Value\nAccuracy | 0.95".to_owned(),
        extraction_status: TableExtractionStatus::Ready,
        content_hash: content_hash("fixture-table-grid-v1"),
        source_locator: Some(locator("table-1", None)),
    };
    let equation = DocumentEquation {
        id: Uuid::now_v7(),
        paper_id,
        generation,
        label: Some("(1)".to_owned()),
        ordinal: 0,
        latex: Some("E = mc^2".to_owned()),
        mathml: None,
        plain_text: Some("E equals m c squared".to_owned()),
        context_block_id: Some(paragraph.id),
        page_number: Some(1),
        confidence_status: EquationConfidenceStatus::Supported,
        content_hash: content_hash("fixture-equation-object-v1"),
        source_locator: Some(locator("formula-1", None)),
    };
    second_paragraph.inline_spans = vec![
        InlineSpan {
            kind: InlineSpanKind::FigureReference,
            start: 0,
            end: 8,
            target_id: Some(figure.id.to_string()),
            label: Some("Figure 1".to_owned()),
        },
        InlineSpan {
            kind: InlineSpanKind::TableReference,
            start: 13,
            end: 20,
            target_id: Some(table.id.to_string()),
            label: Some("Table 1".to_owned()),
        },
        InlineSpan {
            kind: InlineSpanKind::EquationReference,
            start: 29,
            end: 39,
            target_id: Some(equation.id.to_string()),
            label: Some("Equation 1".to_owned()),
        },
    ];
    NormalizedDocument {
        paper_id,
        generation,
        arxiv_version: 1,
        schema_version: DOCUMENT_SCHEMA_VERSION.to_owned(),
        parser_id: "grobid".to_owned(),
        parser_version: "0.8.2-pakperk-v1".to_owned(),
        blocks: vec![heading, paragraph.clone(), second_paragraph],
        figures: vec![figure],
        tables: vec![table],
        equations: vec![equation],
        terms: vec![DocumentTerm {
            id: term_id,
            paper_id,
            generation,
            normalized_term: normalize_term("β-catenin"),
            display_term: "β-catenin".to_owned(),
            kind: TermKind::Method,
            canonical_topic_id: None,
            definition_status: DefinitionStatus::Available,
        }],
        term_occurrences: vec![TermOccurrence {
            term_id,
            block_id: paragraph.id,
            paper_id,
            generation,
            start_offset: 4,
            end_offset: 13,
            occurrence_ordinal: 0,
        }],
        term_definitions: vec![TermDefinition {
            id: Uuid::now_v7(),
            term_id,
            paper_id,
            generation,
            source_type: DefinitionSourceType::CurrentPaper,
            source_block_ids: vec![paragraph.id],
            definition: "A fixture method grounded in the current paper.".to_owned(),
            model_id: None,
            prompt_version: None,
            confidence_status: DefinitionConfidenceStatus::Supported,
        }],
    }
}

fn block(
    paper_id: Uuid,
    generation: i32,
    ordinal: u32,
    local_ordinal: u32,
    kind: DocumentBlockKind,
    text: &str,
    legacy_section_ordinal: Option<u32>,
) -> DocumentBlock {
    let section_path = vec!["1 Introduction".to_owned()];
    DocumentBlock {
        id: Uuid::now_v7(),
        paper_id,
        generation,
        stable_key: stable_block_key(&section_path, kind, local_ordinal, text),
        ordinal,
        section_path,
        kind,
        text: text.to_owned(),
        page_start: Some(1),
        page_end: Some(1),
        source_locator: Some(locator(&format!("block-{ordinal}"), legacy_section_ordinal)),
        content_hash: content_hash(text),
        inline_spans: Vec::new(),
    }
}

fn locator(source_element_id: &str, legacy_section_ordinal: Option<u32>) -> SourceLocator {
    SourceLocator {
        source_element_id: Some(source_element_id.to_owned()),
        legacy_section_ordinal,
        page_number: Some(1),
        bounding_box: None,
    }
}

fn cell(text: &str, header: bool) -> TableCell {
    TableCell {
        text: text.to_owned(),
        header,
        row_span: 1,
        column_span: 1,
    }
}

fn legacy_document() -> ParsedPaper {
    ParsedPaper {
        title: Some("Document fixture".to_owned()),
        sections: vec![
            ParsedSection {
                source_id: "introduction".to_owned(),
                ordinal: 0,
                parent_source_id: None,
                kind: SectionKind::Introduction,
                heading: Some("1 Introduction".to_owned()),
                paragraphs: vec![ParsedParagraph {
                    ordinal: 0,
                    text: "The β-catenin method works.".to_owned(),
                    citations: Vec::new(),
                    page_start: Some(1),
                    page_end: Some(1),
                }],
                page_start: Some(1),
                page_end: Some(1),
            },
            ParsedSection {
                source_id: "methods".to_owned(),
                ordinal: 1,
                parent_source_id: None,
                kind: SectionKind::Method,
                heading: Some("2 Methods".to_owned()),
                paragraphs: vec![ParsedParagraph {
                    ordinal: 0,
                    text: "A second paragraph keeps pagination deterministic.".to_owned(),
                    citations: Vec::new(),
                    page_start: Some(2),
                    page_end: Some(2),
                }],
                page_start: Some(2),
                page_end: Some(2),
            },
        ],
        references: Vec::new(),
        citation_contexts: Vec::new(),
    }
}

fn metadata(base_id: &str, version: u32, fetched_at: chrono::DateTime<Utc>) -> PaperMetadata {
    PaperMetadata {
        arxiv_id: ArxivIdentifier {
            base_id: base_id.to_owned(),
            version,
        },
        title: format!("Document reader fixture v{version}"),
        abstract_text: "A document reader database integration fixture.".to_owned(),
        authors: vec![Author::from("Ada Tester".to_owned())],
        primary_category: "cs.AI".to_owned(),
        categories: vec!["cs.AI".to_owned()],
        published_at: fetched_at - TimeDelta::days(1),
        updated_at: fetched_at,
        abs_url: Url::parse(&format!("https://arxiv.org/abs/{base_id}v{version}")).unwrap(),
        pdf_url: Url::parse(&format!("https://arxiv.org/pdf/{base_id}v{version}")).unwrap(),
        doi: None,
        journal_reference: None,
        comment: None,
        license_uri: Some(Url::parse("https://creativecommons.org/licenses/by/4.0/").unwrap()),
        metadata_fetched_at: fetched_at,
    }
}

fn test_cursor_codec() -> opaque_cursor::OpaqueCursorCodec {
    let key = STANDARD.encode([0x64; 32]);
    opaque_cursor::OpaqueCursorCodec::parse_keyring(&format!("document_test:{key}")).unwrap()
}
