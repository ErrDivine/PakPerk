# 应用商店审核备注模板

请将此模板复制到 App Store Connect 和 Play Console，用于完全一致的已签名候选版本。在应用商店门户中完整填写每个方括号字段。切勿将审核账号凭据提交到仓库，也不得通过电子邮件发送，或粘贴到证据、Issue、日志或聊天中。

## 候选版本与环境

- 应用/构建版本：`[version + build number]`
- 应用商店/平台：`[App Store Connect / Play Console]`
- 环境：`[production / approved isolated review environment]`
- API 来源：`[public HTTPS origin]`
- 公开网站：`[published HTTPS URL]`
- 隐私政策：`[published HTTPS URL]`
- 服务条款：`[published HTTPS URL]`
- 社区准则：`[published HTTPS URL]`
- 支持：`[published HTTPS URL and monitored contact]`
- 网页端账户删除：`[published HTTPS URL]`
- 功能状态：`accounts=[on/off], library=[on/off], comments=[on/off], Plan
  03 Deep Reader/Passport/facets/visuals/checkpoints/annotations/evidence/memory/
  version diff/Assistant v2=[all off]`
- 候选版本功能绑定：`[schema-v6 SHA-256 plus exact states for all 24
  To Read First, Plan 02, and Plan 03 mobile flags from the schema-v4
  candidate/provenance manifests]`

当前仓库技术契约已绑定 Plan 03 的全部十项移动端控制，并定义了受保护的 schema-v6 已签名设备/私有研究场景。在针对完全一致候选版本的运行全部通过，且其余产品、隐私/法务、人工审核、实时模型、预发布和发布负责人门禁全部关闭前，必须保持应用商店候选版本中的每项 Plan 03 功能关闭。不得将受检验证器或尚未执行的工作流描述为 Plan 03 证据；执行状态仍为 `not_ready`。

审核账号凭据只能保存在门户的受保护审核字段中。首次确切的完整走查所用的一次性账号必须已验证电子邮箱，但不得设置公开用户名，也不得接受当前的《服务条款》/《社区准则》，以便候选版本能够展示发布评论的引导流程。该账号不含真实用户数据，也没有工作人员/内容审核员权限。请在受保护的发布证据中记录它的重置流程、到期时间和轮换负责人；不得在未记录该限制的情况下复用已完成引导的账号，从而削弱该流程。

### 一次性账号生命周期

审核前，请创建一个已验证电子邮箱、未设置公开用户名、未接受政策、不含真实用户数据且不具有工作人员或内容审核员角色的新账号。受保护的发布记录中只能记录其带密钥的账号引用哈希、创建和到期时间戳、重置流程哈希以及责任人；凭据和提供方主体标识必须留在应用商店门户或密钥管理器中。

走查完成或账号到期后，请提交并观察已记录的删除流程，确认应用账号和提供方身份均已不存在，撤销或轮换每项关联凭据，并删除不属于可复用脱敏环境的审核测试夹具。仅保留删除证据引用、生命周期/结果哈希、UTC 完成时间和负责人批准。如果清理失败、账号到期后仍可使用，或账号能绕过引导步骤，都必须阻止 `reviewerFlowId` 以及应用商店提交。

## 确切的审核走查流程

1. 在未登录状态下启动应用。**Read** 标签页会打开以元数据为优先的论文信息流。纵向滑动可切换论文；相应功能就绪时，横向滑动可在 Abstract、Introduction 和 Connections 之间切换。使用 arXiv 操作，确认操作系统浏览器打开确切的规范记录，而非内嵌 WebView。
2. 打开 **You**。无需账号即可使用隐私政策、服务条款、社区准则、支持、Settings、版本、许可证、外观和缓存控制。
3. 在任意论文中选择 **Save to To Read**。应用会说明需要身份验证的原因，然后打开操作系统浏览器。使用受保护的审核账号凭据登录。即使取消浏览器流程，当前论文和公开阅读功能也必须仍可使用。
4. 登录后，待处理的 Save 会自动完成。打开 **You > To Read**，选择已保存的论文，并确认它在 **Read** 的 Abstract 页面打开。返回操作会回到 To Read 列表。删除保存项和撤销删除后，所有可见的 Save 控件都必须同步更新。然后退出登录；账户所有的本地状态将解绑，但公开阅读仍可使用，因此下一个评论步骤将从真实的访客意图开始。
5. 打开某篇论文的 **Comments** 操作。保留的访客意图必须在登录后恢复，要求这个尚未完成设置的账号选择一次性公开用户名，并接受当前的《服务条款》和《社区准则》。发布完全一致的无害文本 `Store review test comment`，随后将其编辑为 `Store review
   test comment edited`，再删除。在选择 Send 之前，草稿文本保留在本地；删除后，该评论必须从公开列表中消失。
