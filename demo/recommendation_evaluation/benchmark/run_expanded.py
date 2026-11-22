"""100-candidate follow-up with frozen users, positives, and original negatives.

Comparators are selected before this run: training popularity and direct citation
neighbors, with popularity breaking citation-count ties. No production tuning.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import time

import numpy as np

MODELS = ('PakPerk weighted', 'MostPop', 'Citation-neighbor')
METRICS = ('ndcg10', 'recall10', 'precision10', 'mrr10', 'hit10')


def metrics(order, positive):
    relevant = np.isin(order, positive).astype(float)
    discounts = 1 / np.log2(np.arange(2, 12))
    positions = np.flatnonzero(relevant)
    return [float(relevant @ discounts / discounts[:5].sum()),
            float(relevant.sum()/5), float(relevant.sum()/10),
            float(1/(positions[0]+1)) if len(positions) else 0,
            float(len(positions)>0)]


def main(args):
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    data = args.data.resolve()
    old_result = json.loads((args.previous/'results.json').read_text())
    config = old_result['configuration']
    assert config['seeds'] == [42,43,44] and config['eval_users'] == 1000
    manifest = json.loads((data/'manifest.json').read_text())
    for name, expected in manifest['files'].items():
        assert hashlib.sha256((data/name).read_bytes()).hexdigest() == expected['sha256']
    histories=[]
    for line in (data/'users.dat').read_text().splitlines():
        row=list(map(int,line.split()))
        assert row[0] == len(row)-1 == len(set(row[1:]))
        histories.append(np.array(row[1:],dtype=np.int32))
    with (data/'raw-data.csv').open(encoding='latin-1',newline='') as stream:
        metadata=list(csv.DictReader(stream))
    assert [int(row['doc.id']) for row in metadata] == list(range(1,len(metadata)+1))
    graph=[]
    for line in (data/'citations.dat').read_text().splitlines():
        row=list(map(int,line.split())); assert row[0] == len(row)-1
        graph.append(set(row[1:]))
    catalog=[{'title':row['raw.title'] or row['title'],'abstract_text':row['raw.abstract'],
              'neighbors':sorted(neighbors)} for row,neighbors in zip(metadata,graph)]
    nitems=len(catalog); assert nitems == config['dataset_items'] == len(graph)
    previous={}
    for line in (args.previous/'predictions.jsonl').read_text().splitlines():
        row=json.loads(line)
        if row['model']=='PakPerk weighted': previous[(row['seed'],row['user'])]=row
    users=np.array(sorted({user for seed,user in previous}))
    expected_users=np.sort(np.random.default_rng(20261122).choice(
        [i for i,h in enumerate(histories) if len(h)>=25],size=1000,replace=False))
    assert np.array_equal(users,expected_users)
    all_rows=[];predictions=[];seed_metrics=[];timings=[];audit=[]
    for seed in config['seeds']:
        started=time.perf_counter(); train=[]; test=[]; validation=[]
        for user,history in enumerate(histories):
            shuffled=np.random.default_rng(np.random.SeedSequence([seed,user])).permutation(history)
            a,b=int(len(history)*.6),int(len(history)*.2)
            train.append(shuffled[:a]);validation.append(shuffled[a:a+b]);test.append(shuffled[a+b:])
            assert not set(train[-1]) & (set(validation[-1])|set(test[-1]))
        popularity=np.bincount(np.concatenate(train),minlength=nitems)
        cases=[]
        for user in users:
            # Replay the original sampler exactly, then add 50 new negatives.
            rng=np.random.default_rng(np.random.SeedSequence([seed,int(user),True,917]))
            positive=rng.choice(test[user],5,replace=False)
            allowed=np.setdiff1d(np.arange(nitems),histories[user])
            old_negative=rng.choice(allowed,45,replace=False)
            original=rng.permutation(np.concatenate([positive,old_negative]))
            old=previous[(seed,int(user))]
            assert positive.tolist() == old['positive']
            assert original.tolist() == old['candidates']
            extension_rng=np.random.default_rng(np.random.SeedSequence([seed,int(user),100,20261122]))
            extra=extension_rng.choice(np.setdiff1d(allowed,old_negative),50,replace=False)
            candidates=extension_rng.permutation(np.concatenate([original,extra])).tolist()
            assert len(candidates) == len(set(candidates)) == 100
            assert set(original) < set(candidates)
            assert not set(candidates) & set(train[user])
            assert set(positive) == set(candidates) & set(histories[user])
            cases.append({'id':f'{seed}:test:{user}','history':train[user].tolist(),
                          'candidates':candidates,'positive':positive.tolist(),
                          'seed':int(seed*10000+user)})
        raw=json.dumps({'items':catalog,'cases':cases,'weighted_only':True},ensure_ascii=False).encode()
        audit.append({'seed':seed,'input_sha256':hashlib.sha256(raw).hexdigest(),
                      'train_interactions':len(np.concatenate(train)),'preserved_original_pages':len(cases)})
        print(json.dumps({'seed':seed,'stage':'production_ranking','candidates':100,'pages':len(cases)}),flush=True)
        response=subprocess.run([str(args.binary.resolve())],input=raw,capture_output=True,check=True)
        actual={row['id']:row for row in map(json.loads,response.stdout.decode().splitlines())}
        assert len(actual)==len(cases)
        tie_rng=np.random.default_rng(seed+1+239)
        ties=tie_rng.random((len(users),100))
        ranking={model:[] for model in MODELS}
        for j,(user,case) in enumerate(zip(users,cases)):
            candidates=np.array(case['candidates'])
            ranking['PakPerk weighted'].append(np.array(actual[case['id']]['weighted']['indices']))
            ranking['MostPop'].append(candidates[np.lexsort((ties[j],-popularity[candidates]))[:10]])
            history=set(train[user][:50])
            direct=np.array([len(graph[item]&history) for item in candidates])
            # Direct links first; training-only popularity breaks graph ties.
            graph_order=np.lexsort((ties[j],-popularity[candidates],-direct))[:10]
            ranking['Citation-neighbor'].append(candidates[graph_order])
            timings.append({'seed':seed,'user':int(user),'elapsed_us':actual[case['id']]['weighted']['elapsed_us']})
        for model in MODELS:
            model_rows=[]
            for user,case,order in zip(users,cases,ranking[model]):
                assert len(order)==len(set(order))==10 and set(order)<=set(case['candidates'])
                row=dict(zip(METRICS,metrics(order,case['positive'])),seed=seed,user=int(user),model=model)
                all_rows.append(row);model_rows.append(row)
                predictions.append({'seed':seed,'user':int(user),'model':model,
                                    'positive':case['positive'],'candidates':case['candidates'],'top10':order.tolist()})
            seed_metrics.append({'seed':seed,'model':model,
                                 **{m:float(np.mean([row[m] for row in model_rows])) for m in METRICS},
                                 'coverage':len(set(np.concatenate(ranking[model])))/nitems})
        audit[-1]['elapsed_seconds']=round(time.perf_counter()-started,3)
        print(json.dumps({'seed':seed,'stage':'complete','metrics':seed_metrics[-3:]}),flush=True)
    samples=np.random.default_rng(20261122).integers(0,len(users),size=(2000,len(users)))
    summary=[];arrays={}
    for model in MODELS:
        by_user={int(u):[] for u in users}
        for row in all_rows:
            if row['model']==model:by_user[row['user']].append([row[m] for m in METRICS])
        values=np.array([np.mean(by_user[int(user)],axis=0) for user in users]);arrays[model]=values
        entry={'model':model,'coverage':float(np.mean([row['coverage'] for row in seed_metrics if row['model']==model]))}
        for j,m in enumerate(METRICS):
            lo,hi=np.percentile(values[:,j][samples].mean(axis=1),[2.5,97.5])
            entry[m]={'mean':float(values[:,j].mean()),'lo':float(lo),'hi':float(hi)}
        summary.append(entry)
    paired=[]
    for baseline in MODELS[1:]:
        for j,m in enumerate(METRICS):
            difference=arrays['PakPerk weighted'][:,j]-arrays[baseline][:,j]
            lo,hi=np.percentile(difference[samples].mean(axis=1),[2.5,97.5])
            paired.append({'baseline':baseline,'metric':m,'difference':float(difference.mean()),'lo':float(lo),'hi':float(hi)})
    configuration={**config,'candidate_count':100,'positive_count':5,'negative_count':95,
                   'candidate_page':'original 5 positives + original 45 negatives + 50 additional uniform unobserved items',
                   'models':list(MODELS),'citation_baseline':'count direct undirected edges to up to 50 training-history papers; ties: training popularity, then common seeded random key',
                   'audit':audit,'python':platform.python_version(),'numpy':np.__version__,
                   'source_revision':subprocess.check_output(['git','rev-parse','HEAD']).decode().strip(),
                   'previous_results_sha256':hashlib.sha256((args.previous/'results.json').read_bytes()).hexdigest(),
                   'scope':'weighted engine ranking only; no change to production API page limits or citation policy 50-item limit',
                   'parameter_selection':'both baselines fixed before 100-candidate evaluation; no tuning on test data'}
    for unused in ('tfidf_features','scipy','sklearn'):
        configuration.pop(unused,None)
    (out/'results.json').write_text(json.dumps({'configuration':configuration,'summary':summary,'paired':paired,'per_seed':seed_metrics},indent=2),encoding='utf-8')
    for name,records in [('per_user.csv',all_rows),('timing.csv',timings)]:
        with (out/name).open('w',newline='',encoding='utf-8') as stream:
            writer=csv.DictWriter(stream,fieldnames=list(records[0]));writer.writeheader();writer.writerows(records)
    with (out/'predictions.jsonl').open('w',encoding='utf-8') as stream:
        for row in predictions:stream.write(json.dumps(row)+'\n')
    print(json.dumps({'stage':'finished','summary':summary,'paired':paired}),flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--data',type=Path,required=True)
    parser.add_argument('--previous',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--binary',type=Path,required=True)
    main(parser.parse_args())
