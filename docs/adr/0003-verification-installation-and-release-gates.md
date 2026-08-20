# Verification, Installation, and Release Gates (Issue #8)

## Decision

UsageInk V1 has two non-interchangeable gates.

| Gate | Decision it permits | Required evidence |
| --- | --- | --- |
| **Specification/Implementation Ready** | Issue #9 may synthesize the V1 specification and implementation work may proceed. | This ADR's executable contracts, acceptance scenarios, and evidence schema are complete. Synthetic test plans and physical scripts MAY still be unexecuted. |
| **Release Ready** | A passing annotated RC may receive its final annotated tag and GitHub Release. | Fresh evidence for the RC tag/commit meets every mandatory automated, compatibility, physical-device, installation, disclosure, and manifest requirement below; the final tag and assets obey the tag-promotion contract below. |

Research, prototypes, prior branches, and a passing build from another commit MAY inform implementation but MUST NOT be presented as Release Ready evidence. An old test run, device observation, image, checksum, or compatibility result is not evidence for a later RC.

The first V1 candidate is `0.1.0-rc.1`; later candidates increment `N` as `0.1.0-rc.N`. A candidate MUST remain a pre-release until every Release Ready gate passes. A passing `0.1.0-rc.N` promotes only to annotated `0.1.0` at the same commit and with the exact same checksummed assets. UsageInk makes no bit-for-bit reproducibility claim; it provides a repeatable build recipe and SHA-256 checksums for the released assets.

## Scope and non-goals

This ADR fixes the verification, compatibility, unsigned-installation, release-evidence, rollback, and disclosure contracts for UsageInk V1. It supplements ADR 0001's state and best-effort **Refresh** contract and ADR 0002's local-data and privacy contract; it does not redefine them.

It does not promise a signed/notarized distribution, App Store delivery, automatic updates, telemetry, support bundles, a remote verification service, firmware flashing, custom firmware, or verification of hardware outside the exact tuple below.

## Automation gate

CI MUST use synthetic fixtures only. It MUST NOT use a network connection, a real Codex account, a real `~/.codex` source, a real BLE peripheral, or real screen data. Fixture identifiers, values, paths, payloads, and generated frames MUST be synthetic and non-sensitive.

The automated suite MUST include the following categories. A category is complete only when its listed boundary is asserted, not merely exercised.

| Area | Required synthetic coverage |
| --- | --- |
| Codex integration | A fake `codex app-server --stdio` handshake for `initialize` → `initialized` → `account/read` and `account/rateLimits/read`; terminal process/read failures; null/missing fields; schema-invalid values; canonical `codex` multi-bucket data and dropped non-`codex` buckets; explicit `authRequired`, incompatible, and degraded presentations. |
| ADR 0001 state model | The four independent machines, one serialized owner, virtual clock scheduling, 15-minute cadence, 20-minute freshness boundary, automatic coalescing/deduplication, manual override, one Poll/process, all finite retry delays and budgets, sleep/wake catch-up, interrupted transfer, and the one eligible same-session `INIT` retry. Tests MUST prove that no partial resend, offset resume, overlap, or extra retry occurs. |
| Display encoding | Per `docs/research/epd-nrf5-interoperability.md` on branch `research/epd-nrf5-interoperability`, golden tests from known synthetic Display Frames for 400×300 pixels require exactly 15,000 bytes per black and red plane; black plane then red plane then `0x05`; row-major MSB-left bits; black-plane `1=white`/`0=black`; red-plane `0=red`/`1=not-red`; and RLE encoding/decoding and chunk boundaries as pure functions. Goldens MUST include all-white `FF`/`FF`, all-black `00`/`FF`, and all-red `FF`/`00` (black/red plane respectively). Tests MUST fail for a wrong byte count, plane order, bit order, polarity, RLE stream, or chunk sequence. |
| Local Activity | Positive-delta ingestion; source selection across active/archive and revert names; rollback/rebuild, partial final line, parser migration, pruning, UTC-to-local today/week recomputation across midnight and time-zone changes, TPS 3/15/60 elapsed windows, cache-hit definition and incomplete coverage, and derived-value non-persistence. |
| Privacy and stores | ADR 0002 allowlists, atomic state replacement, `0700`/`0600` modes, reset/unbind/rebuild confirmation semantics, migration/future-version failure, JSON/SQLite corruption handling, classified-only diagnostics, no `0x92`/`0x99`, no `~/.codex` mutation, and no rendered plane/PNG/RLE/temp file on either success or failure. A privacy scan reports only pass/fail in release evidence. |
| Rendering/configuration | Each of the three Display Styles—Balanced, Quota Focus, and Activity Focus—renders valid, unavailable, stale, and auth/incompatible synthetic data. Frame Fingerprint tests prove inclusion of every frame-affecting configuration and exclusion of time, transport, retry, MTU, and diagnostic state. |
| Compatibility degradation | Codex below `0.147.0`, missing executable, and runtime capability-probe failure show an honest incompatible/unavailable state, perform no unsafe assumption, and preserve independent Local Activity behavior. |

