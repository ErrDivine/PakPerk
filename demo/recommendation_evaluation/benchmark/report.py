"""Render the completed, measured benchmark as a report and exportable figures."""
import argparse
import csv
import json
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib import font_manager
import numpy as np

parser = argparse.ArgumentParser()
parser.add_argument('--results', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
data = json.loads((args.results/'results.json').read_text(encoding='utf-8'))
summary = data['summary']; config = data['configuration']
rows = {row['model']: row for row in summary}

# Independently recompute accuracy metrics from retained candidate/ranking evidence.
per_user = {}
with (args.results/'per_user.csv').open(encoding='utf-8', newline='') as stream:
    for row in csv.DictReader(stream):
        per_user[(int(row['seed']), int(row['user']), row['model'])] = row
checks = 0
for line in (args.results/'predictions.jsonl').read_text().splitlines():
    record = json.loads(line)
    assert len(record['top10']) == len(set(record['top10'])) == 10
    assert set(record['top10']) <= set(record['candidates'])
    positive = set(record['positive']); assert len(positive) == 5
    hit_positions = [i for i, item in enumerate(record['top10'], 1) if item in positive]
    ndcg = sum(1/np.log2(i+1) for i in hit_positions)/sum(1/np.log2(i+1) for i in range(1,6))
    reference = per_user[(record['seed'], record['user'], record['model'])]
    assert np.isclose(ndcg, float(reference['ndcg10']))
    assert np.isclose(len(hit_positions)/5, float(reference['recall10']))
    checks += 1
assert checks == len(summary)*config['eval_users']*len(config['seeds'])
assert 0.16 < rows['Random']['recall10']['mean'] < 0.24

font = Path(r'C:\Windows\Fonts\msyh.ttc')
if font.exists():
    font_manager.fontManager.addfont(str(font))
    plt.rcParams['font.family'] = font_manager.FontProperties(fname=str(font)).get_name()
plt.rcParams['axes.unicode_minus'] = False
labels = {'Random':'随机推荐', 'MostPop':'热门推荐', 'TF-IDF':'TF-IDF 内容推荐',
          'ItemKNN':'ItemKNN 协同过滤', 'PureSVD':'PureSVD 矩阵分解',
          'PakPerk weighted':'PakPerk 默认加权', 'PakPerk citation (prior)':'PakPerk 引用策略（未训练）'}
ordered = sorted(summary, key=lambda row: row['ndcg10']['mean'], reverse=True)
fig, axes = plt.subplots(1, 2, figsize=(16, 6.7), dpi=250)
fig.subplots_adjust(left=.24, right=.94, bottom=.18, top=.88, wspace=.28)
y = np.arange(len(ordered))
colors = ['#27604C' if row['model'].startswith('PakPerk') else '#9BAAA5' for row in ordered]
for ax, metric, title in zip(axes, ['ndcg10','recall10'], ['前 10 篇的排序质量 · nDCG@10','前 10 篇的召回率 · Recall@10']):
    means = np.array([row[metric]['mean'] for row in ordered])
    errors = np.array([[row[metric]['mean']-row[metric]['lo'] for row in ordered],
                       [row[metric]['hi']-row[metric]['mean'] for row in ordered]])
    ax.barh(y, means, color=colors, height=.56)
    ax.errorbar(means, y, xerr=errors, fmt='none', ecolor='#293E36', capsize=3, lw=1)
    for index, mean in enumerate(means):
        ax.text(mean+.027, index, f'{mean:.3f}', va='center', fontsize=11, color='#22392E')
    ax.set_xlim(0, min(1, float(max(means))+.14))
    ax.set_yticks(y, [labels[row['model']] for row in ordered] if ax is axes[0] else ['']*len(ordered))
    ax.invert_yaxis(); ax.set_title(title, fontsize=14, loc='left', pad=18, color='#22392E')
    ax.tick_params(axis='both', length=0, labelsize=11, pad=9, colors='#344E43')
    ax.xaxis.grid(True, color='#D6DFDA', lw=.7, alpha=.7); ax.set_axisbelow(True)
    for spine in ax.spines.values(): spine.set_visible(False)
    ax.set_facecolor('none')
fig.text(.24, .055, 'CiteULike-a · 1,000 名用户 × 3 次划分 · 每页 5 篇已收藏 + 45 篇未观察候选\n误差线：按用户聚类的 95% 置信区间；本图为候选页排序实验，不代表全库推荐或线上效果。', fontsize=10, color='#486052')
fig.savefig(args.output/'benchmark-transparent.png', transparent=True, dpi=250)
fig.savefig(args.output/'benchmark.png', facecolor='white', dpi=250)
fig.savefig(args.output/'benchmark.svg', transparent=True)
plt.close(fig)

table = ['| 算法 | nDCG@10（95% CI） | Recall@10 | Precision@10 | MRR@10 | 至少命中一篇 | 目录覆盖率 | 文本多样性 |',
         '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |']
for row in ordered:
    n = row['ndcg10']
    table.append(f"| {labels[row['model']]} | {n['mean']:.4f} [{n['lo']:.4f}, {n['hi']:.4f}] | "
                 f"{row['recall10']['mean']:.2%} | {row['precision10']['mean']:.2%} | "
                 f"{row['mrr10']['mean']:.4f} | {row['hit10']['mean']:.2%} | {row['coverage']:.2%} | "
                 f"{row['diversity10']['mean']:.4f} |")
paired = ['| 对比：引用策略减去… | nDCG@10 差值 | 配对 95% CI |', '| --- | ---: | ---: |']
for row in data['paired_ndcg']:
    model = row['comparison'].removeprefix('PakPerk citation (prior) minus ')
    paired.append(f"| {labels[model]} | {row['ndcg10_difference']:+.4f} | [{row['lo']:+.4f}, {row['hi']:+.4f}] |")
perseed = ['| 划分种子 | ItemKNN k | PureSVD 秩 | 默认加权 nDCG | 引用策略 nDCG |', '| --- | ---: | ---: | ---: | ---: |']
for audit in config['audit']:
    scores = {row['model']:row['ndcg10'] for row in data['per_seed'] if row['seed'] == audit['seed']}
    perseed.append(f"| {audit['seed']} | {audit['best_itemknn_k']} | {audit['best_svd_rank']} | {scores['PakPerk weighted']:.4f} | {scores['PakPerk citation (prior)']:.4f} |")
current = rows['PakPerk citation (prior)']; old = rows['PakPerk weighted']; best = ordered[0]
lift = current['ndcg10']['mean']/old['ndcg10']['mean']-1
timings = {}
with (args.results/'timing.csv').open(newline='', encoding='utf-8') as stream:
    records = list(csv.DictReader(stream))
for policy in ['weighted','citation']:
    selected = [row for row in records if row['policy'] == policy]
    elapsed = [float(row['elapsed_us'])/1000 for row in selected]
    timings[policy] = {'p50_ms':float(np.percentile(elapsed,50)), 'p95_ms':float(np.percentile(elapsed,95)),
                       'root_neighbor_page_fraction':float(np.mean([int(row['root_neighbors'])>0 for row in selected]))}
report = f"""# PakPerk 推荐算法对比实验：2026-11-22

本次真实运行的结论：引用策略 nDCG@10 为 **{current['ndcg10']['mean']:.4f}**，
默认加权为 **{old['ndcg10']['mean']:.4f}**，相对变化 **{lift:+.2%}**。
本实验最高分为 **{labels[best['model']]}，{best['ndcg10']['mean']:.4f}**。
请结合下方配对区间判断提升是否稳定；不应将该实验描述为已经证明线上用户更满意。

## 实验设置

- 数据：[CiteULike-a](https://github.com/js05212/citeulike-a)，固定源提交 `{config['data_manifest']['commit']}`。
  文件实测 5,551 名用户、16,980 篇论文、204,986 条收藏、44,709 条无向引用边。
  作者 README 的收藏数多 1；本实验按实际文件计数，未自行补造或删减记录。
- 全部用户参与协同过滤训练；评估固定 1,000 名至少收藏 25 篇论文的用户。
  每用户随机 60%/20%/20% 划分；种子 42/43/44，共 3,000 个测试用户页。
- 每页同样的 5 篇测试收藏 + 45 篇未观察候选，推荐前 10 篇。
  每个算法共推荐 30,000 个位置；7 个方法共 21,000 个测试列表。
  未观察候选按隐式反馈惯例作为评估负例，不等于真实不喜欢。
- ItemKNN 在验证集选 k∈{{20,50,100}}；PureSVD 选秩∈{{32,64}}。
  测试收藏不参与训练或参数选择。PakPerk 保持当前评分默认值，没有为赢过基线调权。
- PakPerk 直接调用当前 Rust `build_recommendation_batch`。
  代码基线为 `{config['source_revision']}`；业务推荐算法未改。
- 95% CI：先把同一用户三次结果取平均，再对 1,000 个用户聚类自助采样 2,000 次。
  不是把同一用户的三次结果当成三个独立用户；区间未作多重比较校正。

## 最终测试集结果

数值越大越好，但覆盖率与文本多样性是辅助指标，并非相关性本身。

{chr(10).join(table)}

nDCG 衡量喜欢的论文是否排在靠前位置；Recall 衡量五篇测试收藏找回多少；
Precision 衡量十个推荐中有多少篇测试收藏；MRR 衡量第一次命中有多靠前。
目录覆盖率按每个种子计算再平均，多样性为列表内平均 1−TF-IDF 余弦。

## 配对差值

区间完全高于 0 才支持该项配对提升；包含 0 表示该实验没有给出稳定差异。

{chr(10).join(paired)}

## 各次划分与验证选择

{chr(10).join(perseed)}

## 解释范围与局限

1. 这是 50 篇受控候选中的重排实验，不是 16,980 篇全库召回。
   五篇测试正例被放入候选，绝对分数不能直接套到真实线上流量。
2. 数据没有论文时间、真实 arXiv 分类和作者关注。时间统一，分类/关注为空；
   为避免一个 unknown 分类把列表错误截成六篇，未知分类/作者/主题上限均设 50。
   其他评分、嵌入、生成器和多样性规则使用当前实现。
3. 数据包含旧论文和较活跃用户，没有验证新用户、最新论文或真实排队阅读行为。
   收藏只用来模拟归档后的历史兴趣，不能当作已读或真实 app 点赞。
4. 引用图为完全对称的无向图，映射为 reciprocal 支持；不能证明方向区分有效。
   本次有根邻居的引用测试页占比为 {timings['citation']['root_neighbor_page_fraction']:.2%}。
   PakPerk 最多 50 条历史种子、10 个引用根；传统基线使用全部训练收藏。
5. 没有明确的相关/不相关反馈。引用策略使用 .5/.5/.5 先验权重，
   **本次没有证明在线学习的增益**，也没有合成用户投票来冒充真实反馈。
6. ItemKNN/PureSVD 使用多用户收藏信号；当前 PakPerk 主要使用本人的历史、文本与引用。
   这是不同信息条件下的实用比较，不是仅替换一个打分函数的因果实验。
7. TF-IDF 用公开全目录拟合词表和 IDF，不使用测试收藏标签。引用也视为已知公共图；
   因无时间戳，不能解释为严格的未来预测或无未来信息的时序实验。

## 本机性能记录

- 默认加权：p50 {timings['weighted']['p50_ms']:.2f} ms，p95 {timings['weighted']['p95_ms']:.2f} ms。
- 引用策略：p50 {timings['citation']['p50_ms']:.2f} ms，p95 {timings['citation']['p95_ms']:.2f} ms。
- 每策略 3,000 个测试页；本机 debug 构建，仅计构造好嵌入后的排名时间，
  不含 OpenAlex、数据库、网络或 API 请求；不作跨语言运行速度排名。

## 如何继续证明真实效果

采用同构建、同候选来源、用户级随机分流的线上 A/B：主指标为每个已确认空队列
For You 会话的收藏率/新增有效收藏；辅助指标为推荐卡片拒绝率、每次找到有用论文的
时间、主动继续阅读率；约束指标为队列越权、已拒绝推荐、首屏和续页延迟。
在看结果前确定样本量/最小可检测提升和主指标；保留未收藏会话作分母。
至少同时报告相关性、覆盖、多样性和速度，不能用“测试全部通过”代替质量提升。

## 复现与证据

完整协议和命令见 [README](README.md)。原始汇总、验证选择、逐用户分数和
每次候选/正例/推荐结果随实验交付，已独立重算全部 {checks:,} 个测试列表的
nDCG 和 Recall，并核对随机基线与理论召回约 20% 一致。

环境：Python {config['python']}，NumPy {config['numpy']}，SciPy {config['scipy']}，
scikit-learn {config['sklearn']}，{config['platform']}；数值计算限制为 4 个线程。
未调用付费模型服务，未上传产品用户数据或使用 API 密钥。
"""
(args.output/'RESULTS_2026-11-22.md').write_text(report, encoding='utf-8')
with (args.output/'summary.csv').open('w', newline='', encoding='utf-8-sig') as stream:
    writer = csv.writer(stream)
    writer.writerow(['model','ndcg10','ndcg10_ci_low','ndcg10_ci_high','recall10','precision10','mrr10','hit10','coverage','diversity10'])
    for row in ordered:
        writer.writerow([row['model'],row['ndcg10']['mean'],row['ndcg10']['lo'],row['ndcg10']['hi'],
                         *[row[m]['mean'] for m in ['recall10','precision10','mrr10','hit10']],row['coverage'],row['diversity10']['mean']])
(args.output/'verification.json').write_text(json.dumps({'independently_checked_lists':checks,'timing':timings},indent=2))
print(json.dumps({'checked_lists': checks, 'ranking': [(row['model'],row['ndcg10']['mean']) for row in ordered]},ensure_ascii=False))
