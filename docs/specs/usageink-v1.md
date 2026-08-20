# UsageInk V1 Specification

**Version:** 1.0

**Status:** implementation contract for Issue #9

**Language:** English

## 1. Authority, terminology, and scope

This specification is the authoritative V1 implementation contract. If it conflicts with an ADR, issue, prototype, or research document, this specification wins for V1. Research and prototypes are informative evidence only. The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHOULD**, **SHOULD NOT**, and **MAY** are normative as described by RFC 2119 and RFC 8174.

UsageInk is an experimental, MIT-licensed macOS menu-bar companion. It supports exactly one Codex usage provider and exactly one **Bound Display**: an EPD-nRF5 device driving a 4.2-inch, 400 x 300, UC8176 BWR panel. It targets macOS 14.0 or later as a Universal binary. It is an independent implementation; no GPL source from EPD-nRF5 may be copied.

V1 is out of scope for: product implementation decomposition; multiple displays or providers; firmware flashing, custom firmware, device wipe, and non-EPD-nRF5 protocols; signed/notarized/App Store distribution; automatic update; iOS, Windows, Linux, cloud sync, multi-user sharing, export, historical reporting, support bundles, telemetry, remote crash reporting, and uploads. It does not read authentication material, modify Codex configuration or `~/.codex`, or guarantee battery longevity; external power is recommended.

Canonical terms:

| Term | Meaning |
| --- | --- |
| **Usage Snapshot** | Plan information and Usage Windows obtained together at one point in time. Never call it a raw response or usage payload. |
| **Source Observation** | The latest accepted normalized account or local value and availability, plus the time that source last succeeded. Never call it a cached payload. |
| **Usage Window** | An account quota interval with used percentage, duration, and reset time. Never call it a bucket or limit. |
| **Bound Display** | The one selected e-paper display receiving UsageInk output. Never call it a peripheral, tag, or device in product text. |
| **Display Frame** | One complete 400 x 300 image prepared for the Bound Display. Never call it a bitmap or screen payload. |
| **Frame Fingerprint** | The semantic identity used to decide whether an automatic Refresh is necessary. It is not a pixel hash or last-sent hash. |
| **Display Style** | A selectable information hierarchy for composing a Display Frame. It is not a layout variant or template. |
| **Local Activity Metric** | A token or throughput measure observed from Codex activity on this Mac, distinct from account quota. |
| **Activity Fact** | An allowlisted timestamped positive token delta derived from a local cumulative counter, with at most an opaque source key. It is not a raw JSONL event or session record. |
| **Refresh** | A complete Display Frame transfer followed by e-paper refresh without an observed transport failure for 15 seconds. It is a best-effort commitment, never a pixel inspection or physical confirmation. |
| **Panel Trust** | Whether UsageInk may assume the Bound Display still shows its last successfully Refreshed frame. Restart or interrupted display work invalidates it even when content is unchanged. |

## 2. Native application architecture

The product is a native Xcode macOS app named `UsageInk`, bundle identifier `com.patrickfu.UsageInk`, in Swift 6 language mode with deployment target macOS 14.0. `LSUIElement` MUST be `true`; the app activation policy MUST be `.accessory`; it has no Dock icon and no main window. Use AppKit `NSStatusItem` and `NSMenu`, plus exactly one Settings `NSPanel`. Do not use `MenuBarExtra`.

V1 has zero third-party runtime dependencies. It MAY use only Foundation (`Process`, `Pipe`), AppKit, CoreGraphics/CoreText, CoreBluetooth, SQLite3, `os_log`, and CryptoKit. App Sandbox and Hardened Runtime are both OFF for unsigned V1. It MUST NOT request Full Disk Access. `Info.plist` MUST provide English and Simplified-Chinese Bluetooth usage strings and MUST make no other TCC permission claim.

`UsageInkRuntime` is the sole mutable-state owner on one serial `.userInitiated` dispatch queue. CoreBluetooth delegates run on that queue. Worker I/O completion events MUST hop back to it; main-thread work is limited to UI snapshots and commands. There may be at most one Poll process, one BLE recovery sequence, and one Refresh transfer at a time.

The logical modules and write boundaries are:

| Module | Owns and may write |
| --- | --- |
| Domain | Value types, normalization rules, availability, formatting inputs, and state-machine events; no I/O. |
| Codex | Executable discovery, Process JSONL, capability probe, and normalized account observation; no persistent-store writes. |
| Activity | Allowed JSONL scan, SQLite facts/cursors, and normalized local observation; only it writes `activity.sqlite`. |
| Render | Pure 400 x 300 composition, semantic fingerprint, and RAM-only planes; no BLE, files, or state writes. |
| BLE | CoreBluetooth link/session and RAM-only transfer; no product-state writes except Runtime commands. |
| Persistence | Validated `state.json` read/write, migration, quarantine, and destructive-store operations; only it writes state. |
| App | AppKit status/menu/panel and Runtime command dispatch; no source parsing or transport decisions. |

Target/package grouping MAY differ, but these boundaries MUST remain. No module may bypass Runtime to mutate another module's owned state.

## 3. Preferences, menu, and display semantics

### 3.1 Defaults and validation

Defaults are: Display Style `quotaFocus`; title `CODEX USAGE`; modules `title`, `plan`, `quota`, `today`, `weekTokens`, `updated`, and `status` enabled; `cache` and `tps` disabled; quota order `quotaFirst`; TPS lookback 15 minutes; date format `relative`; red accent `threshold`; threshold 80; language `system`.

| Preference | Allowed values and contract |
| --- | --- |
| `displayStyle` | `balanced`, `quotaFocus`, `activityFocus`. |
| `modules` | Boolean `title`, `plan`, `quota`, `today`, `weekTokens`, `cache`, `tps`, `updated`, `status`. A quota module displays every returned canonical window. Canonical order is used except that Quota Focus selects its hero by the explicit rule below; its remaining quota cells retain canonical order. |
| `quotaOrder` | `quotaFirst` or `activityFirst`; default `quotaFirst`. |
| `tpsWindowMinutes` | `3`, `15`, or `60`; default `15`. |
| `dateFormat` | `relative` or `absolute`; default `relative`. |
| `redAccent` | `off`, `threshold`, or `always`; default `threshold`. |
| `redThreshold` | Integer 50 through 100 inclusive, increment 5; default 80. |
| `language` | `system`, `en`, or `zh-Hans`; default `system`. `system` resolves once per frame from the current preferred language, and the resolved result enters the fingerprint. |
| `title` | Trim leading/trailing whitespace, remove newlines, limit to 24 extended grapheme clusters, then ellipsize by rendered width. |
| plan | If displayed, show at most 8 displayed characters, ellipsized by width. |
| `customCodexPath` | Null or the validated absolute executable path in Section 7; default null. |

