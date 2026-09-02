# 队列优先发现的部署边界

**状态：** 当前默认关闭的分阶段发布技术契约，并保留 Phase 0 基线清单
**检查日期：** 2026-08-31
**Git 基线：** `cde04d1b2c49c0c8673559fb8d7816cc604536d9`

前三节保留固定 Phase 0 Git 提交中的事实。后续各节说明截至 Plan 03 的当前实现。
不要把历史清单当作当前功能或数据库迁移清单使用。

## 固定的 Phase 0 数据库迁移事实（历史）

后端内置十项仅向前执行的 SQL 数据库迁移：

| 版本 | 文件 |
| ---: | --- |
| 1 | `backend/migrations/0001_initial.sql` |
| 2 | `backend/migrations/0002_arxiv_shared_cooldown.sql` |
| 3 | `backend/migrations/0003_chat_prompt_version.sql` |
| 4 | `backend/migrations/0004_accounts.sql` |
| 5 | `backend/migrations/0005_shared_rate_limits.sql` |
| 6 | `backend/migrations/0006_library.sql` |
| 7 | `backend/migrations/0007_per_user_library_revisions.sql` |
| 8 | `backend/migrations/0008_comments_and_moderation.sql` |
| 9 | `backend/migrations/0009_account_deletion.sql` |
| 10 | `backend/migrations/0010_user_reports.sql` |

发布/部署技术契约还要求 `.env.example`、Helm 校验模板与 README、恢复/负载证据和
运营门禁校验器都使用版本 10。该基线中不存在 `0011_reading_feed_imports.sql`。

Phase 0 计划要求未来的数据库迁移 0011 只能向前执行且必须是增量迁移；同时更新每一项
精确版本断言，使用一次性 PostgreSQL 覆盖升级和重放，并保留账户删除能力。这项工作现已成为
历史；当前数据库迁移边界记录如下。

## 固定的 Phase 0 服务端开关（历史）

在该提交中，`backend/apps/api/src/config.rs` 恰好定义以下六个 API 能力开关。
每份 `.env.example` 和 Helm 代码仓库默认值均为 false：

| 环境变量开关 | Helm 值 | 当前依赖关系/效果 |
| --- | --- | --- |
| `ACCOUNTS_ENABLED` | `features.accounts` | 启用账户验证与个人资料行为。 |
| `LIBRARY_ENABLED` | `features.library` | 依赖账户能力；注册 To Read 读取及变更操作路由。 |
| `LIBRARY_WRITES_ENABLED` | `features.libraryWrites` | 依赖 Library；单独启用保存/移除变更操作。 |
| `COMMENTS_ENABLED` | `features.comments` | 依赖账户能力；注册讨论和安全路由。 |
| `COMMENT_CREATION_ENABLED` | `features.commentCreation` | 依赖评论能力；只启用新评论发布。 |
| `ACCOUNT_DELETION_ENABLED` | `features.accountDeletion` | 依赖账户能力和删除边界。 |

在该提交中，队列优先开关或路由均没有相应的服务端字段、环境变量解析、Helm 值、
路由注册或 OpenAPI 操作。

## 固定的 Phase 0 移动端开关（历史）

在该提交中，`mobile/lib/app/feature_flags.dart` 包含四个编译期布尔值，且都默认为 false：

```text
PAKPERK_ACCOUNTS_ENABLED
PAKPERK_LIBRARY_ENABLED
PAKPERK_COMMENTS_ENABLED
PAKPERK_OPENING_MOTION_ENABLED
```

Library 和评论功能都依赖账户能力。此列表属于历史记录；当前源码还包含下文所述的
Plan 01、Plan 02 和 Plan 03 构建控制项。

## 当前数据库迁移边界

schema 18 是已接受的 Plan 02 边界；其历史发布演练从 schema 11 开始，依次应用数据库迁移 12–18。
当前 Plan 03 演练从 schema 18 开始并应用数据库迁移 19–24：准备触发审计、规范化文档模型、
Passport/溯源信息/助手、私有注释/研究记忆、版本差异，以及注释归档导入/冲突保真度。
受保护的发布门禁必须恢复 schema 18，把已审核的迁移镜像恰好一次应用到 schema 24，证明重放、
新旧版本兼容、私有数据删除及恢复后重新应用、完整性、兼容 schema 的代码回滚，以及再次向前迁移。
功能回滚会保留 schema 24；绝不会只为关闭某项能力而执行向下迁移。

## 当前默认关闭的服务端控制项

以下控制项已经实现，并会在启动时校验：

