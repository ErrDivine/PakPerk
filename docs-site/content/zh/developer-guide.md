# Pakperk 开发者指南

本指南是参与 Pakperk 开发的起点。它会说明各组件分别在哪里运行，带您在本地跑通访客版应用，并指引您阅读真机调试和服务器部署的进阶指南。

除非段落另有说明，本指南中的每个 shell 代码块都应视为相互独立，并从仓库根目录开始执行。以 `cd mobile` 或 `cd docs-site` 开头的代码块，只会在该代码块的执行过程中切换目录。

> **第一次使用？** 请从头到尾完成[在本地运行 Pakperk](#run-pakperk-locally)，之后再启用账户或可选功能。默认访客技术栈经过刻意精简，是了解整个系统最容易的起点。

## 选择所需路径

| 目标 | 从这里开始 |
| --- | --- |
| 在同一台开发电脑上运行 API 和应用 | [在本地运行 Pakperk](#run-pakperk-locally) |
| 在 Android 真机或 iPhone 真机上调试 | [在真机上测试 Pakperk](mobile-device-development.md) |
| 将后端安装到预发布或生产服务器 | [部署后端](backend-deployment.md) |
| 了解系统为何采用这些边界 | [架构](architecture.md)和[部署边界](deployment-boundaries.md) |
| 构建已签名的移动端发布版本 | [移动端发布](mobile-release.md) |
| 查看哪些生产声明仍缺少证据 | [Production v0.0 完成度审计](production-v0.0-completion-audit.md) |

本仓库是暗发布候选版本，并不能证明它已获准公开发布。源代码、本地测试和健康的预发布路由，都不能替代完成度审计所跟踪、在受保护环境中取得的运维、法律、隐私、无障碍、签名、应用商店和人工审核证据。

## 先建立实用的系统认知

Pakperk 主要由五个部分组成：

1. Flutter 应用向 API 请求公开 Feed 和论文数据。账户专属功能是可选的；只有应用与后端同时启用兼容的功能开关时，这些功能才会显示。
2. Axum API 验证请求并读写 PostgreSQL。PostgreSQL 还承担持久化队列、共享限流存储和内容审核唯一可信数据源的职责；系统不依赖 Redis、Kafka 或 NATS。
3. 论文 worker 以租约方式从 PostgreSQL 领取论文预处理任务，获取获准使用的源材料，调用 GROBID 解析材料，并可调用已配置的模型提供商。论文预处理必须由明确操作触发；仅仅打开应用或刷新 Feed，绝不会附带触发预处理工作。
4. 独立的删除 worker 通过身份提供商和一份单独备份的签名账本，协调执行账户删除。它有意与普通论文 worker 隔离。
5. 静态 `site/` 项目提供公开政策、支持、删除说明和应用关联文件。`docs-site/` 项目就是本开发者文档网站。两者都不是 API。

本地访客开发使用 Docker Compose 运行 PostgreSQL、GROBID、API 和论文 worker。预发布和生产环境支持的部署形态则是 Kubernetes Helm Chart。Compose 有意简化本地开发，但也有意不具备直接暴露到公共互联网所需的安全性。

## 安装开发工具

请使用仓库固定的版本，不要直接采用当前最新版本。

| 工具 | 用途 |
| --- | --- |
| Rust 1.91.1 | 构建、测试后端和制作发布镜像 |
| 支持 Compose v2 的 Docker | 运行本地数据库、解析器、API 和 worker |
| Flutter 3.44.8 与 Dart 3.12.2 | 构建当前 Android 和 iOS 应用 |
| Android SDK 工具 | 构建 Android、运行模拟器、使用 `adb` 和调试真机 |
| macOS 上的 Xcode | 构建 iOS、运行模拟器、完成签名和调试 iPhone 真机 |
| OpenSSL 工具 | 生成仅所有者可读的本地 API 和账户密钥文件 |
| Python 3 和 `jq` | 运行仓库验证器和小型维护工具 |
| Node.js 22.13 或更高版本、npm 和 Pandoc | 构建公共网站与开发者文档网站 |
| Helm 3.18.x 工具 | 渲染和验证部署用 Chart |

Java 签名工具、Ruby 和应用商店命令行工具只在对应发布门禁中需要。主检查脚本会报告缺少的可选工具和被跳过的门禁，而不会悄悄把它们当作通过。

锁文件和工作流中固定的输入是发布控制的一部分。不要随意更新 Rust、Pub、npm、Gradle、SwiftPM、Ruby、镜像或工作流 Action 的版本。校验和、软件清单和证据验证器就是用来发现未经审核的版本漂移的。

## 在本地运行 Pakperk

除非步骤另有说明，本节所有命令都从仓库根目录开始执行。

### 1. 创建本地配置

复制失败时默认拒绝的配置模板：

```bash
cp .env.example .env
```

打开 `.env`，将会被拒绝的 `ARXIV_CONTACT_EMAIL` 占位值替换为真实、有人监控的地址。arXiv 要求 API 客户端注明可以联系到的联系人，因此 API 和 worker 都会拒绝占位值或示例域名地址。

首次运行时，请让可选能力开关保持为 `false`。尤其是在基本访客路径可用之前，不要启用账户、Library、评论、删除、发现或 Deep Reader 功能。

生成本地源地址哈希和游标加密所需的密钥文件：

```bash
./scripts/prepare_dev_api_origin_secret.sh
```

该脚本会在 `.local/pakperk-secrets/` 下写入仅所有者可读的文件。它只输出文件路径，不输出密钥值。不要把密钥值复制到 `.env`、打印到日志或提交到仓库。

### 2. 启动访客后端

```bash
docker compose up -d --build
```

首次构建可能需要几分钟。查看服务状态和 API 日志：

```bash
docker compose ps
docker compose logs --tail=100 api
```

等待就绪端点成功：

```bash
curl --fail http://localhost:8080/health/ready
```

HTTP 200 表示 API 可以连接 PostgreSQL，并且迁移与必需扩展的技术契约有效。`/health/live` 只能证明 API 进程正在运行。就绪检查**不能**证明 GROBID、模型提供商、OIDC、后台 worker、遥测投递、DNS 或 TLS 处于健康状态。

如果就绪检查失败，请在重启任何组件之前，先查看 API 和迁移日志：

```bash
docker compose logs --tail=200 api postgres
```

为方便本地开发，Compose 中的 API 会应用数据库迁移。长期运行的预发布和生产进程必须改用 `RUN_MIGRATIONS=false`；独立迁移 Job 才是 schema 变更的唯一负责人。

迁移只创建数据表，不会预置论文。如果接下来的任务需要证明真实 API 数据可用，而不只是验证网络连通性，请立即载入仓库中已提交的演示元数据：

```bash
./scripts/seed_demo.sh
curl --fail http://localhost:8080/v1/feed | jq '.items | length'
```

返回数量应大于零。`seed_demo.sh` 会使用 `.env` 中配置的身份信息联系 arXiv。准备 Introduction 和 Connections 内容属于另一项速度更慢、依赖提供商的操作；只有任务确实需要验证这条路径时，才运行 `./scripts/preprocess_demo.sh`。移动应用也包含明确标注的内置演示论文，因此仅在屏幕上看到论文，并不能证明当前运行的数据库中已存在该论文。

### 3. 运行 Flutter 应用

在第二个终端中执行：

```bash
cd mobile
flutter pub get --enforce-lockfile
flutter devices
flutter run \
  --flavor dev \
  --dart-define=PAKPERK_ENV=development \
  --dart-define=PAKPERK_API_BASE_URL=http://localhost:8080 \
  --dart-define=PAKPERK_FULLTEXT_POLICY=prototype
```

这个 URL 可直接用于 iOS Simulator。Android 模拟器通过 `http://10.0.2.2:8080` 访问开发电脑，因此要把 API 基础 URL 替换为该地址。真机还需要额外的网络路由和签名设置；请按[真机指南](mobile-device-development.md)操作，不要猜测局域网地址。

构建变体与环境必须成对匹配：

| Flutter 构建变体 | `PAKPERK_ENV` | 应用身份后缀 |
| --- | --- | --- |
| `dev` | `development` | `.dev` |
| `staging` | `staging` | `.staging` |
| `prod` | `production` | 无 |

如果二者不匹配，应用会在启动时拒绝运行。这项早期失败机制可以防止携带某个环境身份的构建版本悄悄以另一个环境的身份通信。

### 4. 验证基本路径

在应用中确认公开 Feed 可以打开，并且能够选择一篇论文。保持 `flutter run` 连接，打开它输出的 DevTools 链接，选择 **Network** 视图，刷新 Feed，并确认 `GET /v1/feed` 成功。同时在开发电脑上独立验证实际 API 响应：

```bash
curl --fail http://localhost:8080/v1/feed | jq '.items | length'
```

默认的精简 API 日志不会为每个请求输出一行，因此在 `docker compose logs` 中搜索 `/v1/feed` 不能作为连通性测试。全新数据库返回零条数据是有效结果，而且应用仍可能显示内置演示 Feed。如果任务必须验证真实后端数据，请先执行上述预置步骤，确认 API 返回数量大于零，再用手机 DevTools 中的请求证明应用实际走过哪条网络路径。

要运行仓库门禁所使用的同一条可重复后端测试命令，请执行：

```bash
cargo test --manifest-path backend/Cargo.toml --locked --workspace --all-features
```

要运行可重复的移动端检查，请执行：

```bash
cd mobile
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

完整仓库门禁为：

```bash
./scripts/check.sh
```

该检查刻意覆盖很广，因此可能耗时较长。请阅读末尾的跳过项报告：设备、签名、Helm 或外部服务门禁被跳过，并不代表通过。

### 5. 停止本地技术栈

```bash
docker compose down
```

该命令会保留命名数据库卷。只有在您明确要销毁本地数据库状态，并确认其中没有任何仍需保留的数据时，才使用会删除卷的命令。

## 仅在确有需要时启用本地账户

参考身份提供商使用独立的 Compose profile。其签发者 URL 对外使用 `localhost`，因此在此工作流中 API 必须运行在宿主机上；为 `localhost` 签发的令牌，不得使用只有容器内部才能解析的主机名进行验证。

首先停止 Compose API，启动 PostgreSQL 和 Keycloak，并创建本地账户密钥材料：

```bash
docker compose stop api
docker compose --profile accounts up -d postgres keycloak
./scripts/prepare_dev_account_secrets.sh
```

然后按照[账户认证](account-authentication.md)配置宿主机 API 所需的确切环境变量。参考签发者 URL 为 `http://localhost:8081/realms/pakperk`，验证邮件会显示在 `http://localhost:8025` 的 Mailpit 中。

仓库中已提交的 `mobile/config/dev.json` 会同时启用账户、Library 和评论。后端也必须启用兼容的账户、Library 读取/写入和评论读取/创建开关。移动端构建中绝不能包含客户端密钥、提供商 API 密钥、管理员令牌或删除 worker 凭据。

当一项改动涉及多个功能时，请从依赖链底部开始依次启用，并按相反顺序停用。启动过程会拒绝无效的组合。完整依赖图和分阶段发布证据位于相应的功能文档中，包括[发现与 Library](discovery-and-library.md)和 [Deep Reader 发布运行手册](runbooks/deep-reader-rollout.md)。

## 使用聚焦的编辑与测试循环

### 后端改动

1. 更改系统边界前，先阅读相关 ADR 和技术契约。
2. 确保领域规则、持久化、API DTO、OpenAPI 和移动端解析保持一致。移动端响应解析器会有意拒绝未知字段。
3. 在发生改动的 crate 或应用内就近添加测试，先运行该软件包的定向测试，再运行完整工作区测试套件。
4. 如果 API 技术契约发生变化，请重新生成它并检查差异：

   ```bash
   ./scripts/generate_openapi.sh > docs/openapi-v1.json
   ./scripts/check_openapi.sh
   ```

5. 更改 schema 时，请新增仅向前迁移。绝不要修改已应用的迁移，也绝不要让生产 API 副本相互竞争执行迁移。

重试写操作时必须保持幂等；论文预处理产物必须始终绑定其处理代次；面向公众的功能必须保留访客阅读能力。不得将访问令牌、密码、身份属性、论文全文、提示词、评论或举报写入日志和遥测。

### 移动端改动

迭代时运行格式化、分析和最小范围的相关 Widget 测试或单元测试。交接前，请运行完整 Flutter 测试套件，并在改动涉及的各个平台上实际操作相应流程。模拟器适合快速迭代；而[在真机上测试 Pakperk](mobile-device-development.md)中要求的已签名真机测试和原生行为证据，必须通过真机取得。

### 文档改动

请编辑 `docs/` 中作为权威来源的英文 Markdown；不要手动编辑 `docs-site/app/generated/` 或 `docs-site/public/docs-data/` 中的生成文件。

```bash
cd docs-site
npm ci
npm run sync-docs
npm test
```

`sync-docs` 需要 Pandoc。若没有匹配且已审核的中文翻译，文档网站可以显示英文回退内容；界面不得把过期翻译呈现为当前版本。

## 了解本地成功无法证明什么

本地运行成功只表示被测试的代码路径在开发环境中有效。它不能证明以下任何事项：

- 公共 DNS、TLS、Ingress、可信代理或 HSTS 行为；
- 生产 PostgreSQL 角色、备份、恢复兼容性或数据库迁移执行权归属；
- OIDC 浏览器/原生客户端、提供商权限或删除账本重放；
- 真实环境中的 GROBID、模型提供商、遥测、告警或 worker 行为；
- 真机上的无障碍、后台运行、离线恢复、签名或应用商店验收；或
- 发布负责人、隐私、法律、安全和领域专家人工审批。

请使用服务器部署指南、真机指南、运行手册和完成度审计来收集这些证据。不得仅仅因为某条路由存在或其本地测试通过，就在生产环境中启用对应功能。

## 仓库结构

| 路径 | 存放内容 |
| --- | --- |
| `backend/apps/api` | 提供公开接口和账户接口的 Axum API |
| `backend/apps/worker` | 论文元数据和预处理任务 |
| `backend/apps/deletion-worker` | 提供商侧和应用侧的删除工作 |
| `backend/apps/migrate` | 独立运行的部署数据库迁移 Job |
| `backend/apps/admin` | 要求操作者近期完成认证的内容审核操作 |
| `backend/apps/telemetry-gateway` | 采用封闭 schema 的移动端遥测接收服务 |
| `backend/crates` | 领域、数据库、认证、策略、队列和提供商模块 |
| `mobile` | Flutter 应用及 Android/iOS 宿主项目 |
| `site` | 公开政策、支持、删除说明和关联网站 |
| `docs` | 权威英文文档和运行手册 |
| `docs-site` | 生成的、可搜索的开发者文档界面 |
| `deploy` | 参考身份配置和 Kubernetes Helm Chart |
| `scripts` | 检查、证据验证器、发布工具和演练脚本 |

## 首次运行常见问题

**API 拒绝 arXiv 联系地址。** 请将 `.env` 中的占位值替换为有人监控的真实地址，然后重新创建受影响的 API 和 worker 容器。

**`/health/live` 正常，但 `/health/ready` 失败。** 进程虽然存活，但其数据库技术契约尚未就绪。请阅读 API、迁移和 PostgreSQL 日志；不要用循环重启掩盖故障。

**Android 模拟器无法访问 `localhost:8080`。** `localhost` 指向模拟器本身。请使用 `http://10.0.2.2:8080`。Android 真机请使用文档规定的 `adb reverse` 路径。

**iPhone 真机无法访问 Mac 的 `localhost`。** `localhost` 指向 iPhone 本身，而且本仓库不提供 iOS 反向隧道。请按照手机指南使用可访问且受信任的 HTTPS 开发或预发布 API。

**应用启动后立即退出。** 请检查构建变体与环境是否匹配，并确认已启用的所有移动端能力都提供了必需的编译期参数。

**账户令牌只在容器 API 中验证失败。** 令牌签发者与 API 发现 URL 不一致。参考本地账户工作流必须保留对外签发者 `localhost`，并在宿主机上运行 API。

**某条功能路由不存在。** 大多数可选路由并非仅在界面中隐藏；当失败时默认拒绝的功能开关处于关闭状态时，后端根本不会注册这些路由。更改开关前，请先确认完整依赖链。
