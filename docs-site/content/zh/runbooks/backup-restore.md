# 备份、PITR、恢复与删除重放操作手册

**负责人：** 数据库恢复负责人以及隐私/值班负责人。
**适用范围：** PostgreSQL、Keycloak PostgreSQL、独立的签名删除
台账，以及验证/解密保留台账记录所需的密钥历史。

本仓库提供恢复/重放机制，但无法证明托管提供商的快照、
WAL 归档、保留期或恢复时间。发布记录必须写明该环境的
已测量 RPO/RTO、最新已验证备份 ID、恢复点、存储清单以及演练证据。
在一次真实的隔离恢复完成本操作手册之前，当前的备份/恢复门禁尚未
通过。

## 不可妥协的拓扑结构

- PostgreSQL 与 Keycloak 具备可分别恢复的备份与凭据。
- 最终的已签名删除台账卷会在独立于两个数据库的恢复时间线上进行
  备份。数据库 PITR 必须挂载当前台账，绝不能挂载来自较旧数据库
  恢复点的台账快照。
- 当前及保留的历史台账签名密钥、身份指纹密钥与提供方坐标加密
  密钥均可通过密钥管理器恢复。它们不会与应用数据存储在同一个
  备份归档中。
- `ACCOUNT_RECOVERABLE_BACKUP_DAYS` 涵盖每一个能够恢复删除前个人数据的
  快照、副本、归档、导出以及 PITR 来源。台账保留期严格更长。在更改
  任一取值之前，请参见 [account-deletion.md](account-deletion.md)。
- 备份作业使用只读/导出权限；恢复则使用专用的隔离目标。迁移、API、
  worker、Keycloak 与备份角色保持彼此独立。

## 发布前的备份验证

请在受保护的发布数值中记录一个不可变的备份 ID，并验证以下全部
事项：

1. PostgreSQL 基础备份/快照已完成，且其 WAL/PITR 链已
   到达声明的恢复点。
2. Keycloak 备份已完成至一个兼容的时间点，并包含 Realm
   状态、客户端、服务账户角色映射以及用户身份。
3. 当前的删除台账与所需的历史密钥均存在于独立清单之中。请对
   只读副本运行 `pakperk-deletion-worker verify-ledger`；在不可变清单中记录其
   确切的规范记录计数以及 `ledger_inventory_sha256`；绝不检视或复制明文
   提供方坐标。该域分隔摘要绑定的是签名者环境与有序的规范签名
   记录信封，而不仅仅是其计数。当不存在删除记录时，应记录一个
   显式的零值及其特定环境的空清单摘要。摘要绑定的是逻辑记录
   集合，而非存储设备身份；受保护的存储清单必须独立证明实际
   挂载的是哪个物理卷或对象版本。
4. 校验和、静态加密证据、保留期/到期时间、区域/账户以及恢复
   权限均在不含密钥的情况下被记录。
5. `migration.confirmBackupId` 用于命名此证据。请勿复用某个测试夹具
   或此前某次发布的标识符。

## 隔离恢复与 schema 门禁

