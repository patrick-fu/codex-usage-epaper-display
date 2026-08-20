# Local Persistence and Privacy Boundaries (Issue #7)

## Decision

UsageInk V1 is a per-current-macOS-user local app. The **Bound Display** is visible/public output: anyone who can see it can see its rendered Usage Snapshot and Local Activity Metric. Codex source files are an external authority; UsageInk reads them but never modifies them.

UsageInk has exactly two durable stores beneath its Application Support directory:

| Store | Purpose | Consistency and protection |
| --- | --- | --- |
| `state.json` | Versioned product state and latest normalized observations. | Atomic replacement: same-directory temp file `fsync`, rename, then directory `fsync`; directory mode `0700`, file mode `0600`. |
| `activity.sqlite` | Locally pseudonymous, allowlisted Local Activity facts and incremental cursors. | Fact ingestion, retention pruning, and cursor update share one SQLite transaction; directory mode `0700`, file mode `0600`, including SQLite sidecars. |

UsageInk marks both stores excluded from backup and uses no Keychain, App Group, iCloud container, network store, product analytics, remote crash SDK, support zip, usage export, or automatic upload. The backup exclusion is an app request, not a promise about Time Machine or another backup product.

The custom `codex` executable path may be retained in `state.json` for local settings, but is never logged. Apart from that explicitly configured binary path, no path is durable. These are the only two durable stores: preferences MUST NOT be duplicated in `UserDefaults` or another store.

## Scope and non-goals

This ADR fixes the V1 durable-data, retention, reset, migration, and diagnostic contract. It applies to app-server account observations, local Codex activity, BLE binding, and rendering lifecycle.

It does not add cloud sync, multi-user sharing, export, historical reporting, support bundles, device configuration persistence, app-server authentication, or device wiping. UsageInk does not read authentication material; its local app-server may itself contact OpenAI under Codex's own behavior.

## `state.json` schema allowlist

`schemaVersion` is `1`. An implementation MUST reject unknown fields on write and MUST NOT use a permissive arbitrary-payload model.

| Area | Allowed durable fields |
| --- | --- |
| Root | `schemaVersion`; `setupDone`; `boundDisplay`; `preferences`; `sources`; `refreshRecord`. |
| Setup | `setupDone` becomes true only after the first actual successful Refresh as defined by ADR 0001. |
| Binding | `CBPeripheral.identifier` as primary key; optional user-visible advertised name or user alias. RSSI and short ID are not keys; RSSI is never stored. |
| Preferences | Selected Display Style, enabled modules, order, titles, date format, threshold, red-accent behavior, TPS lookback, language, and custom `codex` path. |
| Account source | `lastSuccessfulObservationAt`; latest classified failure; availability; `planType` only when rendered; every actually displayed canonical `codex` Usage Window's slot/identity, `usedPercent`, `windowDurationMins`, and `resetsAt`. |
| Local Activity source | Only `lastSuccessfulObservationAt`, availability, and latest classified failure. Today/week, Cache hit rate, TPS, and all other local derived values never enter `state.json`. |
| Refresh record | `lastSucceededFingerprint` and `lastSuccessfulRefreshAt` only. |

On every cold start, Panel Trust is `invalid`, regardless of a saved fingerprint or refresh time. A skipped Refresh MUST NOT mutate the succeeded fingerprint, successful Refresh time, or `setupDone`.

The following are forbidden in `state.json`: wakeup-pin/cache state; pending consent; BLE session, MTU, retry, pending frame, candidate list, RSSI, raw failure text; email, account/user/installation ID, `account.type`, credits details, raw response, token/API credentials, or a raw JSONL source locator/path/session ID. Extra non-`codex` buckets are dropped. The app MUST NOT persist rendered planes, PNG, RLE, or a Display Frame.

## Normalized account boundary

Account data is normalized in memory before it can enter `state.json`. Every actually displayed primary or secondary canonical `codex` Usage Window is eligible; extra non-`codex` buckets are dropped. Null/missing data remains `unavailable`; it is never normalized to zero. `planType` is optional and retained only while displayed.