| 开关 | 必需依赖项 | 路由/行为边界 |
| --- | --- | --- |
| `ACCOUNTS_ENABLED` | 无 | 启用已认证账户/个人资料行为。 |
| `LIBRARY_ENABLED` | 账户 | 注册旧版 Library 读取和变更操作路由。 |
| `LIBRARY_WRITES_ENABLED` | Library | 单独启用规范 Library 变更操作。 |
| `COMMENTS_ENABLED` | 账户 | 注册讨论和安全路由。 |
| `COMMENT_CREATION_ENABLED` | 评论 | 单独启用新评论发布。 |
| `ACCOUNT_DELETION_ENABLED` | 账户 | 注册需要近期认证的删除操作及其持久 worker 边界。 |
| `PAPER_RESOLUTION_ENABLED` | 无；部署使用时要求受监控的 arXiv 配置和共享门禁 | 允许新的搜索/导入解析流程；不得禁用或改变现有的公开精确论文路由。 |
| `PAPER_TITLE_SEARCH_ENABLED` | 账户、论文解析 | 注册并启用有界标题搜索。 |
| `LIBRARY_IMPORT_WRITES_ENABLED` | 账户、Library、Library 写入、论文解析 | 注册并启用将指定论文幂等导入 To Read。 |
| `READING_FEED_ENABLED` | 账户和 Library | 注册已认证阅读信息流，包括证明队列为空后、受最小权威状态约束的 Recent 后备结果。 |
| `TO_READ_FIRST_ENFORCEMENT_ENABLED` | 阅读信息流 | 在已认证响应中发布 `enforcement=strict`；关闭时发布 `shadow`，为支持严格模式的客户端提供立即回滚权限。 |
| `LIBRARY_V2_ENABLED` | 账户、Library | 注册规范五状态 Library、列表、标签和统一变更信息流。 |
| `RESEARCH_PROFILES_ENABLED` | 账户 | 注册可选的未来发现偏好；绝不对队列状态执行变更操作。 |
| `RECOMMENDATIONS_ENABLED` | 账户、Library、阅读信息流 | 启用高级推荐模式、感知资料的理由、解释和反馈。该开关关闭时，阅读信息流仍可使用受最小权威状态约束的 Recent 后备结果。 |
| `RECOMMENDATION_EVENTS_ENABLED` | 无 | 注册可选、不含内容的评测事件；产品状态绝不依赖事件是否送达。 |
| `SEARCH_LOOKUP_ENABLED` | 无 | 注册确定性的公开本地元数据 Lookup。 |
| `SEARCH_EXPLORE_ENABLED` | Lookup | 注册显式、有界且包含来源诊断的 Explore。 |
| `SAVED_QUERIES_ENABLED` | 账户、Explore | 注册归账户所有的已保存查询定义。 |
| `READING_BRIEFS_ENABLED` | 阅读信息流 | 在阅读信息流的权威状态之下注册队列/发现简报。 |
| `SUBSCRIPTIONS_ENABLED` | 账户、Library、阅读信息流 | 注册私有类别/主题/作者/已保存查询订阅。 |
| `NOTIFICATIONS_ENABLED` | 订阅 | 注册感知队列状态的应用内通知投递；推送和电子邮件仍不可用。 |
| `DEEP_READER_ENABLED` | 无 | 注册规范化文档/大纲边界。Plan 03 的更深层能力仍从属于它。 |
| `PAPER_PASSPORT_ENABLED` | Deep Reader | 启用与证据关联的 Paper Passport 产物。 |
| `SEMANTIC_FACETS_ENABLED` | Deep Reader | 启用有界语义切面和来源关联定义。 |
| `VISUAL_OBJECTS_ENABLED` | Deep Reader | 启用与来源关联的插图、表格和公式对象。 |
| `ASSISTANT_V2_ENABLED` | Deep Reader | 启用经过证据 ID 校验的助手技术契约。 |
| `ANNOTATIONS_ENABLED` | 账户、Deep Reader | 启用私有同步注释和证据卡。 |
| `RESEARCH_MEMORY_ENABLED` | 账户、Deep Reader、注释 | 启用私有且可审核的记忆项目，但不授予 Library 权威状态。 |
| `VERSION_DIFF_ENABLED` | Deep Reader | 启用感知处理代次的论文版本及差异界面。 |
| `DOCLING_EXPERIMENT_ENABLED` | Deep Reader | 允许经过评测的解析器实验；它本身绝不会把 Docling 设为默认解析器。 |

当前所有可选控制项都默认为 false。启动过程会拒绝相互矛盾且涉及关键安全的组合。
可选功能路由沿用现有模式：父能力关闭时路由不存在；只有父界面可用、但其后某个写入或操作被独立禁用时，
才会明确返回 503。

