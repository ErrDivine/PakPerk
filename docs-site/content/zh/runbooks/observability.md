# 可观测性、脱敏、保留与告警操作手册

Pakperk 进程通过 OTLP 与 JSON stdout 日志发出结构化的追踪/指标数据。一个由 chart 管理的节点 Collector 仅会跟踪 Pakperk 容器日志，应用容器解析与受保护字段脱敏，并导出到已配置的 HTTPS OTLP 汇点。移动端客户端只会向经过验证的 `/v1/logs` 网关发送封闭的、不含标识符的 schema；由该网关（而非应用本身）将已接受的事件转发给集群内的 Collector。

## 部署边界

- 进程 OTLP 会使用确切的集群内 `*-otel-collector:4317` 端点，且仅在 NetworkPolicy 边界内部通过明文使用。外部导出是确切的、不含凭据的 HTTPS 主机/端口，并携带来自外部 Secret 的请求头。
- 遥测网关的 `/health/live` 与 `/health/ready` 是不可缓存的网关进程信号：它们表示配置、客户端构造以及监听器设置在服务器变为可达之前已经成功完成。它们有意不去探测 Collector 接收器、导出器队列或外部汇点。请使用下文受保护的金丝雀检测以及外部观测到的 Collector 告警来获取投递证据；不要让产品可用性依赖于这条尽力而为的路径。
- 日志 DaemonSet 以只读方式挂载 `/var/log/pods`，因此需要专门的节点调度以及 Pod 安全准入审查。它没有服务账户令牌，具有只读的根文件系统、已丢弃的权能，有界的内存/批处理队列，且仅允许 DNS/上游遥测出站流量。
- `filelog` 从头开始读取，因此新调度的代理不会错过已有的容器输出。其偏移量使用 `file_storage` 扩展，存储在一个 128 MiB、限定于 Pod 范围的 `emptyDir` 中。OTLP 导出器的重试队列使用一个独立的 `file_storage` 实例以及 128 MiB 的 `emptyDir`，因此一条已被接受并设有检查点的记录，会在同一个 Pod 内的 Collector 容器重启期间保持排队状态。重试没有经过时间的到期限制；有界队列或卷饱和会转而通过 Collector 的失败/丢弃告警可见地失败。Pod 的替换、重新调度或节点丢失会丢弃这两个存储，并可能重放有界保留的日志文件。汇点必须在需要时进行去重，且告警必须能够容忍重放；请勿从日志中推断唯一的用户/会话计数。请在部署之前验证轮转与导出器队列的边界。这些 `emptyDir` 卷仅为原地容器重启提供连续性，并不构成持久状态或投递到外部汇点的证据。
- 如果集群的受限配置文件禁止使用 hostPath，请部署一个等效的、由平台拥有的节点日志代理，并且既不得禁用脱敏，也不得禁用后端 stdout 采集技术契约。请记录该例外情况及其负责人。

## 隐私与保留期

Collector 会在导出之前删除认证/cookie/API 密钥字段、请求/响应正文、查询字符串、原始 URL/路径参数、用户/账户/提供商 ID、网络地址、设备/会话标识符、评论/论文内容、私人笔记、资料标签、已保存查询定义、反馈原因、推荐证据、通知负载、异常消息/堆栈，以及源文件路径。OTLP 日志正文使用一套独立的、失败即拒绝的转换规则：只保留一个确切的移动端网关事件名称，并附带预期的 `pakperk-mobile` 服务、部署环境以及 `app.pakperk.mobile` 作用域；其余每一个标量或结构化的 OTLP 正文都会被替换为静态的 `otlp_log_body_redacted` 标记。Node 的 stdout 是一条独立的流水线：每条已解析的消息都会变成固定的 `pakperk_backend_log` 标记，但两条确切的、不含内容的告警消息除外。`external deletion ledger failed verification` 仅针对 `ERROR` 级别、且来源为 `account_deletion::worker` 的记录保留；`authenticated reading feed could not
prove queue authority` 仅针对 `ERROR` 级别、且来源为 `pakperk_api::routes::reading_feed` 的记录保留。该流水线会更新插入其固定的服务/环境身份，并只保留正文、严重级别以及 Rust 命名空间。应用诊断只使用有界的错误类别、操作类别/结果、聚合计数器以及请求 ID。请求 ID 在操作层面是随机的，且不得变成用户/会话身份。

