import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

export const TRANSLATION_POLICY_VERSION = "zh-CN-professional-v4";

export const PRESERVED_TECHNICAL_NAMES = Object.freeze([
  "Pakperk", "arXiv", "Rust", "Flutter", "Dart", "Axum", "Drift", "SQLite",
  "PostgreSQL", "OIDC", "OAuth", "PKCE", "JWT", "JWKS", "Keycloak", "AppAuth",
  "Android", "iOS", "iPhone", "Xcode", "Gradle", "Kubernetes", "Helm",
  "OpenTelemetry", "OTLP", "GROBID", "GitHub Actions", "TestFlight", "Google Play",
  "App Store Connect", "Fastlane", "Mailpit", "Riverpod", "SharedPreferences",
  "DevTools", "WidgetTester", "Keychain", "APK", "AAB", "IPA", "Android App Links",
  "Universal Links", "Pod", "CronJob", "DaemonSet", "Ingress", "NetworkPolicy",
  "ServiceAccount", "ConfigMap", "PersistentVolumeClaim", "Helm Chart", "Dart Zone",
  "WAL", "SQLCipher",
]);

export const PAKPERK_UI_LABELS = Object.freeze([
  "Read", "You", "To Read", "Abstract", "Introduction", "Connections", "Deep Reader",
  "Search", "Lookup", "Explore", "Passport", "Library",
]);

export const PRESERVED_EXACT_UI_LABELS = Object.freeze([
  "Library", "To Read", "Deep Reader", "Passport",
]);

export const MODEL_PROTECTED_TECHNICAL_LITERALS = Object.freeze([
  "outbox",
]);

export const MODEL_PROTECTED_LITERALS = Object.freeze([
  ...PRESERVED_TECHNICAL_NAMES,
  ...PRESERVED_EXACT_UI_LABELS,
  ...MODEL_PROTECTED_TECHNICAL_LITERALS,
]);

const driftLocalDatabasePathPattern = /(?:^|\/)adr\/0002-drift-local-database\.md$/u;
const statefulShellRoutingPathPattern = /(?:^|\/)adr\/0003-stateful-shell-routing\.md$/u;

export function exactUiLabelsFor(relativePath = "") {
  const labels = [...PRESERVED_EXACT_UI_LABELS];
  const normalizedPath = normalizeRelativePath(relativePath);
  if (driftLocalDatabasePathPattern.test(normalizedPath) || statefulShellRoutingPathPattern.test(normalizedPath)) {
    labels.push("Introduction", "Connections");
  }
  if (statefulShellRoutingPathPattern.test(normalizedPath)) {
    labels.push("Read", "You", "Abstract");
  }
  return labels;
}

export function modelProtectedLiteralsFor(relativePath = "") {
  return [...new Set([...MODEL_PROTECTED_LITERALS, ...exactUiLabelsFor(relativePath)])];
}

const pakperkLibrarySourcePattern = /\b(?:Library|To Read library|(?<!Rust )(?<![Ss]oftware )(?<![Pp]hysical )(?<![Ss]tandard )(?<![Cc]lient )(?<![Ss]tatic )(?<![Dd]ynamic )(?<![Ss]hared )library (?:routes?|items?|sync|writes?|states?|revisions?|projections?|operations?|rows?|pages?|gates?))\b/u;
const historicalYouLibraryRoutesSourcePattern = /\baccount and then-current library routes belonged under You\b/u;
const olderRestoredYouSessionSourcePattern = /\ban older restored You session\b/u;
const operationalAlertSourcePattern = /\b(?:(?:operational|production|staging|monitoring|observability|telemetry|service|system|security|privacy|queue|failure|error|latency|invariant|deletion|moderation|release|deployment|ledger|collector|slo|live|owned|external|release-blocking) alerts?|alerts?(?=[^.!?;\n]{0,64}\b(?:adapter|policy|route|routing|receiver|threshold|delivery|engine|evaluation|dependency|integration|canary|metrics?|paging|tickets?|evidence|public disclosures|staffing|coverage)\b)|(?:restore|backup|incident|queue|telemetry|retention|provider|ledger|platform|canary|slo)[^.!?;\n]{0,48}\balerts?)\b/iu;
const publicUserHandleSourcePattern = /\b(?:(?:public|profile|account|user|review(?: fixture)?|one-time|immutable) handles?|handles? (?:availability|claim|selection|field|value|uniqueness|conflict)|(?:choose|claim|change|enter) (?:an? |the |one-time )?handles?|saving does not require (?:an? |the )?handles?)\b/iu;
const identitySubjectSourcePattern = /\b(?:(?:OIDC|provider|token|identity) subjects?|subjects? identifiers?|(?:OIDC|provider|token|identity)\b[^.!?;]{0,240}\brequired subjects?|required subjects?\b[^.!?;]{0,240}\b(?:OIDC|provider|token|identity))\b/iu;
const checkedInRepositorySourcePattern = /\bchecked-in(?=[^.!?;\n]{0,64}\b(?:artifacts?|fixtures?|configs?|configurations?|files?|code|values?|realms?|licenses?|regressions?|profiles?|versions?|builds?|examples?|approvals?|contracts?|orchestration|validators?|flags?|gates?|feeds?|papers?|targets?|inventories?|guides?|workflows?|YAML|declarations?|hosts?)\b)/iu;
const failClosedSourcePattern = /\bfail(?:s|ed|ing)?(?:\s+[\w-]+){0,4}\s+closed\b/iu;
const explicitFailClosedTargetPattern = /(?:(?:在)?(?:失败|故障)时[，,\t ]*(?:(?:默认|明确)(?:地)?[\t ]*)?拒绝|(?:失败|故障)(?:时)?(?:即|则)拒绝|(?:失败|故障)并拒绝)/u;
const unavailableFailClosedTargetPattern = /不可用时(?:(?!可能|或许|也许|有时|视情况|不一定|未必)[^。；]){0,24}拒绝/u;
const schemaMigrationSourcePattern = /\bschema migrations?\b/iu;
const schemaVersionSourcePattern = /\bschema version\b/iu;
const schemaContainsSourcePattern = /\b(?:the )?schema contains\b/iu;
const schemaPersistsBehaviorSourcePattern = /\b(?:the )?schemas?\s+persist(?:s|ed|ing)?\b/iu;
const completeHistoricalSchemaFixturesSourcePattern = /\bmigrations are explicit and tested from complete historical schema fixtures through version \d+\b/iu;
const technicalOutboxSourcePattern = /(?<!mailbox )(?<!mailbox's )(?<!mailbox’s )(?<!email )(?<!email's )(?<!email’s )(?<!e-mail )(?<!e-mail's )(?<!e-mail’s )(?<!mail client )(?<!mail client's )(?<!mail client’s )\boutbox\b/iu;
const authorizationHeaderSourcePattern = /\bauthorization headers?\b/iu;
const oidcNotBeforeSourcePattern = /\bnot[- ]before(?:\s+(?:time|claim|validation))?\b/iu;
const bruteForceProtectionSourcePattern = /\bbrute[- ]force protection\b/iu;
const physicalIPhoneSourcePattern = /(?:\bphysical iPhone(?:s| (?:phones?|devices?))?\b|\bphysical (?:Android )?phones? (?:or|and) iPhones?\b)/iu;
const flutterBuildFlavorSourcePattern = /(?:\b(?:build|dev|staging)[- ]flavors?\b|\b(?:Flutter|Android|iOS|iPhone|app|application|build|bundle|configuration|probe|run|uses?|using)[^.!?;\n]{0,48}\bproduction[- ]flavors?\b|\bproduction[- ]flavors?\b(?=[^.!?;\n]{0,48}\b(?:app|application|backend|build|bundle|configuration|Flutter|Android|iOS|iPhone|probe|release|signing)\b))/iu;
const profileBuildSourcePattern = /(?:\b(?:the|an?|this|that|each|Android|iOS|Flutter|mobile) profile builds?\b|\bprofile builds?\b(?=[^.!?;\n]{0,32}\b(?:uses?|requires?|runs?|is|are|artifacts?|configuration|signing|bundle|mode)\b))/iu;
const releaseBuildSourcePattern = /(?:\b(?:the|an?|this|that|each|named|signed|mobile|Android|iOS|Flutter) release builds?\b|\brelease builds?\b(?=[^.!?;\n]{0,32}\b(?:uses?|requires?|runs?|is|are|artifacts?|candidate|configuration|signing|bundle|version)\b))/iu;

