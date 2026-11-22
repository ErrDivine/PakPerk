"""Verify and render the frozen 100-item experiment, without headline overlays."""
import argparse
import csv
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib import font_manager, ticker
import numpy as np

parser=argparse.ArgumentParser()
parser.add_argument('--results',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
data=json.loads((args.results/'results.json').read_text())
config=data['configuration'];rows={row['model']:row for row in data['summary']}
models=['PakPerk weighted','MostPop','Citation-neighbor']
labels=['PakPerk 默认策略','热门推荐','直接引用邻居']
lookup={}
with (args.results/'per_user.csv').open(newline='',encoding='utf-8') as stream:
    for row in csv.DictReader(stream):lookup[(int(row['seed']),int(row['user']),row['model'])]=row
seen=0
for line in (args.results/'predictions.jsonl').read_text().splitlines():
    row=json.loads(line)
    assert len(set(row['candidates']))==len(row['candidates'])==100
    assert len(set(row['positive']))==5
    assert len(set(row['top10']))==len(row['top10'])==10
    assert set(row['top10'])<=set(row['candidates'])
    hit=[rank for rank,item in enumerate(row['top10'],1) if item in row['positive']]
    ndcg=sum(1/np.log2(rank+1) for rank in hit)/sum(1/np.log2(rank+1) for rank in range(1,6))
    reference=lookup[(row['seed'],row['user'],row['model'])]
    assert np.isclose(ndcg,float(reference['ndcg10']))
    assert np.isclose(len(hit)/5,float(reference['recall10']))
    seen+=1
assert seen==9000

font=Path(r'C:\Windows\Fonts\msyh.ttc')
if font.exists():
    font_manager.fontManager.addfont(str(font))
    plt.rcParams['font.family']=font_manager.FontProperties(fname=str(font)).get_name()
plt.rcParams['axes.unicode_minus']=False
plt.rcParams['svg.fonttype']='none'
fig,axes=plt.subplots(1,3,figsize=(16,4.8),dpi=250)
fig.subplots_adjust(left=.15,right=.98,top=.96,bottom=.20,wspace=.36)
for index,(ax,metric,label,factor) in enumerate(zip(axes,['ndcg10','recall10','coverage'],
                                                  ['nDCG@10','Recall@10（%）','目录覆盖率（%）'],[1,100,100])):
    values=np.array([rows[m][metric]['mean'] if isinstance(rows[m][metric],dict) else rows[m][metric] for m in models])*factor
    ax.barh([0,1,2],values,color=['#27604C','#A3B0AA','#B9C5BF'],height=.48)
    if metric!='coverage':
        errors=np.array([[rows[m][metric]['mean']-rows[m][metric]['lo'] for m in models],
                         [rows[m][metric]['hi']-rows[m][metric]['mean'] for m in models]])*factor
        ax.errorbar(values,[0,1,2],xerr=errors,fmt='none',ecolor='#293E36',capsize=3,lw=1)
    upper=max(values)*1.26
    for y,value in enumerate(values):
        ax.text(value+upper*.035,y,f'{value:.3f}' if factor==1 else f'{value:.1f}',va='center',fontsize=16,color='#22392E')
    ax.set_yticks([0,1,2],labels if index==0 else ['','',''])
    if index==0:ax.set_ylabel('推荐方法',fontsize=16,labelpad=16,color='#22392E')
    ax.set_xlabel(label,fontsize=17,labelpad=16,color='#22392E')
    ax.set_xlim(0,upper);ax.set_ylim(2.55,-.55)
    ax.xaxis.set_major_locator(ticker.MaxNLocator(nbins=4,min_n_ticks=3))
    ax.tick_params(length=0,pad=9,colors='#344E43',labelsize=15)
    ax.set_axisbelow(True);ax.xaxis.grid(True,color='#DDE4DF',lw=.7);ax.set_facecolor('none')
    for spine in ax.spines.values():spine.set_visible(False)
fig.savefig(args.output/'comparison-100-transparent.png',transparent=True,dpi=250)
fig.savefig(args.output/'comparison-100.png',facecolor='white',dpi=250)
fig.savefig(args.output/'comparison-100.svg',transparent=True)
plt.close(fig)

# A standalone coverage figure for the presentation's supported advantage.
fig,ax=plt.subplots(figsize=(12,4.4),dpi=250)
fig.subplots_adjust(left=.25,right=.95,top=.96,bottom=.22)
coverage=[rows[model]['coverage']*100 for model in models]
ax.barh([0,1,2],coverage,color=['#27604C','#A3B0AA','#B9C5BF'],height=.48)
for y,value in enumerate(coverage):
    ax.text(value+.6,y,f'{value:.2f}',va='center',fontsize=16,color='#22392E')
ax.set_yticks([0,1,2],labels);ax.set_ylim(2.55,-.55);ax.set_xlim(0,35)
ax.set_ylabel('推荐方法',fontsize=16,labelpad=16,color='#22392E')
ax.set_xlabel('目录覆盖率（%）',fontsize=17,labelpad=16,color='#22392E')
ax.tick_params(length=0,pad=9,colors='#344E43',labelsize=15)
ax.xaxis.set_major_locator(ticker.MultipleLocator(10))
ax.set_axisbelow(True);ax.xaxis.grid(True,color='#DDE4DF',lw=.7);ax.set_facecolor('none')
for spine in ax.spines.values():spine.set_visible(False)
fig.savefig(args.output/'coverage-100-transparent.png',transparent=True,dpi=250)
fig.savefig(args.output/'coverage-100.png',facecolor='white',dpi=250)
fig.savefig(args.output/'coverage-100.svg',transparent=True)
plt.close(fig)

table=['| 方法 | nDCG@10（95% CI） | Recall@10 | 目录覆盖率 |','| --- | ---: | ---: | ---: |']
for model,label in zip(models,labels):
    r=rows[model];n=r['ndcg10']
    table.append(f"| {label} | {n['mean']:.4f} [{n['lo']:.4f}, {n['hi']:.4f}] | {r['recall10']['mean']:.2%} | {r['coverage']:.2%} |")
differences=['| 对照 | 指标 | PakPerk 相对变化 | 绝对差 | 配对 95% CI |', '| --- | --- | ---: | ---: | ---: |']
for pair in data['paired']:
    if pair['metric'] not in ('ndcg10','recall10'):continue
    model=pair['baseline'];metric=pair['metric']
    relative=rows['PakPerk weighted'][metric]['mean']/rows[model][metric]['mean']-1
    differences.append(f"| {model} | {metric} | {relative:+.2%} | {pair['difference']:+.4f} | [{pair['lo']:+.4f}, {pair['hi']:+.4f}] |")
report=f"""# PakPerk：100 篇候选、两个基线对比

## 实验设置

| 项目 | 设置 |
| --- | --- |
| 数据 | CiteULike-a；5,551 名用户、16,980 篇论文、204,986 条收藏 |
| 评估 | 与 50 候选实验相同的 1,000 名用户，至少 25 条收藏 |
| 划分 | 每用户随机 60%/20%/20%；种子 42、43、44 |
| 候选 | **100 篇＝原 5 篇测试正例＋原 45 篇未观察负例＋新增 50 篇负例** |
| 推荐 | 相同候选，Top 10；共 3,000 个测试用户页、9,000 个推荐列表 |
| PakPerk | 实际 Rust `weighted_v1`，原权重、128 维元数据嵌入、最多 50 条历史兴趣及原重排规则 |
| 对照一 | MostPop：训练集中收藏该论文的用户数，降序排列 |
| 对照二 | 直接引用邻居：与最多 50 篇历史训练论文直接相连的数量；并列按训练集收藏人数，再按固定随机键排序 |
| 指标 | nDCG@10、Recall@10、目录覆盖率；另保留 Precision/MRR/HitRate |
| 区间 | 同一用户三次分数先取平均，2,000 次用户聚类 Bootstrap，95% CI |

## 最终结果

{chr(10).join(table)}

展示可聚焦目录覆盖率：相比 MostPop 提升
{(rows['PakPerk weighted']['coverage']/rows['MostPop']['coverage']-1):.2%}，
相比直接引用邻居提升
{(rows['PakPerk weighted']['coverage']/rows['Citation-neighbor']['coverage']-1):.2%}。
该指标描述推荐覆盖面，不能替代相关性或用户满意度。
引用邻居在 nDCG 和 Recall 上较高，完整表格如上；不宣称 PakPerk 三项均领先。

## 配对比较

{chr(10).join(differences)}

相对变化计算为 PakPerk÷基线−1；Recall 的绝对差乘 100 后是百分点。
目录覆盖率是每个种子内推荐的不同论文数÷16,980，再对三次取平均。
未观察候选作为隐式反馈评估负例，不等于真实不喜欢。

## 保持不变与实现边界

- 原 3,000 个测试页的用户、训练划分、五篇正例以及原 45 篇负例均逐页核对一致。
  只扩充候选和增加一个固定基线；没有更换用户、调评分权重或根据本次测试结果选参。
- 新正例比例为 5%，原实验为 10%；绝对分数不与 50 候选结果直接混用。
- 无发表时间、真实分类和作者关注的数据适配保持原设置：年龄固定、关注为空，
  未知分类/作者/主题上限为 50，避免未知分类截断 Top 10。
- `weighted_v1` 排序内核支持至多 500 候选，本次直接处理 100 篇，不分批合并。
  不修改生产 API 页大小，也不运行受 50 篇上限约束的 `citation_online_v1`。
- 二个基线在本次运行前固定，未根据 100 候选测试结果更换。新增方法是透明的
  直接引用邻居计数基线，不是对任意商业产品或复杂图模型的复刻。
  直接引用是论文种子检索中已有的研究对照，参见
  [Sjögårde & Ahlgren, 2024](https://doi.org/10.1002/asi.24951)。
- 结论对应本次两个对照和受控候选页；不声称全库召回、时序预测或所有算法领先。
  引用图完全对称，无法评估引用方向；没有在线相关/不相关反馈或线上 A/B。

## 校验与复现

独立重算全部 {seen:,} 个测试列表的 nDCG 和 Recall，核对候选数、正例数、
Top 10 唯一性及输出范围。源数据 SHA-256 与原实验清单一致。
源码基线 `{config['source_revision']}`；生产推荐源码未改。

```powershell
cd backend
cargo build --locked -p recommendations --example benchmark_rank
cd ..
python demo/recommendation_evaluation/benchmark/run_expanded.py --data .local/recommendation-benchmark-20261122/data --previous .local/recommendation-benchmark-20261122/results --output .local/recommendation-benchmark-100-20261122/results --binary backend/target/debug/examples/benchmark_rank.exe
python demo/recommendation_evaluation/benchmark/report_expanded.py --results .local/recommendation-benchmark-100-20261122/results --output .local/recommendation-benchmark-100-20261122/final
```

运行依赖 Python 3.12、NumPy 1.26.4；制图另需 Matplotlib 3.8.4。
Windows 字体使用微软雅黑，其他系统可替换为已安装的中文字体。
原始结果保留 `results.json`、`per_user.csv`、`predictions.jsonl`、输入指纹及运行日志。
"""
(args.output/'SETTING_AND_RESULTS_100.md').write_text(report,encoding='utf-8')
with (args.output/'summary-100.csv').open('w',newline='',encoding='utf-8-sig') as stream:
    writer=csv.writer(stream);writer.writerow(['model','ndcg10','ndcg10_lo','ndcg10_hi','recall10','coverage'])
    for model in models:
        r=rows[model];writer.writerow([model,r['ndcg10']['mean'],r['ndcg10']['lo'],r['ndcg10']['hi'],r['recall10']['mean'],r['coverage']])
(args.output/'verification-100.json').write_text(json.dumps({'verified_lists':seen,'original_test_pages_preserved':3000},indent=2))
print(json.dumps({'verified_lists':seen,'summary':data['summary']}))
