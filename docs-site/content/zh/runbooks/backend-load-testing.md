# 后端预发布负载与时延门禁

**负责人：**服务负责人。**批准人：**发布经理和数据库负责人；
当演练任何已认证账户测试夹具时，隐私/安全负责人作为额外批准人。

`scripts/run_backend_load.py` 是一个可选加入、有界的 HTTP 负载门禁，针对已评审的预发布部署。它始终演练访客 Feed 分页和访客论文元数据，并且可以添加已认证的论文库读取、首个已发布评论页面、权威的队列/推荐阅读 Feed、标题搜索、显式授权的论文库写操作，以及显式确认的幂等论文导入重放。普通 CI 只运行其确定性的环回契约测试；CI 绝不调用真实环境。

此工具未获准用于生产环境。请取得部署负责人批准，确认预发布容量和限流余量，并且只使用合成的论文和一次性的预发布账户。在生成的证据旁边记录精确的源修订、部署修订/拓扑、数据库状态和饱和度、故障画像、观察窗口和遥测链接。该 JSON 有意不包含那些可能敏感的外部坐标。

首选的共享执行路径是仅手动的**预发布后端负载门禁** Actions 工作流。它只从 `main` 运行，检出可从 `main` 到达的精确已评审完整 SHA，进入受保护的 `staging` 环境，使用有界的选择输入，并且即使 SLO 门禁失败也会上传聚合证据。配置该环境时使用 `PAKPERK_STAGING_API_ORIGIN`，并且仅针对选定的已认证场景配置 `PAKPERK_STAGING_LOAD_TOKEN` 密钥。已认证评论使用合成的 `PAKPERK_STAGING_LOAD_COMMENTS_PAPER_ID` 变量。写操作还需要专用的、默认缺席的 `PAKPERK_STAGING_LOAD_MUTATION_PAPER_ID` 变量以及分发确认短语。环境审核者必须在批准运行前验证那些测试夹具和请求的负载画像。该工作流会把 `0400` 证据和校验和打包进 tar 归档，使内部的仅限所有者模式在产物传输中幸存；仓库和环境访问控制仍然决定谁能下载 Actions 产物。

## 访客门禁

输出父目录必须已存在，而输出路径必须尚不存在。预发布只接受无凭据的 HTTPS 源，不遵循重定向，不使用代理环境变量，验证平台 TLS 信任链，并限制响应体大小。典型的访客运行是：

```bash
python3 scripts/run_backend_load.py \
  --api-origin https://api.staging.example.org \
  --environment staging \
  --output /secure/evidence/pakperk-backend-load.json \
  --evidence-id release-0.2.0/staging-backend-load-01 \
  --source-revision aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --duration-seconds 60 \
  --concurrency 8 \
  --max-requests 10000 \
  --request-timeout-seconds 5 \
  --preflight-timeout-seconds 60 \
  --minimum-paper-records 200 \
  --minimum-samples-per-scenario 20
```

请替换示例源和 40 字符修订。预检会跟随有界的 Feed 游标，直到拥有至少 200 个唯一 UUID 论文记录。被测量的 Feed 请求复用这些发现的页面，而元数据请求则采样发现的论文 ID。访客请求绝不会收到 Bearer 令牌，即使同一运行中启用了已认证场景也是如此。

工作负载会在时长或请求上限中首先到达者处停止调度。并发限制为 64，时长为一小时，测量请求为 100,000，每个请求超时为 30 秒，预检为五分钟加上至多一个进行中的请求超时，每个响应为 8 MiB（二进制兆字节）。预热、预检页面、写操作和论文库快照计数分别有界。

## 已认证读取

把当前的合成账户访问令牌放入仓库之外的常规文件。它必须只包含令牌加上至多一个行结束符，大小为 16–65,536 字节，具有诸如 `0600` 之类的仅限所有者权限，并且不是符号链接。绝不把令牌放入参数、环境变量、证据路径、终端记录、议题或产物中。

添加论文库读取和评论首页读取：