Snapshot/golden inputs MUST be held in the repository or generated deterministically by the test, with an explicit fixture version. CI MAY use a fake clock and fake transport; it MUST NOT infer physical pixel confirmation from either.

## Physical-device gate

Physical Release Ready evidence is required for the exact target tuple only:

`EPD-nRF5` + `4.2-inch 400×300` + `UC8176` + `BWR`.

For each RC tag/commit, an operator MUST run and record the script below against that tuple. The record MUST state the exact firmware version byte, board identity, panel identity, negotiated MTU, and advertised transfer mode. Firmware version `>= 0x16` is an eligibility check only; it is not blanket proof for a board, panel, MTU, mode, or future firmware.

1. Discover the Bound Display; connect; discover required service and characteristics; subscribe; receive/configure the session; send `INIT`; observe a new `mtu=` notification; record negotiated MTU.
2. Always send the raw protocol using both colors and a full refresh, with black then red then `0x05`. If this exact tuple's post-`INIT` configuration explicitly advertises `rle=1`, also send the advertised RLE protocol using both colors and a full refresh; its failure is a blocker and MUST NOT be hidden by disabling RLE after the RC. If it does not advertise `rle=1`, record RLE as unsupported for this tuple. The synthetic test chart MUST expose the row-major MSB-left orientation, required plane polarities, edges, text, and red/black regions without displaying real account or Local Activity data.
3. Perform separate manual pixel inspection of that synthetic chart after every required transfer mode and record manual pass/fail. A privacy-reviewed synthetic-chart photo MAY be retained only in a non-published evidence area; published evidence MAY include only its SHA-256, never the photo or a link. A completed **Refresh** remains best effort under ADR 0001; physical inspection is separate evidence, never a transport-success assertion.
4. On a fresh install/first run, deny Bluetooth permission, then re-enable it and verify the honest permission-denied/recovery path. Verify a documented `sourcePermissionDenied` Local Activity path when macOS denies source access.
5. Force a disconnect separately while sending the black plane, red plane, and `0x05`; verify Panel Trust invalidation and the required recovery. Verify that only an eligible still-connected timeout uses one same-session `INIT` + two-full-plane retry, and that a disconnect requires full reconnect → discover → subscribe → config → `INIT`.
6. Put the Mac to sleep and wake it during an active/pending Refresh. Verify one catch-up/recovery path, no timer backlog, no partial resume, and the ADR 0001 retry budget.
7. V1 MUST NOT send optional panel-sleep `0x06` or MCU system-sleep `0x92`, and MUST NOT claim device deep-sleep capability. Verify recovery only after the device externally sleeps or its advertisement times out: discover/reconnect, configure, `INIT`, and a full Refresh. `wakeup_pin` MUST NOT be written unless the test includes a distinct, explicit human confirmation immediately before the write; absent that confirmation, the trace MUST prove no write.
8. Exercise Unbind and Reset UsageInk Data with confirmation. Verify no `0x92`, no `0x99`, no device wipe, and no mutation of `~/.codex`.
9. Record measured app-server, scan, connect, config, `INIT`, each-plane, and `0x05` observation timings against ADR 0001 defaults. If this exact tuple does not satisfy a default, Release Ready fails; ADR 0001 MUST be amended before a new RC can use a changed value. This ADR MUST NOT override ADR 0001 timeout values, and a default copied from research is insufficient.

The physical script MUST stop and fail the gate on a safety-critical observation. It MUST NOT hide a failed `rle=1` mode by silently retrying with raw mode. Raw transfer is always mandatory; RLE is mandatory only when this exact tuple advertises `rle=1` after `INIT`.

## Compatibility contract

The deployment target is macOS `14.0`. The release asset MUST be a Universal Binary containing `arm64` and `x86_64`; lipo evidence MUST cover the app executable and every bundled executable, framework, plug-in, helper, and other bundled code.

