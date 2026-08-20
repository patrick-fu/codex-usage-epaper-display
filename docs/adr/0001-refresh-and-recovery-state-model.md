# Refresh and Recovery State Model (Issue #6)

## Decision

UsageInk V1 uses four orthogonal, actor-owned state machines: **Poll**, **BLE Link**, **Panel Trust**, and **Refresh Cycle**. A state change in one machine MUST NOT imply a state change in another except where this document names the transition. This avoids treating a fresh Usage Snapshot as proof that the panel changed, or a healthy BLE connection as proof that source data is current.

The owner serializes all events on one executor. Lifecycle state needed across launches is durable, while connection-session state is never restored after process restart. Storage schema, retention, and allowlists are owned by Issue #7.

## Scope and non-goals

This decision defines V1 collection cadence, display submission, recovery, deduplication, stale-data treatment, and menu-bar attention.

It does not define display layout, persistence schema, CoreBluetooth packet pacing, device selection UI, wakeup-pin configuration, or physical-panel verification. V1 supports one Bound Display and keeps its BLE session ready after a successful Refresh. It MUST NOT send the MCU system-sleep opcode (`0x92`); it also does not send optional panel-sleep opcode `0x06` in V1.

## Resolved principles

- A **Refresh** is best effort: all image blocks and `REFRESH` (`0x05`) were sent, followed by 15 seconds without an observed transport error. It is not a pixel check, firmware acknowledgement, or proof that the full frame reached the controller.
- The EPD protocol has no application-level ACK, sequence number, or CRC. A failed or interrupted transfer has no resumable offset.
- Account quota and Local Activity Metric are independent sources. Their freshness, failure, and stale age are never merged.
- Automatic Refresh is content-driven. Passing time, retry count, connection state, and diagnostic timestamps alone MUST NOT cause a display write.
- A manual Refresh is an explicit request to send a complete frame even when its fingerprint is unchanged.
- Attention is menu-bar-only. V1 sends no macOS notification for stale data, source failures, or an unreachable display.

## Canonical machines

### 1. Poll

`idle` and `running` are the only Poll states. `running` owns one `codex app-server --stdio` process.

| From | Event / guard | To | Required action |
| --- | --- | --- | --- |
| `idle` | scheduled, manual, wake catch-up, stale-boundary, or explicit retry trigger | `running` | Start one per-Poll app-server process. |
| `running` | either app-server read becomes terminal while the other read or Local scan remains | `running` | Hold the account result until both app-server reads are terminal; publish the Local result independently. |
| `running` | both app-server reads are terminal | `running` | Publish one account terminal result: valid Usage Snapshot if both reads are valid, otherwise an account failure classification. |
| `running` | account terminal result and Local scan terminal result both exist | `idle` | Close stdin, let the process exit, and evaluate the pending Refresh request. Success from one source never requires success from the other. |

Each Poll MUST perform `initialize` → `initialized` → `account/read` and `account/rateLimits/read`, then exit. V1 MUST ignore sparse `account/rateLimits/updated` notifications because every Poll uses short-lived reads; this does not deny that the protocol supports sparse-update merge for a future long-lived client. A Poll may run the Local scan alongside the app-server reads, but `running → idle` is legal only after the combined account terminal result and the Local scan terminal result both exist.

### 2. BLE Link

The durable binding is separate from the transient link. An unbound app starts at `unbound`; an app with a stored binding starts at `disconnected`.

| State | Allowed transitions | Meaning |
| --- | --- | --- |
| `unavailable` | central powered on/authorized → `unbound` or `disconnected` | Bluetooth unavailable or unauthorized; no scan/connect attempt. |
| `unbound` | user scan → `scanning` | No Bound Display. |
| `disconnected` | recovery trigger → `scanning` | A Bound Display exists but no usable session. Each trigger starts its five-attempt recovery budget. |
| `scanning` | matching Bound Display found → `connecting`; failed attempt → next budget attempt or `unreachable` | Scan only for the Bound Display during recovery. |
| `connecting` | connected → `discovering`; failure/timeout → retry or `unreachable` | GATT is not yet trusted. |
| `discovering` | required service and characteristics found → `subscribing`; failure → retry or `unreachable` | Discover only the documented service and characteristics. |
| `subscribing` | notify enabled → `awaitingConfig`; failure → retry or `unreachable` | The first config notification is required for this connection. |
| `awaitingConfig` | valid config notification → `initializing`; timeout → retry or `unreachable` | A prior connection's config is never reusable. |
| `initializing` | new `mtu=` notification after `INIT` → `ready`; timeout/error → retry or `unreachable` | `INIT` is the session boundary. |
| `ready` | refresh, normal idle | `ready` | Keep the BLE connection; it is eligible to transfer. |
| any session state | disconnect, willSleep, central loss, or process restart → `disconnected` | Cancel delegates and pending writes; invalidate Panel Trust. |
| `unreachable` | a new recovery trigger → `scanning`; explicit unbind → `unbound` | Retry budget for the triggering recovery cycle is exhausted. |

