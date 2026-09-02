# 在实体手机上测试 Pakperk

本指南讲解如何在 Android 实体手机和 iPhone 实体设备上完成日常开发循环。其中明确区分三件很容易混淆的事情：

- **在调试过程中运行应用**；
- **运行 Pakperk 的设备端确定性测试框架**；以及
- **收集受保护的发布证据**。

一次成功的调试启动可以提供有价值的开发证据。但它不是经过签名的发布版本，不代表应用商店已经验收，也不能替代[移动端发布](mobile-release.md)中说明的受保护四设备验收测试。

## 选择真正符合需要的连接方式

| 手机与目标 | 推荐连接方式 |
| --- | --- |
| Android 实体手机、访客版应用、后端在本机运行 | 通过 USB 使用 `adb reverse`，连接到 `http://localhost:8080` |
| Android 实体手机，还要测试本地账户 | 反向转发 API 端口 8080 和身份认证端口 8081；只有测试流程会用到公共站点或遥测时，才反向转发相应端口 |
| iPhone，开发 UI 或内置离线内容 | 运行 dev 构建变体；后端可以保持不可访问 |
| iPhone，使用实时 API 开发 | 使用 iPhone 可以访问且采用可信 HTTPS 的开发或预发布 API |
| 任一平台，验证确定性的应用行为 | 运行集成测试驱动；其中的网络、身份认证和持久化协作者都是受控测试替身 |
| 任一平台，验证真实的身份认证、双设备或服务端行为 | 使用受保护的预发布验收流程，不要使用确定性测试框架 |

这种差异是有意设计的。Android 开发工具可以通过 USB，将手机上的端口反向转发到开发电脑上的端口。本仓库没有对应的 iPhone 反向隧道配置。在 iPhone 实体设备上，`localhost` 指的是 iPhone 本身，而不是 Mac。

除非某段明确另有说明，否则请把下面每个 shell 代码块都视为彼此独立，并从仓库根目录开始执行。需要使用 Flutter 项目的代码块会先执行 `cd mobile`；不要把上一个代码块的工作目录沿用到下一个代码块。

## 连接手机前的准备

从仓库根目录开始。进入 `mobile/`，然后确认所安装的 Flutter 符合仓库锁定的版本，并检查开发电脑上的工具链：

```bash
cd mobile
flutter --version
dart --version
flutter doctor -v
flutter pub get --enforce-lockfile
```

当前发布证据使用 Flutter 3.44.8 和 Dart 3.12.2 构建。Pakperk 要求 Android 7.0/API 24 或更高版本，以及 iOS 15 或更高版本。Android 项目的编译 SDK 和目标 SDK 均为 API 36；项目使用 Java 17，并锁定 NDK 28.2.13676358。请安装 JDK 17，并确保 Flutter 能够找到它。在新的 Android 开发电脑上，还要先接受已安装 SDK 的许可协议，再尝试构建：

```bash
flutter doctor --android-licenses
flutter doctor -v
```

请使用能够传输数据的 USB 线，解锁手机，并在首次配对期间保持屏幕常亮。只能充电的线缆，是设备未显示时一个出人意料却十分常见的原因。

列出 Flutter 当前能够识别的设备：

```bash
flutter devices
```

请原样复制设备 ID。以下示例使用环境变量，确保每条命令都作用于预期的实体手机：

```bash
export PAKPERK_MOBILE_DEVICE_ID='COPY_THE_DEVICE_ID_HERE'
```

连接了多个模拟器、仿真器或手机时，不要使用 `android` 或 `ios` 这类宽泛名称。

## Android：配对并运行应用

### 1. 启用 USB 调试

