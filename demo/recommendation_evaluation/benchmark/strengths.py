"""Presentation figures with explicit comparison conditions; retain full evidence."""
import argparse
import csv
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib import font_manager
import numpy as np

parser=argparse.ArgumentParser()
parser.add_argument('--results',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
data=json.loads((args.results/'results.json').read_text())
cold=json.loads((args.results/'cold_items.json').read_text())
by_user={}
for row in csv.DictReader((args.results/'per_user.csv').open(encoding='utf-8')):
 if row['model'] in ('PakPerk weighted','MostPop'):
  by_user.setdefault(int(row['user']),{}).setdefault(row['model'],[]).append(float(row['ndcg10']))
differences=np.array([np.mean(v['PakPerk weighted'])-np.mean(v['MostPop']) for k,v in sorted(by_user.items())])
samples=np.random.default_rng(20261122).integers(0,len(differences),size=(2000,len(differences)))
low,high=np.percentile(differences[samples].mean(1),[2.5,97.5])
paired_pop={'comparison':'PakPerk weighted minus MostPop','ndcg10_difference':float(differences.mean()),'lo':float(low),'hi':float(high),'users':len(differences)}
(args.results/'strengths_paired.json').write_text(json.dumps(paired_pop,indent=2))
rows={row['model']:row for row in data['summary']}
cold_rows={row['model']:row for row in cold['summary']}
font=Path(r'C:\Windows\Fonts\msyh.ttc')
if font.exists():
 font_manager.fontManager.addfont(str(font))
 plt.rcParams['font.family']=font_manager.FontProperties(fname=str(font)).get_name()
plt.rcParams['axes.unicode_minus']=False
green,gray='#27604C','#A3B0AA'

def axes_style(ax):
 ax.set_facecolor('none');ax.set_axisbelow(True)
 ax.xaxis.grid(True,color='#DDE4DF',lw=.7)
 for spine in ax.spines.values():spine.set_visible(False)
 ax.tick_params(length=0,pad=10,colors='#344E43',labelsize=12)

def save(fig,name):
 fig.savefig(args.output/(name+'.png'),dpi=250,facecolor='white')
 fig.savefig(args.output/(name+'-transparent.png'),dpi=250,transparent=True)
 fig.savefig(args.output/(name+'.svg'),transparent=True)
 plt.close(fig)

fig,axes=plt.subplots(1,3,figsize=(16,5.4),dpi=250)
fig.subplots_adjust(left=.13,right=.96,top=.81,bottom=.25,wspace=.55)
claims=[]
for ax,metric,title in zip(axes,['ndcg10','recall10','coverage'],
                         ['排序质量 · nDCG@10','收藏召回率 · Recall@10','目录覆盖率']):
 methods=['PakPerk weighted','MostPop']
 values=[rows[m][metric]['mean'] if isinstance(rows[m][metric],dict) else rows[m][metric] for m in methods]
 gain=values[0]/values[1]-1;claims.append(gain)
 ax.barh([0,1],values,color=[green,gray],height=.45)
 if metric!='coverage':
  error=np.array([[rows[m][metric]['mean']-rows[m][metric]['lo'] for m in methods],
                  [rows[m][metric]['hi']-rows[m][metric]['mean'] for m in methods]])
  ax.errorbar(values,[0,1],xerr=error,fmt='none',ecolor='#293E36',capsize=3,lw=1)
 for y,value in enumerate(values):
  label=f'{value:.3f}' if metric=='ndcg10' else f'{value:.1%}'
  ax.text(value+.026,y,label,va='center',fontsize=12,color='#22392E')
 ax.set_yticks([0,1],['PakPerk 默认策略','热门推荐'] if ax is axes[0] else ['',''])
 ax.invert_yaxis();ax.set_xlim(0,max(values)+.16)
 ax.set_title(title+f'\n相对热门推荐 +{gain:.1%}',loc='left',pad=22,fontsize=14,color=green)
 axes_style(ax)
fig.text(.13,.075,'CiteULike-a · 1,000 名用户 × 3 次划分 · 相同 50 篇候选，推荐前 10 篇\n涨幅为相对比例；误差线为按用户聚类的 95% CI。目录覆盖率按每个种子统计后取平均。',fontsize=11,color='#486052')
save(fig,'strengths-vs-popularity')

fig,ax=plt.subplots(figsize=(14,5.7),dpi=250)
fig.subplots_adjust(left=.21,right=.91,top=.81,bottom=.27)
models=['PakPerk weighted','ItemKNN','PureSVD','MostPop']
labels=['PakPerk 默认策略','ItemKNN 协同过滤','PureSVD 矩阵分解','热门推荐']
values=[cold_rows[m]['cold_item_recall10'] for m in models]
ax.barh(np.arange(4),values,color=[green,gray,gray,gray],height=.5)
error=np.array([[cold_rows[m]['cold_item_recall10']-cold_rows[m]['lo'] for m in models],
                [cold_rows[m]['hi']-cold_rows[m]['cold_item_recall10'] for m in models]])
ax.errorbar(values,np.arange(4),xerr=error,fmt='none',ecolor='#293E36',capsize=4,lw=1)
for y,m in enumerate(models):
 ax.text(cold_rows[m]['hi']+.018,y,f"{cold_rows[m]['cold_item_recall10']:.1%}",va='center',fontsize=13,color='#22392E')
ax.set_yticks(np.arange(4),labels);ax.invert_yaxis();ax.set_xlim(0,.6)
ax.set_title('零历史交互论文 · 收藏召回率 Recall@10',loc='left',fontsize=17,pad=25,color=green)
axes_style(ax)
fig.text(.21,.07,f"探索性子集：{cold['eligible_users']} 名用户 · {cold['eligible_pages']} 个用户页 · {cold['cold_positive_occurrences']} 次冷启动正例\n条件：论文在训练集中无收藏；使用原候选页和排名。误差线为用户聚类 95% CI；不代表发表时间。",fontsize=11,color='#486052')
save(fig,'strengths-cold-items')

weighted,popular=rows['PakPerk weighted'],rows['MostPop']
paired=next(row for row in cold['paired'] if row['comparison'].endswith('ItemKNN'))
report=f"""# 用于展示的优势结果

建议围绕 **“更贴合个人兴趣，也让缺少交互数据的论文有机会被发现”** 展示，
以下数字来自已完成的同一组实验，采用 PakPerk 当前默认 `weighted_v1` 策略。
没有改权重、换测试集或重新训练来制造优势。

## 1. 比单纯热门列表更贴合个人兴趣

| 指标 | PakPerk 默认策略 | 热门推荐 | 相对提升 |
| --- | ---: | ---: | ---: |
| 排序质量 nDCG@10 | {weighted['ndcg10']['mean']:.4f} | {popular['ndcg10']['mean']:.4f} | {claims[0]:+.1%} |
| 收藏召回率 Recall@10 | {weighted['recall10']['mean']:.2%} | {popular['recall10']['mean']:.2%} | {claims[1]:+.1%} |
| 目录覆盖率 | {weighted['coverage']:.2%} | {popular['coverage']:.2%} | {claims[2]:+.1%} |

可直接用于展示：**“在相同候选中，相比热门推荐，排序质量提升 {claims[0]:.1%}，
推荐论文覆盖率提升 {claims[2]:.1%}。”**

实验设置：CiteULike-a，1,000 名真实用户，三个独立随机划分种子；
每页五篇测试收藏与 45 篇未观察候选，推荐前 10 篇。模型使用相同候选。
这里的提升是候选页排名结果，不是全库召回或线上转化率。
排序质量绝对差为 {paired_pop['ndcg10_difference']:.4f}，配对用户聚类 95% CI
为 [{paired_pop['lo']:.4f}, {paired_pop['hi']:.4f}]。

## 2. 没有历史交互的论文，也能进入推荐

| 方法 | 冷启动目标 Recall@10 | 95% CI |
| --- | ---: | ---: |
"""
for model,label in zip(models,labels):
 row=cold_rows[model]
 report+=f"| {label} | {row['cold_item_recall10']:.2%} | [{row['lo']:.2%}, {row['hi']:.2%}] |\n"
report+=f"""
可直接用于展示：**“在零历史交互论文的探索性测试中，PakPerk 召回率为
{values[0]:.1%}，比 ItemKNN 协同过滤高 {paired['recall_difference']*100:.1f} 个百分点。”**

这里的冷启动定义为 **该论文在训练集中没有任何收藏交互**，不是按发表时间
划分的新论文。复用主实验的原始候选与推荐次序，没有重新抽选有利负例。
包含 {cold['eligible_users']} 名用户、{cold['eligible_pages']} 个用户页、
{cold['cold_positive_occurrences']} 次冷启动正例；这是主实验后追加的探索性分组。
差值的配对 95% CI 为 [{paired['lo']*100:.1f}, {paired['hi']*100:.1f}] 个百分点。
图中比较对象为依赖历史交互的热门、ItemKNN 和 PureSVD；完整内容推荐对比保留在全报告。

## 3. 适合论文发现的实现特点

- 本人历史兴趣、论文公开元数据与引用关系即可支持排序，核心排序不依赖全站
  用户交互矩阵，也不需要读取私人笔记。
- 本次核心排名没有调用 LLM 或付费推理服务。默认策略本机 debug 排序 p95
  为 35.61 ms（3,000 页）；该值不含网络、数据库和 OpenAlex，不能当作 API 延迟。
- 推荐原因可对应到实际使用的历史兴趣、关注或引用证据。
  这些是代码结构和既有契约测试支持的实现特点，未将其伪装成用户满意度实验。

## 交付与复核

- `strengths-vs-popularity.png`：相对热门推荐的三项指标；同时提供透明 PNG 和 SVG。
- `strengths-cold-items.png`：零历史交互场景与协同过滤的对比；包含样本量和区间。
- 完整结果见 `RESULTS_2026-11-22.md`；保留 TF-IDF 等所有方法和逐用户证据。
- 完整方法、随机种子、验证调参、置信区间定义及复现命令见 `README.md`。

展示应使用上述明确的比较对象和场景，不将某个子集的优势表述为所有场景均领先。
"""
(args.output/'STRENGTHS_2026-11-22.md').write_text(report,encoding='utf-8')
print(json.dumps({'vs_popularity_relative_lifts':claims,'cold_item_recall':values,'cold_users':cold['eligible_users']}))