const sharedTerminology = [
  term("guest", /\bguests?\b/iu, /访客/u, "guest", "访客", "Guest access remains available.", "访客访问仍然可用。"),
  term("physical-android-phone", /\bphysical Android phones?\b/iu, /Android\s*(?:真机|实体(?:设备|手机)|物理(?:设备|手机))|(?:实体|物理)\s*Android\s*(?:设备|手机)/u, "physical Android phone", "Android 真机/实体 Android 手机/物理 Android 手机", "Test on a physical Android phone.", "在 Android 实体手机上测试。"),
  term("physical-iphone", physicalIPhoneSourcePattern, /(?:iPhone\s*(?:真机|实体(?:设备|手机)?|物理(?:设备|手机)?)|(?:实体|物理)\s*iPhone)/u, "physical iPhone", "iPhone 真机/实体 iPhone/物理 iPhone", "Test on a physical iPhone.", "在实体 iPhone 上测试。"),
  term("physical-phone", /\bphysical phones?\b/iu, /真机|实体(?:手机|设备)|物理(?:手机|设备)/u, "physical phone", "真机/实体手机/物理手机", "Test on a physical phone.", "在实体手机上测试。"),
  term("paper", /\b(?:(?:arXiv|saved|public|research|reading|recommended|imported|cached|seed|synthetic) papers?|papers? (?:record|metadata|route|content|data|ID|identifier|feed|reader|worker|version|title|abstract|preparation|cache|library))\b/iu, /论文/u, "research paper", "论文", "The arXiv paper remains available.", "该 arXiv 论文仍然可用。"),
  term("feed", /\b(?:(?:reading|paper|recommendation|guest|Read) feeds?|feeds? (?:endpoint|page|item|cache|repository|route|response))\b/iu, /Feed|论文流|信息流/u, "reading/paper feed", "Feed（论文流）/信息流", "The reading feed remains available.", "阅读 Feed 仍然可用。"),
  term("library", pakperkLibrarySourcePattern, /Library|个人论文库|论文库/u, "Pakperk Library", "Library（个人论文库）", "The Library remains available.", "Library（个人论文库）仍然可用。"),
  term("durable-sync-outbox", /\bdurable sync outbox\b/iu, /^(?=[\s\S]*持久(?:化)?)(?=[\s\S]*待同步队列)/u, "durable sync outbox", "持久/持久化 + 待同步队列（outbox）", "Use a durable sync outbox.", "使用持久化待同步队列（outbox）。"),
  term("outbox", technicalOutboxSourcePattern, /待同步队列/u, "outbox", "待同步队列（outbox）", "Drain the outbox safely.", "安全排空待同步队列（outbox）。"),
  term("route", /\broutes?\b/iu, /路由/u, "route", "路由", "Validate the route.", "验证该路由。"),
  term("endpoint", /\bendpoints?\b/iu, /端点/u, "endpoint", "端点", "Call the endpoint.", "调用该端点。"),
  term("origin", /\b(?:(?:CORS|request|allowed|configured|web|HTTPS?) origins?|origins? (?:allowlist|header|policy|check|validation))\b/iu, /(?:CORS\s*)?源|来源/u, "network/CORS origin", "源/来源；CORS origin=CORS 源", "Allow the CORS origin.", "允许该 CORS 源。"),
  term("source-of-truth", /\bsource of truth\b/iu, /权威数据源|唯一可信数据源|权威来源|事实来源/u, "source of truth", "权威数据源/唯一可信数据源/权威来源", "PostgreSQL is the source of truth.", "PostgreSQL 是唯一可信数据源。"),
  term("profile-contract", /\bprofile contracts?\b/iu, /(?:用户|账户|个人)资料(?:技术)?契约|(?:用户|账户|个人)资料规范/u, "profile contract", "用户资料技术契约/用户资料契约", "Preserve the profile contract.", "保留用户资料契约。"),
  term("contract", /\b(?:(?:API|wire|repository|product|support|interface|schema|service|response|request|synchronization|export|deployment|release|mobile|backend) contracts?|contracts? (?:test|result|surface|boundary)|contract (?:requires|defines|binds|exposes|accepts|preserves))\b/iu, /技术契约|接口契约|规范/u, "technical contract", "技术契约/接口契约/规范", "Preserve the API contract.", "保留 API 技术契约。"),
  term("response-envelope", /\bresponse envelopes?\b/iu, /响应封装|响应包络/u, "response envelope", "响应封装/响应包络", "Validate the response envelope.", "验证响应包络。"),
  term("delta-seconds", /(?<![\p{L}\p{N}-])delta(?:-| )seconds(?![\p{L}\p{N}-])/u, /秒数差值|以秒为单位的差值/u, "delta-seconds", "秒数差值/以秒为单位的差值", "Return a delta-seconds Retry-After value.", "返回以秒为单位的差值作为 Retry-After 值。"),
  term("mutation", /\b(?:(?:API|library|comment|account|profile|write) mutations?|mutations? (?:request|intent|route|operation|race|limit))\b/iu, /写操作|变更操作|修改操作/u, "software mutation", "写操作/变更操作/修改操作", "Retry the library mutation.", "重试该写操作。"),
  term("moderation", /\bmoderation\b/iu, /内容审核/u, "moderation", "内容审核", "Moderation remains available.", "内容审核仍然可用。"),
  term("moderator", /\bmoderators?\b/iu, /审核员/u, "moderator", "审核员", "Notify the moderator.", "通知审核员。"),
  term("abuse-report", /\b(?:(?:abuse|user|comment|moderation) reports?|reports? (?:of abuse|against (?:a )?user))\b/iu, /举报/u, "moderation/user report", "举报", "Inspect the user report.", "检查该用户举报。"),
  term("block", /\b(?:(?:block|blocked|blocking) (?:an? |another |the )?(?:abusive )?(?:user|author|account)|(?:user|author|account)(?:[- ]level)? blocks?|(?:report|add|create|remove|persist|explicit) (?:a )?block)\b/iu, /屏蔽|拉黑/u, "user/account block", "屏蔽/拉黑", "Block the abusive user.", "屏蔽该违规用户。"),
  term("unblock", /\b(?:unblock(?:ed|ing|s)? (?:an? |another |the )?(?:user|author|account)|(?:user|author|account) unblocks?)\b/iu, /取消屏蔽|解除屏蔽|取消拉黑/u, "unblock a user/account", "取消屏蔽/解除屏蔽/取消拉黑", "Unblock the user.", "解除屏蔽该用户。"),
  term("feature-flag", /\bfeature flags?\b/iu, /功能开关/u, "feature flag", "功能开关", "Disable the feature flag.", "关闭该功能开关。"),
  term("feature-gate", /\bfeature gates?\b/iu, /功能开关/u, "feature gate", "功能开关", "Disable the feature gate.", "关闭该功能开关。"),
  term("kill-switch", /\bkill switch(?:es)?\b/iu, /紧急关闭开关/u, "kill switch", "紧急关闭开关", "Test the kill switch.", "测试该紧急关闭开关。"),
  term("fail-closed", failClosedSourcePattern, explicitFailClosedTargetPattern, "fail ... closed", "在失败/故障时拒绝（可用默认/明确修饰）、失败/故障即（则）拒绝、失败并拒绝；源文明确 unavailable 时也可译为不可用时明确拒绝", "The gate must fail these actions closed.", "该门禁必须在失败时默认拒绝这些操作。", [
    { sourcePattern: /\bunavailable\b/iu, targetPattern: unavailableFailClosedTargetPattern },
  ]),
  term("rate-limiting", /\brate limit(?:ing|s|ed)?\b/iu, /限流/u, "rate limiting", "限流", "Rate limiting remains enabled.", "限流保持启用。"),
  term("idempotent", /\bidempoten(?:t|cy)\b/iu, /幂等/u, "idempotent", "幂等", "The request is idempotent.", "该请求是幂等的。"),
  term("replay", /\breplays?(?:ed|ing)?\b/iu, /重放/u, "replay", "重放", "Reject the replay.", "拒绝该重放。"),
  term("worker", /\b(?:(?:paper|deletion|background|job|queue|metadata|preparation|document|recommendation|assistant|Passport|dedicated) workers?|workers? (?:process|pipeline|deployment|downloads?|checks?|leases?|runs?|retries?|writes?|stores?|coordinates?))\b/iu, /worker|工作进程|工作线程|后台进程|后台任务/iu, "background worker", "worker/工作进程/工作线程/后台任务", "Restart the paper worker.", "重启论文工作进程。"),
  term("runbook", /\brunbooks?\b/iu, /操作手册|运行手册/u, "runbook", "操作手册/运行手册（英文注释可选）", "Follow the runbook.", "遵循操作手册。"),
  term("readiness", /\breadiness\b/iu, /就绪/u, "readiness", "就绪状态", "Check readiness.", "检查就绪状态。"),
  term("liveness", /\bliveness\b/iu, /存活/u, "liveness", "存活状态", "Check liveness.", "检查存活状态。"),
  term("telemetry", /\btelemetry\b/iu, /遥测/u, "telemetry", "遥测", "Review telemetry.", "检查遥测。"),
  term("operator", /\b(?:(?:on-call|deployment|release|platform|database|moderation|qualified|designated) operators?|operators? (?:reviews?|records?|runs?|approves?|controls?|owns?|invokes?|workstation|checklist))\b/iu, /运维人员|操作人员|值班人员/u, "human operator", "运维人员/操作人员/值班人员", "Notify the on-call operator.", "通知值班人员。"),
  term("alert", operationalAlertSourcePattern, /告警/u, "operational alert", "告警", "Resolve the operational alert.", "处理该运维告警。"),
  term("ticket", /\b(?:(?:support|incident|change|alert|operations?) tickets?|(?:open|create|close|resolve|route|page) (?:a )?tickets?)\b/iu, /工单/u, "support/incident ticket", "工单", "Open a support ticket.", "创建支持工单。"),
  term("gate", /\b(?:(?:release|promotion|verification|acceptance|quality|deployment|production|protected) gates?|gates? (?:passes?|fails?|blocks?|requires?|evidence))\b/iu, /门禁|准入条件|检查关卡/u, "release/verification gate", "门禁/准入条件/检查关卡", "Pass the release gate.", "通过发布门禁。"),
  term("checked-in", checkedInRepositorySourcePattern, /已提交到代码仓库的|已纳入版本控制的|随代码仓库提供的|已检入代码仓库的|代码仓库中已检入的/u, "checked-in repository fixture/config/file/code", "已纳入版本控制的/已提交到代码仓库的/随代码仓库提供的/已检入代码仓库的", "Use the checked-in fixture.", "使用已纳入版本控制的测试夹具。"),
  term("owner-only", /\bowner[- ]only\b/iu, /仅(?:限)?所有者|只有所有者|所有者专用/u, "owner-only", "仅限所有者/只有所有者可访问", "Create an owner-only file.", "创建仅限所有者访问的文件。"),
  term("exact", /\bexact(?:ly)?\b/iu, /指定|完全一致|完全相同|精确|确切|原样|恰好/u, "exact", "指定的/完全一致的/确切的（按上下文）", "Verify the exact candidate.", "验证完全一致的候选版本。"),
  term("allowlist", /\ballow[- ]?lists?\b/iu, /允许列表/u, "allowlist", "允许列表", "Update the allowlist.", "更新允许列表。"),
  term("artifact", /\bartifacts?\b/iu, /产物|OpenAPI\s*规范文件/u, "artifact", "产物；OpenAPI artifact=OpenAPI 规范文件", "Verify the build artifact.", "验证构建产物。"),
  term("release-candidate", /\brelease candidates?\b/iu, /发布候选版本/u, "release candidate", "发布候选版本", "Sign the release candidate.", "签署发布候选版本。"),
  term("staging", /\b(?:deploy(?:ed|ing)? to staging|staging (?:environment|cluster|server|deployment|configuration|config|origin|policy|evidence|resource|candidate|test|validation|change|switch|run|API)|protected staging)\b/iu, /预发布(?:环境)?|暂存环境/u, "staging environment", "预发布环境/暂存环境", "Deploy to staging.", "部署到预发布环境。"),
  term("rollout", /(?<!canary[- ])(?<!canary )\brollouts?\b/iu, /分阶段发布|逐步发布|上线/u, "rollout", "分阶段发布/逐步发布/上线", "Pause the rollout.", "暂停分阶段发布。"),
  term("canary-rollout", /\bcanary(?:[- ](?:staged|phased))? rollouts?\b/iu, /金丝雀(?:分阶段|逐步)?发布/u, "canary rollout", "金丝雀发布/金丝雀分阶段发布", "Pause the canary rollout.", "暂停金丝雀发布。"),
  term("immutable", /\bimmutable\b/iu, /不可变/u, "immutable", "不可变", "Keep the digest immutable.", "保持该摘要不可变。"),
  term("fixture", /\bfixtures?\b/iu, /测试夹具|测试固件/u, "test fixture", "测试夹具/测试固件", "Load the fixture.", "加载测试夹具。"),
  term("single-flight-refresh", /\bsingle[- ]flight refresh\b/iu, /合并并发刷新请求/u, "single-flight refresh", "合并并发刷新请求", "Use single-flight refresh.", "使用合并并发刷新请求。"),
  term("single-flight", /\bsingle[- ]flight\b/iu, /合并并发/u, "single-flight", "合并并发请求/机制", "Use a single-flight request.", "使用合并并发请求。"),
  term("provenance", /\bprovenance\b/iu, /溯源信息|来源依据|来源信息|来源记录/u, "provenance", "溯源信息/来源依据/来源记录", "Preserve the provenance.", "保留来源记录。"),
  term("processing-generation", /\b(?:positive generation|processing[- ]generation|generation[- ]bound|current generation match|newer generation|reviewed generation)\b/iu, /代次/u, "processing generation / positive generation", "处理代次/正数代次", "Require a positive generation.", "要求正数代次。"),
  term("state-key", /\b(?:reader[- ]state|state) keys?\b/iu, /状态键/u, "state key", "状态键", "Create a fresh reader-state key.", "创建新的阅读器状态键。"),
  term("security-authority", /\b(?:security authority|(?:supplies?|grants?|confers?) authority)\b/iu, /权限|授权依据|授权能力/u, "security authority", "安全权限/授权依据", "A deep link never supplies authority.", "深层链接绝不提供授权依据。"),
  term("queue-authority", /\b(?:queue|state) authority\b/iu, /权威状态|权威性|可信状态/u, "queue/state authority", "队列/状态的权威状态或权威性", "Verify queue authority.", "验证队列的权威状态。"),
  term("ground-truth", /\bground truth\b/iu, /真值|人工标注/u, "ground truth", "真值/人工标注真值", "Compare with human ground truth.", "与人工标注真值比较。"),
  term("data-export-contract", /\bdata[- ]export contracts?\b/iu, /数据导出(?:技术契约|规范)/u, "data-export contract", "数据导出技术契约/规范", "Preserve the data-export contract.", "保留数据导出技术契约。"),
  term("redaction", /\bredact(?:ion|ed|ing|s)?\b/iu, /脱敏|遮盖|隐去/u, "redaction", "脱敏/遮盖", "Apply log redaction.", "对日志进行脱敏。"),
];