1. 创建一个网络隔离的非生产目标环境，不含公共入口、API、计划任务或删除 worker。在删除重放准备就绪之前，拒绝出站的身份管理访问。
2. 将 PostgreSQL 与 Keycloak 恢复到所选的时间点。在运行更新的迁移之前，先恢复 schema 与数据。确认已恢复的数据库名称、预期的 `_sqlx_migrations` 版本，以及 `vector`、`pg_trgm` 与 `pgcrypto` 是否均在 `public` schema 中确切地各自安装了一次。仅存在扩展名称是不够的。
3. 以仅限所有者访问的方式挂载**当前**独立台账及全部所需密钥。将 `APP_ENV` 与 `ACCOUNT_DELETION_LEDGER_ENVIRONMENT_ID` 设置为相同的 `development` 或 `staging` 值。演练框架会拒绝生产环境。
4. 在已恢复的数据库中安装一个短期防护标记。使用一个唯一标记，其取值为经脱敏的持久恢复变更 ID，且到期时间不超过 24 小时。该框架还会将这一经证明且受防护绑定的确切标记用作重新应用时的数据库审计操作者：

   ```sql
   CREATE TABLE public.pakperk_restore_drill_guard (
       marker text PRIMARY KEY,
       backup_id text NOT NULL,
       recovery_point timestamptz NOT NULL,
       restore_attestation_sha256 text NOT NULL,
       expected_ledger_inventory_sha256 text NOT NULL,
       expires_at timestamptz NOT NULL
   );
   REVOKE ALL ON public.pakperk_restore_drill_guard FROM PUBLIC;
   INSERT INTO public.pakperk_restore_drill_guard(
       marker, backup_id, recovery_point, restore_attestation_sha256,
       expected_ledger_inventory_sha256, expires_at
   ) VALUES (
       'restore-CHANGE-ID',
       'backup-change-123-20260802t010000z',
       '2026-08-02T01:00:00Z',
       'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
       'sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
       statement_timestamp() + interval '2 hours'
   );
   ```

5. 确保监控/管理客户端均已断开连接。该框架会拒绝任何其他数据库会话。这只是一次时间点观测，并不能证明网络隔离；请另行保留网络策略证据。

## 迁移 12–18 发布演练

这是保留下来的 Plan 02 演练技术契约。在启用任何 Plan 02 开关之前，请针对已部署的 schema-11 生产形态备份的隔离恢复环境，演练扩展与恢复路径：

1. 保留提供商备份/PITR 回执、恢复点、schema-11 迁移历史、数据库身份，以及当前独立的删除台账清单。
2. 运行确切的、经过评审的独立迁移镜像与 DDL 角色一次。要求迁移 12 到 18（即 `0012_library_v2.sql` 到 `0018_recommendation_generation_jobs.sql`）依次成功，并要求从 1 到 18 的每一条历史记录都具有经评审的校验和以及 `success=true`。
3. 再次运行相同的迁移命令，并证明其为空操作。验证 v0.0 到 Inbox 的兼容性投影；五态 Library 修订版本；研究资料来源分离；推荐队列/资料/反馈边界及确切/基础身份排除项；仅含元数据的搜索索引；已保存查询/简报/订阅/通知的所有权；账户删除级联；交互原因代码兼容性；保留期清理/索引；以及运营证据中不含原始提交的标题、URL、私人笔记、资料标签、反馈详情或通知负载。
4. 针对已扩展的 schema 演练最后一个 schema 兼容镜像，然后再前向到候选版本。功能回滚会保持 schema 18；切勿仅为关闭某个开关而使用向下迁移或将 schema 恢复到 11。
5. 完成台账重新应用与下文的收尾流程，并使用 `PAKPERK_RESTORE_DRILL_EXPECTED_MIGRATION=18`，然后保留受保护的内容 ID、备份/PITR 审计记录、完整性结果、回滚/再前向结果、清理，以及数据库/隐私/发布批准。

仓库中的迁移测试与封闭式恢复框架仅验证该机制本身。在完成由提供商支持的隔离恢复、迁移 Job、当前台账重放以及 schema 兼容回滚，并获得外部锚定证据之前，本门禁将保持开放状态。

## 迁移 19–24 当前发布演练

当前的 Plan 03 候选版本从已验收的 schema-18 Plan 02 边界开始，止于 schema 24。在启用任何 Plan 03 开关之前：

