# 生产 v0.0 API 错误目录

规范的 Production v0.0 计划要求使用下列稳定名称。本页是兼容性目录，并未穷举 API 可能返回的所有校验错误或服务专用错误；端点专用错误仍以代码优先的 [OpenAPI 规范文件](openapi-v1.json)为准。

**已发出**的名称可以出现在标准错误封装的 `error.code` 字段中。**保留**名称属于稳定词汇表，但目前不会作为错误发出。客户端必须根据文档规定的成功响应表示处理相应行为，不得等到并不存在的保留错误才更新本地状态。

规范计划列出 19 个名称：

| 稳定名称 | 状态 | 当前 v0.0 含义 |
| --- | --- | --- |
| `UNAUTHENTICATED` | 已发出 (401) | 缺少 Bearer 令牌，或令牌格式错误、无效、无法识别对应账户。 |
| `TOKEN_EXPIRED` | 已发出 (401) | 其他方面可识别的 Bearer 令牌已经过期。 |
| `REAUTHENTICATION_REQUIRED` | 已发出 (401) | 敏感操作要求用户在足够近的时间内重新登录。 |
| `ACCOUNT_INCOMPLETE` | 已发出 (403) | 执行社区操作前必须完成账户资料设置。 |
| `ACCOUNT_SUSPENDED` | 已发出 (403) | 账户已暂停，不能执行所请求的私有操作。 |
| `ACCOUNT_DELETION_PENDING` | 已发出 (403) | 账户正等待删除或删除已经提交，因此当前不可用。 |
| `FORBIDDEN` | 保留 | API 目前针对授权拒绝返回范围更窄的领域错误代码，而不使用这一通用名称。 |
| `PROFILE_VERSION_CONFLICT` | 已发出 (412) | 个人资料前置条件已过期；请重新加载当前资料及实体标签。 |
| `HANDLE_UNAVAILABLE` | 已发出 (409) | 无法注册所请求的公开用户名。 |
| `TERMS_ACCEPTANCE_REQUIRED` | 已发出 (403) | 执行社区操作前必须接受当前版本的条款和指南。 |
| `LIBRARY_OPERATION_CONFLICT` | 已发出 (409) | 同一个 Library 操作 ID 被重复用于另一篇论文或不同的变更操作意图。 |
| `COMMENT_NOT_FOUND` | 已发出 (404) | 所请求的评论不存在，或对调用方不可见。 |
| `COMMENT_EDIT_CONFLICT` | 已发出 (409) | 提交编辑之前，评论版本已经发生变化。 |
| `COMMENT_REJECTED` | 已发出 (422) | 内容审核流水线拒绝了评论正文。 |
| `COMMENT_PENDING_REVIEW` | 保留 | 待审核表示写入已成功接受，对应的私有规范评论状态为 `pending_review`；它不是错误响应。 |
| `USER_BLOCKED` | 保留 | 屏蔽和取消屏蔽属于幂等关系变更操作，读取时会过滤被屏蔽的作者；该关系不会以错误响应呈现。 |
| `RATE_LIMITED` | 已发出 (429) | 已达到共享请求或变更操作的限流阈值；请遵循 `Retry-After`。 |
| `IDEMPOTENCY_CONFLICT` | 已发出 (409) | 同一个评论 `client_request_id` 被重复用于另一篇论文或不同的规范化正文。 |
| `FEATURE_DISABLED` | 已发出（依路由而定，返回 404 或 503） | 所请求的功能或写入路径已被配置项或紧急开关禁用。 |

稳定名称按原样精确比较，绝不能改作其他用途。尤其需要注意：
Library 操作 ID 冲突使用 `LIBRARY_OPERATION_CONFLICT`，评论创建请求 ID 冲突仍使用 `IDEMPOTENCY_CONFLICT`。

## To Read First 保留词汇

To Read First 技术契约增加了下列名称。当默认关闭的父路由启用后，经过检查的 API 会发出搜索/导入及阅读信息流相关名称。父能力关闭时，对应路由仍不存在；经过检查的 OpenAPI 表达能力契约，不代表拥有分阶段发布权限。

| 稳定名称 | 状态 | 冻结含义 |
| --- | --- | --- |
| `INVALID_PAPER_INPUT` | 已发出 (400) | 严格导入/搜索的请求正文、输入类型或标识符无效。 |
| `UNSUPPORTED_PAPER_URL` | 已发出 (400) | 提交的 URL 不属于明确接受的 HTTPS arXiv 格式。 |
| `PAPER_SEARCH_QUERY_TOO_SHORT` | 已发出 (400) | 规范化标题少于最低要求的三个 Unicode 标量值。 |
| `PAPER_RESOLUTION_NOT_FOUND` | 已发出 (404) | 按指定 arXiv 标识符解析后未找到论文。 |
| `PAPER_IMPORT_OPERATION_CONFLICT` | 已发出 (409) | 同一个导入操作 ID 被重复使用，但输入指纹不同。 |
| `READING_FEED_CURSOR_STALE` | 已发出 (409) | 账户的 Library 修订号已变化；请丢弃游标并从第一页重新开始。 |
| `LIBRARY_SYNC_RESET_REQUIRED` | 已发出 (410) | 现有 Library 行为；继续接收变更前，先替换账户投影。 |
| `PAPER_SEARCH_UNAVAILABLE` | 已发出 (503) | 有界标题搜索的依赖项暂时不可用。 |
| `QUEUE_AUTHORITY_UNAVAILABLE` | 已发出 (503) | 服务器无法以权威方式选择队列或推荐模式，因此会在失败时默认拒绝。 |

