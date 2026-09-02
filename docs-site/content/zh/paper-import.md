# 手动论文搜索与导入契约

**状态：** Phase 2 实施；除非启用相应的默认关闭功能开关，否则端点保持暗置
**提取基线：** `cde04d1b2c49c0c8673559fb8d7816cc604536d9`

手动添加拆分为有界的标题搜索和幂等的精确导入。两者都是经过认证的服务器操作。移动端绝不直接调用 arXiv，API 也绝不获取用户提交的 URL。

每个成功与错误响应都仅限账户私有，并带有 `Cache-Control: private,
no-store`、`Vary: Authorization` 和 `X-Request-Id`。除非其完整的父级能力已启用，否则这些路由不存在。

## 标题搜索

```http
POST /v1/me/paper-searches
Authorization: Bearer <access-token>
Content-Type: application/json
```

注册路由要求 `ACCOUNTS_ENABLED=true`、`PAPER_RESOLUTION_ENABLED=true` 和 `PAPER_TITLE_SEARCH_ENABLED=true`。

严格请求架构：

| 字段 | 类型 | 边界 |
| --- | --- | --- |
| `query` | 字符串 | 必填；进行 Unicode/空白规范化；长度为 3–300 个 Unicode 标量值；拒绝 NUL 和普通空白以外的控制字符。 |
| `limit` | 整数 | 可选；必须为正数且最多为 10；默认值由服务器策略提供。 |

未知字段会被拒绝。原始标题不会放入 URL、日志、指标、跟踪属性或持久操作台账。

```json
{
  "query": "Attention Is All You Need",
  "limit": 8
}
```

成功响应的严格架构：

| 字段 | 类型 | 契约 |
| --- | --- | --- |
| `query_id` | UUID 字符串 | 不透明的请求/结果关联标识符；不是账户身份。 |
| `normalized_query` | 字符串 | 返回给调用者的规范化已提交标题；服务绝不记录该值。 |
| `candidates` | 数组 | 数量从零到已接受的上限；搜索不会收藏任何候选项。 |
| `candidates[].arxiv_id` | 字符串 | arXiv 提供时采用带版本的规范 arXiv 标识符。 |
| `candidates[].title` | 字符串 | 有界 arXiv 元数据。 |
| `candidates[].authors` | 字符串数组 | 有界作者投影。 |
| `candidates[].abstract` | 字符串 | 有界摘要元数据。 |
| `candidates[].primary_category` | 字符串 | arXiv 主分类。 |
| `candidates[].categories` | 字符串数组 | 有界分类投影。 |
| `candidates[].published_at` | RFC 3339 UTC 字符串 | 发布时间戳。 |
| `candidates[].updated_at` | RFC 3339 UTC 字符串 | 元数据更新时间戳。 |
| `candidates[].abs_url` | HTTPS URL 字符串 | 由服务器构造的规范 arXiv 摘要 URL。 |
| `candidates[].match.kind` | `"title"` | v1 的闭合集合匹配类型。 |
| `candidates[].match.rank` | 正整数 | 仅在本次结果内保持稳定的顺序。 |

```json
{
  "query_id": "0198f500-0000-7000-8000-000000000001",
  "normalized_query": "Attention Is All You Need",
  "candidates": [
    {
      "arxiv_id": "1706.03762v7",
      "title": "Attention Is All You Need",
      "authors": ["Ashish Vaswani", "Noam Shazeer"],
      "abstract": "The dominant sequence transduction models are based on complex recurrent or convolutional neural networks.",
      "primary_category": "cs.CL",
      "categories": ["cs.CL", "cs.LG"],
      "published_at": "2017-06-12T00:00:00Z",
      "updated_at": "2023-08-02T00:00:00Z",
      "abs_url": "https://arxiv.org/abs/1706.03762v7",
      "match": {
        "kind": "title",
        "rank": 1
      }
    }
  ]
}
```

服务器会复用现有的安全标题查询构造器、arXiv 客户端、共享 PostgreSQL 预留/速率门禁和持久查询摘要缓存。它只返回候选项，不会向上插入每条结果，也不会自动选择第一个匹配项。

## 精确导入

```http
POST /v1/me/library/imports
Authorization: Bearer <access-token>
Idempotency-Key: 0198f500-0000-7000-8000-000000000010
Content-Type: application/json
```

