use std::collections::BTreeMap;

use chrono::{DateTime, Days, Utc};
use domain::{AuthenticatedUserId, PaperId};
use recommendations::{
    CitationDirection, CitationOnlineInputs, CitationPair, CitationRoot, HistoricalSeed,
    HistoricalSeedState, LearnerVote, LearnerWeights,
};
use sqlx::{FromRow, Postgres, Transaction};
use uuid::Uuid;

use super::{
    RecommendationBatchRepository, RecommendationBatchRepositoryError,
    RecommendationFeedbackContext, begin_consistent_read, load_feedback_context,
    load_historical_seeds, valid_page_ids,
};

#[derive(Debug, Clone)]
pub struct RecommendationCitationLearningContext {
    pub library_revision: i64,
    pub profile_revision: Option<i64>,
    pub personalization_enabled: bool,
    pub feedback: RecommendationFeedbackContext,
    pub historical_seeds: Vec<HistoricalSeed>,
    pub citation: CitationOnlineInputs,
    pub openalex_roots: Vec<(CitationRoot, Option<String>)>,
    pub openalex_candidates: Vec<RecommendationCitationPaper>,
}

#[derive(Debug, Clone, FromRow)]
pub struct RecommendationCitationPaper {
    pub paper_id: PaperId,
    pub base_arxiv_id: String,
    pub doi: Option<String>,
}

impl RecommendationBatchRepository {
    /// Reads the ranking evidence and its fences from one committed database
    /// view. Inputs from a different authorized page cannot reuse these fences.
    pub async fn citation_learning_context(
        &self,
        user_id: AuthenticatedUserId,
        paper_ids: &[PaperId],
        observed_at: DateTime<Utc>,
    ) -> Result<RecommendationCitationLearningContext, RecommendationBatchRepositoryError> {
        self.read_citation_learning_context(user_id, paper_ids, observed_at, false)
            .await
    }

    /// Includes public identifiers for the ranked roots and supplied page.
    pub async fn citation_learning_context_with_openalex(
        &self,
        user_id: AuthenticatedUserId,
        paper_ids: &[PaperId],
        observed_at: DateTime<Utc>,
    ) -> Result<RecommendationCitationLearningContext, RecommendationBatchRepositoryError> {
        self.read_citation_learning_context(user_id, paper_ids, observed_at, true)
            .await
    }

    async fn read_citation_learning_context(
        &self,
        user_id: AuthenticatedUserId,
        paper_ids: &[PaperId],
        observed_at: DateTime<Utc>,
        include_openalex: bool,
    ) -> Result<RecommendationCitationLearningContext, RecommendationBatchRepositoryError> {
        if !valid_page_ids(paper_ids, 50) {
            return Err(RecommendationBatchRepositoryError::InvalidRequest);
        }
        let mut transaction = begin_consistent_read(&self.pool).await?;
        let Some(fence) = sqlx::query_as::<_, LearningFenceRow>(
            r"
            SELECT account.status,
                   COALESCE(library.current_revision, 0) AS library_revision,
                   profile.profile_revision,
                   profile.personalization_enabled IS TRUE AS personalization_enabled
            FROM users AS account
            LEFT JOIN library_sync_metadata AS library ON library.user_id = account.id
            LEFT JOIN research_profiles AS profile ON profile.user_id = account.id
            WHERE account.id = $1
            ",
        )
        .bind(user_id.into_inner())
        .fetch_optional(&mut *transaction)
        .await?
        else {
            return Err(RecommendationBatchRepositoryError::AccountNotFound);
        };
        if fence.status != "active" {
            return Err(RecommendationBatchRepositoryError::AccountUnavailable);
        }
        if fence.library_revision < 0 || fence.profile_revision.is_some_and(|value| value <= 0) {
            return Err(RecommendationBatchRepositoryError::InvalidPersistedData);
        }
        let feedback =
            load_feedback_context(&mut transaction, user_id, paper_ids, observed_at).await?;
        let mut context = RecommendationCitationLearningContext {
            library_revision: fence.library_revision,
            profile_revision: fence.profile_revision,
            personalization_enabled: fence.personalization_enabled,
            feedback,
            historical_seeds: Vec::new(),
            citation: CitationOnlineInputs::default(),
            openalex_roots: Vec::new(),
            openalex_candidates: Vec::new(),
        };
        if fence.personalization_enabled {
            context.historical_seeds =
                load_historical_seeds(&mut *transaction, user_id, 50).await?;
            if !paper_ids.is_empty() {
                let roots = sqlx::query_as::<_, RootRow>(SELECT_ROOTS)
                    .bind(user_id.into_inner())
                    .fetch_all(&mut *transaction)
                    .await?
                    .into_iter()
                    .map(RootRow::into_root)
                    .collect::<Result<Vec<_>, _>>()?;
                if !roots.is_empty() {
                    context.citation.pairs =
                        load_pairs(&mut transaction, &roots, paper_ids).await?;
                    if include_openalex {
                        context.openalex_candidates =
                            sqlx::query_as::<_, RecommendationCitationPaper>(SELECT_CANDIDATES)
                                .bind(paper_ids)
                                .fetch_all(&mut *transaction)
                                .await?;
                        context.openalex_roots = roots;
                    }
                }
            }
            context.citation.weights = load_weights(&mut transaction, user_id, observed_at).await?;
        }
        transaction.commit().await?;
        Ok(context)
    }
}

