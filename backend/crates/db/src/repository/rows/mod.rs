use super::{
    ArxivIdentifier, Author, Capabilities, ChatRole, ChatTurn, ConnectionReference, DateTime,
    DbError, FailureCategory, FromRow, HashMap, IntroductionCitation,
    IntroductionCitationReference, IntroductionParagraph, KeyConnection, OnceLock,
    OverallProcessingState, Paper, PaperId, PaperMetadata, PaperSummary, Postgres, ProcessingError,
    ProcessingGeneration, ProcessingStage, ProcessingState, ReferenceResolutionStatus, Regex,
    RelationType, RetrievalCandidate, SectionKind, StoredSection, TitleCandidate, Transaction, Url,
    Utc, Uuid, Value, info,
};

pub(super) const PAPER_SELECT_BY_ID: &str = r"
    SELECT
        id,
        arxiv_base_id,
        arxiv_version,
        title,
        abstract AS abstract_text,
        authors,
        primary_category,
        categories,
        published_at,
        updated_at,
        abs_url,
        pdf_url,
        doi,
        journal_reference,
        comment,
        license_uri,
        metadata_fetched_at
    FROM papers
    WHERE id = $1
";

pub(super) const PAPER_SELECT_BY_ARXIV: &str = r"
    SELECT
        id,
        arxiv_base_id,
        arxiv_version,
        title,
        abstract AS abstract_text,
        authors,
        primary_category,
        categories,
        published_at,
        updated_at,
        abs_url,
        pdf_url,
        doi,
        journal_reference,
        comment,
        license_uri,
        metadata_fetched_at
    FROM papers
    WHERE arxiv_base_id = $1
";

pub(super) const PAPER_SUMMARY_BY_ID: &str = r"
    SELECT
        p.id,
        p.arxiv_base_id,
        p.arxiv_version,
        p.title,
        p.abstract AS abstract_text,
        p.authors,
        p.primary_category,
        p.categories,
        p.published_at,
        p.updated_at,
        p.abs_url,
        p.pdf_url,
        processing.metadata_ready,
        processing.introduction_ready,
        processing.chat_ready,
        processing.connections_ready
    FROM papers AS p
    JOIN paper_processing AS processing ON processing.paper_id = p.id
    WHERE p.id = $1
";

pub(super) const PROCESSING_SELECT: &str = r"
    SELECT
        paper_id,
        generation,
        stage,
        metadata_ready,
        introduction_ready,
        chat_ready,
        connections_ready,
        retryable,
        last_error_category,
        last_error_code,
        last_error_message,
        started_at,
        updated_at,
        completed_at,
        parser_version,
        embedding_model,
        summary_model
    FROM paper_processing
    WHERE paper_id = $1
";

#[derive(Debug, FromRow)]
pub(super) struct PaperRow {
    pub(super) id: Uuid,
    pub(super) arxiv_base_id: String,
    pub(super) arxiv_version: i32,
    pub(super) title: String,
    pub(super) abstract_text: String,
    pub(super) authors: Value,
    pub(super) primary_category: String,
    pub(super) categories: Vec<String>,
    pub(super) published_at: DateTime<Utc>,
    pub(super) updated_at: DateTime<Utc>,
    pub(super) abs_url: String,
    pub(super) pdf_url: String,
    pub(super) doi: Option<String>,
    pub(super) journal_reference: Option<String>,
    pub(super) comment: Option<String>,
    pub(super) license_uri: Option<String>,
    pub(super) metadata_fetched_at: DateTime<Utc>,
}

impl TryFrom<PaperRow> for Paper {
    type Error = DbError;

    fn try_from(row: PaperRow) -> Result<Self, Self::Error> {
        Ok(Self {
            id: row.id,
            metadata: PaperMetadata {
                arxiv_id: ArxivIdentifier {
                    base_id: row.arxiv_base_id,
                    version: u32::try_from(row.arxiv_version)
                        .map_err(|_| DbError::InvalidData("negative arXiv version".to_owned()))?,
                },
                title: row.title,
                abstract_text: row.abstract_text,
                authors: decode_authors(row.authors)?,
                primary_category: row.primary_category,
                categories: row.categories,
                published_at: row.published_at,
                updated_at: row.updated_at,
                abs_url: Url::parse(&row.abs_url)?,
                pdf_url: Url::parse(&row.pdf_url)?,
                doi: row.doi,
                journal_reference: row.journal_reference,
                comment: row.comment,
                license_uri: row.license_uri.map(|url| Url::parse(&url)).transpose()?,
                metadata_fetched_at: row.metadata_fetched_at,
            },
        })
    }
}

#[derive(Debug, FromRow)]
#[allow(clippy::struct_excessive_bools)]
pub(super) struct PaperSummaryRow {
    pub(super) id: Uuid,
    pub(super) arxiv_base_id: String,
    pub(super) arxiv_version: i32,
    pub(super) title: String,
    pub(super) abstract_text: String,
    pub(super) authors: Value,
    pub(super) primary_category: String,
    pub(super) categories: Vec<String>,
    pub(super) published_at: DateTime<Utc>,
    pub(super) updated_at: DateTime<Utc>,
    pub(super) abs_url: String,
    pub(super) pdf_url: String,
    pub(super) metadata_ready: bool,
    pub(super) introduction_ready: bool,
    pub(super) chat_ready: bool,
    pub(super) connections_ready: bool,
}

