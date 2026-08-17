# `coding-agent-metrics` 对 UsageInk 的可复用设计研究

研究日期：2026-08-18

目标项目：[patrick-fu/coding-agent-metrics](https://github.com/patrick-fu/coding-agent-metrics)

核验版本：[`0aadbfcb05162a7c94b03f19040e7256effc1e2e`](https://github.com/patrick-fu/coding-agent-metrics/commit/0aadbfcb05162a7c94b03f19040e7256effc1e2e)（`main`，2026-08-17）

GitHub 同名搜索只有该项目与一个仅按 commit tag 统计贡献的 `CodingAgentContributionMetrics`；前者明确是 macOS coding-agent telemetry app，且源码直接实现 Codex token、cache 与 Claude request TPS，因此是本研究目标。

## 结论

`coding-agent-metrics` 最值得 UsageInk 复用的不是 UI，而是“先把来源语义归一化，再计算指标”的边界：累计计数先做增量、水位线与去重；OpenAI/Anthropic 的 cache 子集语义分别处理；系统吞吐与逐请求 Decode TPS 严格分名；缺少身份或时序时保持 unavailable。

但它**没有实现今日/本周 token，也没有 cache-hit 次数或命中率**。当前实现只有：

- 本地日志导出的逐事件 `UsageFact`；
- 3 分钟 `Output Throughput`；
- 10 分钟 `Token Burn/min` 与能力门控的 `Calls/min`；
- Claude Code opt-in OTel 的逐请求 TTFT、E2E、Decode TPS。

所以 UsageInk 不能直接照搬其数字口径，更不能把本机日志合计称为 Codex 账号/订阅的权威今日或本周用量。

## 能力总表

| 问题 | 当前项目实际能力 | UsageInk 判断 |
|---|---|---|
| 今日/本周 token | 未实现日历日、日历周或时区分桶；只能从带时间戳的 canonical facts 另行派生 | 只借鉴增量事实层，不借用不存在的日/周口径 |
| Cache read | 实现；Codex 与 Claude 的字段关系分别归一化 | 可借鉴字段语义与不可用状态 |
| Cache hit / hit rate | 未实现请求命中次数或命中率 | 不应把 cached-token 占比命名为 hit rate |
| Output TPS | 实现的是 180 秒系统 Output Throughput，不是逐调用 TPS | 若展示，必须明确为窗口吞吐 |
| Decode TPS | 仅 Claude Code request OTel；逐调用 `(output_total - 1)/(duration-TTFT)` | Codex local-only 与账号聚合场景不可套用 |
| Coding agents | Codex CLI/Desktop、Claude Code CLI；增强性能当前仅 Claude OTel | UsageInk 当前只需 Codex，不必复制多 agent 抽象全量 |
| 增量与归档 | 有 cursor、水位线、回滚重建、未完成尾行与 Codex archive 支持 | 可复用核心算法，但实现需简化并修正性能问题 |
| 隐私 | 本地 SQLite；不持久化正文；增强通道默认关闭且仅 loopback | 值得复用 allowlist 与默认关闭原则 |

## 1. 今日/本周 token：来源与口径

### 1.1 当前项目没有日/周指标

公开规格只定义固定 180 秒 Output Throughput、固定 600 秒 Token Burn/Calls，以及 15m、1h、24h、7d 的性能范围；源码中也只有这些常量，没有 `Calendar`、`TimeZone`、`startOfDay` 或 week-start 规则（[`Domain.swift#L109-L121`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Domain.swift#L109-L121)，[`Performance.swift#L3-L25`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Performance.swift#L3-L25)，[MVP spec #11](https://github.com/patrick-fu/coding-agent-metrics/issues/11)）。

因此不存在可直接引用的“今日 token”或“本周 token”产品口径。若从它的事实库派生，必须先决定两件事：

1. `token` 指 `outputTokens`，还是归一化后的全部 `Token Burn`；两者不是同一个指标。
2. “今日/本周”使用哪个时区、周起始日，以及时区变化后是否重分桶。

### 1.2 Codex 来源

Codex adapter 读取 `$CODEX_HOME`（默认 `~/.codex`）下 `sessions/**/rollout-*.jsonl` 与 `archived_sessions/**/rollout-*.jsonl`（[`CodexHome.swift#L3-L13`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Codex/CodexHome.swift#L3-L13)，[`CodexRolloutSourceAdapter.swift#L342-L362`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Codex/CodexRolloutSourceAdapter.swift#L342-L362)）。它只从 `event_msg.payload.type == token_count` 取 `total_token_usage` 的累计字段；`last_token_usage` 虽被解析，却不参与 fact 计算（[`CodexRolloutParser.swift#L94-L119`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Codex/CodexRolloutParser.swift#L94-L119)）。

每个 rollout 文件维护累计水位线。新值大于水位线时只记录正增量；相等时记零个新 fact；下降时触发 source-scoped rebuild，不产生负数（[`CodexRolloutSourceAdapter.swift#L200-L237`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Codex/CodexRolloutSourceAdapter.swift#L200-L237)，[ingestion resolution #4](https://github.com/patrick-fu/coding-agent-metrics/issues/4#issuecomment-5302588428)）。fact 的归属时间是该 `token_count` 行的 ISO-8601 `timestamp`，不是 session 开始时间、文件 mtime 或请求开始时间（[`CodexRolloutSourceAdapter.swift#L261-L280`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Codex/CodexRolloutSourceAdapter.swift#L261-L280)）。

这会产生一个日/周边界限制：一次累计增量整体归入事件落盘时刻。若生成跨越午夜，当前模型无法把 token 精确拆到午夜两侧。

### 1.3 Claude Code 来源

Claude adapter 读取 `$CLAUDE_CONFIG_DIR`（默认 `~/.claude`）下 `projects/**/*.jsonl`（[`ClaudeHome.swift#L3-L10`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Claude/ClaudeHome.swift#L3-L10)，[`ClaudeTranscriptSourceAdapter.swift#L382-L421`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Claude/ClaudeTranscriptSourceAdapter.swift#L382-L421)）。支持两种 fixture-proven envelope：

- `assistant.message.usage`：以 message `uuid` 为 identity，含 model 与四类 token；
- `system/subtype=session_usage`：只有 session output 总数，作为 message-total 缺失时的 fallback。

解析字段见 [`ClaudeTranscriptParser.swift#L20-L69`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Claude/ClaudeTranscriptParser.swift#L20-L69)。同一 session 出现 message totals 时，其 authority 替代 session fallback；若运行中从 fallback 切换到 message authority，会重建 source，避免相加（[`ClaudeTranscriptSourceAdapter.swift#L187-L250`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Claude/ClaudeTranscriptSourceAdapter.swift#L187-L250)，[issue #14 completion](https://github.com/patrick-fu/coding-agent-metrics/issues/14#issuecomment-5316066125)）。时间同样取 transcript 行的 `timestamp`。

### 1.4 `outputTokens` 与 `Token Burn` 的差异

`UsageFact.outputTokens` 保存 source-reported output total 的增量。对 Codex，它包含 `reasoning_output_tokens` 这个 output 子集；项目不会再把 reasoning 加一次。`Token Burn` 则将来源归一化成互斥 parts：input uncached、cache read、cache write、visible output、reasoning（[`UsageModels.swift#L3-L33`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/UsageModels.swift#L3-L33)）。

因此 UsageInk 若需要“今日/本周 token”，建议 API/文案至少区分：

- `output_tokens`：模型输出总量；
- `processed_tokens` 或其他经过合同定义的总量：所有互斥 token parts 的和；
- 订阅用量/配额：若来源是账号 usage endpoint，则保持该 endpoint 的原生口径，不与本地日志事实混称。

## 2. Cache read 与 cache hit

### 2.1 Codex

Codex parser 读取 `input_tokens`、`cached_input_tokens`、`cache_write_input_tokens`、`output_tokens`、`reasoning_output_tokens`（[`CodexRolloutParser.swift#L155-L168`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Codex/CodexRolloutParser.swift#L155-L168)）。归一化规则是：

```text
input_uncached = delta(input_tokens) - delta(cached_input_tokens)
cache_read     = delta(cached_input_tokens)
output_visible = delta(output_tokens) - delta(reasoning_output_tokens)
reasoning      = delta(reasoning_output_tokens)
cache_write    = unavailable
```

`cached_input_tokens` 是 `input_tokens` 的子集，不能把两者直接相加。`cache_write_input_tokens` 与 input 的重叠关系没有被项目的一手研究证实，所以当前实现刻意设为 `nil`，但仍可计算不含 cache write 的 partial burn（[`CodexRolloutSourceAdapter.swift#L283-L316`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Codex/CodexRolloutSourceAdapter.swift#L283-L316)，[source capability matrix §5.1](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/docs/research/source-capability-matrix.md#51-codex-responses-api-usage-object)）。

### 2.2 Claude Code

Claude 的 `input_tokens`、`cache_creation_input_tokens`、`cache_read_input_tokens`、`output_tokens` 被当作可相加的 source-native parts；标准 usage 没有 visible-output / reasoning 拆分，所以后两项保持 unavailable，但 burn total 使用完整 `output_tokens` 一次（[`ClaudeTranscriptParser.swift#L108-L119`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Claude/ClaudeTranscriptParser.swift#L108-L119)，[`ClaudeTranscriptSourceAdapter.swift#L336-L359`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Claude/ClaudeTranscriptSourceAdapter.swift#L336-L359)）。

### 2.3 没有 cache-hit 指标

当前仓库没有“命中的请求数”、cache lookup 次数或 hit-rate 公式。UI 只显示 `Cache read` token 数（[`LightSnapshotPresentation.swift#L108-L120`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/LightSnapshotPresentation.swift#L108-L120)）。

`cache_read_tokens / total_input_tokens` 只能叫 cached-input token share；它按 token 加权，不是“多少请求命中 cache”。而且 Codex 与 Claude 对 input/cache-write 的子集关系不同，跨来源公式不能暗中共用。UsageInk 若没有一手请求级 cache hit 事件，应只展示 `cached input tokens` 或明确命名的 token share，不展示 `cache hit rate`。

## 3. Output Throughput 与 Decode TPS

### 3.1 Output Throughput（系统窗口吞吐）

项目定义：在 `[now - 180s, now]` 内选择 canonical facts，求 `outputTokens` 总和，再除以固定 180 秒（[`LiveSampler.swift#L3-L21`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/LiveSampler.swift#L3-L21)，[`SnapshotBuilder.swift#L157-L207`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/SnapshotBuilder.swift#L157-L207)）：

```text
Output Throughput = sum(output token deltas whose observedAt is in the window) / 180s
```

它不是逐 model-call TPS：

- 不记录第一/最后一个输出 token 的采样点；
- 整个 delta 被放在 token event 的 `observedAt`；
- 180 秒分母包含窗口内的空闲、工具执行、等待用户与思考阶段；
- 多 agent/model 先合并 compatible numerators，再使用同一分母，而不是平均各自 TPS。

因此更准确的中文是“3 分钟输出吞吐”，不宜缩写成无修饰的 TPS。[metric contract resolution #5](https://github.com/patrick-fu/coding-agent-metrics/issues/5#issuecomment-5309727805) 也明确要求两者分开。

### 3.2 Decode TPS v1（逐请求解码率）

精确定义是：

```text
Decode TPS v1 = (output_total - 1) / ((request_duration_ms - TTFT_ms) / 1000)
```

只在 `output_total >= 2` 且 `request_duration_ms - TTFT_ms > 0` 时有效；`-1` 对应第一个 token 已在 TTFT 边界出现，剩余 `n-1` token 分布在 decode interval。代码见 [`Performance.swift#L28-L31`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Performance.swift#L28-L31) 与 [`Performance.swift#L149-L179`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Performance.swift#L149-L179)。

采样边界来自 Claude `claude_code.llm_request` OTel span：`observedAt` 取 span `endTimeUnixNano`，measurement start 反推为 `end - duration_ms`；请求必须同时带稳定 request ID、model、duration、TTFT、output tokens 与 attempt（[`Performance.swift#L300-L348`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Performance.swift#L300-L348)）。

时间处理边界：

- TTFT 从 denominator 中扣除；
- agent 在两次 model calls 之间的工具执行不位于 request span 内，因而不进入 Decode TPS；
- retry 不进入正常分布，只单独计数；
- `PerformanceFact` 没有 reasoning-time 字段，numerator 使用完整 `outputTotal`，所以项目**没有**单独扣除“思考时间”或区分 thinking tokens；能证明的只有扣除了 TTFT；
- TTFT/E2E 显示 p50/p95，Decode TPS 显示 p50/p10，先 pool compatible raw requests 再算 nearest-rank quantile，不平均每个 model 的 percentile。

本地 Codex rollout 与 Claude transcript 都没有足够的逐请求时间/稳定 identity，不能用 turn duration 代替。当前增强 receiver 也只识别 Claude span，Codex Decode TPS 尚未实现（[issue #18](https://github.com/patrick-fu/coding-agent-metrics/issues/18)，[source capability matrix §4](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/docs/research/source-capability-matrix.md#4-capability-matrix--p0-metrics)）。

## 4. 支持的 agent 与日志格式

| Agent / channel | 路径或协议 | 当前可得能力 | 关键限制 |
|---|---|---|---|
| Codex CLI/Desktop local rollout | `$CODEX_HOME/{sessions,archived_sessions}/**/rollout-*.jsonl` | output delta、model/session/turn、Codex token parts | `TokenCount` 是累计观察；无 durable model-call identity；无 Decode TPS |
| Claude Code local transcript | `$CLAUDE_CONFIG_DIR/projects/**/*.jsonl` | message/session output delta、model、四类 token parts | 只支持代码与 synthetic fixture 证明的 v1 shape；transcript schema 不是稳定公开合同 |
| Claude Code enhanced telemetry | `POST application/json http://127.0.0.1:4318/v1/traces`，span 名 `claude_code.llm_request` | request TTFT/E2E/Decode TPS、retry、model/request identity | 默认关闭，用户自行配置 exporter；不是 token activity 的默认 authority |

Source channels 枚举目前只有 Codex rollout、Claude transcript、Claude telemetry 与 synthetic（[`Domain.swift#L29-L43`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Domain.swift#L29-L43)）。不支持 Gemini CLI、Cursor、Copilot、OpenCode 等其他 agent。

## 5. 聚合、增量、去重、时区、运行中 session 与归档

### 5.1 增量扫描与重建

每个 source 的持久状态包含 parser semantic version、逐文件 identity/relative locator、inode generation、已消费 offset、已消费 prefix 的 SHA-256 fingerprint、各累计计数水位线及 Claude authority 状态（[`SourceState.swift#L3-L76`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/SourceState.swift#L3-L76)）。

扫描规则：

- 只消费以 newline 结束的完整 JSONL 行；未完成尾行不推进 offset，下次重读（[`CodexRolloutSourceAdapter.swift#L319-L340`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Codex/CodexRolloutSourceAdapter.swift#L319-L340)，[`ClaudeTranscriptSourceAdapter.swift#L366-L380`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Claude/ClaudeTranscriptSourceAdapter.swift#L366-L380)）；
- inode 变化、文件缩短、已消费 prefix fingerprint 改变或 parser version 改变时重建文件/source；
- facts 删除/替换与新 cursor、水位线在一个 `BEGIN IMMEDIATE` transaction 中提交，避免 fact/state 半更新（[`SQLiteFactStore.swift#L144-L165`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/SQLiteFactStore.swift#L144-L165)）。

### 5.2 去重与 authority

- scan 内先按 source-scoped observation identity 去重；
- `usage_facts.id` 是 SQLite primary key，incremental insert 使用 `OR REPLACE`（[`CanonicalIngestor.swift#L6-L27`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/CanonicalIngestor.swift#L6-L27)，[`SQLiteFactStore.swift#L17-L48`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/SQLiteFactStore.swift#L17-L48)）；
- 可证明 stable model-call ID 时，按 agent + call ID + granularity 合并；enhanced tier 替代 fallback tier，不相加；同 tier 冲突稳定选择一个代表或 fail closed（[`AuthorityCoalescing.swift#L13-L40`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/AuthorityCoalescing.swift#L13-L40)，[`Performance.swift#L182-L220`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Performance.swift#L182-L220)）。

### 5.3 时间与时区

source ISO-8601 timestamp 最终存成绝对 `Date`/Unix seconds，滑动窗口按 elapsed seconds 计算。trend bucket 以 Unix epoch 对齐，只给完成 bucket 数值，open bucket 为 `nil`（[`TrendBuilder.swift#L19-L29`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/TrendBuilder.swift#L19-L29)，[`TrendBuilder.swift#L67-L75`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/TrendBuilder.swift#L67-L75)）。这避免当前 bucket 假精确，但不提供日历时区语义。

UsageInk 若添加 today/week，必须自行固定合同，例如：按用户所选 IANA 时区、local midnight、ISO week 或明确的 locale week；将原始 fact 保留为 UTC，查询时重分桶。不能沿用 epoch bucket 当作日历日。

### 5.4 运行中 session

没有独立的 active/running session 状态机。运行中日志只要追加完整 usage 行，就会贡献新 delta；未完成尾行暂不贡献。因而“当前 session token”是截至最后完整事件的 provisional total，不代表 session 已结束，也没有完成性标记。

### 5.5 归档与日志消失

Codex 同时扫描 active 与 archived；相同文件 identity 同时出现时优先 active，移动到 `archived_sessions` 不会按路径产生第二份 identity（[`CodexRolloutSourceAdapter.swift#L342-L362`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Codex/CodexRolloutSourceAdapter.swift#L342-L362)）。Claude 没有单独 archive 目录语义，只遍历 `projects`。

SQLite canonical facts 不因源日志消失而自动删除。Claude 明确保留已知 cursor 并把 source 标成 `SOURCE_UNAVAILABLE`；Codex 当前实现会从 source state 清除不再发现的文件 cursor/watermarks，但已持久化 facts 仍保留（[`ClaudeTranscriptSourceAdapter.swift#L74-L83`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Claude/ClaudeTranscriptSourceAdapter.swift#L74-L83)，[`CodexRolloutSourceAdapter.swift#L81-L88`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Codex/CodexRolloutSourceAdapter.swift#L81-L88)）。这是当前两个 adapter 的不对称边界，UsageInk 不应直接复制。

## 6. 隐私与性能

### 6.1 隐私

本地 adapters 会在内存中 JSON-decode 原日志行，但只持久化 allowlisted metadata、token、timestamp、model 与 opaque session/turn identity；SQLite schema 不含 prompt/code/tool output/raw body（[`SQLiteFactStore.swift#L17-L58`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/SQLiteFactStore.swift#L17-L58)）。注意：数据库仍含 model 名、session/turn/request identity 与相对 source locator，属于本机敏感 metadata，不是匿名库。

增强 OTel：

- 默认关闭，只允许固定 `127.0.0.1:4318`（[`Performance.swift#L230-L259`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Performance.swift#L230-L259)）；
- 只接受 `POST /v1/traces` JSON，单请求最多 1 MiB（[`OTLPHTTPReceiver.swift#L156-L199`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/OTLPHTTPReceiver.swift#L156-L199)）；
- 整批先检查敏感字段；发现 prompt、content、path、body、credential、tool I/O 或未知 target attribute 就拒绝，不产 fact；原 envelope 检查后丢弃（[`Performance.swift#L273-L305`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Performance.swift#L273-L305)，[privacy diagnostics resolution #9](https://github.com/patrick-fu/coding-agent-metrics/issues/9#issuecomment-5309935938)）。

项目声明不做 product analytics 或 remote crash reporting，且 public fixtures 只使用 synthetic data（[MVP spec #11](https://github.com/patrick-fu/coding-agent-metrics/issues/11)）。

### 6.2 性能现状与未完成项

已实现：SQLite WAL + `synchronous=NORMAL`，`observed_at` index；light snapshot 只查最近 10 分钟；trend 查询上限 20,000 facts，并在打开 detail 时单独执行（[`SQLiteFactStore.swift#L7-L49`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/SQLiteFactStore.swift#L7-L49)，[`TelemetryRuntime.swift#L100-L111`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/TelemetryRuntime.swift#L100-L111)，[`TelemetryRuntime.swift#L190-L208`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/TelemetryRuntime.swift#L190-L208)）。Claude discovery 另有限制：4096 entries、256 transcripts、depth 12。

但不能把 future spec 当成已实现：1 Hz light、visible-only 4 Hz detail、256/source queue、128 drain/tick、retention hard cap 都仍在 open issues [#20](https://github.com/patrick-fu/coding-agent-metrics/issues/20) 与 [#21](https://github.com/patrick-fu/coding-agent-metrics/issues/21)。当前每次 Codex incremental scan 会读取整个已消费 prefix 计算 SHA-256，并再次解析 prefix 来恢复上下文；大 active rollout 会产生 O(file size) 重读（[`CodexRolloutSourceAdapter.swift#L142-L179`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/Codex/CodexRolloutSourceAdapter.swift#L142-L179)）。另外 light snapshot 当前会读取全部 `performance_facts`（[`TelemetryRuntime.swift#L190-L205`](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/Sources/CodingAgentMetricsCore/TelemetryRuntime.swift#L190-L205)）。

这两点不适合直接搬到持续运行、低功耗或高历史量的 UsageInk 采集路径。

## 7. 对 UsageInk 的取舍

### 适合复用

1. **累计值先转事实增量**：持久 cursor + positive watermark + duplicate-zero + rollback rebuild；fact 与 state 原子提交。
2. **来源特定的 token algebra**：Codex cached/reasoning 是父计数子集；Claude cache parts 是独立字段；缺失 part 用 unavailable，不用 0。
3. **指标命名分层**：窗口 Output Throughput、逐请求 Decode TPS、账号 quota/usage 是三个不同概念。
4. **质量、状态、覆盖率正交**：zero、stale、absent、unavailable 不混；partial 不伪装成 complete。
5. **本地最小化**：正文不入库；增强遥测默认关闭、loopback-only、严格 allowlist。
6. **运行中与 archive 幂等**：完整行才消费；路径移动不改变稳定 source identity。

### 不应照搬

1. **不要把本机 rollout 合计当账号今日/本周权威用量**：它只覆盖本机被发现并成功解析的 Codex sessions，无法证明覆盖其他设备、远端任务或被清理前未采集的日志。
2. **不要复制不存在的 cache-hit rate**：只能展示 cached input tokens，或另行定义并改名为 token share。
3. **不要把 3 分钟 Output Throughput 写成 Output TPS**；它把 idle/tool/thinking 时间留在公共窗口分母里。
4. **不要从 Codex turn duration 推 Decode TPS**：当前项目也明确禁止；只有共键 request duration、TTFT、output 与 stable request identity 才能算。
5. **不要复制菜单栏专用刷新预算**：e-paper 刷新与功耗约束不同，1/4 Hz detail 与 180/600 秒窗口不是 UsageInk 产品合同。
6. **不要复制全 prefix hashing/rehydration**：大日志下每轮 O(n)；应优先权威账号 usage API，确需 tail 时采用稳定 identity、offset、有限 overlap/tail checksum 与显式重建。
7. **不要先引入完整多-agent/OTel/percentile 栈**：UsageInk 当前目标是 Codex subscription usage 的单屏表达；这些模块会显著扩大隐私面、配置面与测试面。
8. **不要把 accepted retention proposal 当生产能力**：当前 cap/prune/reset 尚未实现；若 UsageInk 存历史，需自己定义容量、删除和 reset 验收。

## 一手资料索引

- [README](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/README.md)
- [MVP product specification, issue #11](https://github.com/patrick-fu/coding-agent-metrics/issues/11)
- [Source capability matrix](https://github.com/patrick-fu/coding-agent-metrics/blob/0aadbfcb05162a7c94b03f19040e7256effc1e2e/docs/research/source-capability-matrix.md)
- [Incremental ingestion decision, issue #4](https://github.com/patrick-fu/coding-agent-metrics/issues/4#issuecomment-5302588428)
- [Metric contract decision, issue #5](https://github.com/patrick-fu/coding-agent-metrics/issues/5#issuecomment-5309727805)
- [Codex local ingestion, issue #13](https://github.com/patrick-fu/coding-agent-metrics/issues/13)
- [Claude local ingestion, issue #14](https://github.com/patrick-fu/coding-agent-metrics/issues/14)
- [Token burn/cache semantics, issue #16](https://github.com/patrick-fu/coding-agent-metrics/issues/16)
- [Request performance telemetry, issue #18](https://github.com/patrick-fu/coding-agent-metrics/issues/18)
- [Open bounded-runtime work, issue #20](https://github.com/patrick-fu/coding-agent-metrics/issues/20)
- [Open retention/reset work, issue #21](https://github.com/patrick-fu/coding-agent-metrics/issues/21)