For every RC, real-Mac smoke rows MUST include: (a) `arm64` on the latest stable macOS at the RC date; (b) `x86_64` on the latest Apple-supported Intel macOS `>= 14`; and (c) at least one latest macOS 14.x row. Rows MAY overlap when one Mac/OS combination satisfies more than one requirement. Every row MUST install, launch, present the menu, and run the synthetic local parser. BLE bind plus one best-effort Refresh is required only once, by the Physical-device gate on at least one row; it is not repeated per architecture. The evidence records product version, build number, architecture, and whether Intel support existed. Every unrun matrix cell is unverified and MUST NOT be claimed as passed.

UsageInk requires Codex `>= 0.147.0` plus a successful runtime capability probe. A volunteer release operator using a real, already signed-in Codex installation MUST run `initialize`, `account/read`, and `account/rateLimits/read` and obtain a structurally valid Usage Snapshot. The manifest records only Codex version, runtime probe/schema outcome, and valid pass/fail—not values, identity, payload, or path. Synthetic CI alone tests `authRequired`; that scenario does not replace this real smoke. There is no upper-version compatibility claim. A newer Codex that fails the probe MUST degrade honestly and safely, and prompt a patch release; if the current RC itself fails its required Codex smoke/probe, Release Ready is blocked.

Only the exact `EPD-nRF5` / 4.2-inch 400×300 `UC8176 BWR` tuple, firmware byte, board, MTU, and mode recorded for an RC are verified. Other panels, boards, firmware, modes, and unrecorded tuple combinations are unsupported/unverified and MUST be disclosed as such.

## Unsigned installation and removal

Distribution is GitHub Release only. Each release MUST publish exactly these primary installation assets:

- `UsageInk-<version>.app.zip`
- `SHA256SUMS`

The versioned evidence manifest is an additional evidence asset, not a third installation asset.

The English and Chinese README/release installation sections MUST be equivalent and instruct users to download only from the GitHub Release, verify the app ZIP against `SHA256SUMS`, unzip it, move `UsageInk.app` to `/Applications`, and make one normal first open attempt. If macOS blocks it, the official path is System Settings → Privacy & Security → **Open Anyway**, followed by confirmation. Documentation MUST link to Apple's [Open Anyway instructions](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac); Finder right-click Open MUST NOT be presented as the primary path.

Those documents MUST warn that the app is unsigned and not notarized, that running unverified software has risk, and that organizational MDM/security policy can block installation. They MUST NOT instruct users to remove the quarantine attribute with `xattr`, weaken Gatekeeper globally, or grant Full Disk Access. The app requests Bluetooth permission when required, and source access may present `sourcePermissionDenied`; neither is a Full Disk Access promise.

Uninstall means moving `UsageInk.app` from `/Applications` to Trash. Removing the app does not necessarily remove Application Support data. The documents MUST define **Reset UsageInk Data** as the confirmed in-app action that clears the two ADR 0002 stores and preferences, never alters `~/.codex` or device FDS, and does not issue `0x99`.

## Known-limitations disclosure

The English and Chinese README, first-run disclosure, About screen, and release notes MUST present equivalent known limitations. They MUST state that the EPD protocol has no application-level ACK, sequence number, CRC, or pixel confirmation; a **Refresh** is best effort and physical inspection is separate. They MUST also disclose:

- the Codex app-server protocol, its schema, and quota buckets are experimental; unsupported/missing buckets degrade honestly;
- Local Activity is derived only from Codex activity observed on the current Mac; TPS is selected-window output tokens per elapsed second, and Cache hit rate is the local-Today token-weighted `sum(cachedInput) / sum(input)` when coverage is complete;
- battery operation has no longevity promise and external power is recommended;
- GitHub assets are unsigned and not notarized; backup exclusion is not a guarantee; and
- V1 has no automatic update, support bundle, telemetry, export, or upload, and all unverified hardware is unsupported.

## Release evidence manifest

Each published final version MUST have a versioned manifest at `docs/release-evidence/<version>.md`, linked from the GitHub Release notes. It MUST contain only the following bounded evidence fields:

| Area | Required manifest content |
| --- | --- |
| Source/build | Annotated RC tag and final annotated tag; one identical commit SHA for both; `dirty=false`; path-independent/redacted build recipe invocation that contains no local path; deployment target; toolchain, Xcode, Swift, and build-macOS versions. |
| Assets | Exact asset names, byte sizes, SHA-256 values, and lipo slices. |
| Signing assessment | Observed `codesign` and `spctl` command/status output summarized as status; explicitly state no Developer ID signing and no notarization. |
| Automation | CI run URLs, result, fixture version, and test counts by suite. |
| Physical and compatibility | Date; operator role (not identity); architecture/OS rows; real-Codex valid pass/fail plus exact Codex version and runtime probe/schema outcome; exact hardware tuple/firmware byte/board/panel/MTU/mode and post-`INIT` `rle=1` advertisement state; measured timeout comparison to ADR 0001; and manual synthetic-chart inspection pass/fail. It MAY include only the SHA-256 of a privacy-reviewed synthetic-chart photo held in a non-published evidence area; it MUST NOT publish, link, or attach that photo. |
| Installation/release | Gatekeeper-path results, pre-publish checksum verification result, bilingual-doc result, known limitations, and the stable release-workflow run URL/job that is authoritative for post-publish GitHub verification. |
| Privacy | Privacy scan pass/fail only. |

