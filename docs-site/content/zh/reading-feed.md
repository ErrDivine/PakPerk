# 已认证阅读信息流契约

**状态：** Plan 02 队列仲裁与推荐交接已在默认关闭的服务器标志之后实现
**契约基线：** `cde04d1b2c49c0c8673559fb8d7816cc604536d9`

本文档定义 To Read First 功能的 API 和失败时拒绝的客户端语义。已认证路由、标志、快照仓库和加密游标均已实现；兼容客户端的分阶段发布仍由独立的强制开关管辖。公开信息流的分离方式由 [ADR 0007](adr/0007-public-discovery-and-authenticated-reading-feed.md)确定。

## 可用性与请求

```http
GET /v1/me/reading-feed?recommendation_mode={optional}&category={optional}&cursor={optional}&limit={optional}
Authorization: Bearer <access-token>
```

| 查询参数 | 类型 | 契约 |
| --- | --- | --- |
| `recommendation_mode` | `recent \| following \| for_you \| explore`，可选 | 明确提供的值优先。省略时，服务使用账户已存储的 `preferred_discovery_mode`；若资料查询不可用或失败，则安全回退到 `recent`。只有本次请求证明有效队列为空后，生效模式才会被使用，并且它不能覆盖队列的权威状态。 |
| `category` | 字符串，可选 | 现有的有界 arXiv 分类语法。它只限定推荐范围；绝不会隐藏有效队列项目或改变有效项目计数。 |
| `cursor` | 字符串，可选 | 由这一指定账户/查询遍历返回的不透明 `reading_feed.v1` 续页值。 |
| `limit` | 整数，可选 | 正数页面大小；默认 20，最大 50。 |

仅当以下服务器能力全部为 true 时，才注册该路由：

```text
ACCOUNTS_ENABLED=true
LIBRARY_ENABLED=true
READING_FEED_ENABLED=true
```

`TO_READ_FIRST_ENFORCEMENT_ENABLED` 是独立的分阶段发布开关，用于在受支持的已登录客户端中将此路由设为规范路由。它依赖 `READING_FEED_ENABLED`；不得形成只注册一部分的路由。

对于已认证会话，服务器策略和签名客户端能力共同构成以下失败时拒绝的分阶段发布矩阵：

| 客户端强制能力 | 服务器 `enforcement` | 渲染结果 |
| --- | --- | --- |
| 关闭 | `shadow` | 旧版公开发现；只计算并发送闭合集合的影子决策。 |
| 关闭 | `strict` | 旧版公开发现；此构建不是执行强制规则的客户端，不能计入全面采用。 |
| 开启 | `shadow` | 取得当前账户/当前纪元响应后的旧版公开发现；这是即时回滚路径。 |
| 开启 | `strict` | 已认证的队列优先界面。 |