#[derive(Debug, FromRow)]
pub(super) struct LicenseUriRow {
    pub(super) id: Uuid,
    pub(super) license_uri: Option<String>,
}

impl TryFrom<PaperSummaryRow> for PaperSummary {
    type Error = DbError;

    fn try_from(row: PaperSummaryRow) -> Result<Self, Self::Error> {
        let authors = decode_authors(row.authors)?
            .into_iter()
            .map(|author| author.name)
            .collect();
        Ok(Self {
            paper_id: row.id,
            arxiv_id: format!(
                "{}v{}",
                row.arxiv_base_id,
                u32::try_from(row.arxiv_version)
                    .map_err(|_| DbError::InvalidData("negative arXiv version".to_owned()))?
            ),
            title: row.title,
            abstract_text: row.abstract_text,
            authors,
            primary_category: row.primary_category,
            categories: row.categories,
            published_at: row.published_at,
            updated_at: row.updated_at,
            abs_url: Url::parse(&row.abs_url)?,
            pdf_url: Url::parse(&row.pdf_url)?,
            capabilities: Capabilities {
                metadata: row.metadata_ready,
                introduction: row.introduction_ready,
                chat: row.chat_ready,
                connections: row.connections_ready,
            },
        })
    }
}

#[derive(Debug, FromRow)]
#[allow(clippy::struct_excessive_bools)]
pub(super) struct ProcessingRow {
    pub(super) paper_id: Uuid,
    pub(super) generation: i32,
    pub(super) stage: String,
    pub(super) metadata_ready: bool,
    pub(super) introduction_ready: bool,
    pub(super) chat_ready: bool,
    pub(super) connections_ready: bool,
    pub(super) retryable: bool,
    pub(super) last_error_category: Option<String>,
    pub(super) last_error_code: Option<String>,
    pub(super) last_error_message: Option<String>,
    pub(super) started_at: Option<DateTime<Utc>>,
    pub(super) updated_at: DateTime<Utc>,
    pub(super) completed_at: Option<DateTime<Utc>>,
    pub(super) parser_version: Option<String>,
    pub(super) embedding_model: Option<String>,
    pub(super) summary_model: Option<String>,
}

impl TryFrom<ProcessingRow> for ProcessingState {
    type Error = DbError;

    fn try_from(row: ProcessingRow) -> Result<Self, Self::Error> {
        let stage = parse_processing_stage(&row.stage)?;
        let capabilities = Capabilities {
            metadata: row.metadata_ready,
            introduction: row.introduction_ready,
            chat: row.chat_ready,
            connections: row.connections_ready,
        };
        if !capabilities.valid_for_stage(stage) {
            return Err(DbError::InvalidData(format!(
                "capabilities violate publication order for stage `{}`",
                processing_stage_name(stage)
            )));
        }
        let last_error = match (row.last_error_code, row.last_error_message) {
            (Some(code), Some(message)) => Some(ProcessingError {
                category: row
                    .last_error_category
                    .as_deref()
                    .map(parse_failure_category)
                    .transpose()?
                    .unwrap_or(FailureCategory::Internal),
                code,
                message,
            }),
            (None, None) => None,
            _ => {
                return Err(DbError::InvalidData(
                    "processing error code and message must be set together".to_owned(),
                ));
            }
        };
        let overall_state = match stage {
            ProcessingStage::NotRequested => OverallProcessingState::NotRequested,
            ProcessingStage::Ready => OverallProcessingState::Ready,
            ProcessingStage::FailedRetryable | ProcessingStage::FailedTerminal => {
                OverallProcessingState::Failed
            }
            _ => OverallProcessingState::Processing,
        };
        Ok(Self {
            paper_id: row.paper_id,
            generation: row.generation,
            overall_state,
            stage,
            capabilities,
            retryable: row.retryable,
            last_error,
            started_at: row.started_at,
            updated_at: row.updated_at,
            completed_at: row.completed_at,
            parser_version: row.parser_version,
            embedding_model: row.embedding_model,
            summary_model: row.summary_model,
        })
    }
}

#[derive(Debug, FromRow)]
pub(super) struct IntroductionHeaderRow {
    pub(super) generation: i32,
    pub(super) introduction_ready: bool,
    pub(super) pdf_url: String,
}

#[derive(Debug, FromRow)]
pub(super) struct IntroductionSectionRow {
    pub(super) heading: Option<String>,
    pub(super) paragraphs: Value,
    pub(super) detection_confidence: Option<f32>,
}

#[derive(Debug, FromRow)]
pub(super) struct IntroductionResolvedReferenceRow {
    pub(super) ordinal: i32,
    pub(super) paper_id: Uuid,
    pub(super) title: String,
    pub(super) context_text: Option<String>,
}

