//! Bounded source reads. The request, not model arguments, owns authorization.

use domain::{AssistantObjectKind, AssistantOutlineEntry, AssistantTool};
use serde::Serialize;
use serde_json::Value;

use super::{
    AssistantContextRepository, AssistantRequest, AssistantScopeKind, DbError, FromRow, Postgres,
    QueryBuilder, Uuid, section_kind_name,
};

#[derive(Clone, Serialize)]
pub struct AssistantToolSource {
    pub block_id: Uuid,
    pub paper_id: Uuid,
    pub generation: i32,
    pub section_heading: Option<String>,
    pub page_start: Option<u32>,
    /// None means text was withheld because of a block or cumulative evidence budget.
    pub text: Option<String>,
    pub references: Value,
}

#[derive(Clone, Serialize)]
pub struct AssistantToolRead {
    pub status: &'static str,
    pub truncated: bool,
    pub sources: Vec<AssistantToolSource>,
    pub object_status: Option<String>,
    /// For range reads: the block that follows the last one returned, so the
    /// model can continue reading in order.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub next_block_id: Option<Uuid>,
}

impl AssistantContextRepository {
    #[allow(clippy::too_many_lines)]
    pub async fn execute_tool(
        &self,
        request: &AssistantRequest,
        tool: &AssistantTool,
    ) -> Result<AssistantToolRead, DbError> {
        request.validate().map_err(|_| tool_scope_error())?;
        if !tool.is_valid() {
            return Err(tool_scope_error());
        }
        let mut transaction = self.pool.begin().await?;
        sqlx::query("SET LOCAL statement_timeout = '2000ms'")
            .execute(&mut *transaction)
            .await?;
        // Pin generation for the bounded database operation, never across LLM work.
        let current = sqlx::query_scalar::<_, i32>(
            "SELECT processing.generation FROM paper_processing processing
             JOIN document_generations document ON document.paper_id = processing.paper_id
               AND document.generation = processing.generation
             WHERE processing.paper_id = $1 FOR SHARE OF processing",
        )
        .bind(request.paper_id)
        .fetch_optional(&mut *transaction)
        .await?;
        if current != Some(request.generation) {
            return Err(DbError::AssistantContextNotReady);
        }

        if let Some(selection) = &request.scope.selection {
            let length = sqlx::query_scalar::<_, i32>(
                "SELECT char_length(text) FROM document_blocks
                 WHERE id = $1 AND paper_id = $2 AND generation = $3",
            )
            .bind(selection.block_id)
            .bind(request.paper_id)
            .bind(request.generation)
            .fetch_optional(&mut *transaction)
            .await?;
            if length.is_none_or(|length| i64::from(selection.end) > i64::from(length)) {
                return Err(tool_scope_error());
            }
        }

        if let AssistantTool::ReadPaperBlocks(args) = tool {
            let mut check = scoped_query(request);
            check
                .push(" SELECT id FROM scoped WHERE id = ANY(")
                .push_bind(args.block_ids.clone())
                .push(")");
            let ids = check
                .build_query_scalar::<Uuid>()
                .fetch_all(&mut *transaction)
                .await?;
            if ids.len() != args.block_ids.len() {
                return Err(tool_scope_error());
            }
        }
        if let AssistantTool::ReadPaperRange(args) = tool {
            let mut check = scoped_query(request);
            check
                .push(" SELECT id FROM scoped WHERE id = ")
                .push_bind(args.start_block_id);
            if check
                .build_query_scalar::<Uuid>()
                .fetch_optional(&mut *transaction)
                .await?
                .is_none()
            {
                return Err(tool_scope_error());
            }
        }
        let object_status = if let AssistantTool::GetObjectEvidence(args) = tool {
            let (table, status) = match args.kind {
                AssistantObjectKind::Figure => ("paper_figures", "extraction_status"),
                AssistantObjectKind::Table => ("paper_tables", "extraction_status"),
                AssistantObjectKind::Equation => ("paper_equations", "confidence_status"),
            };
            let mut query = QueryBuilder::<Postgres>::new("SELECT ");
            query
                .push(status)
                .push(" FROM ")
                .push(table)
                .push(" WHERE id = ")
                .push_bind(args.object_id)
                .push(" AND paper_id = ")
                .push_bind(request.paper_id)
                .push(" AND generation = ")
                .push_bind(request.generation);
            Some(
                query
                    .build_query_scalar::<String>()
                    .fetch_optional(&mut *transaction)
                    .await?
                    .ok_or_else(tool_scope_error)?,
            )
        } else {
            None
        };
        if let AssistantTool::GetCitationContext(args) = tool {
            let exists = sqlx::query_scalar::<_, bool>(
                "SELECT EXISTS(SELECT 1 FROM paper_references WHERE id = $1 AND citing_paper_id = $2 AND generation = $3)",
            ).bind(args.reference_id).bind(request.paper_id).bind(request.generation)
                .fetch_one(&mut *transaction).await?;
            if !exists {
                return Err(tool_scope_error());
            }
        }
        let mut query = scoped_query(request);
        query.push(" SELECT block.id AS block_id, block.paper_id, block.generation,
            COALESCE(CASE WHEN ").push_bind(request.scope.kind == AssistantScopeKind::Section).push(" THEN section.heading END, NULLIF(block.section_path[array_length(block.section_path, 1)], '')) AS section_heading,
            block.page_start,
            CASE WHEN char_length(block.text) <= 20000 THEN block.text END AS text,
            COALESCE((SELECT jsonb_agg(ref.value) FROM
                (SELECT jsonb_build_object('kind', span->>'kind', 'target_id', span->>'target_id') AS value
                 FROM jsonb_array_elements(block.inline_spans) span
                 WHERE span->>'target_id' IS NOT NULL LIMIT 16) ref), '[]'::jsonb) AS references
            FROM scoped block LEFT JOIN paper_sections section
              ON section.id = block.section_id AND section.paper_id = block.paper_id
              AND section.generation = block.generation WHERE true");
        let limit = match tool {
            AssistantTool::SearchPaperEvidence(args) => {
                if !args.section_kinds.is_empty() {
                    query
                        .push(" AND section.kind = ANY(")
                        .push_bind(
                            args.section_kinds
                                .iter()
                                .copied()
                                .map(section_kind_name)
                                .collect::<Vec<_>>(),
                        )
                        .push(")");
                }
                // Any content word may match (stemmed, stop words ignored); blocks
                // that contain all of them rank first. Headings are left out: the
                // outline lists them and the paragraph below one matches on its
                // own. A query without usable words matches nothing.
                let any_words = super::keyword_query(&args.query);
                if any_words.is_empty() {
                    query.push(" AND false");
                } else {
                    let all_words = any_words.replace(" | ", " & ");
                    query
                        .push(" AND block.kind <> 'heading' AND to_tsvector('english', block.text) @@ to_tsquery('english', ")
                        .push_bind(any_words.clone())
                        .push(") ORDER BY (to_tsvector('english', block.text) @@ to_tsquery('english', ")
                        .push_bind(all_words)
                        .push(")) DESC, ts_rank(to_tsvector('english', block.text), to_tsquery('english', ")
                        .push_bind(any_words)
                        .push("), 1) DESC, block.ordinal");
                }
                args.limit
            }
            AssistantTool::GetPaperOutline(args) => {
                if !matches!(
                    request.scope.kind,
                    AssistantScopeKind::Paper | AssistantScopeKind::Section
                ) {
                    return Err(tool_scope_error());
                }
                query.push(" AND block.kind = 'heading' ORDER BY block.ordinal");
                args.limit
            }
            AssistantTool::ReadPaperBlocks(args) => {
                query
                    .push(" AND EXISTS (SELECT 1 FROM scoped anchor WHERE anchor.id = ANY(")
                    .push_bind(args.block_ids.clone())
                    .push(") AND abs(block.ordinal::bigint - anchor.ordinal::bigint) <= ")
                    .push_bind(i64::from(args.neighbors))
                    .push(") ORDER BY (block.id = ANY(")
                    .push_bind(args.block_ids.clone())
                    .push(")) DESC, block.ordinal");
                6
            }
            AssistantTool::ReadPaperRange(args) => {
                query
                    .push(" AND block.ordinal >= (SELECT anchor.ordinal FROM scoped anchor WHERE anchor.id = ")
                    .push_bind(args.start_block_id)
                    .push(") ORDER BY block.ordinal");
                args.count
            }
            AssistantTool::GetObjectEvidence(args) => {
                query.push(" AND (");
                push_target(
                    &mut query,
                    args.object_id,
                    match args.kind {
                        AssistantObjectKind::Figure => "figure_reference",
                        AssistantObjectKind::Table => "table_reference",
                        AssistantObjectKind::Equation => "equation_reference",
                    },
                );
                if args.kind == AssistantObjectKind::Equation {
                    query.push(" OR block.id IN (SELECT context_block_id FROM paper_equations WHERE id = ")
                        .push_bind(args.object_id).push(" AND paper_id = block.paper_id AND generation = block.generation)");
                }
                query.push(") ORDER BY block.ordinal");
                6
            }
            AssistantTool::GetCitationContext(args) => {
                query.push(" AND ");
                push_target(&mut query, args.reference_id, "bibliography_reference");
                query.push(" ORDER BY block.ordinal");
                args.limit
            }
        };
        query.push(" LIMIT ").push_bind(i64::from(limit) + 1);
        let mut rows = query
            .build_query_as::<ToolSourceRow>()
            .fetch_all(&mut *transaction)
            .await?;
        let truncated = rows.len() > limit as usize;
        let next_block_id = if matches!(tool, AssistantTool::ReadPaperRange(_)) {
            rows.get(limit as usize).map(|row| row.block_id)
        } else {
            None
        };
        rows.truncate(limit as usize);
        // Do not disclose out-of-scope object metadata even when its UUID exists.
        if object_status.is_some() && rows.is_empty() {
            transaction.commit().await?;
            return Ok(AssistantToolRead {
                status: "no_matches",
                truncated: false,
                sources: vec![],
                object_status: None,
                next_block_id: None,
            });
        }
        let sources = rows
            .into_iter()
            .map(ToolSourceRow::into_source)
            .collect::<Result<Vec<_>, _>>()?;
        let status = if sources.is_empty() {
            "no_matches"
        } else if sources.iter().all(|source| source.text.is_none()) {
            "content_too_large"
        } else {
            "ok"
        };
        transaction.commit().await?;
        Ok(AssistantToolRead {
            status,
            truncated,
            sources,
            object_status,
            next_block_id,
        })
    }
}

#[derive(FromRow)]
struct OutlineRow {
    first_block_id: Uuid,
    heading: Option<String>,
    kind: String,
    blocks: i32,
    chars: i32,
}

impl AssistantContextRepository {
    /// Sections of the authorized scope with the id of each one's first block and
    /// its size, in reading order. It is shown to the model before the first
    /// tool step so navigation does not cost a call. Sections that hold only
    /// headings or footnotes are left out; footnotes stay reachable by search.
    /// Only paper and section scopes have an outline.
    pub async fn outline(
        &self,
        request: &AssistantRequest,
    ) -> Result<Vec<AssistantOutlineEntry>, DbError> {
        request.validate().map_err(|_| tool_scope_error())?;
        if !matches!(
            request.scope.kind,
            AssistantScopeKind::Paper | AssistantScopeKind::Section
        ) {
            return Ok(vec![]);
        }
        let mut transaction = self.pool.begin().await?;
        sqlx::query("SET LOCAL statement_timeout = '2000ms'")
            .execute(&mut *transaction)
            .await?;
        let mut query = scoped_query(request);
        query.push(
            " SELECT (array_agg(block.id ORDER BY block.ordinal))[1] AS first_block_id,
                section.heading AS heading,
                section.kind AS kind,
                (count(*) FILTER (WHERE block.kind NOT IN ('heading', 'footnote')))::int AS blocks,
                (COALESCE(sum(char_length(block.text)) FILTER (WHERE block.kind NOT IN ('heading', 'footnote')), 0))::int AS chars
            FROM scoped block
            JOIN paper_sections section
              ON section.id = block.section_id
             AND section.paper_id = block.paper_id
             AND section.generation = block.generation
            GROUP BY section.id, section.heading, section.kind
            HAVING count(*) FILTER (WHERE block.kind NOT IN ('heading', 'footnote')) > 0
            ORDER BY min(block.ordinal)
            LIMIT 60",
        );
        let rows = query
            .build_query_as::<OutlineRow>()
            .fetch_all(&mut *transaction)
            .await?;
        transaction.commit().await?;
        rows.into_iter()
            .map(|row| {
                Ok(AssistantOutlineEntry {
                    first_block_id: row.first_block_id,
                    heading: row.heading,
                    kind: row.kind,
                    blocks: u32::try_from(row.blocks).map_err(|_| tool_scope_error())?,
                    chars: u32::try_from(row.chars).map_err(|_| tool_scope_error())?,
                })
            })
            .collect()
    }
}

fn tool_scope_error() -> DbError {
    DbError::InvalidData("assistant tool arguments or scope are invalid".into())
}

fn push_target(query: &mut QueryBuilder<'_, Postgres>, id: Uuid, kind: &'static str) {
    query.push("EXISTS (SELECT 1 FROM jsonb_array_elements(block.inline_spans) span WHERE span->>'target_id' = ")
        .push_bind(id.to_string()).push(" AND span->>'kind' = ").push_bind(kind).push(")");
}

fn scoped_query(request: &AssistantRequest) -> QueryBuilder<'static, Postgres> {
    let mut query = QueryBuilder::new(
        "WITH scoped AS (SELECT block.* FROM document_blocks block WHERE block.paper_id = ",
    );
    query
        .push_bind(request.paper_id)
        .push(" AND block.generation = ")
        .push_bind(request.generation);
    match request.scope.kind {
        AssistantScopeKind::Paper => {}
        AssistantScopeKind::Section => {
            query.push(" AND block.section_id IN (SELECT id FROM paper_sections WHERE paper_id = block.paper_id AND generation = block.generation AND kind = ANY(")
                .push_bind(request.scope.section_kinds.iter().copied().map(section_kind_name).collect::<Vec<_>>()).push("))");
        }
        AssistantScopeKind::Selection => {
            query.push(" AND block.id = ").push_bind(
                request
                    .scope
                    .selection
                    .as_ref()
                    .map(|selection| selection.block_id),
            );
        }
        AssistantScopeKind::PassportField => {
            query.push(" AND block.id IN (SELECT unnest(field.source_block_ids) FROM paper_passport_fields field
                JOIN paper_passports passport ON passport.id = field.passport_id AND passport.paper_id = field.paper_id AND passport.generation = field.generation
                WHERE field.paper_id = block.paper_id AND field.generation = block.generation
                AND passport.superseded_at IS NULL AND passport.status IN ('ready', 'partial')
                AND field.status IN ('supported', 'inferred', 'conflicting') AND field.field_key = ")
                .push_bind(request.scope.passport_field.clone()).push(")");
        }
        AssistantScopeKind::Figure | AssistantScopeKind::Table | AssistantScopeKind::Equation => {
            let (table, span_kind) = match request.scope.kind {
                AssistantScopeKind::Figure => ("paper_figures", "figure_reference"),
                AssistantScopeKind::Table => ("paper_tables", "table_reference"),
                _ => ("paper_equations", "equation_reference"),
            };
            query.push(" AND (SELECT count(*) FROM ").push(table)
                .push(" WHERE paper_id = block.paper_id AND generation = block.generation AND id = ANY(")
                .push_bind(request.scope.object_ids.clone()).push(")) = ")
                .push_bind(i64::try_from(request.scope.object_ids.len()).unwrap_or(i64::MAX));
            query.push(" AND (EXISTS (SELECT 1 FROM jsonb_array_elements(block.inline_spans) span WHERE span->>'target_id' = ANY(")
                .push_bind(request.scope.object_ids.iter().map(Uuid::to_string).collect::<Vec<_>>()).push(") AND span->>'kind' = ")
                .push_bind(span_kind).push(")");
            if request.scope.kind == AssistantScopeKind::Equation {
                query.push(" OR block.id IN (SELECT context_block_id FROM paper_equations WHERE paper_id = block.paper_id AND generation = block.generation AND id = ANY(")
                    .push_bind(request.scope.object_ids.clone()).push("))");
            }
            query.push(")");
        }
    }
    query.push(")");
    query
}

#[derive(FromRow)]
struct ToolSourceRow {
    block_id: Uuid,
    paper_id: Uuid,
    generation: i32,
    section_heading: Option<String>,
    page_start: Option<i32>,
    text: Option<String>,
    references: Value,
}

impl ToolSourceRow {
    fn into_source(self) -> Result<AssistantToolSource, DbError> {
        Ok(AssistantToolSource {
            block_id: self.block_id,
            paper_id: self.paper_id,
            generation: self.generation,
            section_heading: self.section_heading,
            page_start: self
                .page_start
                .map(u32::try_from)
                .transpose()
                .map_err(|_| tool_scope_error())?,
            text: self.text,
            references: self.references,
        })
    }
}
