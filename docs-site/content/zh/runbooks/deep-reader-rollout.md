# Deep Reader 分阶段发布与回滚

本运行手册用于管控 Plan 03 中默认关闭的九个开关，以及由 23 道门禁组成的完整发布证据包。它是通用[发布运行手册](release.md)的补充；不能取代迁移、恢复、部署绑定、告警适配器或签名移动端流程。

## 不可协商的准入条件

1. 生成的 OpenAPI 契约与候选版本一致，并保留旧版 Introduction 和 `/chat` 兼容路由。
2. 受保护的迁移/恢复演练从 schema 18 开始，将迁移 19 至 24 各执行一次，证明重放不会产生任何操作，执行与 schema 兼容的回滚及再次向前迁移，并针对 Plan 03 中每张归属于所有者的表重复执行删除账本重新应用流程。功能回滚必须保留 schema 24。
3. 除非解析器基准、资源预算、回退、重新处理和回滚门禁共同授权其他适配器，否则 GROBID 仍须作为配置的默认选项。
4. 全部 30 个发布开关和全部 39 条依赖边都必须与渲染后的发布技术契约核对一致。
5. 仓库、环境和 Helm 中的 Plan 03 开关，以及移动端全部十项 Plan 03 控制项，都必须保持为 false，直至 `releaseEvidence.deepReaderReleaseId` 指向经过完整验证的证据包。
6. 任何信息流、导入、预取、推荐、通知或 Abstract 展示路径都不得将深度准备任务加入队列。经批准的触发来源信息必须保留到每项任务及其派生产物中。
7. 队列导航测试必须证明：当队列状态为活动、未知、过期、待定、离线或正在切换账号时，自动推荐泄漏为零。
8. 面向公众的隐私声明和签名客户端审核材料必须说明：Drift 中的私有研究正文就是普通 SQLite 文本。当前本地安全边界由操作系统沙盒、设备访问、文件保护和备份策略构成；SQLCipher 已延期，并且不得声称应用层提供静态加密。

仓库测试只能证明可执行契约。受保护的预发布环境执行、人工领域/法律/无障碍/安全审核、真实模型/遥测、签名设备工作和发布批准，必须分别由其对应的证据来源类别提供。绝不能把仓库摘要复制到外部证据槽位中。

## 证据工作流

输出仅含要求的清单：

```bash
python3 -B scripts/deep_reader_release_evidence.py inventory
```

该输出特意不包含任何结果。受保护的生成方负责创建规范的仅所有者可访问 JSON 清单，取得经过域隔离的内容 ID，并逐一验证每份清单：

```bash
chmod 0600 protected/deep-reader/*.json
python3 -B scripts/deep_reader_release_evidence.py content-id gate protected/deep-reader/gate.json
python3 -B scripts/deep_reader_release_evidence.py validate-gate protected/deep-reader/gate.json
```

当同一个精确发布绑定下的 23 份不同清单全部就绪后，发布负责人须在最近一次运行后的 14 天内批准该精确证据包。请连同每份清单一起验证：

```bash
python3 -B scripts/deep_reader_release_evidence.py validate-bundle \
  protected/deep-reader/bundle.json \
  --gate-evidence protected/deep-reader/grobid-block-preservation.json \
  --gate-evidence protected/deep-reader/parser-benchmark-published.json
```

上述缩略命令只用于展示接口；只有提供全部 23 个 `--gate-evidence` 参数后，验证才会通过。受保护清单和原始来源记录必须存放在 Git 之外。只有最终的 `sha256:` 证据包 ID 可以写入受保护的 Helm values。

## 分阶段启用

每一步都必须遵循同一流程：先以暗发布方式部署，核验候选版本与部署的精确绑定，执行指定的仓库检查和受保护检查，仅启用本步骤指定的开关，观察范围受限的金丝雀流量，并记录变更前后的结果。

