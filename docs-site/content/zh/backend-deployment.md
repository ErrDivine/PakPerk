# 在服务器上部署 Pakperk 后端

本指南将代码仓库中的部署技术契约梳理成便于运维人员执行的
操作流程。它适用于预发布或生产服务器环境，无论该环境是
托管式 Kubernetes 集群，还是安装在运维人员自有服务器上的
Kubernetes。

> **受支持的服务器部署方式是 Kubernetes 1.29 或更高版本，并使用
> Pakperk Helm Chart。** Docker Compose 是本地开发栈。该栈包含
> 开发密码、开发用身份提供商、明文端点、自动数据库迁移、原型全文策略，
> 而且 API 端口绑定在所有网络接口上。不得将它作为面向公网的生产服务。

Helm Chart 有意不做成一条命令即可完成的安装程序。PostgreSQL、OIDC、DNS、
TLS、镜像仓库中的镜像、Secret、备份、删除账本和遥测，都是由 Helm Chart
之外负责的安全与恢复边界。在明确提供这些输入之前，部署会在失败时明确拒绝继续。

## 先确定“服务器”具体指什么

| 目标 | 适用场景 | 重要限制 |
| --- | --- | --- |
| 托管式多节点 Kubernetes | 预发布或生产环境 | 外部服务、values、证据和冒烟测试仍由您负责 |
| 运维人员自行管理的多节点 Kubernetes | 平台通过审核后，可用于预发布或生产环境 | 控制平面、节点、存储、Ingress 和升级的可靠性也由您负责 |
| 一台服务器上的单节点 Kubernetes | 私有开发或预发布评估 | 数据库、工作负载、Ingress 和存储可能共处同一故障域；这不是具备韧性的生产拓扑 |
| 远程 VM 上的 Docker Compose | 仅限短期私有开发工作 | 它不是生产部署拓扑，必须始终置于防火墙或 VPN 之后 |

本代码仓库不指定 Kubernetes 发行版或云服务商。无论选择哪种平台，
都必须满足 Helm Chart 对版本、存储、NetworkPolicy、Ingress、
安全上下文和不可变镜像的要求。

## 了解 Helm Chart 负责的范围

Helm Chart 会部署：

- Axum API；
- 论文预处理 worker；
- 一个独立隔离的账户删除 worker；
- 一个安装前/升级前数据库迁移 Job；
- 一个定时执行元数据同步的 CronJob；
- 托管公开政策与应用关联文件的静态站点；
- 一个隔离的 GROBID 解析器；
- 移动端遥测网关；以及
- 一个 OpenTelemetry Collector。

Helm Chart **不会**创建：

- PostgreSQL；
- Keycloak 或其他 OIDC 提供商；
- 公共 DNS、证书或共享 Ingress 控制器；
- 应用镜像仓库；
- 外部 Kubernetes Secret；
- 删除账本卷或可选的视觉资源卷；
- 外部 OTLP 接收端和告警适配器；以及
- 备份、恢复点、受保护证据或人工审批记录。

API、各 worker、元数据同步任务和数据库迁移 Job 分别使用不同的 PostgreSQL
角色。PostgreSQL 同时也是 Pakperk 的持久化队列、共享限流存储、
同步协调的权威来源和内容审核的唯一可信数据源。除非已有获准的 ADR
改变了架构，否则不得为了“补全”此部署而添加 Redis、Kafka 或其他网络服务。

## 准备运维人员的工作站

请使用能够访问目标集群和受保护配置系统的可信工作站。安装：

- 与集群兼容的 `kubectl`；
- Helm 3.18.x 系列版本；
- PostgreSQL 16 的 `psql`，或由 Secret 管理器提供凭据的等效 SQL 控制台；
- 用于运行代码仓库验证器的 Python 3 和 `jq`；以及
- 签出到已经审核的确切源代码修订版本的本代码仓库。

每次渲染或应用资源之前，都要确认当前上下文：

```bash
kubectl config current-context
kubectl version
helm version
```

以下示例使用用途明确的专用变量：

```bash
export PAKPERK_DEPLOY_ENV='staging'
export PAKPERK_K8S_NAMESPACE='pakperk-staging'
export PAKPERK_HELM_RELEASE='pakperk-staging'
export PAKPERK_VALUES_FILE='/protected/path/pakperk-staging-values.yaml'
```

values 文件由具体环境负责，应保存在受保护系统中，
不得存入本代码仓库。只有同一候选版本通过规定的预发布和晋级门禁之后，
才能换成生产环境名称。文件顶层的 `environment` 值必须与
`PAKPERK_DEPLOY_ENV` 完全一致。

### 先创建命名空间并添加标签

Secret、PVC 和所有平台负责的 ServiceAccount 都属于特定命名空间，因此必须先
创建命名空间，才能配置 Helm Chart 所依赖的外部资源。对于新环境，
只需创建一次命名空间，并添加稳定的所有权与环境标签：

```bash
kubectl create namespace "$PAKPERK_K8S_NAMESPACE"
kubectl label namespace "$PAKPERK_K8S_NAMESPACE" \
  app.kubernetes.io/part-of=pakperk \
  "pakperk.app/environment=$PAKPERK_DEPLOY_ENV" \
  --overwrite
kubectl get namespace "$PAKPERK_K8S_NAMESPACE" --show-labels
```

如果命名空间已经存在，不要重新创建；使用前应检查其现有
标签、归属、配额、默认拒绝策略和准入配置。不要盲目应用 `restricted`
Pod Security 标签。Helm Chart 中的 Collector 需要读取 `/var/log/pods`，
并采用经过审核的只读 `hostPath`，因此平台必须记录与之兼容的准入例外，
或改为提供功能等效、由平台负责的节点日志代理。

## 完成外部先决条件

请按顺序完成以下各项。缺少任何一项都会阻断部署，不得填入占位值代替。

