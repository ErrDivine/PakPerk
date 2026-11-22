"""Exploratory cold-item slice of the completed, unchanged benchmark rankings."""
import argparse
import json
from pathlib import Path

import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument('--data', type=Path, required=True)
parser.add_argument('--results', type=Path, required=True)
args = parser.parse_args()
result = json.loads((args.results/'results.json').read_text())
config = result['configuration']
histories = [np.array(list(map(int, line.split()))[1:])
             for line in (args.data/'users.dat').read_text().splitlines()]
popularity = {}
for seed in config['seeds']:
    pop = np.zeros(config['dataset_items'], dtype=int)
    for user, row in enumerate(histories):
        shuffled = np.random.default_rng(np.random.SeedSequence([seed,user])).permutation(row)
        pop[shuffled[:int(len(row)*.6)]] += 1
    popularity[seed] = pop
groups = {}
counts = {}
for line in (args.results/'predictions.jsonl').read_text().splitlines():
    row = json.loads(line)
    cold = [item for item in row['positive'] if popularity[row['seed']][item] == 0]
    if not cold:
        continue
    hits = len(set(cold) & set(row['top10']))
    groups.setdefault(row['model'], {}).setdefault(row['user'], []).append(hits/len(cold))
    # Count each user page once, independent of algorithm.
    counts[(row['seed'],row['user'])] = len(cold)
users = sorted(next(iter(groups.values())))
bootstrap = np.random.default_rng(20261122).integers(0,len(users),size=(2000,len(users)))
summary, arrays = [], {}
for model, by_user in groups.items():
    assert sorted(by_user) == users
    values = np.array([np.mean(by_user[user]) for user in users])
    arrays[model] = values
    lo,hi = np.percentile(values[bootstrap].mean(axis=1),[2.5,97.5])
    summary.append({'model':model,'cold_item_recall10':float(values.mean()),'lo':float(lo),'hi':float(hi)})
paired=[]
for model in arrays:
    if model == 'PakPerk weighted':continue
    difference=arrays['PakPerk weighted']-arrays[model]
    lo,hi=np.percentile(difference[bootstrap].mean(axis=1),[2.5,97.5])
    paired.append({'comparison':'PakPerk weighted minus '+model,'recall_difference':float(difference.mean()),'lo':float(lo),'hi':float(hi)})
output={'analysis_type':'exploratory post-hoc slice, not a new independent test',
        'definition':'test positives with exactly zero training interactions, on the original unchanged 50-item pages',
        'aggregation':'mean per eligible user across their eligible split-seed pages; 2000 user-cluster bootstrap resamples',
        'eligible_users':len(users),'eligible_pages':len(counts),'cold_positive_occurrences':sum(counts.values()),
        'per_seed_pages':{seed:sum(s==seed for s,u in counts) for seed in config['seeds']},
        'summary':summary,'paired':paired}
(args.results/'cold_items.json').write_text(json.dumps(output,indent=2))
print(json.dumps(output,ensure_ascii=False))