There is no weekly-only setting and no 5-hour assumption. Canonical account-window order is `primary`, then `secondary`; absent windows are not invented. Percentages are valid only when finite and within 0...100; render the nearest integer percentage. Invalid percentages are unavailable.

Settings exposes exactly the preferences in the preceding table plus `customCodexPath`; binding, destructive actions, and wakeup edits are not Settings fields. Saves MUST batch changes. A save during a transfer MUST NOT mutate that transfer's frame; it replaces one coalesced later automatic request. A manual Refresh follows Section 9 even when a save is pending. The first-run disclosure is shown in this Settings panel on the first launch; it MUST NOT create a second window or panel.

### 3.2 Status-item menu

The menu order is exact:

1. Non-clickable status summary.
2. `Refresh Now`.
3. `Find and Bind Display…` when unbound, otherwise `Unbind Display…` with confirmation.
4. `Display Style` submenu: `Balanced`, `Quota Focus`, `Activity Focus`.
5. `Settings…`.
6. `Configure Wakeup Pin…` only when the current ready BLE session has a valid 13-byte configuration. It MUST show a separate immediate confirmation immediately before its write.
7. `Rebuild Local Metrics…` with confirmation.
8. `Reset UsageInk Data…` with confirmation.
9. `About UsageInk`.
10. `Quit UsageInk`.

The status summary includes independent account/local source availability and, when relevant, `Display unavailable`, its last transport classification, and last successful Refresh age. V1 sends no macOS notifications.

Binding candidates show advertised name, live RSSI, and the final four hexadecimal characters of `CBPeripheral.identifier`; `CBPeripheral.identifier` is the binding primary key. RSSI is never persisted. Codex absence MUST NOT prevent binding or an honest degraded frame. A missing firmware characteristic reads as version `0x15`; version `< 0x16` is incompatible and MUST NOT bind, send `INIT`, or send `WRITE_IMAGE`.

### 3.3 Rendering and localization

Coordinates are top-left, integer pixels, at 400 x 300. Use system fonts, PingFang fallback for Chinese, and `monospacedDigitSystemFont` for numeric values. Do not use web fonts. CoreText MAY antialias while rasterizing in RAM, but the final black/red planes MUST be 1-bit: coverage `>= 0.5` selects ink and lower coverage selects paper. Do not dither. Normal rules are 1 px and strong rules are 2 px.

Only quota percentage and quota progress may be red: never for errors. `off` is black; `threshold` is red only at or above the configured threshold; `always` is always red.

| Style | Content rect and rows | Exact hierarchy |
| --- | --- | --- |
| Balanced | `(16,11,368,280)`; rows `38/215/27` | Title 17 heavy; quota value 29 heavy monospaced; metric value 25 heavy monospaced; quota label 11; metric label 9; reset 9; footer 8. The body has at most six enabled entries, quotas first or locals first according to `quotaOrder`; it is a two-column, `ceil(n/2)`-row grid in row-major order. Divide each integer width/height evenly and assign each remainder pixel to earlier columns/rows. |
| Quota Focus | `(14,10,372,282)`; rows `38/145/73/26` | Title 13; hero value 65 on a 56-point line; ticker value 21; footer 8. Under `quotaFirst`, hero is the returned window with greatest `windowDurationMins`; an equal-duration tie selects the later canonical slot. Under `activityFirst`, hero is the first enabled local metric. If the preferred group is empty, fall back to the other group. The ticker contains the remaining items with the preferred group first, preserving canonical quota and local-priority order; it has at most five equal cells. |
| Activity Focus | `(14,10,372,282)`; rows `31/223/28` | Title 11; primary local value 43; secondary local values 21; footer 8. Primary plus up to three right-side local cells follow local priority. Quotas occupy the bottom in canonical order with equal integer widths; earlier quota cells receive remainder pixels. |

If all content modules are disabled, render the selected style's title/header and a localized unavailable mark; it MUST NOT synthesize a metric. A disabled title slot displays `USAGE` only as structural fallback, not the saved title.

Window labels derive from `windowDurationMins`: use `N min`, `N hr`, or `N d` in English and `N 分钟`, `N 小时`, or `N 天` in Simplified Chinese, preferring exactly divisible larger units. Relative reset labels use `Resets in …` / `… 后重置`; absolute labels use local current-calendar formatting with `Resets …` / `重置 …`. An invalid/out-of-range reset timestamp is unavailable. Relative countdown text is allowed in a frame but is excluded from its fingerprint and therefore freezes until another semantic Refresh.

Local priority is exactly Today, Week, Cache, TPS. Labels are `Local Today`, `Local This Week`, `Cache hit rate`, `TPS` in English and `本机今日`, `本机本周`, `缓存命中率`, `TPS` in Simplified Chinese. Format tokens as: `< 1k` integer; `< 1m` one decimal `K`; `< 1b` two decimal `M`; otherwise two decimal `B`; trailing zeros MAY be removed. Every numeric rounding in V1 is round-half-away-from-zero. Format a valid token-weighted cache rate as a rounded integer percent. TPS is `sum(output deltas in selected elapsed window) / window seconds`, formatted to one decimal and labelled `TPS` / `TPS`; it is not per-request decode TPS. Today and week mean the current local time zone, local midnight, and ISO-8601 Monday-start week; total tokens are `input + output`, never adding cached/reasoning subsets again.

If enabled, footer `updated` is always the absolute local composition time, formatted `Updated HH:mm` / `更新 HH:mm`; it never uses the relative-date preference. Footer `status` is exactly `Display connected` / `显示器已连接`, because a frame may begin transfer only from a ready session. Both are excluded from the fingerprint and freeze until the next actual transfer; a skipped frame MUST NOT change them. BLE-unavailable detail remains in the live menu while the panel retains its prior frame. Account/local availability and classified failure are content-region semantic state and MUST enter the fingerprint.