const mobileTerminology = [
  term("physical-device", /\bphysical devices?\b/iu, /真机|实体(?:设备|手机)|物理(?:设备|手机)/u, "physical device", "真机/实体设备/物理设备", "Test on a physical device.", "在实体设备上测试。"),
  term("host-computer", /\bhost computers?\b/iu, /开发电脑|主机|宿主机/u, "host computer", "开发电脑/主机/宿主机", "Connect the host computer.", "连接宿主机。"),
  term("usb-debugging", /\bUSB debugging\b/iu, /USB\s*调试/u, "USB debugging", "USB 调试", "Enable USB debugging.", "启用 USB 调试。"),
  term("developer-mode", /\bDeveloper Mode\b/u, /开发者模式/u, "Developer Mode", "开发者模式", "Enable Developer Mode.", "启用开发者模式。"),
  term("local-network-permission", /\bLocal Network (?:access|permissions?)\b/iu, /本地网络(?:访问)?权限/u, "Local Network access/permission", "本地网络访问权限/本地网络权限", "Grant Local Network access.", "授予本地网络访问权限。"),
  term("reverse-port-forwarding", /\breverse port forwarding\b/iu, /反向端口(?:映射|转发)/u, "reverse port forwarding", "反向端口映射/反向端口转发", "Configure reverse port forwarding.", "配置反向端口转发。"),
  term("build-flavor", flutterBuildFlavorSourcePattern, /构建变体/u, "Flutter build/dev/staging/production flavor", "Flutter 构建变体（英文 flavor 注释可选）", "Run the dev flavor.", "运行 dev 构建变体。"),
  term("debug-mode", /\bDebug mode\b/u, /Debug[^\n。；]{0,12}调试/u, "Debug mode", "Debug（调试）模式", "Use Debug mode.", "使用 Debug（调试）模式。"),
  term("profile-mode", /\bProfile mode\b/u, /Profile[^\n。；]{0,12}性能分析/u, "Profile mode", "Profile（性能分析）模式", "Use Profile mode.", "使用 Profile（性能分析）模式。"),
  term("release-mode", /\bRelease mode\b/u, /Release[^\n。；]{0,12}发布/u, "Release mode", "Release（发布）模式", "Use Release mode.", "使用 Release（发布）模式。"),
  term("profile-build", profileBuildSourcePattern, /(?:Profile(?:[（(]性能分析[）)])?(?:模式)?\s*构建|性能分析(?:模式)?构建)/iu, "Flutter profile build", "Profile（性能分析）构建/性能分析模式构建", "Run the profile build.", "运行 Profile（性能分析）构建。"),
  term("release-build", releaseBuildSourcePattern, /(?:Release(?:[（(]发布[）)])?(?:模式)?\s*构建|发布(?:模式)?构建|发布版本)/iu, "mobile release build", "Release（发布）构建/发布模式构建/发布版本", "Verify the release build.", "验证 Release（发布）构建。"),
  term("hot-reload", /\bhot reload\b/iu, /热重载/u, "hot reload", "热重载", "Use hot reload.", "使用热重载。"),
  term("hot-restart", /\bhot restart\b/iu, /热重启/u, "hot restart", "热重启", "Use hot restart.", "使用热重启。"),
  term("widget-test", /\bwidget tests?\b/iu, /Widget\s*测试|组件测试|小组件测试/u, "widget test", "Widget 测试/组件测试/小组件测试", "Run the widget test.", "运行组件测试。"),
  term("accessibility", /\baccessibility\b/iu, /无障碍|辅助功能/u, "accessibility", "无障碍/辅助功能", "Review accessibility.", "检查辅助功能。"),
  term("screen-reader", /\bscreen[- ]readers?\b/iu, /屏幕阅读器|读屏软件|VoiceOver|旁白/u, "screen reader/screen-reader", "屏幕阅读器/读屏软件/VoiceOver（旁白）", "Enable the screen-reader.", "启用读屏软件。"),
  term("reduced-motion", /\breduced motion\b/iu, /减少动态效果|减弱动态效果|降低动态效果/u, "reduced motion", "减少/减弱/降低动态效果", "Test reduced motion.", "测试减弱动态效果。"),
  term("code-signing", /\bcode signing\b/iu, /代码签名/u, "code signing", "代码签名", "Configure code signing.", "配置代码签名。"),
  term("mobile-signing", /\b(?:(?:mobile|app|store|release|distribution|development|debug|Apple|Android|iOS|iPhone|build|code)[- ]signing|signing (?:identity|service|setup|details|credentials|material|certificate|configuration|profile|team|values?|inputs?|secrets?|custody|evidence))\b/iu, /签名/u, "mobile/build signing", "移动端/构建签名", "Configure release signing.", "配置发布签名。"),
  term("provisioning-profile", /\bprovisioning[- ]profiles?\b/iu, /预置描述文件|配置描述文件/u, "provisioning profile/provisioning-profile", "预置描述文件/配置描述文件", "Select the provisioning-profile.", "选择配置描述文件。"),
  term("ios-bundle-id", /\biOS bundle (?:identifier|ID)\b/iu, /iOS\s*Bundle\s*ID/u, "iOS bundle identifier", "iOS Bundle ID", "Set the iOS bundle identifier.", "设置 iOS Bundle ID。"),
  term("deep-link", /\bdeep[- ]links?\b/iu, /深层链接|深度链接/u, "deep link/deep-link", "深层链接/深度链接", "Open the deep-link.", "打开深度链接。"),
  term("cache-eviction", /\bcache eviction\b/iu, /缓存淘汰|缓存逐出|缓存驱逐/u, "cache eviction", "缓存淘汰/缓存逐出/缓存驱逐", "Test cache eviction.", "测试缓存逐出。"),
  term("state-hydration", /\bstate hydration\b/iu, /从持久化存储恢复状态|状态恢复|恢复状态/u, "state hydration", "从持久化存储恢复状态/状态恢复", "Test state hydration.", "测试状态恢复。"),
  term("app-store-policy", /\b(?:app store|store) (?:polic(?:y|ies)|disclosures?)\b/iu, /应用商店(?:政策|披露信息)/u, "app-store policy/disclosures", "应用商店政策/披露信息", "Review the app-store policy disclosures.", "检查应用商店披露信息。"),
  term("dart-zone", /\bDart zones?\b/iu, /Dart\s*Zone/u, "Dart zone", "Dart Zone", "Run in the Dart zone.", "在 Dart Zone 中运行。"),
];