pub(super) fn build_introduction_content(
    rows: Vec<IntroductionSectionRow>,
    resolved_reference_rows: Vec<IntroductionResolvedReferenceRow>,
) -> Result<(Option<String>, f32, Vec<IntroductionParagraph>), DbError> {
    // Detection source IDs are persisted in document order, with the
    // Introduction root first. Do not promote a nested heading to the root
    // when an unheaded fallback section is used.
    let heading = rows.first().and_then(|row| row.heading.clone());
    let confidence = rows
        .iter()
        .filter_map(|row| row.detection_confidence)
        .fold(0.0_f32, f32::max);
    let mut resolved_references = HashMap::new();
    let mut legacy_contexts = HashMap::<usize, Vec<String>>::new();
    for row in resolved_reference_rows {
        let ordinal = i32_to_usize(row.ordinal, "reference ordinal")?;
        resolved_references
            .entry(ordinal)
            .or_insert(IntroductionCitationReference {
                paper_id: row.paper_id,
                title: row.title,
            });
        if let Some(context) = row.context_text {
            legacy_contexts.entry(ordinal).or_default().push(context);
        }
    }
    let mut paragraphs = Vec::new();
    for (section_index, row) in rows.into_iter().enumerate() {
        let parsed: Vec<domain::ParsedParagraph> = serde_json::from_value(row.paragraphs)
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        for (paragraph_index, paragraph) in parsed.into_iter().enumerate() {
            let legacy_paragraph = paragraph.citations.is_empty();
            let mut citations = paragraph
                .citations
                .into_iter()
                .filter_map(|citation| {
                    let marker = paragraph
                        .text
                        .chars()
                        .skip(citation.start)
                        .take(citation.end.saturating_sub(citation.start))
                        .collect::<String>();
                    if citation.end < citation.start || marker != citation.marker {
                        return None;
                    }
                    let references = resolved_citation_references(
                        &citation.reference_ordinals,
                        &resolved_references,
                    )?;
                    Some(IntroductionCitation {
                        start: citation.start,
                        end: citation.end,
                        marker: citation.marker,
                        references,
                    })
                })
                .collect::<Vec<_>>();
            if legacy_paragraph {
                citations = legacy_numeric_citations(
                    &paragraph.text,
                    &resolved_references,
                    &legacy_contexts,
                );
            }
            paragraphs.push(IntroductionParagraph {
                ordinal: paragraphs.len(),
                text: paragraph.text,
                heading: (section_index > 0 && paragraph_index == 0)
                    .then(|| row.heading.clone())
                    .flatten(),
                citations,
                page_start: paragraph.page_start,
                page_end: paragraph.page_end,
            });
        }
    }
    Ok((heading, confidence, paragraphs))
}

pub(super) fn resolved_citation_references(
    ordinals: &[usize],
    resolved_references: &HashMap<usize, IntroductionCitationReference>,
) -> Option<Vec<IntroductionCitationReference>> {
    if ordinals.is_empty() {
        return None;
    }
    let mut references = Vec::with_capacity(ordinals.len());
    for ordinal in ordinals {
        let reference = resolved_references.get(ordinal)?;
        if !references
            .iter()
            .any(|existing: &IntroductionCitationReference| existing.paper_id == reference.paper_id)
        {
            references.push(reference.clone());
        }
    }
    Some(references)
}

pub(super) fn legacy_numeric_citations(
    text: &str,
    resolved_references: &HashMap<usize, IntroductionCitationReference>,
    legacy_contexts: &HashMap<usize, Vec<String>>,
) -> Vec<IntroductionCitation> {
    legacy_numeric_marker_regex()
        .captures_iter(text)
        .filter_map(|captures| {
            let marker = captures.get(0)?;
            if text[..marker.start()].ends_with('[') || text[marker.end()..].starts_with(']') {
                return None;
            }
            let labels = parse_numeric_reference_labels(captures.name("body")?.as_str().trim())?;
            let references = uniquely_context_backed_references(
                &labels,
                text,
                marker.as_str(),
                resolved_references,
                legacy_contexts,
            )?;
            let start = text[..marker.start()].chars().count();
            Some(IntroductionCitation {
                start,
                end: start + marker.as_str().chars().count(),
                marker: marker.as_str().to_owned(),
                references,
            })
        })
        .collect()
}

pub(super) fn uniquely_context_backed_references(
    labels: &[usize],
    paragraph: &str,
    marker: &str,
    resolved_references: &HashMap<usize, IntroductionCitationReference>,
    legacy_contexts: &HashMap<usize, Vec<String>>,
) -> Option<Vec<IntroductionCitationReference>> {
    let exact_ordinals = labels.to_vec();
    let conventional_one_based = labels
        .iter()
        .map(|label| label.checked_sub(1))
        .collect::<Option<Vec<_>>>();
    let mut matches = [Some(exact_ordinals), conventional_one_based]
        .into_iter()
        .flatten()
        .filter_map(|ordinals| {
            let all_contexts_match = ordinals.iter().all(|ordinal| {
                legacy_contexts.get(ordinal).is_some_and(|contexts| {
                    contexts
                        .iter()
                        .any(|context| citation_context_matches(context, paragraph, marker))
                })
            });
            all_contexts_match
                .then(|| resolved_citation_references(&ordinals, resolved_references))
                .flatten()
        });
    let only_match = matches.next()?;
    matches.next().is_none().then_some(only_match)
}