`disconnected` and `unreachable` are distinct: the first says recovery has not yet been exhausted; the second is a user-visible terminal result for this trigger. The menu MUST show **Display unavailable** plus the last transport reason and, when available, the last successful Refresh age. It MUST keep source collection running.

### 3. Panel Trust

| State | Transition |
| --- | --- |
| `invalid` | Initial state at cold start; also entered on process restart, `willSleep`, BLE disconnect, central loss, any transfer/refresh timeout or error, and any interrupted Refresh. If a Bound Display exists, enqueue immediate automatic recovery. |
| `assumed(fingerprint, refreshedAt)` | Entered only after a best-effort Refresh success. |

`assumed` means UsageInk may use its own last successful frame record as the expected panel content. It MUST NOT be described as physical confirmation. On cold launch, restart, sleep, or disconnect, a Bound Display entering `invalid` queues one automatic recovery; it does not wait for the next 15-minute deadline. Remaining `invalid` after that recovery budget is exhausted does not enqueue another budget by itself. Recovery may reuse data only when every enabled source has a `lastSuccessfulObservationAt` younger than 20 minutes; a missing or stale observation requires a Poll before composing.

The normal `invalid` path requires reconnect → discover → subscribe → config → `INIT` before another transfer, then sends black and red planes in full. The sole exception is the `sessionRetry` state below: only a still-connected session with an observed plane or `0x05` timeout may issue one fresh `INIT` and a full resend. That retry consumes the same request and MUST NOT enqueue a competing recovery until it fails. Disconnect, sleep, restart, central loss, or callback ambiguity always require the normal full connection chain. There is no partial resend or breakpoint continuation.

### 4. Refresh Cycle

| State | Transition | Required action |
| --- | --- | --- |
| `idle` | scheduled, stale-boundary, first setup, or manual request → `waitingForPoll` | Coalesce automatic reasons; a manual reason is retained separately. |
| `idle` | invalid-trust recovery with all enabled source observations fresh → `awaitingLink` or `pending` | Reuse fresh data immediately; choose `pending` when BLE is already `ready`. |
| `idle` | an idle configuration batch → `pending` or `awaitingLink` | Compose from existing source observations without adding a Poll; choose `pending` only when BLE is `ready`. |
| `waitingForPoll` | Poll terminal and no usable link → `awaitingLink` | Preserve the request and start/restart BLE recovery as appropriate. |
| `waitingForPoll` | Poll terminal and link `ready` → `pending` | Compose the frame from the independent source states. |
| `awaitingLink` | BLE `ready` and all enabled sources fresh → `pending` | Resume the same request; it has not been discarded. |
| `awaitingLink` | BLE `ready` and any enabled source missing or stale → `waitingForPoll` | Poll before composing an invalid-trust recovery frame. |
| `awaitingLink` | recovery budget exhausted → `failed` | Leave BLE `unreachable`; retain one dormant manual or automatic request until a manual Refresh, wake, `poweredOn`, or next scheduled Poll starts a new budget. |
| `pending` | automatic + unchanged fingerprint + Panel Trust `assumed` → `skipped` | Skip the transport. |
| `pending` | transfer required and BLE not `ready` → `awaitingLink` | Preserve the composed request and start recovery without mutating the in-flight frame. |
| `pending` | BLE `ready` + manual, first setup, Panel Trust `invalid`, or changed fingerprint → `transferring` | Send full black plane, then full red plane, then `0x05`. |
| `transferring` | both planes sent and `0x05` sent → `refreshWait` | Begin the 15-second observation window. |
| `refreshWait` | 15 seconds without observed error → `succeeded` | Set Panel Trust `assumed`; record the fingerprint and Refresh time. |
| `transferring` or `refreshWait` | still connected + plane or `0x05` timeout + session retry unused → `sessionRetry` | Invalidate Panel Trust; issue one new `INIT`, then resend both planes and `0x05`. |
| `sessionRetry` | new `mtu=` then full resend reaches `refreshWait` | `refreshWait` | This is the only same-session recovery. |
| `transferring`, `refreshWait`, or `sessionRetry` | disconnect, sleep, restart, callback ambiguity, or any non-eligible failure → `awaitingLink` | Invalidate Panel Trust, start a full BLE recovery budget when one is not already active, and never resume an offset. |
| `skipped`, `succeeded`, `failed` | completion bookkeeping → `idle` | Retain one later automatic request; a retained manual request remains actionable on the next recovery trigger. |

