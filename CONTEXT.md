# UsageInk

UsageInk presents Codex subscription usage on a single bound e-paper display. This glossary names the concepts shared by product decisions, specifications, and implementation work.

## Language

**Usage Snapshot**:
The plan information and usage windows obtained together at one point in time.
_Avoid_: Raw response, usage payload

**Source Observation**:
The latest normalized value and availability state accepted from an account or local activity source, together with when that source was successfully observed.
_Avoid_: Raw response, cached payload

**Usage Window**:
A quota interval with a used percentage, duration, and reset time.
_Avoid_: Bucket, limit

**Bound Display**:
The single e-paper display selected to receive UsageInk output.
_Avoid_: Peripheral, tag, device

**Display Frame**:
A complete 400×300 image prepared for the Bound Display.
_Avoid_: Bitmap, screen payload

**Frame Fingerprint**:
The semantic identity of a Display Frame used to decide whether an automatic Refresh is necessary. It includes visible data and configuration but excludes time passing, transport state, and other changes that should not cause a Refresh by themselves.
_Avoid_: Pixel hash, last sent fingerprint

**Display Style**:
A selectable information hierarchy used to compose a Display Frame.
_Avoid_: Layout variant, template

**Local Activity Metric**:
A token or throughput measure covering Codex activity observed on this Mac, distinct from an account quota.
_Avoid_: Usage Window, account usage

**Activity Fact**:
An allowlisted, timestamped positive token delta derived from a local Codex cumulative counter. It may carry an opaque source key but no conversation content or recoverable source locator.
_Avoid_: Raw JSONL event, session record

**Refresh**:
The complete transfer of a new Display Frame followed by an e-paper refresh command without an observed transport failure. It is a best-effort commitment, not confirmation that the physical pixels were inspected.
_Avoid_: Sync, update, push

**Panel Trust**:
Whether UsageInk may assume the Bound Display still shows the Display Frame from its last successfully completed Refresh. An interrupted display session or UsageInk restart invalidates this assumption even when the frame content has not changed.
_Avoid_: Connection state, last sent frame
