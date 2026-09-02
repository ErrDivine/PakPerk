# 账户认证与用户资料技术契约

**阶段：** Production v0.0 第 3 阶段
**功能开关：** `ACCOUNTS_ENABLED`
**验证状态：** 已实现并通过验收；请参阅
[第 3 阶段报告](phase-reports/phase-3.md)，了解确切证据和尚待完成的
真机发布候选版本检查。

Pakperk 采用结合 PKCE 的 OpenID Connect 授权码流程。移动应用是公共原生客户端，Rust API 是资源服务器。密码、注册、电子邮件验证、账户恢复和身份提供商会话均由配置的身份提供商负责；Pakperk 仅存储本地账户及其公开用户资料。

访客阅读不依赖此功能。当账户功能关闭时，不会注册 `GET /v1/me` 和 `PATCH /v1/me` 路由。当账户功能开启，但 OIDC 发现服务或签名密钥暂时不可用时，公开论文路由仍然可用，而账户路由会在故障时默认拒绝请求。

## 开发环境参考身份提供商

本节中的每个 shell 命令块都以仓库根目录为起始目录。此账户功能拓扑要求在主机上运行 API，因此在占用 8080 端口前，请先停止任何由 Compose 启动的 API 服务：

```bash
docker compose stop api
```

可选的 Compose profile 会启动版本固定且仅供开发使用的 Keycloak Realm，以及它独立使用的 PostgreSQL 数据库和 Mailpit：

```bash
docker compose --profile accounts up -d postgres keycloak
```

代码仓库中已检入的 Realm 使用以下配置：

```text
issuer:                  http://localhost:8081/realms/pakperk
API audience:            pakperk-api
native client:           pakperk-mobile-dev
redirect URI:            pakperk-auth-dev://oauth/callback
post-logout redirect:    pakperk-auth-dev://oauth/logout
operator client/audience: pakperk-admin-dev
operator redirect URI:   pakperk-admin-dev://oauth/callback
browser deletion client: pakperk-web-deletion-dev
browser redirect URI:    http://localhost:8082/account-deletion/
deletion admin client:   pakperk-deletion-worker-dev (runtime-generated secret)
requested scopes:        openid profile
verification inbox:      http://localhost:8025
```

公共原生客户端和运维客户端均不使用客户端密钥，并且要求 PKCE S256。运维客户端的令牌只携带专用的 `pakperk-admin-dev` 受众；面向 API 受众的令牌明确不能用作管理员凭证。该 Realm 启用了自行注册、电子邮件验证、密码恢复、暴力破解防护、最长五分钟的访问令牌有效期，以及单次使用的刷新令牌轮换机制。有关开发用途边界，请参阅
[Realm 操作手册](../deploy/keycloak/README.md)。不得将 Realm 导出配置和 Compose 引导启动的默认值复用为生产密钥或生产身份策略。

请在主机上运行启用账户功能的 API，使 API 与原生客户端使用完全一致的 `localhost` 颁发者地址。首先将 `.env.example` 复制为 `.env`，按照根目录 README 的说明替换 arXiv 联系信息占位符，并在启动 API 前创建仅限所有者访问的账户密钥环：

```bash
./scripts/prepare_dev_account_secrets.sh
```

然后运行：

```bash
set -a
source .env
set +a
ACCOUNTS_ENABLED=true \
DATABASE_URL=postgres://pakperk:pakperk@127.0.0.1:5432/pakperk \
OIDC_ISSUER_URL=http://localhost:8081/realms/pakperk \
API_ORIGIN_HASH_SECRET_FILE="$PWD/.local/pakperk-secrets/API_ORIGIN_HASH_SECRET" \
API_CURSOR_ENCRYPTION_KEYS_FILE="$PWD/.local/pakperk-secrets/API_CURSOR_ENCRYPTION_KEYS" \
ACCOUNT_IDENTITY_FINGERPRINT_KEYS_FILE="$PWD/.local/pakperk-secrets/ACCOUNT_IDENTITY_FINGERPRINT_KEYS" \
API_BIND=127.0.0.1:8080 \
cargo run --manifest-path backend/Cargo.toml -p pakperk-api
```

不要为该拓扑启动 Compose `api` 服务。在该容器内，`localhost` 指向 API 容器本身；如果只将后端的颁发者地址改为 `keycloak:8080`，就会破坏原生客户端要求的颁发者地址完全一致性校验。

