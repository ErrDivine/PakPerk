# To Read First 第 0 阶段执行报告

**阶段：** 基线、ADR、技术契约与测试脚手架
**状态：** 已准备好接受架构审核
**记录日期：** 2026-08-19
**起始分支：** `main`
**起始提交：** `cde04d1b2c49c0c8673559fb8d7816cc604536d9`
**提交主题：** `V0.1 (almost) complete.`

在第 0 阶段开始编辑前，已通过 `git rev-parse HEAD` 记录确切的起始提交。共享工作区当时已经包含未提交的工作，其中包括提供的根目录实施计划，以及与本阶段无关的移动端/docs-site 改动；这些工作树状态不属于固定的 Git 提交。本阶段会保留这些改动，但不会把它们当作基线证据。

## 范围与决策

- 新增 [ADR 0007](../adr/0007-public-discovery-and-authenticated-reading-feed.md)，保留公开发现能力，并让已认证路由独自负责账户队列仲裁。
- 在[已认证阅读 Feed](../reading-feed.md)中冻结已认证响应结构、快照不变量、游标围栏、失败时默认拒绝的队列权威状态、验收判定条件和真值表。
- 在[手动搜索与导入论文](../paper-import.md)中冻结严格标题搜索和精确导入的请求、成功响应、URL/网络边界、幂等性、恢复流程及稳定错误。
- 在 [To Read First 部署边界](../deployment-boundaries.md)中记录当前与计划中的数据库迁移、后端开关、移动端开关、组件和分阶段发布事实。
- 在 `backend/apps/api/tests/fixtures/to_read_first/` 下新增 JSON 示例，并添加一个包含零项测试的 Rust 集成测试目标。后续实施阶段可以把同一批测试夹具绑定到 Rust 序列化器、已核验的 OpenAPI 和 Dart 解析器，而不必新增占位生产路径。

## 基线证据

已在固定提交上重新核对以下源代码事实：

- `backend/apps/api/src/app.rs` 始终注册 `GET /v1/feed`；账户和 Library 路由只会在各自现有门禁之后注册。它没有注册阅读 Feed、论文搜索或 Library 导入路由。
- `backend/apps/api/src/routes/feed.rs` 使用公开缓存策略 `public, max-age=60, stale-while-revalidate=300` 和通用论文 Feed 仓库。它不会根据账户 Library 执行仲裁。
- `backend/apps/api/src/config.rs` 包含六个功能布尔值：账户、Library、Library 写入、评论、评论创建和账户删除；其中没有任何计划中的 To Read First 开关。
- `mobile/lib/app/feature_flags.dart` 只包含账户、Library、评论和开场动效的编译期布尔值，而且默认全部关闭。
- `backend/migrations/` 截止到 `0010_user_reports.sql`；`.env.example` 声明 `PAKPERK_MIGRATION_EXPECTED_VERSION=10`。数据库迁移 0011 仍在计划中，尚不存在。
- `docs/library-sync.md` 已经定义权威的账户所属 `to_read` 集合、逐用户修订号、幂等操作、墓碑记录、私有缓存策略，以及新技术契约复用的禁止准备边界。
- `docs/openapi-v1.json` 包含 `/v1/feed`，但不包含三项计划中的操作。第 0 阶段有意不修改这份生成的技术契约。

## 对运行时的影响

无。第 0 阶段只新增文档、技术契约示例和一个空的集成测试目标。它不会：

- 注册或修改 API 路由；
- 新增数据库迁移、数据表、索引或持久化字段；
- 解析新的功能开关或更改默认值；
- 修改 OpenAPI 或生成的 docs-site 文件；
- 更改移动端代码或配置；
- 更改公开 Feed、Library 同步、worker 或准备行为。

## 已运行的检查

以下聚焦检查已于 2026-08-19 通过：

```bash
for f in backend/apps/api/tests/fixtures/to_read_first/*.json; do
  jq empty "$f"
done
git diff --check
cargo fmt --manifest-path backend/Cargo.toml --all -- --check
cargo test --manifest-path backend/Cargo.toml --locked \
  -p pakperk-api --test to_read_first_contract_scaffold
```

脚手架测试目标按预期完成编译并运行了零项测试：`0 passed; 0
failed; 0 ignored`。编译过程报告 `backend/apps/api/src/routes/mod.rs` 中存在两个此前已有或并发产生的未使用 import；它们不属于第 0 阶段的改动路径集合，也没有导致聚焦命令失败。这些文档/脚手架检查并不代表仓库范围的发布证据已经具备。

一项只读基线断言还核对了确切的提交树：十个数据库迁移名称全部按顺序存在，`.env.example` 预期版本为 10，而且 `git grep` 没有找到五个计划开关或三条计划路由路径。聚焦的相对链接检查成功解析新增或更新 Markdown 文件中的每一个本地链接，第 0 阶段完整改动路径集合的尾随空白扫描也已通过。

## 退出审核

- **已固定起始修订：** 已完成；完整 SHA 已记录在上文以及 ADR/技术契约文档中。
- **架构与公开/私有边界：** 已记录，正等待人工批准。
- **队列状态的权威性与 API 语义：** 已由链接的技术契约冻结。
- **当前数据库迁移与功能开关：** 已与计划名称分别确认。
- **运行时行为未发生变化：** 改动路径清单和聚焦检查已经证明这一点。

本报告不得把第 1 阶段或后续实施描述为已经开始。只有在架构审核获批后，第 0 阶段退出条件才算正式验收通过。
