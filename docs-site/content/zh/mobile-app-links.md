# 移动端应用链接

阶段 1 注册并校验以下深度链接入口：

```text
pakperk://paper/{paper_id}
pakperk://paper/{paper_id}/comments
https://pakperk.app/p/{paper_id}
https://pakperk.app/p/{paper_id}/comments
https://pakperk.app/arxiv/{arxiv_id}
```

论文 ID 必须是 UUID。arXiv ID 可以采用现代格式，也可以采用旧版分类号格式；后者的斜杠必须在 URL 中进行百分号编码。路由器只接受已配置的 HTTPS 来源（包括其实际生效的端口）；它会拒绝用户凭据、不匹配的端口、查询字符串、URL 片段、预期之外的路径段、路径遍历，以及过长或格式错误的标识符。校验失败时默认拒绝该链接并回到 Read，且不发起论文请求。

Android Intent 过滤器，以及 iOS 的自定义 URL Scheme 和 Associated Domains（关联域）权限声明，均已纳入版本控制并配置在原生宿主工程中。仅有这些声明还不足以建立经过验证的生产 Android App Links 或 iOS Universal Links。在发布经过签名的版本之前，运维人员必须完成以下工作：

1. 通过 `https://pakperk.app/.well-known/assetlinks.json` 提供最终的 Android 应用 ID（application ID），以及所有仍在使用的 **Play App Signing**（Play 应用签名）证书的 SHA-256 指纹。本地签名 AAB 中的上传密钥证书与应用签名证书并不相同，绝不能用它来建立已安装应用的关联。
2. 通过 `https://pakperk.app/.well-known/apple-app-site-association` 提供最终的 Apple Team ID、Bundle ID，以及严格限定的 `/p/*` 和 `/arxiv/*` 路径。
3. 将最终的 Android 包名、iOS Bundle ID、Apple Team ID 和 Play App Signing（Play 应用签名）证书指纹写入发布所用的受保护 Helm 配置值。Helm Chart 会据此渲染这两份文件；如果应用 ID 与 `app.pakperk.pakperk` 不一致，生产渲染会失败。
4. 从 AAB/APK 中提取包名、版本号和上传密钥证书，并从 IPA 中提取 Team ID 与 Bundle ID 身份信息。要求两个 Android 候选产物使用同一个上传证书；但是，校验 `assetlinks.json` 时，必须与受到独立保护的 Play App Signing（Play 应用签名）指纹进行比对：

   ```bash
   PAKPERK_RELEASE_ENV=production \
   PAKPERK_ANDROID_PACKAGE=app.pakperk.pakperk \
   PAKPERK_ANDROID_SHA256="$PLAY_APP_SIGNING_SHA256" \
   PAKPERK_APPLE_TEAM_ID="$APPLE_TEAM_ID" \
   PAKPERK_APPLE_BUNDLE_ID=app.pakperk.pakperk \
   ./scripts/verify_mobile_associations.sh assetlinks.json apple-app-site-association
   ```

   提交任一平台的应用商店构建之前，请在不跟随重定向的情况下请求已部署的 URL，并要求响应为 HTTP 200，且 `Content-Type: application/json`。
5. 通过 HTTPS 直接提供这两份文件，使用正确的 JSON 内容类型，并且不得重定向。
6. 使用已签名发布候选版本校验这两份文件，然后在实体设备上分别覆盖冷启动、温启动和应用已在运行三种情形下的 Android App Links 与 iOS Universal Links。
7. 确认格式错误或具有恶意来源的 URL 会留在浏览器中，或者在失败时默认拒绝并回到 Read；同时确认有效的公开链接会打开 Abstract。

受保护的移动端实体设备验收 schema v6 通过一套严格有序的 Android/iOS 场景完成步骤 6 和 7：在两个平台上，都要分别在冷启动、温启动和应用已经运行状态触发 `/p/*` 与 `/arxiv/*`（共 12 次有效触发）；恶意来源必须保证论文请求数为零，并在失败时默认拒绝并回到 Read。获准的预发布环境来源从经审核的移动端配置中读取，且必须保证其完全一致；该值通过规范的 schema-2 源绑定和驱动程序请求传递，并在留存证据中再次校验，不能在执行链接分派时临时选择。通过标记始终只是受保护的执行证据，不能替代平台负责人对已部署关联文件和签名身份信息的审核。

手动触发的 `public edge verification` 工作流会针对名称完全匹配的指定环境，自动执行步骤 1 至 5 中无需凭据的技术检查：它要求端点通过 HTTPS 直接返回 200 JSON 响应；依据封闭式结构规则，使用受保护的 Play App Signing（Play 应用签名）指纹以及 Apple Team ID 与 Bundle ID 身份信息校验关联文件；将站点公告的源码修订标记绑定到选定的 `main` 修订版本；并且仅保留经过脱敏的摘要和检查结果。该工作流不会检查已签名 AAB/APK/IPA 的原始字节，也无法证明应用商店签名密钥的保管权，还不会实际触发操作系统的链接分派。即使该工作流通过，步骤 4 和 6 中从产物提取身份信息的校验，以及 Android 和 iOS 实体设备上的冷启动、温启动和应用已在运行测试矩阵，仍为强制要求。

已纳入版本控制的原生宿主配置使用 `pakperk.app` 作为生产链接来源。若更改该来源，必须以一次原子变更同步更新路由器允许列表、Android 和 iOS 两个原生宿主工程、两份对外关联文件、测试和已发布链接。