上述命令只启用账户功能。要使用移动端代码仓库中已检入的完整 `config/dev.json` 配置，请先按 Ctrl-C 停止该 API，然后运行同一命令，并加入以下四个额外开关：

```bash
LIBRARY_ENABLED=true \
LIBRARY_WRITES_ENABLED=true \
COMMENTS_ENABLED=true \
COMMENT_CREATION_ENABLED=true \
ACCOUNTS_ENABLED=true \
DATABASE_URL=postgres://pakperk:pakperk@127.0.0.1:5432/pakperk \
OIDC_ISSUER_URL=http://localhost:8081/realms/pakperk \
API_ORIGIN_HASH_SECRET_FILE="$PWD/.local/pakperk-secrets/API_ORIGIN_HASH_SECRET" \
API_CURSOR_ENCRYPTION_KEYS_FILE="$PWD/.local/pakperk-secrets/API_CURSOR_ENCRYPTION_KEYS" \
ACCOUNT_IDENTITY_FINGERPRINT_KEYS_FILE="$PWD/.local/pakperk-secrets/ACCOUNT_IDENTITY_FINGERPRINT_KEYS" \
API_BIND=127.0.0.1:8080 \
cargo run --manifest-path backend/Cargo.toml -p pakperk-api
```

请按上文所示导出 `.env`，然后从仓库根目录运行该命令。这些是相互独立的读取和写入功能开关：在 Flutter 中启用 Library 或评论开关，并不会注册或启用相应的 API 操作。

仅当 `ACCOUNTS_ENABLED=true` 时，后端才会读取账户配置：

```dotenv
ACCOUNTS_ENABLED=true
OIDC_ISSUER_URL=http://localhost:8081/realms/pakperk
OIDC_AUDIENCE=pakperk-api
OIDC_ALLOWED_ALGORITHMS=RS256
OIDC_DISCOVERY_TIMEOUT_SECONDS=5
OIDC_JWKS_CACHE_TTL_SECONDS=900
OIDC_JWKS_MIN_REFRESH_SECONDS=30
OIDC_CLOCK_SKEW_SECONDS=30
ACCOUNT_LAST_SEEN_INTERVAL_SECONDS=900
OIDC_RETRY_INITIAL_SECONDS=5
OIDC_RETRY_MAX_SECONDS=300
CURRENT_TERMS_VERSION=2026-07-31
PROFILE_UPDATE_LIMIT=5
PROFILE_UPDATE_WINDOW_SECONDS=3600
```

仅在使用回环地址的本地开发环境中接受明文 HTTP 颁发者地址。预发布环境和生产环境要求使用 HTTPS、完全一致的颁发者地址、显式受众，以及非对称签名算法允许列表。读取身份提供商元数据和 JWKS 时不会跟随重定向，并且设有响应字节数与超时时间上限；读取结果会被缓存。未知的签名密钥 ID 会触发合并并发刷新请求，并受冷却时间限制。

访问令牌是自包含的 JWT；API 不会逐个向身份提供商查询令牌状态。因此，常规会话撤销会阻止后续刷新，并依赖强制要求的较短访问令牌有效期。紧急撤销签名密钥通过从 JWKS 中移除相应 `kid` 来表示；在最长不超过 `OIDC_JWKS_CACHE_TTL_SECONDS` 的缓存期限结束后，API 的下一次验证就会应用这一撤销。组合式 PostgreSQL/OIDC API 测试会发布只包含替代密钥的 JWKS，等待其短测试缓存期限过去，并证明旧签名令牌会在 JIT 即时预配之前遭到拒绝。每个经过身份认证的请求都会检查本地账户是否处于暂停或待删除状态；即使令牌在密码学上仍然有效，也会被拒绝，无需等待身份提供商侧的令牌到期。

使用相互匹配的构建参数启用原生客户端：