```bash
python3 scripts/run_backend_load.py \
  --api-origin https://api.staging.example.org \
  --environment staging \
  --output /secure/evidence/pakperk-backend-auth-load.json \
  --evidence-id release-0.2.0/staging-backend-auth-load-01 \
  --source-revision aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --duration-seconds 60 \
  --concurrency 8 \
  --max-requests 10000 \
  --bearer-token-file /secure/runtime/pakperk-load-token \
  --include-library \
  --comments-paper-id 00000000-0000-4000-8000-000000000001
```

论文库场景请求一个有界的 `to_read` 页面。评论场景只请求 `limit=50` 并且绝不跟随 `next_cursor`，因此它无法加载整个讨论。响应体在内存中验证并丢弃；令牌、URL、类别值、论文 ID、标题、评论和其他响应内容绝不会被打印或序列化进证据。

## Plan 02 队列、搜索和导入测试夹具

全部四个 Plan 02 场景默认在分发时关闭。`reading_feed_queue` 使用一个专用的受保护合成账户，其服务器权威响应是 `to_read`；`reading_feed_recommendations` 使用另一个受保护账户，其响应是服务器确认的 `recommendations`。每个令牌都通过自己的仅限所有者常规文件提供，绝不通过参数或保留的产物提供，并且每个请求使用 20 的有界页面大小。它们的默认 p50/p95/p99 限制是 350/700/1,400 ms，错误率至多 1%。这是两个单独的权威测试夹具；一个账户或令牌绝不能同时充当两者。

`paper_title_search` 只把从仅限所有者常规文件加载的受保护规范化查询发送到 `POST /v1/me/paper-searches`，并带 `limit=8`。一次私有预检会预热并验证有界响应。测量的搜索请求上限为九个，因此预检加测量不会超过配置的每分钟十次账户限制；受保护的工作流因此要求至多九个的场景样本下限。其默认 p50/p95/p99 限制是 500/1,000/2,000 ms，错误率至多 1%。

`paper_import_replay` 是一个具备写能力、默认关闭的重放检查。它要求 `--allow-paper-import-replays`、一个规范 UUID 操作 ID、受保护的 Bearer 令牌文件，以及一个包含一个规范 arXiv ID 的仅限所有者常规文件全部齐备。预检和每个测量请求都在正文和 `Idempotency-Key` 中发送同一操作 ID；每个测量响应必须把该操作绑定为带自洽论文与同步修订技术契约的规范已保存条目。CLI 从配置的每分钟二十次账户限制中保留一个请求，因此其硬上限是 19；受保护的工作流把测量上限缩小到 5 或 10，并额外要求精确的分发确认 `RUN_DEDICATED_STAGING_PAPER_IMPORT_REPLAYS`。其默认 p50/p95/p99 限制是 350/700/1,400 ms，错误率至多 1%。未播种的操作可以创建一个持久的预发布导入，因此评审者必须在运行前后验证一次性测试夹具和清理状态。

该工作流会以 `0600` 模式创建所有令牌/查询/导入测试夹具文件，在实体化后取消设置源密钥/变量，在退出时移除文件，并且只打包不含内容的聚合证据。该证据设置 `private_fixture_content_recorded=false`；它不包含令牌、查询、标题、URL、arXiv ID、操作 ID、账户身份、结果元数据或游标。仓库环回测试证明这些限制和脱敏技术契约，但没有已提交到代码仓库的产物能证明此受保护工作流已针对发布候选版本运行。真实的受保护预发布结果、拓扑/数据库上下文、不可变产物摘要和可问责的批准仍然是必需的。

## 显式写操作门禁

Library 写操作负载默认关闭，并且要求 `--allow-library-mutations`、`--library-mutation-paper-id` 和一个令牌文件全部齐备。使用专用的一次性预发布账户，以及一个在该账户完整有界 `to_read` 快照中缺席的现有合成论文。以并发 `1` 单独运行写操作检查，以获得稳定的时延证据：

```bash
python3 scripts/run_backend_load.py \
  --api-origin https://api.staging.example.org \
  --environment staging \
  --output /secure/evidence/pakperk-backend-mutation-load.json \
  --evidence-id release-0.2.0/staging-backend-mutation-load-01 \
  --source-revision aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --duration-seconds 30 \
  --concurrency 1 \
  --max-requests 1000 \
  --minimum-samples-per-scenario 10 \
  --bearer-token-file /secure/runtime/pakperk-load-token \
  --allow-library-mutations \
  --library-mutation-paper-id 00000000-0000-4000-8000-000000000002 \
  --max-library-mutation-requests 20
```

