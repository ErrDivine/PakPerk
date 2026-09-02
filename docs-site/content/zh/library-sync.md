# To Read Library 同步技术契约

Phase 4 的 Library 是归一个账户所有、名为 `to_read` 的单一集合。它没有文件夹、标签、优先级、备注、已读状态或公开收藏计数。服务器具有权威性；移动端以乐观方式应用相同操作，并通过变更信息流在多设备间收敛。

## 可用性与授权

只有同时满足 `ACCOUNTS_ENABLED=true` 和 `LIBRARY_ENABLED=true` 时，才会注册这四条路由。它们要求有效的 OIDC bearer 令牌，且令牌必须映射到一个有效的 Pakperk 账户。收藏论文不以设置公开昵称或接受条款为前提。

`LIBRARY_WRITES_ENABLED=false` 是紧急只读开关。它保留两条 Library 读取路由，并让 PUT 和 DELETE 返回 503 `FEATURE_DISABLED`。关闭 Library 功能会移除全部四条路由；这不会改变公开论文阅读。

来自 `/v1/me/library` 及其下级路径的每个响应（包括错误响应）都带有 `Cache-Control: private, no-store`。浏览器客户端可以通过已配置的 CORS 来源发送 `Authorization`、`Content-Type`、`Idempotency-Key`、`X-Request-Id` 和其他已有文档说明的 v1 标头。

## 线协议技术契约

```text
GET    /v1/me/library?state=to_read&cursor=&limit=
GET    /v1/me/library/changes?after_revision=&limit=
PUT    /v1/me/library/{paper_id}
DELETE /v1/me/library/{paper_id}
```

列表响应先按最新的 `saved_at` 排序，再按论文 ID 排序，且只包含有效项目：

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

`state` 必须严格为 `to_read`。API 会限制 `limit`，游标则是不透明的：客户端必须原样返回游标，不得构造或检查游标。游标中的坐标与修订隔离线采用 AES-256-GCM 加密和认证，并绑定到账户与 Library 状态，因此令牌无法伪造，也无法重放到另一账户的遍历中。第一页会捕获一个已提交且限定账户范围的 `sync_revision`；每个 `next_cursor` 都携带该修订隔离线，后续每一页也会重复同一修订。当前规范修订已超过隔离线的行会从后续页面中排除。由于服务器只存储每篇论文的最新行，分页并非不可变的历史快照：并发变更的项目可能从余下页面消失，或移动到其他页面。列表遍历完成后，客户端必须从第一页的 `sync_revision` 开始请求变更，并在事务中应用该增量。这一强制步骤会恢复收敛。其他账户的变更绝不会推进这个水位线，也无法通过轮询空的变更信息流推断出来。

变更信息流在已认证账户内按修订升序排列，同时包含有效行和移除墓碑：

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

客户端只有在本地事务中应用整页内容后，才持久化 `next_after_revision`。当 `has_more` 为 true 时，客户端立即请求下一页。当 `has_more` 为 false 时，`next_after_revision` 会推进到该页已提交的 `sync_revision`。修订号看似可能跳号，因为信息流返回每篇论文的最新规范状态，而不是每项已被取代的操作；但其他账户绝不可能造成缺口。可选的论文投影使墓碑即使在公开元数据随后被淘汰后仍然有用。

## 变更与幂等性

两种变更都要求提供一个 `Idempotency-Key` 标头，其中包含规范 UUID。PUT 还要求严格 JSON——API 会拒绝未知字段——且正文中的操作 ID 必须与标头完全一致：

```http
PUT /v1/me/library/0198f4d7-a4ce-7b40-8ee8-4f350350810c
Idempotency-Key: 0198f4da-383f-77f0-9404-e6d6614d26e1
Content-Type: application/json

{"operation_id":"0198f4da-383f-77f0-9404-e6d6614d26e1","state":"to_read"}
```

