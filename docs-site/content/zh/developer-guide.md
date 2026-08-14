# Pakperk 开发者指南

这是开发、测试和准备 Pakperk Production v0.0 候选版本的最短安全路径。规范性要求仍保留在
[Production v0.0 实施计划](../pakperk_production_v0_0_implementation_plan.md) 中，已实现源代码与批准发布证据之间的差异在
[完成审计](production-v0.0-completion-audit.md) 中跟踪。

## 当前状态

仓库实现是一个暗启动候选版本。访客阅读、可选账户、To Read 同步、评论和管理、账户删除、遥测、部署、发布自动化和证据验证器已实现。已提交的生产配置在对应受保护的预发布、操作、法律、设备、签名和存储门通过之前，保持账户、图书馆和评论关闭。

源代码检查不授权公开发布。不要在完成审计中未经检查的项目变成通过声明，除非其所需的不可变工件和所有者批准。

## 仓库地图

| 路径 | 目的 |
| --- | --- |
| `backend/apps/api` | Axum 公共/账户 API |
| `backend/apps/worker` | 论文元数据和准备任务 |
| `backend/apps/deletion-worker` | 租用提供者/应用程序删除任务 |
| `backend/apps/migrate` | 独立生产迁移任务 |
| `backend/apps/admin` | 最近认证的管理操作 |
| `backend/apps/telemetry-gateway` | 验证封闭的移动遥测模式 |
| `backend/crates` | 领域、数据库、认证、图书馆、评论、管理、任务、提供者和策略模块 |
| `mobile` | Flutter Android/iOS 应用程序和原生主机 |
| `site` | 静态政策、支持、删除和关联网站 |
| `deploy` | Keycloak 参考部署和生产 Helm 图表 |
| `scripts` | 检查、证据验证器、发布组装和操作演练 |
| `docs/adr` | 已接受的架构决策 |
| `docs/runbooks` | 发布、事件、恢复、管理、删除、遥测和负载程序 |

PostgreSQL 是应用程序数据、任务、共享速率限制、同步和管理的生产源真值。不要在没有 ADR 的情况下引入另一个网络服务。

## 工具链

完整的本地工具链报告缺少可选工具和每个跳过的门。一个完全代表的开发者机器需要：

- 用于 CI 和发布镜像的固定 Rust 1.91.1 工具链；
- Docker 与 Compose v2；
- Python 3 和 `jq`；
- 用于当前移动发布证据的固定 Flutter 3.44.8 / Dart 3.12.2 工具链；
- Android 工具，加上 macOS 上的 Xcode 用于 iOS 构建；
- Node/npm 用于公共网站套件；
- Helm 3.18.x 用于部署渲染；以及
- 用于相应发布检查的 Java 签名工具和 Ruby。

使用锁定文件。不要随意更新 Rust、Pub、npm、Gradle、SwiftPM、Ruby 或工作流操作输入：依赖项自动化、校验和、SBOM 清单和发布证据有意在未经审查的漂移上关闭。

## 启动访客开发堆栈

从仓库根目录：

```bash
cp .env.example .env
# Replace ARXIV_CONTACT_EMAIL with a real monitored address.
./scripts/prepare_dev_api_origin_secret.sh
docker compose up -d --build
```

只有当此命令返回 HTTP 200 时，API 才准备好：

```bash
curl --fail http://localhost:8080/health/ready
```

`/health/live` 仅证明进程正在运行。API 和 worker 拒绝占位符 arXiv 联系方式。生成的密钥文件是所有者独有，不得打印、复制到 `.env` 或提交。

运行移动应用：

```bash
cd mobile
flutter pub get --enforce-lockfile
flutter run \
  --flavor dev \
  --dart-define=PAKPERK_ENV=development \
  --dart-define=PAKPERK_API_BASE_URL=http://localhost:8080 \
  --dart-define=PAKPERK_FULLTEXT_POLICY=prototype
```

Android 模拟器通过 `http://10.0.2.2:8080` 访问主机 API；要么覆盖开发 API 定义，要么使用可以访问主机的设备/网络配置。iOS 模拟器通常使用 `http://localhost:8080`。

## 启用本地参考账户

启动单独的 Keycloak 数据库/提供者配置文件：

```bash
docker compose stop api
docker compose --profile accounts up -d postgres keycloak
./scripts/prepare_dev_account_secrets.sh
```

