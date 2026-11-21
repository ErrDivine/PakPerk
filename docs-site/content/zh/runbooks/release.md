# 发布、迁移、回滚与商店候选版本操作手册

**负责人：** 发布经理。**批准者：** 服务负责人、数据库负责人、隐私/安全负责人，以及针对商店候选版本的移动端签名负责人。

仓库自动化流程构建候选版本，并在证据缺失时失败并拒绝。它不会建立真实的备份、批准生产发布、使用不可用的密钥进行签名、发布法务页面、上传商店构建，或人为制造性能与崩溃证据。

## 候选版本输入

- 一个干净的、经评审的修订版本，`./scripts/check.sh` 通过，且针对目标环境的每一项显式跳过均已解决。
- 一次针对该确切完整修订版本的、成功的受保护 `publish-release-images` 工作流。晋升必须消费 `promotion-handoff.json`；复制一个可变标签或手动替换一个未扫描的摘要，都不是发布证据。
- 匹配的 `0.2.0` Rust 工作区、Helm `appVersion`，以及移动端版本名称；移动端构建号必须超过两个商店中已上传的最高数值。
- 不可变的后端/site/GROBID/Collector 镜像摘要，以及成功的漏洞/许可证/密钥扫描、已生成的 CycloneDX SBOM、声明文件与校验和。移动端证据必须包括生产运行时的 Maven SBOM、两份匹配的 SwiftPM 锁文件，以及校验和完整的 Gradle 策略。
- 确切的 HTTPS 来源、OIDC Realm/客户端/重定向、支持联系方式、法务版本、Play 应用签名指纹、Apple 团队/bundle ID、经评审的出站 CIDR、入站代理来源 CIDR、数据库角色、删除台账声明、密钥轮换版本、OTLP 端点，以及经验证的备份 ID。
- 针对发布签发方密钥轮换/移除的受保护目标证据、确切的 Library 与评论操作重放、跨副本共享限流，以及下文所指定的每一个独立控制的功能/紧急关闭开关。
- 一次已批准的严格内容评审，以及[移动端发布阻塞项](../mobile-release.md#external-release-blockers)下所列的外部证据。

## 发布证据绑定范围

该 chart 的六个 `releaseEvidence` 数值是受保护的、规范证据清单的内容 ID，而不是变更编号、工作流运行 ID、工单 URL，或操作人员断言的哈希。每份清单都必须标识其负责人与批准者、UTC 验证窗口、目标环境、确切的来源修订版本与已部署/候选版本构建身份、证据产物摘要、结果，以及批准时间戳。除非受保护的发布系统能够取回并验证那些字节，否则一个摘要不具备任何证据价值。

| Chart 数值 | 所需范围 | 负责人 |
| --- | --- | --- |
| `legalReviewId` | 确切的已发布法务/支持版本、实际启用的数据/处理者与保留期、公开 URL 检查，以及批准 | 隐私/法务负责人 |
| `reviewerFlowId` | 一次性审核者账户的生命周期，以及针对访客、账户、安全与删除路径的、经脱敏的确切候选版本审核者步骤 | 商店发布负责人 |
| `strictContentReviewId` | 确切的严格后端/移动端策略、已展示且保留的 Introduction 行为、仅元数据行为，以及合格的内容权利批准 | 法务/内容负责人 |
| `moderationReadinessId` | 受保护的实时评论/用户举报/评论举报/屏蔽/管理与紧急关闭流程；专用的操作人员受众/允许列表拒绝矩阵；内容审核回退；经脱敏的输出；有人值守的响应目标；支持/删除/保留期依赖项；以及告警/工单金丝雀检测 | Trust & Safety 负责人 |
| `accountDeletionE2eId` | 使用真实密钥管理器、独立台账与告警路由，从受保护预发布环境的近期认证请求，一直到提供商/会话/应用数据完成的全过程 | 隐私/值班负责人 |
| `restoreDrillId` | 隔离的 PostgreSQL/Keycloak 恢复、确切的当前台账计数、外部清单摘要、本地台账/作业绑定摘要连续性、确切的 `public, pg_catalog` 变更会话绑定、用作重新应用审计操作者的经证明变更标记、schema-2/v2 重新应用/收尾包（其中实际的此前包已针对 ID/证明/时序/核心计数连续性重新验证）、RPO/RTO，以及恢复/隐私批准 | 数据库与隐私负责人 |

除 `restoreDrillId` 之外的这五个批准 ID，都使用封闭的 schema-1 技术契约，定义在 `scripts/production_approval_evidence.py` 中。一个受保护证据的生成方，必须使用已测量的产物与一个可问责的批准，调用其 `build_evidence(...)` API；该命令行界面被有意设计为无法把未经检查的文字说明或一个工作流运行编号，变成一次批准。请独立验证每一份已取回的规范清单，然后构建并重新打开一个捆绑包：

`restoreDrillId` 是已验证的 schema-2 收尾包的确切 `archive_sha256`，来自 `PACKAGE_SHA256.json`。请一并保留并验证同一文件的经域分隔的 `pakperk-restore-evidence-v2:sha256:` 内容 ID 及其实际的此前重新应用包链条。与 Helm 兼容的归档摘要，并不能替代那个更强的外部锚点或包验证。

```bash
python3 scripts/production_approval_evidence.py validate \
  protected/legal-review.json --gate legalReviewId
python3 scripts/production_approval_evidence.py validate-old-client-policy \
  protected/old-client-policy.json

approval_manifests=(
  --manifest "legalReviewId=protected/legal-review.json"
  --manifest "reviewerFlowId=protected/reviewer-flow.json"
  --manifest "strictContentReviewId=protected/strict-content-review.json"
  --manifest "moderationReadinessId=protected/moderation-readiness.json"
  --manifest "accountDeletionE2eId=protected/account-deletion-e2e.json"
)
umask 077
install -d -m 0700 protected
python3 scripts/production_approval_evidence.py bundle \
  "${approval_manifests[@]}" \
  --rendered-manifest protected/rendered-production.yaml \
  --old-client-policy protected/old-client-policy.json \
  --output protected/production-approval-bundle.json
python3 scripts/production_approval_evidence.py predeploy \
  protected/production-approval-bundle.json \
  "${approval_manifests[@]}" \
  --rendered-manifest protected/rendered-production.yaml \
  --old-client-policy protected/old-client-policy.json
```

每份清单都绑定确切的来源、镜像、chart、已签名的移动端候选版本、独立的恢复演练 ID，以及一个经域分隔的发布配置摘要，该摘要在计算时，这五个尚未产出的批准字段均为空。这是有意为之：让某个批准 ID 依赖于最终的 Helm 发布绑定（而该绑定自身又包含那个 ID），将会构成一个不可能的哈希循环。在这五个 ID 存在之后，请使用那些确切数值渲染最终的受保护 chart。该捆绑命令要求这次渲染，重新计算规范化的配置、镜像与完整发布绑定摘要，检查全部 ConfigMap 批准镜像，然后绑定完整的已渲染清单字节。

该捆绑包的 schema-2 部署声明，还携带确切的已渲染 `toReadFirstEnforcement` 数值，以及一个内容寻址的旧客户端策略 ID 或 `null` 二者之一。当强制执行为 false 时，该策略处于休眠且可选状态。如果最终的生产渲染将强制执行设为 true，则除非提供了相同的规范策略字节，且这些字节绑定了来自全部五份批准清单的确切来源修订版本、规范化发布配置、镜像、chart、恢复演练与已签名移动端候选版本，否则 `bundle` 与 `predeploy` 都会失败并拒绝。

旧客户端策略没有仓库默认值，且该验证器绝不会自行选择一个采用阈值。一个受保护的生成方必须调用 `build_old_client_policy(...)`，保留其来源证据，并针对恰好一种策略，获得封闭的 `product_release_owner` 批准：

| 策略 | 确切参数 | 所需的受保护证据 |
| --- | --- | --- |
| `minimum_supported_version` | 最低移动端版本/构建，以及固定的 `remote_configuration` 机制 | 已批准的策略记录、强制执行观测、回滚证据 |
| `disable_legacy_account_library` | 最后一个旧版本/构建，加上账户与 Library 访问均固定为 `disabled` | 已批准的策略记录、服务端/访问门禁观测、回滚证据 |
| `advisory_until_adoption_threshold` | 所有者选定的、以基点表示的阈值、观测小时数，以及固定为 `advisory` 的声明 | 已批准的策略记录、采用率测量、回滚证据 |

该 advisory（建议性）选项，只授权分阶段/建议性行为，直到外部测量证明达到所有者选定的阈值为止；该产物并不声称已达到该阈值，且绝不能被用来宣称已实现普遍强制执行。类似地，一份摘要只能证明哪一份受保护记录已被批准，而不能证明某个远程版本或旧版访问机制确已部署。那些实时观测、可问责的批准，以及回滚执行，仍是外部发布证据。只有在已渲染发布的严格强制执行开关为 false 时，省略 `--old-client-policy` 才是有效的。

该捆绑包还要求全部五份清单具有一个逐字节等同的批准绑定，并交叉检查审核者流程的法务、严格内容与删除引用。请将已渲染清单、五份清单、捆绑包、受保护审计记录，以及产物校验和一并保留。`predeploy` 会重新打开所有这些文件，且必须在应用已渲染清单之前成功完成。该 chart 无法取回受保护的批准文件，因此其语法检查不能替代这一步骤。schema 验证证明的是该记录是封闭且内部绑定一致的；它并不执行实时演练，也不能提供可问责的人工决定。

这些绑定涵盖的是服务端部署义务，其适用性遵循生产功能映射。它们有意**不会**把 Helm 变成用于镜像发布/安全扫描、公共边缘检查、预发布负载、迁移/回滚演练、实时遥测保留期/告警路由、受保护认证/写入/开关演练、已签名移动端候选版本、物理设备性能/崩溃窗口，或商店提交/评审的发布台账。这些门禁绑定到受保护发布记录中的一个确切候选版本，以及其各自具名的工作流/商店证据。一次暗部署的 Helm 分阶段发布并不满足这些要求，即便 `helm template` 成功执行，它们的缺失仍会阻塞公开/商店发布。

## 运营门禁证据捆绑包

迁移/回滚、实时遥测/保留期/告警，以及已签名移动端性能/崩溃观测，使用规范的 schema-1 技术契约，定义在 `scripts/operational_gate_evidence.py` 中。它们被有意设计为独立于 Helm 批准 ID：

| 门禁 | 内容 ID | 封闭的受保护范围 |
| --- | --- | --- |
| `migration_expand_contract` | `pakperk-migration-exercise-v1:sha256:` | 预发布环境 schema 18 到 24；经验证的恢复证据；经评审的迁移镜像；一个迁移 Job 与 DDL 角色；新旧兼容性；全部 30 个发布开关均已对账，且全部 39 条必需依赖边在不满足时均被拒绝；私有产物删除/恢复完整性；schema 兼容的代码回滚与再前向；数据库/隐私/发布批准 |
| `live_telemetry_retention` | `pakperk-live-telemetry-v1:sha256:` | 针对同一候选镜像的、独立的生产与预发布副本 Collector/网关/适配器/配置/接收器/保留期身份；经评审的一致性差异；生产安全金丝雀投递以及确切的 30 天保留边界；预发布的有效/恶意/脱敏/重启/page/ticket 检查；平台/可观测性/隐私批准 |
| `mobile_performance_crash` | `pakperk-mobile-performance-v1:sha256:` | 确切的已签名 APK/IPA 与版本/构建；经评审的设备/OS 矩阵；至少 20 个缓存帧与开场样本，p95 至多 1,500 毫秒，开场至多 700 毫秒；至少 20 次顺序请求，命中率 95% 且无空白卡片；至少 20 个帧样本；至少 24 小时与 200 个聚合确切候选版本会话，无崩溃率 99.5%；移动端/发布/隐私批准 |

每一个受保护生成方都必须产出规范数据，将其原始来源记录保留在 Git 之外，并同时通过清单预期的内容 ID 与一个单独批准的确切绑定。该绑定固定来源、目标环境、通过的 `deployment-binding-v1:` ID、候选版本/配置摘要，以及确切的生成方/驱动程序/适配器工具版本与摘要。在封存一份清单之前，请使用 `build_approval_subject_id(...)` 推导出其稳定的、经域分隔的执行主体 ID，然后要求每一位具名负责人，在清理之后的 14 天内批准该确切 ID。批准记录不能复用清理审计引用。一次前向修复可以作为额外的事件证据保留，但它不能替代这一新增的 18 到 24 发布门禁所要求的 schema 兼容回滚。请验证这三项结果：

由于规范文档形态与哈希算法未变，该迁移清单仍为 schema/domain v1。其封闭的当前发布策略确实发生了变化：一份针对 schema 10 到 11、11 到 16、11 到 17 的此前清单，或已完成的 Plan 02 schema 11 到 18 门禁，都无法满足新的 18 到 24 主体。一个只证明了六开关或十一开关的产物同样无法满足。当前清单必须绑定确切的主体、有序断言 ID、30 开关/39 边的技术契约，以及 schema-24 私有数据/恢复检查；此前的内容 ID 不得为这个候选版本复用。

对于遥测，请在生产环境与预发布金丝雀副本中使用相同的不可变 Collector、网关与适配器镜像。请分别绑定它们的配置、告警策略导入、接收器清单与保留策略；生产环境与预发布环境身份不可互换。请在受保护台账中重新打开两条具名的 `deployment-binding-v1:` 记录；生产 ID 必须等于清单的预期绑定，而预发布 ID 携带在预发布副本主体中。一致性记录必须表明，预发布环境只更改了经评审的环境过滤器/路由，且不会削弱这六项输入、19 条规则、脱敏，或 30 天策略。这两份接收器清单必须将全部 19 条规则，路由到 `page` 与 `ticket` 两者，且不存在无归属的接收器；零接收器的清单不算通过。请将一份隐私安全的金丝雀数据，通过暗部署的生产环境发送，并要求它到达生产汇点。请播种绑定的生产保留期金丝雀承诺，在最初以及从第 29 天起、直到第 30 天之前，分别观测每一项，然后在第 30 天与第 31 天之间，确认这些相同承诺均为零。UTC 时间戳与年龄指标必须确切对账。有效/恶意的移动端探针、重启重放/覆盖率，以及 page/ticket 投递，仍是预发布副本的金丝雀检测；它们不能悄悄替代生产投递或保留期证据。

```bash
python3 scripts/operational_gate_evidence.py validate \
  protected/migration-exercise.json \
  --gate migration_expand_contract \
  --expected-id "$MIGRATION_EVIDENCE_ID" \
  --expected-binding protected/migration-expected-binding.json
python3 scripts/operational_gate_evidence.py validate \
  protected/live-telemetry.json \
  --gate live_telemetry_retention \
  --expected-id "$TELEMETRY_EVIDENCE_ID" \
  --expected-binding protected/telemetry-expected-binding.json
python3 scripts/operational_gate_evidence.py validate \
  protected/mobile-performance.json \
  --gate mobile_performance_crash \
  --expected-id "$MOBILE_PERFORMANCE_EVIDENCE_ID" \
  --expected-binding protected/mobile-performance-expected-binding.json
```

在同一个来源修订版本的全部三项都通过之后，请构建并独立重新打开确切的捆绑包：

```bash
operational_manifests=(
  --manifest migration_expand_contract=protected/migration-exercise.json
  --manifest live_telemetry_retention=protected/live-telemetry.json
  --manifest mobile_performance_crash=protected/mobile-performance.json
)
python3 scripts/operational_gate_evidence.py bundle \
  "${operational_manifests[@]}" \
  --output protected/operational-gates-bundle.json
python3 scripts/operational_gate_evidence.py validate-bundle \
  protected/operational-gates-bundle.json \
  "${operational_manifests[@]}"
```

请将这三份清单、预期绑定、原始系统引用、字节摘要/内容 ID、负责人批准，以及 `pakperk-operational-gates-v1:sha256:` 捆绑包，都保留在不可变的发布台账中。该捆绑包强制要求一个共同的来源修订版本；发布台账还必须对账每一个部署/候选版本/配置身份。本仓库验证器不会运行任何迁移、汇点查询、保留期等待、告警投递、物理性能探测、商店查询，或人工批准。其测试只是 **R** 级证据；每一份受保护清单与决定仍为 **P/H**。

## 发布镜像发布信任边界

`publish-release-images` 使用三个全新的 GitHub 托管运行器。`build` 作业只具有 `contents: read` 权限，不具备受保护环境，且是唯一一个检出或执行候选版本源代码或已解析构建依赖项的作业。它会构建确切的 `sha-<source_revision>` 后端与 site 标签，并使用 `docker save` 冻结每一个镜像。其归档 ID、哈希与元数据被有意归类为**不受信任的构建交接**：一个存活下来的候选版本进程可以更改任何同运行器输出，因此没有任何扫描或发布决定会信任该作业的观测结果。原始交接文件会在禁用压缩的情况下上传，并只通过上传服务不可变的产物 ID 与摘要向后传递。

`scan` 作业是一个独立的、不含凭据的运行器，具有 `permissions: {}` 权限，不进行检出，也不执行任何候选版本编写的程序或容器。它会按 ID 下载原始构建产物（摘要不匹配即失败），拒绝非规范/重复键的清单，以及任何多余、符号链接、已链接、非运行器所有、可变、空或超大的成员，对两个归档重新计算哈希，加载但绝不运行它们，并再次推导出确切的、预期的标签到镜像 ID 映射。它会在四项固定的 Trivy 操作消费已下载的归档字节之前，将输入树设为只读：两次阻塞性漏洞扫描与两次 CycloneDX 镜像 SBOM 生成。由于候选版本进程无法跨越该作业边界，它们无法与扫描报告、SBOM、扫描后归档哈希、可信清单或上传操作产生竞态。

在再次对两个归档重新计算哈希之后，这个全新的扫描作业会创建规范的 `release-image-handoff.json`。其封闭 schema 绑定目标环境、来源修订版本、确切的仓库与标签、推导出的镜像 ID、Docker 归档名称与 SHA-256 摘要、每一个扫描/SBOM/工具链/依赖项/声明文件摘要，以及不受信任的构建产物 ID、产物摘要与清单摘要。该封闭交接界面会被设为只读，并在禁用压缩的情况下，以第二个不可变的产物 ID/摘要上传。两个中间产物都会被保留一天，且都不构成部署批准。

受保护的 `publish` 作业会在第三个全新的运行器上启动，只依赖已完成的扫描作业，且只有它具有 `packages: write` 权限以及所选的受保护环境。它不进行检出，也不执行任何候选版本编写的程序或容器。在 `PATH` 固定、且 `BASH_ENV`/`ENV` 被固定为 `/dev/null` 的情况下，它会按产物 ID 下载已扫描的交接文件，检查扫描产物与上游构建产物两者的溯源信息以及来源/环境绑定，拒绝非规范或重复键的清单以及任何多余/符号链接/可变文件，并对每一个归档与证据成员重新计算哈希。随后，它会在不运行的情况下加载这两个 Docker 归档，并要求已加载的标签到镜像 ID 映射，在进行注册表认证之前与已扫描清单相等。

`GITHUB_TOKEN` 只绑定到确切的推送步骤。该步骤只推送这两个重建的提交标签，并要求每次推送都恰好对应一个注册表报告的摘要。最终的规范 `promotion-handoff.json` 包含那些注册表摘要，加上已扫描产物 ID、已扫描产物容器摘要，以及已扫描清单摘要。`SHA256SUMS` 涵盖 90 天发布产物中的晋升交接文件、已扫描与不受信任构建清单、扫描结果、SBOM、工具链记录、依赖项清单，以及声明文件。晋升操作必须验证这些字节，并使用仅含摘要的 Helm 数值；它绝不能重新构建、重新打标签，或替换为本地守护进程的摘要。

环境评审者必须将全新作业隔离视为批准边界的一部分。请勿合并 `build` 与 `scan`，请勿将 `scan` 或 `publish` 转换为一个能够保留候选版本进程或 Docker 守护进程的自托管运行器，请勿为任一全新作业添加检出或候选版本钩子，请勿向 `scan` 授予令牌权限或受保护环境，请勿向 `packages: write` 授予 `build`，请勿按可变产物名称下载任一交接文件，也请勿在归档与已加载镜像 ID 检查之前暴露注册表令牌。

手动的 `live comments acceptance` 工作流是一个一次性的参考栈回归通道，而不是受保护的预发布环境。其证据具有一个封闭的安全 schema，以及非断言性的环境分类 `manual_ci_disposable_reference`；它并不证明 GitHub 环境保护措施的存在。其经域分隔的 `reference-sha256:` ID 被有意设计为对生产环境的 `moderationReadinessId` 无效；请勿将其产物校验和或 Actions 运行 ID 复制到该字段中。在评论创建功能可以被启用之前，目标环境记录必须针对确切的已部署候选版本，满足完整的[内容审核就绪矩阵](moderation.md#acceptance-and-production-readiness-evidence)。

## 公共边缘技术证据

请在启用功能或提交商店构建之前，针对暗部署的预发布或生产候选版本，运行手动的 `public edge verification` 工作流。请从 `main` 派发它，附带全部四项必需输入：

- `source_revision`：经评审的完整小写提交 SHA，必须等于所选的工作流修订版本、已检出的 `HEAD`，以及获取到的 `origin/main` 顶端；
- `target_environment`：确切为 `staging` 或 `production`；
- `candidate_id`：`sha256:` 加上 `promotion-handoff.json` 的确切摘要（记录在受保护镜像发布产物中、经验证的 `SHA256SUMS` 里）；以及
- `confirmation`：确切为 `RUN_PUBLIC_EDGE_VERIFICATION`。

请在每一个具名的 GitHub 环境上，配置这些非密钥变量。它们是受保护的发布坐标，而不是由派发控制的主机：

```text
PAKPERK_SITE_ORIGIN
PAKPERK_API_ORIGIN
PAKPERK_TELEMETRY_ORIGIN
PAKPERK_OIDC_ISSUER
PAKPERK_WEB_OIDC_CLIENT_ID
PAKPERK_SUPPORT_EMAIL
PAKPERK_PUBLIC_DOCUMENT_VERSION
PAKPERK_ANDROID_PACKAGE
PAKPERK_ANDROID_SHA256
PAKPERK_APPLE_TEAM_ID
PAKPERK_APPLE_BUNDLE_ID
```

该验证器会向公开解析的 80/443 地址，发起不经代理、不含凭据、禁用重定向的请求，并设有有界的 DNS、连接、总请求、请求头与正文限制。它会检查确切的 HTTP 到 HTTPS 重定向；TLS 与 HSTS；运行时配置；独立稳定的 HTML 路由及其安全/缓存请求头；声明的来源修订版本标记；Android 与 Apple 的关联身份；一个具有有效尾部完整性、有界解压、封闭 JSON 封装、确切公开缓存策略以及 `Vary: Accept-Encoding` 的完整 gzip 公开 Feed 流；API 就绪响应技术契约；以及遥测网关的进程就绪状态。一次失败的观测仍会产出一份封闭的、仅限所有者访问的、经脱敏的失败声明；该工作流随即会失败并拒绝，但会先保留确切来源产物。原始正文、请求头、传输错误、cookie、凭据、支持地址与操作人员身份都不会被保留。

该产物的 `public-edge-sha256:` 内容 ID，被有意设计为不是一个 Helm `releaseEvidence` 批准 ID。所请求的候选版本 ID 是发布记录上下文，并不会在边缘被观测到。公开声明标记只观测 site 来源修订版本；它并不能证明 API 镜像、Pod 镜像 ID、Helm 发布，或整体部署溯源信息。在晋升之前，平台负责人必须单独将实际的 Pod `imageID` 数值以及不可变的、已渲染的发布绑定 ConfigMap/摘要，与受保护的晋升交接文件及发布记录进行比对。

这一技术通道同样不会批准法务文本或披露信息，不证明 GitHub 环境评审者/分支设置，不证明已签名候选版本的托管情况，不测试物理设备通用链接，不完成已认证的账户删除，也不证明 Collector/导出/汇点投递。请将那些批准与受保护的实时金丝雀检测分开保留；请从发布台账中引用可取回的公共边缘产物摘要、工作流运行/时间、目标与结果。

## 暗部署溯源信息证据

在确切的、仅含摘要的 Helm 候选版本被暗部署并稳定之后，请使用 `scripts/deployment_binding_evidence.py`，用一份封闭的 `deployment-binding-v1:sha256:` 记录，取代此前的手动镜像 ID 比对。该构建器会交叉检查四项独立输入：

1. 来自受保护镜像发布产物的规范 `promotion-handoff.json`。
2. 由发布记录所选定的、唯一实时不可变的 `release-evidence` ConfigMap，使用 `kubectl get configmap NAME -o json` 导出。
3. 在分阶段发布稳定之后导出的一个命名空间 PodList。每一个已选中的 Pakperk Pod 都必须处于 Running 且 Ready 状态，每一个常规与初始化容器规格镜像都必须等于其发布绑定，每一个运行时 `imageID` 都必须公开相同的可拉取仓库与摘要，且副本数量必须与经评审的预期确切匹配。每一个 Deployment Pod 必须只有一个 ReplicaSet 控制器所有者，每一个 Collector Pod 必须只有一个 DaemonSet 所有者，且在分阶段发布稳定之后，某个组件的全部 Pod 必须共享同一个所有者 UID。已完成的迁移/元数据同步 Pod 会被忽略；一个活跃或已失败的临时作业，会使这次捕获失败并拒绝。
4. 一份规范的、仅限所有者访问的观测 JSON，只包含环境、来源修订版本、捕获时间、发布命名空间/实例、一个单向集群身份、确切的预期副本数与经评审的默认 Pod 规格、已渲染数值/认证/数据库角色/NetworkPolicy/保留期/密钥版本评审的摘要、经评审的入站控制器仓库/摘要/配置/引用、一个确切镜像的受保护预发布冒烟测试引用，以及平台负责人批准引用。全部五项冒烟测试结果都必须是 `passed`。

请将文件捕获到一个全新的、仅限所有者访问的目录中。请勿在该观测记录中放置 kubeconfig 数据、令牌、Secret 对象、原始日志、公开 UGC、Pod 日志或操作人员身份：

```bash
evidence_dir="$(mktemp -d "${TMPDIR:-/tmp}/pakperk-deployment-binding.XXXXXX")"
chmod 0700 "$evidence_dir"
umask 077

kubectl --namespace "$PAKPERK_RELEASE_NAMESPACE" get configmap \
  "$PAKPERK_RELEASE_EVIDENCE_CONFIG_MAP" --output json \
  >"$evidence_dir/release-config-map.json"
kubectl --namespace "$PAKPERK_RELEASE_NAMESPACE" get pods --output json \
  >"$evidence_dir/pods.json"
```

该观测记录是规范的 ASCII JSON，带有一个尾随换行符，且恰好包含以下这些顶层成员：`schema`（`1`）、`environment`、`source_revision`、`captured_at`、`release_namespace`、`release_instance`、`cluster_identity`、`expected_replicas`、`expected_pod_specs`、`controls`、`ingress`、`staging_smoke` 与 `approval`。请使用全部七个副本键（`api`、`paper-worker`、`deletion-worker`、`telemetry-gateway`、`site`、`grobid`、`otel-collector`）；只有在账户删除功能被禁用时，才对删除 worker 使用零值。`expected_pod_specs` 使用相同的七个键，以及经域分隔的 SHA-256（由 `pod-spec-id` 命令针对每一个经评审的、API 默认化的 Pod 规格返回）：

```bash
python3 scripts/deployment_binding_evidence.py pod-spec-id \
  --component api \
  --pod "$evidence_dir/reviewed-api-pod.json"
```

只有已分配的 `nodeName` 会被排除。对于 `otel-collector` DaemonSet，该验证器还会识别并只移除 Kubernetes 确切生成的单节点 `metadata.name In [...]` 亲和性；其他任何亲和性形态都保持绑定，或失败并拒绝，而控制器添加的容忍度则保持绑定。只有当删除 worker 副本数为零时，才能使用空值。请在对这些原始规格进行哈希之前，在受保护的平台边界内，将它们与已渲染的控制器模板及准入策略进行比对评审。随后，该验证器会要求每一个已选中的 Pod 都匹配，因此一个被更改的命令、环境、安全上下文、注入的容器、卷或服务身份，都无法用相同的证据通过。原始规格绝不会进入保留的产物中。

`controls` 必须包含六个 `*_sha256` 键，其由脚本中的 `CONTROL_KEYS` 定义。`ingress` 必须包含 `controller_repository`、`controller_digest`、`configuration_sha256` 与 `review_reference`。`staging_smoke` 绑定相同的来源、后端摘要与 site 摘要，且恰好包含由 `SMOKE_CHECK_KEYS` 定义的五项检查。`approval` 确切为 `{"role":"platform_owner","reference":"sha256:..."}`。请使用一个拒绝重复键的受保护生成方生成规范字节；请勿在事后将一个未经评审的输入规范化。

请先构建经脱敏的产物，然后在保留之前，将其与同一批捕获结果重新核对：

```bash
python3 scripts/deployment_binding_evidence.py build \
  --promotion-handoff protected/promotion-handoff.json \
  --release-config-map "$evidence_dir/release-config-map.json" \
  --pods "$evidence_dir/pods.json" \
  --observation "$evidence_dir/observation.json" \
  --output "$evidence_dir/deployment-binding-evidence.json"

python3 scripts/deployment_binding_evidence.py verify \
  --promotion-handoff protected/promotion-handoff.json \
  --release-config-map "$evidence_dir/release-config-map.json" \
  --pods "$evidence_dir/pods.json" \
  --observation "$evidence_dir/observation.json" \
  --evidence "$evidence_dir/deployment-binding-evidence.json"
```

请将证据文件与一个校验和保留在受保护发布记录中。该产物保留组件计数、发布身份、控制摘要，以及每一个 Pod 集合的摘要；它排除原始的 Kubernetes 对象、命名空间/实例文本、Pod/节点名称、集群凭据以及操作人员身份。其 `release.config_map_sha256` 绑定确切的捕获字节，而 `release.release_binding_sha256` 则独立重新推导出不可变的 Helm 技术契约。一次成功的本地验证并不证明存在集群捕获、预发布冒烟测试、入站评审或平台批准；那些事实仍属于受保护执行与人工门禁。

## 部署前与启用前门禁

1. 冻结修订版本并附加 CI/安全结果。验证每一个 GitHub Action 都固定到一个真实的、经评审的提交，而不仅仅是一个可变标签注释。请运行 `publish-release-images`（源自 `main`），使用经评审的完整提交 SHA 与目标受保护环境。在部署之前，要求两项漏洞扫描、两份镜像 SBOM，以及仅含摘要的 Helm 交接产物均已就绪。
2. 使用 [backup-restore.md](backup-restore.md) 验证备份是否可恢复。将其证据 ID 放入 `migration.confirmBackupId`。
3. 使用 `helm lint` 与 `helm template` 渲染确切的受保护数值；运行 `scripts/validate_helm_release.sh`。将已渲染的主机、身份、授权、镜像、NetworkPolicy、保留期、功能开关与命令，与变更记录进行比对。确认没有任何 worker 轮询间隔达到其租约期限，删除重试基数低于其最大值，台账保留期覆盖安全保留期，每一个终止宽限预算都覆盖其最大请求/租约，且受信任代理列表最多包含 64 个规范范围。验证这四个不含标签、至多 255 字符的 OCI 仓储、独立的小写外部 FQDN、Kubernetes 名称/标签/选择器、请求不超过限制的资源，以及 PDB 数值，均来自受保护的发布清单。仓库中的预发布测试夹具绝不可部署。在暗部署的分阶段发布稳定之后，请构建并验证上文的 `deployment-binding-v1:sha256:` 产物；请勿仅凭一次人工视觉比对，就启用公开流量或功能写入。
4. 确认只有迁移角色能够执行 DDL；应用角色不能。确认 worker、API 与同步角色使用不同的 Secret 密钥。每一个运行时角色，针对共享就绪检查，都必须只具有 `USAGE` 权限（作用于 `public`），外加列级的 `SELECT (version, success, checksum)` 权限（作用于 `public._sqlx_migrations`）；它绝不能具有迁移历史的写入权限。请在迁移之后，针对每一个确切角色测试就绪状态：缺失、失败、过旧、存在缺口或校验和分歧的嵌入式历史记录，都必须失败并拒绝。
5. 在启用删除功能之前，确认删除 worker 仅限 `manage-users` 的服务账户就绪状态、当前独立台账，以及告警覆盖范围。
6. 将经评审的 `deploy/helm/ingress-nginx-production-values.yaml` 应用到固定版本的 TLS 控制器发布。其确切的 HSTS 与 gzip 设置是发布要求，包括 `application/json` 与 256 字节的压缩阈值。请在依赖评论来源限制之前，验证 Nginx 的真实 IP 信任以及 API 观测到的入站来源范围。请勿仅凭 Helm 渲染结果或已配置的主机，就推断公共边缘检查通过；受保护的公共边缘运行，还必须观测到一个完整的、经有界解压的 JSON `/v1/feed?limit=100` 响应，且带有 `Vary: Accept-Encoding`；魔术字节或损坏/截断的 gzip 流都不算通过。

## 队列优先发现功能的分阶段启用

本小节保留了 Plan 02 schema 11 到 18 的启用顺序。它是历史性的前提条件证据，而不是当前的 schema-24 迁移门禁。请在受保护的预发布环境中，针对确切的 Plan 02 候选版本与发布形态拓扑，运行此顺序。每一个可选的队列优先/Plan 02 开关都从 false 开始。请每次只更改一个开关，保留已渲染的前/后数值以及观测到的允许与禁用请求结果，然后在进入下一个独立用例之前，恢复到经评审的基线状态。下文的六开关受保护服务产物本身并不能证明其余的开关。迁移运营清单是独立的全映射技术契约：它必须对账全部 30 个发布开关，并在全部 39 条必需依赖边各自不满足时，拒绝它们。

1. 在启用任何功能开关之前，请从一份经验证的备份完成 schema 11 到 18 的演练。恢复一个隔离的 schema-11 快照，运行经评审的独立迁移 Job 恰好一次到版本 18，证明重放是空操作，运行新旧兼容性与完整性检查，针对 schema 18 执行 schema 兼容的代码回滚，然后再前向。挂载当前的删除台账并完成删除重新应用/收尾。该测试夹具必须包含一行活跃的 To Read、一个已移除的墓碑、保存/移除操作历史，以及不同的已接受时间戳。证明旧版 SQL 仍能读取、写入并重放 `to_read`（在 schema 18 之后），并证明新代码会在同一操作 ID 下拒绝一个已更改的 v2 意图。请勿使用向下迁移。
2. 启用 `PAPER_RESOLUTION_ENABLED`。通过受监控的 arXiv 身份以及共享的数据库门禁/缓存，证明已缓存与未缓存的确切解析均有效，同时现有的公开确切论文路由与匿名 Feed 保持兼容。
3. 独立测试 `PAPER_TITLE_SEARCH_ENABLED` 与 `LIBRARY_IMPORT_WRITES_ENABLED`。搜索需要账户与解析功能。导入需要账户、Library、Library 写入与解析功能。针对每一项，证明关闭/开启/关闭行为、有界的账户与上游限制、缓存行为、重试/降级语义、幂等的导入重放，以及不会创建任何准备作业。两个开关互不启用对方。
4. 启用 `READING_FEED_ENABLED`（同时设置 `TO_READ_FIRST_ENFORCEMENT_ENABLED=false`）。证明 FIFO 活跃队列分页、推荐排除、仅在权威为空时才允许的推荐访问、确切的 `decision.policy_version=queue_first_v1`、单快照的计数/分页一致性、当前修订版本的游标、陈旧与跨账户拒绝、未知策略的失败即关闭处理，以及私有/不存储响应。运行已商定的可用性/延迟观测以及队列优先正确性金丝雀检测。在兼容的已签名客户端上，验证旧版发现功能仍是已渲染的界面，而后台权威控制器只会发出封闭的 `reading_feed_shadow_decision` 比较结果。请将其聚合决策类别与服务端决策指标进行对账，并附加观测窗口；请勿将缺失的移动端遥测视为一个安全的决策。请触发预发布副本的 `reading-feed-authority-unavailable` 规则，并在继续之前证明其自有的分页路由。
5. 启用 `LIBRARY_V2_ENABLED`，然后启用 `RESEARCH_PROFILES_ENABLED`。证明五态的 Library、清单、标签、笔记、显式的资料兴趣、个性化开关/重置/导出，以及它们的幂等性/修订版本围栏。活跃的 Library 状态仍是唯一的队列输入；资料/清单/标签/笔记相关操作绝不能对其执行变更操作或覆盖它。
6. 启用 `SEARCH_LOOKUP_ENABLED`，然后启用 `SEARCH_EXPLORE_ENABLED`，然后启用 `SAVED_QUERIES_ENABLED`。证明确定性的本地元数据查找与建议、有界的显式 Explore/来源诊断、账户所有的已保存查询定义、不存在隐式查询历史，以及规范的 Library/仅导入保存。一个搜索结果绝不会成为自动 Feed 条目。
7. 独立测试 `RECOMMENDATION_EVENTS_ENABLED`，并证明当其可选的、不含内容的数据流不可用时，产品状态保持不变。在启用 `RECOMMENDATIONS_ENABLED` 之前，请证明在该开关关闭时，阅读 Feed 只会持久化/提供最简的、权威绑定的 Recent 回退内容，并仍会重新检查最终的空修订版本。高级模式、感知资料的原因、解释与反馈都必须保持不可用，且仅 Recent 的条目必须报告 `explanation_available=false`。只有在阅读 Feed 的 shadow 权威健康时，才启用 `RECOMMENDATIONS_ENABLED`。证明构建、持久化与提供服务都会重新检查 Library、资料与反馈修订版本；不匹配会使未提供的批次被取代。证明每一个保留的确切/基础 arXiv 反馈身份都被排除，不相关与忽略是硬性排除项，且合格的曝光只会增加一个有界的重复惩罚。在个性化功能已启用的情况下，相关反馈可以创建一个单独标注的 `feedback` 类别偏好；For You 会标注反馈/推断来源，而 Following 只使用显式分组。在 For You 离开 shadow 状态之前，请绑定离线评估语料库/结果摘要、生成器与评分/多样性策略版本、来源覆盖率与主题/作者集中度结果、队列泄漏目标为零，以及可问责的研究/产品/隐私评审。
8. 启用 `READING_BRIEFS_ENABLED`，然后启用 `SUBSCRIPTIONS_ENABLED`，然后启用 `NOTIFICATIONS_ENABLED`。证明活跃/未知队列的延迟处理、简报溯源信息与恢复、周期性调度、静音/静默时段/预算规则、过期/关闭，以及活跃论文的应用内投递。简报进度或完成状态，必须既不能改变、也不能证明队列已清空。推送与邮件仍保持不可用。
9. 在移动端能力仍处于暗发布状态下，发布兼容的已签名客户端，并在物理 iOS 与 Android 上，测试失败即关闭的队列权威性真值表。批准最低支持客户端/采用策略。只有在这些结果、完整的观测窗口以及回滚演练都已附加到该发布之后，才启用 `TO_READ_FIRST_ENFORCEMENT_ENABLED`。

隐私门禁会扫描 API 日志、Collector 输出、外部汇点，以及每一份保留的证据包。它必须发现不存在任何原始搜索查询或标题、已提交的 URL、Bearer 令牌或刷新令牌、账户/论文/批次/事件标识符、游标、私人笔记、资料兴趣、已保存查询/订阅密钥、反馈原因、推荐证据或通知负载。告警标签与证据只保留固定的环境/服务/严重级别/命名空间/消息数值、封闭枚举、分桶、请求 ID 与聚合值；它们绝不使用账户、游标、类别/主题/作者、查询、标题、URL、令牌、论文、批次、事件或 arXiv 身份。

这些步骤仍将保持阻塞状态，直到外部证据绑定了确切的受监控 arXiv 联系方式与实时适配器、多副本共享门/缓存、迁移 Job 与受保护数据库身份、提供商备份/PITR 恢复、当前删除台账重放、预发布与生产环境的告警策略导入与自有接收器；针对资料、搜索、推荐、简报、订阅与通知的保留期清理与队列/修订版本金丝雀检测；已签名的物理客户端；隐私扫描；以及数据库、平台、服务、安全/隐私、移动端与发布批准。仓库测试、测试夹具、本地 Docker Compose、一次 Helm 渲染，以及一个本地告警策略验证器，都只是仓库证据；它们都不能替代那些实际执行。

## 受保护认证、写入与开关演练

请针对确切的暗部署候选版本及其发布形态拓扑，在受保护的预发布环境中运行此门禁。只使用已批准的合成论文、一次性账户，以及有界的非生产配额。身份、服务、数据库、平台与发布负责人批准此次运行；隐私/安全部门还会批准任何已认证的 UGC。请将凭据、Bearer 令牌、原始网络地址、原始评论正文以及提供商密钥材料排除在证据之外。

该封闭证据包必须绑定来源修订版本、已部署镜像 ID、已渲染的发布数值、数据库身份、服务副本拓扑、发布签发方/发现/JWKS 身份、UTC 窗口、断言计数、清理结果，以及批准者。它必须证明以下全部行为：

1. 在已配置的发布签发方上，执行一次经身份负责人批准的签名密钥轮换。只记录新旧 `kid` 数值以及已配置的 `OIDC_JWKS_CACHE_TTL_SECONDS`。接受一个由替换密钥签名的、未过期的访问令牌，并证明在移除之前，那个仍然有效的旧密钥令牌会被立即接受。从 JWKS 中移除旧密钥，等待超过已配置的缓存边界，在探测时记录一个正数的令牌剩余有效期，并证明那个原本仍未过期的相同旧密钥令牌，会被以 HTTP 401 `UNAUTHENTICATED` 拒绝。另外证明一个已过期的令牌会返回 HTTP 401 `TOKEN_EXPIRED`，且受保护的移动端过期路径会执行一次成功的刷新。在一个独立的一次性移动端会话中，使真实的刷新凭据在发布 IdP 处失效，强制进行一次刷新，并绑定 schema-v6 的物理结果，展示访客身份转换、不可访问的账户所有行、不可读的刷新记录、保留的公开缓存与确切的阅读器状态，以及持续的访客阅读。恢复或退役提供商密钥是一项身份负责人操作，且必须在不保留凭据/密钥字节的情况下被记录。发布 IdP 必须签发合成的旧密钥令牌，且其剩余有效期必须足以超过已配置的缓存边界、有界的移除后等待时间，以及探测开销。如果确切的发布签发方/候选版本无法做到这一点，此门禁仍将保持阻塞状态：自然的令牌过期无法证明签名密钥已被移除，因为密钥查找先于声明过期验证发生。
2. 使用逐字节相同的意图、相同的 `Idempotency-Key` 与相同的正文 `operation_id`，将同一个 Library 写操作发送两次；然后使用相同的论文、规范化正文与 `client_request_id`，将同一次评论创建发送两次。要求两次 Library 响应都返回 HTTP 200，且具有相同的规范论文/状态/修订版本，然后要求 HTTP 201，随后重放请求返回 HTTP 200，且具有相同的规范评论 ID/状态/正文摘要。要求恰好一次持久的 Library 操作/副作用，以及一条持久评论。只记录经批准可用作证据的 ID 或摘要、聚合行数、状态与断言结果；绝不记录原始 UGC。
3. 通过受保护的平台归属，识别至少两个同时提供服务的 API 副本。在一个已配置的共享配额/窗口内，将已接受的请求路由经过这两个副本，通过一个副本耗尽所选的安全操作桶，并将下一个请求路由到另一个副本。要求 HTTP 429、确切的 `RATE_LIMITED` 错误代码、一个有效的秒数差值形式的 `Retry-After`，以及在经证明的重置之后成功。请记录该操作、已配置的配额/窗口、按副本划分的聚合计数、共享数据库身份，以及重置结果。将每一个已接受、耗尽、受限与重置的请求，绑定到由经评审的受保护驱动程序针对确切的桶/作用域所产出的同一个 `protected-rate-scope-sha256:` 承诺；它必须与每一个服务副本身份都不同。请勿保留原始 IP、账户标识符或未哈希的数据库作用域键。请使用一个有界的、可重复的操作；
账户删除不符合此条件，因为一次已接受的操作，会使该账户后续的、限定身份范围的重试变为免费，并阻止该账户的普通新操作。HTTP 202 是一次已接受的论文准备请求，在重置之后的成功结果。
4. 从已批准的基线开始，每次只更改一个开关，并针对 `ACCOUNTS_ENABLED`、`LIBRARY_ENABLED`、`LIBRARY_WRITES_ENABLED`、`COMMENTS_ENABLED`、`COMMENT_CREATION_ENABLED` 与 `ACCOUNT_DELETION_ENABLED`，保留已渲染的前/后数值，以及观测到的允许与禁用路径。只测试有效的依赖组合，在各用例之间恢复并验证基线，并针对无效组合保留失败即关闭的验证结果。具体而言，禁用 Library 写入会保留 Library 读取，禁用评论创建会保留评论/安全相关的读取与操作，禁用账户会保留访客阅读功能，且在账户删除被禁用时，不能接受生产账户。

一次仓库测试、一个拥有两个仓库对象的进程、一个无法标识服务副本的负载均衡请求、每次写入都使用全新 UUID，或一个没有对应观测请求结果的已渲染开关，都不满足这一受保护门禁。

请使用手动的 `protected service exercise` 工作流产出规范结果。请从确切的、经评审的 `main` 顶端派发它，附带以下这四项输入：

- `source_revision`：完整的小写经评审提交 SHA；
- `candidate_id`：确切的 `sha256:<digest>` 受保护候选版本 ID；
- `deployment_evidence_id`：该候选版本通过的 `deployment-binding-v1:sha256:<digest>`；以及
- `confirmation`：确切为 `RUN_PROTECTED_SERVICE_EXERCISE`。

`protected-staging-service-exercise` 环境必须使用一个标记为 `pakperk-protected-service-exercise` 的、临时的、根控制的 Linux 运行器，并定义以下这些非密钥受保护变量：

```text
PAKPERK_PROTECTED_SERVICE_RUNNER_SESSION_ID=sha256:<root session-attestation digest>
PAKPERK_PROTECTED_SERVICE_DRIVER_SHA256=<64 lowercase hex>
PAKPERK_PROTECTED_SERVICE_VALIDATOR_SHA256=<64 lowercase hex>
PAKPERK_PROTECTED_SERVICE_WORKFLOW_SHA256=<64 lowercase hex>
```

运行器会话 ID，是一份规范 ASCII JSON 文档（带一个尾随换行符）的原始 SHA-256，存储为 `/opt/pakperk/protected-service-runner-sessions/<digest>.json`。其确切的键为 `schema_version`（`1`）、`classification`（`dedicated ephemeral protected service exercise runner session`）、确切的 `source_revision`、`protected_environment`（`protected-staging-service-exercise`）、`purpose`（`protected_service_exercise`）、`runner_labels`（确切按此顺序为 `Linux`、`pakperk-protected-service-exercise` 与 `self-hosted`）、一个非占位符的 `host_identity_sha256`、确切的布尔值 `dedicated: true` 与 `ephemeral: true`，以及规范的 UTC `issued_at`/`expires_at` 时间戳。该有效期必须为正数且至多八小时，且在验证时，必须至少还剩六小时，以便该证明能够覆盖工作流超时时间。它绝不能包含任何主机名、地址、凭据、操作人员身份或其他个人数据。请只在将那些确切字节放入内容寻址根目录之后，才将 `PAKPERK_PROTECTED_SERVICE_RUNNER_SESSION_ID` 设置为 `sha256:<digest>`。

请将经评审的驱动程序安装为 `/opt/pakperk/bin/pakperk-protected-service-exercise-driver`，并将确切的、经评审的验证器安装为 `/opt/pakperk/bin/pakperk-protected-service-exercise-validator.py`。经由 `/opt/pakperk/bin` 的每一个父目录，以及运行器会话根目录，都必须是一个根拥有的、群组/其他人不可写的目录。这两个工具与会话清单，必须是根拥有的、非群组/其他人可写的单链接常规文件；只有驱动程序是可执行的。请从那些已安装的字节以及已检查的工作流中设置这三个工具摘要，而不是从一个可变路径或此前的运行中设置。候选版本检出是一个仅数据的请求生成方：它绝不能在这一权限驱动程序边界内，安装、引入或执行候选版本代码。根拥有的驱动程序只通过其单独经评审的、根拥有的代理/集成来获取凭据；GitHub 密钥与仓库代码不会跨越那个边界。它必须对每一次尝试的写操作进行分类，并执行无条件清理。

在受保护执行之前，固定版本的根拥有验证器会重新打开会话清单，检查其内容地址、确切的来源/用途/标签/主机绑定、文件安全性，以及实时有效期窗口。该驱动请求绑定确切的 schema 版本、29 个断言 ID、20 个测量 ID、六个开关、六种无效组合，以及仓库经域分隔的请求技术契约摘要。随后，该工作流会创建一个全新的挑战值，在一个空环境中调用驱动程序，通过该验证器再次验证返回的文档，只上传规范的、经脱敏的 JSON，并在会话导入、演练、证据验证或上传任一环节不成功时判定失败。schema-1 结果具有内容 ID `protected-service-exercise-sha256:<digest>`、一个为避免内容/批准哈希循环而单独计算的批准主体、确切的 29 个有序断言、20 项封闭测量、全部六种开关情形、六种无效依赖情形，以及六项可问责的负责人批准。请使用以下方式再次验证保留的字节：

```bash
python3 scripts/protected_service_exercise_evidence.py validate \
  protected/pakperk-protected-service-evidence.json
```

请将规范 JSON 及其字节摘要/内容 ID、工作流运行与尝试次数、不可变产物 ID 与服务器摘要、受保护环境批准日志、运行器会话证明、已安装的驱动程序/验证器/工作流摘要，以及清理记录一并保留。该为期 90 天的 Actions 产物只是一次传输交接，而非不可变的发布总账：请将其内容 ID 与产物坐标锚定在已获批准的受保护证据系统中。通过的仓库验证器或已检查的工作流，仅是 **R** 证据；在这次确切的运行成功之前，实时的签发方、副本、数据库、开关、产物与批准仍然只是 **P/H**。

## 扩展/收缩式部署

1. 对于本次扩展发布，请使用仅新增式、可为空的表、列、索引，以及双兼容代码。切勿将破坏性收缩与首次停止使用某字段的代码上线合并在一起。所保留的 schema-18 Plan 02 兼容性规则依然适用：逻辑上的 Inbox 在物理上是 `to_read`，v0 的 `intent_fingerprint` 保持不变，而全新的写操作意图则使用另一个独立的、可为空的 v2 指纹。在此兼容性窗口内，任何物理上的 `inbox` 行都应被视为对不变量的违反。新读者可以出于防御性目的对其进行解码，但生产环境写入方不得创建这种行。迁移 19 到 24 仅新增准备审计、规范化的文档/Passport/来源信息、私人研究、版本差异，以及注释归档导入边界；其中任何一项都不得成为第二个 Library 或阅读订阅源的权威来源。
2. 请只运行一次该 chart 迁移 Job，使用经评审的镜像摘要、独立的迁移数据库角色、在其他所有位置均设为 `RUN_MIGRATIONS=false`、预期的内嵌迁移版本 `24`，以及一个有界的、非占位符的备份证据 ID。计划中的元数据清单必须是有效的 JSON，其中须包含从 1 到 2,000 个规范的 arXiv ID，这些 ID 位于该 chart 的 1,048,000 字节 ConfigMap 边界之内，且其有界的五字段 Cron 表达式必须能够成功渲染。请在不泄露任何密钥的情况下保存 Job 的日志/状态。失败或超时的迁移将阻止上线。
3. 请先上线 deletion worker 并验证其就绪状态，然后依次上线论文 worker、元数据同步、遥测 gateway/Collector、API 与网站。在账号相关功能（包括删除）、Library 写操作，以及评论创建各自的依赖项和冒烟检查全部通过之前，请将它们保持为 dark（隐藏）状态。生产环境中的账号启用要求同时启用删除功能。
4. 请针对这一确切的 dark 部署目标，派发 `public edge verification`，并将其通过的产物附加到发布总账中。缺失/失败的产物、来源标记不匹配，或任何重定向/请求头/配置/文档/关联/就绪状态方面的不匹配，都会阻止功能启用与应用商店提交。
5. 请先执行访客缓存阅读，然后依次执行已认证的个人资料/Library、评论/举报/屏蔽/内容审核、删除请求/状态/网络回调、论文准备、默认关闭的 Deep Reader 路由注册、私人研究导出/删除、遥测脱敏/导出，以及关联链接。请针对同一候选版本，完成[受保护的身份验证、写操作与开关演练](#protected-auth-write-and-switch-exercise)。仅捕获每份证据契约所定义的、有界且经脱敏的结果。
6. 请将全部 30 项开关结果，与最终渲染出的功能地图，以及迁移清单中确切的 39 条边的依赖契约进行核对。受保护服务产物仅提供其中六个历史遗留的现场用例；独立执行的队列优先发现序列与 Plan 03 上线包，则提供其余用例。不要仅凭健康的基线冒烟检查就推断某项开关已通过，也不要在任何相关的镜像、签发方、配额、拓扑或功能地图发生变化之后，复用此前的证据。账号删除功能仍然
只要生产环境账号被启用，该功能就随之启用，包括在禁用评论的 Library 发布版本中。
7. 请在整个发布观察窗口内，持续观察错误率、就绪状态、数据库饱和度、队列/积压年龄、阅读订阅源的可用性/延迟以及队列权威性的『失败即关闭』告警、解析器/准备/Passport/assistant/visual/version-diff 结果、移动端阅读器/缓存/注释/内存信号、内容审核 SLA、删除失败、OTLP 丢弃，以及 ingress 错误。请记录确切的窗口与批准人。源头监测手段不能替代受保护的实时遥测、人工、法务、已签名设备、无障碍，或发布批准这些关卡。

收缩操作只有在每个 serving/worker 版本都已兼容、兼容性窗口与回滚保留期均已过去，且存在另一个已验证的备份之后，才可以作为单独的一次发布。请在预发环境中演练迁移与回滚流程；仅渲染出命令并不能证明其已被执行。

## 回滚

请优先选择正向代码回滚，回退到最近一个与 schema 兼容的镜像，并配合功能性的紧急关闭开关。请勿运行破坏性的降级迁移。如果新 schema 向后兼容，请回滚 API/site/workers，并保留已扩展的 schema。如果出现数据损坏，或迁移不兼容而需要恢复，请宣布事件、隔离写入操作，遵循 [backup-restore.md](backup-restore.md) 中记录的备份恢复步骤，挂载当前的删除总账，并在恢复流量之前重新执行删除操作。

对于队列优先发现，请先关闭 `TO_READ_FIRST_ENFORCEMENT_ENABLED`。请先关闭 `NOTIFICATIONS_ENABLED`，再关闭 `SUBSCRIPTIONS_ENABLED`；先关闭 `READING_BRIEFS_ENABLED`、`RECOMMENDATIONS_ENABLED`、订阅功能与强制执行，再关闭 `READING_FEED_ENABLED`。请先关闭 `SAVED_QUERIES_ENABLED`，再关闭 `SEARCH_EXPLORE_ENABLED`；先关闭 Explore，再关闭 `SEARCH_LOOKUP_ENABLED`。请独立地先关闭 `PAPER_TITLE_SEARCH_ENABLED` 与 `LIBRARY_IMPORT_WRITES_ENABLED`，再关闭 `PAPER_RESOLUTION_ENABLED`。Library v2 与研究者个人资料功能，可以在其各自的消费方均已变为 dark 之后独立关闭；可选的推荐事件流可以在任何时候关闭，因为产品状态不依赖于它。请在事件允许的范围内，保留普通的 Library 读写操作与账号删除功能。

对于 Plan 03，请按照 [Deep Reader 上线](deep-reader-rollout.md#rollback) 中记录的相反顺序，依次关闭这些开关：Docling 实验、版本差异、内存、注释、助手 v2、视觉对象、语义分面、Passport，最后是 Deep Reader。请保留可读的 source/legacy Introduction 访问权限，以及私有数据。请保留新增式 schema 24 不变，并使用与 schema-24 兼容的镜像；切勿恢复到 schema 18，仅仅是为了禁用某个 Plan 03 能力。以往的 Plan 02 规则同样从未允许从 schema 18 降级到 schema 11。请在每个适用的回滚步骤之后，验证匿名 `GET /v1/feed`、现有的精确论文路由、Library 读取操作，以及显式搜索导航。

schema-18 Plan 02 的历史规则，仅允许使用经过验证的 v0.0 镜像，且仅限于任何 Library v2 写操作发生之前。它并非当前 schema-24 的回滚目标。一旦可能已存在 Plan 03 写操作，就应使用最新的扩展兼容镜像——它能够识别这五种 Library 状态，并安全地忽略或读取新增式 Plan 03 表——同时关闭它们的消费方，并将 schema 24 保留在原位。

切勿仅恢复 PostgreSQL，却把删除义务抛在一边。应用商店操作绝不会让已安装的移动端二进制包降级：请提升构建版本号，并发布一个已修正的候选版本。下文所述的、单独获批的 Android 专属全量发布暂停，是面向新用户/符合条件用户的分发兜底方案，而不是已安装二进制包的回滚。

## 已签名的移动端/应用商店交接

请运行手动的 `signed-mobile-release` 工作流。其签名与上传作业均受环境门控限制，而准备、组装、引导与收尾阶段则保持无凭据。它会验证 flavor 配置、签名/描述文件身份、AAB/APK/IPA 元数据、权限/关联链接、严格打包资源、符号表、声明文件、SBOM，以及证据哈希。无凭据的准备阶段会在候选版本执行之前，发布不可变的配置绑定；随后，独立的全新 Android 与 iOS 签名方会重新推导该绑定，并各自仅获得自己的签名家族。无凭据的组装器会创建合并后的候选版本/来源记录；无凭据的引导阶段会打包冻结的应用商店客户端与按字面值哈希的控制项；全新的、无需检出代码的各平台上传作业，各自仅获得自己的应用商店凭据；而始终运行的无凭据收尾阶段，则会保留两种请求结果。该工作流被固定使用 macOS 26 runner 技术契约、Xcode 26.6 build 17F113、Flutter 3.44.8 framework revision `058e0af2c2b57e369d905a03ac9748b0ebf543c6`，并配合 Dart 3.12.2、Temurin 17.0.19+10（来自 `JAVA_HOME_17_arm64`）、MRI Ruby 3.4.10、RubyGems 4.0.17，以及一份使用 RubyGems 校验和的、冻结的 Bundler 2.6.9/Fastlane 2.235.0 依赖图。在执行任何 gem 安装或 Bundler 操作之前，都会先验证并记录 Ruby 引擎与确切的运行时。Bundler 本身会按确切版本下载、经 SHA-256 校验，并在本地安装；只要缺少任何一项确切的工具链，就会导致该候选版本失败。请使用经评审的完整提交 SHA，从 `main` 分发；该工作流会拒绝精确检出不匹配，或 `origin/main` 祖先不匹配的情况，并且所保留的已签名发布源代码，必须与其记录的工作流修订版本完全一致。Android 上传密钥摘要用于证明候选版本的保管链；关联文件则使用另一个独立的、受保护的 Play App Signing 摘要。请参阅 [mobile-release.md](../mobile-release.md)。

公开发布推广是第二次受保护交接。一个无凭据的引导阶段会检出代码，并将受信任的工具链绑定到经评审的 `github.workflow_sha`（该操作与仅含数据的不可变候选版本源代码分开进行），随后打包一个不可变的应用商店客户端/控制闭包。全新的各平台写操作作业不会执行检出，而是先对照工作流字面值 SHA-256 校验每一个可执行文件，然后才具体化仅属于该平台的凭据；候选版本自身携带的工具链，绝不会获得应用商店凭据。在处理候选版本产物或凭据之前，该引导阶段必须通过 GitHub Actions API，将所提供的运行验证为确切成功、已完成的 `workflow_dispatch`（属于 `.github/workflows/mobile-release.yml`，来自 `main`），且其来源 SHA、运行尝试次数与仓库均一致，并具备确切的全成功八项作业面：无凭据准备、独立的 Android 与 iOS 签名方、`production
signed candidate`、无凭据的应用商店客户端引导、独立的 Android 与 iOS 上传，以及无凭据的已签名发布收尾阶段。它只接受那些唯一、未过期、与本次尝试绑定的候选版本、交接，以及最终已签名发布结果产物，记录它们各自不同的服务器 ID/摘要，并按不可变产物 ID 进行下载。只有在其评审人员取回确切的生产环境已签名发布产物，并核对其规范候选版本与来源记录 ID、运行 ID/尝试次数、版本/构建号、已签名发布工作流修订版本，以及应用商店后台记录之后，才可以派发 `protected-mobile-store-rollout`。分阶段的 Play 更新，同样需要一个确切的、符合条件的、此前已完成的生产环境回退方案。一次 iOS `start` 操作，需要当前处于 `appVersionState` `READY_FOR_DISTRIBUTION` 状态下的确切此前公开版本、处于已评审的提交前状态的确切目标，以及提交之后处于确切 `INACTIVE` 状态的分阶段资源；缺少该此前记录将拒绝首次发布。请为每个已选定的平台，保留经评审的应用商店提交前/提交后状态，以及一个无条件的结果（包括失败或未运行的操作），然后该作业才会报告最终失败；部分成功的情况，必须在重试之前完成协调。

请勿将分阶段证据用于首个公开应用商店版本。请针对 100% 首次 Play 发布，以及 App Store 首个版本提交，遵循各自独立的移动端流程：包括所选定的手动发布设置、确切的 `Pending Developer Release`/发布或暂缓发布的提交前/提交后状态、UTC 操作时间、后台审计记录，以及应用商店所有者批准。如果只有一个平台属于更新，请将受保护的分阶段工作流限定于该平台，并单独保留另一个平台的首次发布记录。

对于更新，请将 Play 从百分之一开始；Apple 的分阶段百分比计划会自动推进。请将每一次推进，都以确切构建版本的崩溃/性能观察窗口与发布批准作为门槛，然后将每一个内容寻址的结果，与各应用商店各自独立的审计记录进行核对。在 Pakperk 自动化流程中，提交前中止对该候选版本而言是终局性的。Apple 的暂停仅影响自动更新，并不会阻止手动的 App Store 下载，因此请在适用之处禁用有害的服务器写操作、披露该残留风险、保留事件/变更记录、提升构建版本号，并向前修复。在 Play 达到 100% 之后，一个单独获批的、Android 专属的全量发布暂停，可以为新用户/符合条件用户恢复到此前符合条件的确切发布版本；但它不会让已安装用户降级，也没有对应的 Apple 机制，并且在首个 Play 生产发布中不可用。请参阅[受保护的分阶段上线流程](../mobile-release.md#protected-staged-store-rollout)。

应用商店所有者必须提供一个一次性的评审人员账号，该账号具备已验证的电子邮箱、没有公开的用户名/账号名、没有当前有效的 Terms 或 Community Guidelines 接受记录、没有真实用户数据、没有任何特权角色，并配有一位负责轮换/到期的负责人，以便该确切候选版本能够完整走完引导流程。评审说明需描述访客阅读、登录、举报/屏蔽、账号删除、网页删除 URL、严格的元数据/全文行为，以及任何仅限预发环境的坐标信息。凭据只保存在各应用商店后台中，绝不放入 Git/issue 系统。请从经过脱敏处理的[应用商店评审说明模板](../store/reviewer-notes-template.md)开始，并让每一个方括号中的证据字段，在该确切候选版本通过验证之前都保持阻止发布状态。请遵循其有界的生命周期：创建、走查、删除、验证应用/提供方是否已彻底移除、轮换凭据，并只保留经过脱敏的哈希值、时间戳、证据引用，以及负责人批准记录。

生产环境已签名发布上传，会在每一次 Play/TestFlight 二进制发送之前，写入一份仅所有者可访问、且已 fsync 落盘的尝试日志，并保留一个无条件的 `mobile-store-upload-attempt-<run-id>-<attempt>` 产物。Play 回读必须将确切的服务器端软件包 SHA-256 绑定到候选版本 AAB；Apple 回读必须将确切的应用、构建版本与预发布版本资源 ID、iOS 平台，以及已完成的 BuildUpload 关联关系绑定在一起。其唯一的 IPA 资源必须是一个已完成的 `ASSET`/`com.apple.ipa` 文件，其 SHA-256 与字节大小必须与候选版本及发送前日志一致；请将 BuildUpload ID 与资源 BuildUploadFile ID 保留在不可变交接记录中。如果存在日志，但缺少该权威回读结果，请将此次上传标记为 `unknown_reconcile_required`，并在重试之前对后台记录进行协调。

TestFlight/封闭式 Play 上传、受保护的更新上线或单独获批的首次发布执行与应用商店侧审计协调、物理设备深链接/回调/删除、当前的 Data Safety/App Privacy/年龄分级表单、评审状态、经测量的启动/缓存目标，以及具有代表性的无崩溃观察窗口，均属于外部关卡。请为每一项都标注证据，否则就应将该发布保持在阻塞状态。

对于 `protected-mobile-store-rollout`，请记录由成功的生产环境已签名发布所生成的不可变 `store-handoff-v1:sha256:<digest>`。请勿从一次遗漏了应用商店上传，或缺少单独已验证交接产物的运行中进行派发。标记为 `unknown_reconcile_required` 的已保留尝试日志，意味着该请求可能已经到达应用商店；请检查确切的 Play/App Store 资源，并在重试之前解决该发布总账的问题。在 `both` 转换中，除非 Android 结果与日志关卡已经是 `succeeded_verified`，否则不得允许 Apple 请求。该工作流将其实现为一个无凭据的引导阶段、各自仅使用其对应密钥家族的独立 Android 与 iOS 作业，以及一个无凭据的 `always()` 收尾阶段。iOS 作业必须下载并验证不可变的 Android 结果，适用场景为 `both`；每个已选定的平台，都会在完成无条件的密钥清理（包括失败情形下）之后，上传各自的结果 ID 与服务器摘要。请保留最终的 schema-v4 汇总结果，它绑定了已签名的运行、候选版本/来源记录/交接、来源、版本/构建号、转换，以及确切的成功/未选定/依赖跳过语义。请将上传操作的原始 64 位十六进制产物摘要，规范化为 `sha256:<hex>`，然后再进行比较或记录。