#[derive(FromRow)]
struct LearningFenceRow {
    status: String,
    library_revision: i64,
    profile_revision: Option<i64>,
    personalization_enabled: bool,
}

const SELECT_ROOTS: &str = r"
    WITH retained_feedback AS (
        SELECT paper.arxiv_base_id,
               bool_or(feedback.feedback_type IN ('not_relevant', 'dismissed')) AS veto,
               bool_or(feedback.feedback_type = 'relevant' AND feedback.feature_mask IS NOT NULL)
                   AS promoted
        FROM recommendation_feedback AS feedback
        JOIN papers AS paper ON paper.id = feedback.paper_id
        WHERE feedback.user_id = $1
        GROUP BY paper.arxiv_base_id
    ),
    eligible AS (
        SELECT paper.id AS paper_id, paper.arxiv_base_id, paper.doi,
               left(paper.title, 160) AS title, library.state, library.updated_at,
               CASE
                   WHEN library.state = 'reviewed' AND feedback.promoted THEN 4
                   WHEN library.state = 'reviewed' THEN 3
                   ELSE 2
               END AS tier
        FROM user_paper_library AS library
        JOIN papers AS paper ON paper.id = library.paper_id
        LEFT JOIN retained_feedback AS feedback ON feedback.arxiv_base_id = paper.arxiv_base_id
        WHERE library.user_id = $1
          AND library.removed_at IS NULL
          AND NOT COALESCE(feedback.veto, false)
          AND (library.state = 'reviewed' OR (library.state = 'archived' AND feedback.promoted))
    ),
    representatives AS (
        SELECT DISTINCT ON (arxiv_base_id) *
        FROM eligible
        ORDER BY arxiv_base_id, tier DESC, updated_at DESC, paper_id ASC
    )
    SELECT paper_id, arxiv_base_id, doi, title, state, updated_at, tier
    FROM representatives
    ORDER BY tier DESC, updated_at DESC, paper_id ASC
    LIMIT 10
";

const SELECT_CANDIDATES: &str = r"
    SELECT paper.id AS paper_id, paper.arxiv_base_id AS base_arxiv_id, paper.doi
    FROM unnest($1::uuid[]) WITH ORDINALITY AS page(paper_id, position)
    JOIN papers AS paper ON paper.id = page.paper_id
    ORDER BY page.position
";

const SELECT_PAIRS: &str = r"
    WITH directional_edges AS (
        SELECT connection.cited_paper_id AS candidate_paper_id,
               connection.citing_paper_id AS root_paper_id,
               true AS reference, false AS citing
        FROM paper_connections AS connection
        JOIN paper_processing AS processing
          ON processing.paper_id = connection.citing_paper_id
         AND processing.generation = connection.generation
        WHERE connection.citing_paper_id = ANY($1)
          AND connection.cited_paper_id = ANY($2)
        UNION ALL
        SELECT connection.citing_paper_id AS candidate_paper_id,
               connection.cited_paper_id AS root_paper_id,
               false AS reference, true AS citing
        FROM paper_connections AS connection
        JOIN paper_processing AS processing
          ON processing.paper_id = connection.citing_paper_id
         AND processing.generation = connection.generation
        WHERE connection.citing_paper_id = ANY($2)
          AND connection.cited_paper_id = ANY($1)
    )
    SELECT candidate_paper_id, root_paper_id,
           bool_or(reference) AS reference,
           bool_or(citing) AS citing
    FROM directional_edges
    WHERE candidate_paper_id <> root_paper_id
    GROUP BY candidate_paper_id, root_paper_id
    ORDER BY candidate_paper_id, root_paper_id
";

