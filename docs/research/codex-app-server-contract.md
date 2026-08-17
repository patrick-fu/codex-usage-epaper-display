# UsageInk 的 Codex app-server 集成契约

研究日期：2026-08-18。目标是让 UsageInk macOS App 通过本机 `codex app-server --stdio` 读取账户和 ChatGPT Codex 用量，并把结果转换为 Usage Snapshot；不调用 ChatGPT 私有 HTTP API，不写入 Codex 凭据。

## 结论（建议实现）

1. 启动 `codex` 可执行文件的 `app-server --stdio`，stdin/stdout 使用一行一个 JSON 的 JSONL；stderr 只收集诊断日志。协议是 JSON-RPC 2.0 的线协议变体（省略 `jsonrpc` 字段）。这是上游 app-server README 的明确约定（[protocol](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#protocol)）。
2. 最低支持版本固定为 `codex-cli 0.147.0`（本研究机器实测版本）；启动后执行一次 capability probe。版本低于 0.147.0、无法生成/识别所需方法，或响应 schema 不兼容时，显示“需要升级 Codex”，不猜测字段。上游没有承诺稳定的跨版本协议，因此按运行中的 CLI 版本生成 schema（[message schema](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#message-schema)）。
3. 每个进程只建立一个连接：发送 `initialize` request，等待 response，再发送 `initialized` notification；只有完成这一步后才请求账户和限额。重复 initialize 或握手前请求都应归类为协议错误（[initialization](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#initialization)）。
4. 读取顺序为并行或串行的 `account/read` 与 `account/rateLimits/read`；两者都返回后才发布一个新的 Usage Snapshot。限额更新通知 `account/rateLimits/updated` 是稀疏 rolling update，必须 merge 到最近一次完整 snapshot，或重新调用 read（[auth endpoints](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#auth-endpoints)）。
5. 账户未登录、OpenAI auth 不可用、无 rate-limit 数据和临时网络失败必须是不同状态；不能把 `null` 限额当作 0%。`account/read` 的 `requiresOpenaiAuth` 反映当前 provider 是否需要 OpenAI 凭据；`account` 也可能为 `null`（[account/read field notes](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#1-accountread)）。

## 二进制发现与最低版本

- 允许用户在设置中指定绝对路径；否则使用 macOS `PATH` 中的 `codex`（本机为 `/opt/homebrew/bin/codex`）。不要扫描任意目录或下载二进制。
- 先运行 `codex --version`，要求可解析 `codex-cli <major>.<minor>.<patch>` 且版本 `>= 0.147.0`。版本只是最低兼容门槛，不是 schema 版本保证。
- 以实际选中的 binary 执行 `codex app-server --stdio`；不要依赖默认 transport 以外的 websocket/unix socket。上游明确 stdio 是默认 JSONL transport，而 websocket 仍是 experimental/unsupported（[protocol](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#protocol)）。
- 对用户可见的错误只保留 binary 路径、版本和分类；不要把 command line、环境变量或 stderr 原文上传。

## JSONL 握手与请求

```json
{"method":"initialize","id":1,"params":{"clientInfo":{"name":"usageink","title":"UsageInk","version":"<app-version>"}}}
{"method":"initialized","params":{}}
{"method":"account/read","id":2,"params":{"refreshToken":false}}
{"method":"account/rateLimits/read","id":3}
```

`clientInfo.name` 会用于 OpenAI Compliance Logs Platform；应使用稳定、可识别的 `usageink`，不要放邮箱、机器名或用户内容（[initialization](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#initialization)）。UsageInk 不需要 experimental API capability；不要发送 `experimentalApi: true`。

`initialize` response 的稳定字段是 `userAgent`、`codexHome`、`platformFamily`、`platformOs`。仅将它们用于诊断，不显示或上传 `codexHome`。

## 账号与限额数据映射

`account/read` response：

```json
{"account":{"type":"chatgpt","email":"user@example.com","planType":"pro"},"requiresOpenaiAuth":true}
```

将 `account` 缺失或 `requiresOpenaiAuth == true` 映射为“需要登录/授权”提示；email 只在本地短暂使用，不进入 Display Frame 或遥测。`planType` 可作为本地诊断元数据，不能决定窗口是否存在。

`account/rateLimits/read` 的关键 response：

```json
{
  "rateLimits": {
    "limitId": "codex",
    "primary": {"usedPercent": 13, "windowDurationMins": 10080, "resetsAt": 1787499508},
    "secondary": null,
    "credits": {"hasCredits": false, "unlimited": false, "balance": "0"},
    "planType": "pro",
    "rateLimitReachedType": null
  },
  "rateLimitsByLimitId": {"codex": {"...": "same snapshot shape"}},
  "rateLimitResetCredits": {"availableCount": 0, "credits": []}
}
```

- `primary`/`secondary` 是可空 quota windows；显示 `usedPercent`、`windowDurationMins`、`resetsAt`。`resetsAt` 是 Unix seconds，转换为本地时区前校验范围。
- 首选 `rateLimitsByLimitId.codex`；缺失时回退到顶层 `rateLimits`，仅当其 `limitId == "codex"` 或 `limitId` 缺失时。不要硬编码 `codex_bengalfox` 等其他 bucket；可保留它们作诊断但不把 `limitName` 当稳定 ID。
- `credits.balance` 是字符串，按 Decimal 解析；`credits == null` 表示未知，不是 0。`rateLimitReachedType == null` 表示未报告达到某类限制，不等同于“无限”。
- `rateLimitResetCredits` 只在完整 read 中有权威快照；UsageInk 当前不消费 reset credit，也不调用写入型 account RPC。
- 上游类型定义与字段说明见 [`GetAccountRateLimitsResponse` / `RateLimitSnapshot`](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/v2/account.rs)。

监听 `account/rateLimits/updated` 时，只 merge 通知中出现的非空字段；通知中的 nullable account metadata 不应清除已有值。收到无法匹配 bucket 的更新时，重新 `account/rateLimits/read`。上游明确说明该通知是 sparse rolling update（[source](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/v2/account.rs#L528-L535)）。

## 进程生命周期与超时

- `Process` 状态：`starting → initialized → refreshing → idle → stopping → stopped`；同一时刻最多一个 app-server 子进程。
- 启动后 5 秒内必须收到 initialize response；单个 account read 10 秒超时。超时后先关闭 stdin，等待短暂退出，再 terminate/kill；下次刷新建立全新进程。
- 应用进入后台或刷新完成后退出进程，避免常驻读取。若未来需要持续更新，可保持一个连接并仅监听通知，但必须有 idle watchdog。
- stdin EOF、stdout EOF、非 0 exit、无法解析 JSONL 都是 transport/process failure；丢弃未完成请求，保留上一个 Usage Snapshot 并标为 stale。
- app-server 没有本任务需要的“shutdown” RPC；优雅关闭是关闭 stdin/连接并等待子进程退出。不要向 stdout 写非 JSONL 内容。
- 上游 transport 使用有界队列；拥塞时会返回 JSON-RPC `-32001` / `Server overloaded; retry later.`，按可重试 transport error 处理并使用带 jitter 的指数退避（[backpressure](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#protocol)）。

## 认证与错误分类

UsageInk 只读，不调用 `account/login/start`、`account/login/cancel`、`account/logout`，不接触 OAuth token、API key 或 `CODEX_ACCESS_TOKEN`。认证由用户已有 Codex CLI 状态负责。上游列出的模式包括 ChatGPT managed、API key、personal access token 等（[auth endpoints](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#auth-endpoints)）。

错误分类及 UI 行为：

| 分类 | 证据 | 行为 |
| --- | --- | --- |
| binaryMissing/versionTooOld | 找不到 `codex` 或版本低于 0.147.0 | 引导安装/升级；不重试 |
| transportStart/exit/invalidJSON | spawn、EOF、stderr/JSONL 失败 | 保留 stale snapshot；短退避重试一次 |
| protocolNotInitialized/alreadyInitialized/methodNotFound/invalidParams | JSON-RPC error；包括握手顺序错误、旧 schema | 标记 incompatible，停止本轮 |
| authRequired | `requiresOpenaiAuth: true`、`account == null` 或 auth error | 显示“请在 Codex 登录”；不读取凭据、不自动登录 |
| backendUnauthorized/forbidden | RPC error 或上游 HTTP 401/403 | 显示登录过期/无权限；等待用户在 Codex 重新登录 |
| rateLimitUnavailable | read 成功但 windows 为 null | 显示“限额暂不可用”，不是 0% |
| overloaded/timeout | `-32001` 或本地超时 | 可重试，指数退避；避免并发刷新 |
| unknown | 未知 error code/字段 | 安全降级为 unavailable；记录脱敏诊断 |

不要按错误 message 文本做唯一判断；优先 JSON-RPC code、是否有 result、`requiresOpenaiAuth` 和结构化字段。未知字段必须忽略；缺失必需字段则本次 snapshot 无效。

## Schema 兼容策略

- 将 `codex app-server generate-json-schema --out <temporary-dir>` 作为开发/CI fixture 来源；生成物与运行该命令的 CLI 版本严格匹配（[message schema](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md#message-schema)）。不要在生产启动时写入用户目录。
- Swift 解码使用 `JSONDecoder` 的 camelCase 映射和可选字段；对 `rateLimitsByLimitId`、`rateLimitResetCredits`、`credits`、`individualLimit`、未知 enum 值全部容错。
- 兼容判定只要求四个 RPC 存在且核心字段类型正确：initialize response、account/read response、rateLimits/read response、account/rateLimits/updated notification。额外字段向前兼容。
- schema 或响应不兼容时不得按旧字段位置解析；报告版本与方法名，等待升级。

## 隐私约束

- 不记录或上传 token、API key、OAuth URL/code、完整 email、`codexHome`、机器名、installation ID、原始 stderr、原始 JSON-RPC payload。
- Display Frame 只包含 Usage Window 的百分比、窗口时长和 reset 时间；不显示 email、账户 ID 或 credits 明细，除非产品另行明确授权。
- 日志只记录：CLI 版本、RPC 方法名、耗时、错误分类、字段存在性和脱敏的 JSON-RPC code。
- `clientInfo.name` 是合规日志标识；保持稳定为 `usageink`，`version` 使用 App 版本。上游 README 特别警告该名称会被 OpenAI Compliance Logs Platform 使用。
- app-server CLI 帮助显示 analytics 默认关闭；UsageInk 不添加 `--analytics-default-enabled`，也不修改用户 analytics 配置。所有刷新均为本机子进程调用。

## 测试夹具与验收

提交仓库的测试夹具应是脱敏 JSONL，不含真实 email、path、时间戳之外的账户标识：

1. `handshake-success.jsonl`：initialize response + initialized 后的 account/read 和 rateLimits/read。
2. `handshake-order-errors.jsonl`：握手前请求、重复 initialize，验证错误分类。
3. `account-unauthenticated.jsonl`：`account: null` / `requiresOpenaiAuth: true`。
4. `rate-limits-null-and-multi-bucket.jsonl`：null windows、`rateLimitsByLimitId.codex`、未知 bucket 和字符串 credits。
5. `rate-limits-updated-sparse.jsonl`：通知只更新 primary，验证 merge 不清除 secondary/credits。
6. `transport-failures`：spawn failure、EOF、invalid JSON、`-32001`、超时和非零退出。
7. `schema-forward-compatibility.jsonl`：额外字段、未知 enum、缺失可选字段；验证仍可解码。

每个 fixture 测试必须断言：不泄露敏感字段、null 不转 0、未知字段不崩溃、更新通知合并正确、进程最终退出。集成测试使用临时 fake `codex` executable（仅输出固定 JSONL），不调用真实账户；一条手工 smoke test 才运行真实 `codex app-server --stdio`。

## 本机实测证据（0.147.0）

`codex --version` 输出 `codex-cli 0.147.0`。发送上述握手和两个 read 请求后，收到：

- initialize result：`userAgent` 为 `Codex Desktop/0.147.0 ... dumb (usageink-research; 0.1.0)`，并返回 `codexHome`、平台字段。
- account/read：ChatGPT `pro` 账户，`requiresOpenaiAuth: true`。
- rateLimits/read：顶层 `rateLimits.limitId: "codex"`，同时返回 `rateLimitsByLimitId`；本机当时 primary 为一周窗口，secondary 为 null。该结果证明客户端必须接受窗口缺失和 bucket 变化，不能假定固定的 5 小时/周字段。

本机帮助还确认 `--stdio` 等价于 `--listen stdio://`，analytics 默认对 app-server 关闭。实现以运行时 probe 和上述兼容策略为准，不把一次账户结果当作永久契约。

## 未决风险

- app-server protocol 仍标为 experimental，且上游只保证“按运行版本生成 schema”；0.147.0 可能改变字段或错误码，需随 CLI 更新重新验证。
- rate-limit bucket（包括 primary/secondary 及 opaque `limitId`）由后端决定，可能缺失、重排或出现新 bucket；UsageInk 只能显示可用窗口。
- 官方 README 没有 macOS app bundle 内置 `codex` 的稳定发现路径；绝对路径设置和 PATH fallback 需在真实发行包验收。
- 上游认证/限额请求可能受到登录状态、网络和后端可用性影响；UsageInk 不能区分所有 401/403 的根因，只能安全提示重新登录或稍后重试。

## 参考（第一方）

- [OpenAI Codex app-server README](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md)
- [OpenAI Codex app-server protocol: v1 initialization](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/v1.rs)
- [OpenAI Codex app-server protocol: v2 account and rate limits](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/v2/account.rs)
- [OpenAI Codex app-server protocol method declarations](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/common.rs)
- [OpenAI Developers Codex documentation](https://developers.openai.com/codex/)