### 1. Kubernetes、Ingress、存储与出站访问

集群必须运行 Kubernetes 1.29 或更高版本，并强制执行 Helm Chart 中关于
非 root 用户、只读根文件系统、seccomp、Linux capability、无令牌
ServiceAccount 和 NetworkPolicy 的设置。

准备一个 Ingress 控制器，其命名空间和 Pod 标签必须与
`networkPolicy.ingressController` 完全一致。经过审核的参考配置是
`deploy/helm/ingress-nginx-production-values.yaml`；它提供预期的
HSTS 和 gzip 边界。如果平台使用其他 Ingress，则必须复现同等的
TLS 重定向、精确主机名/路径、请求大小/超时、限流、转发地址、gzip
和不会泄露查询内容的安全日志记录行为。

解析并审核以下访问实际需要的 IPv4 CIDR：

- 数据库访问；
- API 通过 HTTPS 访问 OIDC 和可选内容审核服务的出站流量；
- 访问 arXiv 的 HTTPS 出站流量；
- 访问模型提供商的 HTTPS 出站流量；
- 访问身份管理服务的 HTTPS 出站流量；以及
- 遥测导出流量。

Helm Chart 接受规范的 `/8` 至 `/32` IPv4 网络，并有意拒绝彼此重叠的
arXiv、模型提供商和身份管理网段。标准 NetworkPolicy 无法安全表达
提供商主机名，因此每当提供商变更其网段时，都要重新解析并审核这些网段。

运行删除 worker 时，应准备一个供删除账本使用的 `ReadWriteMany` PVC。
它必须独立于 PostgreSQL 进行备份，并允许
UID/GID 10001 写入。另外，可选的视觉资源 PVC 也必须允许所有参与节点
以 RWX 模式访问。在多节点生产部署中，
不得改用节点本地存储或普通 `ReadWriteOnce` 存储。

### 2. PostgreSQL 16 与数据库角色

配置 PostgreSQL 16，并在 `public` schema 中安装以下扩展：

- `vector`；
- `pg_trgm`；以及
- `pgcrypto`。

分别为数据库迁移、API、论文 worker、元数据同步和删除 worker 创建不同的
登录角色与连接 URL。只有数据库迁移角色拥有经过审核的 DDL 权限。
运行时角色仅获得各自组件所需的 DML 权限。Keycloak 使用独立的数据库和角色，
不得使用 Pakperk 应用数据库。

代码仓库中的授权矩阵定义了所需的权限边界，但它不是可直接执行的角色配置脚本。
数据库所有者必须维护并审核一份针对具体环境的 SQL/IaC 授权产物，
将这些边界映射到数据库迁移 1 至 24 创建的表。不得用 `GRANT ALL`、
schema 所有权、共享登录角色或运行时 Secret 中的数据库迁移角色来替代
这份尚未随仓库提供的产物。

每个 Pakperk 运行时角色还需要以下范围严格受限的就绪检查权限：

```sql
GRANT USAGE ON SCHEMA public TO <runtime_role>;
GRANT SELECT (version, success, checksum)
  ON TABLE public._sqlx_migrations TO <runtime_role>;
```