const backendTerminology = [
  term("modular-monolith", /\bmodular monolith\b/iu, /模块化单体/u, "modular monolith", "模块化单体", "Deploy the modular monolith.", "部署模块化单体。"),
  term("durable-queue", /\bdurable queues?\b/iu, /持久(?:化)?(?:作业)?队列/u, "durable queue", "持久队列/持久化队列/持久化作业队列", "Drain the durable queue.", "排空持久化队列。"),
  term("message-broker", /\bmessage brokers?\b/iu, /消息代理|消息中间件/u, "message broker", "消息代理/消息中间件", "Configure the message broker.", "配置消息中间件。"),
  term("lease", /\b(?:(?:worker|job|queue|operation|processing) leases?|leases? (?:expires?|renewal|duration|timeout|owner|reclaim|claim)|(?:acquire|renew|reclaim|expire|hold|release) (?:a |the )?leases?)\b/iu, /租约/u, "worker/job lease", "租约", "Renew the worker lease.", "续订 worker 租约。"),
  term("schema", /\bschemas?\b/iu, /schema|数据库模式|数据结构(?:约束)?/iu, "schema", "schema/数据库模式/数据结构约束", "Validate the schema.", "验证数据库模式。", [
    {
      sourcePattern: schemaPersistsBehaviorSourcePattern,
      targetPattern: /持久化|存储/u,
    },
  ]),
  term("database-migration", /\bdatabase migrations?\b/iu, /数据库迁移/u, "database migration", "数据库迁移", "Run the database migration.", "运行数据库迁移。"),
  term("forward-only-migration", /\bforward[- ]only migrations?\b/iu, /仅向前迁移/u, "forward-only migration", "仅向前迁移", "Use a forward-only migration.", "使用仅向前迁移。"),
  term("expand-contract-migration", /\bexpand\/contract migrations?\b/iu, /扩展[—-]收缩式迁移/u, "expand/contract migration", "扩展—收缩式迁移", "Use an expand/contract migration.", "使用扩展—收缩式迁移。"),
  term("advisory-lock", /\badvisory locks?\b/iu, /advisory lock|咨询锁/iu, "advisory lock", "咨询锁（英文注释可选）", "Acquire the advisory lock.", "获取咨询锁。"),
  term("backup", /\bbackups?\b/iu, /备份/u, "backup", "备份", "Verify the backup.", "验证备份。"),
  term("restore", /\brestor(?:e|es|ed|ing)\b/iu, /恢复/u, "restore", "从备份恢复/恢复", "Restore the backup.", "从备份恢复。"),
  term("rollback", /\brollbacks?\b/iu, /回滚/u, "rollback", "回滚", "Test the rollback.", "测试回滚。"),
  term("readiness-probe", /\breadiness probes?\b/iu, /就绪探针/u, "readiness probe", "就绪探针", "Check the readiness probe.", "检查就绪探针。"),
  term("liveness-probe", /\bliveness probes?\b/iu, /存活探针/u, "liveness probe", "存活探针", "Check the liveness probe.", "检查存活探针。"),
  term("smoke-test", /\bsmoke tests?\b/iu, /冒烟测试/u, "smoke test", "冒烟测试", "Run the smoke test.", "运行冒烟测试。"),
  term("deployment-topology", /\bdeployment topolog(?:y|ies)\b/iu, /部署拓扑/u, "deployment topology", "部署拓扑", "Review the deployment topology.", "检查部署拓扑。"),
  term("container-image", /\bcontainer images?\b/iu, /容器镜像/u, "container image", "容器镜像", "Pin the container image.", "固定容器镜像。"),
  term("image-digest", /\bimage digests?\b/iu, /镜像摘要/u, "image digest", "镜像摘要", "Pin the image digest.", "固定镜像摘要。"),
  term("least-privilege", /\bleast privilege\b/iu, /最小权限/u, "least privilege", "最小权限原则", "Apply least privilege.", "应用最小权限原则。"),
  term("drift-over-sqlite", /\bDrift over SQLite\b/u, /(?:基于|建立在|运行在)[^\n。；]{0,20}SQLite[^\n。；]{0,20}Drift|Drift[^\n。；]{0,20}(?:基于|使用)[^\n。；]{0,12}SQLite/u, "Drift over SQLite", "基于 SQLite 的 Drift", "Use Drift over SQLite.", "使用基于 SQLite 的 Drift。"),
  term("authorization-header", authorizationHeaderSourcePattern, /Authorization\s*请求头/u, "Authorization header", "Authorization 请求头", "Do not log authorization headers.", "不得记录 Authorization 请求头。"),
  term("authentication-scope", /\bauthentication scopes?\b/iu, /(?:身份(?:认证|验证|鉴别)|账户认证|用户认证|认证)(?:范围|作用域)/u, "authentication scope", "身份/账户/用户认证范围或作用域；身份验证作用域", "Limit the authentication scope.", "限制账户认证作用域。"),
];