pub(super) fn citation_context_matches(context: &str, paragraph: &str, marker: &str) -> bool {
    let context = context.trim();
    let paragraph = paragraph.trim();
    !context.is_empty()
        && context.contains(marker)
        && (paragraph.contains(context) || context.contains(paragraph))
}

pub(super) fn legacy_numeric_marker_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(r"\[(?P<body>[0-9][0-9,\t \-–]*)\]")
            .expect("legacy numeric citation marker regex is valid")
    })
}

pub(super) fn parse_numeric_reference_labels(body: &str) -> Option<Vec<usize>> {
    const MAX_REFERENCES_PER_MARKER: usize = 64;
    let mut ordinals = Vec::new();
    for item in body.split(',') {
        let item = item.trim();
        if item.is_empty() {
            return None;
        }
        let range_parts = item.split(['-', '–']).map(str::trim).collect::<Vec<_>>();
        let (start, end) = match range_parts.as_slice() {
            [single] => {
                let value = parse_positive_numeric_label(single)?;
                (value, value)
            }
            [start, end] => {
                let start = parse_positive_numeric_label(start)?;
                let end = parse_positive_numeric_label(end)?;
                if end < start {
                    return None;
                }
                (start, end)
            }
            _ => return None,
        };
        if end.saturating_sub(start) >= MAX_REFERENCES_PER_MARKER {
            return None;
        }
        for ordinal in start..=end {
            if ordinals.contains(&ordinal) || ordinals.len() == MAX_REFERENCES_PER_MARKER {
                return None;
            }
            ordinals.push(ordinal);
        }
    }
    (!ordinals.is_empty()).then_some(ordinals)
}

pub(super) fn parse_positive_numeric_label(value: &str) -> Option<usize> {
    if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let value = value.parse::<usize>().ok()?;
    (value > 0).then_some(value)
}

#[derive(Debug, FromRow)]
pub(super) struct StoredSectionRow {
    pub(super) id: Uuid,
    pub(super) kind: String,
    pub(super) heading: Option<String>,
    pub(super) text: String,
    pub(super) paragraphs: Value,
    pub(super) page_start: Option<i32>,
    pub(super) page_end: Option<i32>,
    pub(super) ordinal: i32,
}

impl TryFrom<StoredSectionRow> for StoredSection {
    type Error = DbError;

    fn try_from(row: StoredSectionRow) -> Result<Self, Self::Error> {
        Ok(Self {
            id: row.id,
            kind: parse_section_kind(&row.kind)?,
            heading: row.heading,
            text: row.text,
            paragraphs: serde_json::from_value(row.paragraphs)
                .map_err(|error| DbError::InvalidData(error.to_string()))?,
            page_start: option_i32_to_u32(row.page_start, "section page")?,
            page_end: option_i32_to_u32(row.page_end, "section page")?,
            ordinal: i32_to_usize(row.ordinal, "section ordinal")?,
        })
    }
}

#[derive(Debug, FromRow)]
pub(super) struct RetrievalRow {
    pub(super) id: Uuid,
    pub(super) paper_id: Uuid,
    pub(super) section_id: Uuid,
    pub(super) generation: i32,
    pub(super) ordinal: i32,
    pub(super) section_kind: String,
    pub(super) section_heading: Option<String>,
    pub(super) text: String,
    pub(super) page_start: Option<i32>,
    pub(super) page_end: Option<i32>,
    pub(super) token_count: Option<i32>,
    pub(super) rank: i64,
}

impl TryFrom<RetrievalRow> for RetrievalCandidate {
    type Error = DbError;

    fn try_from(row: RetrievalRow) -> Result<Self, Self::Error> {
        Ok(Self {
            chunk: domain::Chunk {
                id: row.id,
                paper_id: row.paper_id,
                section_id: row.section_id,
                generation: row.generation,
                ordinal: i32_to_usize(row.ordinal, "chunk ordinal")?,
                section_kind: parse_section_kind(&row.section_kind)?,
                section_heading: row.section_heading,
                text: row.text,
                page_start: option_i32_to_u32(row.page_start, "chunk page")?,
                page_end: option_i32_to_u32(row.page_end, "chunk page")?,
                token_count: i32_to_usize(row.token_count.unwrap_or(1), "chunk token count")?,
            },
            rank: usize::try_from(row.rank)
                .map_err(|_| DbError::InvalidData("negative retrieval rank".to_owned()))?,
        })
    }
}

#[derive(Debug, FromRow)]
pub(super) struct ChatTurnRow {
    pub(super) role: String,
    pub(super) content: String,
}

impl TryFrom<ChatTurnRow> for ChatTurn {
    type Error = DbError;

    fn try_from(row: ChatTurnRow) -> Result<Self, Self::Error> {
        let role = match row.role.as_str() {
            "user" => ChatRole::User,
            "assistant" => ChatRole::Assistant,
            other => {
                return Err(DbError::InvalidData(format!("unknown chat role `{other}`")));
            }
        };
        Ok(Self {
            role,
            content: row.content,
        })
    }
}

