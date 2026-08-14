# 移动应用链接

第一阶段注册并验证这些入口点：

```text
pakperk://paper/{paper_id}
pakperk://paper/{paper_id}/comments
https://pakperk.app/p/{paper_id}
https://pakperk.app/p/{paper_id}/comments
https://pakperk.app/arxiv/{arxiv_id}
```

Paper IDs 必须是 UUID。arXiv IDs 可以使用现代格式或一个旧版档案格式，其中斜杠在 URL 中使用百分号编码。路由器仅接受精确的 HTTPS 原点，拒绝凭据、端口、查询字符串、片段、意外的段、遍历和过长或格式错误的标识符，并在未发出论文请求的情况下关闭读取。

Android intent 过滤器和 iOS URL 方案/关联域权限声明已提交到原生主机。这些声明本身并不能建立经过验证的生产通用链接。在签署发布之前，必须执行以下操作：

1. 通过 `https://pakperk.app/.well-known/assetlinks.json` 提供最终的 Android 应用程序 ID 和所有活跃的 **Play 应用签名** 证书 SHA-256 指纹。本地签名 AAB 上的上传密钥证书是不同的，不能用于已安装应用的关联。
2. 通过 `https://pakperk.app/.well-known/apple-app-site-association` 提供最终的 Apple 团队 ID、捆绑 ID 以及仅支持的 `/p/*` 和 `/arXiv/*` 路径。
3. 将最终的包/捆绑 ID、Apple 团队 ID 和 Play 应用签名证书指纹放入用于发布的受保护 Helm 值中。图表会渲染这两个文档，如果应用程序 ID 不匹配 `app.pakperk.pakperk`，则生产渲染会失败。
4. 从 AAB/APK 提取包/版本和上传密钥证书，以及从 IPA 提取团队/捆绑身份。要求两个 Android 候选应用共享上传证书，但比较 `assetlinks.json` 与独立保护的 Play 应用签名指纹：

   ```bash
   PAKPERK_RELEASE_ENV=production \
   PAKPERK_ANDROID_PACKAGE=app.pakperk.pakperk \
   PAKPERK_ANDROID_SHA256="$PLAY_APP_SIGNING_SHA256" \
   PAKPERK_APPLE_TEAM_ID="$APPLE_TEAM_ID" \
   PAKPERK_APPLE_BUNDLE_ID=app.pakperk.pakperk \
   ./scripts/verify_mobile_associations.sh assetlinks.json apple-app-site-association
   ```

   在提交任一商店构建之前，获取部署的 URL 时不跟随重定向，并要求 HTTP 200 响应，且 `Content-Type: application/json`。
5. 通过 HTTPS 直接提供这两个文件，并确保正确的 JSON 内容类型，且不进行重定向。
6. 验证文件与已签名的发布候选版本，然后在物理 Android 和 iOS 设备上测试冷启动、温启动和已运行的应用链接。
7. 确认格式错误和恶意源的 URL 保持在浏览器中或在未发出论文请求的情况下关闭读取，并且有效的公共链接可以打开摘要。

受保护的物理移动验收方案 v3 通过一个有序的 Android/iOS 场景完成步骤 6 和 7：每个平台上的 `/p/*` 和 `/arxiv/*` 都从冷启动、温启动和已运行状态进行分发（共 12 个有效分发），恶意源必须在关闭读取时产生零个论文请求。允许的精确测试源从已审查的移动配置中读取，通过规范的 schema-2 源绑定和驱动请求传递，并在保留的证据中再次要求；它不能在分发时选择。通过的标记仍然是受保护的执行证据，而不是平台所有者审查部署的关联和签名身份的替代品。

手动 `公共边缘验证` 工作流程自动化了步骤 1 到 5 的无凭证技术部分，针对确切的命名环境：它要求直接 HTTPS 200 JSON，验证关闭关联文档与受保护的 Play 应用签名指纹和 Apple 团队/捆绑身份，将站点通知标记绑定到选定的 `main` 版本，并仅保留净化的摘要/结果。它不会检查已签名的 AAB/APK/IPA 字节，证明商店签名的保管权，或测试操作系统链接分发。即使该工作流程通过，步骤 4 和 6 中的由工件派生的身份检查和冷启动/温启动/已运行的物理 Android 和 iOS 矩阵仍然是强制性的。

提交的主机配置使用 `pakperk.app` 作为生产链接源。更改该源需要对路由器允许列表、两个原生主机、两个外部关联文件、测试和已发布的链接进行原子更新。