在手机上启用 **开发者选项（Developer options）**，再启用 **USB 调试（USB debugging）**。确切的菜单名称会因厂商而异。Android 官方的[硬件设备指南](https://developer.android.com/studio/run/device)说明了当前菜单路径，以及各平台的驱动程序要求。

连接已解锁的手机。Android 询问是否允许这台电脑进行 USB 调试时，请核对指纹并批准。只有在你信任的电脑上，才选择“始终允许使用此计算机进行调试”（Always allow from this computer）。

在 macOS 上，通常不需要额外安装 USB 驱动程序。Windows 可能需要手机厂商提供的 OEM USB 驱动程序。Linux 可能要求当前用户属于 `plugdev` 组，并配置合适的 udev 规则。

### 2. 确认 Android 工具识别到已授权设备

```bash
adb devices -l
flutter devices
```

`adb` 对应行的状态必须是 `device`，不能是 `unauthorized` 或 `offline`。

如果状态是 `unauthorized`，请解锁手机并处理信任提示。如果提示始终不出现，请在开发者选项中撤销 USB 调试授权，拔下线缆后重新连接，再核对新的指纹。如果状态是 `offline`，先重新连接手机，再考虑重启 `adb` 服务器。只有一条线缆有问题时，不要重置其他已连接设备。

### 3. 启动本地访客后端

从仓库根目录开始，先完成[开发者指南](developer-guide.md#run-pakperk-locally)中的访客环境配置，然后验证：

```bash
curl --fail http://localhost:8080/health/ready
```

### 4. 通过 USB 反向转发 API 端口

```bash
adb -s "$PAKPERK_MOBILE_DEVICE_ID" reverse tcp:8080 tcp:8080
adb -s "$PAKPERK_MOBILE_DEVICE_ID" reverse --list
```

第一个 `8080` 是应用在手机上访问的端口，第二个是开发电脑上的 API 端口。应用 URL 应继续使用 `http://localhost:8080`。Android dev 构建的网络安全策略只允许 `localhost`、`127.0.0.1` 和仿真器专用地址 `10.0.2.2` 使用明文传输。因此，随意使用局域网中的 `http://192.168...` URL，既不符合本文档规定的路径，也会被应用策略拦截。

### 5. 启动访客版应用

从仓库根目录开始执行这个代码块：

```bash
cd mobile
flutter run -d "$PAKPERK_MOBILE_DEVICE_ID" \
  --flavor dev \
  --dart-define=PAKPERK_ENV=development \
  --dart-define=PAKPERK_API_BASE_URL=http://localhost:8080 \
  --dart-define=PAKPERK_FULLTEXT_POLICY=prototype
```

这条最小化命令不会启用账户及其他可选产品功能。安装后的应用名为 `PakPerk Dev`，Android 应用 ID 为 `app.pakperk.pakperk.dev`。

Feed 显示后，请在另一个终端中验证 USB 映射：

```bash
adb -s "$PAKPERK_MOBILE_DEVICE_ID" reverse --list
curl --fail http://localhost:8080/v1/feed | jq '.items | length'
```

保持 `flutter run` 连接，打开它输出的 DevTools 链接，选择 **Network（网络）** 视图，刷新 Feed，并确认 `GET /v1/feed` 成功。API 默认使用精简日志，不会打印每一条请求路径，因此，使用 grep 在 Compose 日志中搜索这个 URL 不能作为有效测试。

刚完成迁移的数据库中没有论文，但应用可以显示内置的演示 Feed。测试需要服务端提供论文时，请停止应用，在仓库根目录运行 `./scripts/seed_demo.sh`，确认 `curl --fail http://localhost:8080/v1/feed | jq '.items | length'` 的结果大于零，然后重新启动应用。只有测试还需要后端实时提供已预处理的 Introduction 或 Connections 内容时，才运行 `./scripts/preprocess_demo.sh`。

如果应用报告连接错误，请再次运行 `adb reverse --list`；端口反向转发按设备分别设置，手机断开连接或重启后，该设置可能失效。

### 6. 仅在账户相关任务中添加本地账户

请先按照[账户身份认证](account-authentication.md#reference-development-provider)中的说明操作。请使用其中完整的 `config/dev.json` 后端命令，而不是仅启用账户的命令，这样开发电脑上的 API 还会启用 `LIBRARY_ENABLED`、`LIBRARY_WRITES_ENABLED`、`COMMENTS_ENABLED` 和 `COMMENT_CREATION_ENABLED`。该流程在开发电脑上运行 API，并通过端口 8081 提供参考颁发者。请反向转发这两个端口：

```bash
adb -s "$PAKPERK_MOBILE_DEVICE_ID" reverse tcp:8080 tcp:8080
adb -s "$PAKPERK_MOBILE_DEVICE_ID" reverse tcp:8081 tcp:8081
```

已纳入版本控制的完整 dev 配置还会指向端口 3000 上的公共站点和端口 4318 上的遥测端点。只有相应服务正在运行，而且当前测试流程需要使用它们时，才反向转发这些端口：

```bash
adb -s "$PAKPERK_MOBILE_DEVICE_ID" reverse tcp:3000 tcp:3000
adb -s "$PAKPERK_MOBILE_DEVICE_ID" reverse tcp:4318 tcp:4318
```

然后启动完整的 dev 配置组合：

```bash
cd mobile
flutter run -d "$PAKPERK_MOBILE_DEVICE_ID" \
  --flavor dev \
  --dart-define-from-file=config/dev.json
```

`config/dev.json` 会在应用中启用账户、Library 和评论。API 必须启用与之匹配的账户、Library 读取/写入以及评论读取/创建开关。移动端开关不会启用对应的后端路由；同样，启用后端路由也不能保证不兼容的移动端构建安全可用。

## iPhone：完成签名、配对并运行应用

在 iPhone 实体设备上开发，需要使用 macOS 和 Xcode。Flutter 当前的 [iOS 设置指南](https://docs.flutter.dev/platform-integration/ios/setup)涵盖 Xcode 安装、命令行工具、设备信任和代码签名。免费的个人 Apple 开发者账户可以为你自己的设备签署开发版应用，但会受到 Apple 的限制；分发应用仍然需要使用受保护的 Pakperk 签名配置。

### 1. 使用 Xcode 与 iPhone 配对

1. 使用能够传输数据的线缆，将已解锁的 iPhone 连接到 Mac。
2. 在 iPhone 上接受 **“信任此电脑”（Trust This Computer）**，并完成 Xcode 中出现的对应配对提示。
3. 如果尚未添加，请在 Xcode 的 Accounts 设置中添加你的 Apple ID。
4. 在 iPhone 上的 **“设置”（Settings）>“隐私与安全性”（Privacy & Security）** 中启用 **开发者模式（Developer Mode）**，按提示重新启动，并在重启后确认。Apple 的[在设备上启用开发者模式](https://developer.apple.com/documentation/Xcode/enabling-developer-mode-on-a-device)文档解释了为什么必须执行这一步。
5. 先确认 Xcode 能够识别设备，再确认 Flutter 也能识别：

   ```bash
   cd mobile
   flutter devices
   ```

首次通过 Flutter 启动调试版本时，系统可能会请求“本地网络访问权限”（Local Network）。开发期间请允许该权限，以便热重载、DevTools 和 Dart VM 服务建立连接。Flutter 的 [iOS 调试指南](https://docs.flutter.dev/platform-integration/ios/ios-debugging)解释了这一提示。

### 2. 提供开发团队信息，但不要将其提交到仓库

创建已被 Git 忽略的文件 `mobile/ios/Flutter/LocalSigning.xcconfig`，其中只写入以下开发设置：

```text
PAKPERK_DEVELOPMENT_TEAM = YOUR_APPLE_TEAM_ID
```

请使用 Team ID，而不是 Apple ID 邮箱地址。不要把分发证书名称或预置描述文件的值提交到源代码管理。已纳入版本控制的 `LocalSigning.xcconfig.example` 说明了受保护的发布签名，并包含手动分发设置；普通 Debug（调试）构建不需要这些额外设置。

dev 构建变体要求使用 Bundle ID `app.pakperk.pakperk.dev`。如果 Apple 签名服务提示你的个人团队无法使用该标识符，问题并不在 USB 连接。请获取 Pakperk 开发团队的访问权限，或者与维护者协商，有计划地修改开发 Bundle ID。未经协商只修改某一个 Xcode 字段，会破坏仓库对构建变体、回调和发布流程的既有假设。

### 3. 选择离线 UI 开发或实时 HTTPS API

dev iOS 配置只允许 `localhost` 使用明文 HTTP，而手机上的 `localhost` 指向手机本身。本仓库不为 iOS 提供 USB 反向隧道。

开发 UI、导航、动画或内置离线内容时，即使 Mac 上的 API 无法访问，dev 应用仍可使用默认本地 URL 运行：

```bash
cd mobile
flutter run -d "$PAKPERK_MOBILE_DEVICE_ID" \
  --flavor dev \
  --dart-define=PAKPERK_ENV=development \
  --dart-define=PAKPERK_API_BASE_URL=http://localhost:8080 \
  --dart-define=PAKPERK_FULLTEXT_POLICY=prototype
```

预期结果是：应用使用带明确标识的内置演示内容，并如实报告实时网络不可用。不要把这次启动当作 API 测试。

需要使用实时访客 API 开发时，请使用 iPhone 能够通过可信 HTTPS 访问的开发服务器：

```bash
cd mobile
flutter run -d "$PAKPERK_MOBILE_DEVICE_ID" \
  --flavor dev \
  --dart-define=PAKPERK_ENV=development \
  --dart-define=PAKPERK_API_BASE_URL=https://YOUR-DEV-API-HOST \
  --dart-define=PAKPERK_FULLTEXT_POLICY=prototype
```

不要通过添加宽泛的 App Transport Security 例外或禁用证书验证来绕过此限制。要测试实时 OIDC，正确的环境是稳定的 HTTPS 预发布部署：发现文档中的颁发者、浏览器重定向、令牌、API 验证配置和应用的构建参数，必须使用完全相同的公共颁发者。

如果可以使用受保护的预发布服务和签名身份，请运行仓库完整的 staging 组合：

```bash
cd mobile
flutter run -d "$PAKPERK_MOBILE_DEVICE_ID" \
  --flavor staging \
  --dart-define-from-file=config/staging.json
```

这条命令假定真实的预发布 API、身份提供商、公共站点、遥测源、关联域文件和兼容的后端开关均已存在。它不会创建这些资源。

## 正确使用热重载，不要把它和重启混为一谈

`flutter run` 保持连接时：

- 完成普通 Dart UI 修改后，按 `r` 执行热重载；
- 初始化逻辑或依赖设置发生变化时，按 `R` 执行完整的热重启；以及
- 更改构建变体、Android/iOS 原生文件、签名、应用授权或 `--dart-define` 值后，停止应用并重新启动。

热重载会保留大量运行时状态，这有助于快速迭代。但它不适合用来验证冷启动、数据库迁移、身份认证恢复或进程终止后的行为。

## 在手机上运行确定性测试

集成测试驱动使用受控协作者，运行一组可重复的 Flutter 行为。手势序列由 Flutter 的 `WidgetTester` 生成；生命周期事件和内存警告事件则是受控的测试输入。它们以确定性方式执行应用代码，并不等同于真人操作触摸屏、操作系统终止进程或真实内存压力。该套件还涵盖大型缓存 Feed、分页、同时存活数量有上限的阅读器、SQLite 工作负载、丢包、待同步队列（outbox）恢复、评论分页、减弱动态效果，以及严格策略下的缓存遮蔽。

普通开发者使用 dev 应用标识运行时：

```bash
cd mobile
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/production_verification_test.dart \
  --flavor dev \
  --dart-define-from-file=config/dev.json \
  --profile \
  -d "$PAKPERK_MOBILE_DEVICE_ID"
```

如需运行较短的演示流程：

```bash
cd mobile
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/demo_flows_test.dart \
  --flavor dev \
  --dart-define-from-file=config/dev.json \
  -d "$PAKPERK_MOBILE_DEVICE_ID"
```

仓库的标准实体设备探测使用 prod 构建变体：

```bash
cd mobile
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/production_verification_test.dart \
  --flavor prod \
  --dart-define-from-file=config/prod.json \
  --profile \
  -d "$PAKPERK_MOBILE_DEVICE_ID"
```

在 Android 上，这个 Profile（性能分析）构建使用开发签名/Debug（调试）签名。在 iOS 上，它需要获准用于生产 Bundle ID 和 Associated Domains（关联域）授权的开发团队及预置描述文件；个人团队未必拥有相应权限。这两个 Profile 构建都不能作为 Release（发布）签名证据。dev 构建变体的结果仍能提供有价值的开发反馈，但不能替代标准的生产构建变体探测。

先设置 `PAKPERK_MOBILE_DEVICE_ID`，再运行 `./scripts/check.sh`，会让完整的仓库检查包含这项标准探测。该检查成本很高，这是有意的设计。

确定性测试驱动**不会**测试真实身份提供商、实时后端、安装了应用的第二台设备、操作系统终止进程、账户删除、真实模型提供商、应用商店候选版本，也不会覆盖具有代表性时长的真人操作性能测试。这些测试属于受保护的预发布和发布流程。

## 运行 iOS 原生数据保护测试

在已连接且配置好开发签名的 iPhone 上运行：

```bash
cd mobile
xcodebuild test -quiet \
  -project ios/Runner.xcodeproj \
  -scheme dev \
  -configuration Debug-dev \
  -destination "platform=iOS,id=$PAKPERK_MOBILE_DEVICE_ID" \
  -disableAutomaticPackageResolution
```

这是一项额外的原生测试，不能替代 Flutter 测试套件。

## 完成一次有价值的手动检查

测试前，请记录应用构建变体、源代码修订版本、手机型号、操作系统版本、连接方式和后端修订版本。然后检查此次更改所影响的界面，包括：

1. 主屏幕图标和显示名称按预期标识为 `PakPerk Dev`、`PakPerk Staging` 或生产版 Pakperk。
2. 冷启动、切换到后台再返回前台，以及完全重新启动，都能正确运行。
3. Feed 能够加载；如果本次测试使用实时后端，DevTools 的 Network 视图会显示成功的 `/v1/feed` 请求。
4. 垂直滚动、论文内横向手势、轻点、返回导航，以及手势中途被打断时，行为都自然合理。
5. 开启飞行模式或切断后端连接时，应用会如实显示离线状态；恢复连接后，应用能够继续工作且不会产生重复操作。
6. 深色外观、更大字号、减弱动态效果、屏幕阅读器焦点，以及适用场景下的实体键盘，均保持可用。
7. 登录账户后，系统浏览器能够通过正确的自定义回调 URL scheme 返回应用。只有应用和后端同时启用 Library 与评论时，这些功能才会出现。
8. `pakperk://` 深度链接会打开预期目标。dev iOS 构建不会声明生产关联域，因此，自定义 scheme 是可靠的本地检查方式。

已纳入版本控制的第一篇演示论文，其 ID 为 `387fc70a-a95a-4c45-aa9d-f6252934da33`。安装 dev 应用后，请明确启动它的自定义 URL。Android：

```bash
adb -s "$PAKPERK_MOBILE_DEVICE_ID" shell am start -W \
  -a android.intent.action.VIEW \
  -d 'pakperk://paper/387fc70a-a95a-4c45-aa9d-f6252934da33' \
  app.pakperk.pakperk.dev
```

iPhone：

```bash
xcrun devicectl device process launch \
  --device "$PAKPERK_MOBILE_DEVICE_ID" \
  --terminate-existing \
  --payload-url 'pakperk://paper/387fc70a-a95a-4c45-aa9d-f6252934da33' \
  app.pakperk.pakperk.dev
```

预期结果是打开 Attention Is All You Need 论文。即使后端不可用，这篇论文也存在于已纳入版本控制的内置 Feed 中。该结果能够证明自定义 scheme 路由有效，但不能证明 Universal Links（通用链接）或服务端数据有效。

收集证据时，不要记录访问令牌、密码、论文全文、提示词、评论、举报内容或身份属性。

## 仅在测试需要全新安装时重置

以下命令会删除所选手机上的应用自有状态。如果需要保留测试账户，请先退出登录；运行命令前，还要确认应用 ID。

Android dev 构建变体：

```bash
adb -s "$PAKPERK_MOBILE_DEVICE_ID" shell pm clear app.pakperk.pakperk.dev
```

iPhone dev 构建变体：

```bash
xcrun devicectl device uninstall app \
  --device "$PAKPERK_MOBILE_DEVICE_ID" \
  app.pakperk.pakperk.dev
```

卸载 iOS 应用并不能保证所有 Keychain 条目都会消失。请把身份认证恢复作为单独测试；只有通过文档规定的删除流程，才能在身份提供商一侧清理账户。

## 故障排查速查表

| 现象 | 通常意味着 | 首先检查 |
| --- | --- | --- |
| 没有 Android 设备行 | 线缆、驱动程序或开发者选项存在问题 | `adb devices -l` |
| Android 显示 `unauthorized` | 尚未批准 RSA 信任提示 | 解锁手机并查看提示 |
| 浏览器中 Feed 正常，但 Android 应用中不正常 | USB 反向转发不存在，或绑定到了另一台设备 | `adb -s "$PAKPERK_MOBILE_DEVICE_ID" reverse --list` |
| Android 拦截局域网 HTTP URL | dev 策略只允许文档指定的回环主机 | 使用 `adb reverse` 和 `http://localhost:8080` |
| Xcode 能识别 iPhone，但 Flutter 无法启动 | 开发者模式、团队、证书或预置描述文件存在问题 | 查看 `flutter doctor -v` 和 Xcode 签名详情 |
| iPhone 无法访问 Mac API | 手机上的 `localhost` 并不指向 Mac | 使用可以访问且可信的 HTTPS |
| 应用启动时退出 | 构建变体与环境不匹配，或功能依赖关系不匹配 | 检查 `flutter run` 输出和传入的构建定义 |
| 账户浏览器流程成功，但应用仍显示未登录 | 颁发者、客户端或回调不匹配 | 逐项比较公共颁发者和构建变体专用回调，必须完全一致 |
| 测试通过，但实时登录失败 | 确定性测试框架使用了受控测试替身 | 运行受保护的实时预发布场景 |

操作系统工具本身发生变化时，最佳参考资料是 Flutter 官方的 [Android 设置指南](https://docs.flutter.dev/platform-integration/android/setup)、Android 的 [`adb` 参考](https://developer.android.com/tools/adb)，以及 Flutter 的 [iOS 设置指南](https://docs.flutter.dev/platform-integration/ios/setup)。上文 Pakperk 专用的构建变体、策略、签名和测试命令来自本仓库，应当随实现一同更新。