Use this exact degraded text table. A stale value retains its last value plus the status badge; a source with no history renders em dash plus this copy. Null never becomes zero.

| Semantic state | English | Simplified Chinese |
| --- | --- | --- |
| `authRequired` | Sign in to Codex | 请在 Codex 登录 |
| `binaryMissing` | Codex not found | 未找到 Codex |
| `versionTooOld` | Update Codex | 请升级 Codex |
| `protocolIncompatible` | Codex incompatible | Codex 协议不兼容 |
| `rateLimitUnavailable` | Quota unavailable | 限额暂不可用 |
| account `stale` | Account data stale | 账户数据已过期 |
| local `unknown` | Local activity unknown | 本机活动未知 |
| `sourceUnavailable` | Local source unavailable | 本机来源不可用 |
| `sourceUnreadable` or `sourcePermissionDenied` | Local source unreadable | 本机来源不可读 |
| `sourceMalformed` or `sourcePartialTail` | Local data partial | 本机数据不完整 |
| `firmwareIncompatible` | Display firmware incompatible | 显示器固件不兼容 |
| BLE unavailable/unreachable | Display unavailable | 显示器不可用 |

## 4. Frame Fingerprint

The Frame Fingerprint is lowercase hexadecimal SHA-256 of UTF-8 canonical JSON. Canonical JSON means recursively sorted object keys, UTF-8 strings, JSON booleans/null without whitespace, and arrays in rendered order. Apart from integer `v:1`, every display value is its canonical formatted string, boolean, or null: no float, exponent, or negative-zero representation is permitted. Its root contains resolved language, style, every visible preference, and a `visible` array containing each rendered field's semantic identity, formatted value or unavailable state, quota identity/duration/absolute `resetsAt`, and local coverage/availability. It includes selected TPS lookback and resulting TPS availability/value.

It MUST exclude wall clocks, relative countdowns, source age after availability is selected, last Poll/Refresh/update times, schedule deadline, retries, pending reasons, link state, RSSI, MTU, diagnostics, and all transport fields. Manual requests always transfer a full frame. An automatic request skips only when the fingerprint is unchanged **and** Panel Trust is `assumed`; cold invalid Panel Trust is the explicit content-unchanged exception and requires full recovery transfer.

## 5. Codex app-server account contract

### 5.1 Discovery and process lifecycle

Resolve one executable in this order: an explicitly configured absolute executable; executable `codex` on the process `PATH`; `/opt/homebrew/bin/codex`; `/usr/local/bin/codex`; `$HOME/.local/bin/codex`. Do not invoke a login shell, scan arbitrary directories, download a binary, or assume a bundled binary. Resolve executability, run `codex --version`, and require a parseable version `>= 0.147.0`.

Each Poll starts a fresh `codex app-server --stdio` process. Stdin/stdout are JSONL; JSON-RPC's `jsonrpc` member is omitted. A stdout line is limited to 1 MiB before decoding; an over-limit line terminates the process and is classified `invalidJSON` when framing is impossible, otherwise `schemaInvalid`. Do not run `generate-json-schema` in production or write it to user directories. It is permitted only in development/CI in a temporary fixture directory. Production capability detection is the handshake plus the required method and core-type checks below.

Send these messages in this order; `version` is UsageInk's app version:

```jsonl
{"method":"initialize","id":1,"params":{"clientInfo":{"name":"usageink","title":"UsageInk","version":"<app-version>"}}}
{"method":"initialized","params":{}}
{"method":"account/read","id":2,"params":{"refreshToken":false}}
{"method":"account/rateLimits/read","id":3}
```

Wait for the initialize response before `initialized`; then issue the two reads. Send no capability member unless the runtime schema requires an empty object; never send `experimentalApi`. `clientInfo` MUST contain no email, machine name, path, or user content. Close stdin and let the process exit after terminal reads; do not send `shutdown`.

Initialize has a 5 s timeout. Each read has a 10 s timeout. Ordinary start/exit/invalid-JSON/timeout failure gets one non-overlapping retry. `-32001` overload retries at most three times within a 30 s total window, using jittered exponential backoff; stop at the first exhausted limit. All reads are terminal before publishing: hold account result until both account reads terminal, even though Local Activity publishes independently.

### 5.2 Normalization and failure

The runtime probe requires successful `initialize`, `account/read`, and `account/rateLimits/read`, plus correct core response types. Unknown optional fields are ignored. A required core field with the wrong type is `schemaInvalid` and makes the protocol incompatible for that Poll.

Normalize as follows:

* `Account`: no durable email or `account.type`; `planType` is retained only while actually rendered. A non-null structured account is logged in even when `requiresOpenaiAuth:true`; that boolean is only a provider-capability hint. `authRequired` means only that a successful `account/read` result contains absent/null `account`. An `account/read` JSON-RPC error never becomes `authRequired`: structured 401/403 evidence is `backendUnauthorized`/`backendForbidden`, and any other error follows the transport/protocol/backend classifications below. `requiresOpenaiAuth` is never authentication-error evidence.
* `UsageSnapshot`: account plan plus zero, one, or two canonical `UsageWindow`s.
* `UsageWindow`: `slot` is `primary` or `secondary`; `usedPercent` is finite 0...100; `windowDurationMins` is a positive integer; `resetsAt` is a valid Unix second in the platform `Date` range. Invalid required window fields make that window unavailable.

If `rateLimitsByLimitId` contains key `codex`, use that value only when it is a valid object whose inner `limitId` is `codex` or absent; a null, wrong-type, or mismatched inner `limitId` is `schemaInvalid` and MUST NOT fall back. Only when that map key is absent may top-level `rateLimits` be used, and only with `limitId` `codex` or absent. Drop all other buckets, credits, reset credits, account type, and email. Do not call `account/usage/read`, login, logout, auth, or write RPCs. `primary` and `secondary` are independently nullable; no fixed quota duration is assumed. A valid rate-limits result plus non-null account publishes a Usage Snapshot, regardless of `requiresOpenaiAuth`. V1 ignores `account/rateLimits/updated` notifications entirely because each Poll is short-lived; tests MUST prove sparse notifications do not mutate the current snapshot.

