# 论文发现指标：100 候选、两个基线

| 方法 | 论文覆盖率 | 推荐新颖性（bit） | 排序质量（nDCG） |
| --- | ---: | ---: | ---: |
| PakPerk | 29.33% | 9.48 | 0.4296 |
| MostPop | 13.06% | 7.96 | 0.2375 |
| DC | 19.74% | 8.16 | 0.4680 |

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