运行器会交替执行幂等的收藏/移除操作，只允许一个进行中的写操作，把测量的写操作请求上限设为 100，并且总是在测量窗口之后发送一次最终的幂等移除。该清理请求不计入配置的上限之内。清理失败会使门禁失败。强制终止、机器故障或丢失的响应仍可能中断清理：在任何重跑之前检查合成账户并手动移除测试夹具。成功的移除会留下同步墓碑，并且每次尝试都会消耗预发布限流预算，因此此模式不适用于真实用户账户。

## 阈值与故障画像

每个启用的场景都会强制执行最小样本数、最大错误率，以及按最近秩法计算的请求成功 p50、p95 和 p99 时延。默认值为：

| 场景 | p50 延迟 | p95 延迟 | p99 延迟 | 错误率 |
| --- | ---: | ---: | ---: | ---: |
| 暖 Feed 页面 | 250 毫秒 | 500 毫秒 | 1,000 毫秒 | 1% |
| 缓存元数据 | 125 毫秒 | 250 毫秒 | 500 毫秒 | 1% |
| Library 页面 | 250 毫秒 | 500 毫秒 | 1,000 毫秒 | 1% |
| Read Feed（活跃队列） | 350 毫秒 | 700 毫秒 | 1,400 毫秒 | 1% |
| Read Feed（推荐） | 350 毫秒 | 700 毫秒 | 1,400 毫秒 | 1% |
| 论文标题搜索 | 500 毫秒 | 1,000 毫秒 | 2,000 毫秒 | 1% |
| 首个评论页面 | 350 毫秒 | 700 毫秒 | 1,400 毫秒 | 1% |
| Library 写操作 | 250 毫秒 | 500 毫秒 | 1,000 毫秒 | 1% |
| 论文导入重放 | 350 毫秒 | 700 毫秒 | 1,400 毫秒 | 1% |

使用重复的 `--threshold NAME=P50_MS,P95_MS,P99_MS,ERROR_RATE` 覆盖显式场景；例如 `--threshold metadata=100,200,400,0.005`。使用 `--scenario-weight NAME=WEIGHT` 更改一个 Feed 请求对四个元数据请求以及每个可选场景一个请求的默认组合。

要进行可重复的客户端降级网络演练，请用 `--simulated-network-delay-ms`（0–5,000）设置固定的附加延迟，并用 `--simulated-packet-loss-rate`（0–1）设置确定性的合成丢包。丢包选择会对证据 ID、源修订、场景和序列进行哈希；相同的输入复现相同的选择。这些控制不模拟带宽、抖动、TCP 重传或服务器端依赖故障。单独记录任何基础设施级故障注入，并且不要把客户端画像声称为真实的丢包测量。

## 证据与解读

该工具在配置、预检、清理、样本下限、时延、错误率、预热或运行器失败时以非零值退出。它会在返回阈值失败之前写入规范、按键排序的 JSON。测试工具会拒绝已存在的路径，以所有者可读的 `0400` 原子创建文件，并且只输出聚合计数、有界错误类别、时延百分位、配置的边界、场景名称、源 SHA-256、提供的证据 ID/修订以及显式限制。把该文件哈希并存储到经批准的不可变发布证据系统中；仅靠本地文件系统权限不是持久的不可变性或批准。

此后端门禁只覆盖生产计划第 19.6 节的 HTTP 部分。它不测量 Flutter 帧构建/光栅化时间、设备上 SQLite 查询时延或大小、500 篇论文缓存/100 篇已收藏论文状态、PaperReader 保留、内存警告/生命周期恢复、真机行为或移动端 Feed 合并并发行为。这些仍是独立的真机和移动端性能分析门禁。评论请求演示了此测试工具的有界首页使用；它不能替代移动端分页保留测试。

运行本地、无真实调用的契约套件：

```bash
python3 scripts/test_backend_load.py
```