The app-server is read-only: UsageInk never starts login/logout RPCs, reads tokens, credentials, or raw auth payloads, or modifies Codex configuration.

## Local Activity database

`activity.sqlite` exists solely so today/week totals and the selected trailing 3-, 15-, or 60-minute output-throughput calculation survive restart. “Today” and “week” are query-time bins over UTC facts using the current macOS time zone and ISO-8601 Monday-start week; derived bins are never stored. A time-zone change or midnight therefore recomputes the same retained facts into the current bins. “TPS” is the selected elapsed-window output throughput, not per-request decode TPS.

### Tables and allowlists

| Table | Allowed columns | Forbidden examples |
| --- | --- | --- |
| `activity_fact` | UTC `observedAt`; positive deltas for `input`, `cachedInput`, `output`, and `reasoning`; opaque 64-lowercase-hex SHA-256 `sourceKey`. | Model, absolute/relative path, session/turn/request ID, prompt, tool input/output, JSONL body, raw cumulative counters. |
| `source_cursor` | `sourceKey`; `parserVersion`; inode generation; size; newline offset; bounded tail checksum; cumulative watermarks; `lastSeenAt`. | Any source path/locator, raw line, model, session, or content. |

At scan time only, the runtime enumerates allowed Codex source paths and applies the verified rollout filename contract: the basename starts with `rollout-`, ends with exactly `.jsonl`, contains no `.jsonl.` suffix, and its core is longer than the 20-character timestamp prefix. It removes that prefix, takes the substring before the first `_`, and requires that substring to be a lowercase 8-4-4-4-12 hexadecimal UUID. That in-memory UUID is `canonicalRolloutId`; the timestamp and `sessions`/`archived_sessions` path are excluded. It computes exactly `SHA-256(UTF8("codex-rollout-v1") + [0x00] + UTF8(canonicalRolloutId))`, where `[0x00]` is one NUL byte, not the two characters `\` and `0`. If that stable ID cannot be proven, the source is `sourceMalformed`/partial, is not guessed, and produces no ingest.

The raw basename, ID, and path are discarded after scanning and are never persisted or logged. The opaque key is locally pseudonymous and MUST NOT be reversible to a locator. Inode and size are cursor change detectors, never source identity. Discovery selects exactly one file per `sourceKey` before cursor checks: any `sessions` candidate beats every `archived_sessions` candidate; within the winning layer, the lexicographically greatest basename wins. All losing candidates are skipped and MUST NOT trigger rollback. This deterministic rule also covers revert filenames that append `_<rollout_id>` while retaining the same canonical rollout ID. A move/archive therefore does not duplicate facts. UsageInk never copies a raw JSONL file or line.

For each cumulative token family, a new observation greater than the stored watermark inserts the positive delta; an equal value inserts nothing. A lower counter, parser-version change, inode generation change, file shrink, or tail checksum mismatch is a source-scoped rollback/rebuild: remove that source's derived facts and cursor, then rescan it. Ingested facts and replacement cursor/watermarks MUST commit in one transaction. An incomplete final line does not advance the newline offset. A temporarily missing source preserves facts until normal retention; a later rediscovery is reconciled using these rules.

`cachedInput` and `reasoning` are `input` and `output` subsets respectively. **Cache hit rate** / **缓存命中率** is the canonical token-weighted `sum(cachedInput) / sum(input)` for the fixed V1 period of local Today; it is not a request hit count or request hit rate. If `sum(input) == 0` or the required local-source coverage is incomplete, it is unavailable, never zero.

Today/week totals are `sum(input) + sum(output)` over their query-time bins; cached and reasoning deltas are never added again. The UI retains the name **TPS**; it may calculate the user-selected 3/15/60-minute window from facts on demand. The only persisted measurements are the allowlisted deltas and observation times.

## Retention and destructive resets

| Data/action | Required behavior |
| --- | --- |
| Product state | Keep latest allowed values until superseded or an explicit reset. |
| Activity facts | In the ingest transaction, prune every fact with `observedAt < now - 8 * 24h`. |
| Cursors | In that same transaction, prune every cursor with `lastSeenAt < now - 30 * 24h`; update `lastSeenAt` on every successful discovery/scan. |
| Unbind | Clear `boundDisplay`, `lastSucceededFingerprint`, `lastSuccessfulRefreshAt`, and `setupDone`; retain preferences and activity. |
| Rebuild Local Metrics | Clear/recreate `activity.sqlite` and cursors, and clear the Local Activity source's observation/availability/failure in `state.json`, then reconstruct from source files. |
| Reset UsageInk Data | Clear both stores and preferences; never alter `~/.codex` or device FDS. |

Each destructive UI action MUST require explicit confirmation. Unbind, Rebuild Local Metrics, and Reset UsageInk Data never alter `~/.codex`, device FDS, or send `0x99`. V1 has no CSV or other export. Restart never restores a BLE session.

## Render and BLE lifecycle

Display Frame pixels, black/red planes, PNGs, RLE streams, encodings, and intermediate rendering artifacts live only in RAM and are discarded at the end of the Refresh cycle. They MUST NOT be written to any temporary file. The fingerprint and successful refresh time are the only render-related durable values. Unbind and restart do not issue `0x99`, a device wipe, or a session restore.

## Failure classifications

Only a classification is durable or loggable; implementations MUST discard raw cause text/payload after classifying it.

| Domain | Classifications |
| --- | --- |
| Account/app-server | `binaryMissing`, `versionTooOld`, `transportStart`, `transportExit`, `invalidJSON`, `protocolIncompatible`, `authRequired`, `backendUnauthorized`, `backendForbidden`, `rateLimitUnavailable`, `overloaded`, `timeout`, `schemaInvalid`, `unknown`. |
| Local source | `sourceUnavailable`, `sourceUnreadable`, `sourcePermissionDenied`, `sourceMalformed`, `sourcePartialTail`, `sourceRollbackRebuild`, `sourceScanTimeout`, `unknown`. |
| BLE/display | `bluetoothUnavailable`, `bluetoothUnauthorized`, `boundDisplayNotFound`, `connectFailed`, `serviceMissing`, `characteristicMissing`, `subscribeFailed`, `configTimeout`, `initTimeout`, `mtuInvalid`, `planeTimeout`, `refreshTimeout`, `disconnected`, `callbackAmbiguous`, `retryExhausted`, `firmwareIncompatible`, `unknown`. |
| State/storage | `stateVersionUnsupported`, `stateCorrupt`, `stateWriteFailed`, `databaseOpenFailed`, `databaseIntegrityFailed`, `databaseTransactionFailed`, `migrationFailed`, `unknown`. |

## Logging and diagnostics

V1 uses only default `os_log` with a compile-time allowlist. There is no file log and no debug toggle.

| May log | Must never log |
| --- | --- |
| App/OS/Codex versions; RPC method name; duration bucket; JSON-RPC numeric code; failure classification; field-presence boolean; canonical state name; retry index; schema version; firmware version. | Raw stderr, error message, payload; displayed values/percentages/tokens; email/IDs; title; paths; machine name; `codexHome`; UUID/name; source key; JSONL/body/content; prompt/code; credentials. |

No product analytics, remote crash SDK, support archive, usage export, or automatic upload exists in V1. Backup exclusion is not a guarantee against Time Machine or another backup product. OS crash diagnostics and `sysdiagnose` are outside UsageInk's control and may include process or local information; UsageInk never intentionally attaches or uploads either store.

## Corruption, versioning, and migration

`state.json` version 1 has explicit, ordered migrations for every future schema version. JSON replacement MUST use a same-directory temporary file, `fsync`, and rename. A newer unknown `schemaVersion` fails closed into a user-visible read-only reset path; it MUST NOT be overwritten.

If JSON is corrupt, surface `stateCorrupt`, quarantine the original in the same directory with mode `0600` and backup exclusion, retain only one quarantine for at most seven days, then start clean defaults. If SQLite integrity checking fails, automatically delete and rebuild only this derived activity database. Never upload corrupt files.

## Disclosure requirements

The README, first-run disclosure, and About screen MUST each provide equivalent English and Chinese disclosure that UsageInk keeps only the versioned product state plus normalized `codex` app-server observations, and locally pseudonymous positive token deltas parsed from local Codex JSONL on this Mac. They MUST also disclose:

- two local-only stores and their exact source scope;
- no authentication-material read and no UsageInk telemetry/upload;
- the Bound Display is physically visible/public output;
- reset/rebuild/unbind behavior; and
- the local Codex app-server may itself contact OpenAI.

## Acceptance scenarios

All fixtures are synthetic. Tests and manual acceptance MUST cover:

1. Grep `state.json`, `os_log` test capture, and SQLite reveals no email, raw prompt, raw JSONL locator/path, session/turn/request ID, account identity, rollout basename, or canonical rollout ID. The explicitly configured custom `codex` binary path may appear only in `state.json`. SQLite may contain only a 64-lowercase-hex opaque `sourceKey`; `sourceKey` never reaches logs.
2. A filename fixture matching the timestamp-prefix rollout contract extracts the verified UUID. Active/archive and ordinary/revert filename fixtures with that same UUID create one source key: `sessions` wins across layers and the lexicographically greatest basename wins within a layer; losers do not trigger rollback. An invalid basename/timestamp/UUID is partial and ingests nothing. Inode/size changes do not change source identity.
3. Store directory/file permissions are `0700`/`0600`; no plane/PNG/RLE/encoding temporary file is created, including after failed Refresh.
4. After restart, saved binding/preferences/facts remain but Panel Trust is `invalid` and no BLE session is restored.
5. Fact pruning follows `observedAt < now - 8 * 24h`; cursor pruning follows `lastSeenAt < now - 30 * 24h`; pruning and successful ingest are atomic.
6. Unbind, Rebuild Local Metrics, and Reset UsageInk Data require confirmation; all leave `~/.codex` and device FDS untouched and send no `0x99`. Rebuild also clears the Local Activity source state before reconstruction.
7. Corrupt JSON is backup-excluded quarantined as one `0600` copy for at most seven days and loads defaults; a future unknown schema is read-only and not overwritten; a corrupt SQLite database is automatically rebuilt from sources only.
8. Today/week recompute from UTC facts across midnight and macOS time-zone changes. Their total is `sum(input) + sum(output)`, without double-counting cached/reasoning subsets.
9. The UI labels **Cache hit rate** / **缓存命中率** and **TPS**. Cache hit rate is local-Today token-weighted `sum(cachedInput) / sum(input)`; zero input or incomplete coverage displays unavailable, not `0%`.
10. Source rollback, move/archive, incomplete tail, and parser change do not duplicate facts or preserve a raw locator/body. Classified account, source, BLE, and storage failures retain no raw text; a skipped Refresh mutates neither success fingerprint/time nor `setupDone`.
11. English and Chinese disclosures state the exact local source scope, public display visibility, reset behavior, backup limitation, no telemetry/upload, and Codex app-server caveat.

## Evidence

- `docs/adr/0001-refresh-and-recovery-state-model.md`: Panel Trust, successful Refresh, skipped-cycle, and no-device-wipe boundaries.
- `docs/research/codex-app-server-contract.md` (branch `research/codex-app-server-contract`): read-only app-server, normalized account allowlist, and structured error handling.
- `docs/research/epd-nrf5-interoperability.md` (branch `research/epd-nrf5-interoperability`): ephemeral transfer artifacts and no-ACK BLE recovery boundary.
- `docs/research/coding-agent-metrics.md` (branch `research/coding-agent-metrics`) and Issue #10: incremental local facts, rebuild semantics, and token-weighted cached-input terminology.
- Prototype branches and Issues #2–#6: one Bound Display, first-run/recovery, and Display Style customization scope.