async fn load_pairs(
    transaction: &mut Transaction<'_, Postgres>,
    roots: &[(CitationRoot, Option<String>)],
    paper_ids: &[PaperId],
) -> Result<Vec<CitationPair>, RecommendationBatchRepositoryError> {
    let roots = roots
        .iter()
        .map(|(root, _)| (root.paper_id, root))
        .collect::<BTreeMap<_, _>>();

    // The papers table has a unique base arXiv identity, making grouping on
    // the exact paired IDs equivalent to grouping on the bases. The root
    // and page predicates both apply before either branch yields any edges.
    let edges = sqlx::query_as::<_, PairRow>(SELECT_PAIRS)
        .bind(roots.keys().copied().collect::<Vec<_>>())
        .bind(paper_ids)
        .fetch_all(&mut **transaction)
        .await?;
    edges
        .into_iter()
        .map(|edge| {
            let direction = match (edge.reference, edge.citing) {
                (true, true) => CitationDirection::Reciprocal,
                (true, false) => CitationDirection::Reference,
                (false, true) => CitationDirection::Citing,
                (false, false) => {
                    return Err(RecommendationBatchRepositoryError::InvalidPersistedData);
                }
            };
            let root = roots
                .get(&edge.root_paper_id)
                .copied()
                .ok_or(RecommendationBatchRepositoryError::InvalidPersistedData)?;
            Ok(CitationPair {
                candidate_paper_id: edge.candidate_paper_id,
                root: root.clone(),
                direction,
            })
        })
        .collect()
}

#[derive(FromRow)]
struct RootRow {
    paper_id: Uuid,
    arxiv_base_id: String,
    doi: Option<String>,
    title: String,
    state: String,
    updated_at: DateTime<Utc>,
    tier: i32,
}

impl RootRow {
    fn into_root(
        self,
    ) -> Result<(CitationRoot, Option<String>), RecommendationBatchRepositoryError> {
        let tier = u8::try_from(self.tier)
            .map_err(|_| RecommendationBatchRepositoryError::InvalidPersistedData)?;
        let state = match self.state.as_str() {
            "reviewed" => HistoricalSeedState::Reviewed,
            "archived" => HistoricalSeedState::Archived,
            _ => return Err(RecommendationBatchRepositoryError::InvalidPersistedData),
        };
        Ok((
            CitationRoot {
                paper_id: self.paper_id,
                base_arxiv_id: self.arxiv_base_id,
                title: self.title.trim().to_owned(),
                updated_at: self.updated_at,
                tier,
                state,
            },
            self.doi,
        ))
    }
}

#[derive(FromRow)]
struct PairRow {
    candidate_paper_id: Uuid,
    root_paper_id: Uuid,
    reference: bool,
    citing: bool,
}

async fn load_weights(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    observed_at: DateTime<Utc>,
) -> Result<LearnerWeights, RecommendationBatchRepositoryError> {
    let oldest = observed_at
        .checked_sub_days(Days::new(180))
        .ok_or(RecommendationBatchRepositoryError::InvalidRequest)?;
    let votes = sqlx::query_as::<_, VoteRow>(
        r"
        WITH latest_per_base AS (
            SELECT DISTINCT ON (paper.arxiv_base_id)
                   feedback.id, paper.arxiv_base_id, feedback.created_at,
                   feedback.feature_mask, feedback.feedback_type = 'relevant' AS relevant
            FROM recommendation_feedback AS feedback
            JOIN papers AS paper ON paper.id = feedback.paper_id
            WHERE feedback.user_id = $1
              AND feedback.created_at > $2 AND feedback.created_at <= $3
              AND feedback.feature_mask > 0
              AND feedback.feedback_type IN ('relevant', 'not_relevant')
            ORDER BY paper.arxiv_base_id, feedback.created_at DESC, feedback.id DESC
        )
        SELECT id, arxiv_base_id, created_at, feature_mask, relevant
        FROM latest_per_base
        ORDER BY created_at DESC, id DESC
        LIMIT 100
        ",
    )
    .bind(user_id.into_inner())
    .bind(oldest)
    .bind(observed_at)
    .fetch_all(&mut **transaction)
    .await?
    .into_iter()
    .map(LearnerVote::try_from)
    .collect::<Result<Vec<_>, _>>()?;
    LearnerWeights::from_votes(observed_at, &votes)
        .map_err(|_| RecommendationBatchRepositoryError::InvalidPersistedData)
}

#[derive(FromRow)]
struct VoteRow {
    id: Uuid,
    arxiv_base_id: String,
    created_at: DateTime<Utc>,
    feature_mask: i16,
    relevant: bool,
}

impl TryFrom<VoteRow> for LearnerVote {
    type Error = RecommendationBatchRepositoryError;

    fn try_from(row: VoteRow) -> Result<Self, Self::Error> {
        Ok(Self {
            id: row.id,
            base_arxiv_id: row.arxiv_base_id,
            created_at: row.created_at,
            feature_mask: u8::try_from(row.feature_mask)
                .map_err(|_| Self::Error::InvalidPersistedData)?,
            relevant: row.relevant,
        })
    }
}
