# 阅读库同步契约

Phase 4 库是一个账户拥有的集合，名为 `to_read`。它没有文件夹、标签、优先级、注释、阅读状态或公开保存计数。服务器具有权威性；移动设备乐观地应用相同的操作，并使用变更流在设备之间达成一致。

## 可用性和授权

四个路由仅在 `ACCOUNTS_ENABLED=true` 和 `LIBRARY_ENABLED=true` 时注册。它们需要一个有效的 OIDC 令牌，该令牌映射到一个活跃的 Pakperk 账户。一个句柄和条款接受不是保存论文的先决条件。

`LIBRARY_WRITES_ENABLED=false` 是一个紧急只读开关。它保留库读取路由，并从 PUT 和 DELETE 返回 503 `FEATURE_DISABLED`。关闭库功能会移除所有四个路由；它不会改变公开论文阅读。

从 `/v1/me/library` 及其子项的每个响应，包括错误，都有 `Cache-Control: private, no-store`。浏览器客户端可以通过配置的 CORS 原点发送 `Authorization`、`Content-Type`、`Idempotency-Key`、`X-Request-Id` 和其他文档中记录的 v1 标头。

## 通信契约

```text
GET    /v1/me/library?state=to_read&cursor=&limit=
GET    /v1/me/library/changes?after_revision=&limit=
PUT    /v1/me/library/{paper_id}
DELETE /v1/me/library/{paper_id}
```

列表响应按最新的 `saved_at` 排序，然后是论文 ID，并且只包含活动项：

```json
{
  "items": [
    {
      "item": {
        "paper_id": "0198f4d7-a4ce-7b40-8ee8-4f350350810c",
        "state": "to_read",
        "saved_at": "2026-07-31T12:00:00.000Z",
        "updated_at": "2026-07-31T12:00:00.000Z",
        "removed": false,
        "removed_at": null,
        "revision": 42,
        "last_operation_id": "0198f4da-383f-77f0-9404-e6d6614d26e1"
      },
      "paper": {
        "paper_id": "0198f4d7-a4ce-7b40-8ee8-4f350350810c",
        "arxiv_id": "2401.12345v2",
        "title": "A bounded paper title",
        "abstract": "Bounded public arXiv metadata.",
        "authors": ["Ada Reader"],
        "primary_category": "cs.AI",
        "categories": ["cs.AI"],
        "published_at": "2026-07-01T00:00:00.000Z",
        "updated_at": "2026-07-02T00:00:00.000Z",
        "abs_url": "https://arxiv.org/abs/2401.12345v2",
        "pdf_url": "https://arxiv.org/pdf/2401.12345v2",
        "capabilities": {
          "metadata": true,
          "introduction": false,
          "chat": false,
          "connections": false
        }
      }
    }
  ],
  "next_cursor": null,
  "sync_revision": 42
}
```

`state` 必须是 `to_read`。`limit` 由 API 限制，游标是不透明的：客户端必须返回它们不变，且不能构造或检查它们。它们的坐标和修订边界是 AES-256-GCM 加密、认证并绑定到账户和库状态，因此令牌不能伪造或重放到另一个账户的浏览中。第一页捕获一个提交的、账户范围的 `sync_revision`；每个 `next_cursor` 携带该修订边界，每个后续页面重复相同的修订。当前规范修订超过边界行的行将被排除在后续页面之外。因为服务器只存储每篇论文的最新行，分页不是不可变的历史快照：一个并发修改的条目可能从剩余页面中消失或移动。在耗尽列表后，客户端必须从第一页的 `sync_revision` 请求更改，并事务性地应用该差异。这个强制性步骤恢复一致性。其他账户的修改永远不会推进这个水位线，也不能通过轮询空的变更流推断出来。

变更流按认证账户中的修订升序排列，并包括活动行和删除墓碑：

```json
{
  "items": [
    {
      "item": {
        "paper_id": "0198f4d7-a4ce-7b40-8ee8-4f350350810c",
        "state": "to_read",
        "saved_at": "2026-07-31T12:00:00.000Z",
        "updated_at": "2026-08-01T09:00:00.000Z",
        "removed": true,
        "removed_at": "2026-08-01T09:00:00.000Z",
        "revision": 43,
        "last_operation_id": "0198f9be-9b08-72ff-b946-62e68779ce36"
      },
      "paper": null
    }
  ],
  "next_after_revision": 43,
  "has_more": false,
  "sync_revision": 43
}
```