在支持 strict 的客户端获得当前已验证账户响应前，或遇到不可用、格式错误、属于先前账户或先前纪元的响应时，它会抑制公开发现并在失败时拒绝。访客仍使用公开发现。将 `strict` 改为 `shadow` 会重新激活并重新验证公开预加载；将 `shadow` 改为 `strict` 会先停用公开预取，再发布账户信息流。服务器值为 `strict` 不会升级旧版构建或关闭该能力的构建，因此最低客户端版本/采用批准仍是独立生产门禁。[生产发布证据流程](runbooks/release.md#release-evidence-binding-scope)要求负责人为 strict 渲染提供一项指定的最低版本、禁用旧版访问或在达到门槛前发出提示的策略；流程不定义默认采用门槛。

此路由的每个成功与错误响应都包含：

```http
Cache-Control: private, no-store
Vary: Authorization
X-Request-Id: <request-id>
```

成功响应还可以包含不透明的 `ETag`。它绝不会继承公开信息流的缓存策略或游标。只有再次检查相同的本地失败时拒绝谓词后，`304` 才允许复用表示；在发生本地变更后，它并不能作为队列为空的新证明。

## 响应架构

响应是一个不含账户标识符的严格 JSON 对象：

| 字段 | 类型 | 契约 |
| --- | --- | --- |
| `enforcement` | `"shadow" \| "strict"` | 当前服务器分阶段发布策略。兼容且支持 strict 的客户端只在值为 `strict` 时渲染已认证界面；`shadow` 会在后台计算决策，同时让旧版发现保持可见。 |
| `mode` | `"to_read" \| "recommendations"` | 在响应快照上作出的决策。 |
| `decision.policy_version` | `"queue_first_v1"` | 本契约理解的确切服务器队列仲裁策略；未知值会让兼容客户端在失败时拒绝。 |
| `decision.library_revision` | 非负整数 | 决策和游标使用的账户范围修订隔离线。 |
| `decision.active_to_read_count` | 非负整数 | 同一快照中的有效队列计数。 |
| `decision.queue_proven_empty` | 布尔值 | 仅在成功证明计数为零时为 true。 |
| `batch_id` | UUID 或 null | 持久推荐批次的页面范围来源记录。队列页面绝不含批次；推荐页面可以同时包含批次 ID 和 `next_cursor`，续页也可以使用不同的批次 ID。 |
| `items` | 数组 | 最多为已接受的页面上限；项目规则取决于 `mode`。 |
| `next_cursor` | 字符串或 null | 绑定账户、模式、修订、查询、密钥纪元和过期时间的不透明续页值。 |
| `server_time` | RFC 3339 UTC 字符串 | 服务器观测时间；其本身不是队列的权威状态。 |

每个项目都把现有严格 `PaperSummary` 作为 `paper`，另有取决于模式的 `queue` 和闭合集合的 `source` 值：

| 模式 | `queue` | `source` | 必需不变量 |
| --- | --- | --- | --- |
| `to_read` | `{state, saved_at, revision, save_source_kind}` | `"to_read"` | 论文在决策隔离线处是此账户有效的 Inbox/Read next/Reading 行；`recommendation` 为 null。 |
| `recommendations` | `null` | `"recent_v1" \| "following_v1" \| "for_you_v1" \| "explore_v1"` | 决策隔离线处的有效计数为零，排除规则已应用，且 `recommendation` 包含实际模式、不可变理由代码/标签和说明可用性。 |

当 `READING_FEED_ENABLED=true` 且 `RECOMMENDATIONS_ENABLED=false` 时，唯一符合条件的推荐路径是持久化的最小 `recent_v1` 批次，该批次绑定同一空 Library 权限和最终修订复查。这样可以在不启用 Following、For You、Explore、资料衍生理由、说明或反馈路由的情况下，确保游标和阅读简报来源记录安全。其项目设置 `explanation_available=false`；仅当受推荐门禁保护的说明路由可用时，配置的增强批次才会将其设为 true。

决策元组在内部保持一致：

| `mode` | 有效计数 | `queue_proven_empty` | 推荐来源 |
| --- | ---: | ---: | --- |
| `to_read` | 大于零 | false（否） | 不得调用。 |
| `recommendations` | 零 | true（是） | 每页恰好可以调用一次。 |
| 没有权威快照 | 未知 | 绝不合成 | 返回 `503 QUEUE_AUTHORITY_UNAVAILABLE`。 |

每个权威行还要求 `decision.policy_version="queue_first_v1"`。缺失或未知的策略值不是兼容的队列权威状态，必须沿用不可用/失败时拒绝路径，而不得根据 `mode` 或计数猜测。

第一页由一条 SQL 语句或一个只读的可重复读事务生成。跨无关快照计数和选择无效。

## To Read 示例

```json
{
  "enforcement": "shadow",
  "mode": "to_read",
  "decision": {
    "policy_version": "queue_first_v1",
    "library_revision": 128,
    "active_to_read_count": 1,
    "queue_proven_empty": false
  },
  "batch_id": null,
  "batch_metadata": null,
  "items": [
    {
      "paper": {
        "paper_id": "0198f4d7-a4ce-7b40-8ee8-4f350350810c",
        "arxiv_id": "2401.12345v2",
        "title": "A bounded paper title",
        "abstract": "Bounded public arXiv metadata.",
        "authors": ["Ada Reader"],
        "primary_category": "cs.AI",
        "categories": ["cs.AI"],
        "published_at": "2026-07-01T00:00:00Z",
        "updated_at": "2026-07-02T00:00:00Z",
        "abs_url": "https://arxiv.org/abs/2401.12345v2",
        "pdf_url": "https://arxiv.org/pdf/2401.12345v2",
        "capabilities": {
          "metadata": true,
          "introduction": false,
          "chat": false,
          "connections": false
        }
      },
      "queue": {
        "state": "inbox",
        "saved_at": "2026-07-31T12:00:00Z",
        "revision": 126,
        "save_source_kind": "title_search"
      },
      "source": "to_read",
      "recommendation": null
    }
  ],
  "next_cursor": null,
  "server_time": "2026-08-19T12:00:00Z"
}
```

Read 信息流按 `saved_at ASC, paper_id ASC` 排列队列项目。现有 Library 管理列表可以继续采用最新优先顺序。

## 推荐示例

```json
{
  "enforcement": "shadow",
  "mode": "recommendations",
  "decision": {
    "policy_version": "queue_first_v1",
    "library_revision": 129,
    "active_to_read_count": 0,
    "queue_proven_empty": true
  },
  "batch_id": "0198f4d7-a4ce-7b40-8ee8-4f350350830e",
  "batch_metadata": {
    "profile_revision": 7,
    "feedback_revision": 12,
    "algorithm_version": "recommendations_v1",
    "recommendation_policy_version": "weighted_v1"
  },
  "items": [
    {
      "paper": {
        "paper_id": "0198f4d7-a4ce-7b40-8ee8-4f350350820d",
        "arxiv_id": "2501.01010v1",
        "title": "A discovery candidate",
        "abstract": "Bounded public arXiv metadata.",
        "authors": ["Grace Researcher"],
        "primary_category": "cs.LG",
        "categories": ["cs.LG"],
        "published_at": "2026-01-03T00:00:00Z",
        "updated_at": "2026-01-03T00:00:00Z",
        "abs_url": "https://arxiv.org/abs/2501.01010v1",
        "pdf_url": "https://arxiv.org/pdf/2501.01010v1",
        "capabilities": {
          "metadata": true,
          "introduction": false,
          "chat": false,
          "connections": false
        }
      },
      "queue": null,
      "source": "for_you_v1",
      "recommendation": {
        "mode": "for_you",
        "reason_codes": ["feedback_category_affinity"],
        "reason_label": "Based on your relevance feedback",
        "explanation_available": true
      }
    }
  ],
  "next_cursor": null,
  "server_time": "2026-08-19T12:00:00Z"
}
```

推荐会排除有效行、保留的移除墓碑、基础 arXiv 身份重复项，以及当前发布策略下不可用的论文。这些排除通过有界数据库反连接实现，而非无界内存列表。

`batch_metadata` 与 `batch_id` 的存在条件完全一致。它会重复生成该不可变批次时持久化的资料与反馈修订隔离线，以及算法和评分策略版本。队列页面和无批次的按时间回退页面会把两个字段都返回为 null。只有当整个元组、Library 修订、所选模式和强制策略仍与新的服务器权限匹配时，移动端才可以复用限定账户范围的缓存批次。

推荐批次限定为由一个空队列权威快照授权的确切时间顺序候选页。游标续页会再次证明队列权威状态，因此可以返回不同的不可变 `batch_id`；兼容客户端只会在强制规则、队列决策/Library 修订、生效推荐模式和 `batch_metadata` 仍兼容时接受该页。在内存中追加页面后，客户端会保留每个项目的来源批次 ID 及其从零开始的页内重排位置，用于说明、反馈、收藏和交互事件。客户端绝不会把包含不同批次的合并游标遍历序列化到一个批次 ID 下，也不会将其缓存为单一批次。

## 反馈、资料与批次修订隔离线

推荐反馈绝不会决定队列资格。接受 `relevant`、`not_relevant` 或 `dismissed` 操作会推进一条独立且单调递增的反馈修订。每个账户批次会持久化该修订，并在持久化和提供服务前再次检查该修订、可选研究资料修订、Library 修订和已证明为空的权限。反馈或资料修订发生变化会取代旧的 `building` 或 `ready` 批次；重放无法让它们再次成为当前批次。

同一快照的候选查询会排除反馈中保留的每个确切论文身份与基础 arXiv 身份。`not_relevant` 和 `dismissed` 也是硬性重排排除项。尚未过期的合格曝光并不证明用户不喜欢或已经读完：它们只会带来有界的重复曝光惩罚。

只有已经启用个性化时，正面反馈才会创建分类亲和度。它会推进资料修订，并以 `source=feedback` 存储论文的主分类；它绝不会变成明确关注项。For You 可以使用另行标注的 `feedback_affinity` 和 `inferred_affinity` 来源及匹配的理由代码。Following 只使用明确的分类、主题和作者，因此其说明不能对反馈得出或推断的材料声称 `you follow`。关闭个性化后，不会再创建反馈衍生分类亲和度；明确的负面反馈仍作为确切论文排除项。

`GET /v1/discovery/profile/interests` 和资料导出会分开显示 `explicit`、`feedback` 与 `inferred` 组。它们不会公开按时间排列的原始反馈或交互台账。资料 Reset All 会删除原始推荐反馈、其修订隔离线、交互、批次和非明确兴趣；账户删除会级联清除相同的账户所有数据。

说明和项目的 `reason_codes` 架构是闭合的。14 个受支持代码包括 `saved_query_match`；与它对应的闭合候选来源是 `saved_query`。这组搭配表示归该账户所有的真实已保存查询匹配了论文，并不声称用户明确关注某个主题或作者。

## 阅读简报权限

阅读简报只使用 `/v1/me/reading-briefs` 下专用的已认证创建/当前和进度界面，包括 `/v1/me/reading-briefs/{brief_id}/progress`。阅读信息流请求可以包含归账户所有的 `brief_id`；只有当该简报的确切 Library 修订与队列/推荐权威状态匹配返回页面时，响应才会包含可空、只读的 `brief` 摘要 `{id,position,total,complete}`。这不是第二套创建、选择、游标或进度权威机制：信息流不能更新简报；绑定不存在、不匹配或不可用时返回 `brief=null`，而不会削弱权威信息流。简报创建使用已存储资料的 `brief_size`（15–25，默认/回退为 20）。明确请求的推荐模式优先；省略时使用已存储的 `preferred_discovery_mode`，若无法读取资料则安全回退到 `recent`。这些偏好只选择符合条件的简报材料，绝不会改变队列权威状态。队列简报可以概括有效工作，发现简报只能根据已证明为空的权威状态创建；但是读取、推进、完成、关闭或让简报过期，都不能改变或证明有效 Library 计数。只有新的阅读信息流快照和已确认的规范 Library 变更操作能做到这一点。

## 游标与修订行为

游标使用新的加密用途 `reading_feed.v1`，并绑定：

- 已认证的本地用户 ID；
- `to_read` 或 `recommendations` 模式；
- Library 修订隔离线；
- 队列或推荐排序坐标；
- 分类/生效推荐查询和页面大小策略；
- 游标密钥纪元/版本和过期时间。

To Read 坐标为 `saved_at, paper_id`。每次续页前，服务器都会将当前账户修订与游标隔离线比较。不匹配时返回 `409 READING_FEED_CURSOR_STALE`；客户端会丢弃游标并从第一页重新开始。跨账户或用途错误的游标无效，并且绝不会泄露另一账户是否存在。

## 失败时拒绝的移动端权限

移动端将权限建模为闭合状态，而非布尔值：

```text
unknown | localNonEmpty | pendingSave | serverConfirmedNonEmpty |
serverConfirmedEmpty | stale
```

以下渲染真值表具有权威性：

| 认证 | 本地有效行 | 待处理收藏/导入 | 服务器/同步权限 | 可见结果 |
| --- | ---: | ---: | --- | --- |
| 已退出 | 不适用 | 不适用 | 不适用 | 现有公开发现信息流。 |
| 已登录 | 大于零 | 任意 | 任意 | To Read；抑制推荐。 |
| 已登录 | 零 | 是 | 任意 | 待处理收藏/To Read 转换；立即抑制推荐。 |
| 已登录 | 零 | 否 | 未知 | 正在检查或不可用；不显示推荐。 |
| 已登录 | 零 | 否 | 已确认非空 | 只获取/渲染服务器 To Read。 |
| 已登录 | 零 | 否 | 已在 `queue_first_v1` 下确认当前修订为空 | 允许推荐。 |
| 已登录 | 陈旧缓存行 | 否 | 需要同步重置 | 需要完整同步；不显示推荐。 |
| 已登录 | 零 | 否 | 认证/身份提供商不可用 | 失败时拒绝；不显示推荐。 |
| 已登录，最终移除待处理 | 本地为零 | 没有收藏 | 尚未确认移除，也未再次确认为空 | 正在完成队列；不显示推荐。 |
| 账户/认证纪元正在变化 | 任意 | 任意 | 来自旧范围的响应 | 丢弃响应并重置为未知。 |

只有在以下所有谓词仍成立时，才可以发布推荐响应：

```text
signed in
AND response.mode == recommendations
AND response.decision.policy_version == queue_first_v1
AND response.decision.queue_proven_empty == true
AND response.decision.active_to_read_count == 0
AND local authority == serverConfirmedEmpty
AND no pending save/import/remove conflict exists
AND account scope and authentication epoch match request start
AND response library_revision remains the accepted decision fence
```

任何谓词失败都会取消/停用推荐预取、清除其续页值、保留普通公开元数据缓存行，并重新开始队列仲裁。离线或缓存状态可以证明非空，但只有当前服务器决策可以证明为空。

## 稳定失败

失败使用现有的严格错误响应封装：

```json
{
  "error": {
    "code": "QUEUE_AUTHORITY_UNAVAILABLE",
    "message": "The To Read queue could not be verified.",
    "retryable": true,
    "request_id": "0198f500-0000-7000-8000-000000000099"
  }
}
```

功能专用失败为 `READING_FEED_CURSOR_STALE`（409，从第一页重试）和 `QUEUE_AUTHORITY_UNAVAILABLE`（503，可重试）。现有认证、速率限制、功能禁用和 Library 同步重置错误保持当前含义。

契约测试固件位于 `backend/apps/api/tests/fixtures/to_read_first/`。已检查的 OpenAPI 目前会发布此操作，而运行时注册仍取决于账户、Library 和阅读信息流能力。

## 运维与分阶段证据

设计目标为阅读信息流每月可用性至少达到 99.9%，缓存第一页服务器 p95 不超过 250 ms。队列优先正确性是一项 100% 不变量：任何在没有权威空队列证明时显示推荐的情况都是严重级别 1。在受保护的预发布与生产观测证明这些目标前，它们只是目标；仓库测试并不声称测得了服务性能。

只有在论文解析及任何独立选择的搜索/导入能力通过各自门禁后，才可在预发布环境启用 `READING_FEED_ENABLED`。在按照发布形态构建的数据库和 API 拓扑中证明以下所有事项时，保持 `TO_READ_FIRST_ENFORCEMENT_ENABLED=false`：

- 有效队列按 FIFO 返回 To Read 项目，并且绝不调用推荐；
- 只有以权威方式计数为零的可重复读快照才可以返回推荐，并排除有效 Library 项目；
- 陈旧、用途错误和跨账户游标会在失败时拒绝，且不暴露账户状态；
- 队列变更、游标续页、计数、模式与页面保持修订一致；并且
- 成功与错误响应始终保持私有/禁止存储且按授权变化。

兼容的移动构建将这组确切的标志搭配用作影子模式：它们继续渲染旧版公开发现，同时在后台运行账户范围的队列权威状态控制器和已认证阅读信息流请求。唯一新增的移动事件是 `reading_feed_shadow_decision`。其架构闭合为影子决策、队列权威状态枚举、常量旧版决策、闭合服务器策略、一个决策一致性布尔值和离线布尔值。它不接受账户、论文、游标、分类、查询、标题、URL、令牌、计数或自由格式错误值。请先将这些聚合值与服务器的 `pakperk.reading_feed.decisions` 指标比较，再开放新界面。影子遥测只用于诊断；缺少该遥测绝不能使产品变为可用，也不能削弱失败时拒绝策略。

生产告警 `reading-feed-authority-unavailable` 会对确切的 `ERROR` 消息 `authenticated reading feed could not prove queue authority` 触发通知；该消息来自 `pakperk_api::routes::reading_feed`（五分钟内大于零，持续 60 秒）。缺少数据视为健康。生产策略和预发布副本策略必须只保留环境、服务、严重性、Rust 命名空间和固定消息等闭合标签；绝不能添加账户、游标、分类、查询、标题、URL、令牌、论文或 arXiv 标识符。强制执行前，要演练保护隐私的预发布金丝雀与通知路由。请参阅[可观测性运行手册](runbooks/observability.md#verification-and-alerts)。

只有在兼容的签名客户端通过队列权威状态真值表、最低支持客户端策略获得批准，且发布记录绑定 SLO 观测、不变量金丝雀、告警投递、隐私扫描、回滚演练和负有责任的批准后，才能启用强制规则。回滚时先关闭强制规则，再关闭阅读信息流。公开发现信息流、Library 读取和加法迁移 11 至 18 会保留。
