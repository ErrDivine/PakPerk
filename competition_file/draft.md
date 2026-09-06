Pakperk 项目实现方案

参赛方向：AI+X 应用——AI + 科研阅读与知识管理

项目定位：面向移动端、以证据可追溯为核心的科研阅读与研究记忆系统

事实口径：本文所称“已实现”，是指相应产品功能、接口、数据结构和验证机制已在项目中完成。服务器论文批处理及 Android、iOS 测试属于团队已经开展的项目验证。应用商店发布、代表性语料评测、签名设备全量验收以及法律和隐私审批仍需按照独立流程完成。文中涉及的性能数值如标注为“验收阈值”，不代表已经取得相同数值的实测成绩。


第一章 项目介绍

项目概况

Pakperk 是一款面向学生、科研人员和研发工程师的移动科研阅读应用，围绕“读什么、如何读、结论是否可信、阅读成果如何保留”四个连续问题展开。2025 年 arXiv 新增论文 284,486 篇，日均约 780 篇[1]。在论文供给快速增长的背景下，研究者面临的主要困难已经集中到阅读顺序安排、小屏阅读效率、AI 结论核验和知识长期复用。现有工具多分别处理检索、PDF 阅读、问答、关系探索或文献综述[2-6]，跨工具切换会打断阅读过程；持续推荐容易造成待读任务积压，缺少证据约束的问答也可能偏离原文。

项目提出“Queue First，Evidence First，Memory by Choice”三项原则。Queue First 将用户主动建立的 To Read 队列设为阅读流的首要依据。活动队列尚未完成时，系统不插入推荐；服务器在当前修订版本下确认队列为空后，推荐内容才可出现。Evidence First 要求 Assistant 的回答绑定当前论文、当前版本和实际检索到的证据块。服务端重新校验证据编号、章节、页码和字符范围，证据不足时返回明确的拒答结果。Memory by Choice 规定只有用户主动保存的批注、证据卡和研究线索进入长期记忆，普通浏览不会自动形成个人研究档案。

项目采用 GROBID、Rust 和 PostgreSQL/pgvector 构建论文处理链路，将 PDF 归一化为带章节结构、稳定对象键、页码定位和版本代际的文档。论文正文经过关键词与向量混合检索后，模型只能引用本轮允许的证据集合；论文之间的关系依据真实引用句归纳为“使用、扩展、比较、背景”等受控类型。Flutter 客户端将同一篇论文组织为 Abstract、Introduction + Assistant、Connections 三个阶段，并提供 Skim、Read、Inspect 三种阅读深度。全文下载和解析只由用户明确进入深度阅读触发，从而控制计算成本与版权风险。

目前项目已形成 Flutter Android/iOS 客户端、Rust/Axum API、Tokio 后台 Worker、PostgreSQL 16 + pgvector、GROBID、OIDC 账号、Drift 离线数据库以及部署运维体系。团队已在服务器上尝试批量处理数百篇论文，并在 Android、iOS 系统完成测试。固定演示语料包含 6 篇真实 arXiv 论文；15 个问答案例中，10 个有效问题均获得证据支持，5 个错误前提问题均正确拒答。项目由此完成了从论文发现、按需处理、证据核验到研究记忆沉淀的闭环，为后续扩大语料评测和正式发布奠定了基础。


第二章 项目实施方案

项目按照“规范数据入口、异步结构化处理、证据约束生成、移动端可靠同步、分阶段验证发布”的顺序实施。

一、数据接入与任务控制

系统以 arXiv 为规范论文来源。API 仅接受合法 arXiv ID 或白名单 URL，先将输入转换为规范标识，再请求元数据或文件，防止任意地址成为服务端下载目标。元数据经过 PostgreSQL 共享缓存和跨进程请求闸门；旧版 arXiv API 的请求起始时间默认至少间隔 3 秒，并遵守 Retry-After[15]。PDF 单文件限制为 50 MiB，下载到随机私有临时路径并计算 SHA-256，解析完成后删除。搜索、推荐、收藏、导入和摘要卡只使用元数据。用户首次进入 Introduction 或主动重试时，系统才创建幂等全文准备任务。

二、论文解析与稳定文档模型

后台 Worker 使用 GROBID 0.9.0 将 PDF 转换为 TEI XML，Rust 解析层限制 XML 体积和节点数量、拒绝自定义实体、清理页眉页脚噪声，并提取章节、段落、页码、引用区间、参考文献、图、表、公式和术语。每个文档对象都绑定论文 ID、generation、稳定键、内容哈希与解析器版本。arXiv 发布新版本后，系统创建新的 generation，旧版派生内容不再进入当前读取范围。批注迁移优先使用稳定键和精确引文；可靠性不足的候选进入人工复核，无法匹配的内容标记为孤立，原版本继续保留。