Classify binary absence, old version, malformed JSON, transport start/exit, protocol incompatibility, auth, backend unauthorized/forbidden, quota unavailable, overload, timeout, schema invalid, and unknown using structured evidence rather than error-message matching. Preserve the last valid account observation and its independent age on failure. The earlier research rule that mapped `requiresOpenaiAuth:true` by itself to `authRequired` is superseded by this specification.

## 6. Local Activity contract

Read only `${CODEX_HOME:-~/.codex}/sessions` and `${CODEX_HOME:-~/.codex}/archived_sessions`, recursively. The only accepted JSONL events are `event_msg` whose payload type is `token_count`. The only inspected payload fields are `total_token_usage` and `last_token_usage`, and within each only `input_tokens`, `cached_input_tokens`, `cache_read_input_tokens`, `cache_read_tokens`, `output_tokens`, and `reasoning_output_tokens`. Every accepted counter is a nonnegative signed 64-bit integer; overflow, negative, fractional, or nonnumeric values are malformed. The three cached-input aliases are equivalent; if more than one is present their integer values MUST match, otherwise classify the source `sourceMalformed`. Facts use `total_token_usage` cumulative counters only; `last_token_usage` is read only to tolerate the known shape and never contributes a fact. `activity_fact.observed_at` is the token-count line's top-level ISO-8601 `timestamp` converted to UTC Unix seconds. It MUST be nonnegative and no later than five minutes after Poll start; a missing or invalid timestamp inserts no fact and classifies that source `sourceMalformed`/partial. File mtime and scan time MUST NOT substitute. Do not retain content, model, source path, session ID, or raw event.

One scan per Poll has a single cumulative hard budget: 8 s wall time, 512 files, and 64 MiB read, including enumeration, both attempts, and rollback/rebuild. Enumerate by `lstat` only regular files, never follow symlinks, require `realpath` containment under the selected source root, reject link count greater than one, and maintain visited directory identities to prevent cycles. Open relative to a retained root directory descriptor with `openat(..., O_NOFOLLOW)`, then `fstat` the descriptor and require the same regular-file device/inode identity observed during enumeration before reading; a pathname is never reopened after validation. A rejection is classified and counts against coverage/budget. Retry exactly once only for a non-budget transient failure while budget remains. Any budget excess, rejection that prevents complete coverage, or transaction failure rolls back the entire scan transaction and publishes no partial result; exhaustion is `sourceScanTimeout` and retains the prior observation.

A basename is eligible only when it starts `rollout-`, ends exactly `.jsonl`, contains no `.jsonl.` suffix, and has a core longer than the 20-character timestamp prefix. Remove the prefix; take the substring before the first `_`; require a lowercase `8-4-4-4-12` hexadecimal UUID. This in-memory value is `canonicalRolloutId`. Compute:

```text
sourceKey = lowercase-hex(SHA-256(UTF8("codex-rollout-v1") || 0x00 || UTF8(canonicalRolloutId)))
```

Discard basename, UUID, and path immediately after scan. For the same `sourceKey`, `sessions` wins over `archived_sessions`; within the selected layer the lexicographically greatest basename wins. Losing candidates never trigger rollback. This also handles revert names ending `_<rollout_id>` without duplicate facts.

Only newline-terminated complete lines advance the cursor. An incomplete final line does not advance the offset and sets `sourcePartialTail` for coverage; it does not invent a timestamp or fact. It is not a scan rejection: already completed lines MAY commit, but Cache remains unavailable until a later complete scan. For each counter greater than its watermark, insert its positive delta; equal counters insert nothing. Lower counters, parser version change, inode-generation change, file shrink, or tail-checksum mismatch require source-scoped rollback/rebuild: delete that source's facts and cursor, then rescan. The tail checksum is SHA-256 of up to the 4,096 bytes immediately preceding the stored newline offset. Facts, pruning, cursor, watermarks, and rebuild replacement commit in one `BEGIN IMMEDIATE` transaction. A missing file preserves facts until retention pruning; no raw locator is stored.

`cachedInput` is a subset of `input`; `reasoning` is a subset of `output`. TPS is anchored at Poll start: for N = configured 3/15/60 minutes, sum output facts in inclusive `[pollStart - N*60, pollStart]` and divide by exactly `N*60`. A scan that commits its completed lines updates the Local observation time; Today/week/TPS use those committed facts, so an empty result is fresh `0`/`0`/`0.0` rather than unavailable. Only `lastSuccessfulObservationAt == null` produces the no-history em dash. Today cache rate is `sum(cachedInput) / sum(input)` only when `sum(input)>0` and coverage is complete. Its coverage domain is every eligible source enumerated in `sessions` and `archived_sessions` during this Poll. Coverage is complete exactly when all of them were read and committed with no rejected, malformed, partial-tail, unreadable, permission-denied, or timeout condition; otherwise only Cache is unavailable while Today/week/TPS continue from committed facts. It is token-weighted, not a request hit count. Local availability and account availability are independent.

At startup, rebuild the in-memory local observation by querying `activity.sqlite`; do not use a `state.json` local-fresh marker as authority. If the database is unavailable or fails integrity check, local state is `unknown`/`unavailable`, not fresh, and the derived database is rebuilt from sources. Derived local values are never persisted in `state.json`.

Open SQLite with WAL and `synchronous=NORMAL`. The exact schema is:

```sql
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
CREATE TABLE activity_fact (
  id INTEGER PRIMARY KEY,
  source_key TEXT NOT NULL CHECK(length(source_key)=64 AND source_key NOT GLOB '*[^0-9a-f]*'),
  observed_at INTEGER NOT NULL,
  input_delta INTEGER NOT NULL CHECK(input_delta >= 0),
  cached_input_delta INTEGER NOT NULL CHECK(cached_input_delta >= 0 AND cached_input_delta <= input_delta),
  output_delta INTEGER NOT NULL CHECK(output_delta >= 0),
  reasoning_delta INTEGER NOT NULL CHECK(reasoning_delta >= 0 AND reasoning_delta <= output_delta),
  CHECK(input_delta + output_delta > 0)
);
CREATE INDEX activity_fact_observed_at ON activity_fact(observed_at);
CREATE INDEX activity_fact_source_key_observed_at ON activity_fact(source_key, observed_at);
CREATE TABLE source_cursor (
  source_key TEXT PRIMARY KEY CHECK(length(source_key)=64 AND source_key NOT GLOB '*[^0-9a-f]*'),
  parser_version INTEGER NOT NULL CHECK(parser_version = 1),
  inode_generation INTEGER NOT NULL,
  size_bytes INTEGER NOT NULL CHECK(size_bytes >= 0),
  newline_offset INTEGER NOT NULL CHECK(newline_offset >= 0),
  tail_checksum TEXT NOT NULL CHECK(length(tail_checksum)=64 AND tail_checksum NOT GLOB '*[^0-9a-f]*'),
  input_watermark INTEGER NOT NULL CHECK(input_watermark >= 0),
  cached_input_watermark INTEGER NOT NULL CHECK(cached_input_watermark >= 0),
  output_watermark INTEGER NOT NULL CHECK(output_watermark >= 0),
  reasoning_watermark INTEGER NOT NULL CHECK(reasoning_watermark >= 0),
  last_seen_at INTEGER NOT NULL
);
CREATE INDEX source_cursor_last_seen_at ON source_cursor(last_seen_at);
```

Prune facts where `observed_at < now - 8*24*60*60` and cursors where `last_seen_at < now - 30*24*60*60`, in the same transaction as ingestion. Query UTC facts at display time using the current macOS local time zone and ISO Monday week. `Rebuild Local Metrics` deletes/recreates this database and cursors, clears Local Activity availability/failure/observation from state, then reconstructs from allowed sources.

## 7. Persistence, privacy, and disclosures

The sole durable directory is `~/Library/Application Support/com.patrickfu.UsageInk/`. It MUST be mode `0700` and marked excluded from backup. The only stores are `state.json` and `activity.sqlite` plus SQLite sidecars, all mode `0600`. `state.json` is atomically replaced by same-directory temporary file, file `fsync`, rename, then directory `fsync`. No preference is duplicated in `UserDefaults`. No rendered plane, PNG, RLE, temporary render artifact, raw payload, auth material, account identity, raw source locator, telemetry, crash upload, support bundle, export, or network store exists. The configured custom Codex executable path is the single durable path exception and MUST never be logged.

`state.json` accepts only the following schema and enum values; writes reject unknown fields. Times are Unix seconds and `resetsAt` uses Unix seconds.

```json
{
  "schemaVersion": 1,
  "setupDone": false,
  "boundDisplay": {"identifier": "<CBPeripheral UUID>", "displayName": "<optional alias>"},
  "preferences": {
    "displayStyle": "quotaFocus",
    "modules": {"title": true, "plan": true, "quota": true, "today": true, "weekTokens": true, "cache": false, "tps": false, "updated": true, "status": true},
    "quotaOrder": "quotaFirst",
    "title": "CODEX USAGE",
    "tpsWindowMinutes": 15,
    "dateFormat": "relative",
    "redAccent": "threshold",
    "redThreshold": 80,
    "language": "system",
    "customCodexPath": null
  },
  "sources": {
    "account": {"lastSuccessfulObservationAt": null, "availability": "unknown", "failure": null, "planType": null, "windows": []},
    "localActivity": {"lastSuccessfulObservationAt": null, "availability": "unknown", "failure": null}
  },
  "refreshRecord": {"lastSucceededFingerprint": null, "lastSuccessfulRefreshAt": null}
}
```

`boundDisplay` may be null. `boundDisplay.displayName` is trim/no-newline and at most 64 extended grapheme clusters. `lastSuccessfulObservationAt` is a Unix second or null when there has been no success. `availability` is `unknown`, `fresh`, `stale`, `authRequired`, or `unavailable`. `customCodexPath`, when non-null, is an absolute path without NUL, at most 4,096 UTF-8 bytes, and resolves to an executable at runtime; an invalid stored value is rejected. Account `failure` is null or one of `binaryMissing`, `versionTooOld`, `transportStart`, `transportExit`, `invalidJSON`, `protocolIncompatible`, `authRequired`, `backendUnauthorized`, `backendForbidden`, `rateLimitUnavailable`, `overloaded`, `timeout`, `schemaInvalid`, `unknown`; local failure is null or one of `sourceUnavailable`, `sourceUnreadable`, `sourcePermissionDenied`, `sourceMalformed`, `sourcePartialTail`, `sourceRollbackRebuild`, `sourceScanTimeout`, `unknown`; BLE and storage classifications are exactly those in Section 9 and below. `planType` MUST be erased/not stored whenever the plan module is off. Windows contain only `slot`, `usedPercent`, `windowDurationMins`, and `resetsAt` for actually displayed canonical windows. Last transport classification is RAM-only and is cleared at launch.

`setupDone` becomes true only after the first actual successful Refresh, never a skipped frame. On every cold launch, Panel Trust is invalid regardless of stored refresh record.

For corrupt JSON, show `stateCorrupt`, quarantine the original in the same directory mode `0600` and backup-excluded, retain at most one quarantine for at most seven days, then load clean defaults. A newer unknown schema is read-only and MUST NOT be overwritten; offer Reset UsageInk Data. SQLite integrity failure deletes and rebuilds only the derived database. Future migrations are ordered and explicit; migration failure is classified `migrationFailed`.

`Unbind` clears binding, succeeded fingerprint, successful Refresh time, and `setupDone`, retaining preferences and activity. `Reset UsageInk Data` clears both stores and preferences. All destructive actions require confirmation and MUST NOT alter `~/.codex`, device FDS, or send `0x99`.

Use only default `os_log` and a compile-time allowlist: app/OS/Codex versions, RPC method, duration bucket, numeric JSON-RPC code, failure classification, field-presence boolean, canonical state, retry index, schema version, and firmware byte. Never log raw stderr/message/payload, displayed values, percentages/tokens, email/IDs/title/path/machine name/`codexHome`/UUID/name/source key/JSONL/body/content/prompt/code/credentials.