父路由的注册要求 `ACCOUNTS_ENABLED=true`、`LIBRARY_ENABLED=true` 和 `PAPER_RESOLUTION_ENABLED=true`。成功写入还要求 `LIBRARY_WRITES_ENABLED=true` 和 `LIBRARY_IMPORT_WRITES_ENABLED=true`；后者仍是独立的运行时紧急关闭开关，关闭时返回 `FEATURE_DISABLED`。

`Idempotency-Key` 和正文中的 `operation_id` 必须是同一个规范 UUID。严格请求是一个可辨识联合类型：

```json
{
  "operation_id": "0198f500-0000-7000-8000-000000000010",
  "source": {
    "kind": "arxiv_url",
    "value": "https://arxiv.org/abs/1706.03762"
  },
  "target_state": "inbox",
  "save_source_kind": "arxiv_url"
}
```

```json
{
  "operation_id": "0198f500-0000-7000-8000-000000000011",
  "source": {
    "kind": "arxiv_id",
    "value": "1706.03762v7"
  },
  "target_state": "inbox",
  "save_source_kind": "title_search"
}
```

| 字段 | 类型 | 契约 |
| --- | --- | --- |
| `operation_id` | UUID 字符串 | 必需的持久幂等标识符；必须与标头一致。 |
| `source.kind` | `"arxiv_url" \| "arxiv_id"` | 闭合集合判别字段。标题搜索选中的结果使用 `arxiv_id`。 |
| `source.value` | 字符串 | 必需的有界输入；先解析和规范化，再进行解析查询。 |
| `target_state` | `"inbox"` | 必需的明确队列意图；导入不能写入其他 Library 状态。 |
| `save_source_kind` | `"arxiv_url" \| "arxiv_id" \| "title_search" \| "lookup" \| "discovery" \| "connection" \| "other"` | 必需的闭合来源记录。直接 URL/ID 来源必须与 `source.kind` 一致；上下文发现流程保留其实际来源。 |

成功响应会结合规范解析结果、现有 Library 行结构、现有 `PaperSummary` 和已提交的账户修订：

```json
{
  "result": "saved",
  "resolution": {
    "input_kind": "arxiv_url",
    "canonical_arxiv_id": "1706.03762v7"
  },
  "item": {
    "paper_id": "0198f4d7-a4ce-7b40-8ee8-4f350350810c",
    "state": "inbox",
    "private_note": null,
    "save_source_kind": "arxiv_url",
    "saved_at": "2026-08-19T12:00:00Z",
    "updated_at": "2026-08-19T12:00:00Z",
    "reviewed_at": null,
    "archived_at": null,
    "removed": false,
    "removed_at": null,
    "revision": 130,
    "last_operation_id": "0198f500-0000-7000-8000-000000000010"
  },
  "paper": {
    "paper_id": "0198f4d7-a4ce-7b40-8ee8-4f350350810c",
    "arxiv_id": "1706.03762v7",
    "title": "Attention Is All You Need",
    "abstract": "Bounded public arXiv metadata.",
    "authors": ["Ashish Vaswani", "Noam Shazeer"],
    "primary_category": "cs.CL",
    "categories": ["cs.CL", "cs.LG"],
    "published_at": "2017-06-12T00:00:00Z",
    "updated_at": "2023-08-02T00:00:00Z",
    "abs_url": "https://arxiv.org/abs/1706.03762v7",
    "pdf_url": "https://arxiv.org/pdf/1706.03762v7",
    "capabilities": {
      "metadata": true,
      "introduction": false,
      "chat": false,
      "connections": false
    }
  },
  "sync_revision": 130
}
```

在 v1 中，`result` 的闭合集合值为 `saved`，包括对已完成操作的完全相同重放。响应使用 v2 Library 项目，从而不把 Inbox 状态、私有备注字段和已接受的收藏来源记录反向投影到旧版 `to_read` 结构。重放会返回当前规范数据，而不分配第二项操作或队列行。目标状态和收藏来源记录都是操作指纹的一部分，因此使用不同意图复用操作 ID 会产生冲突。

## 接受的输入与网络边界

严格解析器最初接受：

```text
https://arxiv.org/abs/{id}
https://arxiv.org/pdf/{id}
https://arxiv.org/pdf/{id}.pdf
bare arXiv identifier through kind=arxiv_id
```

除非后续契约变更明确选择加入并添加测试固件，否则不接受 `https://export.arxiv.org/abs/{id}`。生产/预发布环境会拒绝 HTTP、用户信息、自定义端口、意外的查询/片段数据、非 arXiv 主机、欺骗性子域、IP 字面量、重定向、短链接、任意 PDF、编码主机技巧、路径遍历，以及格式错误/不受支持的标识符。