The manifest is generated from evidence for the exact RC tag/commit. It MUST NOT be required to exist in the tagged commit or retarget that tag. After the RC passes, it records the same-commit final tag and identical asset checksums. It MAY be attached after the tags as a draft-release evidence asset and committed separately at `docs/release-evidence/<version>.md` on the default branch. Its stable release-workflow URL/job records the final post-publish verification result; the immutable release asset MUST NOT be rewritten to pretend that result was known before publication.

The manifest and release notes MUST NOT contain an account identity, local path, machine name, raw BLE payload, raw app-server payload/error, log body, real displayed value, real screen data, source locator, secret, operator identity, or a photo. A URL may identify a CI run, GitHub Release, or official documentation but MUST NOT bypass these exclusions.

## Release blockers and workflow

Release Ready is closed: every mandatory test, physical-script step, inspection, compatibility row, disclosure, installation result, and evidence field above MUST pass or be explicitly recorded as unsupported only where this ADR permits it. The following failures are non-waivable blockers:

- any required CI failure or privacy leak;
- wrong plane polarity, byte count, order, MSB bit order, or required golden stream;
- an unconfirmed `wakeup_pin` write;
- any `0x92`, `0x99`, device wipe, or mutation of `~/.codex`;
- failure of any required physical-script step, manual pixel inspection, required sleep/recovery scenario, or timeout default comparison;
- missing successful real Codex smoke/capability evidence;
- missing two-architecture/macOS 14 matrix or required current-macOS smoke;
- missing bilingual disclosure/installation material or a failed official unsigned first-open → Privacy & Security **Open Anyway** path;
- missing universal asset or checksum; and
- a failed raw transfer, or a failed RLE transfer when the exact tuple advertised `rle=1`.

The release owner MUST: (1) create annotated `0.1.0-rc.N` from a clean commit; (2) build assets once from that tag; (3) run all gates and gather fresh RC evidence; (4) only on a pass, create annotated `0.1.0` at the identical commit and retain the exact same checksummed assets; (5) create the manifest recording both tags and their shared SHA, attach the app ZIP, `SHA256SUMS`, and manifest to the draft GitHub Release, then commit the same manifest separately on the default branch; (6) verify every uploaded non-source asset against its checksum and, when the repository supports it, enable/use GitHub immutable releases; (7) publish and link the manifest in release notes; and (8) run `gh release verify 0.1.0` plus `gh release verify-asset 0.1.0 <local-asset>` for every uploaded non-source asset in the stable release-workflow job. `gh release verify-asset` MUST NOT be used for GitHub-generated source ZIP/tarball assets. That job carries the final post-publish results. A command failure triggers immediate withdrawal; the owner MUST NOT rewrite an immutable asset to claim an anticipated result. The build MUST record `dirty=false` before asset production. A failed candidate MUST NOT lend its assets or evidence to a later candidate; increment `N` and repeat the full process.

## Rollback, yank, and capability response

A privacy leak, unconfirmed device-configuration write, `0x92`/`0x99`, device wipe, or `~/.codex` mutation requires an immediate yank: stop recommending/linking it as the current version, publish a prominent public advisory, and publish a fixed version. The advisory MUST acknowledge that downloads cannot be recovered. The default withdrawal path is to mark the version withdrawn in the repository README and release index and ensure current-version links do not point to it; deletion is not required. If the platform permits deleting an immutable release, the owner MAY also delete that release and its tag, but MUST NOT reuse the same tag or release name. UsageInk MUST NOT claim removal when immutable assets/tag remain inspectable. Immutable evidence is not a reason to continue distribution.

Functional regressions may remain published with a known-limitation disclosure or receive a patch according to severity, but may not be mislabeled as verified.

After a Codex update, a capability failure MUST degrade safely and prompt a patch. It blocks publication when the current RC smoke/probe fails. It does not create an upper-version guarantee for any released build.

## Acceptance scenarios