const identityTerminology = [
  term("authentication", /\bauthentication\b/iu, /(?:身份|账户|用户)?认证|身份验证/u, "authentication", "认证/身份认证/身份验证/账户认证/用户认证", "Require authentication.", "要求账户认证。"),
  term("authorization", /\bauthorization\b(?!\s+headers?)/iu, /授权/u, "authorization", "授权", "Check authorization.", "检查授权。"),
  term("identity-provider", /\bidentity providers?\b/iu, /身份提供商/u, "identity provider", "身份提供商（IdP）", "Configure the identity provider.", "配置身份提供商（IdP）。"),
  term("keycloak-realm", /\bKeycloak realms?\b/iu, /Keycloak\s*Realm/u, "Keycloak realm", "Keycloak Realm（领域）", "Create the Keycloak realm.", "创建 Keycloak Realm（领域）。"),
  term("issuer", /\b(?:(?:OIDC|token|provider|identity) issuers?|issuers? (?:URL|URI|validation|metadata|coordinate|claim))\b/iu, /颁发者|签发者|签发方/u, "OIDC/token issuer", "颁发者/签发者/签发方", "Validate the OIDC issuer.", "验证 OIDC 签发方。"),
  term("subject", identitySubjectSourcePattern, /主体标识/u, "OIDC/provider subject", "主体标识（subject）", "Validate the OIDC subject.", "验证 OIDC 主体标识（subject）。"),
  term("audience", /\b(?:(?:OIDC|token|client|API|operator|admin) audiences?|audiences? (?:claim|validation|value|set))\b/iu, /受众|目标受众/u, "OIDC/token audience", "受众/目标受众", "Validate the OIDC audience.", "验证 OIDC 目标受众。"),
  term("claim", /\b(?:(?:OIDC|JWT|token|identity) claims?|claims? (?:value|set|validation)|claim (?:value|set|validation))\b/iu, /声明/u, "OIDC/JWT/token claim", "声明（claim）", "Validate the OIDC claim.", "验证 OIDC 声明（claim）。"),
  term("public-native-client", /\bpublic native clients?\b/iu, /原生公共客户端|公共原生客户端/u, "public native client", "原生公共客户端/公共原生客户端", "Register the public native client.", "注册公共原生客户端。"),
  term("access-token", /\baccess tokens?\b/iu, /访问令牌/u, "access token", "访问令牌", "Store no access token.", "不存储访问令牌。"),
  term("refresh-token", /\brefresh tokens?\b/iu, /刷新令牌/u, "refresh token", "刷新令牌", "Rotate the refresh token.", "轮换刷新令牌。"),
  term("bearer-token", /\bbearer tokens?\b/iu, /Bearer\s*令牌/u, "bearer/Bearer token", "Bearer 令牌", "Attach the Bearer token.", "附加 Bearer 令牌。"),
  term("jit-provisioning", /\bJIT (?:provisioning|mapping)\b/iu, /即时(?:创建本地账户映射|预配|配置)|JIT/iu, "JIT provisioning/mapping", "即时预配/即时创建本地账户映射（JIT）", "Use JIT provisioning.", "使用 JIT 即时预配。"),
  term("secure-storage", /\bsecure storage\b/iu, /安全存储/u, "secure storage", "安全存储", "Use secure storage.", "使用安全存储。"),
  term("user-profile", /\buser profiles?\b/iu, /用户资料|个人资料/u, "user profile", "用户资料/个人资料", "Update the user profile.", "更新个人资料。"),
  term("handle", publicUserHandleSourcePattern, /用户名|账号名|用户标识/u, "public user handle", "用户名/账号名/用户标识", "Choose a public handle.", "选择公开用户名。"),
  term("compare-and-swap", /\bcompare[- ]and[- ]swap\b/iu, /比较并交换|比较交换/u, "compare-and-swap", "比较并交换/比较交换（CAS）", "Use compare-and-swap.", "使用比较交换（CAS）。"),
  term("in-flight", /\bin[- ]flight\b/iu, /正在进行|进行中|尚未完成/u, "in-flight", "正在进行的/进行中的/尚未完成的", "Wait for the in-flight request.", "等待进行中的请求。"),
  term("not-before", oidcNotBeforeSourcePattern, /不得早于指定时间生效|生效时间下限|not-before/u, "OIDC not-before", "不得早于指定时间生效/生效时间下限/not-before", "Enforce the OIDC not-before time.", "强制执行 OIDC 生效时间下限。"),
  term("brute-force-protection", bruteForceProtectionSourcePattern, /暴力破解防护|防暴力破解/u, "brute-force protection", "暴力破解防护/防暴力破解", "Enable brute-force protection.", "启用暴力破解防护。"),
];

const adrReaderStageTerminology = [
  term("introduction-reader-stage", /\bIntroduction\b(?=[^.!?;]{0,120}\b(?:caches?|responses?|blobs?|stages?)\b)/u, /(?<![\p{L}\p{N}_])Introduction(?![\p{L}\p{N}_])/u, "Introduction reader stage", "Introduction（保留阶段名）", "Cache the Introduction stage.", "缓存 Introduction 阶段。"),
  term("connections-reader-stage", /(?:\bConnections\b(?=[^.!?;]{0,120}\b(?:caches?|responses?|blobs?|stages?|back-navigation|scroll-restoration)\b)|\b[Bb]egin(?:s|ning)? on Connections\b)/u, /(?<![\p{L}\p{N}_])Connections(?![\p{L}\p{N}_])/u, "Connections reader stage", "Connections（保留阶段名）", "Begin on Connections.", "从 Connections 阶段开始。"),
];

