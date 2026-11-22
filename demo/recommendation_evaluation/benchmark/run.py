"""Seeded CiteULike-a comparison; invokes the actual Rust PakPerk builder.

Input data is public. No product accounts, notes, credentials or services are used.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time

for name in ('OPENBLAS_NUM_THREADS', 'OMP_NUM_THREADS', 'MKL_NUM_THREADS'):
    os.environ.setdefault(name, '4')

import numpy as np
import scipy
from scipy import sparse
import sklearn
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.preprocessing import normalize
from sklearn.utils.extmath import randomized_svd
from threadpoolctl import threadpool_limits

METRICS = ('ndcg10', 'recall10', 'precision10', 'mrr10', 'hit10', 'diversity10')
MODELS = ('Random', 'MostPop', 'TF-IDF', 'ItemKNN', 'PureSVD',
          'PakPerk weighted', 'PakPerk citation (prior)')


def ranking_metrics(order, positives):
    relevance = np.isin(order[:10], positives).astype(float)
    discounts = 1 / np.log2(np.arange(2, 12))
    dcg = np.dot(relevance, discounts[:len(relevance)])
    ideal = discounts[:min(10, len(positives))].sum()
    hit = np.flatnonzero(relevance)
    return [dcg / ideal, relevance.sum() / len(positives), relevance.sum() / 10,
            1 / (hit[0] + 1) if len(hit) else 0, float(len(hit) > 0)]


def candidate_scores(matrix, users, cases):
    return np.asarray([matrix.getrow(int(user))[:, case['candidates']].toarray()[0]
                       for user, case in zip(users, cases)])


def rank_scores(scores, cases, ties):
    return [np.array(case['candidates'])[np.lexsort((tie, -score))[:10]]
            for score, tie, case in zip(scores, ties, cases)]


def mean_ndcg(rankings, cases):
    return float(np.mean([ranking_metrics(order, case['positive'])[0]
                          for order, case in zip(rankings, cases)]))


def item_knn(interactions, kmax=100):
    item_vectors = normalize(interactions.T.tocsr(), norm='l2', axis=1)
    row_out, col_out, val_out = [], [], []
    for start in range(0, item_vectors.shape[0], 256):
        similarities = (item_vectors[start:start+256] @ item_vectors.T).tocsr()
        for offset in range(similarities.shape[0]):
            lo, hi = similarities.indptr[offset:offset+2]
            ids, values = similarities.indices[lo:hi], similarities.data[lo:hi]
            mask = (ids != start + offset) & (values > 0)
            ids, values = ids[mask], values[mask]
            # Full deterministic sort resolves a potentially large tied boundary.
            order = np.lexsort((ids, -values))[:kmax]
            row_out.extend([start + offset] * len(order))
            col_out.extend(ids[order].tolist()); val_out.extend(values[order].tolist())
    return sparse.csr_matrix((np.array(val_out, np.float32), (row_out, col_out)),
                             shape=(interactions.shape[1], interactions.shape[1]))


def prune_knn(matrix, k):
    matrix = matrix.copy()
    for row in range(matrix.shape[0]):
        lo, hi = matrix.indptr[row:row+2]
        order = np.lexsort((matrix.indices[lo:hi], -matrix.data[lo:hi]))
        matrix.data[lo + order[k:]] = 0
    matrix.eliminate_zeros()
    return matrix


def evaluate(args):
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)
    data = args.data.resolve()
    histories = []
    for line in (data / 'users.dat').read_text().splitlines():
        values = list(map(int, line.split()))
        assert values[0] == len(values) - 1
        assert len(set(values[1:])) == values[0]
        histories.append(np.array(values[1:], dtype=np.int32))
    with (data / 'raw-data.csv').open(encoding='latin-1', newline='') as stream:
        metadata = list(csv.DictReader(stream))
    assert [int(row['doc.id']) for row in metadata] == list(range(1, len(metadata)+1))
    graph = []
    for line in (data / 'citations.dat').read_text().splitlines():
        values = list(map(int, line.split())); assert values[0] == len(values)-1
        graph.append(values[1:])
    nitems = len(metadata); assert len(graph) == nitems
    assert all(0 <= i < nitems for row in histories for i in row)
    edges = {(i, j) for i, values in enumerate(graph) for j in values}
    assert all((j, i) in edges for i, j in edges)
    catalog = [{'title': row['raw.title'] or row['title'],
                'abstract_text': row['raw.abstract'], 'neighbors': neighbors}
               for row, neighbors in zip(metadata, graph)]
    eligible = np.array([i for i, row in enumerate(histories) if len(row) >= 25])
    users = np.sort(np.random.default_rng(20261122).choice(
        eligible, size=min(args.users, len(eligible)), replace=False))
    texts = [item['title'] + ' ' + item['abstract_text'] for item in catalog]
    tfidf = TfidfVectorizer(max_features=30000, min_df=2, max_df=0.95,
                            stop_words='english', sublinear_tf=True, dtype=np.float32)
    text_matrix = tfidf.fit_transform(texts)
    print(json.dumps({'stage': 'data', 'users': len(histories), 'items': nitems,
                      'interactions': sum(map(len, histories)), 'eval_users': len(users),
                      'tfidf_features': len(tfidf.vocabulary_)}), flush=True)
    all_rows, per_seed, validation, timings, audit = [], [], [], [], []
    predictions = []
    for seed in args.seeds:
        started = time.perf_counter()
        train, valid, test = [], [], []
        for user, history in enumerate(histories):
            shuffled = np.random.default_rng(np.random.SeedSequence([seed, user])).permutation(history)
            ntrain, nvalid = int(len(history)*.6), int(len(history)*.2)
            train.append(shuffled[:ntrain]); valid.append(shuffled[ntrain:ntrain+nvalid])
            test.append(shuffled[ntrain+nvalid:])
            assert not set(train[-1]) & (set(valid[-1]) | set(test[-1]))
            assert not set(valid[-1]) & set(test[-1])
        x = sparse.csr_matrix((np.ones(sum(map(len, train)), np.float32),
                               (np.repeat(np.arange(len(train)), list(map(len, train))),
                                np.concatenate(train))), shape=(len(train), nitems))
        popularity = np.asarray(x.sum(axis=0)).ravel()
        cases, ties = {}, {}
        for split, heldout in [('validation', valid), ('test', test)]:
            cases[split] = []
            for user in users:
                rng = np.random.default_rng(np.random.SeedSequence([seed, int(user), split == 'test', 917]))
                positive = rng.choice(heldout[user], 5, replace=False)
                negatives = np.setdiff1d(np.arange(nitems), histories[user])
                negative = rng.choice(negatives, 45, replace=False)
                candidates = rng.permutation(np.concatenate([positive, negative])).tolist()
                assert len(candidates) == len(set(candidates)) == 50
                assert not set(candidates) & set(train[user])
                assert set(positive) <= set(heldout[user])
                cases[split].append({'id': f'{seed}:{split}:{user}', 'history': train[user].tolist(),
                                      'candidates': candidates, 'positive': positive.tolist(),
                                      'seed': int(seed * 10000 + user)})
            ties[split] = np.random.default_rng(seed + (split == 'test') + 239).random((len(users), 50))
        rankings = {split: {} for split in cases}
        for split in cases:
            rankings[split]['Random'] = rank_scores(ties[split], cases[split], ties[split])
            pop_scores = np.array([popularity[c['candidates']] for c in cases[split]])
            rankings[split]['MostPop'] = rank_scores(pop_scores, cases[split], ties[split])
        profiles = normalize(x[users] @ text_matrix, norm='l2', axis=1)
        for split in cases:
            scores = np.array([(profiles.getrow(j) @ text_matrix[c['candidates']].T).toarray()[0]
                               for j, c in enumerate(cases[split])])
            rankings[split]['TF-IDF'] = rank_scores(scores, cases[split], ties[split])
        print(json.dumps({'seed': seed, 'stage': 'item_knn'}), flush=True)
        w100 = item_knn(x)
        knn_options = []
        for k in (20, 50, 100):
            w = prune_knn(w100, k)
            # Row j stores target j's nearest neighbors; sum their training votes.
            scores = x[users] @ w.T
            options = {}
            for split in cases:
                page_scores = candidate_scores(scores, np.arange(len(users)), cases[split])
                options[split] = rank_scores(page_scores, cases[split], ties[split])
            score = mean_ndcg(options['validation'], cases['validation'])
            validation.append({'seed': seed, 'model': 'ItemKNN', 'parameter': k, 'ndcg10': score})
            knn_options.append((score, k, options))
        _, best_k, best_knn = max(knn_options, key=lambda option: (option[0], -option[1]))
        for split in cases: rankings[split]['ItemKNN'] = best_knn[split]
        print(json.dumps({'seed': seed, 'stage': 'pure_svd', 'best_knn_k': best_k}), flush=True)
        u, singular, vt = randomized_svd(x, n_components=64, n_iter=5, random_state=seed)
        svd_options = []
        for rank in (32, 64):
            user_vectors = u[users, :rank] * singular[:rank]
            options = {}
            for split in cases:
                scores = np.array([user_vectors[j] @ vt[:rank, c['candidates']]
                                   for j, c in enumerate(cases[split])])
                options[split] = rank_scores(scores, cases[split], ties[split])
            score = mean_ndcg(options['validation'], cases['validation'])
            validation.append({'seed': seed, 'model': 'PureSVD', 'parameter': rank, 'ndcg10': score})
            svd_options.append((score, rank, options))
        _, best_rank, best_svd = max(svd_options, key=lambda option: (option[0], -option[1]))
        for split in cases: rankings[split]['PureSVD'] = best_svd[split]
        print(json.dumps({'seed': seed, 'stage': 'production_rust', 'svd_rank': best_rank}), flush=True)
        payload = {'items': catalog, 'cases': [c for split in cases for c in cases[split]]}
        raw = json.dumps(payload, ensure_ascii=False).encode('utf-8')
        audit.append({'seed': seed, 'rust_input_sha256': hashlib.sha256(raw).hexdigest(),
                      'train_interactions': int(x.nnz), 'best_itemknn_k': best_k, 'best_svd_rank': best_rank})
        result = subprocess.run([str(args.binary.resolve())], input=raw, capture_output=True, check=True)
        actual = {r['id']: r for r in map(json.loads, result.stdout.decode('utf-8').splitlines())}
        assert len(actual) == 2 * len(users)
        for split in cases:
            for model, key in [('PakPerk weighted', 'weighted'), ('PakPerk citation (prior)', 'citation')]:
                rankings[split][model] = [np.array(actual[c['id']][key]['indices']) for c in cases[split]]
        for model in MODELS:
            model_rows = []
            for user, case, order in zip(users, cases['test'], rankings['test'][model]):
                assert len(order) == len(set(order)) == 10
                assert set(order) <= set(case['candidates'])
                assert not set(order) & set(train[user])
                values = ranking_metrics(order, case['positive'])
                pairwise = (text_matrix[order] @ text_matrix[order].T).toarray()
                diversity = float(1 - pairwise[np.triu_indices(10, 1)].mean())
                row = dict(zip(METRICS, values + [diversity]), seed=seed, user=int(user), model=model)
                all_rows.append(row); model_rows.append(row)
                predictions.append({'seed': seed, 'user': int(user), 'model': model,
                                    'candidates': case['candidates'], 'positive': case['positive'],
                                    'top10': order.tolist()})
            coverage = len(set(np.concatenate(rankings['test'][model]))) / nitems
            per_seed.append({'seed': seed, 'model': model, 'coverage': coverage,
                             **{metric: float(np.mean([row[metric] for row in model_rows])) for metric in METRICS}})
        for case in cases['test']:
            for key in ['weighted', 'citation']:
                timings.append({'seed': seed, 'case': case['id'], 'policy': key,
                                **{k: v for k, v in actual[case['id']][key].items() if k != 'indices'}})
        audit[-1]['elapsed_seconds'] = round(time.perf_counter()-started, 3)
        print(json.dumps({'seed': seed, 'stage': 'done', **audit[-1]}), flush=True)
        del x, w100, w, scores, u, vt, profiles, raw, payload, actual, knn_options, svd_options
    bootstrap = np.random.default_rng(20261122).integers(0, len(users), size=(2000, len(users)))
    arrays, summary = {}, []
    for model in MODELS:
        by_user = {int(user): [] for user in users}
        for row in all_rows:
            if row['model'] == model:
                by_user[row['user']].append([row[metric] for metric in METRICS])
        grouped = np.array([np.mean(by_user[int(user)], axis=0) for user in users])
        arrays[model] = grouped
        entry = {'model': model, 'coverage': float(np.mean([r['coverage'] for r in per_seed if r['model'] == model]))}
        for j, metric in enumerate(METRICS):
            samples = grouped[:, j][bootstrap].mean(axis=1)
            lo, hi = np.percentile(samples, [2.5, 97.5])
            entry[metric] = {'mean': float(grouped[:, j].mean()), 'lo': float(lo), 'hi': float(hi)}
        summary.append(entry)
    paired = []
    for baseline in MODELS:
        if baseline == 'PakPerk citation (prior)': continue
        diff = arrays['PakPerk citation (prior)'][:, 0] - arrays[baseline][:, 0]
        lo, hi = np.percentile(diff[bootstrap].mean(axis=1), [2.5, 97.5])
        paired.append({'comparison': 'PakPerk citation (prior) minus '+baseline,
                       'ndcg10_difference': float(diff.mean()), 'lo': float(lo), 'hi': float(hi)})
    configuration = {'source_revision': subprocess.check_output(['git','rev-parse','HEAD']).decode().strip(),
                     'seeds': args.seeds, 'eval_users': len(users), 'eligible_users': len(eligible),
                     'dataset_users': len(histories), 'dataset_items': nitems,
                     'dataset_interactions': sum(map(len, histories)), 'unique_citation_edges': len(edges)//2,
                     'split': 'per-user random 60/20/20; min 25 interactions for evaluation',
                     'candidate_page': '5 held-out positives + 45 uniformly sampled noninteractions, without replacement',
                     'selection': '1000 fixed users sampled using seed 20261122; all users used for training',
                     'bootstrap': '2000 user-cluster bootstrap resamples after averaging the three split seeds',
                     'python': platform.python_version(), 'numpy': np.__version__,
                     'scipy': scipy.__version__, 'sklearn': sklearn.__version__, 'platform': platform.platform(),
                     'tfidf_features': len(tfidf.vocabulary_), 'audit': audit,
                     'data_manifest': json.loads((data/'manifest.json').read_text())}
    (output/'results.json').write_text(json.dumps({'configuration': configuration, 'summary': summary,
                                                 'paired_ndcg': paired, 'per_seed': per_seed}, indent=2), encoding='utf-8')
    for filename, rows in [('per_user.csv', all_rows), ('validation.csv', validation), ('timing.csv', timings)]:
        with (output/filename).open('w', newline='', encoding='utf-8') as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0])); writer.writeheader(); writer.writerows(rows)
    with (output/'predictions.jsonl').open('w', encoding='utf-8') as stream:
        for row in predictions: stream.write(json.dumps(row)+'\n')
    print(json.dumps({'stage': 'complete', 'summary': summary, 'paired': paired}), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--users', type=int, default=1000)
    parser.add_argument('--seeds', type=int, nargs='+', default=[42,43,44])
    with threadpool_limits(limits=4):
        evaluate(parser.parse_args())