1. 恢复一个隔离的、生产形态的 schema-18 备份，并保留其提供商/PITR 回执、恢复点、数据库身份、确切的迁移历史，以及当前独立的删除台账清单。
2. 运行确切的、经过评审的独立迁移镜像与 DDL 角色一次。要求 `0019_preparation_trigger_audit.sql`、`0020_document_model.sql`、`0021_passport_provenance.sql`、`0022_annotations_memory.sql`、`0023_version_diff.sql` 以及 `0024_annotation_archive_import.sql` 依次成功。从 1 到 24 的每一条迁移历史记录都必须具有经评审的校验和以及 `success=true`。
3. 再次运行相同的迁移命令，并证明其为空操作。验证已批准的准备触发器检查与幂等性；旧版 Introduction 与 `/chat` 的兼容性；按生成代次划分的文档、视觉、Passport、语义及溯源信息约束；限定主体范围的私有产物及导出/导入边界；账户删除级联；助手过期索引；以及稳定、有界的版本差异持久化。该 schema 不得新增第二个 Library 或阅读 Feed 权威源。
4. 针对与 schema-18 兼容的最后一个镜像（该镜像已获发布负责人明确批准）演练至 schema 24，然后前向滚动到候选版本。在 Plan 03 的写入数据存在之后，只能使用能够安全忽略或理解这些新增表的镜像。功能回滚会保持 schema 24 并关闭开关；切勿运行向下迁移或将 schema 恢复到 18，即便目的仅仅是禁用 Deep Reader。
5. 完成删除台账重新应用与下文的收尾流程，并使用 `PAKPERK_RESTORE_DRILL_EXPECTED_MIGRATION=24`。证明已恢复的、属主绑定的标注、冲突、标注导入台账、证据卡片、检查点、记忆、助手历史/溯源信息以及操作行均已再次被删除，而共享的论文与规范化的文档数据仍然保留。

仓库中的迁移与持久化测试仅能证明该机制本身。在由提供商支持的隔离恢复、确切的迁移 Job、当前台账重放、schema 兼容的回滚/再前向、隐私扫描，以及数据库/隐私/发布批准被外部锚定到该候选版本之前，本门禁将保持 `not_ready`。

## 重新应用与收尾

请使用确切的、经过评审的 worker 二进制文件，以及与已恢复环境相同的密钥文件/配置，运行第一阶段。首先创建一份受保护的、仅限所有者访问的规范 JSON 恢复证明。它是一个封闭 schema：不接受遗漏或额外的成员、重复的名称、非有限数值、多个文档、缩进，或不同的键顺序。

```json
{"backup_id":"backup-change-123-20260802t010000z","backup_observed_at":"2026-08-02T01:02:00Z","database":"pakperk_restore_change_123","environment":"staging","expected_ledger_inventory_sha256":"sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789","expected_ledger_records":42,"expected_migration":24,"latest_recoverable_point":"2026-08-02T01:01:00Z","marker":"restore-change-123","recovery_point":"2026-08-02T01:00:00Z","restore_completed_at":"2026-08-02T01:17:00Z","restore_started_at":"2026-08-02T01:02:00Z","schema":2,"source_revision":"0123456789abcdef0123456789abcdef01234567","worker_sha256":"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}
```

将其权限模式设置为 `0600`（或更严格），并将其 SHA-256 单独记录在受保护的发布记录中。防护记录行必须包含相同的摘要、备份 ID 与恢复点。恢复点使用规范的整秒 UTC 精度；数据库中的小数值会被拒绝，而不是被静默截断。该证明必须在此前 24 小时内完成，且其时序必须满足 `recovery_point <=
latest_recoverable_point <= backup_observed_at <= restore_started_at <
restore_completed_at`。