1. 完成从 schema 18 到 24 的迁移、重放、恢复/删除重新应用、schema 兼容回滚和再次向前迁移门禁，并保持所有 Plan 03 开关均为 false。仓库测试不能替代这项受保护执行。
2. 以 GROBID 启用 `DEEP_READER_ENABLED`。演练大纲/内容块分页、来源导航、大型文档、准备触发隔离、生成版本取代、缓存边界，以及队列安全的进入和退出流程。
3. 先启用 `PAPER_PASSPORT_ENABLED`，再启用 `SEMANTIC_FACETS_ENABLED`。必须提供字段级证据、未找到/部分完成状态、拒绝作答机制和领域审核。
4. 只有在提取精度和来源导航均通过后，才可启用 `VISUAL_OBJECTS_ENABLED`。必须完整演练经操作员审核的来源键工作流：从去除辅助元数据的生成，到由原子清单及哈希绑定的小型/中型/大型资源发布，再到已认证的变体选择、移动端缓存标识、题注回退和回滚。启用视觉对象前，必须完成权利审核、受保护的真实交付证据、签名设备上的渲染/来源导航/无障碍检查，并演练严格忠于来源且不做修复的受维护公式渲染器。确认 SmartMath 输入修复和清理仍处于禁用状态；格式错误的 LaTeX 或不受支持的 MathML 必须回退为可选择的精确源文本。不得把受能力门禁限制的无障碍说明重新生成视为可用功能。
5. 只有当虚构证据 ID 的数量为零、不受支持的引用和基线阈值均通过，且模型成本/延迟保持在预算内时，才可启用 `ASSISTANT_V2_ENABLED`。
6. 私有授权、同步冲突、受限的后台重新锚定、手动重新附加、导出、删除、离线和签名设备检查全部通过后，再启用 `ANNOTATIONS_ENABLED`。
7. 在注释功能之后启用 `RESEARCH_MEMORY_ENABLED`。验证审核/停用操作不会改变 Library 状态或自动信息流成员关系。
8. 不确定性、溯源信息、版本导航和旧生成版本行为全部通过后，再启用 `VERSION_DIFF_ENABLED`。
9. 仅对已批准的金丝雀用户群启用 `DOCLING_EXPERIMENT_ENABLED`。该开关不得改变已配置的默认解析器，也不得静默合并不同解析器的输出。

每个阶段都要检查解析器/模型的失败率和拒绝率、准备触发次数、来源导航失败、注释冲突/孤立率、缓存边界、队列权限违规以及保护隐私的遥测。任何确认的队列策略违规都必须立即触发呼叫；一份已渲染的告警策略不能证明在线适配器确实完成了路由。

当前源码树还不具备完成这套流程的资格。响应式视觉资源生成/清理、可选择变体、受限的移动端缓存和受维护的公式渲染已实现为仓库技术契约。由于尚不存在经过审核的持久化草稿 schema，生成无障碍说明的能力仍被刻意设为不可用。解析器/Passport/助手/视觉质量、来源关联和权利审核、隐私审核、注释/重排/差异/无障碍检查、真实流水线和回滚演练、大型文档测量、预发布环境运行以及签名设备证据，仍属于受保护的执行缺口。受影响的开关必须保持关闭；批准不能豁免这些门禁。

## 回滚

按照以下顺序关闭开关，同时确保来源仍可读取，并保留用户存储的数据：

1. `DOCLING_EXPERIMENT_ENABLED`；
2. `VERSION_DIFF_ENABLED`；
3. `RESEARCH_MEMORY_ENABLED`；
4. `ANNOTATIONS_ENABLED`；
5. `ASSISTANT_V2_ENABLED`；
6. `VISUAL_OBJECTS_ENABLED`；
7. `SEMANTIC_FACETS_ENABLED`；
8. `PAPER_PASSPORT_ENABLED`；
9. `DEEP_READER_ENABLED`。

随后，将解析器选择恢复为最近一次验证通过的 GROBID 配置，停止新增受影响任务，等待租约自然收敛或显式取代生成版本，保留私有产物，并且仅在获得批准的触发条件下执行经过测试的重新处理计划。不得仅为关闭功能而向下迁移。旧版 Introduction 和来源访问必须继续可用。保留 schema 24；schema 18 是迁移起始边界，而不是 Plan 03 的回滚目标。

发生队列泄漏时，先按照通用运行手册的指示关闭 `TO_READ_FIRST_ENFORCEMENT_ENABLED`，再关闭受影响的 Plan 03 开关。队列状态未知或待定时仍须以关闭方式失败；回滚绝不能启用推荐回退。

## 退出条件

- 精确的发布/部署/候选版本/解析器/模型/schema/提示词/语料库绑定，与全部 23 份门禁清单及证据包一致。
- 仓库、预发布环境、人工、法律、真实模型、签名设备、真实遥测、安全、无障碍和发布批准等证据类别，已在要求的位置全部具备。
- 隐私/导出/删除和内容权利审核，与最终实现的 schema 和 API 名称一致。
- 已在同一候选版本上完成分阶段回滚和重新处理演练，且没有暴露私有数据，也没有发生队列策略违规。

在上述每一项都具备受保护证据之前，发布状态必须为 `not_ready`；仓库测试通过或生成了摘要都不能改变该状态。