这些权限使进程能够证明其内置数据库迁移历史与数据库一致。运行时角色不得获得
`_sqlx_migrations` 的写权限、schema 所有权或 DDL 权限。详细的组件权限矩阵见
[Helm Chart README](../deploy/helm/pakperk/README.md#database-and-provider-grant-matrix)。

对于新数据库，首次迁移完成前，`_sqlx_migrations` 和应用数据表都不存在。
不要启动 API 或 worker 后，指望在 Helm 等待期间再补授权。请按照
[分两个阶段引导全新数据库](#bootstrap-a-brand-new-database-in-two-phases)中的流程：
先只运行数据库迁移边界，再应用并审核运行时权限，最后才安装常规工作负载。
每次更换角色或 schema 后，都要重新审核权限。

### 3. 公共 HTTPS 标识

分别为以下服务创建互不相同、全部小写的公共主机名：

- 公共站点；
- API；
- 移动端遥测；以及
- OIDC 提供商。

签发受信任的 TLS 证书，并准备 Ingress 使用的 TLS Secret。预发布和
生产环境的公开源地址必须使用 HTTPS。浏览器 OIDC 客户端和原生移动端 OIDC 客户端
必须彼此独立，并使用对应移动端构建变体中的确切回调 URI 进行注册。

为执行账户删除，创建一个单独的 Keycloak 机密客户端服务账户，
并且必须恰好授予 `realm-management/manage-users` 这一项权限。不得授予 `realm-admin`、
`query-users` 或 `view-users`。删除 worker 的就绪检查会执行有界、无破坏性的
Admin REST 权限探测；仅仅成功获取令牌，并不能证明该集成可以正常工作。

### 4. 模型、arXiv 与遥测提供商

符合生产形态的论文 worker 需要一个兼容 OpenAI 的 HTTPS 模型提供商、
明确的聊天和嵌入模型 ID、正确的嵌入维度，以及真实且受到监控的 arXiv 联系邮箱。

准备一个外部 HTTPS OTLP 接收端及其认证请求头。Helm Chart 中的 Collector
会向该接收端导出数据；移动端遥测网关只是一个只接收封闭 schema 数据的公共入口。
此外，还应准备平台适配器，用于导入经过审核的告警策略，并将指定负责人关联到
真实通知接收端。能够渲染告警 ConfigMap，并不能证明告警会实际通知到任何人。

### 5. 不可变发布镜像

Helm Chart 接受由镜像仓库地址与 `sha256:` 摘要组成的配对值，并拒绝可变标签。
后端镜像包含 API、worker、删除 worker、数据库迁移器、遥测网关和管理工具二进制文件。
Helm Chart 中的各工作负载分别选择 API、worker、deletion-worker、migrator
和 gateway 命令。`pakperk-admin` 仍是由运维人员按需调用的工具；Helm Chart
有意不创建常驻的管理工具 Deployment。静态站点使用单独的镜像。

对于正式的预发布或生产候选版本，应运行受保护的
`publish-release-images` 工作流，并以 `main` 中已经审核的确切完整提交 SHA 为目标。
必须取得该工作流生成的
漏洞扫描结果、镜像 SBOM、镜像仓库中的不可变摘要和 `promotion-handoff.json`。
应部署该交接文件中记录的镜像仓库和摘要。晋级过程中不得在本地重新构建，
也不得用本地 Docker 镜像 ID 代替镜像仓库摘要。

代码仓库中已纳入版本控制的 CI values 使用文档示例主机名、私有测试网段、
确定性的摘要和测试夹具凭据。它们只能验证 Helm Chart 逻辑，绝不能将其应用到集群。

## 安全创建外部 Secret

Helm Chart 引用一个已经存在的 Kubernetes Secret，但绝不会创建它。请使用平台的
Secret 管理器、External Secrets 集成、密封式交付机制或其他经过审核的方式。
不得将 Secret 字节写入 values 文件、命令历史、注解、日志或发布证据。

所选的 Secret 键名必须各不相同。默认名称可在 `secret.*Key` 下查看，
其定义位于 `deploy/helm/pakperk/values.yaml`，其中包括：

- 五个角色各自专用的数据库 URL；
- 模型 API 密钥；
- 可选的 HTTP 内容审核令牌；
- API 源哈希材料；
- 按轮换顺序排列的 API 游标加密密钥环；
- 账户身份指纹密钥；
- 删除账本签名密钥；
- 删除提供商坐标加密密钥；
- 身份管理客户端 Secret；以及
- 遥测导出器请求头。

密钥环文件最多包含八行互不相同的 `key_id:base64(raw-random-bytes)`，
第一行是当前生效的密钥。游标加密密钥和删除提供商坐标密钥解码后必须恰好为
32 字节；身份指纹密钥和账本签名密钥解码后必须为 32 至 128 字节。
密钥 ID 必须是长度受限的安全标识符，不得用日期或 Secret 材料充当密钥 ID。
`API_ORIGIN_HASH_SECRET` 是单独的非占位 Secret，不属于密钥环。
所有生产值都必须在获准的 Secret 管理器内生成；`prepare_dev_*` 脚本只创建
本地开发材料，不是生产配置流程。在相应操作手册规定的记录保留期、游标有效期和
备份可恢复期内，全程保留旧的验签密钥或解密密钥。

将 `secret.existingSecret` 设为 Secret 名称，并为
`secret.rotationVersion` 提供不含秘密的版本标识符。更改外部 Secret 后，
递增 `rotationVersion`，使所有使用它的 Pod 滚动更新。游标加密采用两阶段轮换：
先追加新密钥并滚动更新，此时旧密钥仍位于首行；再将新密钥提升到首行并再次滚动更新。
如果在所有旧游标过期前移除旧密钥，滚动部署期间的副本可能出现行为不一致。

## 构建环境 values 文件

应从 `deploy/helm/pakperk/values.yaml` 的字段结构开始，而不是从 CI 测试夹具开始。
根据经过审核的发布清单，填写所有由环境负责的值。

至少要审核以下各组：

| values 组 | 必须描述的内容 |
| --- | --- |
| `environment` | 必须恰好为 `staging` 或 `production` |
| `image`, `siteImage` | 可拉取且不含标签的镜像仓库，以及不可变的镜像仓库摘要 |
| `public` | 确切的 HTTPS 源、签发者/受众、互不相同的客户端、支持联系方式和法律文档版本 |
| `mobileAssociations` | 实际的 Android 软件包/签名标识，以及 Apple 团队/Bundle 标识 |
| `secret` | 已有 Secret、互不相同的键名和轮换版本 |
| `features` | 针对这一确切候选版本、失败时明确拒绝的产品功能图谱 |
| `releaseEvidence` | 生产环境始终需要法律审核、审核员流程和严格内容审核的 SHA-256 内容 ID；启用功能后还需增加相应证据 ID |
| `alerting` | 生产环境启用与打包策略完全一致的摘要；预发布环境保持该生产策略关闭，并在 Helm Chart 之外绑定单独导入的预发布策略 |
| `policy` | 严格全文策略、匹配的法律版本和经过审核的保留期限 |
| `api` | 副本数、超时、资源限制和受信任 Ingress 来源 CIDR |
| `paperWorker` | arXiv 身份、模型坐标、维度、资源与租约设置 |
| `deletionWorker`, `deletionLedger` | 提供商坐标、worker 限制、RWX PVC、环境和保留期限 |
| `migration` | 真实且已验证的备份 ID，以及预期 schema 版本 24 |
| `metadataSync` | 有界的调度计划和规范的 arXiv 清单 |
| `otelCollector` | 外部接收端和容量 |
| `ingress`, `networkPolicy` | 主机名、TLS Secret、控制器选择器，以及经过审核的出站/数据库 CIDR |

开始时应关闭所有可选产品功能。只有针对某项功能的确切依赖项和证据门禁通过后，
才能启用该功能。有一个容易忽略的默认值需要特别留意：
`deletionWorker.enabled` 默认为 `true`，即使 `features.accountDeletion`
为 `false` 也是如此。
如果要部署真正仅限访客的预发布环境，应显式设置 `deletionWorker.enabled: false`；
否则就必须完整配置其数据库角色、管理提供商、Secret 键、账本和告警。

生产环境一旦启用账户，就必须同时启用账户删除。Helm Chart 始终向长期运行的
API 和 worker 进程传入 `RUN_MIGRATIONS=false`。不得试图覆盖这一职责边界。

即使生产 values 文件仅支持访客，也必须设置 `alerting.enabled: true`，
固定与打包版完全一致的 `alerting.policySha256`，并提供
`releaseEvidence.legalReviewId`、`releaseEvidence.reviewerFlowId` 和
`releaseEvidence.strictContentReviewId`；三者都必须是可检索的
`sha256:<64-lowercase-hex>` 内容 ID。预发布环境必须设置
`alerting.enabled: false` 并将 `policySha256` 留空；平台应在 Helm Chart 之外
导入等效的 19 条规则策略，使用预发布资源过滤条件进行金丝雀测试。
生产环境的功能专项证据是在此基础上叠加的：例如，评论功能需要内容审核就绪证据，
账户删除需要提供商 E2E 测试与恢复演练证据，任何 Deep Reader 功能都需要
完整的 Deep Reader 发布证据包。

## 在接触集群之前完成验证

从代码仓库根目录验证这份环境自有 values 文件的**确切内容**：

```bash
helm lint deploy/helm/pakperk \
  --values "$PAKPERK_VALUES_FILE"

helm template "$PAKPERK_HELM_RELEASE" deploy/helm/pakperk \
  --namespace "$PAKPERK_K8S_NAMESPACE" \
  --values "$PAKPERK_VALUES_FILE"
```

任何警告、缺失值或渲染失败都会阻断部署。应对照变更记录检查渲染后的
工作负载命令、公共主机名、镜像摘要、功能图谱、数据库 Secret 键、
NetworkPolicy、ServiceAccount、PVC、保留期限和资源配置。

还要运行代码仓库中的 Helm Chart 回归测试套件：

```bash
HELM_BIN=helm ./scripts/validate_helm_release.sh
```

该脚本会覆盖代码仓库中应通过和应拒绝的测试夹具。它可以证明 Helm Chart
的验证逻辑仍按设计工作；但它**不会**验证您的 Secret 值、连接依赖服务、
证明集群符合要求，也不会让 CI 预发布测试夹具变成可部署配置。

继续之前，请确认：

- 该确切候选版本对应的扫描、SBOM 和不可变交接产物均已通过；
- 外部 Secret 已存在，并且检查过程未输出其内容；
- 每个被引用的 PVC 均已存在，具有规定的访问模式和备份；
- DNS 和 TLS 记录已就绪；
- 所有提供商和数据库 CIDR 都经过实际观测与审核；
- 每个数据库 URL 都以预期的独立角色成功认证；
- Ingress 控制器和真实 IP 信任边界已经安装；并且
- 可恢复的 PostgreSQL 备份已有真实且不可变的标识符。

## 创建并验证迁移前备份

每次数据库迁移前，都应遵循[备份与恢复](runbooks/backup-restore.md)。
受保护记录必须涵盖 PostgreSQL；存在账户时，还必须涵盖 Keycloak、当前外部
删除账本，以及解释恢复后记录所必需的历史密钥。

将已经验证的备份标识符填入 `migration.confirmBackupId`。Helm Chart
会拒绝空值或明显的占位值。恢复 PostgreSQL 时绝不能漏掉当前删除账本；
否则，可能复活已由提供商后续删除操作最终清除的应用状态。

## 分两个阶段引导全新数据库

普通升级或已经包含 `public._sqlx_migrations` 的已恢复数据库应跳过本节；
数据库迁移由 Helm Chart 的升级前 hook 负责。只有应用数据库确实是全新数据库时，
才能使用本节流程。

在数据表创建前，无法向新数据库授予针对具体表的运行时权限。另一方面，
一次原子的 Helm 安装无法在安装前迁移完成后暂停，等待数据库所有者授权。
如果 API 和 worker 在没有这些权限时启动，就绪检查将失败；即使仅向前迁移已经提交，
Helm 也可能移除 Kubernetes release。请通过下面两个明确阶段避免这项竞态。

### 阶段 A：只运行数据库迁移边界

确认命名空间、镜像拉取凭据、外部运行时 Secret、数据库迁移角色、经过审核的
NetworkPolicy CIDR 和已经验证的备份 ID 均已存在。只将 Helm Chart 中数据库迁移
所需的前置资源和 Job 渲染成一份仅限所有者读取的产物：

```bash
export PAKPERK_BOOTSTRAP_RENDER='/protected/path/pakperk-bootstrap-migration.yaml'
test ! -e "$PAKPERK_BOOTSTRAP_RENDER"
umask 077
helm template "$PAKPERK_HELM_RELEASE" deploy/helm/pakperk \
  --namespace "$PAKPERK_K8S_NAMESPACE" \
  --values "$PAKPERK_VALUES_FILE" \
  --show-only templates/migration-prerequisites.yaml \
  --show-only templates/migration-job.yaml \
  > "$PAKPERK_BOOTSTRAP_RENDER"

grep -E '^kind: (ServiceAccount|NetworkPolicy|Job)$' \
  "$PAKPERK_BOOTSTRAP_RENDER"

test "$(grep -c '^kind: ServiceAccount$' "$PAKPERK_BOOTSTRAP_RENDER")" -eq 1
test "$(grep -c '^kind: NetworkPolicy$' "$PAKPERK_BOOTSTRAP_RENDER")" -eq 1
test "$(grep -c '^kind: Job$' "$PAKPERK_BOOTSTRAP_RENDER")" -eq 1
```

`grep` 输出必须恰好显示一个 `ServiceAccount`、一个 `NetworkPolicy`
和一个 `Job`，而且三条静默执行的 `test` 断言都必须成功退出。
应用前，应检查渲染结果中的镜像摘要、Secret/键引用、
数据库 CIDR、环境、备份 ID 和预期版本。该文件包含拓扑和证据标识符，
但不包含 Secret 字节；即便如此，仍应将其保存在受保护的发布记录中。

应用这三项资源，并等待同时由 release 标签和组件标签选中的唯一数据库迁移 Job：

```bash
kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  get jobs,serviceaccounts,networkpolicies \
  --selector "app.kubernetes.io/instance=$PAKPERK_HELM_RELEASE,app.kubernetes.io/component=migration"

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  apply --filename "$PAKPERK_BOOTSTRAP_RENDER"

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  get jobs \
  --selector "app.kubernetes.io/instance=$PAKPERK_HELM_RELEASE,app.kubernetes.io/component=migration" \
  --output name

export PAKPERK_BOOTSTRAP_JOB='COPY_THE_ONE_EXACT_JOB_NAME'

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  wait "job/$PAKPERK_BOOTSTRAP_JOB" \
  --for=condition=complete \
  --timeout=16m

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  logs "job/$PAKPERK_BOOTSTRAP_JOB" \
  --container migrate \
  --tail=-1 \
  --prefix=true
```

首次尝试时，第一个查询的结果必须为空；如果发现遗留资源，应先调查，
不得直接覆盖。应用资源后，第二个查询必须恰好输出一个 `job.batch/...` 名称。
只复制名称部分（即 `/` 之后的文本）到 `PAKPERK_BOOTSTRAP_JOB`。
成功日志会针对确切的环境、备份 ID 和 schema 版本 24 包含 `migration verified`。
由于 Helm Chart 内的 Collector 此时尚不存在，之后可能还会出现 OTLP 刷新警告；
该警告不会推翻成功的数据库迁移结果。Job 失败或超时都会阻断后续操作。
保留 `kubectl describe` 输出和脱敏日志，检查数据库状态；在负责人查明故障原因之前，
不得反复重新创建 Job。

### 阶段 B：在 Helm 启动运行时角色前完成授权与审计

数据库所有者现在应为 API、论文 worker、元数据同步任务以及启用时的删除 worker，
应用经过审核且针对具体环境的授权产物。通过受保护的 SQL 客户端配置，
分别使用每一个指定的运行时角色连接；绝不能将数据库 URL 或密码粘贴到命令行。
至少每个角色都必须能够执行以下只读就绪查询：

```sql
SELECT current_user;

SELECT version, success, checksum
FROM public._sqlx_migrations
ORDER BY version;

SELECT extension.extname, namespace.nspname
FROM pg_catalog.pg_extension AS extension
JOIN pg_catalog.pg_namespace AS namespace
  ON namespace.oid = extension.extnamespace
WHERE extension.extname IN ('vector', 'pg_trgm', 'pgcrypto')
ORDER BY extension.extname;

SELECT service, blocked_until
FROM public.external_rate_limits
WHERE service = 'arxiv';
```

要求数据库迁移 1 至 24 全部成功，三个扩展都恰好有一个实例位于 `public`，
并且恰好存在一行 `arxiv` 门禁记录。随后运行授权产物中针对各组件的允许与拒绝探测：
每个角色必须只拥有其职责范围内的 DML 权限，不得写入数据库迁移历史，也不得拥有
schema。只记录角色名称和范围受限的通过/失败结果，不要记录连接字符串或查询返回的
应用数据。

现在可以开始常规 Helm 安装。它的安装前 hook 会替换引导阶段的 hook 资源，
并再次运行同一个内置数据库迁移器，以幂等方式完成验证。比较安装前后的
`_sqlx_migrations` 版本、成功状态和校验和；它们必须完全不变。后续升级时，
不要再运行这个手动引导阶段——唯一的数据库迁移执行方是 Helm Chart hook。

## 安装或升级 release

代码仓库中没有替运维人员选择 release 名称、命名空间、超时或回滚策略的 Helm
封装脚本。一种常见的运维执行方式是：

```bash
helm upgrade --install "$PAKPERK_HELM_RELEASE" deploy/helm/pakperk \
  --namespace "$PAKPERK_K8S_NAMESPACE" \
  --values "$PAKPERK_VALUES_FILE" \
  --timeout 20m \
  --atomic
```

只有当这种方式符合平台变更流程时，才能使用它。`--atomic` 可以在失败后回滚
Kubernetes 资源，却无法撤销已经提交的数据库迁移。因此 schema 兼容性和
迁移前备份仍是强制要求。这里有意不创建命名空间：它已经承载经过审核的 Secret、
PVC、标签、准入边界和所有由平台创建的 ServiceAccount。

安装期间，Helm 会依次创建无令牌的数据库迁移 ServiceAccount、对应的默认拒绝
NetworkPolicy，以及一个安装前/升级前数据库迁移 Job。该 Job：

- 使用专用的数据库迁移连接 URL；
- 强制并验证 `public, pg_catalog` 搜索顺序；
- 获取咨询锁；
- 检查备份标识符和内置数据库迁移版本；
- 应用截至 schema 24 的仅向前迁移；并且
- 验证数据库迁移校验和和必需的扩展。

它不会重试，并设有明确上限的执行期限。数据库迁移失败会阻止常规工作负载启动。
对于全新数据库，它必须是上文所述、不发生任何更改的幂等验证；对于升级，
它是唯一获准更改 schema 的进程。保存脱敏后的状态和日志；在理解根本原因和
数据库状态之前，不要一味重跑。

检查 release：

```bash
helm status "$PAKPERK_HELM_RELEASE" \
  --namespace "$PAKPERK_K8S_NAMESPACE"

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  get jobs,pods,deployments,cronjobs \
  --selector "app.kubernetes.io/instance=$PAKPERK_HELM_RELEASE" \
  -L app.kubernetes.io/component
```

在 24 小时 TTL 到期前，只列出当前 release 的数据库迁移 hook。查询结果必须
恰好包含一个 `job.batch/...` 条目；将 `/` 后面的文本复制到
`PAKPERK_MIGRATION_JOB`：

```bash
kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  get jobs \
  --selector "app.kubernetes.io/instance=$PAKPERK_HELM_RELEASE,app.kubernetes.io/component=migration" \
  --output name

export PAKPERK_MIGRATION_JOB='COPY_THE_ONE_EXACT_JOB_NAME'

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  logs "job/$PAKPERK_MIGRATION_JOB" \
  --container migrate \
  --tail=-1
```

绝不能将未脱敏的日志粘贴到工单或发布证据中。

## 按依赖顺序验证暗部署

验证基础设施期间，所有公共功能和写入能力都应保持关闭、暂不对外开放。
后面的服务依赖前面的边界，因此请按以下顺序操作：

1. 获准的数据库迁移路径已经完成：升级环境只有一个 Helm Chart hook；
   全新环境先由一个会更改 schema 的引导 Job 执行迁移，再由 Helm hook
   完成不产生变更的验证。没有并发运行的数据库迁移器。
2. 如果有意启用删除 worker，则其状态已经就绪。
3. 论文 worker 正在运行，能够获取租约且不会陷入崩溃重启循环。
4. 元数据 CronJob 配置能够成功渲染，而且受控运行只能访问获准的数据库和
   arXiv 边界。
5. 遥测网关和 Collector 均处于健康状态，并且金丝雀事件能够到达真实
   接收端和告警适配器。
6. API 副本能够通过各自实际受限的数据库角色达到就绪状态。
7. 公共站点副本和应用关联配置与候选版本完全一致。

不同健康检查面能够证明的范围不同：

| 检查面 | 通过时能够证明什么 | 不能证明什么 |
| --- | --- | --- |
| API `/health/live` | API 进程正在运行 | 数据库或依赖是否就绪 |
| API `/health/ready` | PostgreSQL 可访问；截至版本 24 的所有内置数据库迁移均存在且校验和有效；`vector`、`pg_trgm` 和 `pgcrypto` 各自位于 `public`；并且共享 arXiv 门禁存在 | schema 完全一致（会接受兼容的更高版本 schema）、GROBID、模型、OIDC、worker、队列进度、遥测、DNS 或 TLS |
| 遥测网关健康检查 | 网关进程的技术契约处于健康状态 | 外部 OTLP 交付或告警通知是否生效 |
| GROBID `/api/isalive` | 解析器进程能够响应 | 论文预处理的端到端质量 |
| 删除 worker 就绪探针 | 启动、提供商权限探测、数据库和账本边界均已通过 | 真实用户的完整删除流程和恢复重放 |
| 论文 worker 的 Pod 状态 | 进程尚未退出 | 它没有 HTTP 就绪端点；必须用实际取得租约并产出结果的作业来证明 |

从受信任的外部计算机检查公共 API 和完整的边缘技术契约：

```bash
export PAKPERK_SITE_ORIGIN='https://staging.pakperk.app'
export PAKPERK_API_ORIGIN='https://api.staging.pakperk.app'
export PAKPERK_TELEMETRY_ORIGIN='https://telemetry.staging.pakperk.app'

curl --connect-timeout 5 --max-time 30 --fail-with-body --show-error \
  "$PAKPERK_API_ORIGIN/health/live"
curl --connect-timeout 5 --max-time 30 --fail-with-body --show-error \
  "$PAKPERK_API_ORIGIN/health/ready"

./scripts/verify_public_edge.sh \
  "$PAKPERK_SITE_ORIGIN" \
  "$PAKPERK_API_ORIGIN" \
  "$PAKPERK_TELEMETRY_ORIGIN"
```

将示例中的预发布环境源地址替换为受保护 values 文件中的确切值。
不要使用生产环境进行探索性测试。

边缘验证器会检查重定向、安全请求头、gzip、内容量受限的 Feed、配置、法律文档、
应用关联和遥测源行为。应运行受保护的公共边缘工作流来生成发布证据；
本地运行结果只能用于诊断。

### 证明一篇论文完整经过持久化队列

在受保护的预发布环境中，选择一篇经过运维人员审核的合成论文，
其许可证必须允许严格全文处理路径。将它已有的 Pakperk UUID（不是 arXiv
标识符）复制到当前任务专用的变量：

```bash
set -o pipefail
export PAKPERK_SMOKE_PAPER_ID='COPY_REVIEWED_STAGING_PAPER_UUID'

curl --connect-timeout 5 --max-time 30 --fail-with-body --show-error \
  "$PAKPERK_API_ORIGIN/v1/papers/$PAKPERK_SMOKE_PAPER_ID" \
  | jq '{paper_id, arxiv_id, title}'

curl --connect-timeout 5 --max-time 30 --fail-with-body --show-error \
  --request POST \
  --header 'Content-Type: application/json' \
  --data '{"retry":false,"trigger":"explicit_prepare"}' \
  --write-out '%{stderr}HTTP %{http_code}\n' \
  "$PAKPERK_API_ORIGIN/v1/papers/$PAKPERK_SMOKE_PAPER_ID/prepare" \
  | jq '{paper_id, generation, stage, overall_state, retryable}'
```

HTTP 202 表示作业已被接受；HTTP 200 表示该确切代次已经就绪或已处于终止状态。
轮询持久化的处理记录，不要再次提交写请求：

```bash
set -o pipefail
curl --connect-timeout 5 --max-time 30 --fail-with-body --show-error \
  "$PAKPERK_API_ORIGIN/v1/papers/$PAKPERK_SMOKE_PAPER_ID/processing" \
  | jq '{paper_id, generation, stage, overall_state, capabilities, retryable,
         last_error: (.last_error | if . == null then null else {category, code} end)}'
```

必须确认已审核的处理代次达到 `ready`，随后还要确认其获准的 Introduction 路由成功返回。
终止状态或可重试失败是需要诊断的证据，不能以此为理由循环调用 `prepare`：

```bash
set -o pipefail
curl --connect-timeout 5 --max-time 30 --fail-with-body --show-error \
  "$PAKPERK_API_ORIGIN/v1/papers/$PAKPERK_SMOKE_PAPER_ID/introduction" \
  | jq '{paper_id, generation, heading, paragraph_count: (.paragraphs | length)}'
```

只关联范围受限的请求 ID、处理代次、封闭集合中的阶段/错误类别以及队列汇总耗时。
不得在发布证据中保留论文全文、提示词或模型响应。

### 以受限身份手动运行一次元数据 CronJob

首先，只获取当前 release 的元数据 CronJob：

```bash
kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  get cronjobs \
  --selector "app.kubernetes.io/instance=$PAKPERK_HELM_RELEASE,app.kubernetes.io/component=metadata-sync" \
  --output name
```

复制 `cronjob.batch/` 之后的名称，选取一个唯一、全部小写且符合 DNS 规则的
冒烟 Job 名称，然后从该确切 CronJob 模板创建一个 Job：

```bash
export PAKPERK_METADATA_CRONJOB='COPY_EXACT_CRONJOB_NAME'
export PAKPERK_METADATA_SMOKE_JOB='pakperk-metadata-smoke-001'

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  create job "$PAKPERK_METADATA_SMOKE_JOB" \
  --from="cronjob/$PAKPERK_METADATA_CRONJOB"

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  wait "job/$PAKPERK_METADATA_SMOKE_JOB" \
  --for=condition=complete \
  --timeout=20m

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  logs "job/$PAKPERK_METADATA_SMOKE_JOB" \
  --container metadata-sync \
  --tail=-1
```

必须得到范围受限且成功的清单结果。检查渲染后的 Pod，证明它只引用元数据数据库
对应的 Secret 键；随后使用能够强制执行 NetworkPolicy 的 CNI 流日志或等效的平台
观测手段，证明其网络流量仅限于 DNS、经过审核的数据库 CIDR、arXiv 和 Collector。
NetworkPolicy YAML 只表达预期策略，并不是实际流量的观测结果。
该角色经过审计的 SQL 探测必须表明它只有元数据 DML 权限；它不得获得模型密钥，
不得访问 GROBID 路由或全文处理流水线，也不得拥有账户/删除权限。保留脱敏后的状态和日志，然后在
环境证据策略允许时，删除这一项指定的一次性 Job：

```bash
kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  delete "job/$PAKPERK_METADATA_SMOKE_JOB"
```

### 通过真实边界验证删除与遥测

启用删除 worker 时，只查找当前 release 的 Deployment，并在已配置的 Pod 内
运行只读账本验证器。查询必须返回一个 `deployment.apps/...` 条目；
将 `/` 后面的文本复制到 `PAKPERK_DELETION_DEPLOYMENT`：

```bash
kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  get deployments \
  --selector "app.kubernetes.io/instance=$PAKPERK_HELM_RELEASE,app.kubernetes.io/component=deletion-worker" \
  --output name

export PAKPERK_DELETION_DEPLOYMENT='COPY_EXACT_DEPLOYMENT_NAME'

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  exec "deployment/$PAKPERK_DELETION_DEPLOYMENT" \
  --container deletion-worker \
  -- /usr/local/bin/pakperk-deletion-worker verify-ledger
```

这只能证明当前挂载的签名清单通过了内部校验；不能证明提供商删除实际完成或恢复重放有效。
启用生产账户前，必须完成包含具体命令的
[参考提供商 E2E 门禁](runbooks/account-deletion.md#reference-provider-end-to-end-gate)
和受保护的
[恢复演练](runbooks/account-deletion.md#restore-drill-and-production-restore)。

运行本地测试，验证 Helm Chart 所固定的 Collector/脱敏/重启技术契约，
再完成[可观测性验证与告警](runbooks/observability.md#verification-and-alerts)中的
预发布环境的实时接收端检查，以及生产环境暗部署阶段的接收端检查：

```bash
HELM_BIN=helm ./scripts/test_backend_log_export.sh
```

本地测试工具不能证明数据已经实时交付。必须在真实接收端观察到隐私安全的
金丝雀事件，完成导入的全部 19 条规则对应的预发布告警通知与工单金丝雀测试，
从外部观察到 Collector 故障告警，并验证文档所述的 30 天保留行为。

### 完成与候选版本绑定的受保护演练

基础设施检查通过后，使用获准的合成身份和内容完成：

- 访客缓存 Feed 与阅读器行为测试；
- 计划启用账户时，验证 OIDC 发现、浏览器/原生客户端以及确切的签发者；
- 只有在预发布环境中启用相应依赖后，才测试个人资料、Library、评论、
  举报/屏蔽/内容审核和幂等写入；以及
- 启用生产账户前，验证删除请求、提供商操作、应用数据清除、签名账本、
  备份/恢复重放和历史密钥保留。

确切的身份轮换、幂等性、跨副本配额和功能切换流程见
[受保护的认证、写入与切换演练](runbooks/release.md#protected-auth-write-and-switch-exercise)。
冒烟路径稳定后，运行只限预发布环境且范围受控的
[访客负载门禁](runbooks/backend-load-testing.md#guest-gate)；负载测试工具按照设计会拒绝生产环境。

只记录范围受限的结果、哈希、数量和不可变引用。不得将令牌、用户内容、论文全文、
提示词、身份属性、Secret 数据、原始 Pod 对象或集群凭据写入证据。

## 按依赖顺序逐项启用功能

每次只更改受保护 values 中一个失败时明确拒绝的开关，重新渲染、部署，
并在发布操作手册要求时证明关闭/开启/再次关闭的行为。应先启用依赖项，
最后才启用强制执行或写入开关。需要撤回变更时，先关闭依赖方的强制执行和写入能力，
再关闭其提供商。

以下是几项重要的依赖顺序示例：

- 先启用账户，再启用 Library 或评论；
- 先启用 Library，再启用 Library 写入；
- 先启用论文标识解析（paper resolution），再启用标题搜索或导入；
- 先启用阅读 Feed，再启用 To Read First 强制规则；
- 先启用 Lookup，再启用 Explore，最后启用保存查询；
- 先启用订阅，再启用通知；以及
- 先启用 Deep Reader，再启用 Passport、分面、视觉内容、批注、版本差异或
  assistant v2。

路由处于健康状态，并不能证明其后台队列、保留策略、隐私、内容审核、无障碍或
人工领域审核门禁已经通过。确切的分阶段顺序见[发布](runbooks/release.md)和
[Deep Reader 分阶段发布](runbooks/deep-reader-rollout.md)。

## 在不破坏状态的前提下回滚

回滚必须在部署前准备，而不是等事故发生后才开始准备。

1. 按依赖关系的相反顺序关闭强制执行与写入开关。
2. 如果只有应用代码存在问题，仅当先前获准镜像中的代码明确兼容 schema 24 时，
   才能部署其镜像摘要。
3. 常规应用回滚期间，应保留 schema 24。代码仓库采用仅向前的扩展—收缩式迁移，
   不提供自动执行的破坏性向下迁移。
4. 如果无法避免从备份恢复数据库，应遵循备份/恢复操作手册，
   将相互绑定的 PostgreSQL、Keycloak、当前删除账本和历史密钥一并恢复。
   重新开放流量前，再次应用已经最终确认的删除记录。
5. 针对实际回滚后的状态，重新运行就绪、公共边缘、队列、删除、遥测和功能
   冒烟检查。

不要把 `helm rollback` 当成数据库回滚。Helm 操作可以更改工作负载清单，
也可能执行 Helm Chart hook；但它无法撤销已经提交的应用数据，
也无法安全地重建外部账本。

### 停用后清理数据库迁移 hook 资源

数据库迁移 Job、对应的 ServiceAccount 和 NetworkPolicy 都是 Helm hook，
不是普通 release 对象。因此，`helm uninstall` 和首次原子安装失败都可能留下它们。
数据库迁移期间不得移除这些资源，也不能仅仅因为应用分阶段发布失败就将其移除。

有意停用 release 后，或者明确放弃首次安装失败的 release 后，应保留脱敏的
Job 状态/日志，并证明没有数据库迁移 Job 或 Pod 仍在运行：

```bash
kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  get jobs,pods \
  --selector "app.kubernetes.io/instance=$PAKPERK_HELM_RELEASE,app.kubernetes.io/component=migration"

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  get serviceaccounts,networkpolicies \
  --selector "app.kubernetes.io/instance=$PAKPERK_HELM_RELEASE,app.kubernetes.io/component=migration"
```

只有在列出的每个数据库迁移 Job 都已成功完成或失败，并且没有数据库迁移 Pod
仍在运行时，才能删除当前 release 的 Job 及其两项前置资源，然后确认选择器
返回空结果：

```bash
kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  delete jobs \
  --selector "app.kubernetes.io/instance=$PAKPERK_HELM_RELEASE,app.kubernetes.io/component=migration"

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  delete serviceaccounts,networkpolicies \
  --selector "app.kubernetes.io/instance=$PAKPERK_HELM_RELEASE,app.kubernetes.io/component=migration"

kubectl --namespace "$PAKPERK_K8S_NAMESPACE" \
  get jobs,pods,serviceaccounts,networkpolicies \
  --selector "app.kubernetes.io/instance=$PAKPERK_HELM_RELEASE,app.kubernetes.io/component=migration"
```

绝不能扩大该选择器的范围，也不能图省事删除整个命名空间；其中可能仍保留着
PVC、Secret、证据或其他 release。

## 如果只需要临时的远程开发服务器

对于短期私有开发环境，只有主机防火墙或私有 VPN 阻止公网访问其数据库、
GROBID、Keycloak、Mailpit 和 API 端口时，才能在远程 VM 上运行 Compose。
该环境必须保持为**开发**类别并使用 `FULLTEXT_POLICY=prototype`，但不得将
默认密码视为安全边界。替换可配置的 Keycloak 默认值，使用隔离且可随时销毁的主机，
并牢记 Compose 中的应用数据库凭据有意仅供开发使用；严格的网络隔离是强制要求。

一种更安全的访问方式是从开发电脑建立 SSH 隧道：

```bash
ssh -L 8080:127.0.0.1:8080 YOUR_USER@YOUR_PRIVATE_SERVER
```

连接到该电脑的 Android 手机随后可以使用文档中的
`adb reverse tcp:8080 tcp:8080` 路径。iPhone 真机进行实时联网测试时，
仍然需要一个可访问且使用受信任 HTTPS 证书的端点。不得将这种远程 Compose
形式称为预发布、生产或发布证据。

## 运维人员最终检查清单

宣布后端部署完成前，请对每一项适用问题明确回答**是**：

- 是否记录了集群版本和确切的当前上下文？
- 后端与站点镜像是否从获准的交接产物中取得，并按镜像仓库中的不可变摘要拉取？
- PostgreSQL 角色是否彼此独立、遵循最小权限原则，并已针对 schema 24 就绪？
- 备份是否真实、可恢复，而且与本次数据库迁移尝试绑定？
- 当前删除账本和历史密钥是否已分别备份？
- values、日志、命令和证据中是否完全没有 Secret 字节？
- DNS、TLS、HSTS、gzip、真实 IP 信任、受信任代理 CIDR 和
  NetworkPolicy 是否与实际观测到的流量一致？
- 公共源地址、OIDC 客户端、移动端应用关联和法律文档版本是否完全一致？
- 是否已经证明 GROBID、arXiv、模型、删除、遥测和告警依赖不只是进程存活？
- 可选功能是否仍保持关闭，除非相应的确切受保护门禁和人工门禁均已通过？
- 是否已准备兼容当前 schema 的回滚方案和完整恢复流程？
- 最终功能图谱是否已经与完成情况审计和不可变发布记录核对一致？

如果任何答案是“未知”，如实状态应是“已部署，但尚未为该能力做好准备”，
而不是“应该已经准备好了”。