`skipped` is a distinct terminal state. It MUST NOT update Refresh time, Panel Trust, or `setupDone`. `succeeded` is reachable only after an actual full send plus the error-free 15-second wait. `setupDone` is durable first-run product state and MUST become true only on the first such `succeeded` Refresh. Cold start therefore remains eligible for an initial full Refresh even if a saved fingerprint is equal.

## Host events and scheduling

| Host event | Required effect |
| --- | --- |
| app launch | Poll `idle`; BLE is `unbound` or `disconnected`; Panel Trust `invalid`; Refresh `idle`. Do not infer a live session from persistence. With a Bound Display, immediately enqueue automatic recovery and start BLE recovery; Poll first if any enabled source observation is missing or stale. |
| `willSleep` | Cancel a running Poll and BLE work; transition BLE to `disconnected`, invalidate Panel Trust, and move an in-flight Refresh to `awaitingLink`. Preserve one pending manual/automatic reason, but do not queue a reason per missed timer. |
| wake | Immediately resume the invalid-trust automatic request, even after a short sleep. If the 15-minute deadline elapsed while asleep, or any enabled source observation is missing or stale, run exactly one catch-up Poll. Never replay every missed interval. Start a fresh BLE recovery budget. |
| central `poweredOn` | Start a fresh BLE recovery budget if a pending Refresh needs a Bound Display. |
| central unavailable/unauthorized | Move BLE to `unavailable`; invalidate Panel Trust if there was a session; leave Poll and source aging independent. |
| BLE disconnect | Move BLE to `disconnected`, invalidate Panel Trust, and fail the in-flight Refresh. |
| configuration change | Merge all frame-affecting changes into the latest one later automatic request, whether Refresh is idle, polling, transferring, or awaiting recovery. Do not mutate an in-flight frame. |

A scheduled Poll is due every 15 minutes from the start of the previous Poll. Starting any scheduled, catch-up, or manual Poll resets the next deadline to that Poll's start + 15 minutes. A manual Refresh also resets it immediately when accepted, before its Poll starts; the scheduled timer must not create a duplicate Poll while that manual request is pending. Timers do not accrue backlog during sleep.

## Trigger and coalescing rules

| Trigger | Poll | Refresh behavior | BLE budget |
| --- | --- | --- | --- |
| 15-minute schedule | yes | Automatic; transfer when semantic fingerprint changed or Panel Trust is `invalid`. | A new scheduled Poll starts a new budget when recovery is needed. |
| wake / short-sleep recovery | only when overdue or any enabled source observation is missing or stale | Immediately resume invalid-trust automatic recovery; Poll before transfer only when source state requires it. | New budget. |
| manual Refresh | yes, before composing | Always full-frame transfer when link becomes ready, even if unchanged. | New budget. |
| app launch with a Bound Display | only when any enabled source observation is missing or stale | Immediately enqueue automatic full Refresh; its initial frame may be honest and degraded. | New budget. |
| first usable bound display | yes if no Poll is running | Initial full frame; may be an honest degraded frame. | New budget. |
| link `poweredOn` / reconnect needed | no extra Poll unless one is already requested | Resume pending Refresh after recovery. | New budget. |
| idle configuration batch | no extra Poll unless its normal deadline is due | One automatic Refresh; normal fingerprint rule applies. | Existing recovery cycle only. |
| next Poll while another Poll runs | joins it | At most one later automatic Refresh reason. | None. |

