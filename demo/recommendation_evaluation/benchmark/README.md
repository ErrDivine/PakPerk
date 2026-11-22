# Public paper-recommendation benchmark

This benchmark evaluates the current Rust recommendation builder against
established offline baselines. It changes no production scoring code. Results
measure ranking quality on a controlled candidate page, not online satisfaction,
whole-catalog retrieval, API latency, or the effect of learning from app feedback.

## Data and protocol

- Source: [CiteULike-a released for CTRSR](https://github.com/js05212/citeulike-a),
  pinned to commit `91b603922d7f2d3db18071d4798bf78c9c5d1680`.
  `dataset_manifest.json` records URLs and SHA-256 values for the three files.
  CSV item IDs are one-based; interaction and graph IDs are zero-based.
  Read raw metadata as Latin-1. The files contain 5,551 users, 16,980 papers,
  **204,986** interactions and 44,709 undirected citation edges. The release
  README reports 204,987 interactions; this benchmark uses the observed file
  counts, with no discarded interaction. The released graph is exactly symmetric.
- Train all users' interactions with per-user random 60%/20%/20% train/validation/
  test splits. Repeat with seeds 42, 43 and 44. This is not a temporal split:
  interaction/publication timestamps are unavailable.
- Select 1,000 fixed users uniformly from the 2,465 users with at least 25
  interactions, using selection seed 20261122. This ensures at least five
  validation and five test positives. Results represent these sufficiently
  active users; they do not establish new-user performance.
- Each validation/test page contains five randomly chosen held-out positives and
  45 uniformly sampled unobserved items, all without replacement. Exclude all of
  that user's known interactions from negative sampling. Shuffle page order.
  Every method receives the same page; unobserved items are evaluation negatives,
  not confirmed dislikes. This is **sampled-candidate ranking**, with 10% positive
  prevalence. Absolute scores must not be compared to full-catalog benchmarks.
- Choose hyperparameters by validation nDCG@10 only; score the test split once
  with the selected option. Public metadata and the graph are available to all
  methods as side information; interaction-derived parameters use training only.
  TF-IDF vocabulary/IDF uses the known item catalog without held-out user labels.

## Methods

| Method | Implementation/settings |
| --- | --- |
| Random | Seeded uniform random ordering |
| MostPop | Training-only item interaction counts |
| TF-IDF | Title + abstract; English stop words, sublinear TF, min_df=2, max_df=.95, 30,000 terms; normalized mean training-history profile and cosine similarity |
| ItemKNN | Binary item-vector cosine; no self-neighbors; target-neighborhood size selected from 20/50/100; score by summing the user's training interactions with those neighbors |
| PureSVD | Rank-64 randomized SVD of the binary training matrix, five power iterations; select 32 or 64 leading factors on validation; score with UΣVᵀ |
| PakPerk weighted | Actual `build_recommendation_batch`, default `weighted_v1` scoring, metadata hash embedding, historical-seed generators and diversity reranking |
| PakPerk citation (prior) | Actual `citation_online_v1`, with default learner weights .5/.5/.5, up to 10 archived roots, and the released graph; no invented relevance votes |

ItemKNN and PureSVD are established collaborative-filtering families, rather
than claims to reproduce all settings of a particular library or paper. See
[ItemKNN's reference/contract](https://recbole.io/docs/user_guide/model/general/itemknn.html),
[the original PureSVD top-N study](https://re.public.polimi.it/handle/11311/582633),
and [scikit-learn's SVD implementation](https://scikit-learn.org/1.5/modules/generated/sklearn.utils.extmath.randomized_svd.html).

## PakPerk adapter boundaries

`backend/crates/recommendations/examples/benchmark_rank.rs` calls the production
builder, rather than reproducing its score in Python. It constructs an opted-in,
proven-empty queue and an empty candidate-exposure/feedback history. Known
training bookmarks represent archived historical interests; at most 50 become
historical seeds. Their order is seeded, not a claim about recency. Citation
roots are the first 10 such seeds, all archived tier 2. The symmetric dataset
graph is mapped to reciprocal support; direction-specific performance cannot be
measured here. No OpenAlex network call is involved.

The dataset lacks real arXiv categories, author follows, save-query matches and
publication timestamps. Categories/topics/follows are empty, ages are constant,
and author/category/topic caps are raised to 50 so one `unknown` category cannot
artificially limit the output to six papers. Metadata completeness is constant.
Other weights, embedding, generators, diversity penalty and exploration positions
remain the current implementation. Candidate and output limits are 50 and 10.
This explicitly evaluates the supported history/text/graph subset of the ranking
policy, not a complete app personalization configuration. The baselines use each
user's full training history; the PakPerk history bounds are reported above.

No explicit app relevance/irrelevance feedback exists in this corpus. The
citation-policy result is therefore a **prior-weight/cold-learner** result.
Do not describe it as evidence that online learning improved recommendations.

## Metrics and uncertainty

- nDCG@10: binary relevance, gain 1 for each of five held-out bookmarks, discounted
  by `1/log2(rank+1)`, divided by the ideal five-positive ranking.
- Recall@10: held-out bookmarks retrieved / 5.
- Precision@10: retrieved positives / 10.
- MRR@10: reciprocal rank of the first positive; zero without a top-10 positive.
- HitRate@10: fraction of user pages containing at least one positive.
- Catalog coverage: distinct recommended items / 16,980, computed per split seed
  and then averaged. Coverage is descriptive, not automatically relevance.
- Intra-list diversity: mean pairwise `1 − TF-IDF cosine` within each top 10.
  This is a text-based proxy; it is not a user judgment of useful diversity.

Average each user's score over the three split seeds, then bootstrap these
1,000 user clusters 2,000 times for 95% percentile intervals. Pairwise differences
use the same resampled users. These intervals condition on the one selected user
cohort and dataset; split variability is also reported in `per_seed` results.
Comparisons are descriptive and are not corrected for multiple testing.

Timing records are local **debug-build ranking time**, excluding embedding
construction, data loading, OpenAlex, database work and transport. They are not
production HTTP latency or a fair cross-language speed comparison.

## Reproduce

From the repository root, with Python 3.12 and Rust installed:

```powershell
python -m pip install -r demo/recommendation_evaluation/benchmark/requirements.txt
python demo/recommendation_evaluation/benchmark/download.py --output .local/recommendation-benchmark-20261122/data
cd backend
cargo build --locked -p recommendations --example benchmark_rank
cd ..
python demo/recommendation_evaluation/benchmark/run.py --data .local/recommendation-benchmark-20261122/data --output .local/recommendation-benchmark-20261122/results --binary backend/target/debug/examples/benchmark_rank.exe
```

On Unix omit `.exe`. Outputs retain aggregate and per-seed metrics, validation
choices, per-user metrics, candidate/positive/ranking evidence, input hashes and
software versions. There is no API key or product-user data in the experiment.

## Exploratory cold-item slice

After the primary comparison, `cold_items.py` examines test bookmarks whose item
has **zero training interactions**, without changing candidates, models or ranks.
It reports recall of these cold positives on their original pages. Users without
any such positive are excluded from this slice. Average eligible pages per user
before bootstrapping users. This is an exploratory post-hoc analysis of the same
experiment, not a new independent test or proof about publication recency.
Its small cohort size is shown alongside the selected presentation figures.

## Frozen 100-candidate follow-up

`run_expanded.py` preserves the original 1,000 users, split seeds, five test
positives, and all 45 original negatives on every test page. It adds 50 uniform
unobserved negatives, producing 100 candidates with no production scoring change.
It compares weighted PakPerk against MostPop and a fixed direct-citation-neighbor
baseline (link count to up to 50 historical training papers; popularity breaks
ties). This is a simple seed-based graph baseline, not a reproduction of an
advanced graph recommender or commercial product. Both baselines were fixed
before the new evaluation; they have no tuned hyperparameters.

The weighted builder supports 100 candidates directly; this run does not invoke
the citation-online policy, whose page bound remains 50. No API limit is changed.
Metrics and user-cluster confidence intervals follow the earlier protocol. The
positive prevalence falls from 10% to 5%, so do not reuse absolute 50-item scores
as results of the expanded experiment. See `SETTING_AND_RESULTS_100.md` for the
observed comparison, including metrics on which PakPerk does not lead.

```powershell
python demo/recommendation_evaluation/benchmark/cold_items.py --data .local/recommendation-benchmark-20261122/data --results .local/recommendation-benchmark-20261122/results
python demo/recommendation_evaluation/benchmark/report.py --results .local/recommendation-benchmark-20261122/results --output .local/recommendation-benchmark-20261122/final
python demo/recommendation_evaluation/benchmark/strengths.py --results .local/recommendation-benchmark-20261122/results --output .local/recommendation-benchmark-20261122/final
```