```bash
APP_ENV=staging \
ACCOUNT_DELETION_LEDGER_ENVIRONMENT_ID=staging \
PAKPERK_RESTORE_DRILL_CONFIRM=isolated-nonproduction-restore \
PAKPERK_RESTORE_DRILL_PHASE=reapply \
PAKPERK_RESTORE_DRILL_DATABASE=pakperk_restore_change_123 \
PAKPERK_RESTORE_DRILL_MARKER=restore-change-123 \
PAKPERK_RESTORE_DRILL_EVIDENCE_DIR=/secure/evidence/change-123-reapply \
PAKPERK_RESTORE_DRILL_EXPECTED_MIGRATION=24 \
PAKPERK_RESTORE_DRILL_EXPECTED_LEDGER_RECORDS=42 \
PAKPERK_RESTORE_DRILL_EXPECTED_LEDGER_INVENTORY_SHA256=sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789 \
PAKPERK_RESTORE_DRILL_SOURCE_REVISION=0123456789abcdef0123456789abcdef01234567 \
PAKPERK_RESTORE_DRILL_WORKER_SHA256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
PAKPERK_RESTORE_DRILL_BACKUP_ID=backup-change-123-20260802t010000z \
PAKPERK_RESTORE_DRILL_RECOVERY_POINT=2026-08-02T01:00:00Z \
PAKPERK_RESTORE_DRILL_RPO_SECONDS=120 \
PAKPERK_RESTORE_DRILL_RTO_SECONDS=900 \
PAKPERK_RESTORE_DRILL_ATTESTATION=/secure/restore/change-123-attestation.json \
PAKPERK_RESTORE_DRILL_ATTESTATION_SHA256=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
PAKPERK_DELETION_WORKER_BIN=/usr/local/bin/pakperk-deletion-worker \
./scripts/drill_backup_restore.sh
```

请将每一个示例性的修订版本、摘要、备份 ID、恢复点以及测量目标，替换为来自已批准恢复记录的不可变值。该修订版本必须等于干净检出的 `HEAD`；该 worker 必须是一个可执行的常规非符号链接文件，其 SHA-256 必须与经评审的摘要一致。备份 ID 会拒绝占位符/测试夹具形态的取值。恢复点必须是有效的 UTC 时间戳。RPO 独立计算为 `backup_observed_at -
recovery_point`；RTO 计算为 `restore_completed_at -
restore_started_at`。所提供的有界整数值必须与这些计算结果确切相等。`latest_recoverable_point` 记录的是所观测到的备份链可达范围，但它有意不会在实际演练的 RPO 计算中替代恢复点。

该脚本会在任何写入之前验证每一条台账记录，运行 `reapply-ledger`，证明该摘要涵盖了每一条已验证记录，检查匹配的已恢复用户是否已被禁用，检查每条台账是否都有对应作业，并写入仅限所有者访问的内容寻址证据。它还要求确切的数据库名称、当前迁移、到期防护标记、环境绑定、隔离性，以及来自不可变的恢复前清单的确切台账计数。只有在显式提供确切的空清单摘要时，计数为零才是有效的。该 worker 的验证摘要与重新应用摘要必须都等于受保护的取值，因此非空、缺失、陈旧、被替换或计数相同但内容有误的台账集合都不可能悄无声息地产生通过的证据。对于空集合，摘要仍会绑定所声明的环境，但无法区分两个物理上不同的空卷；需要另行提供受保护的存储卷/对象版本清单。该上下文将这一局限记录为 `empty_inventory_digest_does_not_prove_physical_storage_identity`。请将已挂载的台账保持为只读，并且不要在验证与重新应用两个阶段之间运行追加或清除操作。
在任何咨询锁、迁移或恢复重放变更之前，独立迁移连接以及每一个池化的 worker 连接都会将 `search_path` 强制设置为确切的 `public, pg_catalog`，并将其读回，同时要求生效的当前 schema 为 `public`。该框架对每个 `psql` 会话也执行相同操作。这一重置发生在 PostgreSQL 应用启动设置之后，因此 `DATABASE_URL` 的 `options` 参数无法将未限定的对象重定向到攻击者选定的 schema 中。在其首次数据库快照之前（也就是在其首次调用 `public.digest` 之前），该框架还会将 `pg_extension` 与 `pg_namespace` 相连接，并要求 `vector`、`pg_trgm` 与 `pgcrypto` 必须各自确切地从 `public` 解析一次，否则即失败。应用就绪状态强制执行相同的命名空间约定。
在重新应用时，该框架会移除任何继承得到的 `PAKPERK_ADMIN_ACTOR`，并将其设置为经证明的恢复标记。因此，调用方控制的操作者无法替换由 PostgreSQL 记录的持久变更 ID。
在这两个阶段中，它还会强制设置 `RUN_MIGRATIONS=false`；经评审的 worker 的确切就绪检查必须检查已恢复的迁移历史，而不先对其进行修复或推进，即便在 `APP_ENV=development` 时也是如此。