At most one Poll, one BLE recovery attempt sequence, and one Refresh transfer may exist at a time. Automatic requests coalesce into one pending reason. Configuration changes always replace the configuration payload of that later automatic request, including while Poll or transfer is active. If a manual request arrives during an automatic Poll, it upgrades that request to manual and joins the active Poll; it does not start a second process. If it arrives during an automatic transfer, retain one manual request to run after the transfer becomes terminal, and reset the schedule deadline at the time of the click. Multiple manual clicks coalesce to one subsequent manual Refresh.

## Frame Fingerprint

The Frame Fingerprint is a canonical serialization of only display-semantic inputs. It MUST include:

- selected Display Style and all frame-affecting configuration: visible modules, order, titles, date format, threshold rules, and red-accent behavior;
- each rendered account Usage Window's identity, displayed percentage, duration, canonical absolute `resetsAt` value, date-format option, and explicit rendered availability state;
- each rendered Local Activity Metric's value and coverage/availability state; and
- the selected TPS lookback (3, 15, or 60 minutes) and the resulting value/availability state.

It MUST exclude relative rendered countdowns, source age after its state is already chosen, last Poll/Refresh/updated timestamps, schedule deadline, retry counters, pending reasons, connection state, RSSI, MTU, diagnostics, and every transport-only field. These excluded pixels, if a style exposes them, freeze at the last successful Refresh; passing time alone never changes the fingerprint. Unknown/null is never rendered as zero.

## Source freshness and failure

Every source keeps `lastSuccessfulObservationAt`, last valid value, and latest failure classification independently. It is **fresh** for less than 20 minutes after its own success and **stale** at or beyond 20 minutes; a later success clears only that source's stale state. Account failure never marks Local Activity stale, and vice versa.

An enabled source with no `lastSuccessfulObservationAt` is `unknown`, not fresh. Cold launch and recovery MUST Poll before composing when any enabled source is `unknown`.

`fresh`, `stale`, `authRequired`, and `unavailable` are visible semantic states. They are included in the Frame Fingerprint. At each source's 20-minute fresh→stale crossing, enqueue one automatic request and Poll before composing; if that source remains stale, the resulting honest degraded frame is automatically transferred when the link is available. Later growth of the displayed/menu age while the source remains `stale` does not enqueue another request. The physical panel can retain an older frame for a long time only when BLE is unavailable; the menu then shows the age and transport reason.

TPS is calculated whenever a Poll calculates Local Activity Metrics, including scheduled, catch-up, and manual Polls. It never runs on an independent display timer. It uses the configured trailing 3-, 15-, or 60-minute elapsed-time window: `sum(output token deltas observed in the window) / window seconds`. It is a local-Mac window throughput label, not provider-native decode rate.

On source failure, UsageInk MUST retain the last valid value and record the classified failure and age in the menu. It does not change BLE Link or Panel Trust. A successful source result, an explicit auth/unavailable result, or a fresh→stale crossing may change the visible semantic state and therefore request an automatic Refresh. On BLE failure, UsageInk MUST invalidate Panel Trust and recover transport; it does not discard source observations or reclassify them as stale. These failure paths are independent.

For a manual or initial Refresh after a failed Poll, compose the best available honest frame: valid values retain their stale/unavailable presentation, and missing values use their explicit unavailable/auth/incompatible text, never `0%`. Automatic Refreshes still require the fingerprint rule above.

## Timeouts and retry budgets

All values below are V1 defaults and **MUST be calibrated on real hardware** before release. A timeout is an observed failure, not evidence that the peripheral or panel did nothing.

| Operation | Timeout | Retry budget / disposition |
| --- | ---: | --- |
| app-server `initialize` | 5 s | Ordinary Codex failure: one retry. |
| each `account/read` and `account/rateLimits/read` | 10 s | Ordinary Codex failure: one retry. |
| app-server overloaded (`-32001`) | 30 s total retry window | At most three retries with jittered backoff; stop at whichever limit occurs first. |
| Local Activity scan | implementation-bounded scan | One retry, then preserve its prior observation and report failure. |
| BLE scan | 15 s | Consume the current BLE recovery sequence. |
| BLE connect | 10 s | Consume the current BLE recovery sequence. |
| config notification after subscribe | 5 s | Consume the current BLE recovery sequence. |
| `INIT` to new `mtu=` notification | 5 s | Consume the current BLE recovery sequence. |
| each full image plane | 30 s | Same-session `INIT` + full-frame retry once; otherwise recover BLE. |
| `0x05` observation wait | 15 s | Enter the one allowed `sessionRetry` when still connected and unused; otherwise recover BLE. No completion assertion. |