三、论文内检索与证据约束问答

正文按章节和段落切块，默认目标约 750 token，上限 900 token，重叠约 100 token。内容块同时进入 PostgreSQL 全文索引和 pgvector 向量索引[13]。提问时，检索范围限定为当前论文和当前 generation；关键词结果与向量结果通过 Reciprocal Rank Fusion 融合[8]，最多选择 6 个证据块和约 4,500 token 上下文。模型输出必须符合结构化 Schema，并提供 claim 级证据 ID。后端只接受本轮检索集合中的 ID，并再次核对论文、版本、章节、页码和字符范围。论文正文始终按不可信数据处理，不具有模型指令权限。

四、引用关系与渐进能力发布

系统解析参考文献及引用句，并结合 arXiv ID、DOI、标题相似度、作者、年份等信号进行实体对齐。置信度达到 0.90 才自动链接，0.80 至 0.90 标记为歧义。关系说明只使用已经保存的引用上下文，证据不足时返回 unknown。metadata、Introduction、Assistant、Connections、Passport、语义线索和视觉对象分别发布。结构化正文可先进入阅读状态，后续向量或关系任务失败不会使已有内容失效。

五、队列优先与离线同步

服务器通过每账号修订号、操作 UUID、删除墓碑和版本围栏维护 Library 权威状态。客户端将本地状态与操作记录写入同一 Drift 事务，通过持久化 outbox 在网络恢复后重试。同步引擎按论文串行发送操作，保留原操作 ID，并采用指数退避和 Retry-After。令牌、账号 ID 与认证 epoch 必须同时匹配，旧账号响应和待发送操作不能写入新账号范围。Library 的保存和删除接口不得触发 PDF、GROBID、模型或准备队列任务。

六、系统搭建与验证

后端采用 Rust/Axum 模块化单体和 Tokio Worker，数据层使用 PostgreSQL 16 与 pgvector，身份认证采用 OIDC Authorization Code + PKCE，移动端使用 Flutter 与 Drift。部署侧提供 Helm、不可变镜像、最小权限、只读文件系统、SBOM、依赖与容器扫描、OTLP 遥测、告警、备份恢复及回滚流程。项目通过单元测试、接口契约测试、PostgreSQL 集成测试、Flutter 组件与端到端测试，以及 Android/iOS 运行测试逐步验证各层行为。


第三章 项目创新性分析

一、实际应用场景创新

Pakperk 将用户已经选择的论文置于推荐之前。传统论文发现工具通常持续增加候选内容，本项目则要求自动阅读流先处理活动 To Read 队列。客户端本地为空、网络离线、修订号过期或存在待同步保存时，系统均暂停推荐，直至服务器给出当前修订版本下的空队列证明。这一设计把注意力管理落实为跨服务端、客户端和离线状态的统一规则。

移动阅读采用二维信息架构：纵向切换论文，横向进入 Abstract、Introduction + Assistant 和 Connections；Skim、Read、Inspect 在同一份结构化文档上提供不同阅读深度。用户可以先判断论文价值，再逐步查看正文、图表、公式、术语和引用来源。系统同时保留按钮、标签和原始论文入口，以兼顾学习成本和内容核验。

二、技术特点创新

全文处理权限与用户意图直接关联。搜索、推荐和收藏阶段只处理元数据，用户明确进入深度阅读后才允许下载和解析 PDF。这项约束同时降低服务器计算成本、上游接口压力和全文处理带来的版权暴露面。

项目将解析后的章节、文本块、图表、公式、引用、批注和版本差异统一绑定到 generation。新版本到来后，系统可以准确失效旧派生能力，并保留旧版本与批注迁移历史。Assistant、Paper Passport、语义线索和研究记忆均引用同一套来源对象，使阅读、生成、批注、导出与删除具有一致的数据依据。

各项能力采用渐进发布机制。正文结构完成后即可阅读，检索、关系分析和生成结果随后补齐；单项任务失败时，已完成能力继续可用。高风险功能还受服务端、移动端和部署配置共同控制，只有依赖和验收证据齐备后才开放。

三、系统算法创新

Assistant 采用限定论文与版本范围的混合检索。关键词检索保留精确术语优势，向量检索补充语义相关内容，RRF 用于融合两个排序结果。模型仅能从本轮允许的证据块中选择来源，后端再对 claim 与证据范围进行确定性校验。来源徽章由数据库可信字段生成，降低模型虚构编号、跨版本引用和提示注入带来的风险。

