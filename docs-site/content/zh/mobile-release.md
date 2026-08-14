# 移动端发布流程

这是 Pakperk 移动端 `0.2.0+2` 的发布协议。生产版本 v0.0 是一个里程碑名称；它不允许降低包或商店构建版本。

## 艺术品身份矩阵

| 环境 | Android 应用程序 ID | iOS 打包 ID | OIDC 回调 | App-link 主机 |
| --- | --- | --- | --- | --- |
| development | `app.pakperk.pakperk.dev` | `app.pakperk.pakperk.dev` | `pakperk-auth-dev` | 仅限回环 HTTP |
| staging | `app.pakperk.pakperk.staging` | `app.pakperk.pakperk.staging` | `pakperk-auth-staging` | `staging.pakperk.app` |
| production | `app.pakperk.pakperk` | `app.pakperk.pakperk` | `pakperk-auth` | `pakperk.app` |

调试构建不能默认使用生产环境。测试和生产环境仅允许 HTTPS。所有变体的 Android 备份/恢复功能均被禁用。iOS 排除 Documents、Preferences、Application Support、SQLite 附加文件及其子项的备份，并在设备上应用 `completeUntilFirstUserAuthentication` 数据保护。

## 当前平台提交协议

最终的构建产物，而不是 Gradle 或 Xcode 默认值，必须证明这些值：