An ordinary Codex retry means one retry after the original attempt. An overload retry uses the same Poll only while the 30-second window remains; it never overlaps requests. A BLE recovery budget contains exactly five sequential attempts. Wait 2 seconds before the first attempt; after each failure, wait **5, 15, 45, and 90 seconds** respectively before attempts two through five. An attempt runs to its own terminal success or timeout before the next delay begins; attempts never overlap. There is no sixth attempt. After the fifth failure BLE enters `unreachable`. A new manual Refresh, wake, `poweredOn`, or next scheduled Poll starts a new budget.

Within one still-connected session, only an observed image-plane timeout or `0x05` observation timeout may enter `sessionRetry`, exactly once: issue `INIT`, wait for a new `mtu=`, and resend both full planes plus `0x05`. It MUST NOT resend only the failed plane or continue from an offset. Failure of that attempt, any disconnect, sleep, restart, central loss, or callback ambiguity invalidates the session and uses the full BLE sequence instead.

## Acceptance scenarios

1. On cold launch with a saved fingerprint and all enabled source observations younger than 20 minutes, Panel Trust is `invalid`; UsageInk immediately starts BLE recovery without waiting 15 minutes, reuses those observations, and sends a full frame. The first actual success, and only it, sets `setupDone`.
2. A successful scheduled Poll with unchanged visible data performs no BLE write when Panel Trust is `assumed`.
3. A manual Refresh always starts or joins a Poll, resets the 15-minute deadline, and sends a full frame even when the fingerprint is unchanged.
4. A 25-minute-old account observation with a 2-minute-old Local Activity observation reports account stale and Local Activity fresh. The one fresh→stale crossing changes the fingerprint and transfers an honest degraded frame when BLE is available; later age growth alone does not.
5. A source failure preserves the last value and reports its age in the menu; it does not invalidate Panel Trust or change BLE Link. A BLE disconnect invalidates Panel Trust without discarding either source value.
6. A five-minute sleep with a Bound Display immediately resumes automatic recovery after wake. An interrupted transfer permits only reconnect → config → `INIT` → full black/red resend; no offset is reused.
7. In a still-connected session, a plane or `0x05` timeout performs exactly one `INIT` + two-full-plane + `0x05` retry. A disconnect, sleep, restart, or callback ambiguity never uses this exception.
8. Exactly five sequential BLE attempts occur: wait 2 seconds before the first, then 5/15/45/90 seconds after each preceding failure. They never overlap. Exhaustion shows **Display unavailable** in the menu, produces no macOS notification, and does not immediately restart while Panel Trust remains `invalid`. A manual Refresh or next scheduled Poll begins a new budget.
9. A wake after multiple missed intervals runs exactly one catch-up Poll. A manual click during an active automatic Poll causes no second app-server process.
10. An unchanged automatic frame reaches `skipped` and updates neither Refresh time, Panel Trust, nor `setupDone`.
11. A best-effort success is recorded only after both planes and `0x05` were sent and the full 15-second observation window had no error; tests must not assert pixel verification.
12. A `account/rateLimits/updated` notification in V1 causes no snapshot mutation; only the next per-Poll reads may update quota data.

## Evidence

- `docs/research/codex-app-server-contract.md` (branch `research/codex-app-server-contract`): per-process app-server lifecycle, 5-second initialize and 10-second read limits, and sparse notification semantics.
- `docs/research/epd-nrf5-interoperability.md` (branch `research/epd-nrf5-interoperability`): no application-level ACK/sequence/CRC; required reconnect, config, `INIT`, and full-frame recovery.
- `docs/research/coding-agent-metrics.md` (branch `research/coding-agent-metrics`) and Issue #10: independent source quality, Local Activity semantics, and 3/15/60-minute TPS windows.
- `prototypes/first-run-menu-state-prototype.html` (branch `prototype/first-run-menu-workflow`) and Issues #2–#5: degraded frames, forced manual transfer, automatic deduplication, one Bound Display, and explicit recovery UX.