新操作也会沿用 `UNAUTHENTICATED`、`ACCOUNT_SUSPENDED`、`ACCOUNT_DELETION_PENDING`、`RATE_LIMITED` 和 `FEATURE_DISABLED`，且不改变其含义。各路由的状态和重试行为详见[已认证阅读信息流](reading-feed.md)与[手动论文搜索和导入](paper-import.md)。

## 队列优先发现词汇

默认关闭的 v0.1 发现界面增加了这些稳定名称。它们不授权推荐模式；队列资格仍由服务器独立证明，并由阅读信息流作出决策。

| 稳定名称 | 状态 | 冻结含义 |
| --- | --- | --- |
| `INVALID_RECOMMENDATION_FEEDBACK` | 已发出 (400) | 反馈结构无效，或把正向信号与负面原因组合在一起。 |
| `RECOMMENDATION_ITEM_NOT_FOUND` | 已发出 (404) | 已认证账户并不拥有所请求、由服务器创建的批次/项目组合，或该组合已经不存在。 |
| `RECOMMENDATION_SERVICE_UNAVAILABLE` | 已发出 (503) | 不可变的解释或显式反馈持久化服务暂时不可用。 |
| `ACCOUNT_UNAVAILABLE` | 已发出 (403) | 执行推荐持久化操作期间，账户变为不可用。 |
| `INVALID_EVENT_BATCH` | 已发出 (400) | 可选的不含内容事件批次违反了封闭 schema，或超出时间、数量或保留边界。 |
| `INVALID_EVENT_PRINCIPAL` | 已发出 (400) | 事件摄入既未收到经过验证的账户，也未收到有效的匿名会话标识符。 |
| `INVALID_RECOMMENDATION_EVENT` | 已发出 (400) | 推荐事件与当前由服务器所有的批次/项目绑定不匹配。 |
| `INTERACTION_CONSENT_REQUIRED` | 已发出 (400) | 账户尚未存储个性化选择加入记录，却尝试收集行为数据；或者匿名会话在可验证的访客同意授权依据建立前，尝试收集任何事件。核心账户 Library 状态保持独立。 |
| `EVENT_SERVICE_UNAVAILABLE` | 已发出 (503) | 可选事件持久化暂时不可用；即使没有该服务，产品和队列状态仍具有权威性。 |
| `SAVED_SEARCH_ID_INVALID` | 已发出 (400) | 已保存查询的删除路径包含 nil UUID。不存在的非 nil ID 和属于其他作用域的非 nil ID 均收到相同、可安全重复的 204 响应。 |

## Deep Reader Assistant 反馈词汇

默认关闭的 Assistant v2 证据反馈路由增加了三个已发出的名称。
它们只描述对某一个指定答案的修正如何持久化；并非通用的评分或情感词汇。

| 稳定名称 | 状态 | 冻结含义 |
| --- | --- | --- |
| `INVALID_ASSISTANT_FEEDBACK` | 已发出 (400) | 封闭的证据修正类别、可选私有详情或必需的声明/证据目标结构无效，或者声称的目标不在持久化答案的证据映射中。 |
| `ASSISTANT_FEEDBACK_TARGET_NOT_FOUND` | 已发出 (404) | 指定的响应/线程/溯源信息元组不属于调用方、该论文和当前处理代次，或者已经过期或因其他原因不可用。这些情况有意共用一种不泄露信息的响应。 |
| `ASSISTANT_FEEDBACK_IDEMPOTENCY_CONFLICT` | 已发出 (409) | 主体已经把该操作 ID 用于另一份 Assistant 证据反馈。精确重放则返回原始的成功接收凭证。 |

## Deep Reader 研究导出词汇

私有研究导出为小型档案保留旧版单响应下载，并提供 `paged=true` 来实现无损、有界的遍历。分页游标不透明，并绑定到已认证主体及可选的论文作用域。

| 稳定名称 | 状态 | 冻结含义 |
| --- | --- | --- |
| `INVALID_RESEARCH_CURSOR` | 已发出 (400) | 游标格式错误、因密钥轮换而失效，或属于其他主体、论文作用域或导出技术契约。请不携带游标，从第一页重新开始。 |
| `RESEARCH_EXPORT_REQUIRES_PAGING` | 已发出 (413) | 旧版单响应 JSON 或 Markdown 导出超出安全上限。请改用 `paged=true`，并依次使用每个响应返回的下一页游标；系统绝不会要求用户删除有效的私有文本。 |
| `RESEARCH_EXPORT_ARTIFACT_INVALID` | 已发出 (500) | 持久化数据违反了逐项产物的响应不变量。服务会在失败时默认拒绝，且不会回显私有内容。 |
