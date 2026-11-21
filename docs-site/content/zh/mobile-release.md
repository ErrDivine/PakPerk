# 移动端发布流程

这是 Pakperk 移动端 `0.2.0+2` 的发布技术契约。Production v0.0 是一个里程碑名称；它不允许降低包版本或商店构建版本。

## 产物身份矩阵

| 环境 | Android 的应用 ID | iOS Bundle ID 值 | OIDC 回调 | 应用链接主机 |
| --- | --- | --- | --- | --- |
| 开发环境 | `app.pakperk.pakperk.dev` | `app.pakperk.pakperk.dev` | `pakperk-auth-dev` | 仅回环 HTTP |
| 预发布环境 | `app.pakperk.pakperk.staging` | `app.pakperk.pakperk.staging` | `pakperk-auth-staging` | `staging.pakperk.app` |
| 生产环境 | `app.pakperk.pakperk` | `app.pakperk.pakperk` | `pakperk-auth` | `pakperk.app` |

调试构建绝不能默认使用生产环境配置。预发布环境与生产环境只允许 HTTPS。Android 的备份/恢复功能在每一个构建变体中都被禁用。iOS 会将 Documents、Preferences、Application Support、SQLite 附属文件及其子项排除在备份之外，并在设备上应用 `completeUntilFirstUserAuthentication` 数据保护。

## 当前平台提交技术契约

最终产物必须证明以下数值，而不是采用 Gradle 或 Xcode 的默认值：