#[derive(Debug, FromRow)]
pub(super) struct ReferenceRow {
    pub(super) id: Uuid,
    pub(super) citing_paper_id: Uuid,
    pub(super) generation: i32,
    pub(super) ordinal: i32,
    pub(super) raw_text: String,
    pub(super) extracted_title: Option<String>,
    pub(super) extracted_authors: Option<Value>,
    pub(super) extracted_year: Option<i32>,
    pub(super) doi: Option<String>,
    pub(super) extracted_arxiv_id: Option<String>,
    pub(super) resolved_paper_id: Option<Uuid>,
    pub(super) resolution_status: String,
    pub(super) resolution_confidence: Option<f32>,
    pub(super) resolution_method: Option<String>,
    pub(super) key_score: Option<f32>,
}

impl TryFrom<ReferenceRow> for domain::Reference {
    type Error = DbError;

    fn try_from(row: ReferenceRow) -> Result<Self, Self::Error> {
        let extracted_authors = row
            .extracted_authors
            .map(serde_json::from_value)
            .transpose()
            .map_err(|error| DbError::InvalidData(error.to_string()))?
            .unwrap_or_default();
        Ok(Self {
            id: row.id,
            citing_paper_id: row.citing_paper_id,
            generation: row.generation,
            ordinal: i32_to_usize(row.ordinal, "reference ordinal")?,
            raw_text: row.raw_text,
            extracted_title: row.extracted_title,
            extracted_authors,
            extracted_year: row.extracted_year,
            doi: row.doi,
            extracted_arxiv_id: row.extracted_arxiv_id,
            resolved_paper_id: row.resolved_paper_id,
            resolution_status: parse_reference_status(&row.resolution_status)?,
            resolution_confidence: row.resolution_confidence,
            resolution_method: row.resolution_method,
            key_score: row.key_score,
        })
    }
}

#[derive(Debug, FromRow)]
pub(super) struct CitationContextRow {
    pub(super) id: Uuid,
    pub(super) reference_id: Uuid,
    pub(super) section_kind: String,
    pub(super) section_heading: Option<String>,
    pub(super) context_text: String,
    pub(super) page_number: Option<i32>,
    pub(super) occurrence_ordinal: i32,
}

impl TryFrom<CitationContextRow> for domain::CitationContext {
    type Error = DbError;

    fn try_from(row: CitationContextRow) -> Result<Self, Self::Error> {
        Ok(Self {
            id: row.id,
            reference_id: row.reference_id,
            section_kind: parse_section_kind(&row.section_kind)?,
            section_heading: row.section_heading,
            context_text: row.context_text,
            page_number: option_i32_to_u32(row.page_number, "citation page")?,
            occurrence_ordinal: i32_to_usize(row.occurrence_ordinal, "citation occurrence")?,
        })
    }
}

#[derive(Debug, FromRow)]
pub(super) struct TitleCandidateRow {
    pub(super) id: Uuid,
    pub(super) arxiv_base_id: String,
    pub(super) arxiv_version: i32,
    pub(super) title: String,
    pub(super) abstract_text: String,
    pub(super) authors: Value,
    pub(super) primary_category: String,
    pub(super) categories: Vec<String>,
    pub(super) published_at: DateTime<Utc>,
    pub(super) updated_at: DateTime<Utc>,
    pub(super) abs_url: String,
    pub(super) pdf_url: String,
    pub(super) doi: Option<String>,
    pub(super) journal_reference: Option<String>,
    pub(super) comment: Option<String>,
    pub(super) license_uri: Option<String>,
    pub(super) metadata_fetched_at: DateTime<Utc>,
    pub(super) similarity: f32,
}

impl TryFrom<TitleCandidateRow> for TitleCandidate {
    type Error = DbError;

    fn try_from(row: TitleCandidateRow) -> Result<Self, Self::Error> {
        let similarity = row.similarity;
        let paper = Paper::try_from(PaperRow {
            id: row.id,
            arxiv_base_id: row.arxiv_base_id,
            arxiv_version: row.arxiv_version,
            title: row.title,
            abstract_text: row.abstract_text,
            authors: row.authors,
            primary_category: row.primary_category,
            categories: row.categories,
            published_at: row.published_at,
            updated_at: row.updated_at,
            abs_url: row.abs_url,
            pdf_url: row.pdf_url,
            doi: row.doi,
            journal_reference: row.journal_reference,
            comment: row.comment,
            license_uri: row.license_uri,
            metadata_fetched_at: row.metadata_fetched_at,
        })?;
        Ok(Self { paper, similarity })
    }
}

#[derive(Debug, FromRow)]
pub(super) struct KeyConnectionRow {
    pub(super) reference_id: Uuid,
    pub(super) paper_id: Uuid,
    pub(super) arxiv_base_id: String,
    pub(super) arxiv_version: i32,
    pub(super) title: String,
    pub(super) authors: Value,
    pub(super) year: Option<i32>,
    pub(super) relation_type: String,
    pub(super) summary: String,
    pub(super) confidence: f32,
}

impl TryFrom<KeyConnectionRow> for KeyConnection {
    type Error = DbError;