该框架会将已读取、经评审的 worker 字节复制到私有暂存区，绑定该副本的摘要，仅运行该副本，对其 stdout/stderr 进行有界且私密的捕获，并在运行失败时不发布任何内容。同一 UID 的恢复操作者仍处于信任边界之内：可移植的所有者权限与本地摘要，并不能使某个文件对一个蓄意的恶意同 UID 进程保持不可变。证据目标必须是一个全新的绝对路径；已存在的目标、符号链接目标以及被符号链接的父级组件，都会在任何数据库或 worker 操作之前的受保护输入准备阶段失败。

仅限所有者访问的清单绑定了 schema 版本、源代码修订版本、worker 摘要、恢复证明摘要、备份标识符、已恢复的恢复点、经证明的 RPO/RTO 时间戳、迁移、环境、数据库、标记、阶段，以及确切的台账计数与清单摘要。经证明的标记同时也是数据库重新应用审计操作者。数据库防护标记会独立重复记录数据库、标记、备份 ID、恢复点、证明摘要以及预期的清单摘要。最终上下文记录数据库观测到的台账计数，加上预期、已验证以及（在重新应用期间）已重新应用的清单摘要，并要求跨文件确切相等。该封闭式自测试通过伪造依赖项演练生产预检、数据库快照、worker 摘要、证据收尾以及失败路径；它并不声称真实的数据库或备份已被恢复。

每个阶段还会在任何必需的账户、论文、核心作业、library、评论/安全或删除相关的表缺失时失败。其校验和数据库快照记录了 `users`、`papers`、`jobs`、`user_paper_library`、`library_operations`、`paper_comments`、`comment_reports`、`user_reports`、`user_blocks`、删除台账以及删除作业的行计数。每份快照还会记录 `local_deletion_bindings_sha256`。该摘要绑定的是固定 `pakperk-local-account-deletion-bindings-v1` 域下的一个有序规范 JSONB 数组：其中包含每一条台账操作 UUID、原始用户 UUID、指纹密钥 ID 与指纹字节，以及关联的作业操作 UUID、目标用户 UUID、指纹绑定，还有可为空的提供方绑定。UUID 使用 PostgreSQL 的规范文本形式，字节使用小写十六进制，空值与数组边界均为显式表示，且各行按操作 UUID 排序，因此拼接与排序不会发生冲突。提供方签发者/主体字符串绝不会进入证据；只有它们经域分隔的嵌套 SHA-256 会参与外层摘要。论文与核心作业计数必须在台账验证/重新应用期间保持不变；而账户所有的计数可能会随着删除义务被正确重放而减少。

随后仅允许已恢复的删除 worker 访问已恢复的 Keycloak，启动 `pakperk-deletion-worker run`，并持续监控直至每一个已重放的作业都达到 `completed`。提供商缺席是幂等的；认证、授权、网络、语义以及终态失败均仍然会阻塞发布。请勿开放用户流量。停止该 worker，并使用 `PAKPERK_RESTORE_DRILL_PHASE=finalize` 与一个新的证据目录再次运行该框架。收尾阶段要求零个未完成/终态作业、零个匹配的已恢复用户、完整的台账验证，以及没有缺失的作业。请复用完全相同的源代码修订版本、worker 摘要、备份 ID、恢复点以及所测得的 RPO/RTO，以便这两个产物描述的是同一次恢复演练。它还要求将 `PAKPERK_RESTORE_DRILL_PRIOR_REAPPLY_CONTENT_ID` 设置为重新应用阶段打印出的、已进行外部锚定的 `pakperk-restore-evidence-v2:sha256:...` ID，并将 `PAKPERK_RESTORE_DRILL_PRIOR_REAPPLY_EVIDENCE_DIR` 设置为包含该实际包的绝对目录。收尾阶段会完整验证此前的包，并要求其计算得到的 ID 相匹配、其恢复证明字节完全相同、其 `recorded_at` 不晚于收尾阶段，且其重新应用后的论文/核心作业计数、迁移、本地台账计数以及本地删除台账/作业绑定摘要，均等于收尾阶段运行前的快照。收尾阶段是只读的：每一个数据库快照成员（包括该绑定摘要）在其验证前后都必须保持一致，且本地所表示的台账清单必须确切，同时不存在与某条台账原始 UUID/指纹、作业目标 UUID 或作业签发者/主体相匹配的用户行；不存在不安全的活跃匹配；不存在缺失的作业；不存在未完成的作业；也不存在终态作业。一个处于 `deletion_pending` 状态的用户，可能会在重新应用之后立即存在（包括一行以新的本地 UUID 恢复的、与提供商匹配的记录），但在删除 worker 完成、且收尾阶段开始之前，必须不再存在。伪造的或不可用的 ID 并不构成一条证据链。两个阶段都要求 `recorded_at` 处于从恢复完成起、最多 24 小时之后的范围内，并保留现有的五分钟未来偏移上限。