```bash
cd mobile
flutter run \
  --flavor dev \
  --dart-define=PAKPERK_ENV=development \
  --dart-define=PAKPERK_API_BASE_URL=http://localhost:8080 \
  --dart-define=PAKPERK_ACCOUNTS_ENABLED=true \
  --dart-define=PAKPERK_OIDC_ISSUER_URL=http://localhost:8081/realms/pakperk \
  --dart-define=PAKPERK_OIDC_CLIENT_ID=pakperk-mobile-dev \
  --dart-define=PAKPERK_OIDC_REDIRECT_URI=pakperk-auth-dev://oauth/callback \
  --dart-define=PAKPERK_OIDC_POST_LOGOUT_REDIRECT_URI=pakperk-auth-dev://oauth/logout \
  --dart-define='PAKPERK_OIDC_SCOPES=openid profile'
```

Android 模拟器通常使用 `http://10.0.2.2:8080` 访问 Pakperk API。对于此 Realm 的 `localhost` 颁发者地址，请在启动前为主机端口设置反向端口转发，以保持颁发者标识完全一致：

```bash
adb reverse tcp:8080 tcp:8080
adb reverse tcp:8081 tcp:8081
```

这样，Android 应用就可以使用上文所示的两个 `localhost` URL。应用配置、令牌、OIDC 发现文档和 API 验证器中的颁发者值必须完全一致；不得只在该边界的一侧将其替换为模拟器或容器内部主机名。

## 令牌与本地数据边界

- 授权流程通过 AppAuth 在系统浏览器中打开；Pakperk 不包含嵌入式 WebView 或密码表单。
- 访问令牌只保存在内存中。刷新令牌、可选的身份提供商注销提示、颁发者与客户端绑定信息以及本地 Pakperk 账户 ID 共同构成唯一的持久会话记录，并存储在平台安全存储中。
- 令牌、授权码、PKCE 验证器、OIDC 主体标识和用户资料数据均不会出现在 SharedPreferences、Drift/SQLite、日志、分析数据、崩溃报告或 Riverpod 快照中。
- SharedPreferences 中的认证失效标记只是一个布尔值。该标记会在删除安全存储中的令牌之前写入，并防止重启后恢复钥匙串或密钥库中的残留记录；它不包含令牌、账户 ID、主体标识或用户资料数据。
- 并发令牌请求共用一次刷新。收到认证质询的请求最多只能刷新并重放一次；仅当请求头提供有界并发控制或幂等保护时，才会重放写操作。
- `invalid_grant` 会使应用返回访客状态。身份提供商服务或网络中断时，安全会话会保留为 auth-unknown 状态，而不会被销毁。
- 注销会使正在进行的认证工作失效，清除安全凭证和归该账户所有的本地数据行，并保留公开论文和 Feed 缓存以及阅读恢复状态。

## 需身份认证的用户资料 API

[openapi-v1.json](openapi-v1.json) 中已验证的 OpenAPI 规范文件是机器可读的权威数据源。用户资料操作使用 OpenAPI 的 `oidcBearer` HTTP Bearer 安全方案，并且绝不接受由客户端提供的 Pakperk 用户 ID。

现有的 `/v1/feed` 和 `/v1/papers/...` 操作在 OpenAPI 中声明匿名访问和 `oidcBearer` 两种可选方案：访客访问仍然有效，而客户端提供的 Bearer 令牌可以经过验证并进行 JIT 映射。不得将这种可选安全声明理解为必须登录账户才能访问。健康检查操作无需 Bearer 认证。

### `GET /v1/me`

首个有效请求会在一个事务中将经过验证的 `(issuer, subject)` 映射到一个 Pakperk 账户。该响应属于私有响应，且禁止缓存：

```http
HTTP/1.1 200 OK
ETag: "profile-3"
Cache-Control: private, no-store
Content-Type: application/json
```

```json
{
  "account": {
    "id": "018f06f0-65f2-7e2e-9a6e-8f349a84730f",
    "handle": "ada_2026",
    "display_name": "Ada",
    "status": "active",
    "profile_version": 3,
    "profile_complete": true,
    "terms_version": "2026-07-31",
    "terms_accepted_at": "2026-07-31T12:00:00Z",
    "current_terms_version": "2026-07-31",
    "terms_current": true,
    "created_at": "2026-07-31T11:55:00Z",
    "updated_at": "2026-07-31T12:00:00Z"
  }
}
```

仅当账户处于活动状态、拥有用户名且已接受当前条款版本时，`profile_complete` 才为 true。`terms_current` 会单独返回，以便客户端解释为什么用户资料即使已有名称仍不完整。身份提供商的颁发者标识、主体标识、电子邮件、声明和 `last_seen_at` 绝不会返回。

