# 生产版 v0.0 API 错误目录

标准的生产版 v0.0 计划要求使用以下稳定的名称。这是一个兼容性目录，而不是 API 可返回的每一种验证或服务特定错误的详尽列表；端点特定的错误仍保留在代码优先的 [OpenAPI 文档](openapi-v1.json) 中。

一个 **发出的** 名称可以出现在标准错误信封的 `error.code` 字段中。一个 **保留的** 名称是稳定词汇表的一部分，但目前并未作为错误发出。客户端必须使用文档中说明的成功表示形式来处理保留行为，并且不得在更新本地状态之前等待保留错误。

标准计划列出了 19 个名称：

| 稳定名称 | 状态 | 当前 v0.0 含义 |
| --- | --- | --- |
| `UNAUTHENTICATED` | 发出 (401) | 不存在、格式错误、无效或无法识别账户的 bearer token。 |
| `TOKEN_EXPIRED` | 发出 (401) | 一个已识别的 bearer token 已过期。 |
| `REAUTHENTICATION_REQUIRED` | 发出 (401) | 一个敏感操作需要最近的登录。 |
| `ACCOUNT_INCOMPLETE` | 发出 (403) | 一个社区操作需要账户的资料设置完成。 |
| `ACCOUNT_SUSPENDED` | 发出 (403) | 账户被暂停，无法执行请求的私有操作。 |
| `ACCOUNT_DELETION_PENDING` | 发出 (403) | 账户不可用，因为删除正在等待或已经提交。 |
| `FORBIDDEN` | 保留 | API 目前返回更具体的域代码而不是这个通用名称来表示授权拒绝。 |
| `PROFILE_VERSION_CONFLICT` | 发出 (412) | 一个资料预条件已过期；重新加载当前资料和实体标签。 |
| `HANDLE_UNAVAILABLE` | 发出 (409) | 请求的公开句柄无法被占用。 |
| `TERMS_ACCEPTANCE_REQUIRED` | 发出 (403) | 一个社区操作需要接受当前的条款和指南。 |
| `LIBRARY_OPERATION_CONFLICT` | 发出 (409) | 一个库操作 ID 被用于不同的论文或突变意图。 |
| `COMMENT_NOT_FOUND` | 发出 (404) | 请求的评论不存在或对调用者不可见。 |
| `COMMENT_EDIT_CONFLICT` | 发出 (409) | 提交编辑前评论版本已更改。 |
| `COMMENT_REJECTED` | 发出 (422) | 模块化流程拒绝了评论内容。 |
| `COMMENT_PENDING_REVIEW` | 保留 | 待审核是成功接受的写入，其私有规范评论状态为 `pending_review`；这不是错误响应。 |
| `USER_BLOCKED` | 保留 | 增删好友是幂等关系的突变，读取过滤被屏蔽的作者；关系不会作为错误响应呈现。 |
| `RATE_LIMITED` | 发出 (429) | 共享请求或突变限制已达到；请尊重 `Retry-After`。 |
| `IDEMPOTENCY_CONFLICT` | 发出 (409) | 一个评论 `client_request_id` 被用于不同的论文或规范化内容。 |
| `FEATURE_DISABLED` | 发出 (路由依赖的 404 或 503) | 请求的功能或写入路径因配置或紧急开关而被禁用。 |

稳定名称必须精确比较，不得被重新用途。特别是，库操作-ID 冲突使用 `LIBRARY_OPERATION_CONFLICT`，而评论创建请求-ID 冲突继续使用 `IDEMPOTENCY_CONFLICT`。