const driftLocalDatabaseTerminology = [
  term("bounded-cache", /\bbounded caches?\b/iu, /有界缓存|容量(?:受限|有限|有上限)(?:的)?缓存|缓存容量(?:受限|有限|有上限)/u, "bounded cache", "有界缓存/容量受限的缓存", "Use bounded cache eviction.", "使用有界缓存淘汰机制。"),
  term("cache-capacity", /\bcache capacit(?:y|ies)\b/iu, /缓存容量/u, "cache capacity", "缓存容量", "Measure cache capacity.", "测量缓存容量。"),
  term("saved-paper-pinning", /\bsaved-paper pinning\b/iu, /(?:(?:固定保留|固定驻留|驻留保护|缓存固定)(?:已保存|收藏)(?:的)?论文|(?:已保存|收藏)(?:的)?论文(?:的)?(?:固定保留|固定驻留|驻留保护|缓存固定))/u, "saved-paper pinning", "固定保留已保存的论文/已保存论文驻留保护", "Use saved-paper pinning.", "固定保留已保存的论文。"),
];

export function mandatoryTerminologyFor(relativePath = "") {
  const normalizedPath = normalizeRelativePath(relativePath);
  const rules = [...sharedTerminology];
  if (/mobile|account-authentication|app-links|user-guide|store\/|adr\/(?:0001|0002|0003|0006)/.test(normalizedPath)) {
    rules.push(...mobileTerminology);
  }
  if (/backend|deployment|architecture|runbooks\/|phase-reports\/|production-v0|adr\//.test(normalizedPath)) {
    rules.push(...backendTerminology);
  }
  if (/account|auth|oidc|comments|moderation|privacy|terms|community|deletion|store\/|adr\/0001/.test(normalizedPath)) {
    rules.push(...identityTerminology);
  }
  if (driftLocalDatabasePathPattern.test(normalizedPath) || statefulShellRoutingPathPattern.test(normalizedPath)) {
    rules.push(...adrReaderStageTerminology);
  }
  if (driftLocalDatabasePathPattern.test(normalizedPath)) {
    rules.push(...driftLocalDatabaseTerminology);
  }
  return [...new Set(rules)];
}

export const FORBIDDEN_TRANSLATION_RULES = Object.freeze([
  forbidden("artwork used for a software artifact", /\bartifacts?\b/iu, /(?:OpenAPI|API|构建|发布|证据|候选|移动|软件)\s*艺术品|艺术品(?:身份|清单|摘要|哈希|校验)/u, ["艺术品"], "The OpenAPI artifact is generated.", "OpenAPI 艺术品已生成。"),
  forbidden("paper translated as a physical sheet", /\bpapers?\b/iu, /纸张(?:路由|记录|内容|数据|元数据|标识符|\s*ID)|纸质(?:许可证|内容|数据|元数据|标识符)/u, ["纸张", "纸质"], "Guest paper routes stay available.", "访客纸张路由保持可用。"),
  forbidden("feed translated as animal feed", /\bfeed\b/iu, /gzip\s*饲料|饲料(?:预取|缓存|同步|端点|响应)/iu, ["饲料"], "The gzip feed is complete.", "gzip 饲料缓存已完成。"),
  forbidden("response envelope translated as a physical envelope", /\benvelopes?\b/iu, /(?:错误|响应|API)\s*信封/u, ["响应信封", "错误信封"], "Return the standard error envelope.", "返回错误信封。"),
  forbidden("source of truth translated literally", /\bsource of truth\b/iu, /源真值|真相来源/u, ["源真值", "真相来源"], "PostgreSQL is the source of truth.", "PostgreSQL 是源真值。"),
  forbidden("fail closed translated literally or backwards", null, /关闭失败|失败关闭/u, ["失败关闭", "关闭失败"], "The gate must fail these actions closed.", "该门禁必须失败关闭这些操作。"),
  forbidden("fail closed translated ambiguously as safe failure", failClosedSourcePattern, /安全失败/u, ["安全失败"], "The gate must fail these actions closed.", "该门禁必须安全失败。"),
  forbidden("in-flight translated literally", /\bin[- ]flight\b/iu, /在飞行中(?:的)?(?:请求|发送|操作|任务|工作)/u, ["在飞行中"], "Permit two in-flight requests.", "允许两个在飞行中的请求。"),
  forbidden("single-flight translated literally", /\bsingle[- ]flight\b/iu, /(?:一次|单次)飞行(?:刷新|请求)?/u, ["一次飞行", "单次飞行"], "Use a single-flight refresh.", "使用一次飞行刷新。"),
  forbidden("lazy swipe translated literally", /\blazy swipe\b/iu, /懒惰滑动/u, ["懒惰滑动"], "Exercise the lazy swipe path.", "测试懒惰滑动路径。"),
  forbidden("test fixture translated as a physical fixture", /\bfixtures?\b/iu, /(?:API|测试|单元测试)\s*固定装置/u, ["固定装置"], "Update the API fixtures.", "更新 API 固定装置。"),
  forbidden("network origin translated as a geometric origin", /\borigins?\b/iu, /(?:CORS|HTTPS?|URL|API)\s*原点/iu, ["原点"], "Allow the configured CORS origin.", "允许配置的 CORS 原点。"),
  forbidden("software mutation translated as a biological mutation", /\bmutations?\b/iu, /资料变异|突变(?:意图|操作|请求|限制)|(?:库|评论|账户|API)\s*突变/u, ["资料变异"], "Reject a different mutation intent.", "拒绝另一项资料变异。"),
  forbidden("block/unblock translated as friend management", /\b(?:un)?block(?:ed|ing|s)?\b/iu, /增删好友/u, ["增删好友"], "Block and unblock are separate operations.", "增删好友是不同操作。"),
  forbidden("profile contract translated as a business contract", /\bprofile contract\b/iu, /资料合约/u, ["资料合约"], "The profile contract is stable.", "资料合约保持稳定。"),
  forbidden("Pakperk Library translated as a physical library", pakperkLibrarySourcePattern, /图书馆/u, ["图书馆"], "Keep the Library available.", "图书馆保持可用。"),
  forbidden("Helm Chart translated literally", /\bHelm Charts?\b/iu, /Helm\s*图表/iu, ["Helm 图表"], "Render the Helm Chart.", "渲染 Helm 图表。"),
  forbidden("accessibility translated as generic reachability", /\baccessibility\b/iu, /可访问性/u, ["可访问性"], "Complete the accessibility review.", "完成可访问性审查。"),
  forbidden("Bearer token translated literally", /\bBearer tokens?\b/iu, /承载令牌/u, ["承载令牌"], "Attach the Bearer token.", "附加承载令牌。"),
  forbidden("Drift product name translated", /\bDrift\b/u, /漂移(?:\s*(?:数据库|本地|缓存|SQLite))?/u, ["将 Drift 译为“漂移”"], "Drift stores the cache.", "漂移数据库存储缓存。"),
  forbidden("Profile mode translated as a file mode", /\bProfile mode\b/iu, /配置文件模式/u, ["配置文件模式"], "Run in Profile mode.", "以配置文件模式运行。"),
  forbidden("state/cache hydration translated literally", /\b(?:state|cache) hydration\b/iu, /(?:状态|缓存)水合/iu, ["状态水合", "缓存水合"], "Verify state hydration.", "验证状态水合。"),
  forbidden("iOS bundle identifier translated literally", /\biOS bundle (?:identifier|ID)\b/iu, /iOS\s*(?:打包|捆绑)\s*ID/iu, ["iOS 打包 ID", "iOS 捆绑 ID"], "Use the iOS bundle identifier.", "使用 iOS 捆绑 ID。"),
  forbidden("OIDC subject translated as a topic", identitySubjectSourcePattern, /OIDC\s*主题/iu, ["OIDC 主题"], "Validate the OIDC subject.", "验证 OIDC 主题。"),
  forbidden("Drift presented as an alternative to SQLite", /\bDrift over SQLite\b/u, /Drift[^\n。！？.!?]{0,80}(?:而不是|取代|替代)[^\n。！？.!?]{0,80}SQLite/u, ["Drift 而不是 SQLite"], "Use Drift over SQLite.", "使用 Drift 而不是 SQLite。"),
  forbidden("positive generation translated as positive sentiment", /\bpositive generation\b/iu, /积极生成|正向生成|正生成/u, ["积极生成", "正向生成"], "Require a positive generation.", "要求积极生成。"),
  forbidden("state key translated as a cryptographic secret", /\b(?:reader[- ]state|state) keys?\b/iu, /(?:阅读器)?(?:状态)?密钥/u, ["状态密钥", "阅读器密钥"], "Create a fresh reader-state key.", "创建新的阅读器密钥。"),
  forbidden("security authority translated as authoritative information", /\b(?:security authority|(?:supplies?|grants?|confers?) authority)\b/iu, /权威信息/u, ["权威信息"], "A deep link never supplies authority.", "深层链接绝不提供权威信息。"),
  forbidden("redaction translated as red/black list", /\bredact(?:ion|ed|ing|s)?\b/iu, /红黑名单/u, ["红黑名单"], "Apply log redaction.", "应用日志红黑名单。"),
  forbidden("container image translated as a picture", /\bcontainer images?\b/iu, /容器图像/u, ["容器图像"], "Pin the container image.", "固定容器图像。"),
  forbidden("GROBID name truncated", /\bGROBID\b/u, /\bGROB\b/u, ["GROB"], "Run GROBID.", "运行 GROB。"),
  forbidden("OIDC not-before translated with reversed timing", oidcNotBeforeSourcePattern, /未过期前|未过期时间/u, ["未过期前", "未过期时间"], "Enforce the OIDC not-before time.", "强制执行 OIDC 未过期时间。"),
  forbidden("brute-force protection translated as vague force protection", bruteForceProtectionSourcePattern, /暴力保护/u, ["暴力保护"], "Enable brute-force protection.", "启用暴力保护。"),
  forbidden("Authorization header translated as a vague authorization head", authorizationHeaderSourcePattern, /授权(?:请求)?头/u, ["授权头", "授权请求头"], "Do not log authorization headers.", "不得记录授权头。"),
]);

