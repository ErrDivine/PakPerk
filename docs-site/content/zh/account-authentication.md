# 账户认证和资料合约

**阶段:** 生产 v0.0 阶段 3
**功能开关:** `ACCOUNTS_ENABLED`
**验证状态:** 已实现并接受；详见
[阶段 3 报告](phase-reports/phase-3.md) 获取确切证据和剩余的物理设备发布候选检查。

Pakperk 使用 OpenID Connect 授权码与 PKCE。移动应用是公共原生客户端，Rust API 是资源服务器。密码、注册、电子邮件验证、恢复和提供者会话属于配置的身份提供者；Pakperk 仅存储其本地账户和公开资料。

游客阅读不依赖此功能。当账户禁用时，`GET /v1/me` 和 `PATCH /v1/me` 不注册。当账户启用但 OIDC 发现或签名密钥暂时不可用时，公共论文路线仍然可用，账户路线失败关闭。

## 参考开发提供者

可选的 Compose 配置启动了固定的开发专用 Keycloak 域，其单独的 PostgreSQL 数据库和 Mailpit：

```bash
docker compose --profile accounts up -d postgres keycloak
```

已检查的域使用：

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

公共原生和操作客户端没有客户端密钥，需要 PKCE S256。操作客户端仅发出专用的 `pakperk-admin-dev` 受众；API 受众令牌不是有意的管理员凭证。域启用自注册、电子邮件验证、密码恢复、暴力保护、访问令牌最长五分钟的生命周期和一次性刷新令牌轮换。详见
[域运行手册](../deploy/keycloak/README.md) 获取开发边界。域导出和 Compose 启动默认值不得重复用作生产密钥或生产身份策略。

在主机上运行启用账户的 API，以便它和原生客户端看到确切的 `localhost` 发行者。首先将 `.env.example` 复制到 `.env`，替换 arXiv 联系占位符，如根 README 中所述，然后：

```bash
set -a
source .env
set +a
ACCOUNTS_ENABLED=true \
DATABASE_URL=postgres://pakperk:pakperk@127.0.0.1:5432/pakperk \
OIDC_ISSUER_URL=http://localhost:8081/realms/pakperk \
API_ORIGIN_HASH_SECRET_FILE="$PWD/.local/pakperk-secrets/API_ORIGIN_HASH_SECRET" \
API_CURSOR_ENCRYPTION_KEYS_FILE="$PWD/.local/pakperk-secrets/API_CURSOR_ENCRYPTION_KEYS" \
API_BIND=127.0.0.1:8080 \
cargo run --manifest-path backend/Cargo.toml -p pakperk-api
```

不要为这个拓扑启动 Compose `api` 服务。在该容器中，`localhost` 是 API 容器本身；仅更改后端发行者为 `keycloak:8080` 将违反原生客户端的精确发行者验证。

后端账户配置仅在 `ACCOUNTS_ENABLED=true` 时读取：

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

仅接受回环开发的普通 HTTP 发行者。预演和生产需要 HTTPS、精确的发行者、显式的受众和非对称签名算法的允许列表。提供者元数据和 JWKS 读取是无重定向、字节限制、超时限制和缓存的。未知的签名密钥 ID 触发一次飞行刷新，受冷却时间限制。

访问令牌是自包含的 JWT；API 不会使用提供者对每个令牌进行验证。因此正常的会话撤销防止刷新并依赖于所需的短访问令牌生命周期。紧急签名密钥撤销通过从 JWKS 中移除该 `kid` 表示，并在第一个 API 验证后 `OIDC_JWKS_CACHE_TTL_SECONDS` 间隔内生效。组合的
PostgreSQL/OIDC API 测试发布仅替换的 JWKS，等待其短测试缓存之后，并证明旧的签名令牌在 JIT 提供之前被拒绝。本地暂停或删除待定状态在每次认证请求时检查，并拒绝一个否则密码学有效的令牌，而无需等待提供者过期。

使用匹配的构建值启用原生客户端：

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

Android 模拟器通常使用 `http://10.0.2.2:8080` 用于 Pakperk API。对于此域的 `localhost` 发行者，通过在启动前反转主机端口以保留精确的发行者身份：

```bash
adb reverse tcp:8080 tcp:8080
adb reverse tcp:8081 tcp:8081
```

然后 Android 应用可以使用两个文档的 `localhost` URL。应用使用的发行者、令牌、发现和 API 验证器必须完全相同；不要用模拟器或内部容器主机名替换该边界的一侧。

## 令牌和本地数据边界

- 授权通过 AppAuth 在系统浏览器中打开；Pakperk 中没有嵌入的 WebView 或密码表单。
- 访问令牌保存在内存中。刷新令牌、可选的提供者注销提示、发行者/客户端绑定和本地 Pakperk 账户 ID 是唯一的持久会话记录，存储在平台安全存储中。
- 令牌、授权码、PKCE 验证器、OIDC 主题和资料数据不会出现在 SharedPreferences、Drift/SQLite、日志、分析、崩溃报告和 Riverpod 快照中。
- SharedPreferences 中的授权无效条目只是一个布尔值。它在安全令牌删除前写入，并防止在重启后恢复残余的密钥链或密钥库记录；它不包含令牌、账户 ID、主题或资料数据。
- 并发的令牌请求共享一个刷新。被挑战的请求可能刷新并最多重放一次；写入仅在受有限并发或幂等性头保护时重放。
- `invalid_grant` 将应用返回到游客状态。提供者/网络中断会保留安全会话作为 auth-unknown 而不是销毁它。
- 注销会无效在飞行中的授权工作，清除安全凭证和账户拥有的本地行，并保留公共论文/Feed 缓存以及阅读恢复。