离线验证会重复相同的证据链检查。仅凭 ID 本身无法验证某个收尾包：

```bash
python3 -I -B scripts/restore_drill_evidence.py verify-package \
  /secure/evidence/change-123-finalize \
  --prior-reapply-evidence-dir /secure/evidence/change-123-reapply
```

在完成收尾之后，对每个已恢复的数据类别进行抽样：论文元数据与核心作业记录保持完整；已删除的 Keycloak 身份确实缺失；同一签发者/主体无法进行 JIT 即时预配；用户、library、评论、屏蔽、举报、草稿/缓存、会话以及令牌相关的应用行，均已缺失或已按策略完成假名化；保留的内容审核证据不包含任何直接的账户引用。只记录计数与带密钥的完整性结果，绝不记录内容本身。

## 批准与拆除

证据必须包含备份/恢复 ID 与时间戳、组件版本、worker 镜像摘要、schema 版本、确切的台账计数、外部清单摘要以及本地台账/作业绑定摘要、台账验证/重新应用 JSON、校验和、终态/未完成计数、参考设备/服务检查、RPO/RTO、操作人员/变更记录，以及隐私/恢复批准。绝不能包含数据库 URL、令牌、密钥材料、提供方坐标、邮箱、用户名、原始 IP 或 UGC。

成功时，新的证据目录中只会包含 `pakperk-restore-evidence.tar` 与 `PACKAGE_SHA256.json`，二者均为所有者可读、具有单个链接的常规文件。该确定性 tar 包内含规范 JSON 与 `SHA256SUMS`；脚本会重新打开它，验证其封闭的成员集合，并在报告成功之前重新计算每一个校验和以及域分隔的内容 ID。请将打印出的内容 ID 记录到运行器之外的一个仅追加的发布系统中。本地权限与校验和可以检测相对于该锚点的变化，但无法阻止所有者替换这两个本地文件。

Schema-2 证明与 schema-2 包使用 `pakperk-restore-evidence-v2:sha256:` 内容 ID 域。当前工具会拒绝 schema-1 证明、v1 包，以及 v1 的此前重新应用 ID。历史性的 v1 证据在其固定的历史源代码修订版本下仍可审计，但无法满足或链接进这一确切清单发布门禁。

恢复证明将一份受保护的提供商/操作人员声明绑定到数据库防护标记与结果；它**并不能**独立证明托管提供商的备份 ID、WAL 可达范围、时间戳或恢复操作。请将提供商的签名回执或控制平面审计记录，与外部内容 ID 锚点一并保留。

批准之后，请根据证据保留策略销毁隔离数据库、Keycloak 目标、临时密钥以及防护标记。一次成功的演练并不授权生产环境回滚。请在备份拓扑、保留期、删除 schema、密钥历史、提供商 Realm 或恢复工具发生变化时，以及按组织既定的节奏重复本流程。