export const TERMINOLOGY_NORMALIZATIONS = Object.freeze([
  normalization(/\bartifacts?\b/iu, /艺术品|工件|制品/gu, "产物"),
  normalization(/\b(?:(?:arXiv|saved|public|research|reading|recommended|imported|cached|seed|synthetic) papers?|papers? (?:record|metadata|route|content|data|ID|identifier|feed|reader|worker|version|title|abstract|preparation|cache|library))\b/iu, /纸张|纸质/gu, "论文"),
  normalization(/\b(?:(?:reading|paper|recommendation|guest|Read) feeds?|feeds? (?:endpoint|page|item|cache|repository|route|response))\b/iu, /饲料/gu, "Feed"),
  normalization(/\bresponse envelopes?\b/iu, /信封/gu, "封装"),
  normalization(/(?<![\p{L}\p{N}-])delta(?:-| )seconds(?![\p{L}\p{N}-])/u, /(?<![\p{L}\p{N}-])delta(?:-| )seconds(?![\p{L}\p{N}-])/gu, "秒数差值"),
  normalization(/\bsource of truth\b/iu, /源真值|真相来源/gu, "权威数据源"),
  normalization(failClosedSourcePattern, /失败时(?:会)?关闭|会失败关闭/gu, "失败时默认拒绝"),
  normalization(failClosedSourcePattern, /关闭失败|失败关闭/gu, "失败时默认拒绝"),
  normalization(/\bin[- ]flight\b/iu, /在飞行中的?/gu, "正在进行的"),
  normalization(/\bsingle[- ]flight refresh\b/iu, /(?:一次|单次)飞行刷新/gu, "合并并发刷新请求"),
  normalization(/\bsingle[- ]flight refresh\b/iu, /一次单次刷新请求|一次单次刷新|单次刷新请求|单次刷新|一次刷新请求/gu, "合并并发刷新请求"),
  normalization(/\bsingle[- ]flight\b/iu, /(?:一次|单次)飞行(?:请求)?/gu, "合并并发请求"),
  normalization(/\blazy swipe\b/iu, /懒惰滑动/gu, "按需滑动"),
  normalization(/\bfixtures?\b/iu, /固定装置/gu, "测试夹具"),
  normalization(/\b(?:(?:CORS|request|allowed|configured|web|HTTPS?) origins?|origins? (?:allowlist|header|policy|check|validation))\b/iu, /((?:CORS|HTTPS?|URL|API)\s*)原点/giu, "$1源"),
  normalization(/\b(?:(?:API|library|comment|account|profile|write) mutations?|mutations? (?:request|intent|route|operation|race|limit))\b/iu, /资料变异|突变/gu, "写操作"),
  normalization(/\b(?:(?:block|blocked|blocking) (?:an? |another |the )?(?:abusive )?(?:user|author|account)|(?:user|author|account)(?:[- ]level)? blocks?|(?:report|add|create|remove|persist|explicit) (?:a )?block)\b/iu, /增删好友/gu, "屏蔽"),
  normalization(pakperkLibrarySourcePattern, /图书馆/gu, replacePakperkLibrary),
  normalization(historicalYouLibraryRoutesSourcePattern, /当前库路由/gu, "当时的个人论文库路由"),
  normalization(olderRestoredYouSessionSourcePattern, /旧的 You 会话/gu, "旧版中恢复的 You 会话"),
  normalization(/\bHelm Charts?\b/iu, /Helm\s*图表/giu, "Helm Chart"),
  normalization(/\baccessibility\b/iu, /可访问性/gu, "无障碍"),
  normalization(/\bBearer tokens?\b/iu, /承载令牌/gu, "Bearer 令牌"),
  normalization(/\bDrift\b/u, /漂移/gu, "Drift"),
  normalization(schemaMigrationSourcePattern, /(?<!数据库)模式迁移/gu, replaceSchemaMigration),
  normalization(schemaVersionSourcePattern, /模式版本/gu, replaceSchemaVersion),
  normalization(schemaContainsSourcePattern, /(^|[\n。！？；;：:，,])([\t ]*)模式包含/gmu, "$1$2schema 包含"),
  normalization(
    completeHistoricalSchemaFixturesSourcePattern,
    /数据库迁移(?:是显式的[，,][\t ]*并从完整的原始模式快照测试到版本|是显式且经过测试的[，,][\t ]*从完整的原始模式快照开始[，,][\t ]*一直到版本)([\t ]*(?:`\{\{PAKPERK_PROTECTED_[^}\r\n]+\}\}`|\d+))/gu,
    "数据库迁移均显式定义，并使用完整的历史数据库模式测试夹具完成截至版本$1 的迁移测试",
  ),
  normalization(technicalOutboxSourcePattern, /\boutbox\b/gu, replaceUnpairedTechnicalOutbox),
  normalization(technicalOutboxSourcePattern, /待同步队列[\t ]+outbox\b/gu, "待同步队列（outbox）"),
  normalization(technicalOutboxSourcePattern, /待同步队列(?:[\t ]*[（(]outbox[）)])?[\t ]*待同步队列[（(]outbox[）)]/gu, "待同步队列（outbox）"),
  normalization(technicalOutboxSourcePattern, /持久化(?:的)?同步[\t ]*待同步队列[（(]outbox[）)]/gu, "持久化的待同步队列（outbox）"),
  normalization(technicalOutboxSourcePattern, /同步[\t ]*待同步队列[（(]outbox[）)]/gu, "待同步队列（outbox）"),
  normalization(technicalOutboxSourcePattern, /待同步队列（outbox）[\t ]+(?=\p{Script=Han})/gu, "待同步队列（outbox）"),
  normalization(/\bProfile mode\b/iu, /配置文件模式/gu, "Profile（性能分析）模式"),
  normalization(/\b(?:cache )?hydration\b/iu, /缓存水合/gu, "从持久化存储恢复状态"),
  normalization(operationalAlertSourcePattern, /警报/gu, "告警"),
  normalization(/\biOS bundle (?:identifier|ID)\b/iu, /iOS\s*(?:打包|捆绑)\s*ID/giu, "iOS Bundle ID"),
  normalization(identitySubjectSourcePattern, /OIDC\s*主题/giu, "OIDC 主体标识"),
  normalization(identitySubjectSourcePattern, /OIDC\s*主体(?!标识)/gu, "OIDC 主体标识"),
  normalization(identitySubjectSourcePattern, /((?:身份)?提供商)\s*主体(?!标识)/gu, "$1主体标识"),
  normalization(identitySubjectSourcePattern, /((?:必需|要求)的)主体(?!标识)/gu, "$1主体标识"),
  normalization(/\bAPI routes?\b/iu, /API\s*路线/giu, "API 路由"),
  normalization(/\bKeycloak realms?\b/iu, /Keycloak[\t ]*(?:领域|域|realm\b)/giu, replaceKeycloakRealm),
  normalization(/\bDrift over SQLite\b/u, /使用[\t ]*Drift[\t ]*作为([^\n。！？，,]{0,40})[，,]?[\t ]*而不是[\t ]*SQLite/gu, "使用基于 SQLite 的 Drift 作为$1"),
  normalization(/\bDrift over SQLite\b/u, /Drift\s*(?:而不是|取代|替代)\s*SQLite/gu, "基于 SQLite 的 Drift"),
  normalization(/\bpositive generation\b/iu, /积极生成|正向生成|正生成/gu, "正数代次"),
  normalization(/\b(?:reader[- ]state|state) keys?\b/iu, /(?:阅读器)?(?:状态)?密钥/gu, "状态键"),
  normalization(/\b(?:security authority|(?:supplies?|grants?|confers?) authority)\b/iu, /权威信息/gu, "授权依据"),
  normalization(/\bcontainer images?\b/iu, /容器图像/gu, "容器镜像"),
  normalization(/\bredact(?:ion|ed|ing|s)?\b/iu, /红黑名单/gu, "脱敏"),
  normalization(publicUserHandleSourcePattern, /句柄/gu, "用户名"),
  normalization(publicUserHandleSourcePattern, /(?:公开|公共)标识符?/gu, "公开用户名"),
  normalization(authorizationHeaderSourcePattern, /authorization[\t ]+(?:headers?|请求头)|授权(?:请求)?头/giu, replaceAuthorizationHeader),
]);