Plan 02 诊断只能保留封闭的操作类别/结果、队列模式/原因、修订版本不匹配计数、来源/模式枚举、延迟分桶，以及聚合的条目计数与维护性移除/失败计数。它们绝不能标注或记录账户、论文/arXiv 身份、批次/反馈/资料修订版本、游标、类别/主题/作者、查询/标题/URL、私人笔记、原因详情、已保存查询/订阅密钥、通知负载或交互 ID。即便是不透明的账户或论文标识符，也会在此边界处造成被禁止的基数与关联性。

Plan 03 遵循相同的无标识符规则。解析器/模型/schema 版本属于产物溯源信息与发布绑定，而非自由格式的遥测标签。问题、答案、摘录、来源选择器、标注/冲突/证据/记忆正文、账户/论文/区块/产物/操作 ID、确切位置以及原始缓存键均被禁止。移动端 Drift 数据库存储的是普通 SQLite 文本，因此不得将遥测脱敏描述为本地加密。

生产环境运营遥测保留期确切为 30 天，除非同时批准了一份更新发布的隐私时间表及相应受保护数值。请在上游汇点强制执行到期；Collector 无法证明汇点已删除数据。访问遵循最小权限原则并接受审计。绝不能将原始生产事件复制到问题跟踪系统或长期存在的测试夹具中。

有界的导出器队列 `emptyDir` 只包含经过上述脱敏处理器处理之后的批次，并会随 Collector Pod 一同被删除。它是临时的投递状态，而非额外的保留层级；请在平台评审期间检查其节点存储与访问控制，并且绝不能将其挂载到另一个工作负载中。

## Plan 02 来源信号与启用门禁

仓库提供了封闭的阅读 Feed 决策/游标指标，以及通用的 `pakperk.operation.count` 与 `pakperk.operation.duration` 度量工具。Plan 02 的操作类别在代码中被限定为发现类 `lookup|suggestions|explore`、研究资料类 `read|write|reset`、推荐类 `feedback|event`、阅读简报创建、通知调度以及保留期清理。结果被限定为 `success|no_result|pending|deferred|rejected|retryable_failure|terminal_failure`。相应的路由 span 均以固定词表命名，并使用 `skip_all`；请求 DTO、主体、路径以及查询/过滤取值绝不会被记录为字段。队列与准入策略边界是确切的八个名称：`reading_feed.request`、`reading_feed.queue_snapshot`、`reading_feed.queue_page`、`reading_feed.recommendation_eligibility`、`reading_feed.recommendation_page`、`paper_search.request`、`paper_import.resolve` 以及 `paper_import.library_save`。导入阶段的 span 只包裹实际运行的工作，因此一次幂等重放不会假装重新解析元数据或再次写入 Library。

后端会从权威边界发出其余的来源层面接入、发现与延迟工作信号：

- `pakperk.reading_feed.stage.duration` 将 `queue_snapshot` 与 `recommendation_page` 工作区分开来，且只使用 `success|stale|rejected|unavailable` 结果。
- `pakperk.paper_search.requests`、`.duration` 与 `.candidates` 会区分 `no_result|single|ambiguous` 响应、失败情况，以及封闭的 `hit|miss|not_applicable` 缓存状态。`pakperk.paper_import.requests` 与 `.duration` 会区分一次全新提交与一次幂等重放，以及封闭的失败结果。任何查询、标题、URL、论文、账户或操作键均不会作为指标属性。
- 现有的通用操作指标就是 Lookup 与 Explore 的有结果/无结果信号。`pakperk.discovery_search.source.requests` 与 `.matches` 会附加其封闭的 `arxiv_metadata` 来源、`results|no_result` 状态以及 `partial` 覆盖分类，而不会重复通用结果。
- `pakperk.arxiv.access.count` 与 `.duration` 涵盖确切解析与标题搜索缓存、调用方限流、共享门、抓取，以及提供方限流与提供方不可用等结果。它们并不声称提供剩余配额量表：当前的提供方与共享门都无法给出真实的剩余配额值。
- `pakperk.notification.deferred.items`、`.oldest_age` 与 `.release_budget_remaining` 来自同一份聚合数据库快照。该预算是为已创建通知之后、已启用发现功能的账户所配置的本地当日剩余容量；它并非即时投递资格判定，也刻意不去猜测静默时段、频率、队列或下游投递状态。