    fn try_from(row: KeyConnectionRow) -> Result<Self, Self::Error> {
        Ok(Self {
            reference_id: row.reference_id,
            paper_id: row.paper_id,
            arxiv_id: format!("{}v{}", row.arxiv_base_id, row.arxiv_version),
            title: row.title,
            authors: decode_authors(row.authors)?
                .into_iter()
                .map(|author| author.name)
                .collect(),
            year: row.year,
            relation_type: parse_relation_type(&row.relation_type)?,
            summary: row.summary,
            confidence: row.confidence,
        })
    }
}

#[derive(Debug, FromRow)]
pub(super) struct ConnectionReferenceRow {
    pub(super) ordinal: i32,
    pub(super) raw_text: String,
    pub(super) paper_id: Option<Uuid>,
    pub(super) title: Option<String>,
    pub(super) resolution_status: String,
}

impl TryFrom<ConnectionReferenceRow> for ConnectionReference {
    type Error = DbError;

    fn try_from(row: ConnectionReferenceRow) -> Result<Self, Self::Error> {
        Ok(Self {
            ordinal: i32_to_usize(row.ordinal, "reference ordinal")?,
            raw_text: row.raw_text,
            resolved: row.paper_id.is_some()
                && row.resolution_status
                    == reference_status_name(ReferenceResolutionStatus::Resolved),
            paper_id: row.paper_id,
            title: row.title,
            resolution_status: parse_reference_status(&row.resolution_status)?,
        })
    }
}

pub(super) fn decode_authors(value: Value) -> Result<Vec<Author>, DbError> {
    if let Ok(authors) = serde_json::from_value::<Vec<Author>>(value.clone()) {
        return Ok(authors);
    }
    serde_json::from_value::<Vec<String>>(value)
        .map(|authors| authors.into_iter().map(Author::from).collect())
        .map_err(|error| DbError::InvalidData(error.to_string()))
}

pub(super) fn processing_stage_name(stage: ProcessingStage) -> &'static str {
    match stage {
        ProcessingStage::NotRequested => "not_requested",
        ProcessingStage::Queued => "queued",
        ProcessingStage::FetchingLicense => "fetching_license",
        ProcessingStage::FetchingPdf => "fetching_pdf",
        ProcessingStage::ParsingPdf => "parsing_pdf",
        ProcessingStage::IntroductionReady => "introduction_ready",
        ProcessingStage::IndexingChat => "indexing_chat",
        ProcessingStage::ResolvingReferences => "resolving_references",
        ProcessingStage::Ready => "ready",
        ProcessingStage::FailedRetryable => "failed_retryable",
        ProcessingStage::FailedTerminal => "failed_terminal",
    }
}

pub(super) fn parse_processing_stage(value: &str) -> Result<ProcessingStage, DbError> {
    match value {
        "not_requested" => Ok(ProcessingStage::NotRequested),
        "queued" => Ok(ProcessingStage::Queued),
        "fetching_license" => Ok(ProcessingStage::FetchingLicense),
        "fetching_pdf" => Ok(ProcessingStage::FetchingPdf),
        "parsing_pdf" => Ok(ProcessingStage::ParsingPdf),
        "introduction_ready" => Ok(ProcessingStage::IntroductionReady),
        "indexing_chat" => Ok(ProcessingStage::IndexingChat),
        "resolving_references" => Ok(ProcessingStage::ResolvingReferences),
        "ready" => Ok(ProcessingStage::Ready),
        "failed_retryable" => Ok(ProcessingStage::FailedRetryable),
        "failed_terminal" => Ok(ProcessingStage::FailedTerminal),
        other => Err(DbError::InvalidData(format!(
            "unknown processing stage `{other}`"
        ))),
    }
}

pub(super) fn failure_category_name(category: FailureCategory) -> &'static str {
    match category {
        FailureCategory::ExternalTemporary => "external_temporary",
        FailureCategory::ExternalPermanent => "external_permanent",
        FailureCategory::ParserTemporary => "parser_temporary",
        FailureCategory::ParserDocument => "parser_document",
        FailureCategory::ModelTemporary => "model_temporary",
        FailureCategory::Validation => "validation",
        FailureCategory::Internal => "internal",
    }
}

pub(super) fn parse_failure_category(value: &str) -> Result<FailureCategory, DbError> {
    match value {
        "external_temporary" => Ok(FailureCategory::ExternalTemporary),
        "external_permanent" => Ok(FailureCategory::ExternalPermanent),
        "parser_temporary" => Ok(FailureCategory::ParserTemporary),
        "parser_document" => Ok(FailureCategory::ParserDocument),
        "model_temporary" => Ok(FailureCategory::ModelTemporary),
        "validation" => Ok(FailureCategory::Validation),
        "internal" => Ok(FailureCategory::Internal),
        other => Err(DbError::InvalidData(format!(
            "unknown failure category `{other}`"
        ))),
    }
}