DELETE 没有请求正文；其操作 ID 就是标头值。新接受的操作会取得新的单调递增修订，即使其目标状态已经是当前状态也一样。修订通过按用户划分的事务性隔离线分配，在不串行化或暴露无关账户活动的前提下，保留该账户各设备之间的提交顺序。对有效收藏再次执行收藏会保留 `saved_at`；移除后再收藏则开始新的收藏时段。移除从未收藏过的论文也会产生墓碑，从而仍能压制另一台设备上的离线乐观收藏。

完全相同的重放会返回当前规范行。若将一个操作 ID 复用于不同论文或意图，则返回 409 `LIBRARY_OPERATION_CONFLICT`。这个 Library 专用代码不同于评论创建契约的 `IDEMPOTENCY_CONFLICT`。系统会先处理持久记录的已知重放和冲突，再消耗新的变更许可，因此已满的限流桶不会把先前接受的重放变成 429。不同操作 ID 会串行处理，最后一次被服务器接受的操作胜出，所以普通的跨设备竞态不是错误。共享 PostgreSQL 限流以服务器持有的用户 UUID 为键，并返回带 `Retry-After` 的 429。

## 保留与重置

移除墓碑保留 90 天。v0.0 中的操作台账行会保留到账户删除，因此无论操作重放延迟多久，都绝不会让规范状态倒退。清理过程有界，并会先推进按用户划分的同步下限，再移除旧墓碑。若客户端的 `after_revision` 低于该下限，会收到 410 `LIBRARY_SYNC_RESET_REQUIRED`；客户端必须通过 `GET /v1/me/library` 在事务中替换其账户 Library，保留并重新叠加尚未发送的本地操作，记录返回的 `sync_revision`，再恢复增量变更同步。

从 Phase 4 初始全局时钟向前迁移时，会把每个现有账户的持久操作顺序重新映射到自己的修订命名空间。迁移会安装一条按用户划分、且高于所有可能旧检查点的重置屏障，因此已在迁移前完成同步的客户端会收到一次安全的完整刷新重置，而不会含糊地把旧全局编号理解为按用户编号。新账户从修订零开始，无需承担这项迁移成本。

## 元数据与准备边界

Library 响应只复用 PostgreSQL 中已有的有界论文摘要元数据。在严格全文模式下，记录的许可不支持的任何派生能力都会与公开论文路由完全一致地被屏蔽。列出、更改、收藏和移除 Library 项目绝不会获取 arXiv 内容、下载 PDF、将准备任务加入队列、调用 GROBID 或调用模型提供商。打开已收藏论文时会沿用普通 Read 路由及其现有的明确准备边界。

## 移动端收敛规则

- Drift 是可见的事实来源；收藏/移除操作及其待同步队列（outbox）条目会在同一事务中写入。
- 完整刷新会持久化第一页列表的 `sync_revision`，遍历完其游标链，再从所保存的修订开始应用 `/changes`，之后才会将本地视图视为已收敛。
- 每次刷新最多处理 1,000 个列表页或变更页（按移动端页面大小计算为 100,000 个列表行）。超过这项 v0.0 安全上限会被视为快照不一致并触发重试，而不会执行无界循环。
- 单台设备会按 `(user_id, paper_id)` 串行处理操作。较新的未发送意图可以取代较旧的未发送意图，但绝不会改写已发送的操作 ID。
- 可重试的网络错误、429 和 503 故障会保留乐观状态，并使用有界指数退避、正向抖动和 `Retry-After` 重试。
- 永久性验证/授权失败会与规范服务器状态对账，并继续向读者提供可操作的处理方式。
- 退出登录和切换账户会清除归账户所有的 Library 行、同步状态和待同步队列（outbox）操作，同时保留公开论文缓存。
- Library 固定项会避免已收藏论文元数据被常规公开缓存淘汰。Library 刷新绝不会预加载 PDF 或派生内容。

代码优先的 [OpenAPI 规范文件](openapi-v1.json)是机器可读技术契约。本文档记录的同步行为有意比端点架构更为详细。计划要求的稳定名称及其已发出或保留状态记录在 [API 错误目录](api-error-catalogue.md)中。