Connections 关注论文之间的引用理由。系统先定位引用句，再通过多信号实体对齐确认被引论文，最后在受控关系类型中生成说明。该方法避免将内容相似度直接解释为“使用”或“扩展”等学术关系。

推荐系统使用可解释候选生成器和固定版本评分，并将结果绑定到 Library、研究档案和反馈 revision。用户保存论文或账号状态变化后，过期推荐响应无法继续显示。推荐理由必须来自实际参与评分的特征，用户可以关闭个性化、重置或导出相关数据。

四、研究记忆创新

批注、证据卡、阅读检查点和 Memory 由用户主动创建，并保留论文版本与来源位置。复习行为不会改变 To Read 队列，私有研究内容默认不进入训练或推荐。用户可以导出或删除这些数据，形成可核验、可迁移、可持续更新的个人研究记录。


第四章 项目实现成果

一、系统实现规模

截至 2026 年 9 月 2 日的静态代码清点，项目包含 249 个 Rust 源文件、244 个 Dart 产品源文件、167 个 Flutter 测试文件和 12 个 CI 工作流文件；Rust 源码中共有 784 个 #[test] 或 #[tokio::test] 测试标记。Rust 0.2.0 工作区包括 API、论文 Worker、删除 Worker、迁移工具、管理员工具、遥测网关及 20 余个领域 crate。PostgreSQL 数据库已包含 24 个迁移版本，覆盖论文处理、账号、Library、评论、删除、推荐、研究档案、结构化文档、批注、Memory 和版本差异。OpenAPI 3.1 静态合同包含 90 条路径、115 个操作和 303 个 Schema。以上数据用于说明实现范围，不等同于声明所有测试已在任意环境下通过。

二、论文处理与内容质量

团队已在服务器上对数百篇论文开展批量处理尝试，验证从元数据获取、PDF 下载、结构化解析、切块、索引到能力发布的完整链路。固定演示语料包含 Transformer、BERT、RoBERTa、T5、RAG 和 LoRA 共 6 篇真实 arXiv 论文[7,29-33]。15 个论文问答案例完成人工复核，其中 10 个应回答案例均达到 answer_supported，5 个错误前提案例均达到 correct_abstention。6 个关键论文连接在参考文献匹配、关系标签、引用上下文支持和实际重要性四个维度通过人工检查。一次隔离环境中的 LoRA 按需处理从 queued 到 ready 约 30 秒，生成 7 个 Introduction 段落、64 条参考文献和 5 个关键连接；连续两次 Prepare 返回同一状态，验证了幂等处理路径。这些结果限定于固定论文、指定解析器和确定性模型组合，不代表跨学科总体准确率或线上延迟承诺。

三、可靠性与跨端体验

移动端确定性测试覆盖 500 篇缓存论文、100 条保存记录和 200 篇连续分页，并检查丢包、延迟返回、离线重试、相同 UUID 的 outbox 恢复、缓存淘汰、账号切换及双端同步。真实 OIDC 两客户端流程完成保存、重复投递、删除和墓碑同步，双方最终收敛到同一修订版本。团队已在 Android 和 iOS 系统完成测试，验证核心阅读、账号、缓存和同步流程能够在两类移动平台运行。

项目还定义了面向四类物理设备角色的完整验收规范，覆盖 Android 手势导航、Android 三键导航、iPhone 和 iPad/第二同步端，共包含 42 个有序场景、317 条行为断言和 254 个整数指标。这些数字描述的是验收范围，不作为全量物理设备测试已经执行的证明。性能验收要求至少采集 20 个缓存首个可读帧样本和 20 个页面打开过渡样本，目标为缓存首个可读帧 p95 不高于 1,500 ms、页面打开过渡不高于 700 ms；相关数值属于发布阈值，最终成绩仍以对应候选版本的实测证据为准。

四、创新成果与应用价值

项目已经把 Queue First 从交互主张落实为服务器快照、修订号、游标、客户端状态机和离线策略共同遵守的约束；将 Evidence First 落实为论文范围检索、结构化 claim、证据集合校验和原文跳转；将 Memory by Choice 落实为用户主动创建、可导出、可删除且不默认参与训练的私有研究对象。这些机制共同连接论文发现、阅读、核验和积累，减少工具切换，也为高校、实验室和研发团队在不同模型、成本及合规条件下部署提供基础。


第五章 项目合规风险分析