### `PATCH /v1/me`

用户资料变更操作采用比较并交换（CAS）机制。`If-Match` 是必需的，并且只接受最新账户响应返回的用户资料强验证器；其值必须完全一致：

```http
PATCH /v1/me HTTP/1.1
Authorization: Bearer <access-token>
If-Match: "profile-3"
Content-Type: application/json
```

```json
{
  "handle": "ada_2026",
  "display_name": "Ada",
  "accept_terms_version": "2026-07-31"
}
```

未知字段会被拒绝，并且必须至少提供一个受支持的字段。
省略 `display_name` 时，该字段保持不变；发送 `null` 会清除该字段。用户名不能为 `null`，会被规范化为小写 ASCII，必须匹配
`[a-z0-9_]{3,30}`，并且只能设置一次。`accept_terms_version` 必须等于服务器当前版本。成功返回与 `GET` 相同的响应封装和私有缓存头，ETag 值递增。

以下稳定失败仍使用常规错误响应封装：

| 状态 | 稳定错误码 | 响应头 |
|---:|---|---|
| 400 | `INVALID_REQUEST`, `INVALID_PROFILE_VERSION`, `INVALID_PROFILE_UPDATE`, `INVALID_HANDLE`, `INVALID_DISPLAY_NAME`, `INVALID_TERMS_VERSION`, `TERMS_VERSION_MISMATCH` | — |
| 401 | `UNAUTHENTICATED`, `TOKEN_EXPIRED` | `WWW-Authenticate: Bearer` |
| 403 | `ACCOUNT_SUSPENDED`, `ACCOUNT_DELETION_PENDING` | — |
| 409 | `HANDLE_ALREADY_SET`, `HANDLE_UNAVAILABLE` | — |
| 412 | `PROFILE_VERSION_CONFLICT` | 当前 `ETag` |
| 428 | `PROFILE_VERSION_REQUIRED` | — |
| 429 | `RATE_LIMITED` | 秒数差值形式的 `Retry-After` |
| 503 | `AUTHENTICATION_UNAVAILABLE`, `ACCOUNT_SERVICE_UNAVAILABLE` | 秒数差值形式的 `Retry-After`（已知时） |

`PROFILE_VERSION_REQUIRED` 表示缺少 `If-Match` 请求头；格式错误、弱验证器、通配符验证器、列表形式、重复值、零值、负值或非规范形式的验证器使用
`INVALID_PROFILE_VERSION`。认证质询和临时认证故障绝不会暴露令牌、声明、身份提供商、颁发者、主体标识或签名密钥的详细信息。

## CORS 技术契约

部署环境中的 CORS 源始终采用明确指定的 HTTPS 地址。API 接受以下方法：

```text
GET, POST, PUT, PATCH, DELETE, OPTIONS
```

预检请求允许以下请求头：

```text
Authorization, Content-Type, X-Session-Id, X-Request-Id,
Idempotency-Key, If-Match, If-None-Match
```

浏览器客户端可以读取以下响应头：

```text
X-Request-Id, ETag, Retry-After
```

原生 Flutter 请求不依赖 CORS，但此契约可以避免 Web 工具要求更宽泛的通配符配置或凭证携带行为。

## 账户专属数据与删除扩展

第 4 阶段目前仅在相互独立的账户、Library 和写入功能开关均允许时，才会开放 Library 路由。保存操作无需用户名或接受条款；远程同步还需要与 epoch 绑定的 `/v1/me` 账户验证。不依赖特定身份提供商的身份管理边界现已提供一个职责范围受限的 Keycloak 实现，且仅供专用删除 worker 进程使用。每次尝试调用 `DELETE /v1/me`，包括在响应丢失后限定于同一身份的重放，都要求近期身份认证。删除验证、持久化状态机、带签名的外部恢复账本、从身份提供商移除会话和身份，以及重放工具，均已实现并受 `ACCOUNT_DELETION_ENABLED` 功能开关控制。在针对目标身份提供商授权、独立账本/备份拓扑、恢复演练、告警和公开披露的证据全部获批之前，这些功能将保持默认关闭。评论功能分别受独立的读取和发布功能开关控制；未满足相应的用户生成内容（UGC）运营准入条件时，不得启用评论功能。