计数、候选项、匹配项、年龄以及预算值在导出之前均为有界值。所有维度都是封闭枚举；身份信息以及用户或论文创作的内容，仍保留在计算该聚合值的服务或数据库操作内部。

移动端客户端以六个不含标识符的事件来收束其队列策略部分，这些事件会被验证 schema 的网关所接受。`recommendation_publication_rejected` 仅在响应仍属于当前账户/认证纪元时，于阅读 Feed 响应边界处发出，并使用一个封闭的队列或个性化原因。`pending_intent_age` 会以粗粒度的时长分桶，对最旧的持久保存待同步队列（outbox）行或导入草稿进行采样。导入台账在无法被验证时会发出 `unknown`，而不是声称一个具体年龄。`discovery_suppression_latency` 从显式的、限定账户范围的保存意图开始计时，并在阅读 Feed 控制器发布一个非推荐状态时结束。`discovery_unlock_latency` 仅在待同步队列（outbox）收到一次成功的最终主动移除确认之后才开始计时，此时会观测到没有剩余的移除项，也没有活跃的本地队列条目，并且只有在当前的服务器响应确认队列为空时才结束。应用终止、作用域变更、期间发生的保存/导入，或端点缺失，都会丢弃该计时样本，而不会去推断它。`library_sync_conflict` 只区分本地修订版本与远程操作的边界。`library_outbox_backlog` 携带有界的待处理计数，外加一个粗粒度的最旧年龄分桶（若 `none` 对应的待同步队列（outbox）为空）。

这些移动端信号是必不可少的队列/产品状态遥测数据。关闭个性化功能并不会启用交互遥测，也不会抑制这些不变量与同步健康观测。经脱敏处理的客户端 schema 与网关都会拒绝原始时间戳、账户/论文/操作标识符、内容以及未知属性；只有它们共享的封闭时长分桶与枚举才能被导出。