一、论文版权与数据来源风险

arXiv 描述性元数据适用 CC0，但论文全文仍受各自版权和投稿许可约束[15]。项目不向客户端重新分发服务器缓存的 PDF；原文件写入私有临时路径，解析完成后删除，客户端持续提供 arXiv 原始页面入口。strict 模式在 Worker、API 和移动缓存三个环节复核派生内容许可，许可未知或不受支持时停止发布。正式上线前还需持续核对 arXiv 接口条款、全文许可和真实部署拓扑，并避免任何可能被理解为 arXiv 背书的表述。

二、AI 输出与学术伦理风险

预印本、PDF 解析、检索和模型生成均可能存在错误。产品需清楚提示 AI 仅用于辅助定位和理解，研究者仍应查阅原文并独立判断。项目已通过限定论文检索、证据范围校验、证据不足拒答、版本记录和纠错反馈降低风险。公开发布前还需完成生成内容标识评估，并依据《人工智能生成合成内容标识办法》[17]及《生成式人工智能服务管理暂行办法》[16]评估适用义务。

三、个人信息与私有研究数据风险

OIDC、Library、评论、批注、Memory 和 Assistant 会处理账号信息及用户生成内容。项目采用最小必要收集、账号作用域隔离、正文不进入普通日志、数据导出和账号删除等措施。生产部署仍需依据《个人信息保护法》[18]和《网络数据安全管理条例》[19]评估委托处理、境内存储、跨境模型调用、备份和个人权利响应。移动端私有研究正文目前以普通 Drift/SQLite 文本保存，主要依赖操作系统沙箱、设备访问控制、平台文件保护和备份策略，尚未采用应用层 SQLCipher 加密；后续应结合威胁模型、迁移与恢复方案决定是否引入数据库加密。

四、内容治理与系统依赖风险

公开评论可能涉及违法有害信息、骚扰、冒名和未成年人保护。项目已实现评论举报、用户举报、拉黑、审核状态、管理员审计及发布熔断；在审核人员、告警、支持渠道和法律审批形成真实环境证据前，评论发布保持关闭，阅读、删除、举报和拉黑能力继续保留。系统对 arXiv、GROBID 和模型提供方的依赖还会带来接口变化、限流、宕机、成本及模型漂移风险。现有缓存优先、超时重试、模型适配层、渐进能力发布和回滚开关可以限制影响，后续仍需扩大跨学科、多语言、扫描型及图表公式密集论文的代表性评测。


第六章 参考文献

[1] arXiv. arXiv Annual Report 2025[R/OL]. 2026. https://info.arxiv.org/about/reports/2025_arXiv_annual_report.pdf（访问日期：2026-09-02）.

[2] Allen Institute for AI. Semantic Scholar: TLDR Feature[EB/OL]. https://www.semanticscholar.org/product/tldr（访问日期：2026-09-02）.

[3] Allen Institute for AI. Semantic Reader[EB/OL]. https://www.semanticscholar.org/product/semantic-reader（访问日期：2026-09-02）.

[4] Connected Papers. About Connected Papers[EB/OL]. https://www.connectedpapers.com/about（访问日期：2026-09-02）.

[5] SciSpace. Chat with Any PDF[EB/OL]. https://scispace.com/chat-pdf（访问日期：2026-09-02）.

[6] Elicit. Systematic Literature Reviews[EB/OL]. https://elicit.com/solutions/literature-review（访问日期：2026-09-02）.

[7] LEWIS P, PEREZ E, PIKTUS A, et al. Retrieval-Augmented Generation for Knowledge-Intensive NLP Tasks[C]//Advances in Neural Information Processing Systems 33. 2020: 9459-9474. https://arxiv.org/abs/2005.11401.

[8] CORMACK G V, CLARKE C L A, BÜTTCHER S. Reciprocal Rank Fusion Outperforms Condorcet and Individual Rank Learning Methods[C]//Proceedings of SIGIR 2009. 2009: 758-759. DOI:10.1145/1571941.1572114.

[9] LOPEZ P. GROBID: Combining Automatic Bibliographic Data Recognition and Term Extraction for Scholarship Publications[C]//Research and Advanced Technology for Digital Libraries. Berlin: Springer, 2009: 473-474. DOI:10.1007/978-3-642-04346-8_62.

[10] GROBID Contributors. GROBID Documentation: Introduction[EB/OL]. https://grobid.readthedocs.io/en/latest/Introduction/（访问日期：2026-09-02）.