移动端构建控制项默认关闭，并会校验账户/Library 依赖关系是否兼容。十项 Plan 03 构建控制分别为
Deep Reader、Passport、语义切面、文档视觉对象、阅读检查点、注释、证据卡、研究记忆、版本差异和助手 v2。
封闭的 schema-v6 功能证据和 schema-v4 候选版本/溯源信息清单会绑定全部十项控制，受保护的验收 schema v6
则定义其十个真机场景。该代码仓库机制并不等于一次通过的运行：签名设备、隐私、法律、人工、真实模型、
预发布环境和发布负责人证据仍为 `not_ready`，因此已检入代码仓库的生产值保持 false。
Helm 服务端开关绝不会改写已经签名的二进制文件。

## 运行时所有权

| 边界 | 所有权 |
| --- | --- |
| 公开发现 `GET /v1/feed` | 现有 API 路由和匿名/公开缓存；保持不变。 |
| 已认证阅读信息流 | API 编排和一次 PostgreSQL 可重复读快照；私有且不可存储，并随授权信息变化。 |
| 标题搜索和精确导入 | 已认证 API 路由使用现有 arXiv 客户端、共享数据库门禁/缓存、论文元数据存储库和 Library 服务。 |
| 队列和导入状态 | PostgreSQL 通过增量数据库迁移 11–18 管理；应用数据库迁移 19–24 后，规范 Library 修订号仍为权威状态。 |
| 资料、推荐和反馈 | 账户私有 PostgreSQL 状态，带独立的资料与反馈修订号屏障；绝不直接对队列执行变更操作。 |
| Lookup、Explore 和已保存查询 | 有界的公开本地元数据读取，加上归账户所有、由用户显式创建的已保存查询定义；不记录隐式搜索历史。 |
| 简报、订阅和通知 | 账户私有投递状态，从属于阅读信息流的权威状态；只在应用内提供。 |
| 文档准备和派生产物 | 论文 worker 具有已批准触发器审计和与解析器无关的适配器；GROBID 仍为默认值，Docling 受编译期/运行时门禁控制，而信息流/搜索/导入/Abstract 显示均不能触发深度处理。 |
| 私有研究产物 | 绑定所有者的 PostgreSQL 注释/冲突/重新锚定历史、证据卡、检查点、记忆、助手历史/溯源信息和幂等操作；共享论文产物与之分离。 |
| 移动端仲裁与存储 | 控制器按账户/认证纪元划分作用域，位于签名编译期开关之后；公开元数据缓存永远不能确立“队列为空”这一权威状态。Drift 私有正文是受平台边界保护的普通 SQLite 文本，并未使用应用层加密。 |
| 共享协议资产 | 路由实现后经过检查的 OpenAPI，以及 Rust/Dart 测试夹具一致性。 |

## Plan 02 演进与分阶段发布顺序（历史）

1. 提交技术契约和测试夹具脚手架，不引入运行时行为。
2. 在默认关闭的服务端开关后增加数据库迁移/解析/搜索/导入。
3. 在相应开关后增加阅读信息流服务和不变量测试。（已实现。）
4. 在默认关闭的开关后增加 Plan 02 Library、资料、搜索、推荐、简报、订阅和应用内通知能力。
5. 交付兼容的移动端支持，但保持隐藏且默认关闭。
6. 先在内部启用服务端能力，再逐步启用兼容的移动端用户群组。
7. 启用严格执行前，先确定最低支持旧客户端政策。