`pakperk.notification.work.items` 只接受一个封闭的工作类别与结果。其类别涵盖订阅、用户选择的提醒，以及活跃论文评估、摘要构建、过期，与延迟队列重新检查；该计数只是聚合工作量。仅提醒类的调度必须进入相同的有界工作信息与待处理指标路径。日志与 span 只包含封闭的 `evaluate_reminders` 类别与聚合计数——绝不包含账户、论文、到期时间戳、负载、笔记或标题。`pakperk.recommendation.generation.count` 与 `pakperk.recommendation.generation.duration` 只接受 `completed|superseded|retrying|failed|unavailable|idle`；时长涵盖有界的“认领到完成”轮询。这两个度量工具都不能接受作业、批次、账户、论文、查询、资料、游标或修订版本取值。`pakperk.recommendation.generator.invocations`、`.outcomes`、`.duration` 与 `.candidates` 只使用封闭的 `recent|following|author|affinity|semantic|citation|exploration` 生成器、`primary|fallback` 角色以及 `success|failure|timeout` 结果这几个维度，外加有界时长与聚合条目计数。它们不接受任何请求或身份相关的材料。`pakperk.recommendation.batch.generation.duration`、`.generated_candidates` 与 `.concentration` 会在受队列门控的引擎完成一次排序之后发出，无论是内联的 Recent 回退，还是排队生成均是如此。生成时长涵盖生成器扇出、合并、评分、重排以及解释构建；失败的构建不会伪装成已完成的批次。唯一的标签是封闭的有效模式 `recent|following|for_you|explore`，只是集中度还会附加封闭维度 `author|category|topic`。候选项计数上限为 10,000，且每个集中度样本都会被限制到 `[0,1]`。集中度使用离线评估器的最大条目占比定义：即在已完成批次中，共享同一个规范化作者、主要类别或规范化主题的条目数量的最大值，除以已完成批次大小。同一篇论文内的重复元数据取值只计一次。标签与身份信息仅在进程内被用于构建这些比例，绝不会跨越遥测 API。`pakperk.recommendation.batch.serve.count`、`.returned_candidates` 与 `.age` 按封闭的请求模式、有效模式、结果以及服务类别对页面尝试进行分类。请求/有效模式为 `recent|following|for_you|explore`（仅在尚无法选定有效模式之前才允许使用 `undetermined`）；结果为 `hit|miss|no_result|blocked|superseded|unavailable`；服务类别为 `existing_batch|inline_generation|generation_queue|pre_serve`。返回页大小上限为 100。年龄只有在实际找到一个已持久化批次时才会发出，对未来时间戳会被限制为零，且最大值限制为 30 天。推荐 API 的缓存命中信号，是现有的确切一对 `serve_class=existing_batch,outcome=hit`；符合条件模式下的无结果，是带有封闭有效模式的确切 `outcome=no_result` 样本。请勿为这两种结果创建并行的代理计数器。`pakperk.recommendation.feedback.ingestion.count` 只使用一个已经
已认证批次的封闭模式与 `applied|replayed|conflict`；无法认证所属批次的反馈没有模式标签，会从该指标中被省略。`pakperk.recommendation.feedback.signal.count` 只会附加封闭的 `relevant|not_relevant|dismissed` 信号与封闭批次模式，且仅针对一次全新的 `applied` 写入如此。幂等重放与冲突绝不会使产品反馈结果递增。这些度量工具都不接受标识符、修订版本、反馈原因、文本、查询、主题/类别或论文取值。

已认证的推荐曝光与推荐归因保存，会作为不含内容、按事件 ID 去重的行进行持久化，绑定到一个已认证的可提供批次条目与封闭的 Feed 模式。它们尚不能安全地用作在线比率指标：仓库目前只返回整批次的已接受/重复总数，因此在路由处统计已提交的事件类型会使重试被计入而虚增结果。`read_next` 是规范的 Library 状态，但并不存在于交互事件技术契约中，也不携带其来源推荐批次/模式。请勿从请求总数、通用的 Library 溯源信息或队列状态迁移中推断曝光、保存或 Read Next 比率。在这些比率可以被采信之前，必须有一个未来的来源能够按封闭模式/事件类型返回全新的已接受分解数据，并在相关的 Library 状态迁移期间保留明确的推荐归因。`pakperk.retention.removed` 只接受封闭的论文导入操作、资料操作、已保存搜索操作、交互事件、推荐批次/反馈、推荐生成作业、简报、通知、互动操作、通知工作、助手会话以及助手溯源信息这几个类别。每次清理还会发出一个封闭的成功/可重试失败操作结果。这些信号刻意无法重建交互、反馈、资料、已保存搜索、简报、订阅、通知或账户状态。

冷启动覆盖率与生产相关性仍是经外部分类的质量证据。可执行的离线评估器会将冷启动覆盖率计算为：从一个带版本、经人工整理的 `cold_start_paper_ids` 群组中检索到的 ID 数量，除以该群组中的全部 ID 数量。生产候选元数据没有经过评审的冷启动分类，因此该服务不得用论文年龄、缺失的引用邻居、生成器来源、新颖度或此前的曝光，来作为一个捏造的替代指标。同样，显式的相关反馈是一种在线产品结果，而不是人工相关性判定。在一个经过独立评审的、隐私安全的群组来源，能够在已完成批次边界处提供相同定义之前，请将带版本的测试夹具门禁与预发布/人工证据保留在外部。