pub(super) fn section_kind_name(kind: SectionKind) -> &'static str {
    match kind {
        SectionKind::Abstract => "abstract",
        SectionKind::Introduction => "introduction",
        SectionKind::Background => "background",
        SectionKind::RelatedWork => "related_work",
        SectionKind::Method => "method",
        SectionKind::Experiment => "experiment",
        SectionKind::Result => "result",
        SectionKind::Discussion => "discussion",
        SectionKind::Limitation => "limitation",
        SectionKind::Conclusion => "conclusion",
        SectionKind::Appendix => "appendix",
        SectionKind::Acknowledgment => "acknowledgment",
        SectionKind::References => "references",
        SectionKind::Other => "other",
    }
}

pub(super) fn parse_section_kind(value: &str) -> Result<SectionKind, DbError> {
    match value {
        "abstract" => Ok(SectionKind::Abstract),
        "introduction" => Ok(SectionKind::Introduction),
        "background" => Ok(SectionKind::Background),
        "related_work" => Ok(SectionKind::RelatedWork),
        "method" => Ok(SectionKind::Method),
        "experiment" => Ok(SectionKind::Experiment),
        "result" => Ok(SectionKind::Result),
        "discussion" => Ok(SectionKind::Discussion),
        "limitation" => Ok(SectionKind::Limitation),
        "conclusion" => Ok(SectionKind::Conclusion),
        "appendix" => Ok(SectionKind::Appendix),
        "acknowledgment" => Ok(SectionKind::Acknowledgment),
        "references" => Ok(SectionKind::References),
        "other" => Ok(SectionKind::Other),
        other => Err(DbError::InvalidData(format!(
            "unknown section kind `{other}`"
        ))),
    }
}

pub(super) fn reference_status_name(status: ReferenceResolutionStatus) -> &'static str {
    match status {
        ReferenceResolutionStatus::Unresolved => "unresolved",
        ReferenceResolutionStatus::Resolving => "resolving",
        ReferenceResolutionStatus::Resolved => "resolved",
        ReferenceResolutionStatus::Ambiguous => "ambiguous",
        ReferenceResolutionStatus::NotArxiv => "not_arxiv",
        ReferenceResolutionStatus::Failed => "failed",
    }
}

pub(super) fn parse_reference_status(value: &str) -> Result<ReferenceResolutionStatus, DbError> {
    match value {
        "unresolved" => Ok(ReferenceResolutionStatus::Unresolved),
        "resolving" => Ok(ReferenceResolutionStatus::Resolving),
        "resolved" => Ok(ReferenceResolutionStatus::Resolved),
        "ambiguous" => Ok(ReferenceResolutionStatus::Ambiguous),
        "not_arxiv" => Ok(ReferenceResolutionStatus::NotArxiv),
        "failed" => Ok(ReferenceResolutionStatus::Failed),
        other => Err(DbError::InvalidData(format!(
            "unknown reference status `{other}`"
        ))),
    }
}

pub(super) fn relation_type_name(relation_type: RelationType) -> &'static str {
    match relation_type {
        RelationType::BuildsOn => "builds_on",
        RelationType::Uses => "uses",
        RelationType::Extends => "extends",
        RelationType::Applies => "applies",
        RelationType::ComparesWith => "compares_with",
        RelationType::ContrastsWith => "contrasts_with",
        RelationType::Background => "background",
        RelationType::RelatedWork => "related_work",
        RelationType::Unknown => "unknown",
    }
}

pub(super) fn parse_relation_type(value: &str) -> Result<RelationType, DbError> {
    match value {
        "builds_on" => Ok(RelationType::BuildsOn),
        "uses" => Ok(RelationType::Uses),
        "extends" => Ok(RelationType::Extends),
        "applies" => Ok(RelationType::Applies),
        "compares_with" => Ok(RelationType::ComparesWith),
        "contrasts_with" => Ok(RelationType::ContrastsWith),
        "background" => Ok(RelationType::Background),
        "related_work" => Ok(RelationType::RelatedWork),
        "unknown" => Ok(RelationType::Unknown),
        other => Err(DbError::InvalidData(format!(
            "unknown relation type `{other}`"
        ))),
    }
}

pub(super) fn usize_to_i32(value: usize, field: &str) -> Result<i32, DbError> {
    i32::try_from(value).map_err(|_| DbError::InvalidData(format!("{field} is too large")))
}

pub(super) fn i32_to_usize(value: i32, field: &str) -> Result<usize, DbError> {
    usize::try_from(value).map_err(|_| DbError::InvalidData(format!("{field} is negative")))
}

pub(super) fn i64_to_usize(value: i64, field: &str) -> Result<usize, DbError> {
    usize::try_from(value).map_err(|_| DbError::InvalidData(format!("{field} is negative")))
}

pub(super) fn option_u32_to_i32(value: Option<u32>, field: &str) -> Result<Option<i32>, DbError> {
    value
        .map(|value| {
            i32::try_from(value).map_err(|_| DbError::InvalidData(format!("{field} is too large")))
        })
        .transpose()
}

pub(super) fn option_i32_to_u32(value: Option<i32>, field: &str) -> Result<Option<u32>, DbError> {
    value
        .map(|value| {
            u32::try_from(value).map_err(|_| DbError::InvalidData(format!("{field} is negative")))
        })
        .transpose()
}