1. A clean synthetic CI run proves all automation categories, including a fake app-server null/multi-bucket/schema failure, every state-machine retry boundary, 15,000-byte black/red golden planes, pure-function RLE/chunk tests, and no network/real-account access.
2. Goldens prove row-major MSB-left output and plane polarity: all-white `FF`/`FF`, all-black `00`/`FF`, and all-red `FF`/`00`. A wrong polarity, 14,999/15,001-byte plane, red-before-black order, malformed RLE/chunk sequence, or fingerprint altered only by elapsed time fails the applicable test.
3. The exact physical tuple completes a raw two-color full-refresh synthetic chart and manual pixel pass. When post-`INIT` config advertises `rle=1`, it also completes RLE or blocks the RC; otherwise the manifest records RLE unsupported. V1 sends neither `0x06` nor `0x92`, recovers after external device sleep/advertisement timeout, and never claims deep-sleep capability.
4. Bluetooth denial/re-enable, Local Activity `sourcePermissionDenied`, first run, black/red/`0x05` disconnects, sleep/wake, same-session retry versus reconnect, wakeup-pin confirmation/no-write trace, and reset/unbind all produce the specified safe state transitions with no forbidden writes. Any physical-script step or manual inspection failure blocks the RC.
5. A test build below Codex `0.147.0` or with a failed probe shows honest degradation. Separately, a volunteer operator's real signed-in Codex smoke produces a structurally valid Usage Snapshot through all three required RPCs; the manifest contains only version, probe/schema outcome, and pass/fail. Synthetic `authRequired` does not replace this smoke.
6. All bundled code has `arm64` and `x86_64` lipo slices. Real-Mac rows cover latest-stable arm64, latest Apple-supported Intel `>= 14`, and a latest 14.x row (which may overlap); each covers install/launch/menu/synthetic parser. BLE bind/Refresh runs on at least one Physical-device row. An unrun cell is unverified, and no hardware or future-Codex claim is inferred.
7. Both language documents use checksum → `/Applications` → first normal open → Privacy & Security **Open Anyway** as the unsigned path, explain the risks/MDM limitation, and contain no `xattr` or Full Disk Access instruction. Failure of this official path blocks the RC.
8. `0.1.0-rc.N` is annotated from a clean commit. Only a passing candidate creates annotated `0.1.0` at the same SHA with exactly identical checksummed assets; the manifest records both tags/shared SHA. A failed candidate increments `N` and contributes neither assets nor evidence to the next candidate.
9. The manifest is generated after the tags without retargeting either, is attached to the draft release and separately committed on the default branch, contains only bounded evidence and the stable release-workflow URL/job, and passes a privacy scan with no account, path, payload, log, photo, or real-screen data. Its optional photo hash identifies only a privacy-reviewed synthetic image held outside published evidence.
10. Post-publish, the release-workflow job passes `gh release verify 0.1.0` and `gh release verify-asset 0.1.0 <local-asset>` for every uploaded non-source asset, never GitHub-generated source ZIP/tarball. A command failure triggers immediate withdrawal and cannot be backfilled into immutable assets as a pre-publish result.
11. A release with any listed blocker is not published. A later functional regression is classified as patch/known limitation; a privacy/device-write/forbidden-opcode/Codex-home incident is immediately withdrawn with an advisory and fixed release. If immutable GitHub assets remain, README/release-index withdrawal status and current-link removal replace a false deletion claim; a deleted immutable release/tag is never reused.

## Official evidence URLs

- Apple Support: [Open a Mac app from an unknown developer](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac) and [Safely open apps on your Mac](https://support.apple.com/en-us/102445) establish the first-open then Privacy & Security **Open Anyway** flow and its security implications.
- Apple Developer: [Building a universal macOS binary](https://developer.apple.com/documentation/Apple-Silicon/building-a-universal-macos-binary) defines `arm64`/`x86_64` universal binaries.
- Apple Developer: [Code Signing Tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html) documents `codesign`/`spctl` assessment and its policy limitations.
- GitHub Docs: [Verifying the integrity of a release](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/verify-release-integrity) and [Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases) define GitHub asset and immutable-release verification.

## Evidence

- `docs/adr/0001-refresh-and-recovery-state-model.md`: canonical Refresh, recovery, virtual-time, retry, Panel Trust, and timeout requirements.
- `docs/adr/0002-local-persistence-and-privacy-boundaries.md`: local stores, privacy scan boundary, no rendered temporary files, destructive-action, migration, corruption, and disclosure requirements.
- Issue #1: V1 destination, target hardware, macOS 14+, Universal Binary, unsigned GitHub Release, and bilingual-document constraints.