在启用相应的生产开关之前，受保护的适配器必须证明以下这些隐私安全的聚合观测结果：

- 阅读 Feed 决策与活跃计数分桶；队列/推荐查询延迟；处于活跃状态的推荐来源调用（目标为零）；客户端发布拒绝；修订版本/游标陈旧度；待处理保存/导入年龄；以及抑制或解锁发现功能所需的时间；
- 按封闭生成器枚举划分的候选项计数/延迟与失败/回退；批次年龄/生成延迟、`blocked_by_queue`、缓存命中、因 library/资料/反馈修订版本变更而被取代、按符合条件模式划分的无结果、相关/忽略结果、主题/作者集中度、冷启动覆盖率，以及反馈去重/拒绝；
- Library 同步冲突/待同步队列（outbox）年龄、人工导入成功/重试，以及搜索延迟/索引使用/无结果/来源覆盖分桶；
- 延迟的发现类通知计数/年龄/发布预算，以及队列所有的通知投递结果；用户选择的提醒的已调度、已完成、重试、终态、因回滚而休眠、24 小时到期、陈旧失效以及去重结果，且只使用聚合的封闭标签；
- 外部富化配额/限流/错误（仅当此类来源确实已启用时）；以及
- 交互、批次、反馈、资料操作、已保存搜索操作、简报、订阅、通知，以及其他保留期清理相关的结果。

硬性排除与队列竞争测试夹具必须伴随这些聚合数据一同提供。缺失某个来源信号意味着发布门禁仍处于开放状态，而不是允许从 API 错误比率推断成功。已打包的 19 条规则基线包含队列权威性不变量，但其本身并不能证明全部这些 Plan 02 观测项。

已实现的来源度量工具是必要的，但并非充分的发布证据。真实的 p95 数值、来源到汇点的投递、生产环境告警评估与寻呼、汇点保留/删除、未来适配器实际公开时的提供方配额，以及经过整理的冷启动群组，仍属于外部在线证据或受保护证据。搜索溯源信息并不等同于索引使用证据：PostgreSQL 会根据已部署的数据与参数，在全文 GIN、三元组 GIN、来源/时近度索引以及顺序路径之间进行选择。请将索引使用证明绑定到已发布的迁移与查询摘要上，使用针对带版本的代表性合成数据、在隐私安全的预发布环境中运行的 `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`，外加同一部署窗口内的聚合 `pg_stat_user_indexes` 与 `pg_stat_statements` 观测结果。受保护的证据必须保留预期与实际的执行计划节点及索引名称、行数/基数估计、缓冲区与延迟边界、数据集修订版本以及负责人，但不得保留用户查询本身。请勿用仓库测试结果或推断出的替代指标来替代任何外部门禁。

每小时运行的、有界的推荐生成清理查询，还会从同一条数据库语句与快照中，返回仍处于 `queued|running` 状态的工作的聚合计数与最旧年龄。维护流程会经由 `pakperk.backlog.items` 与 `pakperk.backlog.oldest_age` 导出这些样本，使用单一封闭的 `recommendation_generation` 类别；缺失的年龄记为零，且任何被接受的年龄都会被限制在十年以内。该样本不会新增第二次查询，也不会暴露任何作业、批次、账户、论文或修订版本数据。真实的来源到汇点投递、告警阈值、寻呼以及保留期证据仍属于外部发布门禁；单独一次 `idle` 状态的生成轮询，绝不能作为积压证据。

请为每个已启用的功能保留一份隐私安全的对账记录：已渲染的开关、封闭的依赖项结果、请求结果、相关的聚合信号、清理结果、UTC 时间窗口、候选/部署身份，以及负责的所有者。这属于外部受保护证据。仓库测试、本地日志扫描或图表渲染，都无法证明真实的来源到汇点投递、保留期或寻呼。

## Plan 03 来源信号与开放的遥测门禁

后端公开以下封闭的、不含内容的度量工具：