6. 在由 `[review fixture handle]` 发布的仅用于审核的预置评论上，打开上下文菜单并选择 **Report comment**。选择列出的某项原因并提交。重新打开菜单并选择 **Report user**；确认提示信息说明未添加屏蔽，且评论仍然可见。随后选择 **Block user**。该作者的评论应立即消失；该用户应出现在 **You > Blocked users** 中，并且可以解除屏蔽。切勿举报或屏蔽真实用户。
7. 打开 **You > Settings > Clear reading cache**。确认信息会说明：可重建的公开数据将被删除，而保存项、草稿、待同步工作、账户数据和阅读位置会保留。
8. 打开 **You > Settings > Delete account**。选中永久删除确认复选框，完成近期身份验证的浏览器步骤，然后提交。应用会进入删除状态，移除账户所有的本地数据，撤销本地会话，同时保持公开阅读可用。如果应用商店审核需要再次执行，请使用 `[fresh disposable account / reset
   procedure]`。
9. 不使用应用时，也可以通过上方的网页账户删除 URL 发起相同的删除请求。已发布的 Support URL 可用于联系支持并升级处理问题。

## 内容与安全行为

- 评论是公开的纯文本。发布评论必须先登录、设置公开用户名，并接受当前的《服务条款》和《社区准则》。
- 每条符合条件的第三方评论均提供相互独立的 Report comment、Report user 和用于屏蔽用户的 Block user 操作。内容审核人员可隐藏/恢复内容，并可停用/恢复账户，同时保留审计记录。
- 可单独禁用评论创建功能；紧急关闭开关关闭评论创建功能时，已有评论和论文阅读仍然可用。
- 生产环境的全文策略为 **strict**。应用始终显示论文元数据和 arXiv 链接，但只有在服务器策略允许时才显示生成的 Introduction、Connections 和聊天内容。未提供某项能力并不表示加载失败。
- v0.0 中不提供私信、关注、公开计数、声望积分、在线状态、广告、支付或后台定位功能。

## 仅用于审核的坐标与证据

- 预置论文标题/arXiv ID：`[non-sensitive public fixture]`
- 预置举报/屏蔽测试夹具的公开用户名：`[review-only account]`
- 审核环境的任何限制：`[none, or exact limitation approved by
  release owner]`
- 审核人/UTC 日期：`[name or controlled identifier + timestamp]`
- 已签名构建产物摘要和 SBOM 摘要：`[release evidence references]`
- 实体设备验收证据：`[schema-v6 controlled evidence
  reference covering all 42 ordered scenarios / 317 assertions / 254 metrics,
  the exact source-bound app-link origin, two-device removal, invalid refresh,
  links, protection, cache bounds, light/dark, To Read First authority/rollout,
  Add Paper resolution/retry, Plan 02 Search/Profile/Why/Brief/Alerts, and all ten
  Plan 03 reader/research scenarios; not a statement or repository-only result]`
- Plan 03 已签名设备证据：`[not_ready; do not submit a candidate with a
  Plan 03 mobile control enabled until the exact v6 device run and every
  implementation/privacy/external gate are passed]`
- 删除完成情况/引用：`[controlled evidence reference; no token,
  email, comment body, or provider subject]`
- 审核账号生命周期/引用：`[controlled creation, expiry,
  deletion, credential-rotation, and owner-approval reference; no credential,
  email, or provider subject]`

任何字段留空或填写“pending”都会阻止发布。此模板并不证明候选版本、账号、端点或应用商店提交确实存在。
