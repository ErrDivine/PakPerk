# PakPerk：100 篇候选、两个基线对比

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

| 方法 | nDCG@10（95% CI） | Recall@10 | 目录覆盖率 |
| --- | ---: | ---: | ---: |
| PakPerk 默认策略 | 0.4296 [0.4175, 0.4408] | 40.49% | 29.33% |
| 热门推荐 | 0.2375 [0.2268, 0.2487] | 26.35% | 13.06% |
| 直接引用邻居 | 0.4680 [0.4549, 0.4799] | 44.27% | 19.74% |

展示可聚焦目录覆盖率：相比 MostPop 提升
124.64%，
相比直接引用邻居提升
48.58%。
该指标描述推荐覆盖面，不能替代相关性或用户满意度。
引用邻居在 nDCG 和 Recall 上较高，完整表格如上；不宣称 PakPerk 三项均领先。

## 配对比较

| 对照 | 指标 | PakPerk 相对变化 | 绝对差 | 配对 95% CI |
| --- | --- | ---: | ---: | ---: |
| MostPop | ndcg10 | +80.92% | +0.1921 | [+0.1760, +0.2074] |
| MostPop | recall10 | +53.66% | +0.1414 | [+0.1253, +0.1565] |
| Citation-neighbor | ndcg10 | -8.22% | -0.0385 | [-0.0474, -0.0302] |
| Citation-neighbor | recall10 | -8.52% | -0.0377 | [-0.0486, -0.0276] |

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

独立重算全部 9,000 个测试列表的 nDCG 和 Recall，核对候选数、正例数、
Top 10 唯一性及输出范围。源数据 SHA-256 与原实验清单一致。
源码基线 `f5d94ca7f9a1a1814a50b4d03908a3a742d2b43c`；生产推荐源码未改。

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