- `pakperk.parser.run.count` 与 `.duration` 只对 `grobid|docling` 与 `success|temporary_failure|document_failure|validation_failure` 进行分类。`pakperk.parser.object.count` 记录有界的聚合 `block|figure|table|equation` 计数；`pakperk.parser.anomaly.count` 只使用 `no_heading|no_visual_objects|large_document`。
- `pakperk.preparation.decision.count` 按封闭的触发类型记录批准/拒绝决策。结合 `pakperk.paper_job.stage.count` 与 `.duration`，可以在不保留论文或操作键的情况下，区分被允许的 Introduction/Inspect/显式/已批准重新处理工作，与被拒绝或未解析的公开请求。
- `pakperk.passport.field.count` 只记录这十个固定字段键与 `supported|inferred|conflicting|not_found|not_applicable`。`pakperk.visual_object.count` 涵盖聚合、图、表或公式的提取/交付，并附带封闭的结果，包括策略拒绝与陈旧生成。
- `pakperk.assistant.phase.count` 与 `.duration` 涵盖请求、检索、回答以及溯源信息查找。结果会区分支持、部分回答、弃权、被拒绝请求/不受支持的输出、上下文未就绪、未找到、策略拒绝、限流、不可用以及失败。`pakperk.assistant.validated_evidence.count` 与 `.claim.count` 只携带有界计数。`pakperk.assistant.cost.availability.count` 记录 `reported|unavailable`；当提供方报告了用量时，`pakperk.assistant.cost.token_count` 会区分输入/输出令牌。货币成本是在下游根据一张与候选版本绑定的价格表推导得出的，绝不会在该服务内被猜测。
- `pakperk.version_diff.count`、`.duration` 与 `.item.count` 对 `build|lookup`、一个有界的完成结果，以及 `none|parser_change|item_level` 不确定性进行分类。它们不会导出差异文本或来源身份。
- `pakperk.annotation_reanchor.count` 按封闭策略 `stable_block_exact|quote_context|fuzzy_high_threshold|manual|no_match` 与结果 `anchored|uncertain|orphaned|skipped|failure` 记录该有界的后台处理过程。它不携带任何标注、账户、论文、区块、生成、选择器、引用或笔记数据；人工移动仍属于属主绑定的历史记录，而不是遥测身份信息。
- 每小时的助手清理会发出 `pakperk.retention.removed`，覆盖 `assistant_thread` 与 `assistant_provenance`；不会发出任何内容或所有者身份信息。

移动端网关只接受以下 Plan 03 事件名称及有界字段：

- `reader_entry_context`、`queue_auto_advance`、`queue_stale_cursor_recovery`、`recommendation_advance_cancelled_after_save`、`end_of_document_library_mutation` 以及 `final_item_checking_duration` 只描述封闭的入口/权威来源/结果、离线/显式操作布尔值，以及一个粗粒度的时长分桶；
- `document_cache_lookup`、`document_cache_eviction` 与 `document_cache_size` 会公开命中/未命中、一个封闭的淘汰原因，以及有界的计数/字节值；以及
- `annotation_sync_outcome` 与 `memory_lifecycle` 只公开一个封闭的操作、锚定/冲突结果或来源类型、策略类别、离线布尔值，以及有界计数。它们绝不携带选择器文本、笔记内容、来源 ID 或账户/论文身份。

有两项 Plan 03 可观测性要求，在仓库代码中被有意保持开放。任意的解析器版本与文档类别字符串，不会被接受为指标标签：版本信息绑定在溯源信息/发布证据中，而未来带边界的文档类别分类器，需要拥有自己经过评审的枚举之后，才能成为遥测数据。同样地，提供方的令牌用量有时不可用，且绝不会捏造货币成本数值。视觉对象结果具有一套已被仪表化的 schema，候选版本现在也同时拥有一个有界的派生产物生成器与一条经过策略检查的可选变体路由。目前不存在受保护的确切候选版本实时生成/投递运行，因此尚无法宣称任何实时素材生成或投递速率。受保护的遥测门禁必须协调这些局限性，证明确切候选版本的来源到汇点投递与隐私扫描，定义实时的解析器/模型/队列仪表盘与自有的告警阈值，并证明 30 天的汇点删除。当前已打包的 19 条规则告警策略本身并不能提供 Plan 03 的质量/发布仪表盘。这些实时遥测、隐私/安全、预发布以及发布批准结果仍保持为 `not_ready`，因为所有 Plan 03 开关都处于关闭状态。