## 认证资料 API

在 [openapi-v1.json](openapi-v1.json) 中的已检查 OpenAPI 艺术品是机器可读的真相来源。资料操作使用 OpenAPI `oidcBearer` HTTP 承载安全方案，从不接受客户端提供的 Pakperk 用户 ID。

现有的 `/v1/feed` 和 `/v1/papers/...` 操作在 OpenAPI 中发布匿名和 `oidcBearer` 替代方案：游客访问保持有效，而提供的承载令牌可以验证和 JIT 映射。此可选的安全注释不得被解释为账户墙。健康操作没有承载安全要求。

### `GET /v1/me`

第一个有效的请求事务性地将验证的 `(issuer, subject)` 映射到一个 Pakperk 账户。响应是私有的且不可缓存：

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

`profile_complete` 仅在账户处于活动状态、有 handle 并且已接受当前条款版本时为 true。`terms_current` 作为单独报告，以便客户端可以解释为什么一个其他命名的资料不完整。提供者发行者、主题、电子邮件、声明和 `last_seen_at` 从不返回。

### `PATCH /v1/me`

资料变异是比较并交换。`If-Match` 是必需的，且仅接受最新账户响应返回的精确强资料验证器：

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

未知字段被拒绝，至少需要一个支持的字段。省略 `display_name` 保持其不变；发送 `null` 清除它。handle 不能为 `null`，规范化为小写 ASCII，必须匹配
`[a-z0-9_]{3,30}`，并且只能设置一次。`accept_terms_version` 必须等于服务器的当前版本。成功返回与 `GET` 相同的信封和私有缓存头，ETag 增加。

稳定的失败保留普通错误信封：

| 状态 | 稳定代码 | 响应头 |
|---:|---|---|
| 400 | `INVALID_REQUEST`, `INVALID_PROFILE_VERSION`, `INVALID_PROFILE_UPDATE`, `INVALID_HANDLE`, `INVALID_DISPLAY_NAME`, `INVALID_TERMS_VERSION`, `TERMS_VERSION_MISMATCH` | — |
| 401 | `UNAUTHENTICATED`, `TOKEN_EXPIRED` | `WWW-Authenticate: Bearer` |
| 403 | `ACCOUNT_SUSPENDED`, `ACCOUNT_DELETION_PENDING` | — |
| 409 | `HANDLE_ALREADY_SET`, `HANDLE_UNAVAILABLE` | — |
| 412 | `PROFILE_VERSION_CONFLICT` | 当前 `ETag` |
| 428 | `PROFILE_VERSION_REQUIRED` | — |
| 429 | `RATE_LIMITED` | delta-seconds `Retry-After` |
| 503 | `AUTHENTICATION_UNAVAILABLE`, `ACCOUNT_SERVICE_UNAVAILABLE` | delta-seconds `Retry-After` 当已知 |

`PROFILE_VERSION_REQUIRED` 表示 `If-Match` 头部缺失；格式错误、弱、通配符、列表、重复、零、负或非规范验证器使用 `INVALID_PROFILE_VERSION`。挑战和临时认证失败永远不会暴露令牌、声明、提供者、发行者、主题或签名密钥的详细信息。

## CORS 合约

已部署的源地址保持为显式的 HTTPS 值。API 接受以下方法：

```text
GET, POST, PUT, PATCH, DELETE, OPTIONS
```

预检（Preflight）允许以下头信息：

```text
Authorization, Content-Type, X-Session-Id, X-Request-Id,
Idempotency-Key, If-Match, If-None-Match
```

浏览器客户端可以读取以下头信息：

```text
X-Request-Id, ETag, Retry-After
```

原生的 Flutter 请求不依赖 CORS，但此协议防止了 web 工具需要更广泛的通配符或凭证行为。

## 账户拥有和删除扩展

Phase 4 现在仅在独立账户、库和写入权限允许时才发布库路由。保存操作不需要句柄或条款接受；远程同步还需要绑定纪元的 `/v1/me` 账户验证。中立提供方的身份管理边界现在有一个有界的 Keycloak 实现，仅由专用删除工作者使用。每个 `DELETE /v1/me` 尝试，包括在响应丢失后身份范围内的重放，都需要最近的认证。删除验证、持久状态机、签名的外部恢复账本、提供方会话/身份移除以及重放工具均在 `ACCOUNT_DELETION_ENABLED` 后面实现。它们在目标提供方授权、独立账本/备份拓扑、恢复演练、警报和公开披露获得证据之前保持默认关闭。评论功能在独立的读取/发布标志后实现，并且在没有其用户生成内容运营门控的情况下不得启用。