- Android 使用最低 API 24 和编译/目标 API 36。Google Play 要求新手机/平板应用和更新从 [2026 年 8 月 31 日](https://developer.android.com/google/play/requirements/target-sdk) 开始使用 Android 16/API 36。
- Android 原生编译固定为 NDK `28.2.13676358`；更改此输入需要重新构建并重新运行档案对齐检查。
- 因为 Pakperk 包含原生共享库，因此 APK 和 AAB 必须具有每个 `arm64-v8a` 和存在 `x86_64` ELF `LOAD` 段，且对齐至少为 16 KiB。APK 还必须通过 `zipalign -c -P 16 -v 4`。Google Play 的 [16 KiB 兼容性要求](https://developer.android.com/guide/practices/page-sizes) 自 2025 年 11 月 1 日起适用于新应用和更新，这些应用和更新的目标 API 为 35 或更高。
- iOS 使用部署目标 15.0。Apple 将 iOS 15 识别为 Xcode 26 支持的 App Store 上传范围的下限，如其 [Xcode 系统要求](https://developer.apple.com/xcode/system-requirements) 所述。自 [2026 年 4 月 28 日](https://developer.apple.com/news/upcoming-requirements/?id=02032026a) 起，上传的 iOS 应用必须使用 Xcode 26 或更高版本和 iOS 26 SDK 或更高版本构建。

`verify_android_release_artifacts.sh` 会发出并要求最低 24、编译/目标 36、一个数值上最新的完整 Build-Tools 安装、16 KiB APK ZIP 对齐和 16 KiB 原生 ELF 对齐。它拒绝调试构建/仅测试归档、Android 调试证书、多个 APK 签名者和缺少 v2 和 v3/v3.1 签名的 APK。其 AAB 检查仅在临时信任库中信任提取的签名者，因此接受正常的自签名 Android 上传证书，而严格的 JAR 完整性、完整的签名、现代算法和 APK/AAB 指纹一致性仍然是强制性的。

`verify_ios_release_artifact.sh` 会从已签名的 IPA 中发出 Xcode、SDK、平台和最低 OS 元数据，并要求 Xcode/iOS SDK 26+、正好 iOS 15.0、未过期的 App Store 配置文件（不是开发、ad hoc 或企业）、配置文件授权的签名权限、精确的应用程序标识符、环境的精确 ATS 策略和源等效、跟踪为假的应用隐私清单。本地模拟器构建目前记录 Xcode 26.6 (`DTXcode=2660`) 和 SDK 26.5；这只是源代码/模拟器证据，不是已签名的 `iphoneos` IPA 门或 App Store 接受的替代品。

## 可重复的检查和构建

使用 Flutter `3.44.8`，框架版本为 `058e0af2c2b57e369d905a03ac9748b0ebf543c6`，其捆绑的 Dart `3.12.2`，在发布工作流中依赖解析之前检查的精确稳定 SDK 身份和完整的本地检查。不同的本地 SDK 仅作为开发证据；当其解析的 SDK 与工作流固定值不同时，发布元数据生成会失败。

原生 Android 依赖解析和发布构建使用托管 arm64 macOS 运行器的 `JAVA_HOME_17_arm64`，仅在它报告 Eclipse Adoptium Temurin `17.0.19+10` 后。Ubuntu 安全证据独立使用 `JAVA_HOME_17_X64`。两者都保留 `java -version`，运行器漂移会阻止发布。在任何 gem 安装或 Bundler 执行之前，已签名的候选者需要 MRI Ruby `3.4.10` (`RUBY_ENGINE=ruby`) 和 RubyGems `4.0.17`，并记录解析的可执行文件和版本。商店上传使用从 RubyGems 下载的 Bundler `2.6.9`，在本地安装前验证其审查的 SHA-256，然后使用冻结的 Fastlane `2.235.0` 图，其中每个 gem 都有锁定文件校验和。

启动器 PNG 是 canonical `mobile/assets/brand/pakperk_app_icon.svg` 的确定性输出。安装 `rsvg-convert` 和 ImageMagick 的 `magick` 后，每当 SVG 改变时，从仓库根目录重新生成它们：

```sh
./scripts/generate_mobile_icons.sh
```

不要直接编辑生成的 PNG。生成器强制执行尺寸和透明度；源测试需要 Android 旧版、圆形、自适应和主题化单色声明以及完整的 iOS AppIcon 目录。

从 `mobile/` 运行，使用仓库锁定的依赖图：

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

对于每个测试或生产制品，检查构建的制品而不是信任源配置：

```sh
dart run tool/verify_strict_artifact_assets.dart PATH_TO_APK_AAB_IPA_OR_APP
```

验证器需要元数据、法律回退和原生启动器资产。它拒绝所有通过路径、内容哈希或未经批准的资产路径的捆绑原型衍生资产，以及标准 Flutter 启动器或不完整的 Android 旧版/圆形/自适应/单色和 iOS 打包图标集。开发变体故意保留经过审查的演示衍生回退，并不是严格的制品。已签名制品验证还要求 iOS 1024x1024 市场版本为不透明。

`PAKPERK_TERMS_DOCUMENT_VERSION` 和 `PAKPERK_COMMUNITY_GUIDELINES_DOCUMENT_VERSION` 在每个变体配置中是构建时绑定到捆绑接受文档中的发布标记。不匹配的构建配置会被拒绝，服务器广告较新版本会禁用接受，直到安装了更新的应用，已签名的发布证据记录两个精确版本。测试和生产签名还要求捆绑版本等于公共边缘验证使用的受保护 `PAKPERK_PUBLIC_DOCUMENT_VERSION`。

在可用的模拟器上运行原生 iOS 保护测试（替换目标 ID）：

```sh
xcodebuild test -quiet \
  -project ios/Runner.xcodeproj \
  -scheme dev \
  -configuration Debug-dev \
  -destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
  -disableAutomaticPackageResolution
```

模拟器验证递归备份排除。当在物理设备上运行时，相同的测试保留额外的文件保护类断言，因为模拟器文件系统不暴露 iOS 数据保护类。

## 受保护的签名输入

永远不要提交签名材料或替换调试/个人身份。

手动 `signed-mobile-release` 工作流使用独立的新运行器信任域。无凭证准备作业仅接受经过审查的完整小写 `main` 提交，发出并不可变地上传配置/证据绑定，而在任何候选可执行文件运行之前，永不绑定受保护环境。独立的 Android 和 iOS 签名作业各自重新下载并重新推导该精确绑定，然后仅暴露各自的签名密钥家族。一个新鲜的无凭证作业验证并组装两个结果，形成规范的已签名候选和来源。商店客户端准备是单独无凭证的；新鲜的无检出 Android 和 iOS 上传作业仅接收各自的商店凭证，且一个始终运行的无凭证最终器在失败任何缺失或未成功请求的上传前保留每个平台的关闭结果。从 `main` 分支使用经过审查的完整提交 SHA；每个源边界拒绝精确检出或 `origin/main` 祖先不匹配。配置这些环境秘密：

- Android 构建签名：`PAKPERK_ANDROID_KEYSTORE_BASE64`、`PAKPERK_ANDROID_STORE_PASSWORD`、`PAKPERK_ANDROID_KEY_ALIAS` 和 `PAKPERK_ANDROID_KEY_PASSWORD`。
- 已安装的 Play 身份用于测试/生产关联文件：`PAKPERK_ANDROID_APP_SIGNING_SHA256`。
- 苹果签名：`PAKPERK_IOS_DISTRIBUTION_CERTIFICATE_BASE64`、`PAKPERK_IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`、`PAKPERK_IOS_PROVISIONING_PROFILE_BASE64`、`PAKPERK_DEVELOPMENT_TEAM` 和 `PAKPERK_IOS_PROVISIONING_PROFILE_SPECIFIER`。
- 店铺上传，仅在 `upload_to_stores=true` 时需要：`PAKPERK_GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_BASE64`、`PAKPERK_APP_STORE_CONNECT_ISSUER_ID`、`PAKPERK_APP_STORE_CONNECT_KEY_ID` 和 `PAKPERK_APP_STORE_CONNECT_PRIVATE_KEY_BASE64`。

环境审查者必须独立阅读每个商店中最高上传的构建，并将其输入工作流。无凭证准备门要求检查入的构建 `2` 大于两个值；它不能在上传凭证被有意隐瞒时推断私有商店历史。工作流始终签署两个平台。`upload_to_stores=true` 请求 Play 内部和 TestFlight 上传；没有单平台快捷方式可以静默省略一个请求的结果。

Android 发布构建需要以下所有内容：

- `PAKPERK_ANDROID_STORE_FILE`
- `PAKPERK_ANDROID_STORE_PASSWORD`
- `PAKPERK_ANDROID_KEY_ALIAS`
- `PAKPERK_ANDROID_KEY_PASSWORD`

一个未跟踪的 `android/key.properties`，其中包含 `android/key.properties.example` 中显示的密钥，是本地等价物。Gradle 在值缺失或部分时会失败任何发布任务。使用以下命令生成已签名的候选：

```sh
flutter build appbundle --release --flavor dev --dart-define-from-file=config/dev.json
flutter build appbundle --release --flavor staging --dart-define-from-file=config/staging.json
flutter build appbundle --release --flavor prod --dart-define-from-file=config/prod.json
```

- `PAKPERK_DEVELOPMENT_TEAM`
- `CODE_SIGN_STYLE = Manual`
- `CODE_SIGN_IDENTITY = Apple Distribution`
- `PROVISIONING_PROFILE_SPECIFIER`

The checked-in example contains placeholders only. Build signed candidates:

```sh
flutter build ipa --release --flavor dev --dart-define-from-file=config/dev.json
flutter build ipa --release --flavor staging --dart-define-from-file=config/staging.json
flutter build ipa --release --flavor prod --dart-define-from-file=config/prod.json
```

Before either upload, compare `0.2.0+2` with the highest uploaded store version
and build number. Increment the checked-in package version if it is not
strictly newer; store history is external and cannot be inferred from Git.

## Protected staged store rollout

The signed-candidate workflow stops at Google Play's `internal` track and
TestFlight. Public production mutation is a separate manual workflow,
`protected-mobile-store-rollout`, bound to the fixed `production-store` GitHub
environment. Configure that environment with required reviewers, restrict it to
`main`, and provide the four store credentials listed above with only the store
permissions needed to promote the exact Play release and manage the exact App
Store version. A YAML environment name is not evidence that those protections
were configured.

Before exposing store credentials, the protected gate must keep two identities
separate. An uncredentialed bootstrap checks out trusted tooling at the reviewed
`github.workflow_sha`; the immutable candidate source is a data-only input and
must never supply credentialed executable code. The bootstrap produces an
immutable store-client/control closure. Every executable in that closure has a
workflow-literal SHA-256 that the fresh Android and iOS mutation jobs verify
before use; those jobs perform no checkout, receive no candidate-provided
executable, clear shell/language/loader/proxy injection surfaces, and expose
only the credential for their own platform. Before any candidate artifact is
accepted or store credential is materialized, the bootstrap queries GitHub's
Actions API for the supplied run ID. It requires the exact repository,
`signed-mobile-release` workflow path, `workflow_dispatch` event, `main` branch,
source SHA, successful completed status and run attempt, plus the exact
all-success eight-job surface: credential-free preparation, isolated Android
and iOS signers, `production signed candidate`, uncredentialed store-client
bootstrap, isolated Android and iOS uploads, and the credential-free signed-
release finalizer. It then requires one non-expired, attempt-bound candidate,
handoff, and signed-release-outcome artifact with distinct server-issued IDs
and SHA-256 digests, and downloads those artifacts by immutable ID (with digest
mismatch as an error). The exact artifact names are
`pakperk-production-<version>-<build>-<sha>-<run-id>-<attempt>` and
`pakperk-production-store-handoff-<version>-<build>-<sha>-<run-id>-<attempt>`,
plus
`pakperk-production-store-outcome-<version>-<build>-<sha>-<run-id>-<attempt>`.
The handoff
is created only after Play independently reports the exact version code as a
completed singleton on `internal` and returns the server-side bundle SHA-256
matching the candidate AAB; App Store Connect must report the exact iOS
app/build/pre-release-version relationship in `VALID` processing state and a
single completed `buildUpload` whose direct `build` relationship is that Build
ID. Its direct `assetFile` must be a completed `ASSET` with UTI
`com.apple.ipa`, the candidate IPA's exact byte size, and a
`sourceFileChecksums.file` SHA-256 equal to the candidate IPA digest. The
gate validates the authenticated canonical Actions record, the
canonical candidate, provenance, and handoff bytes, the candidate and
provenance `sha256:` content IDs, production/strict flavor,
source/version/build/application identities, artifact signer bindings,
repository/workflow/job/stage, signed-release run ID and run attempt, local AAB
and IPA hashes, and both authoritative upload readbacks. The handoff uses a
distinct `store-handoff-v1:sha256:` content ID. The signed-release
source must equal its recorded workflow revision. A typed content ID without
the corresponding downloaded bytes, a control closure that differs from its
literal workflow hashes, a trusted bootstrap checkout that differs from
`github.workflow_sha`, or candidate-authored code receiving store credentials
blocks the gate.

First classify each selected platform as an update or its first public
production version from the independent store history. Do not infer that state
from Git. The protected staged workflow is update-only. For a normal update:

1. Dispatch `signed-mobile-release` for `production` with
   `upload_to_stores=true`. Wait for the exact AAB to reach Play `internal` and
   the exact IPA/build to finish TestFlight processing. Retain its run ID,
   candidate ID, provenance ID, verified store-handoff ID, and
   protected-environment approval. A successful upload process without the
   verified handoff is not rollout-eligible.
   Immediately before each binary send, the workflow fsyncs an owner-only
   attempt journal bound to the candidate/provenance IDs, exact AAB or IPA
   digest and byte size, destination, run attempt, source, version, and build.
   The iOS verification must match both values from that pre-send journal and
   retain the App Store BuildUpload and BuildUploadFile resource IDs. It retains an
   always-run `mobile-store-upload-attempt-<run-id>-<attempt>` artifact. A
   journal without authoritative store readback is
   `unknown_reconcile_required`, even when the upload client lost only its
   success response.
2. Reconcile the two portal records with the signed manifest. Confirm the
   privacy, age-rating, reviewer-flow, physical-device, performance, crash,
   legal, and safety gates for this exact build. For Play, identify an eligible
   prior completed production release that can remain the fallback throughout
   the update; no prior fallback means this is a first publication and the
   staged workflow is prohibited. For iOS `start`, identify the exact prior
   public version; the trusted App Store Connect client must resolve exactly
   one matching iOS record in current
   [`appVersionState`](https://developer.apple.com/documentation/appstoreconnectapi/appversionstate)
   `READY_FOR_DISTRIBUTION`, and the exact target version must be
   `PREPARE_FOR_SUBMISSION` or `READY_FOR_REVIEW`. No matching prior public
   version means this is a first publication and the staged workflow refuses
   it.
3. Dispatch `protected-mobile-store-rollout` from `main` with operation
   `start`, the exact signed-release identities (including the store-handoff
   ID), platform scope, a sanitized
   change ID, and confirmation `MUTATE_PRODUCTION_MOBILE_STORES`. Android
   `start` also requires `android_previous_production_version_code`, expected
   fraction `none`, and target fraction `0.01`; iOS `start` requires
   `ios_previous_public_version`. Android promotes only that version code from
   `internal` to a one-percent `production` rollout. After the exact App Store
   update preflight, iOS submits only that TestFlight build for review with
   automatic phased release enabled, then requires the exact target phased
   resource to be `INACTIVE` before it records submission success.
4. Keep Android at one percent for the approved observation window. Before
   every `advance`, require no release-blocking alert, the exact-candidate
   performance checks, at least 99.5% crash-free sessions, and release-owner
   approval. The reviewed Android fractions are `0.02`, `0.05`, `0.10`,
   `0.20`, and `0.50`; `complete` is the only operation that accepts `1.00`.
   Apple's seven-day percentage progression is automatic, so an iOS
   `advance` observes and retains the current phased-release state rather than
   forcing a percentage; an `advance` succeeds only from exact `ACTIVE`, while
   pause/complete are re-observed after the API mutation. Apple documents the
   phased update schedule and pause
   behavior in [App Store Connect Help](https://developer.apple.com/help/app-store-connect/update-your-app/release-a-version-update-in-phases/).
5. Immediately before each live commit/PATCH/submission, write and `fsync` an
   owner-only attempt journal containing the exact reviewed store pre-state and
   `unknown_reconcile_required`. Only an authoritative postflight may replace
   that classification in the receipt with `succeeded_verified`; any error
   after the send begins remains `unknown_reconcile_required` until an operator
   reconciles the portal. Other closed classifications are `not_attempted`,
   `rejected_pre_mutation`, and `proven_not_committed`. In a combined rollout,
   the receipt requires the canonical journal and postflight to cross-match
   their pre-state/resource identities. A result without that journal, or with
   duplicate/non-finite/non-canonical JSON, remains
   `unknown_reconcile_required`. Apple is not attempted unless Android has this
   fully journal-bound `succeeded_verified` state, not merely a successful step
   exit. Upload the receipt before the workflow reports a final
   failure, and reconcile every unknown state before any retry.
6. Reconcile every platform outcome with the stores' independent audit/history
   record. Each content-addressed record binds trusted-tooling revision,
   candidate source, signed candidate/provenance/handoff, authenticated
   signed-release run/job/artifact IDs and digests, workflow revision,
   version/build, requested transition, sanitized change ID,
   pre/post state, and result. A workflow receipt is not store approval,
   propagation, crash evidence, or proof that an environment reviewer actually
   inspected the portal.

The rollout workflow enforces that sequence with exactly four trust domains:
an uncredentialed bootstrap, an Android-only-secret mutation job, an
iOS-only-secret mutation job, and a credential-free `always()` finalizer. For a
`both` transition, the iOS job downloads by immutable artifact ID and validates
the Android outcome and journal as `succeeded_verified` before any Apple
mutation. Each selected platform cleans up its secret and uploads an immutable
outcome even when the mutation fails; the finalizer then emits the canonical
schema-v4 aggregate and fails on a missing or unsuccessful selected outcome.
That aggregate binds the authenticated signed run, candidate, provenance,
handoff, source, version/build, and requested transition, including exact
unselected and dependency-skip semantics. GitHub's raw 64-hex upload-artifact
digest is retained in evidence only after canonical conversion to
`sha256:<hex>` and cross-checking against the server result.

谷歌和苹果只允许分阶段/分步发布更新。谷歌表示，首次生产版本会发布到选定国家的100%，并提供无发布比例控制；使用单独批准的首次Play发布流程，而不是`protected-mobile-store-rollout`。保留精确的无先前生产前状态、候选/来源和签名发布绑定、国家、审核/管理发布状态、100%发布操作和UTC时间、观察到的后状态/可用性、独立门户审计和商店所有者批准。详见[Play的首次发布和更新流程](https://support.google.com/googleplay/android-developer/answer/9859348)。

苹果的分阶段发布同样不适用于首次公开版本。对于首次iOS发布，应排除iOS的分阶段流程，使用单独批准的手动发布流程。保留精确的无先前公开版本前状态；候选/来源和签名发布绑定；应用/版本/构建和提交身份；提交时间和审核结果；选定的`Manually release this version`设置；发布前的`Pending Developer Release`状态；所有者批准；精确的`Release This Version`操作/时间以及观察到的发布后可用性，或故意保留的状态和决定。
该记录不得声称存在苹果的分阶段状态。详见[App Store版本发布选项](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/select-an-app-store-version-release-option/)。
当一个平台是更新，另一个是首次公开版本时，将保护的分阶段流程仅限于更新，并在同一个发布账本中保留单独的首次发布证据。Fastlane的审核商店操作记录在[Google Play](https://docs.fastlane.tools/actions/upload_to_play_store/)和[App Store](https://docs.fastlane.tools/actions/upload_to_app_store/)中。

在完成前的`halt`是Pakperk自动化流程中该候选的终止点。它会停止精确的Play分阶段更新并暂停精确的苹果分阶段更新。已经收到Android更新的用户将保留该更新。苹果明确允许在自动分发暂停期间，任何用户手动下载分阶段更新，因此暂停不是暴露的截止点。当这减少危害时，使用独立的功能开关禁用受影响的后端创建/写入，保留安全的访客读取，记录手动下载的残留暴露，并通过更高版本的构建修复所有签名候选和保护门。

当Android更新达到100%后，可以使用单独的保护Play完整发布暂停，使该版本再次对新用户和符合条件的用户可用，但它不会降级安装了不良版本的设备。记录精确的先前回退以及Play前/后状态和所有者决定。谷歌不允许在轨道的首次发布中进行此操作。没有等效的iOS回滚；使用功能开关和更高版本的修复前构建。详见[Play的完整发布暂停限制](https://support.google.com/googleplay/android-developer/answer/16285429)。
服务器回滚使用兼容的镜像/功能开关，从不使用自动SQL降级。

## 关联和签名工件门

该流程从本地签名的工件中提取Android包/版本和**上传密钥**证书，并要求AAB和APK匹配。该证书仅作为上传授权证据：在Play应用签名中，谷歌使用不同的应用签名证书对安装的APK进行签名。从受保护的Play控制台记录中读取其SHA-256指纹，并存储为`PAKPERK_ANDROID_APP_SIGNING_SHA256`；从不要用`assetlinks.json`中的上传密钥摘要替换。该流程从签名的IPA/配置文件中提取Apple团队/捆绑身份。生成受保护的关联文件，然后运行`docs/mobile-app-links.md`中描述的仓库验证器：

```sh
PAKPERK_RELEASE_ENV=production \
PAKPERK_ANDROID_PACKAGE=app.pakperk.pakperk \
PAKPERK_ANDROID_SHA256="$PLAY_APP_SIGNING_SHA256" \
PAKPERK_APPLE_TEAM_ID="$APPLE_TEAM_ID" \
PAKPERK_APPLE_BUNDLE_ID=app.pakperk.pakperk \
./scripts/verify_mobile_associations.sh \
  assetlinks.json apple-app-site-association
```

除非部署的`/.well-known/` URL直接返回HTTP 200，使用`application/json`，精确匹配这些签名身份，并在物理设备上打开有效的`/p/*`和`/arxiv/*`链接，否则发布将被阻止。重定向、通配符、过期指纹或占位符值将导致门禁失败。

保留Android身份的证据：验证器的`android_upload_sha256`证明哪个受保护密钥生成了候选，`android_play_app_signing_sha256`证明安装的Play应用将向Android链接验证呈现哪个证书。

签名的Android证据还必须保留`android_min_sdk=24`，`android_compile_sdk=36`，`android_target_sdk=36`，所选的构建工具版本，`android_apk_zip_alignment=16384`，以及每个归档的本地库计数加上`android_native_elf_load_alignment=16384`。签名的Apple证据必须保留发出的Xcode/SDK/最低OS值，配置文件过期时间，权限结果和打包的隐私清单结果。

### 受保护的移动功能标志

检查入的生产配置保持账户、库和评论关闭。检查入的测试环境启用它们，以便普通调试构建可以测试完整的功能组合，但绝不会以原样用于签名候选。对于测试和生产环境，签名候选流程会生成一个临时构建配置，并将所有受保护功能默认设置为关闭，除非这些GitHub环境变量显式启用：

- `PAKPERK_ACCOUNTS_ENABLED`
- `PAKPERK_LIBRARY_ENABLED`
- `PAKPERK_COMMENTS_ENABLED`

每个值必须是精确的`true`或`false`；缺失的值解析为`false`。除非账户也启用，否则库或评论不能启用。在受保护的`staging`和`production`环境中定义它们，要求在这些环境中进行发布审核者/分支限制，并且只能通过发布审批记录更改它们。它们是非秘密变量，从不发送输入或仓库默认值。该流程在`mobile-feature-flags.json`中保留它们的三个布尔值，并从相同的生成配置构建两个平台。保持独立控制的后端读/写/创建标志兼容；移动标志不授权服务器功能。

## 移动验证通道

普通的CI和签名候选流程运行`dart format`，`flutter analyze`和完整的`flutter test`套件。该套件包括无头的确定性生产环境。它通过受控的测试用例证明本地状态机、缓存、出站、分页、策略和有界小部件不变量；它不是物理设备或部署服务的证据。

手动触发的`mobile-device-integration`流程在显式选择的物理Android或iOS设备上以配置文件模式运行相同的确定性环境。受保护的运行器拒绝模拟器，并保留封闭的平台/操作系统版本记录，至少20个引擎帧样本，一个30条记录的缓存首页加上六个确定性游标页面，覆盖恰好200条记录，10个生成的Flutter拖动和10个生成的Flutter快速滑动，一个基于文件的500页/100保存SQLite测量，包括其WAL/SHM文件，以及一个机器可读的范围文件。它从不上传原始的Flutter日志、设备ID或用户分配的设备名称；分发ID在流程输出中被掩码。生成的`WidgetTester`手势在选定的设备上测试Flutter的指针、手势竞技场、滚动和页面提交路径，但在代表性的网络条件下不计为操作员/操作系统驱动器手势。其性能JSON被分类为测试用例负载，不得用作测试阶段p95或签名候选证据。在附加运行器之前，在固定的`mobile-device-verification` GitHub环境中配置所需的审核者和部署分支限制；YAML名称本身不会使环境受保护。仅将精确的Flutter设备标识符存储为该环境的`PAKPERK_MOBILE_DEVICE_ID`秘密；从不将其作为流程分发输入传递，因为运行元数据保留输入在日志掩码之外。这是隐私/不保留控制，而不是凭证隔离边界：选定的Flutter命令和审核的候选测试必然使用该标识符，并且已经获得了对附加物理设备的授权访问。不要在此测试通道中放置账户凭证或特权设备管理令牌，也不要声称原始选择器未隐藏在候选流程中。分发还要求一个显式的全小写`source_revision`，等于选定的`main`修订和获取的`origin/main`尖端，以及精确的确认短语。这防止了绿色测试用例探针附加到不同的源修订。

单独手动触发的`protected mobile acceptance`流程是实时测试/设备通道的自动化入口点。它仅接受精确的主尖端源修订和精确的`sha256:`候选和签名发布来源内容ID，仅在受保护的`mobile-device-verification`环境中运行。其精确的源检查出是一个**仅数据**边界：流程拥有的、隔离的Python仅读取有界测试配置和发布版本，且候选检查出中的任何脚本、二进制、shell启动文件、包钩子或其他可执行文件均不得在受保护会话中运行。流程从不将候选衍生数据写入`GITHUB_ENV`；它将`BASH_ENV`和`ENV`固定到`/dev/null`，并在作业和授权驱动器步骤中再次固定，将`PATH`固定到`/usr/bin:/bin`，并使用绝对系统工具路径。

所有接受验证和打包均使用固定的根拥有的`/opt/pakperk/bin/pakperk-mobile-acceptance-validator.py`；实时设备控制使用固定的根拥有的`/opt/pakperk/bin/pakperk-mobile-acceptance-driver`。在调用任何之前，流程要求`/`、`/opt`、`/opt/pakperk`和`/opt/pakperk/bin`必须是根拥有的且不可写，然后通过一个无跟随的打开描述符验证每个工具，稳定inode元数据，一个链接，根所有权，不可写模式和其受保护的SHA-256。驱动器也必须可执行。配置这些精确的受保护环境变量：

- `PAKPERK_MOBILE_RUNNER_SESSION_ID`;
- `PAKPERK_MOBILE_ACCEPTANCE_VALIDATOR_SHA256`;
- `PAKPERK_MOBILE_ACCEPTANCE_DRIVER_SHA256`;
- `PAKPERK_ANDROID_SIGNER_SHA256`;
- `PAKPERK_IOS_TEAM_ID`;
- `PAKPERK_IOS_SIGNER_SHA256`。

固定验证器和驱动器必须使用绝对、审核的路径，用于任何Android SDK或其他运行器工具，这些工具不在`/usr/bin:/bin`之外。

候选内容 ID 必须解析为一个规范的、由根所有者拥有的清单文件，位于
`/opt/pakperk/mobile-candidates/<digest>.json`。该清单文件绑定源、预发布环境、应用版本/构建、严格风味、Android 和 iOS 安装工件哈希值、精确的预发布应用 ID
`app.pakperk.pakperk.staging`、签名摘要、Apple 团队 ID 以及其来源内容 ID。来源必须独立解析到
`/opt/pakperk/mobile-release-provenance/<digest>.json`，并精确绑定 AAB、APK 和 IPA 的 SHA-256 值到仓库 `ErrDivine/PakPerk`、工作流
`.github/workflows/mobile-release.yml`、任务 `signed-candidate`、审核工作流/源 SHA、GitHub 运行 ID/尝试以及阶段 `artifacts_verified`。坐标从审核的 `mobile/config/staging.json` 中读取；可变坐标和包/捆绑 ID 变量不被接受。源步骤拒绝重复/非有限 JSON、控制字符、非可逆或不安全的 HTTPS 坐标、符号链接/竞争更改，以及无效的严格风味或发布版本。它会在 `RUNNER_TEMP` 下写入一个独占的、仅所有者拥有的规范版本 2 源绑定，仅包含精确的源版本、环境、应用版本/构建、API 源、应用链接源、OIDC 发行者和 OIDC 客户端 ID。

只有绑定的 ASCII 版本/构建和绑定路径成为步骤输出；没有任何内容成为 shell 启动设置。经过认证的请求构建器重新打开该绑定，并使用其坐标进行驱动请求。根所有者拥有的验证器独立重新加载它，要求其与候选/来源和版本/构建匹配，并使用相同的坐标进行最终证据验证。

无凭证的 `signed-candidate` 组装任务会发出规范的候选和来源文件及其内容 ID，但它无法将它们安装到自托管运行器的受保护文件系统中。在经过认证的工件检索后，运行器管理员必须
验证规范文件的摘要，并以根所有者权限、一个链接、无组/世界写入权限将其导入到固定的地址内容根目录中。非根运行器仍需要读取权限；模式 `0444` 是简单审核的安装选择，因为这些清单包含身份和哈希值，而不是凭证。这个经过认证的根侧导入是一个外部操作边界，而不是仓库工作流执行或证明的操作。

受保护的环境变量 `PAKPERK_MOBILE_RUNNER_SESSION_ID` 必须也命名一个规范的根所有者拥有的证明文件，位于
`/opt/pakperk/mobile-runner-sessions/<digest>.json`。其封闭的模式绑定精确的整数 `schema: 1`、分类
`dedicated ephemeral mobile acceptance runner session`、源版本、不透明会话和主机身份哈希、运行器类别
`dedicated-macos-physical-mobile`、精确的 `dedicated: true` 和 `ephemeral: true` 标志、一个封闭的 `physical_identities` 映射，每个所需角色都有一个不同的根键承诺，以及创建/过期时间间隔不超过八小时。相同的受保护父级、根所有者、一个链接、不可写、规范摘要规则适用。验证器拒绝过期的证明文件。创建和根安装此证明文件以及固定验证器/驱动器、配置专用运行器、证明没有先前或不可信的任务/进程共享凭证会话、隔离主机和连接的设备、并在之后销毁其一次性状态，仍然是外部受保护的运行器管理员控制。仓库验证、`BASH_ENV`/`ENV` 固定、标签和声称的 `ephemeral: true` 证明文件本身并不证明运行器组访问、单任务/JIT 注册、进程隔离或主机清理；保留平台/配置证据和管理员批准用于发布。

受保护的运行器向根所有者拥有的、摘要固定的驱动器暴露四个不同的安装设备秘密：一个 Android 手势导航手机、一个 Android 三按钮手机、一个带有主页指示器的 iPhone，以及一个也是独立第二同步安装的物理键盘 iPad。测试账户和密码是环境秘密，永远不会写入请求或证据中。

驱动器必须针对一次性预发布账户自动化以下所有路径，并发出封闭的 `mobile-acceptance-evidence.json` 合约：

1. 安装经过审核的签名 APK 和 IPA，确保之前的应用数据不存在，保持访客身份，达到缓存的读取而无需登录，读取已发布的评论，并通过操作系统浏览器打开精确的规范 arXiv URL，而不是嵌入式网页视图。
2. 从填充的本地缓存冷启动，并收集缓存的首次可读帧 p95、健康的本地初始化打开过渡持续时间以及原生启动连续性测量。
3. 在受控延迟和数据包丢失下垂直滑动至少 20 篇论文；记录空白卡片和顺序缓存命中。
4. 确认介绍准备仅在显式水平意图后开始。
5. 切换 Read -> You -> Read 并恢复精确的论文、阶段和偏移量。
6. 使用 PKCE 完成系统浏览器的 OIDC 与发布租户。
7. 保存、终止/重新启动安装的应用程序，重新连接并验证同步。
8. 在设备 A 上保存，将 A 离线，将保存收敛到独立安装的设备 B，从 B 中移除它，重新连接 A，要求 A 接收移除墓碑，并要求两个投影在无连接时收敛。
9. 从访客帖子意图开始，完成发布租户登录，选择一个不完整档案上的用户名，接受当前的条款和社区指南，使用一个稳定的客户端请求 ID 创建，重放到相同的评论，编辑，拒绝一个过时的编辑，删除，并验证公共列表的缺失。
10. 使用同一个 idempotency 身份提交相同的评论报告两次，要求一个规范的持久报告，然后阻止作者并确认立即且服务器持久隐藏。
11. 过期一个真实的访问令牌，验证一次成功的刷新，并继续原始操作。
12. 在一个单独的临时会话中，在发布 IdP 处使真实刷新凭证失效，强制刷新，要求访客过渡，使刷新记录不可读且账户拥有的行不可访问，同时保留公共缓存和精确的论文/阶段/偏移量状态。
13. 为账户删除重新认证并验证立即停用、会话撤销、提供者清理和删除状态路径。
14. 读取和保存离线内容，终止进程，当网络仍禁用时重新启动，读取任何重新连接前的缓存摘要，然后验证相同 UUID 的出站恢复和连接恢复后的服务器突变。
15. 重复冷/暖启动，减少运动并验证静止的有界过渡。
16. 使用严格签名风味并验证元数据/保存/评论/原始 arXiv 链接保持不变，而每个缓存的派生回退保持隐藏。
17. 在 Android 和 iOS 上，使用精确的源绑定预发布应用链接源的部署 `/p/*` 和 `/arxiv/*` 应用/通用链接，从冷、暖和已运行状态启动，要求 Abstract 打开，并证明敌对源在无论文请求时失败关闭。
18. 在签名安装的设备上，证明 Android 备份已禁用且提取不会恢复任何应用数据；证明 iOS 备份排除和 `completeUntilFirstUserAuthentication` 保护；并验证设备绑定、不可同步的安全凭证属性，无持久访问凭证。
19. 测量一个填充的签名设备数据库加上 WAL/SHM 文件，并要求最多 500 个缓存论文记录和最多 64 MiB 的物理缓存存储，同时至少一个保存的论文 PIN 保持完整。
20. 在 Android 和 iOS 上测试轻量和深色外观，保持阅读状态并找不到不可读、裁剪或不可见的关键操作。
21. 测试根导航安全区域和系统返回，跨 Android 手势、Android 三按钮和 iPhone 主页指示器模式。
22. 在 Android 和 iPad 上测试物理键盘 Tab、Shift-Tab、Enter 和 Escape 路径，包括 200% 文本和最小目标覆盖率。

根所有者拥有的验证器要求精确的源、应用版本/构建、候选、验证器和驱动器摘要；签名发布来源、规范源绑定和临时运行器会话绑定；预发布 API/应用链接/OIDC/客户端坐标；四个有序的物理设备角色；不同的安装和物理身份哈希；清理的硬件型号和操作系统版本；以及上述所有 22 个有序的 schema-v3 场景。只有在精确的设备角色分配、精确的有序声明 ID 列表（总计 141 个标记）和封闭的整数阈值/相等度度量（总计 78 条规则）下，场景才通过；通用的正数计数不被接受。驱动请求携带 schema `3`、精确的场景计数、声明计数、度量计数和规范有序角色/声明/度量规则合同的 SHA-256。固定的驱动器必须拒绝不同的合同，而不是翻译或接受旧的 schema。特别是，`cold_cache_launch.metrics` 必须
包含精确的整数键 `populated_cache_records`、`cached_first_readable_frame_p95_ms` 和 `opening_transition_ms`。后两者必须为正且分别不超过 1,500 毫秒和 700 毫秒；旧的单样本 `first_readable_frame_ms` 键被拒绝。受保护的驱动请求携带相同的两个精确范围规则，以便摘要固定的生产者和验证器共享一个关闭失败的合同。每个 Android 角色必须识别一个绑定来源的 APK 安装；每个 iOS 角色必须识别绑定来源的 IPA。每个设备还必须回声其平台的精确预发布应用、签名者和 Apple 团队绑定。

对于每个角色，驱动程序会推导出一个运行特定的 `device_identity_hash`，而不会保留序列号或其他原始标识符。它首先计算一个稳定的秘密值，形式为 `HMAC-SHA256(root_owned_device_identity_key, platform || NUL || raw_id)`，然后将该稳定的秘密值作为角色的根认证承诺，并计算 `HMAC-SHA256(run_challenge, stable_secret)` 作为证据。验证器会自行执行第二次计算，并且从不将稳定的承诺值复制到请求绑定或保留的证据中。由于角色未参与推导过程，因此使用同一物理设备为两个角色服务会导致相同的承诺值，从而被拒绝。公共挑战值使保留的哈希值在不同运行之间发生变化，而根拥有的密钥则防止其成为直接的序列号预言机。证据仍然有意地标识运行会话，因此当一个认证被重复使用时，可以进行关联。所有四个哈希值和所有四个安装哈希值必须各不相同。原始设备标识符仅保留在受保护的进程环境中，且不得出现在请求、证据、日志或工件中。通过这些标记并不能替代单独的可问责视觉、可访问性、移动平台、身份、隐私和发布审批。

证据模式 v3 也绑定到一个新鲜的加密挑战、GitHub 运行 ID 和尝试次数，以及整个秒数的 UTC not-before 时间。验证限制运行时间为六小时，拒绝过期/重放的完成、重复或非规范的 JSON、非有限数字、额外字段、凭证形状的字符串、符号链接、过大证据、部分场景和失败路径。验证器将已经读取的规范证据以及规范的 `mobile-acceptance-tooling.json` 和 `SHA256SUMS`，按此顺序直接创建最终归档文件，并使用独占打开语义。工具清单具有确切的模式 `1`，分类为 `protected mobile acceptance tooling`，并包含封闭的验证器/驱动程序对象，其中包含固定的文件名和受保护的 SHA-256 值。`SHA2,56SUMS` 覆盖证据和工具成员。验证器检查最终的 inode、所有者、模式 `0400`、链接计数、大小和 SHA-256；在上传之前，它重新打开归档文件，要求封闭成员顺序和元数据，验证两个校验和，并将两个归档工具摘要与受保护的预期变量进行比较。本地 tar 校验和绑定到工件名称中；最终步骤还要求上传操作的单独工件容器校验和。仅所有者驱动的日志被捕获并丢弃，而设备序列号、凭证、句柄和注释/查询文本被排除。

发布所有者必须为确切安装的签名候选者分发此工作流，并附加其不可变工件和受保护环境的批准。已检查的编排和验证器不会证明根安装的工具、隔离的运行会话、测试租户、账户或设备可用，且未分发的工作流、仓库测试、模拟器或操作员声明不会完成此通道。

## 仪表和发布候选门

生产仪表使用仅有的精确 HTTPS `/v1/logs` OTLP 端点。移动导出器不发送授权头、cookie、用户/设备/会话 ID、纸张 ID、句柄、内容、令牌、原始异常消息或堆栈。事件和属性传递一个封闭的词汇表；负载最大为 16 KiB，请求有两秒的截止时间，响应在不缓冲的情况下被取消，最多两个导出在进行中，饱和/失败时丢弃数据而不排队或重试。

全局错误捕获仅向该导出器发送有限的错误类别。它委托框架展示，使用删除细节，并且从不将原始异常或堆栈传递给先前的平台处理程序。接受有限类别的先前处理程序保留失败的所有权。否则，原始引擎回调仅标记为已处理，以防止其原始参数被打印；应用程序在相同的错误区域中使用 `StackTrace.empty` 报告有限类别，且该替换保持真正未捕获。区域和预捕获启动失败使用相同的替换。不要吞食替换：这样做可能导致进程处于损坏状态，并使无崩溃证据误导。Apple/Google 诊断可能在平台策略下保留本地崩溃记录，但不得接收应用程序异常消息、令牌、内容值或 Dart 堆栈。在发布前，请审查确切签名工件的平台诊断和存储披露。

在证据包包含以下内容之前，不要声明发布候选已通过：

- 至少 20 个缓存的首次可读帧样本，p95 在命名参考设备和测试环境中不超过 1.5 秒；
- 至少 20 个打开过渡样本，当本地初始化健康时，测量的过渡时间不超过 700 毫秒；
- 在至少 20 个温暖的连续下一张纸请求中，没有空白卡，且至少 95% 缓存命中；
- 至少 20 个帧样本和一个记录的样本窗口；
- 对于确切签名候选，至少 99.5% 的无崩溃会话；
- 测量的样本/窗口、收集器查询或存储报告、构建号、设备/操作系统矩阵和批准者。

使用由阶段分布/诊断系统提供的隐私审查的崩溃分母汇总。不要向移动仪表添加持久设备、账户或会话标识符以制造此指标。在签署的 TestFlight/封闭 Play 候选至少有 24 小时的观察窗口和两个绑定存储诊断源的 200 汇总确切候选会话之前，且该窗口被发布所有者批准为代表性，崩溃门 **未通过**。这些是生产 v0.0 的最低要求；所有者可以要求更长的窗口或更大的分母，但不能在清单中放弃这些要求。

## 外部发布阻塞项

仓库检查无法完成这些操作。发布所有者必须在启用生产标志之前为每个操作附加证据：

- 受保护的 Android 和 Apple 签名凭证和成功签名的 dev/测试/生产工件；
- 注册的 OIDC 客户端/重定向和生产关联域名；
- 部署的关联和法律/支持 URL 与监控的联系细节；
- 活动的 OTLP 收集器保留和删除验证；
- 物理设备账户、评论/报告/阻止、删除、严格内容、离线、回调和深度链接 QA；
- 审查者账户和存储审查注释，不含真实用户数据；
- TestFlight 和封闭 Play 轨道上传、当前 App 隐私/数据安全和年龄评级表单、单调存储版本、审查状态，以及上述定义的受保护更新过渡证据或单独批准的首次发布证据。更新证据包括可信工具与候选源的分离、合格的 Play 备用、确切的每平台预/后状态和无条件结果、部分成功协调、Apple 手动下载暴露和任何 Android 专用的完整发布暂停；首次发布证据包括确切的 Play 100% 状态和 Apple 手动发布状态/操作。Apple 的 [更新年龄评级问卷](https://developer.apple.com/news/upcoming-requirements/?id=07242025a) 自 2026 年 1 月 31 日起要求回答；
- 验证的 Android 开发者身份和包/签名密钥注册。
  [区域执行从 2026 年 9 月 30 日开始](https://developer.android.com/developer-verification/guides) 对巴西、印度尼西亚、新加坡和泰国的参与商店，随后进行更广泛的推广；
- 测试性能/崩溃证据，以及由运营拥有的备份-恢复/删除重放证据。

不要从源构建或模拟器测试中标记外部项目为完成。