## 验证与告警

经评审的、提供商中立的规则契约是 `deploy/helm/pakperk/files/alerts/pakperk-production-alert-policy.json`。`scripts/validate_alert_policy.py` 为下方每条规则固定了所需的信号、阈值、缺失数据行为、角色负责人、通知类别以及操作手册。Helm chart 会针对确切的已打包字节验证 `alerting.policySha256`，并将这些字节部署到一个内容寻址的、不可变的 ConfigMap 中。这使得已发布的策略可被审计；ConfigMap 并不是一个告警引擎，也不能证明寻呼确实有效。

平台适配器必须原样导入每一条规则而不削弱它，提供已声明的外部合成/数据库/Kubernetes/Collector 输入，并保留已导入策略摘要、已启用规则 ID、接收器归属的不可变证据，即全部 19 条规则在两个环境中都被路由到自有的 `page` 与 `ticket` 接收器类别，以及成功的预发布 page/ticket 金丝雀检测。Collector 的故障信号必须在 Collector 自身失败的导出路径之外被观测到。请勿仅因为仓库验证或一次 Helm 渲染通过，就启用生产功能开关。

这份已打包的策略是有意仅面向生产环境的：其确切的过滤器只会选中生产环境的资源与服务身份。预发布环境的金丝雀检测必须使用一份单独导入的副本，其资源过滤器选中的是预发布环境，且该预发布策略需要拥有自己的不可变适配器证据。请绑定一份经过评审的生产环境与预发布环境对比差异：金丝雀副本可以更改确切的环境过滤器与预发布接收器，但不得削弱这六项输入、19 条规则、脱敏、归属，或 30 天的保留策略。该 chart 会拒绝将已打包的生产策略挂载到预发布发布中。

发布之前：

1. 使用 chart 固定的 Collector 运行 `scripts/test_backend_log_export.sh`。它会注入一条后端容器日志，外加直接的 OTLP 日志、追踪与指标测试夹具。每一个已配置的受保护键都会同时作为信号与资源属性被测试；恶意的标量与结构化 OTLP 日志正文必须被替换，确切的移动端事件身份、固定的后端标记，以及确切的台账告警正文/严重级别/命名空间必须保留，恶意的插值及结构化 stdout 消息加上伪造的资源身份必须不出现，安全哨兵值必须被导出，而受保护的哨兵值必须不被导出。该框架还要求 Collector 的正文允许列表必须与网关事件词表确切匹配。随后它会使汇点变为不可用，对确切的台账告警记录进行检查点记录并排队，使用相同的 Pod 限定范围存储重启 Collector，恢复汇点，并要求该已排队的记录在不从源日志重新读取的情况下送达。这一本地 E2E 只是流水线与同一个 Pod 重启方面的证据，而不是真实汇点或保留期作业的证明。
2. 针对确切的预发布候选版本，扫描 API 日志、Collector 输出、外部汇点以及经脱敏的证据包，检查 To Read First 以及每一个已启用的 Plan 02 流程。证明它们不包含任何原始搜索查询或论文标题、已提交的 URL、Bearer 令牌或刷新令牌、账户/论文/批次/事件标识符、阅读 Feed/搜索游标、私人笔记、资料兴趣、已保存查询/订阅密钥、反馈原因、推荐证据或通知负载。检查解析、搜索、导入、队列模式、陈旧游标、不可用权威来源、资料/重置、批次/反馈/解释、事件、简报、订阅、通知，以及每一项保留期清理的成功与失败情况。只保留经批准的、不含内容的金丝雀数据、封闭枚举/分桶、请求 ID 以及聚合值。
   仓库字符串扫描或本地 Collector 测试，无法替代这一真实的来源到汇点观测。