English and Simplified-Chinese README, first-run disclosure, and About MUST equivalently disclose: two local-only stores; exact local source scope; no authentication-material read, telemetry, or upload; the Bound Display is physically visible/public output; reset/rebuild/unbind behavior; backup exclusion is not a Time Machine or backup guarantee; and the local Codex app-server may contact OpenAI.

## 8. BLE wire contract

Use service UUID `62750001-d828-918d-fb46-b6c11c675aec`, data UUID `62750002-d828-918d-fb46-b6c11c675aec`, and version UUID `62750003-d828-918d-fb46-b6c11c675aec`. Data MUST have read, write-with-response, write-without-response, and notify properties; version MUST be readable and one byte. Discover only this service and these characteristics.

After subscribing to data notifications, the first session notification MUST be a valid 13-byte config in this byte order: `mosi,sclk,cs,dc,rst,busy,bs,model,wakeup,led,en,display_mode,week_start`. Then write `INIT` as `0x01` with no model ID using with-response. Wait for a **fresh** `mtu=N` notification after that INIT; parse optional `rle=1` and `t=<unix-seconds>` separately. A stale notification or Apple default `N=20` fallback is not usable. Config and INIT waits are 5 s each.

For a ready session, chunk capacity is exactly:

```text
min(firmware N - 2,
    maximumWriteValueLength(.withoutResponse) - 2,
    maximumWriteValueLength(.withResponse) - 2)
```

Raw transfer requires chunk capacity >=1. RLE transfer requires capacity >=2; otherwise use raw if raw is possible. If raw capacity is <1, classify `mtuInvalid` and recover the link. `INIT`, `REFRESH`, and `SET_CONFIG` use with-response. Image chunks use without-response and wait for `canSendWriteWithoutResponse`; the final chunk of **each** plane uses with-response as a flush boundary. No fixed sleeps, unbounded in-flight guess, or fixed chunk size is allowed. Each plane has a 30 s timeout.

The 400 x 300 plane is exactly 15,000 bytes: row-major, 50 bytes per row, MSB-left. Black plane bit 1 is white and bit 0 is black. Red plane bit 1 is non-red and bit 0 is red. Send black plane fully before red, then `REFRESH 0x05`.

`WRITE_IMAGE` is `0x30, flags, data...`. Flag bit 0 selects black `0`/red `1`; bit 1 is first chunk; bit 2 is RLE. Raw first/subsequent flags are black `0x02`/`0x00`, red `0x03`/`0x01`. RLE ORs `0x04`. Golden planes are all-white `FF/FF`, all-black `00/FF`, and all-red `FF/00`.

RLE is permitted only if fresh config advertises `rle=1`. Encode under the negotiated chunk-capacity constraint using either literal `(length-1), bytes` for lengths 1...128, or repeat `0x80|(length-3), value` for repeated lengths 3...130; split runs/literals as needed so one complete code always fits one chunk. Select RLE only when this final chunk-constrained wire stream is strictly shorter than raw; otherwise send raw. A transfer failure MUST NOT silently switch RLE to raw; recover the same selected mode on a new request.

V1 MUST NOT send `0x00`, `0x02`, `0x03`, `0x04`, `0x06`, `0x91`, `0x92`, or `0x99` **as opcodes**; byte values used inside `WRITE_IMAGE` flags or data are unaffected. Wakeup configuration edits byte 9 (`wakeup`, one-based) of the current config: allowed values are 0...31 and `0xFF` for disabled. It sends only `SET_CONFIG 0x90` plus the complete 13-byte config. The immediate confirmation states old and new values. After confirmation, Runtime atomically rechecks the same session generation, `ready` state, and unchanged config digest before writing; a failed recheck sends nothing. With-response is GATT receipt only, never application ACK. On receipt, clear RAM-only consent and leave binding unchanged. V1 makes no deep-sleep claim.

## 9. Runtime state machines, scheduling, and recovery

The four orthogonal Runtime-owned state machines are Poll (`idle|running`), BLE Link, Panel Trust, and Refresh Cycle. A transition in one MUST NOT imply another unless stated here.

| Machine/state | Required transitions and meaning |
| --- | --- |
| Poll | `idle -> running` on scheduled/manual/wake/stale/retry trigger. `running` owns one app-server process and concurrent Local scan. Both account reads terminal publish one account terminal result; both account and Local terminal return to `idle`, close stdin, and evaluate the pending request. |
| BLE Link | `unavailable -> unbound|disconnected` when powered/authorized. `unbound -> scanning` only for explicit bind scan. `disconnected -> scanning -> connecting -> discovering -> subscribing -> awaitingConfig -> initializing -> ready`; config and fresh `mtu=` are mandatory. A failure advances the current budget; exhaustion is `unreachable`. Disconnect, sleep, central loss, and restart go to `disconnected`, cancel delegates/writes, and invalidate trust. `unreachable` restarts only on a new recovery trigger; unbind goes `unbound`. |
| Panel Trust | `invalid` at cold start, restart, sleep, disconnect, central loss, transfer error/timeout, or interrupted Refresh. `assumed(fingerprint, refreshedAt)` only after Section 9 best-effort success. Invalid trust with a binding queues immediate recovery once; it does not self-loop after a budget exhausts. |
| Refresh Cycle | `idle`, `waitingForPoll`, `awaitingLink`, `pending`, `transferring`, `refreshWait`, `sessionRetry`, `skipped`, `succeeded`, `failed`. Every request carries `pollAttempted` and `pollTerminal` markers. Automatic reasons coalesce; a manual reason is retained separately. |

Refresh transition table:

| From | Event/guard | To and action |
| --- | --- | --- |
| `idle` | schedule, stale boundary, first setup, manual | `waitingForPoll` with `pollAttempted=false`; coalesce automatic reasons. |
| `idle` | invalid trust and all enabled sources fresh | `pending` if ready, else `awaitingLink`; reuse observations. |
| `idle` | idle settings batch | `pending` if ready, else `awaitingLink`; no extra Poll unless due. |
| `waitingForPoll` | terminal Poll, success or failure | Set `pollTerminal=true`, compose the best honest degraded frame, then `pending` if ready, else `awaitingLink`. |
| `awaitingLink` | ready + request has `pollTerminal=true` or all enabled sources fresh | `pending`; otherwise, only if `pollAttempted=false`, `waitingForPoll`. |
| `awaitingLink` | recovery budget exhausted | `failed`; retain one dormant request until manual, wake, poweredOn, or next scheduled Poll. |
| `pending` | automatic + same fingerprint + trust assumed | `skipped`; do not mutate refresh time, trust, or setup. |
| `pending` | link not ready | `awaitingLink`, preserving the composed immutable frame. |
| `pending` | ready + manual, first setup, invalid trust, or changed fingerprint | `transferring`; full black, red, `0x05`. |
| `transferring` | both planes and `0x05` sent | `refreshWait`, start 15 s observation. |
| `refreshWait` | 15 s without observed error | `succeeded`; trust becomes assumed and record fingerprint/time. |
| `transferring`/`refreshWait` | still connected plane or `0x05` timeout; retry unused | `sessionRetry`; invalidate trust, fresh INIT, then full black/red/`0x05`. |
| `sessionRetry` | fresh `mtu=` and full resend | `refreshWait`. |
| transfer states | disconnect, sleep, restart, central loss, callback ambiguity, other failure | `awaitingLink`; invalidate trust, no offset resume, full recovery. |
| terminal states | bookkeeping | `idle`; retain one later automatic request and any manual request. |

Entering `waitingForPoll` starts the one Poll and sets `pollAttempted=true`; process completion sets `pollTerminal=true` regardless of success. No request may start a second Poll after its terminal marker.

Best-effort success means both complete planes and `0x05` were sent, then 15 s without observed error. It is not an ACK, CRC, sequence confirmation, busy completion, or pixel proof. Only a still-connected observed plane or `0x05` timeout qualifies for the one same-session retry. Every other uncertainty requires reconnect, discover, subscribe, config, INIT, and a full resend.

Sources are fresh for `<20` minutes from each own success and stale at `>=20` minutes. Missing success is `unknown`. Fresh-to-stale crossing queues one automatic Poll/Refresh; later age growth does not. Successful source result, explicit auth/unavailable result, or crossing may affect a frame. A source failure retains last value and menu age without changing BLE Link or Panel Trust. A request with unknown/stale enabled source enters `waitingForPoll` only while `pollAttempted=false`; once that Poll is terminal, it MUST compose and progress with the best honest degraded frame even if the source remains non-fresh. This prevents Poll/Link livelock.

Scheduled Poll occurs every 15 minutes from the prior Poll start. Scheduled and catch-up Polls move their deadline to Poll start + 15 minutes. An accepted manual click immediately moves the deadline to click time + 15 minutes, even during a transfer; if that click starts a Poll, its same start remains the cadence basis and the deadline is not moved again. Sleep accrues no timer backlog. Wake resumes invalid-trust recovery immediately and starts exactly one catch-up Poll only when overdue or an enabled observation is missing/stale. A manual click during automatic Poll upgrades it; during transfer it retains one later manual request. Multiple manual clicks coalesce.

Host-event behavior is fixed:

| Event | Required effect |
| --- | --- |
| Launch | Rebuild in-memory Local Activity from SQLite first; derive BLE `unbound` or `disconnected` from durable binding; set Poll `idle`, Panel Trust invalid, and Refresh idle. With a binding, enqueue immediate automatic recovery and start BLE recovery; Poll first only if an enabled source is missing/stale. Never restore a BLE session. |
| First successful bind | If no Poll runs, start one; request an initial full frame, which MAY be honestly degraded. |
| `willSleep` | Cancel running Poll and BLE work; move BLE to `disconnected`, invalidate trust, and move an in-flight Refresh to `awaitingLink`. Preserve at most one automatic and one manual reason. |
| Wake | Resume invalid-trust request immediately, use the single catch-up rule above, and start a fresh BLE budget. |
| Central `poweredOn` | If a pending request needs a Bound Display, start a fresh budget. |
| Central unavailable/unauthorized | Move BLE to `unavailable`; invalidate trust if a session existed; keep source ageing and Poll independent. |
| BLE disconnect | Move BLE to `disconnected`, invalidate trust, and fail an in-flight transfer without discarding observations. |
| Settings batch | Replace the configuration of exactly one later automatic request, whether idle, polling, awaiting recovery, or transferring. |

BLE recovery has exactly five sequential attempts: wait 2 s before attempt one, then wait 5, 15, 45, and 90 s after failures before attempts two through five. Scan timeout is 15 s, connect 10 s, config 5 s, INIT 5 s, each plane 30 s, and refresh observation 15 s. No sixth attempt exists. A new manual Refresh, wake, poweredOn, or scheduled Poll creates a new budget.

BLE classifications are `bluetoothUnavailable`, `bluetoothUnauthorized`, `boundDisplayNotFound`, `connectFailed`, `serviceMissing`, `characteristicMissing`, `subscribeFailed`, `configTimeout`, `initTimeout`, `mtuInvalid`, `planeTimeout`, `refreshTimeout`, `disconnected`, `callbackAmbiguous`, `retryExhausted`, `firmwareIncompatible`, `unknown`. Storage classifications are `stateVersionUnsupported`, `stateCorrupt`, `stateWriteFailed`, `databaseOpenFailed`, `databaseIntegrityFailed`, `databaseTransactionFailed`, `migrationFailed`, `unknown`.

## 10. Release-later gate

This section is normative for Release Ready, but does not block beginning implementation. **Implementation Ready now** means this document is complete and testable; it does not mean code exists. **Release Ready later** requires all gate evidence below.

Automation MUST cover pure rendering/fingerprint/formatting, app-server fixtures, Local scanner and SQLite transactions, BLE protocol/RLE/chunk goldens, state-machine virtual time, privacy scans, and build/package checks. Tests use synthetic data and never a real account/network. Fixtures include non-null `account` plus `requiresOpenaiAuth:true` with valid rate limits, map-present-invalid versus map-absent fallback, and oversized stdout. Local fixtures cover top-level timestamps, empty-success zero values, coverage loss, symlink/link-count/containment rejection, and both SQLite source-key checks. Goldens include 15,000-byte black/red planes, row-major MSB-left/polarity/order, the leftmost 8-pixel bit patterns, 130-byte repeat crossing chunk boundaries, all RLE boundary shapes, and unchanged elapsed time fingerprint.