const sharedPolicy = `Translate the supplied Pakperk software documentation from English into professional Mainland Simplified Chinese.

Meaning and tone:
- Translate every visible prose sentence. Preserve meaning, scope, ordering, and obligation strength exactly; MUST/MUST NOT/SHOULD/MAY mean 必须/不得/应/可以. “Must not” is never merely 不应.
- Write concise, natural, instructional Chinese. Avoid literal English word order and unexplained noun piles. In developer guides, prefer direct instructions; in reader-facing legal text, address the reader consistently as “您”.
- Do not summarize, omit, invent, soften a requirement, add commentary, duplicate a phrase, or leave an ordinary English sentence untranslated.
- Treat every sentence as complete in its Markdown context. A protected placeholder may be the code block, command, or value introduced by the sentence immediately before it; never add a note claiming that the source is incomplete.
- Use Chinese full-width punctuation in prose and one ASCII space between Chinese and adjacent Latin names, acronyms, versions, numbers, or units.

Protected content and Markdown:
- Preserve every backtick-wrapped {{PAKPERK_*}} marker and every https://pakperk.invalid/__protected/PAKPERK_* placeholder byte-for-byte and in the same order. They represent protected technical content and will be restored after translation.
- Preserve every Markdown heading level, list marker and number, checkbox, block quote, emphasis marker, table shape, hard line break, reference-link definition, and paragraph order.
- Never add raw HTML, an autolink, a footnote, or a new Markdown node.
- Never alter fenced code, inline code, link destinations, paths, commands, flags, environment variables, API paths, HTTP headers/statuses, identifiers, error codes, hashes, content IDs, versions, numeric thresholds, or quoted UI labels.
- Return only translated Markdown. Never emit /no_think, analysis, an introduction, or an outer code fence.`;

const meaningClarifications = `

Meaning-sensitive phrases:
- “Drift over SQLite” means Drift is the typed persistence layer backed by SQLite; it never means Drift replaces SQLite.
- processing generation/generation-bound is 处理代次/代次绑定; positive generation is 正数代次.
- provenance is 溯源信息 or 来源依据; a state key is 状态键, never 密钥.
- authority in a security sentence means 权限/授权依据, not 权威信息. Queue/data authority means authoritative state, not security authorization.`;

export function translationSystemPrompt(relativePath = "") {
  const terminology = mandatoryTerminologyFor(relativePath);
  const forbiddenExamples = FORBIDDEN_TRANSLATION_RULES.flatMap((rule) => rule.examples);
  return `${sharedPolicy}

Names that stay in English:
${PRESERVED_TECHNICAL_NAMES.join(", ")}. Keep exact Pakperk UI labels ${PAKPERK_UI_LABELS.join(", ")} unchanged when the source uses them as interface labels.

Required terminology:
${terminology.map((rule) => `${rule.sourceLabel}=${rule.targetLabel}`).join("; ")}.

Forbidden literal mistranslations in technical prose include: ${forbiddenExamples.join(", ")}.${meaningClarifications}`;
}

export function translationPolicyDigest(relativePath = "") {
  const digest = createHash("sha256");
  digest.update("pakperk-translation-policy-digest-v1\0");
  digest.update(translationSystemPrompt(relativePath));
  for (const moduleName of ["translation-policy.mjs", "translation-quality.mjs", "translation-structure.mjs"]) {
    digest.update("\0");
    digest.update(moduleName);
    digest.update("\0");
    digest.update(readFileSync(new URL(moduleName, import.meta.url), "utf8"));
  }
  return digest.digest("hex");
}

function normalizeRelativePath(relativePath) {
  return relativePath.replaceAll("\\", "/").toLowerCase();
}

function term(
  id,
  sourcePattern,
  targetPattern,
  sourceLabel,
  targetLabel,
  sourceExample,
  validExample,
  conditionalTargets = [],
) {
  return Object.freeze({
    id,
    sourcePattern,
    targetPattern,
    sourceLabel,
    targetLabel,
    sourceExample,
    validExample,
    conditionalTargets: Object.freeze(conditionalTargets.map((target) => Object.freeze(target))),
  });
}

function forbidden(description, sourcePattern, pattern, examples, sourceExample, invalidExample) {
  return Object.freeze({ description, sourcePattern, pattern, examples: Object.freeze(examples), sourceExample, invalidExample });
}

function normalization(sourcePattern, pattern, replacement) {
  return Object.freeze({ sourcePattern, pattern, replacement });
}

function replacePakperkLibrary(match, offset, value) {
  return replaceLatinNameWithChineseSpacing("Library", match, offset, value);
}

function replaceKeycloakRealm(match, offset, value) {
  return replaceLatinNameWithChineseSpacing("Keycloak Realm", match, offset, value);
}

function replaceSchemaMigration(match, offset, value) {
  return replacePhraseStartingWithLatinText("schema 迁移", match, offset, value);
}

function replaceSchemaVersion(match, offset, value) {
  return replacePhraseStartingWithLatinText("schema 版本", match, offset, value);
}

function replaceAuthorizationHeader(match, offset, value) {
  return replacePhraseStartingWithLatinText("Authorization 请求头", match, offset, value);
}

function replaceUnpairedTechnicalOutbox(match, offset, value) {
  const prefix = value.slice(Math.max(0, offset - 24), offset);
  if (/待同步队列[\t ]*[（(]?[\t ]*$/u.test(prefix)) return match;
  return "待同步队列（outbox）";
}

function replacePhraseStartingWithLatinText(replacement, match, offset, value) {
  const previous = [...value.slice(0, offset)].at(-1) || "";
  const leadingSpace = /\p{Script=Han}/u.test(previous) ? " " : "";
  return `${leadingSpace}${replacement}`;
}

function replaceLatinNameWithChineseSpacing(replacement, match, offset, value) {
  const previous = [...value.slice(0, offset)].at(-1) || "";
  const next = [...value.slice(offset + match.length)].at(0) || "";
  const leadingSpace = /\p{Script=Han}/u.test(previous) ? " " : "";
  const trailingSpace = /\p{Script=Han}/u.test(next) ? " " : "";
  return `${leadingSpace}${replacement}${trailingSpace}`;
}