最终生产审批包会强制执行第 7 步。严格模式下渲染的 `toReadFirstEnforcement` 值要求一份规范且经所有者批准的
旧客户端政策，并绑定到指定源码、发布配置、镜像集合、图表、恢复演练和已签名移动端候选版本。封闭选项包括：
设定最低支持版本；为已识别的旧构建禁用账户和 Library 访问；或者在达到所有者提供的采用率阈值前，明确保持
建议执行期。代码仓库默认值没有定义任何阈值。执行标志为 false 的渲染结果会让此政策槽保持 `null` 且不生效。
详见[发布证据流程](runbooks/release.md#release-evidence-binding-scope)。

回滚会关闭新门禁，但不改变公开信息流或现有 Library 线协议技术契约。
在未来经过审核的技术契约阶段之前，schema 变更仍只采用增量方式。

## Plan 02 启用与回滚（历史）

所有可选的队列优先发现控制项在生产默认配置中都保持 false。分别演练每一个预发布环境开关，
保留其渲染前后值及观测到的请求结果，并在转到下一开关前恢复已审核的基线。按以下顺序启用能力：

1. 在所有新开关均为 false 时，完成 schema 11 到 18 的备份/恢复/迁移/回滚演练，以及下文所有外部门禁。
2. 启用 `PAPER_RESOLUTION_ENABLED`。证明现有公开精确论文路由和匿名 `GET /v1/feed` 保持兼容。
3. 把 `PAPER_TITLE_SEARCH_ENABLED` 和 `LIBRARY_IMPORT_WRITES_ENABLED` 作为两个独立的预发布环境变更演练。搜索依赖账户和解析。导入依赖账户、Library、Library 写入和解析。启用或禁用任意一项都不得改变另一项。
4. 启用 `READING_FEED_ENABLED`，同时保持 `TO_READ_FIRST_ENFORCEMENT_ENABLED=false`。证明 FIFO 队列行为、活动 Library 推荐排除、当前修订号游标处理、只有权威证明为空时才可推荐，以及在失败时默认拒绝的行为。
5. 启用 `LIBRARY_V2_ENABLED`，再启用 `RESEARCH_PROFILES_ENABLED`，证明资料和列表/标签/笔记操作不能取代活动队列状态。
6. 依次启用 `SEARCH_LOOKUP_ENABLED`、`SEARCH_EXPLORE_ENABLED` 和 `SAVED_QUERIES_ENABLED`。证明显式导航、有界诊断、隐私以及只通过规范 Library/导入执行保存。
7. 只有在阅读信息流的 shadow 权威状态正常后，才启用 `RECOMMENDATIONS_ENABLED`。独立演练 `RECOMMENDATION_EVENTS_ENABLED`，因为其可选事件流不是产品状态依赖项。证明 Library、资料和反馈修订号的取代机制，以及反馈身份排除。
8. 依次启用 `READING_BRIEFS_ENABLED`、`SUBSCRIPTIONS_ENABLED` 和 `NOTIFICATIONS_ENABLED`。证明活动/未知队列延后、免打扰时段、预算、到期和仅应用内投递。
9. 最后启用 `TO_READ_FIRST_ENFORCEMENT_ENABLED`；前提是兼容的已签名客户端、最低支持客户端政策、阅读信息流服务目标、不变量告警和回滚都已有受保护证据。

回滚按依赖关系的逆序操作开关。先关闭强制执行和阅读信息流的所有消费者，再关闭阅读信息流；
先关闭通知，再关闭订阅；先关闭已保存查询，再依次关闭 Explore 和 Lookup；先关闭标题搜索和导入，再关闭解析。
可选事件流可以独立关闭。保留 schema 18 并回滚到兼容镜像；不得只为禁用功能而执行向下迁移或恢复 schema 11。
只要各自依赖项允许，公开信息流、现有 Library 读取、账户删除和显式搜索导航仍保持可用。

代码仓库测试、Helm 渲染和本地 Docker Compose 是必要检查，但不是发布证据。生产启用还要求下列受保护证明：
schema 11 到 18 演练和独立恢复/删除重放；受监控的 arXiv 联系信息、共享门禁/缓存和真实适配器行为；
预发布环境开关与不变量金丝雀；隐私日志扫描；已签名真机结果；告警路由；以及数据库、平台、安全/隐私、
移动端和发布审批。可执行顺序及证据边界见[发布运行手册](runbooks/release.md#queue-first-discovery-staged-enablement)。

## 当前 Plan 03 启用与回滚

每个 Plan 03 服务端/Helm 开关及对应移动端构建开关都默认设为 false。先完成 schema 18 到 24 的
迁移/恢复/删除后重新应用门禁，再按照 [Deep Reader 分阶段发布运行手册](runbooks/deep-reader-rollout.md)
记录的依赖顺序启用 Deep Reader、Passport/切面、视觉对象、助手 v2、注释、研究记忆、版本差异，
最后才可启用任何 Docling 实验。生产环境 Plan 03 开关还要求完整 23 项门禁证据包所对应、完全一致且不可变的
`releaseEvidence.deepReaderReleaseId`。

回滚会按逆序关闭这些能力，保留旧版 Introduction 与来源访问、私有产物和 schema 24。
功能开关绝不授权向下迁移到 schema 18，也不授权把 Docling 切换为默认解析器。代码仓库检查不能充当
受保护预发布环境、人工领域、法律、真实模型、真实遥测、无障碍、已签名设备、安全或发布审批证据；
在与指定候选版本绑定的清单建立之前，所有这些门禁都保持 `not_ready`。