The physical-device gate applies only to the exact EPD-nRF5 + 4.2-inch 400 x 300 UC8176 BWR tuple. Record firmware byte, board, panel, negotiated MTU, and mode. It MUST validate raw two-plane chart plus manual pixel inspection; if post-INIT advertises `rle=1`, it MUST also validate RLE or block the release. Inspect Bluetooth denial/re-enable, Local permission denial, black/red/`0x05` disconnects, sleep/wake, external sleep/advertisement timeout recovery, timeout defaults, and wakeup-pin confirmation/no-write. If measured timing cannot meet an ADR 0001 default, Release Ready fails until ADR 0001 is amended before a new RC; this specification MUST NOT silently change that default. No observation is a guarantee about untested hardware.

Release compatibility requires Universal `arm64` and `x86_64` slices for every bundled executable/code item; latest-stable arm64 macOS; latest Apple-supported Intel macOS >=14; and at least one latest macOS 14.x row. Each row installs, launches, opens menu, and runs the synthetic local parser. One physical row performs bind/Refresh. Codex requires `>=0.147.0` and a real signed-in operator smoke with valid three-RPC snapshot; store only version, probe/schema result, and pass/fail. No upper-version compatibility claim exists.

Distribution is GitHub Release only: `UsageInk-<version>.app.zip` and `SHA256SUMS` are the two primary assets; the versioned evidence manifest is additional. English/Chinese instructions are equivalent: verify checksum, unzip, move to `/Applications`, try ordinary first open, then System Settings > Privacy & Security > **Open Anyway** if blocked, following [Apple's official Open Anyway instructions](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac). Ordinary first open is the primary path; Finder right-click Open MUST NOT be presented as the primary path. They MUST explain unsigned/notarized and MDM risk, never recommend `xattr`, weakened Gatekeeper, or Full Disk Access. Uninstall is moving `UsageInk.app` to Trash; Application Support data remains until the confirmed `Reset UsageInk Data` action.

README, first-run, About, and release notes disclose experimental app-server/schema/buckets; local-only metrics and their TPS/cache formula; public display; unsigned assets; backup caveat; no automatic update/support/export/telemetry/upload; no battery longevity promise; and unsupported unverified hardware. No release evidence may include identity, local path, machine name, raw BLE/app-server payload/error, log body, real values/screen data, source locator, secret, operator identity, or photo. A privacy-reviewed synthetic photo remains unpublished; only its SHA-256 MAY appear.

For `0.1.0-rc.N`, create an annotated tag at a clean commit, build once, then run all gates. Only a pass creates annotated `0.1.0` at the identical SHA with identical assets/checksums. The manifest records both tags/shared SHA, `dirty=false`, redacted path-free recipe, toolchain/deployment data, assets/lipo/checksums, signing status, CI URLs/counts, bounded physical/compatibility evidence, bilingual/install/privacy results, and stable post-publish workflow URL. Attach manifest to draft release and commit it separately on default branch without retargeting tags. Verify every uploaded non-source asset, then post-publish run `gh release verify 0.1.0` and `gh release verify-asset 0.1.0 <local-asset>` for every uploaded non-source asset; never use `verify-asset` for GitHub-generated source archives. Failure withdraws immediately; failed candidate assets/evidence never promote and `N` increments.

Non-waivable blockers are any required CI/privacy failure; wrong plane length/polarity/order/bit order/golden; unconfirmed wakeup write; `0x92`, `0x99`, device wipe, or `~/.codex` mutation; failed physical inspection/recovery/timeout comparison; failed real Codex smoke; absent required compatibility row; missing bilingual official unsigned path; missing universal asset/checksum; raw transfer failure; or advertised-RLE transfer failure. Privacy leak, unconfirmed configuration write, forbidden opcode, device wipe, or Codex-home mutation requires immediate public advisory, withdrawal/current-link removal, and fixed release; immutable assets cannot be claimed removed or retagged.

## 11. Acceptance and traceability

Implementation acceptance MUST demonstrate:

| Area | Required synthetic or controlled scenario |
| --- | --- |
| App/UI | Accessory app, exact menu order, one settings panel, binding candidates, confirmation actions, no notification. |
| Rendering | All styles/layout coordinates/font sizes; all-disabled fallback; dynamic primary/secondary/none windows; EN/ZH copy; title/plan limits; token/date/accent rules; final 1-bit threshold. |
| Dedup | Manual identical frame transfers; automatic identical frame skips only with assumed trust; cold invalid-trust same content transfers. |
| Codex | Discovery order; <0.147.0; handshake order; missing/null/multi-bucket/unknown field/wrong-type/overload/timeout fixtures; sparse update ignored; no auth/write RPC. |
| Local | Allowlist rejects content/non-token events; filename source-key goldens; active/archive precedence; complete tails; equal/lower watermarks; rollback; budget exhaustion; UTC day/week/TPS/cache coverage; 8d/30d pruning. |
| Privacy | Schema allowlist, permissions, atomic state writes, corruption/migration paths, no temp artifacts, logs/store scans, reset/rebuild/unbind boundaries. |
| BLE | UUID/property/version path; fresh config/INIT/MTU; raw/RLE encoders, code-boundary chunks, final with-response flush, all plane goldens, no forbidden opcode. |
| State/recovery | 15-minute cadence, 20-minute independent stale state, sleep/wake, five-attempt delays, no overlap, eligible session retry versus mandatory reconnect, 15-second best-effort window. |
| Release later | Every Section 10 automation, physical tuple check, manual inspection, compatibility, disclosure, unsigned installation, manifest, and withdrawal path. |

Conflict resolutions applied here are explicit: V1 ignores sparse app-server updates; Cache is local Today token-weighted cache rate; Quota Focus is the default; quota module displays all returned canonical windows; `setupDone` follows ADR 0001 rather than prototype intuition; and cold invalid Panel Trust is the sole content-unchanged recovery exception.

Evidence index: app-server research commit `7fd4b0e`; EPD-nRF5 research `949f198`; coding-agent-metrics research `51006f9`; first-run prototype `cca0a41`; display prototype `46b2761`; ADR 0001 Refresh/recovery, ADR 0002 persistence/privacy, ADR 0003 verification/release; Issues #1 and #9. These are rationale, not V1 override sources.