[11] HEAD A, HSU V, CHEN M, et al. Augmenting Scientific Papers with Just-in-Time, Position-Sensitive Definitions of Terms and Symbols[C]//Proceedings of CHI 2021. 2021. https://arxiv.org/abs/2009.14237.

[12] FOK R, HEAD A, BRAGG J, et al. Scim: Intelligent Faceted Highlights for Interactive, Multi-Pass Skimming of Scientific Papers[C]//Proceedings of IUI 2023. 2023. https://arxiv.org/abs/2205.04561.

[13] pgvector Contributors. pgvector: Open-source Vector Similarity Search for PostgreSQL[CP/OL]. https://github.com/pgvector/pgvector（访问日期：2026-09-02）.

[14] PostgreSQL Global Development Group. PostgreSQL Documentation: SELECT—SKIP LOCKED[EB/OL]. https://www.postgresql.org/docs/current/sql-select.html（访问日期：2026-09-02）.

[15] arXiv. Terms of Use for arXiv APIs[EB/OL]. https://info.arxiv.org/help/api/tou.html（访问日期：2026-09-02）.

[16] 国家互联网信息办公室等. 生成式人工智能服务管理暂行办法[Z/OL]. 2023. https://www.cac.gov.cn/2023-07/13/c_1690898327029107.htm（访问日期：2026-09-02）.

[17] 国家互联网信息办公室等. 人工智能生成合成内容标识办法[Z/OL]. 2025. https://www.cac.gov.cn/2025-03/14/c_1743654685899683.htm（访问日期：2026-09-02）.

[18] 全国人民代表大会常务委员会. 中华人民共和国个人信息保护法[Z/OL]. 2021. https://flk.npc.gov.cn/detail?id=ff8081817b6472a3017b656cc2040044（访问日期：2026-09-02）.

[19] 国务院. 网络数据安全管理条例[Z/OL]. 国务院令第790号, 2024（2025-01-01施行）. https://www.cac.gov.cn/2024-09/30/c_1729384452307680.htm（访问日期：2026-09-02）.

[20] Flutter Authors. Flutter Documentation[EB/OL]. Google, 2026. https://docs.flutter.dev/（访问日期：2026-09-02）.

[21] The Rust Project Developers. The Rust Programming Language[EB/OL]. https://www.rust-lang.org/learn（访问日期：2026-09-02）.

[22] Tokio Contributors. Tokio: An Asynchronous Runtime for Rust[CP/OL]. https://tokio.rs/（访问日期：2026-09-02）.

[23] tokio-rs Contributors. axum: Web Application Framework[CP/OL]. https://github.com/tokio-rs/axum（访问日期：2026-09-02）.

[24] PostgreSQL Global Development Group. PostgreSQL 16 Documentation[EB/OL]. 2023. https://www.postgresql.org/docs/16/（访问日期：2026-09-02）.

[25] Keycloak Authors. Keycloak Documentation[EB/OL]. https://www.keycloak.org/documentation（访问日期：2026-09-02）.

[26] Drift Contributors. Drift Documentation[EB/OL]. https://drift.simonbinder.eu/（访问日期：2026-09-02）.

[27] OpenTelemetry Authors. OpenTelemetry Documentation[EB/OL]. https://opentelemetry.io/docs/（访问日期：2026-09-02）.

[28] Helm Authors. Helm Documentation[EB/OL]. https://helm.sh/docs/（访问日期：2026-09-02）.

[29] VASWANI A, SHAZEER N, PARMAR N, et al. Attention Is All You Need[C]//Advances in Neural Information Processing Systems 30. 2017: 5998-6008. https://arxiv.org/abs/1706.03762.

[30] DEVLIN J, CHANG M W, LEE K, et al. BERT: Pre-training of Deep Bidirectional Transformers for Language Understanding[C]//Proceedings of NAACL-HLT 2019. 2019: 4171-4186. DOI:10.18653/v1/N19-1423.

[31] LIU Y, OTT M, GOYAL N, et al. RoBERTa: A Robustly Optimized BERT Pretraining Approach[EB/OL]. 2019. https://arxiv.org/abs/1907.11692.

[32] RAFFEL C, SHAZEER N, ROBERTS A, et al. Exploring the Limits of Transfer Learning with a Unified Text-to-Text Transformer[J]. Journal of Machine Learning Research, 2020, 21(140): 1-67. https://jmlr.org/papers/v21/20-074.html.

[33] HU E J, SHEN Y, WALLIS P, et al. LoRA: Low-Rank Adaptation of Large Language Models[C]//International Conference on Learning Representations. 2022. https://arxiv.org/abs/2106.09685.