解析后，服务器会丢弃已提交 URL，并通过共享精确解析服务按规范化 arXiv 标识符解析。已提交 URL 绝不会成为 HTTP 目的地。解析或导入绝不会下载 PDF、创建准备任务、调用 GROBID 或调用模型。

## 幂等性与恢复

加法迁移会先按 `(user_id, operation_id)` 预留导入操作，此时内部论文 UUID 不一定已经存在。它存储带版本的输入指纹、仅在安全解析后存储的规范化 arXiv 基础标识、最终论文 ID、闭合集合状态和时间戳。它绝不存储原始 URL 或标题。

| 重放状态 | 结果 |
| --- | --- |
| 相同操作和指纹，已完成 | 返回规范的已收藏结果。 |
| 相同操作，不同指纹 | `409 PAPER_IMPORT_OPERATION_CONFLICT`。 |
| 元数据向上插入后进程停止 | 重试会安全地解析/向上插入，并继续执行 Library 收藏。 |
| 收藏后、响应前进程停止 | 重试会返回已提交的规范收藏状态。 |

调用 arXiv 时不会保持任何数据库事务打开。在仓库边界允许的范围内，最终 Library 状态、按用户划分的修订、现有 Library 操作记录和导入完成状态会原子提交。

## 稳定错误

所有失败都使用现有的 `{ "error": { "code", "message",
"retryable", "request_id" } }` 信封。

| HTTP | 代码 | 可重试 | 含义 |
| ---: | --- | :---: | --- |
| 400 | `INVALID_PAPER_INPUT` | 否 | 严格正文、判别字段、标识符或输入无效。 |
| 400 | `UNSUPPORTED_PAPER_URL` | 否 | URL 不属于接受的 arXiv 形式。 |
| 400 | `PAPER_SEARCH_QUERY_TOO_SHORT` | 否 | 规范化标题少于三个标量值。 |
| 404 | `PAPER_RESOLUTION_NOT_FOUND` | 否 | 未找到确切的 arXiv 论文。 |
| 409 | `PAPER_IMPORT_OPERATION_CONFLICT` | 否 | 操作 ID 被复用于不同输入。 |
| 429 | `RATE_LIMITED` | 是 | 账户/来源或上游策略拒绝了本次尝试；请遵循 `Retry-After`。 |
| 503 | `PAPER_SEARCH_UNAVAILABLE` | 是 | 搜索依赖项暂时不可用。 |
| 503 | `FEATURE_DISABLED` | 取决于上下文 | 某个部署紧急关闭开关处于关闭状态。 |

契约测试固件位于 `backend/apps/api/tests/fixtures/to_read_first/` 下，是代码优先 OpenAPI 架构以及服务/API 不变量测试的补充。

## 独立的预发布启用流程

先启用 `PAPER_RESOLUTION_ENABLED`，并证明现有公开精确论文路由保持不变。然后把标题搜索和导入作为两项独立的预发布变更进行演练：

- 在设置 `PAPER_TITLE_SEARCH_ENABLED=true` 前，标题搜索要求账户、论文解析、受监控的 arXiv 联系方式，以及共享数据库门禁/缓存；并且
- 在设置 `LIBRARY_IMPORT_WRITES_ENABLED=true` 前，导入要求账户、Library、Library 写入和解析。关闭导入开关时，必须保留 Library 读取和普通的收藏/移除行为。

对每个开关，都要保留渲染后的关闭/开启/关闭值、允许请求与禁用请求的结果、有界配额/缓存行为、上游降级结果和清理证据。启用搜索/导入不会启用阅读信息流，也不会启用严格的队列优先强制规则。

受保护的隐私扫描必须覆盖 API 日志、Collector 输出、外部汇和保留的证据。扫描不得发现原始搜索查询或论文标题、已提交 URL、bearer 令牌或刷新令牌、账户标识符或游标。解析后会丢弃已提交 URL，并且它绝不能作为出站目的地出现。证据只能保留闭合集合的操作/输入类型/结果枚举、长度/结果分桶、请求 ID、聚合计数和经批准的不含内容的金丝雀值。

仅仅通过解析器测试、模拟 arXiv 响应或 Helm 渲染，不能证明真实边界。发布证据必须绑定确切且受监控的 arXiv 联系方式、共享多副本门禁/缓存、受保护预发布适配器、按账户和上游划分的限制、重试行为、不触发准备断言、隐私扫描，以及服务/隐私/发布批准。标题搜索和导入要独立回滚；只有两个消费者均已关闭后，才能关闭解析能力。