3. 通过预发布环境发送有效及恶意的移动端遥测负载。要求有效事件被导出，并要求未知字段、标识符、超大负载、重定向以及错误的内容类型失败即拒绝。确认应用不会发送任何认证/cookie 请求头。
   在 To Read First 的影子分阶段发布期间，要求 `reading_feed_shadow_decision` 只包含 `shadow_decision`、`queue_authority`、固定的 `legacy_decision=public_discovery`、封闭的 `server_policy`、`queue_policy_agrees` 以及 `offline`。将其封闭的决策总数与 `pakperk.reading_feed.decisions` 进行对账；绝不能按账户、论文、游标、类别、查询、标题、URL 或令牌来关联或标注这两条数据流中的任何一条。
4. 使用非个人/内容数据的金丝雀取值检查预发布汇点，并验证经脱敏的字段确实缺失。另外，通过确切的暗部署生产 Collector/网关/适配器镜像发送一份隐私安全的金丝雀数据，并要求生产汇点中存在相同的绑定承诺。进程就绪状态与一次预发布投递，都无法替代这一生产路径观测。
5. 绑定生产环境与预发布环境的接收器/保留策略身份
分别验证两者都被确切配置为 30 天。对于生产环境保留行为测试，请播种一份有界的承诺清单，先观测每一个金丝雀条目，再在第 29 天到第 30 天之间对同一集合观测一次，并在第 30 天到第 31 天之间确认其中没有任何一个仍可被观测到。请记录规范的 UTC 播种/查询时间戳以及确切的年龄/计数，以免一个从未被摄入的金丝雀被误判为已过期。
6. 在预发布环境中重启一个代理，并记录重放量/重复数量与恢复时间。验证节点覆盖率，并确认日志轮转不会超出存储容量。

不可变策略会针对以下情况告警：API 就绪状态/错误/延迟，阅读 Feed 队列权威性失败即拒绝事件，已确认的推荐卡片泄漏，以及数据库饱和；论文/删除队列年龄与终态失败；内容审核举报年龄；认证恢复失败；Collector 拒绝/丢弃/导出失败的数据；缺失的节点代理；遥测网关拒绝激增；以及删除台账验证/容量。告警只包含聚合值或确切的、不含内容的静态消息。每条告警都会关联其角色负责人以及适用的事件响应/删除/内容审核操作手册。

`reading-feed-authority-unavailable` 是队列权威性不变量防护措施。它只选取生产环境的 `ERROR` 记录、且来源为 `pakperk_api::routes::reading_feed`，其正文确切等于 `authenticated reading
feed could not prove queue authority`，并在五分钟内计数大于零、持续 60 秒时寻呼；缺失数据视为健康。其预发布副本必须保留该阈值与持续时间，只能更改经过评审的环境/接收器绑定。绝不能引入账户、游标、类别、查询、标题、URL、令牌、论文或 arXiv 取值作为告警标签。请将每一次触发都视为强制执行的阻塞因素，并遵循[事件响应操作手册](incident-response.md)。

`recommendation-card-queue-leakage` 是已渲染卡片不变量防护措施。它只选取封闭的生产环境移动端事件 `recommendation_card_rendered`，且确切等于 `policy_consistent=false`，在五分钟内任意事件出现、持续 60 秒时寻呼，并将缺失数据视为健康。其唯一的过滤条件是封闭的事件正文、生产环境、错误的一致性结果，以及移动端服务身份；账户、游标、论文、类别、查询、标题、URL、令牌以及 arXiv 取值均被禁止使用。一次触发即代表已确认的界面泄漏，而非宽泛的 API 错误替代信号，并会阻塞强制执行的分阶段发布。

如果脱敏、导出器凭据、汇点访问权限或保留期出现问题，请停止受影响的导出，保留有界证据，在需要时轮换凭据，并遵循[incident-response.md](incident-response.md)。请勿使产品可用性依赖于移动端遥测，也不要为了恢复数据量而放松 schema 约束。