- Android 使用最低 API 24 与编译/目标 API 36。Google Play 要求新的手机/平板应用及其更新使用 Android 16/API 36，此要求自 [31 年 2026 月](https://developer.android.com/google/play/requirements/target-sdk)起生效。
- Android 的原生编译被固定为 NDK `28.2.13676358`；更改该输入需要重新构建并重新运行两项归档对齐检查。
- 由于 Pakperk 打包了原生共享库，APK 与 AAB 都必须使每一个 `arm64-v8a` 以及存在的 `x86_64` ELF `LOAD` 分段，都对齐到至少 16 KiB。APK 还必须通过 `zipalign -c -P 16 -v 4`。Google Play 的[16 KiB 兼容性要求](https://developer.android.com/guide/practices/page-sizes)，自 1 年 2025 月起，已适用于面向 API 35 或更高版本的新应用及其更新。
- iOS 使用 15.0 作为部署目标。Apple 将 iOS 15 认定为 Xcode 26 所支持 App Store 上传范围的下限，这记录在其[Xcode 系统要求](https://developer.apple.com/xcode/system-requirements)中。自 [28 年 2026 月](https://developer.apple.com/news/upcoming-requirements/?id=02032026a)起，上传的 iOS 应用必须使用 Xcode 26 或更高版本，以及 iOS 26 SDK 或更高版本构建。

`verify_android_release_artifacts.sh` 会输出并要求最低 24、编译/目标 36、一个数值上最新的完整 Build-Tools 安装、16 KiB 的 APK ZIP 对齐，以及 16 KiB 的原生 ELF 对齐。它会拒绝可调试/仅测试用的归档文件、Android 调试证书、多个 APK 签名者，以及不同时具备 v2 与 v3/v3.1 签名的 APK。其 AAB 检查只在一个临时信任库中信任已提取的签名者，因此一个普通的自签名 Android 上传证书会被接受，同时严格的 JAR 完整性、完整签名、现代算法，以及 APK/AAB 指纹一致性仍是强制性的。

`verify_ios_release_artifact.sh` 会输出 Xcode、SDK、平台与最低 OS 元数据（来自已签名的 IPA），并要求 Xcode/iOS SDK 26+、确切的 iOS 15.0、一份未过期的 App Store 预置描述文件（非开发、临时或企业版）、经描述文件授权的已签名 entitlement、一个确切的应用标识符、该环境确切的 ATS 策略，以及与来源一致的、不跟踪的应用隐私清单。本地模拟器构建目前记录的是 Xcode 26.6（`DTXcode=2660`）与 SDK 26.5；这只是源代码/模拟器证据，不能替代已签名的 `iphoneos` IPA 门禁或 App Store 验收。

## 可复现的检查与构建

请使用 Flutter `3.44.8`，框架修订版本为 `058e0af2c2b57e369d905a03ac9748b0ebf543c6`，配合其内置的 Dart `3.12.2`，这是在发布工作流与完整本地检查中，于依赖解析之前所核验的确切稳定 SDK 身份。使用不同的本地 SDK 只是开发证据；当其解析出的 SDK 与工作流锁定版本不一致时，发布元数据生成将失败并拒绝。

原生 Android 依赖解析与发布构建，只有在托管的 arm64 macOS 运行器的 `JAVA_HOME_17_arm64` 报告为 Eclipse Adoptium Temurin `17.0.19+10` 之后，才会使用它；Ubuntu 安全证据则独立使用 `JAVA_HOME_17_X64`。两者都保留 `java -version`，且运行器出现偏差会阻塞发布。在任何 gem 安装或 Bundler 执行之前，已签名候选版本要求使用 MRI Ruby `3.4.10`（`RUBY_ENGINE=ruby`），配合 RubyGems `4.0.17`，并记录已解析的可执行文件与版本。商店上传使用从 RubyGems 下载的 Bundler `2.6.9`，在本地安装之前会针对其经评审的 SHA-256 进行验证，随后使用一个冻结的 Fastlane `2.235.0` 依赖图，其中每一个 gem 都具有一个锁文件校验和。

启动图标 PNG 是规范的 `mobile/assets/brand/pakperk_app_icon.svg` 的确定性输出结果。在安装了 `rsvg-convert` 与 ImageMagick 的 `magick` 之后，请在每次该 SVG 发生变化、且即将进行带品牌的发布之前，从仓库根目录重新生成它们：

```sh
./scripts/generate_mobile_icons.sh
```

请勿直接编辑生成的 PNG 文件。生成器会强制执行尺寸与不透明度要求；源代码测试要求 Android 旧版、圆形、自适应与主题化单色声明齐全，以及一份完整的不透明 iOS AppIcon 目录。

请从 `mobile/` 目录下，使用仓库锁定的依赖图运行：

```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter test

flutter build apk --debug --flavor dev --dart-define-from-file=config/dev.json
flutter build apk --debug --flavor staging --dart-define-from-file=config/staging.json
flutter build apk --debug --flavor prod --dart-define-from-file=config/prod.json

flutter build ios --simulator --debug --flavor dev --dart-define-from-file=config/dev.json
flutter build ios --simulator --debug --flavor staging --dart-define-from-file=config/staging.json
flutter build ios --simulator --debug --flavor prod --dart-define-from-file=config/prod.json
```

对于每一个预发布或生产环境产物，请检查已构建的产物本身，而不要只信任源代码配置：

```sh
dart run tool/verify_strict_artifact_assets.dart PATH_TO_APK_AAB_IPA_OR_APP
```

该验证器要求提供元数据、法务后备内容与原生启动器素材。它会按路径、内容哈希或未经批准的素材路径，拒绝每一个内置的、原型派生的素材，也会拒绝库存的 Flutter 启动器，或不完整的 Android 旧版/圆形/自适应/单色以及 iOS 打包图标集。开发构建变体有意保留经评审的、演示派生的后备内容，且不是严格产物。已签名产物的验证还额外要求 iOS 的 1024x1024 营销版本必须不透明。

每个构建变体配置中的 `PAKPERK_TERMS_DOCUMENT_VERSION` 与 `PAKPERK_COMMUNITY_GUIDELINES_DOCUMENT_VERSION`，是构建期与内置验收文档中发布标记之间的绑定。不匹配的构建配置会被拒绝；服务器公布了更新版本时，会一直禁用验收，直到已安装应用被更新为止；已签名发布证据会记录这两个确切版本。预发布环境与生产环境的签名，还要求这两个内置版本都等于公共边缘验证所使用的受保护 `PAKPERK_PUBLIC_DOCUMENT_VERSION`。

请在一个可用的模拟器上运行原生 iOS 保护测试（请替换目标 ID）：

```sh
xcodebuild test -quiet \
  -project ios/Runner.xcodeproj \
  -scheme dev \
  -configuration Debug-dev \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -disableAutomaticPackageResolution
```

该模拟器会验证递归的备份排除情况。当同一测试在物理设备上运行时，还会保留一项额外的文件保护类断言，因为模拟器文件系统不会公开 iOS 数据保护类。

## 受保护的签名输入

绝不能提交签名材料，也不能用调试/个人身份替代。

手动的 `signed-mobile-release` 工作流使用各自独立的全新运行器信任域。一个不含凭据的准备作业只接受经评审的、完整的小写 `main` 提交，会在任何候选可执行文件运行之前，发出并不可变地上传配置/证据绑定，并且绝不绑定受保护环境。独立的 Android 与 iOS 签名者作业，各自会重新下载并重新推导出那个确切的绑定，然后才公开各自的签名密钥族。一个全新的、不含凭据的作业会验证并组装这两个结果，形成规范的已签名候选版本与溯源信息。商店客户端的准备工作是单独不含凭据的；全新的、无需检出的 Android 与 iOS 上传作业，只接收各自的商店凭据，且一个始终运行的、不含凭据的收尾器，会在判定任何缺失或不成功的已请求上传为失败之前，保留封闭的、按平台划分的结果。请从 `main` 使用经评审的完整提交 SHA 进行派发；每一个来源边界都会拒绝确切检出或 `origin/main` 血统不匹配的情形。请配置以下这些环境密钥：

- Android 构建签名：`PAKPERK_ANDROID_KEYSTORE_BASE64`、`PAKPERK_ANDROID_STORE_PASSWORD`、`PAKPERK_ANDROID_KEY_ALIAS` 与 `PAKPERK_ANDROID_KEY_PASSWORD`。
- 用于预发布/生产环境关联文件的已安装 Play 身份：`PAKPERK_ANDROID_APP_SIGNING_SHA256`。
- Apple 签名：`PAKPERK_IOS_DISTRIBUTION_CERTIFICATE_BASE64`、`PAKPERK_IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`、`PAKPERK_IOS_PROVISIONING_PROFILE_BASE64`、`PAKPERK_DEVELOPMENT_TEAM` 与 `PAKPERK_IOS_PROVISIONING_PROFILE_SPECIFIER`。
- 商店上传，仅在 `upload_to_stores=true` 时需要：`PAKPERK_GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64`、`PAKPERK_APP_STORE_CONNECT_ISSUER_ID`、`PAKPERK_APP_STORE_CONNECT_KEY_ID` 与 `PAKPERK_APP_STORE_CONNECT_PRIVATE_KEY_BASE64`。

环境评审者必须独立读取每个商店中已上传的最高版本，并将其录入工作流输入。不含凭据的准备门禁要求已纳入版本控制的构建 `2` 大于这两个数值；当上传凭据被有意保留时，它无法推断私有的商店历史记录。该工作流始终会为两个平台签名。`upload_to_stores=true` 会同时请求 Play 内部上传与 TestFlight 上传；不存在可以悄悄省略某一项已请求结果的单平台捷径。

Android 发布构建要求以下全部内容：

- `PAKPERK_ANDROID_STORE_FILE`
- `PAKPERK_ANDROID_STORE_PASSWORD`
- `PAKPERK_ANDROID_KEY_ALIAS`
- `PAKPERK_ANDROID_KEY_PASSWORD`

一个未纳入版本控制的 `android/key.properties`（其中的键与 `android/key.properties.example` 中所示相同）是其本地等效物。当数值缺失或不完整时，Gradle 会使任何发布任务失败。请使用以下命令产出已签名候选版本：

```sh
flutter build appbundle --release --flavor dev --dart-define-from-file=config/dev.json
flutter build appbundle --release --flavor staging --dart-define-from-file=config/staging.json
flutter build appbundle --release --flavor prod --dart-define-from-file=config/prod.json
```

iOS 的 `Release-*` 配置会强制使用手动 Apple Distribution 签名，并要求由 CI 或已加入 gitignore 的 `ios/Flutter/LocalSigning.xcconfig` 提供受保护设置：

- `PAKPERK_DEVELOPMENT_TEAM`
- `CODE_SIGN_STYLE = Manual`
- `CODE_SIGN_IDENTITY = Apple Distribution`
- `PROVISIONING_PROFILE_SPECIFIER`

已纳入版本控制的示例文件只包含占位符。请按以下方式构建已签名候选版本：

```sh
flutter build ipa --release --flavor dev --dart-define-from-file=config/dev.json
flutter build ipa --release --flavor staging --dart-define-from-file=config/staging.json
flutter build ipa --release --flavor prod --dart-define-from-file=config/prod.json
```

在进行任一项上传之前，请将 `0.2.0+2` 与已上传到商店的最高版本及构建号进行比较。如果它并非严格更新，请递增已纳入版本控制的包版本；商店历史记录是外部信息，无法从 Git 中推断得出。

## 受保护的商店分阶段发布

已签名候选版本的工作流会在 Google Play 的 `internal` 轨道以及 TestFlight 处停止。公开的生产环境变更是一个独立的手动工作流 `protected-mobile-store-rollout`，绑定到固定的 `production-store` GitHub 环境。请为该环境配置所需的评审者，将其限定为 `main`，并提供上文列出的四项商店凭据，且只赋予推广确切 Play 发布版本与管理确切 App Store 版本所需的商店权限。一个 YAML 环境名称本身，并不能证明那些保护措施已被配置。

在公开商店凭据之前，受保护门禁必须使两个身份保持独立。一个不含凭据的引导过程，会检出在经评审的 `github.workflow_sha` 处的受信任工具；不可变的候选版本来源是仅数据输入，绝不能提供带凭据的可执行代码。该引导过程会产出一个不可变的商店客户端/控制闭包。该闭包中的每一个可执行文件，都具有一个工作流字面量 SHA-256，全新的 Android 与 iOS 变更作业会在使用之前验证它；这些作业不执行任何检出，不接收任何候选提供的可执行文件，清除 shell/语言/加载器/代理注入面，并且只公开各自平台自己的凭据。在任何候选产物被接受、或任何商店凭据被具体化之前，该引导过程会针对所提供的运行 ID 查询 GitHub 的 Actions API。它要求确切的仓库、`signed-mobile-release` 工作流路径、`workflow_dispatch` 事件、`main` 分支、来源 SHA、成功完成的状态与运行尝试，加上确切的、全部成功的八项作业构成：不含凭据的准备、隔离的 Android 与 iOS 签名者、`production signed candidate`、不含凭据的商店客户端引导、隔离的 Android 与 iOS 上传，以及不含凭据的已签名发布收尾器。随后，它要求一个未过期的、与尝试绑定的候选版本、交接与已签名发布结果产物，且各自具有不同的服务端签发 ID 与 SHA-256 摘要，并按不可变 ID 下载这些产物（摘要不匹配即视为错误）。确切的产物名称是 `pakperk-production-<version>-<build>-<sha>-<run-id>-<attempt>` 与 `pakperk-production-store-handoff-<version>-<build>-<sha>-<run-id>-<attempt>`，外加 `pakperk-production-store-outcome-<version>-<build>-<sha>-<run-id>-<attempt>`。只有在 Play 独立报告确切的版本代码，作为 `internal` 上的一个已完成单例，并返回服务端 bundle SHA-256（其与候选版本 AAB 相匹配）之后，交接文件才会被创建；App Store Connect 必须报告确切的 iOS 应用/构建/预发布版本关系（处于 `VALID` 处理状态），以及一个已完成的、单一的 `buildUpload`，其直接的 `build` 关系正是该 Build ID。其直接的 `assetFile` 必须是一个已完成的 `ASSET`，具有 UTI `com.apple.ipa`、候选版本 IPA 的确切字节大小，以及一个 `sourceFileChecksums.file` SHA-256（其等于候选版本 IPA 摘要）。该门禁会验证已认证的规范 Actions 记录、规范的候选版本、溯源信息与交接字节、候选版本与溯源信息的 `sha256:` 内容 ID、生产/严格构建变体、来源/版本/构建/应用身份、产物签名者绑定、仓库/工作流/作业/阶段、已签名发布的运行 ID 与运行尝试、本地的 AAB 与 IPA 哈希，以及两次权威的上传回读。该交接使用一个独立的 `store-handoff-v1:sha256:` 内容 ID。已签名发布的来源，必须等于其记录的工作流修订版本。一个没有对应已下载字节的、带类型的内容 ID，一个与其字面量工作流哈希不同的控制闭包，一个与 `github.workflow_sha` 不同的受信任引导检出，或者候选版本自身编写的代码接收到商店凭据，都会阻塞该门禁。

请先根据独立的商店历史记录，将每一个所选平台分类为一次更新，或其首个公开生产版本。请勿从 Git 中推断该状态。受保护的分阶段工作流仅适用于更新。对于一次正常更新：

1. 派发 `signed-mobile-release`（目标为 `production`），并设置 `upload_to_stores=true`。等待确切的 AAB 到达 Play 的 `internal`，并等待确切的 IPA/构建完成 TestFlight 处理。请保留其运行 ID、候选版本 ID、溯源信息 ID、已验证的商店交接 ID，以及受保护环境批准。没有已验证交接的成功上传过程，不具备分阶段发布资格。在每次发送二进制文件之前，该工作流都会立即将一份仅限所有者访问的尝试日志进行 fsync，该日志绑定到候选版本/溯源信息 ID、确切的 AAB 或 IPA 摘要与字节大小、目标地、运行尝试、来源、版本与构建。iOS 验证必须与那份发送前日志中的两个数值都相匹配，并保留 App Store 的 BuildUpload 与 BuildUploadFile 资源 ID。它会保留一个始终运行的 `mobile-store-upload-attempt-<run-id>-<attempt>` 产物。一份没有权威商店回读的日志会是 `unknown_reconcile_required`，即便上传客户端只是丢失了成功响应也是如此。
2. 将两个门户记录与已签名清单进行对账。针对这个确切构建，确认隐私、年龄分级、审核者流程、物理设备、性能、崩溃、法务与安全门禁。对于 Play，请识别一个符合条件的、此前已完成的生产发布版本，它能在本次更新期间一直充当回退版本；没有此前的回退版本，就意味着这是首次发布，此时禁止使用分阶段工作流。对于 iOS 的 `start`，请识别确切的此前公开版本；受信任的 App Store Connect 客户端必须恰好解析出一条匹配的 iOS 记录，该记录处于当前的 [`appVersionState`](https://developer.apple.com/documentation/appstoreconnectapi/appversionstate) `READY_FOR_DISTRIBUTION`，且确切的目标版本必须是 `PREPARE_FOR_SUBMISSION` 或 `READY_FOR_REVIEW`。没有匹配的此前公开版本，就意味着这是首次发布，分阶段工作流会拒绝执行。
3. 派发 `protected-mobile-store-rollout`（来自 `main`），操作为 `start`，附带确切的已签名发布身份（包括商店交接 ID）、平台范围、一个经脱敏的变更 ID，以及确认信息 `MUTATE_PRODUCTION_MOBILE_STORES`。Android 的 `start` 还需要 `android_previous_production_version_code`、预期比例 `none`，以及目标比例 `0.01`；iOS 的 `start` 需要 `ios_previous_public_version`。Android 只会将该版本代码从 `internal` 推广到百分之一的 `production` 分阶段发布。在确切的 App Store 更新预检之后，iOS 只会提交该 TestFlight 构建以供评审，并启用自动分阶段发布，随后要求确切的目标分阶段资源为 `INACTIVE`，之后才会记录提交成功。
4. 在已批准的观测窗口内，将 Android 保持在百分之一。在每一次 `advance` 之前，要求不存在任何阻塞发布的告警、确切候选版本的性能检查通过、至少 99.5% 的无崩溃会话率，以及发布负责人批准。经评审的 Android 比例为 `0.02`、`0.05`、`0.10`、`0.20` 与 `0.50`；只有 `complete` 操作才接受 `1.00`。Apple 的七天百分比推进是自动的，因此一个 iOS
`advance` 会观测并保留当前的分阶段发布状态，而不是强制设定一个百分比；`advance` 只有从确切的 `ACTIVE` 状态才会成功，而暂停/完成操作会在 API 变更操作之后被重新观测。Apple 在 [App Store Connect Help](https://developer.apple.com/help/app-store-connect/update-your-app/release-a-version-update-in-phases/) 中记录了分阶段更新的时间表与暂停行为。
5. 在每一次实时提交/PATCH/提交操作之前，立即写入并 `fsync` 一份仅限所有者访问的尝试日志，其中包含经评审的确切商店前置状态与 `unknown_reconcile_required`。只有权威的发送后检查，才可以将回执中的该分类替换为 `succeeded_verified`；发送开始之后出现的任何错误，都会一直保持为 `unknown_reconcile_required`，直到某位操作人员对门户进行对账为止。其他封闭分类包括 `not_attempted`、`rejected_pre_mutation` 与 `proven_not_committed`。在一次组合分阶段发布中，回执要求规范日志与发送后检查，就前置状态/资源身份进行交叉匹配。一个没有该日志、或包含重复/非有限/非规范 JSON 的结果，会一直保持为 `unknown_reconcile_required`。除非 Android 具有这个完全绑定日志的 `succeeded_verified` 状态，而不仅仅是一个成功的步骤退出状态，否则不会尝试 Apple 侧操作。请在工作流报告最终失败之前上传该回执，并在任何重试之前，对每一个未知状态进行对账。
6. 将每一个平台的结果，与各商店独立的审计/历史记录进行对账。每条内容寻址的记录都绑定了受信任的工具修订版本、候选版本来源、已签名的候选版本/溯源信息/交接文件、已认证的已签名发布运行/作业/产物 ID 与摘要、工作流修订版本、版本/构建、所请求的状态迁移、经脱敏的变更 ID、迁移前后状态，以及结果。一份工作流回执并不等同于商店批准、传播完成、崩溃证据，或环境评审者确实检查过门户的证明。

该分阶段发布工作流通过恰好四个信任域来强制执行这一顺序：一个不含凭据的引导过程、一个仅持有 Android 密钥的变更作业、一个仅持有 iOS 密钥的变更作业，以及一个不含凭据的 `always()` 收尾器。对于一次 `both` 状态迁移，iOS 作业会按不可变产物 ID 下载，并在任何 Apple 侧变更之前，将 Android 结果与日志验证为 `succeeded_verified`。每一个被选中的平台都会清理其密钥，并上传一个不可变结果，即使变更失败也是如此；随后收尾器会发出规范的 schema-v4 聚合结果，并在任何已选结果缺失或不成功时判定失败。该聚合结果绑定已认证的已签名运行、候选版本、溯源信息、交接文件、来源、版本/构建，以及所请求的状态迁移，包括确切的未选中与依赖跳过语义。GitHub 原始的 64 位十六进制上传产物摘要，只有在规范转换为 `sha256:<hex>` 并与服务端结果交叉核对之后，才会被保留为证据。

Google 与 Apple 都只允许针对更新使用分阶段/分批发布。Google 规定，首次生产发布会向所选国家/地区的 100% 发布，且不提供分阶段发布比例控制；请使用一个单独批准的首次 Play 发布流程，而不是 `protected-mobile-store-rollout`。请保留确切的无此前生产版本前置状态、候选版本/溯源信息与已签名发布绑定、国家/地区、评审/受管理发布状态、100% 发布操作与 UTC 时间、观测到的发布后状态/可用性、独立的门户审计，以及商店负责人批准。参见 [Play 的首次发布与更新流程](https://support.google.com/googleplay/android-developer/answer/9859348)。

Apple 的分阶段发布同样不适用于首个公开版本。对于首次 iOS 发布，请将 iOS 从分阶段工作流中排除，并使用一个单独批准的手动发布流程。请保留确切的无此前公开版本前置状态；候选版本/溯源信息与已签名发布绑定；应用/版本/构建与提交身份；提交时间与评审结果；所选的 `Manually release this version` 设置；发布之前的 `Pending Developer Release` 状态；负责人批准；确切的 `Release This Version` 操作/时间与观测到的发布后可用性，或有意扣留的状态与决定。该记录绝不能声称存在 Apple 分阶段状态。参见 [App Store 版本发布选项](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/select-an-app-store-version-release-option/)。当一个平台是更新、而另一个平台是首个公开版本时，请将受保护的分阶段工作流范围限定为仅适用于该更新，并将独立的首次发布证据保留在同一份发布台账中。Fastlane 经评审的商店操作，分别记录在 [Google Play](https://docs.fastlane.tools/actions/upload_to_play_store/) 与 [App Store](https://docs.fastlane.tools/actions/upload_to_app_store/) 的文档中。

一次完成前的 `halt`，对 Pakperk 自动化流程中的该候选版本而言是终态的。它会停止确切的 Play 分阶段更新，并暂停确切的 Apple 分阶段更新。已经收到 Android 更新的用户会保留该更新。Apple 明确允许任何用户在自动分发暂停期间，仍手动下载一次分阶段更新，因此暂停并不等同于完全切断曝光。在能够降低危害时，请使用独立的功能开关禁用受影响的后端创建/写入操作，保留安全的访客读取，记录手动下载所造成的残余曝光，并通过每一个已签名候选版本与受保护门禁，使用更高版本号的构建进行前向修复。

在一次 Android 更新达到 100% 之后，一个独立的、受保护的 Play 全面发布暂停操作，可以使确切的、符合条件的、此前已完成的版本，重新面向新用户与符合条件的用户可用，但它不会使已安装该问题版本的设备降级。请记录确切的此前回退版本，加上 Play 发布前/后状态与负责人决定。Google 不允许对某个轨道的首次发布执行此操作。不存在等效的 iOS 回滚；请使用功能开关与更高版本号的前向修复构建。参见 [Play 的全面发布暂停限制](https://support.google.com/googleplay/android-developer/answer/16285429)。服务端回滚使用兼容的镜像/功能开关，且绝不使用自动 SQL 降级。

## 关联与已签名产物门禁

该工作流会从两个本地已签名产物中，提取 Android 包/版本与 **上传密钥** 证书，并要求 AAB 与 APK 相匹配。该证书只是上传授权证据：在启用 Play App Signing 的情况下，Google 会使用一个不同的应用签名证书为已安装的 APK 签名。请从受保护的 Play Console 记录中读取其 SHA-256 指纹，并将其存储为 `PAKPERK_ANDROID_APP_SIGNING_SHA256`；绝不能在 `assetlinks.json` 中替换为上传密钥摘要。该工作流会从已签名的 IPA/描述文件中提取 Apple 团队/bundle 身份。请渲染受保护的关联文件，然后运行 `docs/mobile-app-links.md` 中所述的仓库验证器：

```sh
PAKPERK_RELEASE_ENV=production \
PAKPERK_ANDROID_PACKAGE=app.pakperk.pakperk \
PAKPERK_ANDROID_SHA256="$PLAY_APP_SIGNING_SHA256" \
PAKPERK_APPLE_TEAM_ID="$APPLE_TEAM_ID" \
PAKPERK_APPLE_BUNDLE_ID=app.pakperk.pakperk \
./scripts/verify_mobile_associations.sh \
  assetlinks.json apple-app-site-association
```

除非已部署的两个 `/.well-known/` URL 都直接返回 HTTP 200、使用 `application/json`、确切匹配那些已签名身份，并且能在物理设备上打开有效的 `/p/*` 与 `/arxiv/*` 链接，否则发布会被阻塞。重定向、通配符、陈旧指纹或占位符取值，都会导致该门禁失败。

请在证据中保留这两个 Android 身份：验证器的 `android_upload_sha256` 证明是哪一个受保护密钥产出了该候选版本，而 `android_play_app_signing_sha256` 证明的是已安装的 Play 应用，将向 Android 链接验证呈现哪一个证书。

已签名的 Android 证据还必须保留 `android_min_sdk=24`、`android_compile_sdk=36`、`android_target_sdk=36`、所选的 Build-Tools 版本、`android_apk_zip_alignment=16384`，以及按归档统计的原生库数量，加上 `android_native_elf_load_alignment=16384`。已签名的 Apple 证据必须保留所输出的 Xcode/SDK/最低 OS 数值、预置描述文件的过期时间、entitlement 结果，以及打包后的隐私清单结果。

### 受保护的移动端功能开关

已纳入版本控制的生产配置，会将全部 27 个受保护的移动端能力开关都保持关闭。已纳入版本控制的预发布测试夹具只启用了既定的账户/Library/评论组合，而 24 个与候选版本绑定的 To Read First、Plan 02 与 Plan 03 开关保持关闭，但它绝不会被原样用于一个已签名候选版本。受保护的证据 schema 会控制并绑定以下这既定的十七个开关：

- `PAKPERK_ACCOUNTS_ENABLED`
- `PAKPERK_LIBRARY_ENABLED`
- `PAKPERK_COMMENTS_ENABLED`
- `PAKPERK_PAPER_TITLE_SEARCH_ENABLED`
- `PAKPERK_LIBRARY_IMPORT_WRITES_ENABLED`
- `PAKPERK_READING_FEED_ENABLED`
- `PAKPERK_TO_READ_FIRST_ENFORCEMENT_ENABLED`
- `PAKPERK_LIBRARY_V2_ENABLED`
- `PAKPERK_RECOMMENDATIONS_ENABLED`
- `PAKPERK_RECOMMENDATION_EVENTS_ENABLED`
- `PAKPERK_SEARCH_LOOKUP_ENABLED`
- `PAKPERK_SEARCH_EXPLORE_ENABLED`
- `PAKPERK_SAVED_QUERIES_ENABLED`
- `PAKPERK_RESEARCH_PROFILES_ENABLED`
- `PAKPERK_READING_BRIEFS_ENABLED`
- `PAKPERK_SUBSCRIPTIONS_ENABLED`
- `PAKPERK_NOTIFICATIONS_ENABLED`

源配置还包含以下这十个默认关闭的 Plan 03 控制项：

- `PAKPERK_DEEP_READER_ENABLED`
- `PAKPERK_PAPER_PASSPORT_ENABLED`
- `PAKPERK_SEMANTIC_FACETS_ENABLED`
- `PAKPERK_DOCUMENT_VISUAL_OBJECTS_ENABLED`
- `PAKPERK_READING_CHECKPOINTS_ENABLED`
- `PAKPERK_ANNOTATIONS_ENABLED`
- `PAKPERK_EVIDENCE_CARDS_ENABLED`
- `PAKPERK_RESEARCH_MEMORY_ENABLED`
- `PAKPERK_VERSION_DIFF_ENABLED`
- `PAKPERK_ASSISTANT_V2_ENABLED`

Schema-v6 功能证据与 schema-v4 候选版本/溯源信息清单，现在绑定了这十个数值，且受保护的验收 schema v6 定义了十个 Plan 03 场景。这只是弥合了仓库技术契约方面的缺口。没有签名设备运行、隐私/法务批准、人工评审、实时模型结果、预发布金丝雀检测或发布批准被纳入检查范围；那些门禁仍为 `not_ready`，且启用了某个 Plan 03 数值的候选版本，在没有完整的受保护证据捆绑包时，不能被发布。

每个数值必须确切为 `true` 或 `false`；缺失的数值会解析为 `false`。除非账户功能也为 true，否则 Library、评论或标题搜索都无法启用。导入写入与阅读 Feed 都需要账户与 Library 两者，且 To Read First 的强制执行需要阅读 Feed。Library v2 需要账户与 Library。推荐与订阅需要账户、Library 与阅读 Feed。Explore 需要 Lookup；已保存查询需要账户与 Explore。研究资料需要账户，阅读简报需要阅读 Feed，通知需要订阅。推荐事件投递是独立门控的，不依赖任何推荐功能；运行时收集仍需要相应的同意。Deep Reader 需要账户、Library、阅读 Feed 与 To Read First 强制执行。Passport、语义分面、视觉对象、检查点、版本差异，以及 Assistant v2，都需要 Deep Reader。标注需要 Deep Reader，证据卡片需要标注，研究记忆需要证据卡片。请在受保护的 `staging` 与 `production` 环境上定义这些开关，在那里要求发布评审者/分支限制，并且只通过发布批准记录来更改它们。它们是非密钥变量，绝不能是派发输入或仓库默认值。该工作流会保留封闭的 schema-6 功能证据（包括全部 27 个布尔值与两个公共文档版本），存放于 `mobile-feature-flags.json` 中，并从同一份生成的配置构建两个平台。规范的 schema-4 候选版本与溯源信息清单，都各自绑定该文件的原始 SHA-256，加上确切的 24 个 To Read First、Plan 02 与 Plan 03 布尔值。组装器、两次签名者重新认证、每一次商店候选版本验证，以及不含凭据的收尾器，都会拒绝未知键、非布尔值、依赖违规、摘要不匹配，或候选版本/溯源信息不一致的情形。请保持独立控制的后端读取/写入/创建开关彼此兼容；移动端开关并不能授权某项服务端能力。

Library 提醒需要同时具备 `PAKPERK_LIBRARY_V2_ENABLED=true` 与独立的 `PAKPERK_NOTIFICATIONS_ENABLED=true` 能力。在通知关闭的情况下，Add Paper 会显示“Organize paper”（意为“整理论文”），Library 编辑器无法设置或替换提醒，且一个已存储的提醒仍然可见，并可为了回滚安全的清理而被清除。一个已到期的提醒会被展示为已完成，且只有通过阅读器下一次显式的 Library 保存操作才会被清除；关闭其通知绝不会编辑该队列。当通知开关关闭时，服务端的提醒工作处于休眠状态，且超过 24 小时逾期的提醒，在开关重新启用时也不会触发。

## 移动端验证通道

普通的 CI 与已签名候选版本工作流，会运行 `dart format`、`flutter analyze`，以及完整的 `flutter test` 套件。该套件包括无头的确定性生产测试框架。它会使用受控的测试夹具，证明本地状态机、缓存、待同步队列（outbox）、分页、策略与有界组件不变量；这不是物理设备或已部署服务的证据。

手动派发的 `mobile-device-integration` 工作流，会在一台明确选定的物理 Android 或 iOS 设备上，以 profile 模式运行同一个确定性测试框架。受保护的运行器会拒绝模拟器，并保留一份封闭的平台/OS 版本记录、至少 20 个引擎帧样本、一个 30 条记录的已缓存首页，加上六个确定性游标分页（合计恰好 200 条记录）、10 次生成的 Flutter 拖动与 10 次生成的 Flutter 快滑、一次基于文件的 500 论文/100 收藏的 SQLite 测量（包括其 WAL/SHM 文件），以及一份机器可读的范围文件。它绝不会上传原始的 Flutter 日志、设备 ID 或用户指定的设备名称；派发 ID 会在工作流输出中被遮盖。生成的 `WidgetTester` 手势会在所选设备上测试 Flutter 的指针、手势竞技场、滚动与页面提交路径，但在代表性网络条件下，这不能算作操作人员/OS 驱动的手势。其性能 JSON 被归类为一种测试夹具工作负载，绝不能被用作预发布 p95 或已签名候选版本的证据。请在附加运行器之前，为固定的 `mobile-device-verification` GitHub 环境配置所需的评审者与部署分支限制；仅有 YAML 名称并不能使一个环境受到保护。请只将确切的 Flutter 设备标识符，存储为该环境的 `PAKPERK_MOBILE_DEVICE_ID` 密钥；绝不能将其作为工作流派发输入传递，因为运行元数据会在日志遮盖之外保留输入内容。这是一项隐私/不留存控制，而不是凭据隔离边界：所选的 Flutter 命令与经评审的候选版本测试，必然会使用该标识符，且已经拥有对所连接物理设备的授权访问。请勿在此测试夹具通道中放置账户凭据或具有特权的设备管理令牌，也不要声称原始选择器对候选版本进程是隐藏的。派发还要求一个明确的、完整的小写 `source_revision`，其等于所选的 `main` 修订版本以及获取到的 `origin/main` 顶端，加上确切的确认短语。这可以防止一次通过的测试夹具探测，被附加到一个不同的来源修订版本上。

独立的、手动派发的 `protected mobile acceptance` 工作流，是实时预发布/设备通道的自动化入口。它只接受一个确切的 main 顶端来源修订版本，加上确切的 `sha256:` 候选版本与已签名发布溯源信息内容 ID，且只在受保护的 `mobile-device-verification` 环境中运行。其确切来源的检出是一个**仅数据**边界：由工作流拥有的、隔离的 Python 只读取有界的预发布配置与发布版本，且候选版本检出中的任何脚本、二进制文件、shell 启动文件、软件包钩子或其他可执行文件，都不得在受保护会话中运行。该工作流绝不会将候选版本派生的数据写入 `GITHUB_ENV`；它会为该作业以及带凭据的驱动步骤，两次将 `BASH_ENV` 与 `ENV` 都固定为 `/dev/null`，将 `PATH` 固定为 `/usr/bin:/bin`，并使用绝对的系统工具路径。

全部验收验证与打包工作，改为使用固定的、根拥有的 `/opt/pakperk/bin/pakperk-mobile-acceptance-validator.py`；实时设备控制则使用固定的、根拥有的 `/opt/pakperk/bin/pakperk-mobile-acceptance-driver`。在调用两者之前，该工作流要求 `/`、`/opt`、`/opt/pakperk` 与 `/opt/pakperk/bin` 都为根拥有，且对根以外不可写，随后通过一次不跟随符号链接的打开描述符、稳定的 inode 元数据、一个链接、根所有权、不可写模式，以及其受保护的 SHA-256，来验证每一个工具。该驱动程序还必须是可执行的。请配置以下这些确切的受保护环境变量：

- `PAKPERK_MOBILE_RUNNER_SESSION_ID`；
- `PAKPERK_MOBILE_ACCEPTANCE_VALIDATOR_SHA256`；
- `PAKPERK_MOBILE_ACCEPTANCE_DRIVER_SHA256`；
- `PAKPERK_ANDROID_SIGNER_SHA256`；
- `PAKPERK_IOS_TEAM_ID`；
- `PAKPERK_IOS_SIGNER_SHA256`。

对于任何 Android SDK 或其他运行器工具（如果位于 `/usr/bin:/bin` 之外），固定版本的验证器与驱动程序都必须使用绝对的、经评审的路径。

候选版本内容 ID 必须解析到一份规范的、schema-4 的、根拥有的清单，该清单位于 `/opt/pakperk/mobile-candidates/<digest>.json`。该清单绑定来源、预发布环境、应用版本/构建、严格构建变体、Android 与 iOS 安装产物哈希、确切的预发布应用 ID `app.pakperk.pakperk.staging`、签名者摘要、Apple 团队 ID，以及其溯源信息内容 ID。它还绑定 schema-6 移动端功能证据 SHA-256，以及四个 To Read First 开关、全部十个 Plan 02 开关与全部十个 Plan 03 开关的确切取值。schema-4 溯源信息必须独立解析到 `/opt/pakperk/mobile-release-provenance/<digest>.json` 之下，并确切地将 AAB、APK 与 IPA 的 SHA-256 数值，绑定到仓库 `ErrDivine/PakPerk`、工作流 `.github/workflows/mobile-release.yml`、作业 `signed-candidate`、经评审的工作流/来源 SHA、GitHub 运行 ID/尝试，以及阶段 `artifacts_verified`。它必须重复相同的移动端功能证据绑定；任何清单、摘要、schema 或布尔值不一致，都会失败并拒绝。坐标是作为数据从经评审的 `mobile/config/staging.json` 中读取的；不接受可变坐标以及包/bundle ID 变量。该来源步骤会拒绝重复/非有限 JSON、控制字符、无法往返转换或不安全的 HTTPS 坐标、符号链接/竞态变更，以及无效的严格构建变体或发布版本。它会写入一份独占的、仅限所有者访问的规范 schema-2 来源绑定，位于 `RUNNER_TEMP` 下，其中只包含确切的来源修订版本、环境、应用版本/构建、API 来源、应用链接来源、OIDC 签发方，以及 OIDC 客户端 ID。只有有界的 ASCII 版本/构建与绑定路径会成为步骤输出；两者都不会成为 shell 启动设置。带凭据的请求构建器会重新打开该绑定，并使用其坐标构建驱动请求。根拥有的验证器会独立重新加载它，要求其与候选版本/溯源信息的来源及版本/构建相匹配，并使用相同的坐标进行最终证据验证。

不含凭据的 `signed-candidate` 组装器作业，会产出规范的候选版本与溯源信息文件及其内容 ID，但它无法将它们安装到一个自托管运行器的受保护文件系统中。在完成经认证的产物获取之后，运行器管理员必须验证规范文件摘要，并以根所有权、一个链接、不含群组/所有人写权限的方式，将它们导入到固定的内容寻址根目录中。非 root 的运行器仍需要读取权限；由于这些清单只包含身份与哈希，不含凭据，因此模式 `0444` 是经评审的简单安装选择。这种经认证的根侧导入是一个外部运营边界，而不是由仓库工作流执行或证明的操作。

受保护的环境变量 `PAKPERK_MOBILE_RUNNER_SESSION_ID` 还必须指明一份规范的根拥有证明，位于 `/opt/pakperk/mobile-runner-sessions/<digest>.json`。其封闭 schema 绑定确切的整数 `schema: 1`、分类 `dedicated ephemeral mobile acceptance runner session`、来源修订版本、不透明的会话与主机身份哈希、运行器类别 `dedicated-macos-physical-mobile`、确切的 `dedicated: true` 与 `ephemeral: true` 开关、一个封闭的 `physical_identities` 映射（为每个必需角色各设一个不同的根作键承诺），以及一个不超过八小时的创建/过期时间间隔。相同的受保护父级、根所有者、一个链接、不可写、规范摘要规则均适用。该验证器会拒绝已过期的证明。创建并以根身份安装这份证明与固定版本的验证器/驱动程序、配置一个专用运行器、证明没有更早或不受信任的作业/进程共享该带凭据的会话、隔离主机与所连接设备，以及事后销毁其一次性状态，都仍是外部的、受保护的运行器管理员控制事项。仓库验证、`BASH_ENV`/`ENV` 固定、标签，以及一份声称的 `ephemeral: true` 证明，本身并不能证明运行器组访问权限、单次作业/JIT 注册、进程隔离或主机清理；请为发布保留平台/配置证据与管理员批准。

受保护的运行器会向根拥有的、按摘要固定的驱动程序，公开四个不同的已安装设备密钥：一台 Android 手势导航手机、一台 Android 三按钮手机、一台带主页指示器的 iPhone，以及一台物理键盘 iPad（它同时也是独立的第二同步安装设备）。测试账户与密码是环境密钥，绝不会被写入请求或证据中。

该驱动程序必须针对一次性的预发布账户，自动化以下每一条路径，并产出封闭的 `mobile-acceptance-evidence.json` 技术契约：

1. 全新安装经评审的已签名 APK 与 IPA，且此前无应用数据；保持访客身份，无需登录即可到达已缓存的 Read，阅读已发布的评论，并通过 OS 浏览器（而非内嵌网页视图）打开确切的规范 arXiv URL。
2. 从已填充的本地缓存冷启动，并收集缓存首个可读帧 p95、健康的本地初始化开场过渡时长，以及原生启动连续性测量结果。
3. 在受控的延迟与丢包条件下，纵向滑动至少 20 篇论文；记录空白卡片与顺序缓存命中情况。
4. 确认 Introduction 准备只会在显式的横向意图之后才开始。
5. 在 Read -> You -> Read 之间切换，并恢复确切的论文、阶段与偏移量。
6. 针对发布租户，完成系统浏览器 OIDC（使用 PKCE）。
7. 保存，终止/重新启动已安装的应用，重新连接，并验证同步情况。
8. 在设备 A 上保存，使 A 离线，将该保存收敛到一台独立安装的设备 B 上，在 B 上将其移除，重新连接 A，要求 A 收到该移除墓碑，并要求两边的投影都收敛为缺失状态。
9. 从一个访客发帖意图开始，完成发布租户登录，在一个不完整的资料上选择一个用户名，接受当前的条款与社区准则，使用一个稳定的客户端请求 ID 创建评论，向同一条评论重放，编辑，拒绝一次陈旧编辑，删除，并验证其在公开列表中确实消失。
10. 使用同一个幂等身份两次提交同一条评论举报，要求只产生一条规范的持久举报记录，然后屏蔽该作者，并确认立即且经服务端持久化的隐藏效果。
11. 使一个真实的访问令牌过期，验证一次成功的刷新，并继续原始操作。
12. 在一个独立的一次性会话中，使真实的刷新凭据在发布 IdP 处失效，强制刷新，要求转换为访客身份，使刷新记录不可读且账户所有的行不可访问，同时保留公开缓存与确切的论文/阶段/偏移量状态。
13. 为账户删除重新进行认证，并验证立即停用、会话撤销、提供商清理，以及删除状态路径。
14. 离线阅读并保存，终止该进程，在网络仍然禁用的情况下重新启动，在任何重新连接之前阅读已缓存的摘要，然后在连接恢复后，验证同一 UUID 的待同步队列（outbox）恢复以及一次服务端写操作。
15. 在减少动态效果的情况下重复冷/暖启动，并验证静止的、有界的过渡效果。
16. 使用严格已签名构建变体，并验证元数据/收藏/评论/原始 arXiv 链接保持可用，同时每一个缓存的派生回退都保持被遮蔽状态。
17. 在 Android 与 iOS 上，从冷启动、暖启动与已在运行状态出发，测试确切的、来源绑定的预发布应用链接来源所部署的 `/p/*` 与 `/arxiv/*` 应用/通用链接，要求 Abstract 能够打开，并证明恶意来源会失败并拒绝、回退到 Read，且不发起论文请求。
18. 在已签名的已安装设备上，证明 Android 备份已禁用，且一次提取不会恢复任何应用数据；证明 iOS 备份排除与 `completeUntilFirstUserAuthentication` 保护；并验证设备绑定的、
不可同步的安全凭据属性，且不持久化任何访问凭据。
19. 测量一个已填充的签名设备数据库，加上 WAL/SHM 文件，并要求至多 500 条已缓存论文记录，以及至多 64 MiB 的物理缓存存储，同时至少一个已收藏论文的固定项保持完整。
20. 在 Android 与 iOS 上测试浅色与深色外观，保留阅读器状态，且不存在无法阅读、被裁剪或不可见的关键操作。
21. 在 Android 手势、Android 三按钮与 iPhone 主页指示器模式下，测试根导航安全区域与系统返回操作。
22. 在 Android 与 iPad 上测试物理键盘的 Tab、Shift-Tab、Enter 与 Escape 路径，包括 200% 文本与最小目标覆盖率。
23. 在 Android 与 iOS 上，使用一个非空的 To Read 队列登录，验证本地与服务端的队列权威性以及 FIFO 分页，然后移除每一个条目，并在请求或发布推荐之前，要求服务端确认队列权威性为空；已入队的论文绝不能作为推荐出现。
24. 在两个平台上，针对待处理保存、待处理论文导入、未知/离线连接状态、同步重置以及待处理的最终移除，重复该边界测试。每一种状态都必须在队列/检查/完成权威性方面失败并拒绝，且在最终服务端移除确认之前，不发起推荐请求或解锁。
25. 在一次 Feed 请求进行期间切换一次性账户，并证明不存在任何旧账户可见帧或旧生成代次的发布内容。在 Android 与 iOS 上测试一次预发布服务端策略的 shadow -> strict -> shadow 回滚周期，在每一次界面切换之前重新验证队列权威性。
26. 从 Read 与 To Read 两处（在 Android 与 iOS 上），通过裸 arXiv ID、规范的 arXiv URL 与标题添加论文。确切的输入必须绕过标题搜索；而标题搜索本身必须等待其防抖延迟，并要求显式选择候选项。进度是可访问的，占位符绝不会进入规范的 Drift，且规范结果的应用不会触发第二次待同步队列（outbox）保存。
27. 在两个平台上测试有歧义的标题结果、可重试的搜索/导入错误、不可重试的输入错误，以及导入期间的账户范围变更。重试必须复用确切的操作 ID，并收敛到一次规范保存，不产生任何跨账户结果；保留的证据中不得包含任何原始标题、URL、令牌或账户身份。
28. 在 Android 与 iOS 上，从 Read 打开 Plan 02 的 Search 目的地；测试规范化的 Lookup、有界的仅元数据建议、诊断性 Explore，以及已认证的已保存查询重放。打开结果绝不能变更 Library，且切换账户时必须确保不会暴露此前账户的已保存查询。
29. 在两个平台上，验证个性化功能默认从关闭开始；显式的、反馈派生的与推断得出的兴趣，保持分别标注；已存储的模式/简报大小设置能够持久化；导出/重置行为保留队列权威性；且切换账户不会暴露此前的资料行。请在大字号文本与减少动态效果条件下测试这些控件。
30. 对于一个增强型推荐批次，打开一个封闭的、有证据支持的
`Why this?` 说明，并使用幂等重试测试相关、不相关与忽略反馈。仅限近期的回退绝不能暴露 Why 操作，非活跃种子只可以出现在历史原因中，被排除的条目必须保持缺失状态，且反馈绝不能推进 Library 修订版本。该表单必须只展示已记录的候选来源、行为是否被采纳、相关性/探索/多样性角色，以及历史种子的存在情况（且不暴露种子标识符），然后直接链接到调整推荐与个性化隐私控件。
31. 在两个平台上创建并恢复一份阅读简报，涵盖已存储/默认与显式的大小/模式选择、重新启动后的进度、可访问的进度，以及切换账户。在仍有活跃队列条目的情况下，简报进度、完成或耗尽绝不能对 Library 状态执行变更操作，也不能解锁推荐。
32. 在两个平台上，针对一个活跃队列、活跃论文的选择加入、静默时段、每日预算、全局暂停/静音、一份有界的空队列摘要、已读/关闭、可安全重放的调度，以及切换账户，测试已认证的订阅与应用内通知。要求零条不安全、重复、跨账户、推送或邮件投递。
33. 在 Android 与 iOS 上，提交进入 Deep Reader 的意图，遍历至少四个有界区块分页，在 Skim/Read/Inspect 之间切换而不丢失位置，打开来源定位符，在一个定义表单之后恢复，并证明不存在提交意图之前的准备、陈旧生成代次的渲染，或捏造的解析器回退。
34. 在两个平台上测试 Passport，至少包含三个已填充字段、不同的支持/推断/冲突/未找到状态、确切的证据导航，以及可见的论文版本。每一个已填充字段都需要证据，且任何 Passport 操作都不得对 Library 状态执行变更操作。
35. 只在其显式开关启用时，才在两个平台上测试语义分面与定义。打开确切的出现位置，在定义关闭时保留选择/位置，如实展示不可用的定义，且不创建任何自动 Feed 或 Library 插入。
36. 在两个平台上，针对确切的生成代次测试图、表与公式卡片。打开每一个来源定位符，验证表格/纯文本与公式的无障碍回退（包括在 SmartMath 输入修复与消毒功能均禁用时，针对格式错误的 LaTeX 或不受支持的 MathML 提供可选的确切来源），保留视觉证据定位符，并要求零个错误素材或未经授权的衍生内容暴露。测试从确切的原子化生成代次范围集合中进行的小、中、大规模选择，并验证有界响应、清单/文件校验和绑定，以及特定变体的缓存身份；缺失或无效的素材必须保留说明文字与原始页面访问权限。
37. 在两个平台上，跨进程重启与模式变更保存并恢复仅位置的检查点。检查点与文档末尾必须导致零次 Library 修订版本或队列资格变更；只有显式的“标记为已评审”操作，才可以执行预期的 Library 变更操作。
38. 在 Android 加上独立的 iPad 安装设备上，创建离线高亮/笔记，在进程死亡后存活，幂等地重放，进行同步，在并发冲突时保留两个版本正文，展示重排不确定性，并保留证据锚点。该封闭场景还要求一次确切的导出/导入往返、零条私有正文遥测，以及零条跨账户研究行。导入器已实现，但只有一次受保护的运行才能满足这些设备断言。
39. 在 Android 与 iOS 上，测试显式的记忆创建、审阅、延后、退役、来源返回、重新启动，以及切换账户。已生成但未选中的内容绝不能成为记忆，已退役的条目必须保持退役状态，且记忆相关操作绝不能变更 Library 状态或插入自动 Feed 条目。
40. 在 Android 与 iOS 上比较至少两对版本，打开确切保留的新旧来源，识别已变更的章节/对象，使未变更的区块不出现在差异中，并呈现标注锚点状态。不确定或孤立的标注绝不能被静默移动，且差异导航绝不能对 Library 状态执行变更操作。
41. 在每个平台上测试至少四个明确限定范围的 Assistant v2 问题。拒绝捏造的证据 ID 与陈旧的生成代次，将提示词注入视为来源数据处理，针对实质性论断要求提供证据，在不受支持时弃权，打开确切的证据来源，不产生任何离线的无依据回答，且不保留任何私有的提示词/回答遥测字段。
42. 在 Android、iPhone 与键盘 iPad 上，证明自动的下一篇论文导航只使用活跃队列，在最后一项时会等待服务端确认为空，且在离线时会失败并拒绝。往返测试显式的 Connections 与 Memory 分支且不插入 Feed 内容，在有界加载窗口内遍历至少 20 页大型文档，并验证 200% 文本、目标尺寸与手势仲裁。

根拥有的验证器要求确切的来源、应用版本/构建、候选版本、验证器与驱动程序摘要；已签名发布溯源信息、规范来源绑定与临时运行器会话绑定；预发布的 API/应用链接/OIDC/客户端坐标；四个有序的物理设备角色；不同的安装与物理身份哈希；经脱敏的硬件型号与 OS 版本；以及以上全部 42 个有序的 schema-v6 场景。一个场景只有在具备其确切的设备角色分配、确切的有序断言 ID 列表（总计 317 个标记）以及闭合的整数阈值/相等性指标（总计 254 条规则）时才会通过；一个泛泛的正数计数是不被接受的。该驱动请求携带 schema `6`、那些确切的计数，以及规范的有序角色/断言/指标规则技术契约 SHA-256 `7483820afc6b2111f4886177dd120e72ab8ca47164757ca1eda9e10f64d70ad5`。固定版本的驱动程序必须拒绝一份不同的技术契约，而不是转换或接受一个更旧的 schema。该请求还携带候选版本的封闭移动端功能证据绑定。保留的证据会重复该绑定，且验证器要求其与根导入的候选版本及溯源信息清单都确切匹配。受保护的 schema-v6 验收还要求嵌套的 schema-v6 移动端功能证据的 24 个绑定数值确切为 `true`；一个已禁用的开关无法为此受保护运行产出有效证据，因此会在根拥有的驱动程序启动之前就失败。这 42 个物理场景是一份封闭的基线，涵盖阅读器、身份、安全、设备、To Read First、Add Paper、Plan 02 的 Search/Profile/Why/Brief/Alerts，以及一份十场景的 Plan 03 技术契约。这五个 Plan 02 场景与十个 Plan 03 场景，并不能替代自动化的后端/移动端套件，也不能宣称测试了每一种功能排列；单独的受保护预发布、隐私、分阶段发布、可观测性与外部负责人门禁仍然适用。更改已纳入版本控制的技术契约只是仓库证据。在已更新的根拥有驱动程序为确切的已签名候选版本产出一份完整通过的 schema-v6 产物之前，没有任何场景算作生产环境通过。

仓库现在带有 Plan 03 的候选版本/溯源信息/功能证据/驱动程序/验证器技术契约，但尚未有确切的签名设备运行通过它。标注导入往返以及确切的、按生成代次绑定的差异分页导航，都已作为仓库技术契约实现。经授权的响应式派生生成、剥离辅助元数据的重新编码、原子化的清单/哈希绑定变体发布、已认证的变体投递、感知变体的移动端缓存，以及确切来源、不修复的、经维护的公式渲染，也都已具备。生成的无障碍描述仍然是按能力门控的，且尚未有确切的签名设备运行通过。因此，每一个 Plan 03 签名设备与移动端发布门禁，都仍为 `not_ready`，且每一个已纳入版本控制的 Plan 03 移动端开关都仍为 false。尤其是，`cold_cache_launch.metrics` 必须包含确切的整数键 `populated_cache_records`、`cached_first_readable_frame_p95_ms` 与 `opening_transition_ms`。后两者必须为正数，且分别不超过 1,500 毫秒与 700 毫秒；旧版的单样本 `first_readable_frame_ms` 键会被拒绝。受保护的驱动请求携带那两条相同的确切范围规则，因此按摘要固定的生成方与验证器共享同一份失败即关闭的技术契约。每一个 Android 角色都必须标识一台安装了溯源信息绑定的 APK 的设备；每一个 iOS 角色都必须标识溯源信息绑定的 IPA。每台设备还必须为其平台回显确切的预发布应用、签名者与 Apple 团队绑定。

对于每一个角色，该驱动程序都会推导出一个特定于本次运行的 `device_identity_hash`，且不保留序列号或其他原始标识符。它首先将一个稳定密钥计算为 `HMAC-SHA256(root_owned_device_identity_key, platform || NUL || raw_id)`，然后将该稳定密钥作为该角色的根证明承诺，并计算 `HMAC-SHA256(run_challenge, stable_secret)` 用作证据。验证器会自行执行第二次计算，并绝不会将稳定承诺复制到请求绑定或保留证据中。由于角色本身并不参与该推导过程，将同一台物理设备复用于两个角色会产生相同的承诺，并因此被拒绝。公开的挑战值会使保留的哈希在各次运行之间发生变化，而根拥有的密钥则能防止其变成一个直接的序列号预言机。证据仍会有意标识运行会话，因此在某个证明被复用时，仍可被关联起来。全部四个哈希与全部四个安装哈希必须各不相同。原始设备标识符只保留在受保护的进程环境中，且绝不能出现在请求、证据、日志或产物中。通过这些标记，并不能替代独立的、可问责的视觉、无障碍、移动端平台、身份、隐私与发布批准。

证据 schema v6 还绑定到一个全新的密码学挑战值、GitHub 运行 ID 与尝试次数，以及整秒的 UTC 生效时间下限。验证会将运行限制在六小时以内，拒绝陈旧/重放的完成状态、重复或非规范的 JSON、非有限数值、多余字段、形似凭据的字符串、符号链接、超大证据、部分场景，以及失败路径。该验证器会按顺序打包确切的、已读取的规范证据，加上规范的 `mobile-acceptance-tooling.json` 与 `SHA256SUMS`，通过直接以独占打开语义创建最终归档来完成。该工具清单具有确切的 schema `1`、分类 `protected mobile acceptance tooling`，以及包含固定文件名与受保护 SHA-256 数值的封闭验证器/驱动程序对象。`SHA256SUMS` 涵盖证据与工具这两类成员。该验证器会检查最终的 inode、所有者、模式 `0400`、链接计数、大小与 SHA-256；在上传之前，它会立即重新打开该归档，要求封闭的成员顺序与元数据，验证两个校验和，并将两个已归档的工具摘要与受保护的预期变量进行比对。本地 tar 摘要会被绑定到产物名称中；最后一步还要求上传操作独立的产物容器摘要。仅限所有者访问的驱动程序日志会被捕获并丢弃，而设备序列号、凭据、用户名以及评论/查询文本则会被排除。

一位发布负责人必须为确切的、已安装的已签名候选版本派发此工作流，并附加其不可变产物以及受保护环境批准。已纳入版本控制的编排与验证器并不能证明根安装的工具、隔离的运行器会话、预发布租户、账户或设备确实可用；一次未派发的工作流、仓库测试、模拟器或操作人员陈述都无法完成这一通道。

## 遥测与发布候选版本门禁

生产遥测只使用确切的 HTTPS `/v1/logs` OTLP 端点。移动端导出器不会发送任何 Authorization 请求头、cookie、用户/设备/会话 ID、论文 ID、用户名、内容、令牌、原始异常消息或堆栈。事件与属性遵循一个封闭的词表；负载至多 16 KiB，请求具有两秒截止时间，响应会在不缓冲的情况下被取消，至多两个导出处于进行中状态，且饱和/失败会直接丢弃数据，不进行排队或重试。

全局错误捕获只会向该导出器发送一个有界的错误类别。它会以经脱敏的细节委托框架层展示，绝不会将原始异常或堆栈传递给此前的平台处理程序。一个接受该有界类别的此前处理程序，会保留对该失败的所有权。否则，原始引擎回调只会被标记为已处理足够短的时间，以防止其原始参数被打印出来；应用会在同一个错误区域中，以 `StackTrace.empty` 抛出该有界类别，且该替代异常仍然真正未被捕获。区域与预捕获引导阶段的失败，使用相同的替代方式。请勿吞掉该替代异常：这样做可能使进程处于损坏状态，并使无崩溃证据产生误导。Apple/Google 诊断可以按平台政策保留一条原生崩溃记录，但绝不能从这一边界接收应用异常消息、令牌、内容值或 Dart 堆栈。请在发布之前，检查确切已签名产物的平台诊断与应用商店披露信息。

在证据捆绑包包含以下内容之前，请勿宣布某个发布候选版本已通过：

- 至少 20 个已缓存首个可读帧样本，在指定的参考设备与预发布环境上，p95 不超过 1.5 秒；
- 至少 20 个开场过渡样本，在本地初始化健康时，所测得的过渡时长不超过 700 毫秒；
- 在至少 20 次暖启动的顺序下一篇论文请求中，没有空白卡片，且至少 95% 的缓存命中率；
- 至少 20 个帧样本，以及一个已记录的样本窗口；
- 针对确切的已签名候选版本，至少 99.5% 的无崩溃会话率；
- 已测得的样本/窗口、采集器查询或商店报告、构建号、设备/OS 矩阵，以及批准者。

请使用由分阶段发布分发/诊断系统提供的、经隐私评审的聚合崩溃分母。请勿为了人为制造这一指标，而向移动端遥测中添加持久化的设备、账户或会话标识符。除非一个已签名的 TestFlight/封闭 Play 候选版本已具备至少 24 小时的观测窗口，以及来自两个绑定商店诊断来源、合计 200 个聚合确切候选版本会话，且该窗口已被发布负责人批准为具有代表性，否则崩溃门禁就**未通过**。这些是 Production v0.0 的最低要求；负责人可以要求更长的窗口或更大的分母，但不得在清单中豁免这些要求。

## 外部发布阻塞项

仓库检查无法完成以下这些操作。发布负责人必须在启用生产开关之前，为每一项附加证据：

- 受保护的 Android 与 Apple 签名凭据，以及成功签名的开发/预发布/生产产物；
- 已注册的 OIDC 客户端/重定向以及生产环境的已关联域名；
- 已部署的关联与法务/支持 URL，附带受监控的联系方式详情；
- 实时的 OTLP 采集器保留与脱敏验证；
- 一个兼容的、根拥有的 schema-v6 验收验证器与驱动程序，安装在 `/opt/pakperk/bin` 之下，附带其确切的受保护环境摘要变量、当前的根拥有运行器会话证明，以及全部所需的物理设备/账户密钥；
- 物理设备账户、评论/举报/屏蔽、删除、严格内容、离线、回调、深层链接、To Read First 与 Add Paper 的 QA。受保护的预发布演练还需要一种经批准的方式，来驱动并观测 shadow-to-strict-to-shadow 服务端策略周期，且不向候选版本检出暴露控制平面凭据；
- 审核者账户与商店评审备注，且不含真实用户数据；
- TestFlight 与封闭的 Play 轨道上传、当前的 App Privacy/Data Safety 与年龄分级表单、单调递增的商店版本、评审状态，以及上文所定义的、受保护的更新状态迁移证据或单独批准的首次发布证据两者之一。更新证据包括：受信任工具与候选版本来源的分离、符合条件的 Play 回退版本、确切的、按平台划分的前后状态与无条件结果、部分成功对账、Apple 手动下载曝光，以及任何仅限 Android 的全面发布暂停；首次发布证据包括确切的 Play 100% 状态与 Apple 手动发布状态/操作。Apple 的[更新版年龄分级问卷](https://developer.apple.com/news/upcoming-requirements/?id=07242025a)，自 31 年 2026 月起已要求作答；
- 已验证的 Android 开发者身份与包/签名密钥注册。[区域执行将于 30 年 2026 月开始](https://developer.android.com/developer-verification/guides)，适用于巴西、印度尼西亚、新加坡与泰国的参与商店，随后会有更广泛的分阶段发布；
- 由运营团队负责的预发布性能/崩溃证据，加上备份恢复/删除重放证据。

请勿仅凭源代码构建或模拟器测试，就将某个外部项目标记为已完成。