客户端仅在应用整个页面后才持久化 `next_after_revision`。当 `has_more` 为 true 时，它们立即请求下一页。当 `has_more` 为 false 时，`next_after_revision` 进步到页面的提交 `sync_revision`。修订可能看起来跳过，因为流返回每篇论文的最新规范状态，而不是每个被取代的操作，但另一个账户永远不会创建间隙。可选的论文投影使墓碑即使在公共元数据已被驱逐后仍保持有用。

## 变更和幂等性

所有变更都需要一个 `Idempotency-Key` 头，包含一个规范的 UUID。PUT 还需要严格的 JSON——API 拒绝未知字段——并且操作 ID 必须与头完全匹配：

```http
PUT /v1/me/library/0198f4d7-a4ce-7b40-8ee8-4f350350810c
Idempotency-Key: 0198f4da-383f-77f0-9404-e6d6614d26e1
Content-Type: application/json

{"operation_id":"0198f4da-383f-77f0-9404-e6d6614d26e1","state":"to_read"}
```

DELETE 没有请求体；其操作 ID 是头的值。即使其期望状态已经是当前的，新接受的操作也会获得一个新的单调修订。修订由事务性的用户级围栏分配，保持该账户设备之间的提交顺序，而不会序列化或暴露无关账户的活动。一个活跃的重新保存保留 `saved_at`；在移除后保存开始一个新的保存区间。移除一个从未保存的论文会产生一个墓碑，因此另一个设备的离线乐观保存仍然无效。

精确重播返回当前规范行。重用操作 ID 用于不同的论文或意图返回 409 `LIBRARY_OPERATION_CONFLICT`。这个库特定的代码与评论创建契约的 `IDEMPOTENCY_CONFLICT` 不同。已知的持久重播和冲突在消耗新变更许可前被解决，因此一个完整的速率限制桶不能将之前接受的重播变为 429。不同的操作 ID 被序列化，最后服务器接受胜出，因此普通跨设备竞争不是错误。共享的 PostgreSQL 速率限制由服务器拥有的用户 UUID 键定，并返回 429 带有 `Retry-After`。

## 保留和重置

删除墓碑保留 90 天。操作账本行在账户删除时保留，因此任意延迟的操作重播永远不会退化规范状态。清理是有限的，并在删除旧墓碑前推进每个用户的同步基线。一个客户端的 `after_revision` 在该基线以下会收到 410 `LIBRARY_SYNC_RESET_REQUIRED`；它必须事务性地从 `GET /v1/me/library` 替换其账户库，保留/重叠未发送的本地操作，记录返回的 `sync_revision`，然后继续增量更改。

从初始全局 Phase 4 时钟的正向迁移将每个现有账户的持久操作顺序重新基于其自己的修订命名空间。它在每个可能的旧检查点上方安装一个用户级重置屏障，因此一个已经同步的预迁移客户端会收到一个安全的完整刷新重置，而不是模糊地解释旧全局数字为用户级数字。新账户从修订零开始，不会支付这个迁移成本。

## 元数据和准备边界

库响应只重用 PostgreSQL 中已有的有限论文摘要元数据。在严格全文模式下，任何由记录的许可证不支持的衍生能力都会与公共论文路由上完全相同地屏蔽。列出、更改、保存和删除库项永远不会获取 arXiv、下载 PDF、排队准备、调用 GROBID 或调用模型提供者。打开保存的论文遵循普通的读取路由及其现有的显式准备边界。

## 移动收敛规则

- 偏移是可见的源；保存/删除及其出站条目在一个事务中写入。
- 一次完整刷新会持久化第一列表页的 `sync_revision`，耗尽其游标链，然后从该保存的修订应用 `/changes`，再将本地视图视为收敛。
- 每次刷新限制为 1,000 个列表或变更页（100,000 个列表行在移动页面大小下）。超过该 v0.0 安全上限被视为不一致的快照，并重试而不是运行无限制的循环。
- 一个设备按 `(user_id, paper_id)` 串行化操作。一个较新的未发送意图可能覆盖一个较旧的未发送意图，但永远不会重写一个已发送的操作 ID。
- 可重试的网络、429 和 503 故障保持乐观状态，并使用有界指数退避、正向抖动和 `Retry-After` 重试。
- 永久的验证/授权失败与规范服务器状态协调，并保持对读者的可操作性。
- 登出和账户切换会清除账户拥有的库行、同步状态和出站操作，同时保留公共论文缓存。
- 库固定保持保存的论文元数据远离普通的公共缓存驱逐。库刷新从不预加载 PDF 或衍生内容。

代码优先的 [OpenAPI 艺术品](openapi-v1.json) 是机器可读的契约。此文档记录了同步行为，其详细程度有意超过端点模式。计划规定的稳定名称及其发出或保留状态记录在 [API 错误目录](api-error-catalogue.md) 中。
