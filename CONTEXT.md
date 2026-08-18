# UsageInk

UsageInk presents Codex subscription usage on a single bound e-paper display. This glossary names the concepts shared by product decisions, specifications, and implementation work.

## Language

**Usage Snapshot**:
The plan information and usage windows obtained together at one point in time.
_Avoid_: Raw response, usage payload

**Usage Window**:
A quota interval with a used percentage, duration, and reset time.
_Avoid_: Bucket, limit

**Bound Display**:
The single e-paper display selected to receive UsageInk output.
_Avoid_: Peripheral, tag, device

**Display Frame**:
A complete 400×300 image prepared for the Bound Display.
_Avoid_: Bitmap, screen payload

**Display Style**:
A selectable information hierarchy used to compose a Display Frame.
_Avoid_: Layout variant, template

**Local Activity Metric**:
A token or throughput measure covering Codex activity observed on this Mac, distinct from an account quota.
_Avoid_: Usage Window, account usage

**Refresh**:
The successful transfer of a new Display Frame followed by an e-paper refresh command.
_Avoid_: Sync, update, push