参考发行者是
`http://localhost:8081/realms/pakperk`。在主机上运行 API，使用根 [README](../README.md#optional-local-oidc-accounts) 中记录的账户设置。不要同时运行 Compose API：将发行者更改为容器主机名会使令牌与其中嵌入的公共发行者不一致。验证邮件可在 Mailpit 中访问 `http://localhost:8025`。

对于仅账户的客户端，使用 [`mobile/README.md`](../mobile/README.md#pakperk-mobile) 中的公共原生 OIDC 定义。已提交的 `mobile/config/dev.json` 启用账户、图书馆和评论，用于完整组合测试；在使用它时，也要启用匹配的后端账户、图书馆读写和评论读取/创建标志。移动构建必须永远不包含客户端密钥、提供者 API 密钥、管理员令牌或删除工作者凭证。

## 功能标志

所有生产功能都是独立的关闭开关：

| 标志 | 依赖和影响 |
| --- | --- |
| `ACCOUNTS_ENABLED` | 注册账户验证/资料行为 |
| `LIBRARY_ENABLED` | 需要账户；启用 To Read 读取 |
| `LIBRARY_WRITES_ENABLED` | 需要图书馆；启用保存/删除突变 |
| `COMMENTS_ENABLED` | 需要账户；注册公共讨论和安全路线 |
| `COMMENT_CREATION_ENABLED` | 需要评论；仅启用新评论发布 |
| `ACCOUNT_DELETION_ENABLED` | 需要账户和完整的工作者/账本/提供者边界 |

移动构建具有编译时 `PAKPERK_ACCOUNTS_ENABLED`、`PAKPERK_LIBRARY_ENABLED` 和 `PAKPERK_COMMENTS_ENABLED` 功能。图书馆写入、评论创建和账户删除仍然是独立的服务器端操作开关。后端和移动值仍必须描述兼容的部署产品。关闭评论创建必须保留阅读、举报、阻止、作者删除和管理可用。关闭图书馆写入必须保留图书馆阅读可用。

生产还需要 `FULLTEXT_POLICY=strict`、`PAKPERK_FULLTEXT_POLICY=strict`、`RUN_MIGRATIONS=false` 用于每个长期运行的 API、论文工作者和删除工作者进程，HTTPS 公共源、受信任的入口 CIDR 和挂载的所有者独有密钥文件。独立迁移任务拥有模式更改。

## 正常更改工作流程

1. 在更改边界之前阅读相关的 ADR 和合同文件。
2. 保持 API DTO、领域规则、持久性、移动解析和 OpenAPI 一致。响应解析器有意拒绝未知字段。
3. 添加一个只进扩展/收缩迁移。永远不要编辑已应用的迁移或让生产 API 复制在启动时与迁移竞争。
4. 保持重试写入的幂等性和论文工件的生成范围。
5. 保持访客阅读。认证仅在云拥有的或管理敏感操作时需要。
6. 永远不要让启动、feed 预取、缓存水合或图书馆同步准备论文。准备仅在提交的读者转换或显式重试后开始。
7. 保持令牌、密码、评论/举报文本、论文全文、提示和身份属性不在日志和遥测中。

当 API 表面更改时，重新生成并验证已检查的合同：

```bash
./scripts/generate_openapi.sh > docs/openapi-v1.json
./scripts/check_openapi.sh
```

当 Drift 表、索引、转换器或注释的数据库声明更改时，通过固定生成器重新生成已提交的数据库绑定；永远不要手动编辑 `app_database.g.dart`：

```bash
cd mobile
flutter pub get --enforce-lockfile
dart run build_runner build --delete-conflicting-outputs
dart format lib/core/database/app_database.g.dart
```

审查并提交生成的差异，与模式更改及其迁移/升级测试一起。无关的生成 Drift 是依赖项/工具链信号，而不是盲目丢弃的东西。

对于后端模式迁移：

1. 添加下一个只进 `backend/migrations/NNNN_description.sql` 文件；
2. 更新 `.env.example`、`deploy/helm/pakperk/values.yaml`、`values.schema.json`、`templates/validate.yaml` 和 `scripts/validate_helm_release.sh` 中的精确迁移版本；
3. 将代表旧模式数据保留和幂等重运行断言添加到独立迁移器测试中；以及
4. 创建一个新的临时数据库，如 [Tests](#tests) 所述，然后针对该确切数据库运行聚焦的升级测试：

```bash
TEST_DATABASE_URL=postgres://pakperk:pakperk@localhost:5432/pakperk_test_local_run_01 \
  cargo test --manifest-path backend/Cargo.toml --locked \
  -p pakperk-migrate \
  tests::standalone_run_bootstraps_upgrades_and_rejects_wrong_extension_namespace \
  -- --exact
```

迁移任务还需要在预发布或生产中使用真实的受保护备份标识符。合成的本地值永远不会是部署证据。

## 测试

从仓库根目录运行完整的可用工具链：

```bash
./scripts/check.sh
```

对于基于 PostgreSQL 的测试，使用一个临时数据库——而不是开发或生产数据库：

```bash
docker compose up -d postgres
# Change the suffix for every run; this database must not already exist.
docker compose exec -T postgres \
  createdb -U pakperk pakperk_test_local_run_01
TEST_DATABASE_URL=postgres://pakperk:pakperk@localhost:5432/pakperk_test_local_run_01 \
  cargo test --manifest-path backend/Cargo.toml \
  --locked --workspace --all-features
docker compose exec -T postgres \
  dropdb -U pakperk pakperk_test_local_run_01
```

为每次运行选择一个新的 `pakperk_test_local_*` 名称。永远不要将 `TEST_DATABASE_URL` 指向持久的 `pakperk` 开发数据库；集成套件直接对其目标进行迁移和写入。如果运行在清理之前失败，请勿触碰该数据库，选择另一个名称；稍后显式检查或删除旧数据库。

主要工具链覆盖仓库合同、Rust 格式/Clippy/测试、OpenAPI、发布元数据、依赖项/SBOM 政策、Flutter 格式/分析/测试和调试/模拟器工件（如有）、网站测试、Helm 和可选的容器/设备探针。最后一条说明可用检查通过的行不是发布通过：审查每个显式跳过。

有用的聚焦命令是：

```bash
cargo fmt --manifest-path backend/Cargo.toml --all -- --check
cargo clippy --manifest-path backend/Cargo.toml \
  --locked --workspace --all-targets --all-features -- -D warnings

cd mobile
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test

cd ../site
npm ci --ignore-scripts
npm test
```

不要将跳过的 PostgreSQL 测试、模拟器构建、浏览器测试、容器测试或物理设备通道视为通过的证据。

## 发布路径

发布负责人应按照以下顺序使用 [发布运行手册](runbooks/release.md) 和 [完成审计证据矩阵](production-v0.0-completion-audit.md)：

1. 获取一个干净的精确源代码规范检查，使用一个可丢弃的 PostgreSQL 数据库和所有必需的移动/网站/Helm/容器通道；
2. 运行当前的网络源代码、依赖项、密钥和容器扫描；
3. 生成确定性的通知和源代码/原生 CycloneDX 清单；
4. 执行迁移/回滚和隔离的恢复/删除重放演练；
5. 暗中部署精确的镜像摘要并证明预发布环境一致性、负载、遥测、数据保留、警报、身份验证轮换、重放、共享限制和关闭开关；
6. 验证公共 TLS 边缘、HSTS、gzip 饲料、政策/支持页面和移动关联文件；
7. 构建并绑定签名的 Android/iOS 候选版本；
8. 通过受保护的四设备验收矩阵、性能阈值和无崩溃观察窗口；
9. 获取审核、隐私、法律、内容权利、支持和商店审核批准；以及
10. 上传、验证并通过受保护的商店工作流程逐步发布。

每个工件必须绑定精确的源代码版本和提升的镜像/移动摘要。本地日志、可变 URL、票号或人类声明不能替代完成审计所需的不可变证据。

## 常见失败

- 一个功能路由返回 404：确认其后端标志已启用；缺少默认关闭路由是故意的。
- API 拒绝启动：阅读确切的验证错误并修复缺失的依赖标志、HTTPS 原点、联系人、密钥文件或生产断言。
- 本地 OIDC 令牌失败：使用公共 `localhost` 发行者和主机运行 API；不要使用仅 Docker 发行者主机名。
- PostgreSQL 测试静默地做很少事情：设置一个可丢弃的 `TEST_DATABASE_URL`。
- Flutter 发布检查漂移：使用固定 SDK 和锁定文件，然后审查任何依赖项/SBOM 差异，而不是绕过它。
- 在严格模式下派生内容消失：这是关闭失败的策略，而不是缓存错误；验证纸质许可证和后端/移动策略配对。
- `scripts/check.sh` 成功但跳过：安装/配置缺失的工具或在发布前运行相应的受保护通道。

安全事件、删除、恢复、审核、可观测性和负载事件在 [`docs/runbooks`](runbooks/) 下有专门的流程。
