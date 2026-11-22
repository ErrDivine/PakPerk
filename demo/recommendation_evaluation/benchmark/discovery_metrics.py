"""Post-hoc discovery metrics on the unchanged 100-candidate predictions."""
import argparse
import json
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib import font_manager, ticker

parser=argparse.ArgumentParser()
parser.add_argument('--data',type=Path,required=True)
parser.add_argument('--results',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--language',choices=['zh','en'],default='zh')
args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
experiment=json.loads((args.results/'results.json').read_text())
histories=[np.array(list(map(int,line.split()))[1:]) for line in (args.data/'users.dat').read_text().splitlines()]
population=len(histories);catalog=experiment['configuration']['dataset_items']
models=experiment['configuration']['models'];by_seed={}
for seed in experiment['configuration']['seeds']:
    popularity=np.zeros(catalog,dtype=int)
    for user,history in enumerate(histories):
        train=np.random.default_rng(np.random.SeedSequence([seed,user])).permutation(history)[:int(len(history)*.6)]
        popularity[train]+=1
    order=np.lexsort((np.arange(catalog),-popularity))
    head=np.zeros(catalog,dtype=bool);head[order[:int(catalog*.2)]]=True
    by_seed[seed]=(popularity,head)
values={model:{} for model in models}
for line in (args.results/'predictions.jsonl').read_text().splitlines():
    row=json.loads(line);popularity,head=by_seed[row['seed']];items=np.array(row['top10'])
    novelty=float(np.mean(-np.log2((popularity[items]+1)/(population+1))))
    tail=float(np.mean(~head[items]))
    values[row['model']].setdefault(row['user'],[]).append([novelty,tail])
users=sorted(values[models[0]])
samples=np.random.default_rng(20261122).integers(0,len(users),(2000,len(users)))
summary=[];arrays={};paired=[]
for model in models:
    array=np.array([np.mean(values[model][user],axis=0) for user in users]);arrays[model]=array
    original=next(row for row in experiment['summary'] if row['model']==model)
    entry={'model':model,'coverage':original['coverage'],'ndcg10':original['ndcg10']}
    for j,name in enumerate(['novelty_bits','tail_share']):
        lo,hi=np.percentile(array[:,j][samples].mean(1),[2.5,97.5])
        entry[name]={'mean':float(array[:,j].mean()),'lo':float(lo),'hi':float(hi)}
    summary.append(entry)
for model in models[1:]:
    difference=arrays[models[0]]-arrays[model]
    for j,name in enumerate(['novelty_bits','tail_share']):
        lo,hi=np.percentile(difference[:,j][samples].mean(1),[2.5,97.5])
        paired.append({'baseline':model,'metric':name,'difference':float(difference[:,j].mean()),'lo':float(lo),'hi':float(hi)})
result={'metrics_selected_after_primary_comparison':True,
        'scope':'coverage and novelty are supplementary; ndcg10 is copied from the original relevance evaluation',
        'display_metrics':['coverage','novelty_bits','ndcg10'],
        'candidate_count':100,'recommendations_per_user':10,'users':1000,'seeds':[42,43,44],
        'novelty_definition':'mean -log2((training item user count + 1)/(5551 + 1)), in bits',
        'long_tail_definition':'items outside top 20 percent of catalog ranked by training user count; boundary ties broken by item ID; tail comprises 13584 items',
        'summary':summary,'paired':paired}
(args.results/'beyond_accuracy.json').write_text(json.dumps(result,indent=2))

font=Path(r'C:\Windows\Fonts\msyh.ttc')
if font.exists():
    font_manager.fontManager.addfont(str(font))
    plt.rcParams['font.family']=font_manager.FontProperties(fname=str(font)).get_name()
plt.rcParams['axes.unicode_minus']=False;plt.rcParams['svg.fonttype']='none'
if args.language=='en':
    plt.rcParams['font.family']='DejaVu Sans'
labels=['PakPerk','MostPop','DC']
axis_labels=(['Catalog Coverage (%)','Recommendation Novelty (bits)','Ranking Quality (nDCG)']
             if args.language=='en' else ['论文覆盖率（%）','推荐新颖性（bit）','排序质量（nDCG）'])
fig,axes=plt.subplots(1,3,figsize=(16,4.8),dpi=250)
fig.subplots_adjust(left=.10,right=.98,top=.96,bottom=.20,wspace=.34)
for index,(ax,metric,label,factor) in enumerate(zip(axes,['coverage','novelty_bits','ndcg10'],
                                                  axis_labels,[100,1,1])):
    numbers=np.array([row[metric]['mean'] if isinstance(row[metric],dict) else row[metric] for row in summary])*factor
    ax.barh([0,1,2],numbers,color=['#27604C','#A3B0AA','#B9C5BF'],height=.48)
    if metric!='coverage':
        error=np.array([[row[metric]['mean']-row[metric]['lo'] for row in summary],
                        [row[metric]['hi']-row[metric]['mean'] for row in summary]])*factor
        ax.errorbar(numbers,[0,1,2],xerr=error,fmt='none',ecolor='#293E36',capsize=3,lw=1)
    upper=max(numbers)*1.23
    for y,number in enumerate(numbers):
        ax.text(number+upper*.025,y,f'{number:.3f}' if metric=='ndcg10' else f'{number:.2f}',va='center',fontsize=16,color='#22392E')
    ax.set_yticks([0,1,2],labels if index==0 else ['','',''])
    if index==0:ax.set_ylabel('Method' if args.language=='en' else '推荐方法',fontsize=16,labelpad=16,color='#22392E')
    ax.set_xlabel(label,fontsize=17,labelpad=16,color='#22392E')
    ax.set_xlim(0,upper);ax.set_ylim(2.55,-.55)
    ax.xaxis.set_major_locator(ticker.MaxNLocator(nbins=4,min_n_ticks=3))
    ax.tick_params(length=0,pad=9,labelsize=15,colors='#344E43')
    ax.set_axisbelow(True);ax.xaxis.grid(True,color='#DDE4DF',lw=.7);ax.set_facecolor('none')
    for spine in ax.spines.values():spine.set_visible(False)
plot_name='discovery-metrics-en' if args.language=='en' else 'discovery-metrics'
fig.savefig(args.output/(plot_name+'-transparent.png'),transparent=True,dpi=250)
fig.savefig(args.output/(plot_name+'.png'),facecolor='white',dpi=250)
fig.savefig(args.output/(plot_name+'.svg'),transparent=True)
plt.close(fig)

table=['| 方法 | 论文覆盖率 | 推荐新颖性（bit） | 排序质量（nDCG） |','| --- | ---: | ---: | ---: |']
for row,label in zip(summary,labels):
    table.append(f"| {label} | {row['coverage']:.2%} | {row['novelty_bits']['mean']:.2f} | {row['ndcg10']['mean']:.4f} |")
report=f"""# 论文发现指标：100 候选、两个基线

{chr(10).join(table)}

- **论文覆盖率**：全部用户的推荐列表覆盖了多少不同论文；分母为 16,980。
  按每次划分分别计算后取平均。
- **推荐新颖性**：平均 `−log₂((训练集收藏用户数＋1)/(5,551＋1))`，单位 bit。
  衡量对全局热度的偏离，越高表示推荐内容越不集中于热门论文。
  这是基于流行度的新颖性代理，不是用户主观意外性或相关性。
- **排序质量**：沿用原实验 nDCG@10，衡量五篇测试收藏是否排在靠前位置。
  图中省略“@10”，实验设置仍明确每位用户推荐 10 篇，计算口径未改。

实验不变：固定 1,000 名用户、60/20/20 划分、种子 42/43/44；相同的 100 候选
（5 正例＋95 未观察负例），每人仍推荐 10 篇。只对已保存的推荐列表追加指标计算，
未调整模型、用户、候选或排名。覆盖率与新颖性为主实验后的描述性补充，
排序质量直接采用原实验结果；完整结果保留在 `SETTING_AND_RESULTS_100.md`。
覆盖率与新颖性不等同于相关性或用户满意度。

误差线：新颖性与排序质量先对同一用户三次结果取平均，再做 2,000 次用户聚类
Bootstrap，显示 95% CI。论文覆盖率只画点估计。

DC 是 Direct Citation（直接引用）这一引用关系及检索方法的规范缩写。
本实验使用最多 50 篇历史论文的直接连接数计分，并以训练收藏人数打破并列；
可标注 **“DC baseline（直接引用计数）”**，不是某个商业产品的完整算法复现。

参考：[RecBole 的覆盖与长尾指标](https://www.recbole.io/docs/user_guide/train_eval_intro.html)、
[基于自信息的新颖性](https://pmc.ncbi.nlm.nih.gov/articles/PMC2842039/)、
[Direct Citation 检索研究](https://doi.org/10.1002/asi.24951)。

复现：
```powershell
python demo/recommendation_evaluation/benchmark/discovery_metrics.py --data .local/recommendation-benchmark-20261122/data --results .local/recommendation-benchmark-100-20261122/results --output .local/recommendation-benchmark-100-20261122/final
```
"""
(args.output/'DISCOVERY_METRICS_100.md').write_text(report,encoding='utf-8')
print(json.dumps({'summary':summary},ensure_ascii=False))