pub(super) fn require_current_generation(rows_affected: u64) -> Result<(), DbError> {
    if rows_affected == 1 {
        Ok(())
    } else {
        Err(DbError::StaleGeneration)
    }
}

pub(super) async fn lock_current_generation(
    transaction: &mut Transaction<'_, Postgres>,
    paper_id: PaperId,
    generation: ProcessingGeneration,
) -> Result<(), DbError> {
    let current = sqlx::query_scalar::<_, i32>(
        r"
        SELECT generation
        FROM paper_processing
        WHERE paper_id = $1
        FOR UPDATE
        ",
    )
    .bind(paper_id)
    .fetch_optional(&mut **transaction)
    .await?;
    if current == Some(generation) {
        Ok(())
    } else {
        Err(DbError::StaleGeneration)
    }
}

#[derive(Clone, Copy)]
pub(super) enum CapabilityToPublish<'a> {
    Chat { model: &'a str },
    Connections { model: Option<&'a str> },
}

#[derive(Clone, Copy)]
pub(super) struct CapabilityTransition {
    pub(super) capability: &'static str,
    pub(super) transitioned_at: DateTime<Utc>,
}

pub(super) async fn publish_capability(
    transaction: &mut Transaction<'_, Postgres>,
    paper_id: PaperId,
    generation: ProcessingGeneration,
    capability: CapabilityToPublish<'_>,
) -> Result<Option<CapabilityTransition>, DbError> {
    let (capability_name, was_ready) = match capability {
        CapabilityToPublish::Chat { .. } => (
            "chat",
            sqlx::query_scalar::<_, bool>(
                "SELECT chat_ready FROM paper_processing WHERE paper_id = $1",
            )
            .bind(paper_id)
            .fetch_one(&mut **transaction)
            .await?,
        ),
        CapabilityToPublish::Connections { .. } => (
            "connections",
            sqlx::query_scalar::<_, bool>(
                "SELECT connections_ready FROM paper_processing WHERE paper_id = $1",
            )
            .bind(paper_id)
            .fetch_one(&mut **transaction)
            .await?,
        ),
    };
    let changed = match capability {
        CapabilityToPublish::Chat { model } => {
            sqlx::query(
                r"
                UPDATE paper_processing
                SET chat_ready = true,
                    embedding_model = $3,
                    stage = CASE
                        WHEN connections_ready THEN 'ready'
                        WHEN stage IN ('failed_retryable', 'failed_terminal') THEN stage
                        ELSE 'resolving_references'
                    END,
                    completed_at = CASE WHEN connections_ready THEN now() ELSE completed_at END,
                    retryable = CASE WHEN connections_ready THEN false ELSE retryable END,
                    last_error_category = CASE WHEN connections_ready THEN NULL ELSE last_error_category END,
                    last_error_code = CASE WHEN connections_ready THEN NULL ELSE last_error_code END,
                    last_error_message = CASE WHEN connections_ready THEN NULL ELSE last_error_message END,
                    updated_at = now()
                WHERE paper_id = $1 AND generation = $2
                ",
            )
            .bind(paper_id)
            .bind(generation)
            .bind(model)
            .execute(&mut **transaction)
            .await?
            .rows_affected()
        }
        CapabilityToPublish::Connections { model } => {
            sqlx::query(
                r"
                UPDATE paper_processing
                SET connections_ready = true,
                    summary_model = $3,
                    stage = CASE
                        WHEN chat_ready THEN 'ready'
                        WHEN stage IN ('failed_retryable', 'failed_terminal') THEN stage
                        ELSE 'indexing_chat'
                    END,
                    completed_at = CASE WHEN chat_ready THEN now() ELSE completed_at END,
                    retryable = CASE WHEN chat_ready THEN false ELSE retryable END,
                    last_error_category = CASE WHEN chat_ready THEN NULL ELSE last_error_category END,
                    last_error_code = CASE WHEN chat_ready THEN NULL ELSE last_error_code END,
                    last_error_message = CASE WHEN chat_ready THEN NULL ELSE last_error_message END,
                    updated_at = now()
                WHERE paper_id = $1 AND generation = $2
                ",
            )
            .bind(paper_id)
            .bind(generation)
            .bind(model)
            .execute(&mut **transaction)
            .await?
            .rows_affected()
        }
    };
    require_current_generation(changed)?;
    if was_ready {
        return Ok(None);
    }
    let transitioned_at = sqlx::query_scalar::<_, DateTime<Utc>>(
        "SELECT updated_at FROM paper_processing WHERE paper_id = $1 AND generation = $2",
    )
    .bind(paper_id)
    .bind(generation)
    .fetch_one(&mut **transaction)
    .await?;
    Ok(Some(CapabilityTransition {
        capability: capability_name,
        transitioned_at,
    }))
}

pub(super) fn observe_capability_transition(
    paper_id: PaperId,
    generation: ProcessingGeneration,
    transition: CapabilityTransition,
) {
    info!(
        metric.name = "capability_transition",
        paper_id = %paper_id,
        generation,
        capability = transition.capability,
        transition = "ready",
        transition.timestamp = %transition.transitioned_at.to_rfc3339(),
        "paper capability became ready"
    );
}
