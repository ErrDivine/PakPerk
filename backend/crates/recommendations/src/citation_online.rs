use std::collections::{BTreeMap, BTreeSet};

use chrono::{DateTime, TimeDelta, Utc};
use domain::PaperId;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

use crate::{CandidateDocument, HistoricalSeedState, rerank::base_arxiv_identity};

const REFERENCE: u8 = 1;
const CITING: u8 = 2;
pub(crate) const FOLLOWED_AUTHOR: u8 = 4;
const DIRECTIONS: u8 = REFERENCE | CITING;
const FEATURES: [u8; 3] = [REFERENCE, CITING, FOLLOWED_AUTHOR];
const MAX_ROOTS: usize = 10;
const MAX_PAGE: usize = 50;
const MAX_VOTES: usize = 100;
const MAX_TITLE_BYTES: usize = 256;
const MAX_IDENTITY_BYTES: usize = 128;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CitationDirection {
    Reference,
    Citing,
    Reciprocal,
}

impl CitationDirection {
    const fn mask(self) -> u8 {
        match self {
            Self::Reference => REFERENCE,
            Self::Citing => CITING,
            Self::Reciprocal => DIRECTIONS,
        }
    }

    const fn union(self, other: Self) -> Self {
        match self.mask() | other.mask() {
            REFERENCE => Self::Reference,
            CITING => Self::Citing,
            _ => Self::Reciprocal,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CitationRoot {
    pub paper_id: PaperId,
    pub base_arxiv_id: String,
    pub title: String,
    pub state: HistoricalSeedState,
    pub tier: u8,
    pub updated_at: DateTime<Utc>,
}

impl CitationRoot {
    pub(crate) fn validate(&self) -> Result<(), CitationEvidenceError> {
        validate_root(
            self.paper_id,
            &self.base_arxiv_id,
            &self.title,
            self.state,
            self.tier,
        )
    }

    fn bounded_title(mut self) -> Self {
        if self.title.len() > MAX_TITLE_BYTES {
            let end = self.title.floor_char_boundary(MAX_TITLE_BYTES);
            self.title.truncate(end);
        }
        self
    }
}

fn validate_root(
    paper_id: PaperId,
    base_arxiv_id: &str,
    title: &str,
    state: HistoricalSeedState,
    tier: u8,
) -> Result<(), CitationEvidenceError> {
    if paper_id.is_nil()
        || base_arxiv_id.is_empty()
        || base_arxiv_id.len() > MAX_IDENTITY_BYTES
        || title.trim().is_empty()
        || title.len() > MAX_TITLE_BYTES
        || !matches!(
            (state, tier),
            (HistoricalSeedState::Reviewed, 3 | 4) | (HistoricalSeedState::Archived, 2)
        )
    {
        return Err(CitationEvidenceError::InvalidRoot);
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CitationPair {
    pub candidate_paper_id: PaperId,
    pub root: CitationRoot,
    pub direction: CitationDirection,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CitationSupport {
    pub paper_id: PaperId,
    pub base_arxiv_id: String,
    pub title: String,
    pub state: HistoricalSeedState,
    pub tier: u8,
    pub direction: CitationDirection,
}

impl From<CitationPair> for CitationSupport {
    fn from(pair: CitationPair) -> Self {
        Self {
            paper_id: pair.root.paper_id,
            base_arxiv_id: pair.root.base_arxiv_id,
            title: pair.root.title,
            state: pair.root.state,
            tier: pair.root.tier,
            direction: pair.direction,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CitationCandidateEvidence {
    pub tier: u8,
    pub feature_mask: u8,
    pub overlap: bool,
    pub learned_adjustment: f32,
    pub supporting_roots: Vec<CitationSupport>,
}

impl CitationCandidateEvidence {
    pub fn validate(&self) -> Result<(), CitationEvidenceError> {
        let mask = self.feature_mask;
        let direction_mask = mask & DIRECTIONS;
        if mask > 7
            || !self.learned_adjustment.is_finite()
            || self.learned_adjustment.abs() > centered_weight_limit(mask)
            || self.supporting_roots.len() > 2
            || self.overlap != (self.supporting_roots.len() == 2)
        {
            return Err(CitationEvidenceError::InvalidEvidence);
        }
        match self.tier {
            0 if mask == 0 && self.supporting_roots.is_empty() => {}
            1 if mask == FOLLOWED_AUTHOR && self.supporting_roots.is_empty() => {}
            2..=4 => {
                let mut bases = BTreeSet::new();
                let mut ids = BTreeSet::new();
                let mut witnessed = 0;
                if self.supporting_roots.first().map(|support| support.tier) != Some(self.tier) {
                    return Err(CitationEvidenceError::InvalidEvidence);
                }
                for support in &self.supporting_roots {
                    validate_root(
                        support.paper_id,
                        &support.base_arxiv_id,
                        &support.title,
                        support.state,
                        support.tier,
                    )?;
                    if !bases.insert(&support.base_arxiv_id)
                        || !ids.insert(support.paper_id)
                        || support.tier > self.tier
                    {
                        return Err(CitationEvidenceError::InvalidEvidence);
                    }
                    if support.tier == self.tier {
                        witnessed |= support.direction.mask();
                    }
                }
                if direction_mask != witnessed {
                    return Err(CitationEvidenceError::InvalidEvidence);
                }
            }
            _ => return Err(CitationEvidenceError::InvalidEvidence),
        }
        Ok(())
    }

    pub(crate) fn apply_author(&mut self, followed_author: bool, weights: LearnerWeights) {
        if followed_author {
            self.tier = self.tier.max(1);
            self.feature_mask |= FOLLOWED_AUTHOR;
        }
        self.learned_adjustment = weights.adjustment(self.feature_mask);
    }

    pub(crate) fn score_adjustment(&self) -> f32 {
        let overlap_bonus = if self.overlap { 0.25 } else { 0.0 };
        overlap_bonus + self.learned_adjustment
    }
}

fn centered_weight_limit(mask: u8) -> f32 {
    match mask.count_ones() {
        0 => 0.0,
        1 => 0.5,
        2 => 1.0,
        _ => 1.5,
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct CitationOnlineInputs {
    pub pairs: Vec<CitationPair>,
    pub weights: LearnerWeights,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CitationCoverage {
    pub authorized_candidate_count: usize,
    pub root_neighbor_count: usize,
    pub cap_eligible_tier_inversions: usize,
}

impl CitationOnlineInputs {
    pub(crate) fn classify(
        &self,
        documents: &[CandidateDocument],
    ) -> Result<BTreeMap<PaperId, CitationCandidateEvidence>, CitationEvidenceError> {
        if documents.len() > MAX_PAGE || self.pairs.len() > MAX_PAGE * MAX_ROOTS {
            return Err(CitationEvidenceError::InvalidPage);
        }
        let by_id = documents
            .iter()
            .map(|document| {
                (
                    document.paper.paper_id,
                    base_arxiv_identity(&document.paper.arxiv_id),
                )
            })
            .collect::<BTreeMap<_, _>>();
        if by_id.len() != documents.len() {
            return Err(CitationEvidenceError::InvalidPage);
        }

        // Keep evidence tied to the authorized document version. A second
        // version can compete during reranking, but cannot inherit its edges.
        let mut roots = BTreeMap::new();
        let mut per_candidate = BTreeMap::<PaperId, BTreeMap<String, CitationPair>>::new();
        for pair in &self.pairs {
            let candidate_base = by_id
                .get(&pair.candidate_paper_id)
                .ok_or(CitationEvidenceError::InvalidPage)?;
            let root = pair.root.clone().bounded_title();
            root.validate()?;
            if candidate_base == &root.base_arxiv_id {
                continue;
            }
            let canonical = roots
                .entry(root.base_arxiv_id.clone())
                .or_insert_with(|| root.clone());
            if canonical != &root {
                return Err(CitationEvidenceError::InvalidRoot);
            }
            per_candidate
                .entry(pair.candidate_paper_id)
                .or_default()
                .entry(root.base_arxiv_id.clone())
                .and_modify(|support| support.direction = support.direction.union(pair.direction))
                .or_insert(CitationPair {
                    root,
                    ..pair.clone()
                });
        }
        if roots.len() > MAX_ROOTS {
            return Err(CitationEvidenceError::InvalidPage);
        }
        let evidence = per_candidate
            .into_iter()
            .map(|(id, roots)| (id, classify_roots(roots.into_values().collect())))
            .collect();
        Ok(evidence)
    }
}

fn classify_roots(mut roots: Vec<CitationPair>) -> CitationCandidateEvidence {
    roots.sort_unstable_by(|left, right| {
        right
            .root
            .tier
            .cmp(&left.root.tier)
            .then_with(|| right.root.updated_at.cmp(&left.root.updated_at))
            .then_with(|| left.root.paper_id.cmp(&right.root.paper_id))
    });
    let tier = roots[0].root.tier;
    let winning_mask = roots[0].direction.mask();
    let feature_mask = roots
        .iter()
        .take_while(|support| support.root.tier == tier)
        .fold(0, |mask, support| mask | support.direction.mask());
    let overlap = roots.len() > 1;
    let second = roots
        .iter()
        .enumerate()
        .skip(1)
        .find(|(_, support)| {
            support.root.tier == tier && support.direction.mask() & !winning_mask != 0
        })
        .map_or(1, |(index, _)| index);
    if overlap {
        roots.swap(1, second);
    }
    roots.truncate(2);
    CitationCandidateEvidence {
        tier,
        feature_mask,
        overlap,
        learned_adjustment: 0.0,
        supporting_roots: roots.into_iter().map(CitationSupport::from).collect(),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LearnerVote {
    pub id: Uuid,
    pub base_arxiv_id: String,
    pub created_at: DateTime<Utc>,
    pub feature_mask: u8,
    pub relevant: bool,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LearnerWeights([f32; 3]);

impl Default for LearnerWeights {
    fn default() -> Self {
        Self([0.5; 3])
    }
}

impl LearnerWeights {
    pub fn from_votes(
        now: DateTime<Utc>,
        votes: &[LearnerVote],
    ) -> Result<Self, CitationEvidenceError> {
        let cutoff = now
            .checked_sub_signed(TimeDelta::days(180))
            .ok_or(CitationEvidenceError::InvalidVote)?;
        let mut eligible = Vec::new();
        for vote in votes {
            if vote.feature_mask > 7
                || vote.base_arxiv_id.is_empty()
                || vote.base_arxiv_id.len() > MAX_IDENTITY_BYTES
                || vote.id.is_nil()
            {
                return Err(CitationEvidenceError::InvalidVote);
            }
            if cutoff < vote.created_at && vote.created_at <= now && vote.feature_mask != 0 {
                eligible.push(vote);
            }
        }
        eligible.sort_unstable_by_key(|vote| std::cmp::Reverse((vote.created_at, vote.id)));
        let mut identities = BTreeSet::new();
        let mut positive = [0_u16; 3];
        let mut negative = [0_u16; 3];
        for vote in eligible
            .into_iter()
            .filter(|vote| identities.insert(&vote.base_arxiv_id))
            .take(MAX_VOTES)
        {
            let sixths = match vote.feature_mask.count_ones() {
                1 => 6,
                2 => 3,
                _ => 2,
            };
            let tally = if vote.relevant {
                &mut positive
            } else {
                &mut negative
            };
            for (index, feature) in FEATURES.into_iter().enumerate() {
                if vote.feature_mask & feature != 0 {
                    tally[index] += sixths;
                }
            }
        }
        Ok(Self(std::array::from_fn(|index| {
            f32::from(12 + positive[index]) / f32::from(24 + positive[index] + negative[index])
        })))
    }

    #[must_use]
    pub const fn values(self) -> [f32; 3] {
        self.0
    }

    #[must_use]
    pub fn adjustment(self, feature_mask: u8) -> f32 {
        self.0
            .into_iter()
            .zip(FEATURES)
            .filter_map(|(weight, feature)| (feature_mask & feature != 0).then_some(weight - 0.5))
            .sum()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum CitationEvidenceError {
    #[error("citation evidence uses an invalid or unauthorized page")]
    InvalidPage,
    #[error("citation evidence contains an invalid historical root")]
    InvalidRoot,
    #[error("citation candidate evidence is inconsistent")]
    InvalidEvidence,
    #[error("citation learning vote is invalid")]
    InvalidVote,
}

#[cfg(test)]
pub(crate) mod tests {
    use crate::candidates::tests::document;

    use super::*;

    fn vote(id: u128, base: &str, time: DateTime<Utc>, mask: u8, relevant: bool) -> LearnerVote {
        LearnerVote {
            id: Uuid::from_u128(id),
            base_arxiv_id: base.to_owned(),
            created_at: time,
            feature_mask: mask,
            relevant,
        }
    }

    fn assert_weights(weights: LearnerWeights, expected: [f32; 3]) {
        for (actual, expected) in weights.values().into_iter().zip(expected) {
            assert!(
                (actual - expected).abs() < 0.000_001,
                "{actual} != {expected}"
            );
        }
    }

    #[test]
    fn bounded_learner_splits_each_rating_once_and_starts_at_half() {
        let now = DateTime::UNIX_EPOCH;
        assert_weights(LearnerWeights::from_votes(now, &[]).unwrap(), [0.5; 3]);
        let weights = LearnerWeights::from_votes(
            now,
            &[
                vote(1, "2401.00001", now, 5, true),
                vote(2, "2401.00002", now, 7, false),
            ],
        )
        .unwrap();
        assert_weights(weights, [15.0 / 29.0, 12.0 / 26.0, 15.0 / 29.0]);
    }

    #[test]
    fn learner_bounds_time_and_takes_latest_trainable_per_base_before_limit() {
        let now = DateTime::UNIX_EPOCH;
        let cutoff = now - TimeDelta::days(180);
        let mut votes = (1..=99)
            .map(|id| vote(id, &format!("2401.{id:05}"), now, 1, true))
            .collect::<Vec<_>>();
        votes.extend([
            vote(100, "2401.00100", now - TimeDelta::days(1), 2, false),
            vote(
                101,
                "2401.00101",
                cutoff + TimeDelta::milliseconds(1),
                4,
                false,
            ),
            vote(102, "2401.00102", cutoff, 4, false),
            vote(103, "2401.00001", now, 1, false),
            vote(104, "2401.00002", now, 0, false),
            vote(
                105,
                "2401.00105",
                now + TimeDelta::milliseconds(1),
                4,
                false,
            ),
            vote(
                106,
                "2401.00003",
                now - TimeDelta::milliseconds(1),
                4,
                false,
            ),
        ]);
        let weights = LearnerWeights::from_votes(now, &votes).unwrap();
        assert_weights(weights, [100.0 / 103.0, 2.0 / 5.0, 0.5]);
        assert_weights(
            LearnerWeights::from_votes(now, &votes[100..=101]).unwrap(),
            [0.5, 0.5, 2.0 / 5.0],
        );
        votes.reverse();
        assert_eq!(weights, LearnerWeights::from_votes(now, &votes).unwrap());
    }

    pub(crate) fn pair(
        candidate_id: u128,
        root_id: u128,
        tier: u8,
        direction: CitationDirection,
    ) -> CitationPair {
        CitationPair {
            candidate_paper_id: PaperId::from_u128(candidate_id),
            root: CitationRoot {
                paper_id: PaperId::from_u128(root_id),
                base_arxiv_id: format!("2401.{root_id:05}"),
                title: format!("Historical root {root_id}"),
                state: if tier == 2 {
                    HistoricalSeedState::Archived
                } else {
                    HistoricalSeedState::Reviewed
                },
                tier,
                updated_at: DateTime::UNIX_EPOCH,
            },
            direction,
        }
    }

    #[test]
    fn evidence_keeps_direction_witnesses_and_counts_distinct_bases() {
        use CitationDirection::{Citing, Reference};
        let documents = [
            document(1, "cs.CL"),
            document(2, "cs.CL"),
            document(3, "cs.CL"),
        ];
        let input = CitationOnlineInputs {
            pairs: vec![
                pair(1, 20, 4, Reference),
                pair(1, 21, 4, Reference),
                pair(1, 22, 4, Citing),
                pair(1, 23, 3, Citing),
                pair(2, 20, 4, Reference),
                pair(2, 20, 4, Reference),
                pair(2, 20, 4, Citing),
                pair(3, 20, 4, Reference),
                pair(3, 23, 3, Citing),
                pair(3, 3, 4, Citing),
            ],
            ..CitationOnlineInputs::default()
        };
        let evidence = input.classify(&documents).unwrap();
        for (id, expected_mask, overlap, roots) in [
            (1, 3, true, vec![20, 22]),
            (2, 3, false, vec![20]),
            (3, 1, true, vec![20, 23]),
        ] {
            let value = &evidence[&PaperId::from_u128(id)];
            value.validate().unwrap();
            assert_eq!(value.tier, 4);
            assert_eq!(value.feature_mask, expected_mask);
            assert_eq!(value.overlap, overlap);
            assert!(
                (value.score_adjustment() - if overlap { 0.25 } else { 0.0 }).abs() < f32::EPSILON
            );
            assert_eq!(
                value
                    .supporting_roots
                    .iter()
                    .map(|support| support.paper_id.as_u128())
                    .collect::<Vec<_>>(),
                roots,
            );
        }
    }
}
