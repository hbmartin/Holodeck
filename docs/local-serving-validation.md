# Local serving validation — 2026-10-13

The native Mac loader and LAN transport replace the production GitHub downloader. Shader and preview requests use `CatalogSource`; shipping Swift sources contain no URLSession downloader or public URLs. Bonjour resolution forces multicast DNS-SD, numeric destinations must be private or link-local on the discovered interface, and certificate verification disables network fetching.

## Original local-serving checks

- Shared core: 106 tests executed, two opt-in performance tests skipped, zero failures. This run enabled real LAN Bonjour testing and supplied the local authoring repository.
- All 23 indexed authoring scenes loaded, assembled, compiled, rendered, and animated natively. Supplied preview bytes and SHA-256 hashes were checked. No authoring scripts ran.
- Directory tests cover assembly order, material helpers, collections, discovery metadata, attribution comments, canonical revisions, manual publication, bad-file rollback, persisted copied snapshots, path allowlists, and concurrent reload/download leases.
- Real TLS tests cover connection-derived matching codes, approval, rejection, credential persistence, revocation, and changed keys. Protocol tests cover bounds, malformed messages, interrupted transfers, cancellation, and serialized binary exchanges. Public-address rejection, multicast-only resolver flags, and disabled certificate fetching are asserted.
- Physical Apple TV: 37 unit tests and three UI regressions passed, including first-launch retry, offline error handling, and unchanged playback/focus during an updated catalog.
- Mac UI: four relevant tests passed, covering folder selection, manual reload, invalid-preview rollback, bookmark restoration after relaunch, cached-update retry, renderer error recovery, and collection filters without interrupting playback. Tests used isolated bundle IDs to avoid migrating the existing development app's sandbox container while changing its signing identity.
- Both app targets built successfully. Mac development signing uses a stable Apple Development identity so Keychain items remain accessible across builds. Swift Certificates is restricted to macOS.
- The final signed Mac app restored its configured authoring folder and playback, and reported **Serving shaders on the local network**. Its production identity and approvals use a stable namespace separate from development prototypes and isolated tests.

## Reliability and viewer recovery fix pass

Comments #1–#13 are implemented on the local-serving branch. Protocol v1, the 16-session limit, approval-code comparison, atomic publication, cached playback, and 40-/64-character revisions remain supported. Sleep/wake consolidation (#14) and reload performance work (#15) are deferred.

- Shared core on Mac: 133 tests executed, four opt-in authoring/performance tests skipped, zero failures. `HOLODECK_LAN_TEST=1` enabled the real Bonjour/TLS discovery, pairing, saved-credential reconnect, and asset exchange test.
- Shared core on tvOS 27 simulator: 119 tests executed, three opt-in tests skipped, zero failures. Mac-only server and directory tests are excluded on tvOS.
- TV app on simulator: all 41 unit tests passed. The full 20-test UI run passed with its physical-LAN opt-in skipped; the added Control Center pairing regression also passed separately. The final two Control Center checks cover pairing continuity and browsing focus.
- Physical Apple TV **Arrowhead**, tvOS 26.6: all 41 unit tests passed. Control Center was opened and dismissed during pending pairing; the same code remained afterward. The browsing-focus Control Center check also passed. Pairing continuity uses a controlled transport whose code changes whenever a channel is recreated, with actual tvOS lifecycle transitions. Existing production LAN coverage above is from the original local-serving pass.
- Mac UI: 19 distinct tests passed across the full run and focused reruns, including both new regressions for startup selection errors deferred during reload and renderer errors without a folder. Two existing window-preference tests could not read the isolated app's sandbox preference file (Cocoa error 257 / `EPERM`). Native full-screen and Escape checks were skipped under their existing opt-in requirements. The Mac suite is therefore not reported as fully passing.

Resolver tests repeat duplicate-result and completion/cancellation races 20 times and assert one address lookup with exact handle disposal. Client tests control browser generations and callback order, discovery gaps, pairing, chooser grace/cancellation/return, legacy credential decoding, persistent revocation, explicit pin repair, reconnect backoff, and canceled lifecycle transitions. Independent setup-waiter cancellation repeats 20 times. Unknown legacy and unavailable current revisions fail only their request; the next head request succeeds with the same connected generation.

Server tests use real TLS sockets and an injected clock to reclaim all 16 unauthenticated slots after five minutes despite repeated `hello`, expire approval without polling, and retain healthy approved idle sessions. Close, revoke, and shutdown release publications across reloads. A gated read completes after closure to verify that finalization drains it before releasing its lease, preventing an orphaned lease from appearing afterward. Preview tests verify immediate connection-driven retries, independent cancellation, ordinary cooldown, and existing permanent image-validation suppression. Forced-refresh tests publish a newer revision during a held pass, coalesce overlapping force requests, drain work after failure, and cancel the viewer without canceling service-owned work.

App checks use `HOLODECK_TEST_BUNDLE_SUFFIX=.RecoveryTests`; production builds omit it. This isolates app and test targets without changing embedded dependency identifiers. Mac native-app and preferences helpers derive the app identifier from the test bundle. Core commands do not need the suffix.

```sh
HOLODECK_LAN_TEST=1 swift test --package-path HolodeckCore
xcodebuild -project Holodeck.xcodeproj -scheme HolodeckMac \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  HOLODECK_TEST_BUNDLE_SUFFIX=.RecoveryTests test
xcodebuild -project Holodeck.xcodeproj -scheme Holodeck \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' \
  -parallel-testing-enabled NO HOLODECK_TEST_BUNDLE_SUFFIX=.RecoveryTests test
```

Physical Mac Keychain identity-reset/chooser recovery and silent power-loss/keepalive cleanup were not performed in this pass. Controlled identity/pin recovery, the keepalive settings (30 seconds idle, 10 seconds between probes, three probes), deadline cleanup, and lease release have automated coverage; hardware power-loss detection remains a manual check. No deployment or publishing was performed.

## PR #14 publication, focus, and test reliability fixes

Reload now verifies existing publication manifests and every copied source/preview before reuse. A damaged copy is replaced by a same-volume atomic swap under the catalog actor. Swap failures preserve the existing directory; marker failures preserve the previous current revision and allowlist. Regression cases cover corrupt, missing, oversized, and mismatched-manifest assets, intact reuse, failed swaps and marker writes, staging cleanup, and leases retained across further reloads.

The empty local TV picker recognizes its controls as valid restored focus and remembers the last focused local control when UIKit clears focus during Control Center. The new UI regression uses controlled pairing with an empty catalog, focuses **Check for Scene Updates**, and verifies both that focus and the pairing code after returning. It performs no real discovery or credential access.

Mac preference tests use a DEBUG-only inspection launch to expose saved viewer-frame keys from the app's own persistent defaults domain. Inspection constructs no viewer/library/renderer model, disables frame autosaving, and reports only versioned frame data through accessibility. The runner rejects malformed snapshots and mismatched bundle IDs instead of opening the app's sandbox plist. The two previously blocked persistence tests now pass, including geometry restoration, implicit non-persistence, cleanup, and preservation of the live frame. The canceled-refresh waiter test now waits for removal before admitting its replacement waiter.

- Mac shared core: 139 tests executed, five opt-in checks skipped, zero failures.
- Shared core on tvOS 27 simulator: 119 tests executed, three opt-in checks skipped, zero failures.
- TV app on tvOS 27 simulator: all 42 unit tests passed; the complete 22-case UI suite passed with its physical-LAN opt-in skipped. All three Control Center checks passed in that full run.
- Complete Mac UI suite: 24 tests executed, two skipped, zero failures. Native full-screen and renderer-alert Escape checks require permission to post physical input and were skipped under their existing gates; all other 22 tests passed, including both previously blocked persistence tests.
- Focused Mac preferences/inspection checks: four tests passed, zero failures.
- Real Bonjour/TLS pairing and saved-credential reconnect, plus native loading/compilation of the local authoring library: both focused checks passed.
- Shutdown/refresh-waiter synchronization: 500 consecutive repetitions passed using a temporary test wrapper, removed afterward.
- Both app targets built in Debug through their complete test runs and separately in Release. The inspection launch flag and accessibility identifier are present in the Debug Mac executable and absent from Release. Xcode checks ran sequentially against shared DerivedData.

The first new focus-test attempt incorrectly pressed Select after the empty picker had opened automatically, activating **Change Mac**. After correcting that setup, the test exposed UIKit clearing focus during Control Center; retaining the last local control fixed that behavior. The final focused regression and complete TV run both passed. No physical-device installation, minimum-OS runtime check, merge, or deployment was performed in this pass.

Server admission was explicitly excluded from this fix pass. The shared 16-session pool and timeout policy are unchanged. Unapproved peers that continue sending accepted requests can occupy all slots until the absolute five-minute deadline, preventing an approved TV from reconnecting; completely idle initial reads time out after 30 seconds. This availability finding remains unresolved. No protocol, credential, revision-format, or storage migration changes are included.

## Catalog error classification and request bounds — 2026-10-13

An unpublished directory catalog now reports `CatalogError.invalidResponse` for a head request. Viewer error wording remains platform-specific. Client payload-size validation runs after a complete exchange, so exceeding an individual request's limit fails that request without canceling its connection or changing the connected state or generation. Exchange, framing, protocol, and authorization failures retain the existing teardown and connection identity check; an oversized frame rejected before its payload is consumed still disconnects.

Three new regressions cover the unpublished head, a complete head response exceeding its request limit followed by a successful request on the same connection, and an injected oversized exchange failure that cancels the connection and publishes disconnection. Before the implementation changes, the first two tests failed as expected and the exchange teardown test passed.

- Focused directory, client recovery, protocol, and viewer-session suites: 71 tests executed, two opt-in checks skipped, zero failures.
- Complete Mac shared core: 142 tests executed, five opt-in checks skipped, zero failures. The skipped checks require real LAN access, a supplied authoring library, or release profiling.
- Debug tvOS 27 simulator app build: succeeded with `HOLODECK_TEST_BUNDLE_SUFFIX=.RecoveryTests`; the built app identifier is `me.haroldmartin.Holodeck.RecoveryTests`.

```sh
swift test --package-path HolodeckCore \
  --filter 'DirectoryCatalogTests|LocalClientRecoveryTests|CatalogNetworkTests|ViewerSessionTests'
swift test --package-path HolodeckCore
xcodebuild -project Holodeck.xcodeproj -scheme Holodeck \
  -destination 'platform=tvOS Simulator,id=73CAAA2D-7B80-420F-B33F-EF4B8F036AAE' \
  -derivedDataPath DerivedData/TVLocalServing -disableAutomaticPackageResolution \
  HOLODECK_TEST_BUNDLE_SUFFIX=.RecoveryTests build
```

Server admission and deadlines remain unchanged; the availability limitation above remains deferred. This pass ran no app UI tests, physical-device installations, or opt-in LAN/authoring/profiling checks. No protocol, credential, or storage migration changes are included.

## Original physical LAN check

An Apple TV 4K running tvOS 26.6 discovered the Mac's advertised service, resolved it locally, completed TLS pairing, showed the same six-digit code as the Mac settings view, and downloaded the real 23-scene authoring library after clicking **Approve**. The default scene played successfully. Relaunch restored cached playback and reauthenticated to the remembered Mac without another approval.

A second physical run stopped the Mac server after the remembered-host reconnect. The TV reported disconnection, then relaunched and played the cached default scene with the server unavailable. Both physical LAN UI runs passed.

The opt-in physical test uses real production transport and runtime Metal compilation, with isolated test Keychain credentials and disk storage. On this TV, its system profile picker had to be dismissed before Holodeck could become active. Discovery now starts from the foreground lifecycle; with no usable cache, the TV opens the picker to make connection and approval states visible.

## Remaining device checks

The router-level WAN-blocked test was skipped at the user's request. Physical permission denial/recovery, Mac sleep/wake, and minimum macOS 15 runtime checks remain manual release checks. Automated privacy/error mapping, revocation, TLS pinning, and offline-cache tests do not substitute for testing those OS and router behaviors.

Run instructions and test opt-ins are in [the local shader library workflow](shader-catalog-workflow.md).

## Publication integrity, responsiveness, and viewer recovery — 2026-10-13

This follow-up starts from `f41d8b0`, after generated-preview work merged. Local 64-character publication revisions now bind normalized manifest metadata as well as asset hashes. Directory restoration rejects altered metadata and mismatched manifest revisions. Directory and local-client sources also identify local publications internally, so poisoned viewer snapshots are not activated and the repaired snapshot can be downloaded again under the same revision. Healthy offline snapshots and legacy 40-character commit revisions remain supported. Invalid local snapshots require a reachable Mac to recover; their existing files are replaced on successful refresh, without a storage-format migration.

Reload preparation, staging writes, hashing, and existing-publication verification run on one serial I/O queue. Candidate revisions are retained while verification suspends the catalog actor; current head and asset requests continue during that work. Installation, marker writes, allowlists, and leases advance on the actor without suspension. Startup and subsequent maintenance reclaim only abandoned `stage-<UUID>` directories, exclude active stages, and retry logged deletion failures. Resolved filesystem paths identify stages so `/var` and `/private/var` aliases cannot cause active work to be removed. Transfer bounds are shared, and the final encoded manifest is checked against the 2 MiB limit before installation. The regression includes normalization expanding a valid 500-scene input beyond that bound, plus an exact encoded-size boundary.

Enabled local previews retry integrity failures at 30, 60, 120, 240, and then 300-second intervals. Visible TV cards and Mac previews retain their retry loops through same-revision/same-hash repairs. Descriptor validation, hashing, cancellation, and permanent suppression for other sources remain covered. Empty local TV pickers freeze the remembered control across inactivity and ignore incidental restoration callbacks until that control regains focus. Refresh waiters leave the actor registry before their caller completes; cancellation/completion races run 100 iterations while shared downloads continue.

The DEBUG preferences interface supports refresh without relaunching. Its schema-2 snapshot includes actual model/library construction and server-start-attempt counters. The runner validates those fields, asserts zero lifecycle activity during inspection and refresh, and polls expected persisted frame transitions for up to 10 seconds at 250-millisecond intervals. Malformed snapshots fail immediately. The inspection flag, refresh identifier, and lifecycle type name are absent from the Release Mac executable.

Checks executed:

- Focused directory, local publication integrity, cancellation, preview recovery, client recovery, protocol, viewer-session, and generated-preview tests: 104 executed, two opt-in skips, zero failures.
- Complete Mac core suite: 163 executed, six opt-in skips, zero failures. Skips cover release profiling, real Bonjour/LAN access, and supplied authoring/rendering checks.
- Complete tvOS 27 simulator core suite: 130 executed, three opt-in skips, zero failures. With the added executable product, the package test scheme is `HolodeckCore-Package`; the library-only `HolodeckCore` scheme has no test bundles.
- TV app unit suite: 43 tests, zero failures, including visible-card repair and forced wrong-control restoration.
- Complete TV UI suite: 22 executed, one physical-LAN opt-in skipped, zero failures. All Control Center regressions passed, including Select after returning to the empty picker.
- Focused Mac preferences/inspection suite: five tests, zero failures, covering persistence, cleanup, lifecycle counters, schema validation, and deterministic delayed-visibility/timeout polling.
- Complete Mac UI run: 26 executed, two physical-input opt-in skips, five failures. Logs included native window interruptions and an event-synthesis timeout. The five failing folder-selection, alert, reopening, and held-reload cases all passed in a subsequent isolated six-test run, which also reran the preferences polling test. All 24 non-skipped Mac UI cases passed across these runs; the original complete run is not reported as passing.
- Both app targets built in Debug through their test runs and in Release. App checks used `HOLODECK_TEST_BUNDLE_SUFFIX=.RecoveryTests`; built Debug app identifiers were verified as `me.haroldmartin.Holodeck.RecoveryTests` and `me.haroldmartin.HolodeckMac.RecoveryTests`.
- `git diff --check` passed. Server admission/deadline, transport framing, and package/public product API changes were excluded.

The optimized profile uses the same 256-scene fixture with 1 MiB generated preview bytes and three warm unchanged reloads. The baseline ran before production edits, with the profile fixture added to `f41d8b0`. Baseline reload durations were 803/836/972 ms; head-request p50/p95/max during reload were 0.052/196.039/222.825 ms. The final profile recorded 938/998/1005 ms and 0.044/0.094/0.816 ms respectively. This demonstrates serving responsiveness, not an overall reload-speed improvement: median reload duration increased from 836 to 998 ms in these samples. The final run included Mac UI activity, so these single-machine timings are not a throughput acceptance threshold.

Reproduction commands used for the final checks:

```sh
swift test --package-path HolodeckCore \
  --filter 'DirectoryCatalogTests|LocalPublicationIntegrityTests|CatalogCancellationTests|PreviewRecoveryTests|LocalClientRecoveryTests|CatalogNetworkTests|ViewerSessionTests|ShaderPreviewTests'
swift test --package-path HolodeckCore
HOLODECK_PROFILE=1 swift test --package-path HolodeckCore -c release \
  --filter DirectoryReloadPerformanceTests
# Run from HolodeckCore:
xcodebuild -scheme HolodeckCore-Package \
  -destination 'platform=tvOS Simulator,id=73CAAA2D-7B80-420F-B33F-EF4B8F036AAE' \
  -derivedDataPath ../DerivedData/TVCoreRecovery -disableAutomaticPackageResolution \
  -parallel-testing-enabled NO test
# Run app commands from the repository root:
xcodebuild -project Holodeck.xcodeproj -scheme HolodeckMac \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/MacLocalServing \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO \
  HOLODECK_TEST_BUNDLE_SUFFIX=.RecoveryTests test
xcodebuild -project Holodeck.xcodeproj -scheme Holodeck \
  -destination 'platform=tvOS Simulator,id=73CAAA2D-7B80-420F-B33F-EF4B8F036AAE' \
  -derivedDataPath DerivedData/TVLocalServing -disableAutomaticPackageResolution \
  -parallel-testing-enabled NO HOLODECK_TEST_BUNDLE_SUFFIX=.RecoveryTests \
  -only-testing:HolodeckTests test
xcodebuild -project Holodeck.xcodeproj -scheme Holodeck \
  -destination 'platform=tvOS Simulator,id=73CAAA2D-7B80-420F-B33F-EF4B8F036AAE' \
  -derivedDataPath DerivedData/TVLocalServing -disableAutomaticPackageResolution \
  -parallel-testing-enabled NO HOLODECK_TEST_BUNDLE_SUFFIX=.RecoveryTests \
  -only-testing:HolodeckUITests test
xcodebuild -project Holodeck.xcodeproj -scheme HolodeckMac -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/MacReleaseRecovery \
  -disableAutomaticPackageResolution HOLODECK_TEST_BUNDLE_SUFFIX=.RecoveryTests build
xcodebuild -project Holodeck.xcodeproj -scheme Holodeck -configuration Release \
  -destination 'platform=tvOS Simulator,id=73CAAA2D-7B80-420F-B33F-EF4B8F036AAE' \
  -derivedDataPath DerivedData/TVReleaseRecovery -disableAutomaticPackageResolution \
  HOLODECK_TEST_BUNDLE_SUFFIX=.RecoveryTests build
```

Unsupported-volume repair behavior remains unchanged: there is no rename fallback or recovery journal. The 16-session pool and five-minute unauthenticated deadline remain unchanged, with the previously documented availability limitation deferred. No standalone focus cleanup for comment 11, credential migration, physical-device installation, live LAN/authoring validation, merge, or deployment was performed in this pass.

## Shader requests validation

Validated on 2026-10-14 with Xcode 27, macOS 27.0.1, the tvOS 27 simulator and the connected physical Apple TV “Arrowhead.” The implementation adds unsandboxed personal Mac execution, durable request journals, authenticated independent control traffic, staged publication, TV input/clarification/status/activation, and native-resolution 30 fps performance observation.

| Check | Result | Coverage |
| --- | --- | --- |
| Mac and tvOS builds | Passed | Bundled rendering tool, request UI, transport, renderer capture and telemetry compile. |
| Core suite with GPU and authoring opt-ins | Passed, 179 cases (5 opt-in skips) | Existing catalog/network/session behavior, new request validation/ownership/idempotency/scheduling/recovery and source-bound capture contracts; all 23 current authoring scenes compile/render natively. |
| Disposable Git worker tests | Passed, 18 cases | Edits, creation, named/unlisted targets, approximations, no-op, clarification/resume, technical/visual repair, helper coverage, data-only attribution, scope rejection, dirty-checkout preservation, push races, post-push recovery, deleted context, stale performance evidence, exact CRLF source hashes, and creation identity across activation repairs. |
| Real Codex/image/schema smoke | Passed | Official CLI 0.162.1, authenticated ChatGPT account, explicit `gpt-6.1-sol`, High reasoning, native image input and structured output. |
| Real request execution against a local bare remote | Passed | Request `1E99DC4D-83AF-4DFA-AB63-A90D445557B5` changed Plasma to a warm palette, passed independent technical/GPU and timed image review, committed/pushed `bbdbf8647fc6c0f6334f6c3ef7b2a4fc80a0e7d1`, installed the immutable publication and completed after activation acknowledgement. Evidence was retained under `/tmp/holodeck-live-request-v2`. No production push occurred. |
| Authenticated TLS control integration | Passed | Unapproved requests are rejected; approved submissions retain device ownership and asset framing; revocation cancels queued work. |
| Mac Requests window | Passed | Explicit setup UI, queue detail, queued cancellation, retained record/log access and manual deletion. |
| TV request UI | Passed | Native text entry, captured frame, lock over playback, suggested clarification, no-op completion, and gallery return. |
| Physical Apple TV request smoke | Passed | Native text entry, Metal screenshot capture, lock, frame confirmation and continued playback using an isolated test catalog and deterministic control peer in a separate `.ShaderRequests` test app. The device needed waking; a first Select event was retried after focus settled. |

The physical UI test, real TLS integration and real Codex/Git publication test exercise separate boundaries. A complete paired physical-TV → real-Codex → hosted-push round trip has not been claimed. Shader FPS on physical hardware is evidence for future optimization, not a publication gate. OS sleep/crash paths have checkpoint and recovery tests; forced physical power-loss testing and older supported OS versions remain unverified.

The previously installed Codex launcher lacked its platform binary. Reinstalling its original version exposed a revoked signing certificate; the current official 0.162.1 installation launches and authenticates successfully. The authoring checkout was preserved. Its native tool/preview migration is committed on its feature branch, while its existing main branch retains the previous workflow. Setup deliberately rejects enabling automation until that work is on `origin/main`, the checkout is clean, and an explicit model has been verified.

On tvOS the public Metal drawable interface lacks presentation callbacks/timestamps. The implemented performance counter estimates delivered updates by consuming GPU-completed frames on display ticks, counting at most one update per tick. GPU duration is reported separately. It does not measure the compositor's exact presentation time; this platform limitation is documented in the implementation reference and README.

## Raw-byte publication integrity and recovery — 2026-10-14

Implemented on `codex/apple-tv-shader-requests`, starting from clean `d3b704d`, preserving its request prepare/install/discard APIs and generated previews. Local transport is version 2 without negotiation. Local manifest schema 2 omits `sourceRevision`; the revision is SHA-256 of the exact final encoded bytes, checked against the 2 MiB bound. Consumers verify those bytes before decoding or sanitizing and derive the internal source revision. Local snapshot format 2 stores the original manifest bytes and sources, without a duplicate decoded manifest. Older or invalid local snapshots are deleted; removal failures are logged and never activate rejected data. Both apps must update, and older local caches require an updated reachable Mac to repopulate. Pairing credentials and generated-preview caches remain intact.

Source kind is immutable and required at construction; request wrappers preserve kind and availability. Storage providers now supply removal. Cold restoration is a shared service-owned operation on a serial worker, and directory restoration shares reload verification while retaining inspected revisions and serializing installation. Stage ownership uses UUID names, including after moves through symlink paths. Maintenance scans run once at startup and before each preparation; final cleanup removes only the operation's own stage. Enabled local transfer-integrity failures retain capped backoff, while hash-valid undecodable PNGs are terminal. Active directional navigation overrides pending empty-picker restoration. DEBUG preferences schema 3 carries an acknowledged refresh generation with one ten-second polling budget and stale-generation timeout diagnostics.

Executed validation:

| Check | Result |
| --- | --- |
| Initial focused integrity, worker, directory, preview, cancellation, protocol and client recovery regressions | 81 executed, 2 opt-in skips, zero failures. Later restoration/stage tests are included in the full suite below. |
| Final complete macOS core suite | 187 executed, 11 opt-in skips, zero failures. Includes raw unknown fields, discarded discovery, alternate float spellings, changed bytes, exact size bounds, old-cache deletion, same-revision recovery, healthy offline caches, shared/cancelled cold loads, worker responsiveness, symlink stage keys, scan counts and cancellation cleanup. |
| Complete tvOS simulator core suite | 140 executed, 3 opt-in skips, zero failures; finalized with `TEST SUCCEEDED`. Xcode's post-test diagnostic collector timed out after 600 seconds. Test-only semaphore gates also produced QoS warnings. |
| Final TV app unit suite | 44 tests, zero failures, including user-navigation ownership, remembered focus across another interruption, and visible-card corruption recovery. An earlier run had one startup-check/injected-catalog race; the helper now awaits initial refresh before injection. |
| Focused Mac preferences suite | 5 tests passed initially. The subsequent seven-case rerun passed all six preferences/frame cases with the final strict deadline reader; its folder case still failed before the bookmark fix below. |
| Complete TV UI run | 24 total: 21 passed, 1 physical-LAN opt-in skip, 2 failed. Clarification focus timed out, and the request-input test terminated unexpectedly. Both request cases passed in an isolated two-test rerun. All 23 non-skipped cases passed across runs; the original full run did not pass. All Control Center/pairing regressions passed in the full run. |
| Complete Mac UI run | 27 total: 24 passed, 2 physical-input opt-in skips, 1 failed. The folder case was interrupted after XCTest stalled symbolizing a failed assertion; the app itself was idle. The six preferences/frame cases passed on rerun, and the folder/reload/bookmark/preview-fallback case passed after the resolver fix. All 25 non-skipped cases passed across runs; the original full run did not pass. |
| Debug/Release integration | Both apps built in Debug through tests and in Release. Checks used `HOLODECK_TEST_BUNDLE_SUFFIX=.RecoveryTests`; app identifiers were verified. Inspection flags, refresh control identifier, lifecycle type and inspection text type were absent from the final Release Mac executable. |
| Diff checks | `git diff --check` passed. Server admission/deadlines and generated-preview implementation were unchanged. |

The app matrix exposed three integration problems already present on this branch. Copying a top-level `Resources` directory made the tvOS resource bundle fail signing; a disposable copy signed after renaming that directory. The package now copies the Python worker file directly, and its bundle lookup/availability test follow that layout. Release TV code referenced DEBUG-only `UITestConfiguration`; fixture preferences selection is now DEBUG-gated. Mac library selection saved regular bookmarks but restored them with security-scope options; resolution now matches the stored format. The folder UI assertion is scoped to the viewer so a Settings button cannot satisfy it. No Python worker behavior, request APIs, credentials, publication swap fallback or recovery journal changed.

Optimized profiles used the same 256-scene fixture with approximately 1 MiB previews, three unchanged reloads and three disk restorations. The baseline was captured before production edits. Baseline reloads were 902/1376/914 ms; final reloads were 870/984/932 ms. Head-request p95 during reload was 0.861 → 0.086 ms. Disk-restoration median was 174.855 → 181.597 ms, while concurrent head p95 was 139.846 → 0.090 ms. Viewer cold-load median was 18.339 → 14.155 ms; its concurrent actor-query median was 18.269 → 0.013 ms. These samples demonstrate responsiveness, with a modest directory-restoration duration increase. The final profile overlapped app UI activity and is not a throughput threshold.

Commands executed (repository root unless noted):

```sh
swift test --package-path HolodeckCore --filter 'CatalogWorkerRecoveryTests|LocalPublicationIntegrityTests|DirectoryCatalogTests|PreviewRecoveryTests|LocalClientRecoveryTests|CatalogNetworkTests|CatalogCancellationTests'
swift test --package-path HolodeckCore
HOLODECK_PROFILE=1 swift test --package-path HolodeckCore -c release --filter DirectoryReloadPerformanceTests
# From HolodeckCore:
xcodebuild -scheme HolodeckCore-Package \
  -destination 'platform=tvOS Simulator,id=73CAAA2D-7B80-420F-B33F-EF4B8F036AAE' \
  -derivedDataPath ../DerivedData/TVCoreRecovery -disableAutomaticPackageResolution \
  -parallel-testing-enabled NO test
xcodebuild -project Holodeck.xcodeproj -scheme Holodeck \
  -destination 'platform=tvOS Simulator,id=73CAAA2D-7B80-420F-B33F-EF4B8F036AAE' \
  -derivedDataPath DerivedData/TVLocalServing -disableAutomaticPackageResolution \
  -parallel-testing-enabled NO HOLODECK_TEST_BUNDLE_SUFFIX=.RecoveryTests \
  -only-testing:HolodeckTests test
xcodebuild -project Holodeck.xcodeproj -scheme Holodeck \
  -destination 'platform=tvOS Simulator,id=73CAAA2D-7B80-420F-B33F-EF4B8F036AAE' \
  -derivedDataPath DerivedData/TVLocalServing -disableAutomaticPackageResolution \
  -parallel-testing-enabled NO HOLODECK_TEST_BUNDLE_SUFFIX=.RecoveryTests \
  -only-testing:HolodeckUITests test
xcodebuild -project Holodeck.xcodeproj -scheme HolodeckMac \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/MacLocalServing \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO \
  HOLODECK_TEST_BUNDLE_SUFFIX=.RecoveryTests test
xcodebuild -project Holodeck.xcodeproj -scheme HolodeckMac -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/MacReleaseRecovery \
  -disableAutomaticPackageResolution HOLODECK_TEST_BUNDLE_SUFFIX=.RecoveryTests build
xcodebuild -project Holodeck.xcodeproj -scheme Holodeck -configuration Release \
  -destination 'platform=tvOS Simulator,id=73CAAA2D-7B80-420F-B33F-EF4B8F036AAE' \
  -derivedDataPath DerivedData/TVReleaseRecovery -disableAutomaticPackageResolution \
  HOLODECK_TEST_BUNDLE_SUFFIX=.RecoveryTests build
```

Targeted UI reruns selected the two TV request cases and the seven Mac folder/preferences/frame cases; Mac reruns enabled test timeouts with 120/180-second default/maximum allowances. Logs are retained at `/tmp/holodeck-v2-*`, including baseline/final profiles, full suites, reruns and final builds. Cross-instance coordination remains deferred. No live LAN, physical-device, authoring/GPU opt-in, real Codex/Git execution, credential migration, push, merge or deployment was performed in this pass.

## Shader request publication and recovery fixes

Validated on 2026-10-14 after the PR #18 comment triage. Host Git commands bypass hooks without changing repository configuration, and the complete committed file hashes/modes must match the verified candidate. Repair attempts retain their own commit identity separately from prior publications. Pristine baseline checks distinguish infrastructure failures from unlimited candidate repair. Revocation/operational cleanup is serialized and durable; failed cleanup unlocks TV browsing while blocking Mac readiness. Automatic performance submissions retain their capture guard through acknowledgement. The Gallery instruction grammar is corrected.

| Check | Result |
| --- | --- |
| Immutable PR snapshot Core suite with native GPU and authoring opt-ins | 190 tests, 5 opt-in skips, zero failures; all 23 current scenes compiled/rendered. Pending catalog-size edits/cases were excluded. Log: `/tmp/holodeck-request-fixes-pr-core.log`. |
| Shared-workspace Core suite with native GPU and authoring opt-ins | 197 tests, 5 opt-in skips, zero failures; all 23 current scenes compiled/rendered. Includes the pending catalog-size cases. |
| Disposable Git worker regressions | 29 passed: hook/config preservation, exact new/staged/CRLF bytes, filter mismatch rejection, legacy repair cleanup, lost repair push acknowledgement, newer-main recovery, baseline/host/GPU outages, repeated genuine defects and push races. |
| Deterministic recovery scheduling | Three gated process/cleanup tests repeated ten times: 30 passes. Covers revocation during teardown, pending-cleanup restart and operational cleanup failure. |
| Mac Requests UI | Passed queued cancellation, retained evidence access and record deletion; final Mac app/tool build passed. |
| TV simulator | Both Input/clarification flows passed, and the controlled capture/acknowledgement test passed after more than a full slowdown observation interval. Final TV build passed. |
| Real authenticated Codex and local publication | Passed: request `82D366CC-4D76-41A7-89B3-5AAEC29CD9F5`, implementation and fresh independent timed-image review, technical/GPU/macOS/tvOS validation, exact commit verification, local push, immutable installation and activation acknowledgement. Commit `228f1adc0c826e029d849636afa5e3a46e3cccf8`. |

Actual before/after Plasma images were inspected and the independent source/image-bound verdict passed at 0, 3 and 10 seconds. This live run used a freshly seeded `/tmp/holodeck-request-fixes-live` checkout and local bare origin; no production shader push occurred. Evidence and logs remain there and under `/tmp/holodeck-request-fixes-*`. Physical TV validation remains the earlier isolated smoke test; it was not repeated for these fixes.

The local cache-identity fixture correction is included in this follow-up. The byte-count expectation and renamed `CatalogRequest` fixture remain with the separate pending catalog-size work; that work and the authoring migration were preserved. The paired transport/wire types remain unchanged; the Mac model reads pending cleanup separately from terminal TV status.

## Catalog and request correctness acceptance — 2026-10-14

The `codex/catalog-size-diagnostics` follow-up preserves strict schema-2 identity and unlimited shader-defect retries. It adds bounded descriptor-relative reads, durable marker protection, ignored-file backup/restoration, separate Git tree and workspace verification, execution-scoped interruption, owned cleanup recovery/detachment, selective preview requirements, attributable delivery repair, and display-aware performance evidence. Terminal failures remain terminal while cleanup blocks checkout mutations.

- Python worker suite: 42 tests passed against disposable repositories and command fixtures. Cases include ignored additions/modifications/deletions and backup failures, restart/clarification cleanup, unrelated CRLF and clean/smudge transformations, filter-hidden edits, executable-mode settings, transformed publication inputs, submodules, candidate signals/timeouts, baseline failures, preview coverage and clean-main bootstrap.
- Full Mac core suite: 218 tests executed, 11 opt-in skips, zero failures. Gated lifecycle cases cover interrupted preparation, quick resume, orphan ownership ordering, corrected cleanup paths, detachment, descendants retaining a scheduling slot, stderr draining, and forced shutdown of a descendant holding an output pipe. Filesystem cases cover symlinks, special files, path replacement, growing inputs, exact limits, shared-component UTF-8 diagnostics, and failed/cancelled cold restoration followed by trimming.
- Focused TV simulator tests passed for actual controller delivery classification and capture/acknowledgement submission exclusion. Capture, refresh and control failures do not report shader defects; missing outputs and output activation failures do.
- All three focused Mac UI checks passed: recovery path editing/retry/detachment with retained evidence, folder reload/rollback/bookmark restoration, and queued cancellation/retained records.
- Debug Mac and tvOS simulator app builds passed. `git diff --check` passed.

Commands: `python3 -B tools/test_shader_requests.py`, `swift test --package-path HolodeckCore`, and focused `xcodebuild test` selections for `HolodeckMacUITests` and `HolodeckTests`. Logs for this pass are `/tmp/holodeck-worker-final.log`, `/tmp/holodeck-core-final.log`, `/tmp/holodeck-mac-ui-final.log`, `/tmp/holodeck-tv-tests.log`, and `/tmp/holodeck-{mac,tv}-final-build.log`.

This acceptance pass did not rerun real Codex, authoring/GPU opt-ins, physical-device or live LAN checks. No legacy-cache migration, performance-only refactoring, push, PR, merge or deployment is included.


## PR #21 correctness follow-up acceptance — 2026-10-15

This pass supersedes the ignored-file protection policy in the 2026-10-14 record above. Ignored files are outside host enforcement: no inventory, backup, fingerprint, restoration or cleanup, including legacy checkpoint references. Existing backups remain until request-record deletion. Actual publication inputs must still be present in the verified candidate and committed tree; ignored inputs are rejected before pushing and never force-added.

- Python worker suite: **47 tests passed**, zero skips or failures, against disposable repositories and command fixtures. New coverage includes ignored additions/changes/deletions through clarification, success, failure and restart, nested repositories and special files, ignored host outputs without repair, omitted publication inputs, acknowledged detached-owner setup, dirty/foreign checkout rejection, failed setup retaining ownership, and bootstrap waiting for the checkout lease. The lease regression also passed separately after preventing fixture bytecode generation.
- Full core suite: **229 tests executed, 11 explicit opt-in skips, zero failures**. Focused request regressions cover interrupted owner A ahead of cleanup B, process-group retirement and simulated PID reuse, failed reconciliation/retry and stale completion, durable detachment despite an invalid marker, record deletion/restart and path-alias reuse, startup recovery/cleanup before bootstrap and ordinary work, forced rebuild coalescing, rollback, cancellation, preparation interruption, and setup interruption before exit observation. Cadence checks cover 24/25/30-fps targets, fractional 59.94 Hz, 50/60/120 Hz, positive/negative jitter including the 0.01-Hz boundary, and measurement resets; the final expanded boundary assertions also passed separately.
- Focused Mac UI: **all four tests passed**. These cover cleanup path repair and detachment retaining evidence, reconciliation recovery/retry without pending cleanup, manual reload/rollback/bookmark restoration and warnings surviving a journal update, and queued cancellation/record deletion. Initial runs exposed silently ignored malformed process markers and a fixture-directory mismatch: the UI runner is sandboxed while the app uses ordinary user storage. Malformed markers now expose recovery, and an explicit Debug-only fixture directory lets both processes inspect the same journal/evidence. The four checks were rerun successfully with that setup.
- Focused TV simulator: **both tests passed**: `testDeliveryReportsOnlyOutputDefectsAndRetriesTransientFailures` and `testPerformanceSubmissionGuardSpansCaptureAndDelayedAcknowledgement`.
- Final Debug builds for **both HolodeckMac and Holodeck** passed. `git diff --check` passed. Generated triage reports were removed from tracking under the corrected `reviews_triage/` ignore entry; local copies were retained.

Commands: `python3 -B tools/test_shader_requests.py`; `swift test --package-path HolodeckCore`; focused `swift test --filter` request/cadence runs; `xcodebuild -project Holodeck.xcodeproj -scheme HolodeckMac -destination 'platform=macOS' -parallel-testing-enabled NO -skipPackageUpdates test` with the four named Mac UI selections; the Holodeck scheme with `-destination 'platform=tvOS Simulator,id=73CAAA2D-7B80-420F-B33F-EF4B8F036AAE'` and the two TV selections; and explicit `build` actions for both schemes.

Logs: `/tmp/holodeck-followup-worker.log`, `/tmp/holodeck-followup-core-full.log`, `/tmp/holodeck-followup-cadence-test.log`, `/tmp/holodeck-followup-lease-test.log`, `/tmp/holodeck-followup-mac-tests.log`, `/tmp/holodeck-followup-tv-tests.log`, and `/tmp/holodeck-followup-{mac,tv}-build.log`.

The 11 skipped core checks comprise three profiling tests (`HOLODECK_PROFILE`), one live Bonjour/TLS test (`HOLODECK_LAN_TEST`), two supplied-authoring tests (`HOLODECK_AUTHORING_FIXTURE`), the real Codex publication test (`HOLODECK_REQUEST_FIXTURE_CONFIG`), and four GPU opt-ins (`HOLODECK_GPU_TESTS`). Physical-device testing was not rerun. Strict schema-2 verification, queued-only cancellation, unlimited genuine shader-defect retries, pushed-commit preservation and network compatibility remain covered. Legacy migration, the separate symlink-OID refactor (#9) and performance optimization work (#15) remain deferred. PR #21 had already merged and its branch had been deleted before this pass. The follow-up is committed and pushed on `codex/catalog-size-diagnostics` for [PR #22](https://github.com/hbmartin/Holodeck/pull/22), with a link from #21; no history rewrite, merge or deployment was performed in this pass.


## PR #22 recovery failures and detached-checkout identity — 2026-10-15

Implemented against `main` at `a7e0f9f`, including the merged PR #23 authoring-tool changes. Blocking reconciliation and cleanup failures now settle publication callers with a sequenced, typed local error while retaining a separate session-local retry intent. Successful recovery schedules one publication before ordinary queued work; forced rebuilding, suspension and caller cancellation preserve the intended behavior. An operational automatic-attempt failure remains visible for explicit retry. Disabling requests, detachment and checkout replacement clear the remembered intent.

Detached setup now requires the original canonical repository path and, when recorded, the checkout identity, alongside the existing request/journal proof. Copies and actual moves cannot reuse the acknowledgement; aliases remain supported. Successful verification consumes only matching acknowledgements. Owned-cleanup relocation remains supported. Journal/network formats, strict schema-2 verification and the ignored-file policy are unchanged.

| Check | Result |
| --- | --- |
| Python worker suite | **53 tests passed**, no skips or failures. Includes copied/moved checkouts with identical IDs and owner markers, alias reuse and missing ownership proof. |
| Focused Swift regressions | **44 request tests executed, one opt-in skip, no failures**, followed by a passing native-worker automatic dirty-checkout failure regression. The final full run includes all 45 request tests. Coalesced-waiter and stale-reconciliation races each repeat three times, with deterministic gates and bounded backstops. |
| Full core suite | **239 tests executed, 11 opt-in skips, no failures**. Covers owner/remaining cleanup failure, automatic publication ordering and force semantics, suspension, cancellation, operational failure without loops, explicit retry, disable/detach/replacement, publication rollback, copied-checkout rejection, unrelated acknowledgement retention, restart/record deletion, alias reuse and moved-checkout cleanup. |
| Focused Mac recovery/settings UI | **Seven tests passed**, no skips or failures. Three new cases verify prompt error/spinner completion, automatic preparation retaining the original error through lease contention, visible automatic failure followed by explicit rebuild, and successful recovery preserving an unrelated bookmark diagnostic. Four existing recovery, settings, manual reload/warnings and request-record cases also pass. |
| Existing TV delivery tests | **Both passed**: `testDeliveryReportsOnlyOutputDefectsAndRetriesTransientFailures` and `testPerformanceSubmissionGuardSpansCaptureAndDelayedAcknowledgement`. |
| Final Debug app builds | **HolodeckMac and Holodeck (tvOS Simulator) both passed**. `git diff --check` passed. |

The Mac UI regression exposed selectable native error text retaining its earlier contents after the model received the new failure. Both error views now recreate that text when the diagnostic changes; the failure/explicit-retry case passed again in the final seven-test run. UI fixtures use Xcode's direct Git binary because the sandboxed test runner cannot invoke the `/usr/bin/git` developer-tool shim. Temporary observation traces were removed before final validation.

Commands: `python3 -B tools/test_shader_requests.py`; focused `swift test --package-path HolodeckCore --filter ShaderRequestTests` and native-worker selections; `swift test --package-path HolodeckCore`; `xcodebuild -project Holodeck.xcodeproj -scheme HolodeckMac -destination 'platform=macOS' -parallel-testing-enabled NO -skipPackageUpdates test` with the seven individual Mac UI selections; the Holodeck scheme with `-destination 'platform=tvOS Simulator,id=73CAAA2D-7B80-420F-B33F-EF4B8F036AAE'` and the two named TV selections; and explicit `build` actions for both schemes.

Logs: `/tmp/holodeck-recovery-worker.log`, `/tmp/holodeck-recovery-focused.log`, `/tmp/holodeck-recovery-native-error.log`, `/tmp/holodeck-recovery-core-final.log`, `/tmp/holodeck-recovery-mac-ui-final.log`, `/tmp/holodeck-recovery-tv-tests.log`, and `/tmp/holodeck-recovery-{mac,tv}-final-build.log`.

The 11 skipped core checks are three profiling tests (`HOLODECK_PROFILE`), one live Bonjour/TLS test (`HOLODECK_LAN_TEST`), two supplied-authoring tests (`HOLODECK_AUTHORING_FIXTURE`), one real Codex publication test (`HOLODECK_REQUEST_FIXTURE_CONFIG`), and four GPU opt-ins (`HOLODECK_GPU_TESTS`). Physical-device testing was not rerun. No merge or deployment is included.


## Shader request reliability acceptance — 2026-10-16

Worker teardown now has a five-second graceful deadline and a five-second escalation deadline, independent pipe drains, process birth identities and durable validation descendant evidence. Cleanup quarantines owned type obstructions before restoring tracked files. Publication metadata rejects links and special files; checkout-lock contention fails promptly. A teardown failure retains its journal and prevents checkout reuse.

Recovery uses operation-owned maintenance leases and the exact failed journal/configuration. Canonical original paths and compatible known IDs define one checkout. This supersedes earlier acceptance notes permitting owned-checkout relocation: restore its original location or detach it and select a fresh clean checkout. Verification persists the canonical path, so retargeting a selected alias cannot relocate ownership. Historical detached records without live ownership proof do not disable an enabled checkout. Failed reconciliation refuses new TV submissions while retaining accepted jobs.

Publication uses a dedicated immutable event stream. Failures survive a subsequent preparing state and resolve after successful publication, verification or detachment. Cancel Library Preparation settles manual and automatic callers without cancelling queued requests. Renderer failures are classified before requesting source repair, and 60.02 Hz now selects a 30 fps cadence.

The bundled checker is the published [v1.1.0 artifact](https://github.com/hbmartin/HolodeckShaderCheck/releases/tag/v1.1.0), source commit `0a430fefc522bc462a9369abd7a92d255f534f13`, SHA-256 `191c0f276d724202dc78bfcd5bd042d9e651b6886db57c3901bd8ca3d4bea537`. The downloaded release checksums and lock were verified. Compilation and GPU-only validation each receive 600 seconds; candidate nonzero exits, signals and timeouts repeat the same stage on pristine baseline. Compiler probes occur once per SDK with 30 seconds, and each compilation has 60 seconds. The native wrapper replaces itself with isolated configured Python.

| Check | Result |
| --- | --- |
| Python worker suite | 60 passed. Includes tracked directory/FIFO/symlink-parent quarantine, ignored/external evidence preservation, metadata FIFOs, symlink blob IDs, immediate lock contention, stage budgets, exit-2 baseline classification and actual descendant timeout termination. |
| Full core suite | 253 executed, five explicit opt-in skips, zero failures with `HOLODECK_AUTHORING_FIXTURE` and `HOLODECK_GPU_TESTS=1`. Includes a real native-wrapper timeout and signal test, a valid isolated-checker canary with checkout Python and ignored bytecode, orphan birth-identity verification and unrecorded-descendant evidence retention. |
| Publication/recovery races | Deterministic gates and bounded polling cover detach, overlapping work, active cancellation and stale completion. Failure/preparing/success delivery and active publication cancellation each repeat ten times. |
| Canonical ownership | Three focused final tests passed for setup interruption, detached alias reuse and persistent original-path binding after alias retargeting. |
| Mac recovery/publication UI | Five passed: automatic failure/retry, unrelated bookmark-error preservation, immediate lock contention/rebuild, unmanaged bookmark initialization and deferred startup selection errors. |
| Real Mac authoring/GPU integration | Both supplied-authoring core tests and four native GPU regressions passed. All 23 indexed scenes compiled, rendered and animated. Checker validation passed for 66 assets and seven GPU profiles; the packaged app CLI also passed GPU-only validation. |
| Checker release | 73 local tests passed with real-library and GPU integration. Linux Python 3.9 and 3.15 CI and the tagged release pipeline passed, including library integration and packaged artifact verification. |
| App builds | Mac app packaging and generic tvOS device compilation passed. The required checker resource bundle is asserted during packaging; dependency bundles remain included. |

Commands include `python3 -m unittest discover -s tools -p test_shader_requests.py`; `HOLODECK_AUTHORING_FIXTURE=/absolute/library HOLODECK_GPU_TESTS=1 swift test --package-path HolodeckCore`; focused ownership tests; the five selected `HolodeckMacUITests` through `xcodebuild test`; `xcodebuild build` for HolodeckMac and generic tvOS with signing disabled; checker `tools/run_tests.py --gpu`; and separate actual `library validate ROOT --compile` and `--gpu-only` commands.

Local logs: `/tmp/worker-reliability-final-3.log`, `/tmp/holodeck-full-integration-final.log`, `/tmp/holodeck-canonical-ownership-final.log`, `/tmp/holodeck-mac-ui-tests-final.log`, `/tmp/holodeck-mac-package-verified.log`, `/tmp/holodeck-tv-build.log`, `/tmp/checker-complete-integration.log`, `/tmp/checker-metal-validation.log`, `/tmp/checker-gpu-validation.log` and `/tmp/holodeck-packaged-checker-gpu.log`.

The remaining five core skips are three profiling checks, live LAN/TLS and real Codex publication. Physical-device and tvOS simulator execution were not performed; the installed CoreSimulator runtime is incompatible with this Xcode. Bulk hashing optimization, checksum-to-execution hardening and automatic checkout relocation remain excluded.

## PR #26 recovery and correctness follow-up — 2026-10-17

Implemented from merged PR #26 (`f6ddb4d`). Recovery now persists a versioned sidecar independently of creative records, with the exact journal, optional authoritative checkout and intended continuation. A teardown failure preserves resumable patches and published delivery results. Detachment disables requests and persists pending intent before stopping processes; records and acknowledgements become detached only after termination succeeds. Restart discovers process evidence in detached-record journals. Successful operator recovery resumes eligible work when enabled and awake, or finishes a pending detachment. Unknown checkout targets remain journal-specific repair errors, and damaged optional configuration does not block otherwise safe reconciliation. Legacy ownership inspection is asynchronous, bounded and repeated after failure.

Native and Python supervisors reassess temporary registry gaps at completion, signal verified birth identities once per termination phase and retain unresolved final evidence. Repeated TERM/INT cannot interrupt Python cleanup a second time. Native post-exit waiting blocks between observations within the shared ten-second teardown budget. A syntax-compatible isolated bootstrap rejects unsupported Python before parsing the worker.

Folder loading, accepted configuration and publication share one service lease. Rebuild and Verify await pending selection; rejected selection preserves the prior publication and a failed preference rollback becomes durable recovery. Settings associates catalog failures with their represented diagnostic so approval/revocation errors cannot hide independent catalog alerts. Known Metal pipeline-interface diagnostics become typed source defects; resource and unknown driver failures remain transient. Root aliases remain accepted, interior links remain rejected and an opened reader stays pinned if its alias is retargeted. Checker v1.1.0, validation deadlines, original-path binding and ignored-file isolation are unchanged.

| Check | Result |
| --- | --- |
| Python worker suite | **62 passed**, no skips or failures. Includes repeated TERM/INT during real worker cleanup and natural settlement of an unrecorded descendant. |
| Full shared Swift suite | **269 executed, six explicit opt-in skips, zero failures**, with real authoring and GPU integration enabled. Includes actual Metal source that compiles but fails pipeline linking, positive/negative pipeline classification, exact recovery continuations, two-phase detachment/restart, damaged snapshots, repeated legacy migration and transactional selection/rollback. |
| Concurrency coverage | Resume-after-teardown, temporary registry settlement, selection-lease exclusion, active waiter cancellation and publication state races repeat ten times with gates or bounded backstops. Existing negative coverage retains genuinely unresolved process evidence. |
| Optimized supervision and native CLI tests | **Seven passed** in Release. Idle post-exit supervision measured **28.8 observations/second and 1.3% of one CPU core**, below the 50/second and 20% limits. The six CLI tests resolve the active Debug/Release executable and cover actual native signal/timeout behavior and isolated-checker canaries. |
| Actual native checker | Separate Release CLI `--compile` and `--gpu-only` invocations passed for **66 assets**, with **seven GPU profile checks** in the GPU-only stage. |
| Focused Mac UI | **Seven passed**, no skips or failures. Covers post-startup folder selection followed by Rebuild, independent catalog alerts alongside approval/revocation errors, bookmark/configuration agreement, automatic failure/retry, unrelated bookmark-error preservation, exact-journal recovery and manual reload/rollback/bookmark restoration. |
| Mac Release packaging | **Succeeded** for arm64 and x86_64 with signing disabled. The embedded CLI verified its pinned artifact and reported checker **1.1.0**. |
| tvOS app and test compilation | Generic tvOS device **build-for-testing succeeded** with signing disabled, including the added pipeline-defect/resource delivery cases. Runtime execution was unavailable because the installed CoreSimulator framework is incompatible with Xcode. |

The UI pass exposed an existing memory-pressure callback inheriting MainActor isolation while executing on a global queue. The crash report identified that callback; it is now explicitly `@Sendable`, and the full seven-test selection passed afterward. Rebuild is also available for a selected folder before request verification. Eight final focused core regressions passed, including direct Verify and Retry Recovery diagnostic forwarding.

Commands: `python3 -m unittest discover -s tools -p test_shader_requests.py`; `HOLODECK_AUTHORING_FIXTURE=/absolute/library HOLODECK_GPU_TESTS=1 swift test --package-path HolodeckCore`; `HOLODECK_PROFILE_WORKER=1 swift test -c release --package-path HolodeckCore --filter 'ShaderLibraryToolTests|ShaderRequestTests.testPostExitSupervisorIdleCPUAndPollBudget'`; the seven named Mac UI tests through `xcodebuild -scheme HolodeckMac test`; the Release native CLI with separate `library validate ROOT --compile` and `library validate ROOT --gpu-only` invocations; `xcodebuild -scheme HolodeckMac -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`; and `xcodebuild -scheme Holodeck -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO build-for-testing` (both app commands use `-project Holodeck.xcodeproj -disableAutomaticPackageResolution`).

Logs: `/tmp/holodeck-followup-worker.log`, `/tmp/holodeck-followup-full.log`, `/tmp/holodeck-selection-final.log`, `/tmp/holodeck-python-signals.log`, `/tmp/holodeck-idle-release.log`, `/tmp/holodeck-followup-final-regressions.log`, `/tmp/holodeck-followup-checker-compile.log`, `/tmp/holodeck-followup-checker-gpu.log`, `/tmp/holodeck-followup-ui-verified.log`, `/tmp/holodeck-followup-mac-release.log`, `/tmp/holodeck-followup-tv-build.log` and `/tmp/holodeck-followup-packaged-checker.log`.

The six full-suite skips are three catalog/reload profiling checks, the separately executed optimized worker profile, live LAN/TLS and live Codex publication. Real authoring loading/compilation/rendering and all four native GPU regressions ran. No checker release, physical-device installation, automatic ownership relocation, merge or deployment is included.

## Ownership, bounded templates and coordinated checker adoption — 2026-10-17

This pass starts from Holodeck `4acd63b`, checker `0a430fe` and the library's existing bootstrap-integrity branch `f012575`. The reviewable changes cover exclusive cancel-and-drain detachment and child supervision; selection, publication and correlated diagnostics; checker template correctness/performance; and coordinated release adoption. Template editing remains forbidden to request agents. Root aliases, interface 1, authoring schema 1, legacy recovery journals and retryable migration remain supported. Native verification remains local; both checker and library CI run CPU checks on Linux.

Checker [v1.1.1](https://github.com/hbmartin/HolodeckShaderCheck/releases/tag/v1.1.1) was released from exact source commit `58ed409e023b9b1ccbc08dcedd5b38c1090e14fc`. Downloaded release checksums, the complete zipapp source inventory and its bytes were checked against that clean commit. The released zipapp was copied unchanged into Holodeck, and both consumer locks record SHA-256 `8a8229c76e6e42d91d84fe9744bf53bbcda0c9dc8064ba82a41e2b15bb66ef19`. The installed wheel also validated the library in an isolated environment. Actual worker identity verification succeeded with the Release native executable and the updated library without launching a request or publication.

The checker creates one disposable fixture from declared dependencies using descriptor-based no-follow reads. Template instances reuse validated inventory, provenance and SDK probes. Ignored previews and checkout contents are not recursively copied; binaries and reference originals retain their bytes. Only reserved ID/name placeholders are substituted in defined text inputs, preserving compiler macros. Structural tests cover fixture/probe reuse and bounded copying; CI does not assert elapsed time.

On the same local library, the old bundled checker took 0.02685 s without templates and 0.59631 s with templates. Checker 1.1.1 took 0.06193 s and 0.11964 s respectively, including its now-shared base provenance audit. Added template time fell from 0.56946 s to 0.05771 s, a **89.9% reduction**; total validation time fell **79.9%**. These are local measurements, not portable timing guarantees.

Confirmed checks:

- Full shared Swift suite: **278 executed, six opt-in skips, zero failures**, with real authoring and GPU integration enabled. The skipped worker profile ran separately in Release; live LAN, live Codex and three unrelated catalog profiles were not run.
- Release native resource/launch tests and worker idle profile: **eight passed**. Tests invoke the built executable and packaged resources, reject stale/missing/incompatible installations with specific diagnostics, and bound subprocess lifetime with descendant cleanup. Idle supervision measured 33.5 observations/s and 2.4% of one CPU core.
- Full Python worker suite: **70 passed**, no skips or failures (409.4 s), including late forks, genuine unresolved descendants, closed/idle pipes, repeated termination, transient registry gaps, PID birth checks, 750 retired identities, capacity evidence, large buffered input, observation failure classification, strict checker pairing and long quarantine paths.
- Checker CPU coverage: **80 passed** on Python **3.9** and **3.15**; GPU-enabled checker coverage: **81 passed** locally. Checker release and Linux CI succeeded. The library adoption Linux CPU jobs also passed on both versions.
- The released artifact compiled **66 assets plus shader/snippet templates** for **macOS and tvOS** locally. Its separate native `--gpu-only` run passed **seven profile checks**.
- **Ten distinct Mac UI regressions passed** across focused runs: exact recovery/detach, failed selection followed by rebuild, bookmark initialization, same-folder local rebuilding, cached startup after bookmark rejection, correlated and unrelated diagnostics, automatic publication retry, lock contention and unrelated bookmark-error preservation. Initial attempts exposed outdated alert/disabled-button expectations and one OS permission-dialog interruption; corrected tests and focused reruns passed. The earlier failing combined runs are not reported as passing.
- The final **tvOS Release simulator build succeeded** for arm64 and x86_64. Debug Mac build and generic tvOS device build-for-testing also succeeded; simulator and physical-device execution remain unavailable/not performed as described below.
- The final **Mac Release package built successfully** for arm64 with signing disabled. Its embedded native CLI and bundled resource installation reported the expected checksum-verified artifact identity and checker version **1.1.1**.

Local logs use `/tmp/holodeck-fixes-*`, including `core-final.log`, `worker-verified.log`, `release-profile.log`, `checker-final39.log`, `checker-final315.log`, `checker-final-gpu.log`, `released-compile.log`, `released-gpu.log`, `mac-ui.log`, `mac-ui-final.log`, `mac-ui-resolved.log`, `mac-ui-accepted.log`, `mac-release-build.log` and `tv-release-build.log`.

The installed CoreSimulator framework (1171.7) is older than this Xcode's required build (1174.9.2), so tvOS simulator execution is unavailable. No physical-device runtime checks or live Codex requests ran in this pass. The primary managed installation was not replaced or enabled; deployment still requires draining requests and switching the matching app/tool and library pair before verification and enablement.

## Remaining worker, Detach and app-state races — 2026-10-20

This follow-up starts from main `15a4e77` and keeps checker 1.1.1 and both checker locks unchanged. The three commits cover retained-work/Detach safety, retained session supervision, and app state/diagnostics. Detach reserves and persists intent before draining, checks scheduled cleanup ownership before destructive launch, and rescans canonical journal targets after draining. Quarantine persists each UUID-to-original-path mapping before moving its file.

Captured commands and streaming Codex launches now share a gated, registered session supervisor. It stays alive through descendant settlement and reports actual command status over a separate channel. Verified work receives TERM once and KILL after five seconds, with a ten-second settlement deadline. Unknown identities after anchor loss and unresolved external pipe ownership retain recovery evidence. Registry reads use the same bounded no-follow regular-file reader; failed writes cannot bypass known-process termination. Darwin enumeration uses cached libproc, and both observation paths retry transient enumeration failures three times at 250 ms intervals. Captured and streaming I/O share explicit nonblocking input offsets, including Python 3.9, whose `communicate()` retry implementation otherwise stops writing buffered input. Shared deadlines use the OS monotonic clock because Python 3.9 on macOS assigns `time.monotonic()` a different origin in each process.

Startup proposals and explicit reloads share selection ordering; Verify waits for their accepted configuration. Final worker retirement emits Disable Requests eligibility. Native identity probes each receive 30 seconds, with separate startup, timeout, malformed-response and mismatch errors. Coalesced catalog refreshes retain every explicit correlation ID until task completion; anonymous callers cannot erase them. Alert regressions count actual presentations and use bounded inverted expectations.

Confirmed checks:

- Full Swift core with real authoring/GPU opt-ins: **285 executed, six opt-in skips, zero failures**. All 23 local scenes compiled, rendered and animated. The skipped worker profile ran separately; live LAN, live Codex and three unrelated catalog profiles were not run.
- Release packaged-resource/native-launch tests and supervision profile: **nine passed**. Native idle supervision measured approximately 30 polls/s and 1.6% of one CPU core. The final packaged retained-supervisor profile measured 1.55% for supervisor/command processes and 0.09% for its parent over 15.2 seconds. These local measurements are observations, not CI timing assertions.
- **Full Python worker suite: 83 passed on Python 3.9.6 and 83 passed on Python 3.15.0**, with no skips, failures or errors. Each interpreter ran four disjoint partitions; the resulting unique test names were checked against the complete suite to confirm no omitted or duplicated cases.
- Process regressions cover successful unsampled late helpers, forks during termination, ignored TERM, control closure, supervisor crashes, escaped pipe holders, PID birth checks, malformed/symlink/FIFO evidence, capacity and write failures, 750 retired identities, large buffered input, transient/persistent observations and operational-versus-candidate diagnostics.
- **Five selected Mac UI tests passed**, including startup Verify ordering, rejected bookmarks with cached serving, folder reload/rollback, correlated alert absence and unrelated alert presence. Tests use the isolated `.RecoveryTests` application. Test presentation/selection hooks are excluded from the Release executable.
- **46 tvOS simulator app unit tests passed**. The available tvOS 27 simulator executed successfully in this pass, superseding the earlier unavailable-runtime note. Physical-device and TV UI execution were not performed.
- **Both Release app builds passed**: Mac arm64 and tvOS simulator arm64/x86_64, with signing disabled. The final Mac package's worker bytes match source and its retained supervisor settles a late helper. Its embedded CLI reports the unchanged checksum-verified checker identity and checker version 1.1.1.
- The packaged checker compiled **66 assets plus shader/snippet templates for macOS and tvOS** locally. A separate Mac GPU run passed **seven profile checks**.

Early verification exposed a control-channel completion race, Python 3.9 buffered-input loss, incompatible per-process clock origins and a native-enumeration test stub that lacked the birth-identity API. Those issues were corrected before the final runs. Superseded failed/interrupted runs are not reported as passing.

Commands include `HOLODECK_AUTHORING_FIXTURE=/Volumes/Pro2T/HolodeckShaders HOLODECK_GPU_TESTS=1 swift test --package-path HolodeckCore`; the full Python worker suite under `/usr/bin/python3` and Python 3.15; Release `ShaderLibraryToolTests`, native observation retry and idle-profile selections; the five selected `HolodeckMacUITests`; tvOS `HolodeckTests`; Release builds of both schemes; and packaged native `library artifact-info`, `library info`, `library validate --compile` and `library validate --gpu-only`.

Evidence logs use `/tmp/holodeck-races-*`: `core-clock-final.log`, `worker39-finalpart{0,1,2,3}.log`, `worker315-finalpart{0,1,2,3}.log`, partition `result.json` summaries, `release-clock-final.log`, `ui.log`, `tv-unit.log`, `mac-clock-final.log`, `tv-release.log`, `package-clock-final.log`, `native-compile.log` and `native-gpu.log`.

No live request, physical-device installation, primary app replacement, enabling of requests, checker release, library-lock change, merge or deployment occurred. A later rollout must drain requests before installing the matching native host and bundled worker. Linux checker/library CI remains unchanged.

PR automation: both Socket security checks passed. SonarCloud’s quality gate remains red on five S8707 CLI-path findings in registry persistence/removal. At the reviewed commit, the native host supplies journal arguments from its private Application Support request directory and UUID job IDs (`MacRequestsModel`, `ShaderRequestService.folder`, `RequestWorkerProcess.run`); TV request text and Codex output do not supply these arguments. Temporary names are generated UUIDs and registry basenames are fixed. These findings were triaged as false positives at this trust boundary, with target/HEAD evidence stored by the PR triage workflow. Scanner findings/rules were not dismissed or suppressed; reviewer disposition remains open.

## Per-command supervision settlement follow-up (2026-10-20)

This pass starts from PR #30's merged tree, `22dd0a8`, and retains one supervisor per command. The shared runtime is packaged as `shader_processes.py` beside `shader_requests.py`; isolated worker launches explicitly disable bytecode writes so imports do not add cache files to installed resources. Both files must come from the same app build. Checker bytes and both checker locks remain unchanged.

One settlement engine handles ordinary exit, exceptional exit and Python orphan cleanup. It observes again after signalling/persistence before claiming group quiescence, then retires the owner last. Supervision format 2 adds a session UUID, increasing revisions, a tagged clock, independent process-settlement proof and a pipe-drain acknowledgment. Pending pipe evidence is durable before execution; a failed attempt to record a pipe failure cannot erase that barrier. Older disk status cannot replace newer channel status. Known-only owner crashes can finish cleanup without falsely requiring checkout recovery; a missing command exit status remains an operational failure.

Darwin deadlines use `CLOCK_UPTIME_RAW`, excluding sleep and sharing native `systemUptime`'s domain. Python cross-process tests run under both supported interpreters; a direct Python/Swift probe also placed native uptime between the two Python readings. Simulated sleep and exhausted-budget tests cover the selected clock and inherited deadlines. Untagged version-1 deadlines are not compared against the new clock. Native live and orphan fallback inherit the remaining budget rather than starting another ten seconds.

Native observations and retries run outside ownership locks. Cancellation returns while enumeration is gated, logging continues, retired roots retain uncertainty about unfamiliar descendants, and cached sessions cannot suppress TERM after their owner disappears. Owner retirement requires a fresh quiescent snapshot. Persistent observation failures retain their original diagnostic even if subsequent cleanup succeeds.

Correlation-only updates preserve the presented failure's identity and actions. Repeated automatic checks also preserve an existing unresolved failure; changed explicit owners, dismissal, retry or recovery establish a new occurrence. Alert eligibility reads current correlation metadata. Well-formed unsupported checker versions/interfaces receive compatibility guidance, separately from malformed locks and launch faults.

Validation completed in this pass:

- **99 Python worker tests passed on Python 3.9.6 and 99 on Python 3.15.0**, with no skips, failures or errors. Three disjoint partitions per interpreter were checked against the complete manifest: 99 unique names, no omissions or duplicates. Added coverage includes the post-fsync fork window, channel/disk ordering, pre-launch EOF/stop, lost owners, failed pipe-evidence persistence, directory-sync gating, buffered streaming readiness, control resets, failed supervisor birth establishment and bounded durable writes.
- **Full shared Swift suite: 295 executed, six opt-in skips, zero failures**, with real authoring and GPU integration enabled. Native regressions include paused enumeration, persistent failures followed by successful settlement, stale session maps, inherited live/orphan deadlines, unknown descendants of retired roots, and missing packaged runtime resources. A legacy fixture now waits for observed descendant exit with a bounded backstop instead of assuming a fixed sleep is sufficient.
- **Seven selected Mac UI tests passed**, including both new presented-alert correlation cases, positive unrelated alerts, bounded duplicate-alert absence, startup Verify ordering, rejected bookmarks with cached serving and immediate rebuilding of an accepted folder.
- **46 tvOS 27 simulator app unit tests passed**, with no skips or failures.
- **Fourteen Release resource/native-supervision/profile tests passed**, followed by two packaged launch tests after the final startup guard. The native idle profile measured about **30.4 polls/s and 1.10% of one CPU core**.
- **Both Release app builds passed**, with signing disabled. Both Mac resource-bundle copies of each worker file match source exactly, and the packaged native tool passed artifact-info, checker-info and a read-only selected-library identity comparison. No requests were enabled.
- The unchanged packaged checker compiled **66 assets plus shader/snippet templates for macOS and tvOS**. The separate Mac GPU run passed **seven profile checks**.

Startup measurements use `tools/profile_shader_supervision.py --baseline 22dd0a8 --worker PATH_TO_RELEASE_BUNDLED_WORKER`. Both artifact trees are copied unchanged onto the same temporary filesystem before comparison; recorded hashes match the final packaged files. Each comparison uses the same interpreter, 31 warm short-command samples and five 18-Git-command fixtures. Timings were collected during concurrent validation and are local observations, not CI timing assertions:

| Measurement | Python 3.9.6: PR #30 → follow-up | Python 3.15.0: PR #30 → follow-up |
| --- | --- | --- |
| Short command median | 236.2 → 158.4 ms | 149.5 → 83.4 ms |
| 18-command fixture median | 3397.5 → 2764.5 ms | 2195.3 → 1531.1 ms |
| Atomic evidence replacements per command | 7 → 5 | 7 → 5 |
| Fsync calls per command | 14 → 10 | 14 → 10 |
| Interpreter launches per command | 2 → 2 | 2 → 2 |
| Reaped-child CPU during a 15-second idle command | 1.39 → 1.02% | 0.94 → 0.83% |
| Parent CPU during the same idle command | 0.09 → 0.04% | 0.10 → 0.05% |

The per-command interpreter lifetime is intentionally retained. The optimization removes worker-only imports, replaces startup polling with readiness/SIGCHLD wakeups and batches compatible directory syncs without removing execution or completion barriers.

Evidence uses `/tmp/holodeck-final-*`: `accepted{39,315}-{0,1,2}.log`, matching manifests/status logs, `process-regressions.log`, `core-accepted.log`, `ui-complete.log`, `tv-tests.log`, `tv-test-summary.json`, `gpu.log`, `benchmark{39,315}.json`, `release-audited.log`, `package.log`, `mac-package.log` and `tv-package.log`. Metal compilation is also recorded in `/tmp/holodeck-settlement-metal.log`. The full-core skips cover three unrelated catalog profiles, the separately run worker profile, live LAN/TLS and live Codex publication. Physical Apple TV execution, TV UI tests and live requests were not run. No live app replacement, enabling of requests, checker release, library-lock change, merge or deployment occurred; Linux checker/library CI is unchanged.

## PR #31 ownership and recovery follow-up (2026-10-21)

This follow-up starts from merged main `15aaf29` and keeps one supervisor per command. Its four commits cover independently verified ownership/evidence, worker-first cancellation, boot-aware settlement budgets, and native observation/control diagnostics with regression and benchmark evidence. Checker bytes, checker locks, Linux CI, template-edit restrictions and root-alias support are unchanged.

Missing or malformed registry data cannot erase a command birth identity retained in supervision status or memory. Both Python cleanup and native observation collect independently valid evidence before deciding what can be settled. Unverifiable static metadata and pipe completion use a distinct native evidence error: normal operations remain blocked, while explicit Detach can retain those markers after verified work retires. Live or unfamiliar descendants and failed group observation remain teardown failures. Detach also finishes draining when retirement returns an evidence-only error, preserving exact unpublished bytes in the same operation.

Cancellation first obtains the required fresh worker-group observation, then interrupts the worker without signalling commands underneath it. The worker's interruption handler owns command cleanup; native fallback takes over after the verified worker retires. TERM/KILL tracking, the five-second escalation and ten-second operation ceiling remain intact. Startup and context-manager cleanup preserve interruption identity and report cleanup problems separately, preventing ordinary failure-driven discard.

Supervision format 3 adds attempt UUID, boot identity, clock domain, start time and finite deadline metadata. A live handoff retains its remaining budget; a new recovery attempt gets a fresh bounded budget. Expired handoffs only verify final state and retain unresolved evidence. Formats 1/2 and legacy registries remain readable, but their raw deadlines are not inherited. Persisted deadlines with another/unknown boot or future start are not reused; an already-established local in-memory stop budget remains effective even if boot identity is unavailable.

Native group and birth observations use shared per-pass caches outside the ownership lock. State commits validate operation generation; signalling runs on a separate queue with final birth checks. Known supervisor anchors remain protected independently of stale delegation maps. Functional control channels continue accepting drain acknowledgments after unrelated supervision errors; unusable channels close explicitly. Pipe expiry is classified separately from process settlement even between sampling ticks.

Final validation:

- **111 worker tests passed on Python 3.9.6 and 111 on Python 3.15.0**, with no skips/errors/failures. Three partitions per version were checked against the complete manifest: 111 unique names, no omissions or duplicates. Worker/runtime hashes were unchanged throughout the final runs. The unlimited-repair regression also passed two additional runs on Python 3.9.
- **302 Swift core tests executed, six opt-in skips, zero failures**, with real authoring/GPU integration enabled. The worker profile ran separately in Release; three unrelated catalog profiles, live LAN/TLS and live Codex publication were skipped.
- **15 Release packaged-resource/native-supervision tests passed**, including a late helper, preserved interruptions, lock responsiveness, legacy evidence, budget identity and explicit Detach. Native idle supervision measured **30.2 polls/s and 1.11% of one CPU core**.
- **Four Mac UI recovery/request regressions passed**: queued cancellation, retained-files Detach, reconciliation retry, and publication recovery. **46 tvOS simulator unit tests passed**, with no skips/failures.
- **Both final Release app builds passed**, with signing disabled. Both Mac copies and the tvOS copy of each worker resource match source exactly; neither app contains Python bytecode caches. The packaged native artifact identity matches the selected library lock without enabling requests.
- The packaged checker compiled **66 authoring assets plus shader/snippet templates for macOS and tvOS**. The separate Mac GPU run passed **seven profile checks**.

Benchmark reproduction: `python tools/profile_shader_supervision.py --baseline 15aaf29 --interleave`, using each supported interpreter. Both artifact trees are copied unchanged to the same temporary filesystem. The comparison alternates baseline/current order across 31 short-command samples and five 18-Git-command fixtures; counts and 15-second idle CPU are measured separately. These are local measurements, not CI timing thresholds.

| Measurement | Python 3.9.6: PR #31 → follow-up | Python 3.15.0: PR #31 → follow-up |
| --- | --- | --- |
| Short command median (ms) | 135.0 → 135.3 | 68.4 → 68.0 |
| 18-command fixture median (ms) | 2406.4 → 2425.3 | 1213.7 → 1236.4 |
| Evidence replacements per command | 5 → 5 | 5 → 5 |
| Fsync calls per command | 10 → 10 | 10 → 10 |
| Interpreter launches per command | 2 → 2 | 2 → 2 |
| Idle reaped-child CPU | 1.47 → 1.48% | 1.07 → 1.09% |
| Idle parent CPU | 0.10 → 0.11% | 0.10 → 0.10% |

Development profiling caught an unnecessary 250 ms wait when context cleanup repeated an already-successful settlement. Context exit now forces a fresh observation immediately; a structural regression rejects empty-selector waiting after verified completion. Superseded development runs are not counted above, including an early Python 3.9 run with an unknown command outcome. The final unchanged-source suites and repeated repair checks passed. Exhausted-handoff tests assert the retained evidence and original budget while allowing the error subtype to reflect whether asynchronous retirement has actually been verified.

Evidence uses `/tmp/holodeck-pr31followup-*`: `accepted{39,315}-{0,1,2}` logs/manifests/results, `accepted-summary.json`, `verified-core.log`, `verified-release.log`, `ui.log`, `tv-summary.json`, `verified-{mac,tv}-package.log`, `package-proof.json`, `evidence-summary.json`, `benchmark{39,315}.json`, `metal.log` and `gpu.log`. The worker SHA-256 is `259fc8da7405c80faff82f30a8a2718f5a478df91344f9fa13d1dd2375908c4b`; the process runtime SHA-256 is `9a7a53ad683985f3093cdeb827100cce62d8df494902be9766c523578ed0b1d3`.

Physical Apple TV, TV UI, live LAN/TLS and live Codex publication were not run. No live installation replacement, request enablement, checker release or library-lock update occurred. A later rollout must drain requests before installing the matching host and worker.


## PR #32 follow-up: retained work, bounded retries, and verified launch (2026-10-24)

This follow-up starts at `fbc2dd3`, the merge of PR #32. Supervision faults now preserve unpublished work independently of whether processes settled. Requests, Verify, managed Rebuild, and cleanup share one automatic retry after verified settlement and exact-journal reconciliation. A second supervision fault pauses the operation for manual recovery. Cancellation, unresolved ownership or pipes, invalid evidence, and persistence failures do not trigger an automatic retry.

Worker failure events add optional `failureKind`/`retryable` fields; supervision format 3 also carries an optional retry disposition. Missing fields keep legacy compatibility. Persistence/capacity failures retain their manual-only disposition even when another error was recorded first. The bounded `worker-operation.json` journal records the operation UUID, mode and phase. Its UUID is also retained in the saved worker configuration, so a missing or mismatched retry journal cannot silently replenish the allowance. A pending retry can be resumed after reconciliation; an interrupted running retry requires manual recovery. Explicit manual recovery starts a new operation. The existing recovery format, legacy migration flag, process registry array, and supervision readers remain compatible.

The native Python bootstrap stays gated until the host verifies and durably records its birth identity. Cancelling or failing registration closes the gate before checkout code executes. Worker-root TERM grace uses its actual TERM attempt and is never backdated by a command's older budget. Orphan recovery leaves live commands untouched if their worker root cannot be verified; reuse and Detach remain blocked until ownership is repaired or retirement is verified. Both success and evidence-only retirement now require fresh post-signal observation. Registry and pipe failures retain separate diagnostic causes, and all orphan process operations use the injectable observation/signalling interface.

The supervisor retains partial control frames after unrelated internal errors. The worker's cancellation path preserves cleanup metadata for every BaseException cancellation and attempts command settlement even when supervision metadata cannot be decoded. Failed boot lookups can be retried; successful identities are cached. Idle native signal tasks and the duplicate escalation timer were removed, and failed evidence reads follow the 250 ms observation interval.

Final local validation:

- **117 worker tests passed on Python 3.9.6 and 117 on Python 3.15.0**, with no skips/errors/failures. The three manifests per interpreter contain all 117 unique cases without omissions or duplicates. Runtime hashes stayed unchanged throughout both full runs.
- **319 Swift core tests executed, six opt-in skips, zero failures**, with real authoring/GPU integration enabled. All 23 local scenes compiled, rendered and animated. The worker profile ran separately in Release; three unrelated catalog profiles, live LAN/TLS and live Codex publication were skipped.
- **21 Release packaged-resource/native-supervision tests passed**: seven native resource/launch checks and fourteen ownership, worker-mode retry, retry-journal, retirement and profiling checks. Native idle supervision measured **33.8 polls/s and 0.51% of one CPU core**.
- **Four selected Mac UI tests passed in the final run**. An earlier recovery-path run was interrupted when the Codex window took keyboard focus; explicit activation and a foreground check made the fixture deterministic before final validation. Covered cases include retained-files Detach, queued cancellation, recovery retry, and publication recovery/rebuild.
- **Both final Release app builds passed**, with signing disabled. Both Mac copies and the tvOS copy of each Python resource match source exactly; neither app contains bytecode caches. The packaged native artifact identity matches the selected library lock without enabling requests.
- The packaged checker compiled **66 authoring assets plus shader/snippet templates for macOS and tvOS**. The separate Mac GPU run passed **seven profile checks**.

Regressions cover full-worker patch preservation, corrupt supervision during interruption, all cancellation metadata, split control frames, retry exhaustion and restart/manual recovery, all four worker modes, cancellation/Detach before retry launch, missing/malformed retry metadata, gated startup, older peer deadlines, unidentified live workers, injected orphan identities, fresh final observations, combined evidence diagnostics, failed boot lookups, and idle/evidence-read scheduling. Existing late-helper, escaped-pipe, registry-capacity, PID-reuse and more-than-700-identities cases remain in the full suite.

Benchmark reproduction: `python tools/profile_shader_supervision.py --baseline fbc2dd3 --interleave`, separately under each interpreter. Baseline and current sources run unchanged on the same temporary filesystem, alternating across 31 warm short-command samples and five 18-command fixtures. Writes, fsyncs, launches and 15-second idle CPU are measured separately. These local observations were collected during validation; they are not CI timing thresholds or comparisons with earlier machines/runs.

| Measurement | Python 3.9.6: PR #32 → follow-up | Python 3.15.0: PR #32 → follow-up |
| --- | --- | --- |
| Short command median (ms) | 140.1 → 140.6 | 72.6 → 73.4 |
| 18-command fixture median (ms) | 2584.0 → 2574.0 | 1348.8 → 1348.8 |
| Evidence replacements per command | 5 → 5 | 5 → 5 |
| Fsync calls per command | 10 → 10 | 10 → 10 |
| Interpreter launches per command | 2 → 2 | 2 → 2 |
| Idle reaped-child CPU (%) | 1.006 → 1.046 | 0.649 → 0.667 |
| Idle parent CPU (%) | 0.045 → 0.042 | 0.041 → 0.051 |

Evidence uses `/tmp/holodeck-pr32-*`: `verified-python{39,315}-{0,1,2}` logs/manifests/results, `verified-python-summary.json`, `verified-core.log`, `verified-release.log`, `verified-ui.log`, `verified-mac-build.log`, `verified-tv-build.log`, `verified-package-proof.json`, `verified-benchmark{39,315}.json`, `verified-metal.log`, `verified-gpu.log`, and `verified-native-summary.json`. Development failures are not counted as passing runs: the dangling-link reader and orphan fixtures were corrected before final core validation, and the keyboard-focus UI failure is recorded above.

The worker SHA-256 is `014724c5b06ee79e98a1dfe7b1b26649535238636827725ea025db577ae0654d`; the runtime SHA-256 is `51457dc2ede3168b2c6751040c6edb27fb1f8519b994e267067482d24f2f6ca1`. No checker artifact or library lock changed. Physical Apple TV, TV UI, live LAN/TLS and live Codex publication were not run. The live installation and request settings were not changed; a later rollout must drain requests before installing the matching native host and bundled worker. Linux CI is unchanged.

## PR #33 follow-up: recoverable operations and isolated retry completion (2026-10-24)

The follow-up starts from merge commit `8f2a7a3` (the same tree reviewed in PR #33). Operation-journal format 2 records both configuration-binding states before replacement and replays only the recorded transition. Existing format-1 journals remain readable; unexplained legacy mismatches require explicit recovery after checkout ownership and process settlement are verified. Detach retains binding files and marker evidence in a durable UUID archive. Cleanup configuration corrections remain journaled until request records, preferences, and worker bindings converge.

Checker identity probes retain every supervision-error subtype, and oversized complete or incomplete control frames close their channel without starving process cleanup. Startup interpreter failures report their actual exit or signal and do not consume the supervision retry. Each attempt must supply its own completion event; catalog preparations belong to that attempt, while confirmed commit delivery remains deduplicated across the logical operation. Exact-journal recovery clears only its own reconciliation invalidation. Legacy PID/argv ownership behavior is unchanged.

The new regressions inject interruption at each durable binding boundary, reject unrelated transitions, repair legacy mismatches through the real service action, restore corrected tool paths from both initial and paused operations, and prevent configuration changes when intent persistence fails. They cover independent recovery entries, replaced checkout identities, resumable archives and dangling markers, late cancellation diagnostics, completion isolation in all four modes, interpreter exits at three startup gates, deterministic launch failure, and duplicate committed results.

Final local acceptance used frozen runtime sources; their hashes were checked before/after testing and against both Release apps. Python 3.9.6 and 3.15.0 each passed **119 unique worker tests**, with no skips. Swift core passed **340 tests with six opt-in skips**, including all 23 local scenes. Release passed **140 tests with one opt-in skip**, including seven native packaged-resource tests and the supervision profile. All four targeted Mac UI tests passed together using the isolated `.RecoveryTests` app identity. Both Release apps built successfully with signing disabled.

Core skips were three unrelated catalog performance probes, the worker profile (subsequently run in Release), live LAN/TLS, and live Codex publication. Release skipped only live Codex publication. Physical TV and simulator runtime checks were not run. No live installation, request settings, checker artifact, library lock, or CI configuration changed.

Both bundled copies of each worker file in the Mac app and the tvOS copy matched the source bytes; neither app contained `.pyc` files. Packaged `Worker.require_checker()` accepted the selected library identity. The unchanged checker compiled **66 authoring assets and shader/snippet templates for macOS and tvOS**; Mac GPU verification passed **seven profile checks**.

Supervision benchmarks compare merge `8f2a7a3` with this tree using the same interpreter/filesystem, alternating execution order, 31 warm short-command samples and five fixtures of 18 Git commands. Timings are local evidence, not CI assertions.

| Interpreter | Short command median, baseline → current (ms) | 18 Git commands median, baseline → current (ms) |
| --- | --- | --- |
| Python 3.9.6 | 192.468 → 192.834 | 2954.780 → 3011.385 |
| Python 3.15.0 | 75.752 → 75.620 | 1449.307 → 1474.808 |

Every managed-command fixture retained **two interpreter launches, five atomic replacements, and ten fsyncs**. A new logical-operation binding uses three durable transitions (pending binding, configuration, committed binding); those operation writes are separate from managed-command measurements. Structural tests verify that automatic retry performs exact-journal reconciliation without another full scan and that explicit invalidation still checks other journals.

| Interpreter | Idle parent CPU, baseline → current | Idle reaped-child CPU, baseline → current |
| --- | --- | --- |
| Python 3.9.6 | 0.059% → 0.054% | 1.185% → 1.292% |
| Python 3.15.0 | 0.048% → 0.043% | 0.965% → 0.701% |

The separate Release native teardown profile measured **30.30 wait polls/s** and **0.394% of one CPU core** in the supervising test process.

Reproduction commands:

```sh
/usr/bin/python3 -B tools/test_shader_requests.py
python3 -B tools/test_shader_requests.py
HOLODECK_AUTHORING_FIXTURE=/Volumes/Pro2T/HolodeckShaders HOLODECK_GPU_TESTS=1 swift test --package-path HolodeckCore
HOLODECK_PROFILE_WORKER=1 swift test --package-path HolodeckCore -c release --filter 'ShaderRequestTests|ShaderLibraryToolTests'
/usr/bin/python3 -B tools/profile_shader_supervision.py --baseline 8f2a7a3 --interleave
python3 -B tools/profile_shader_supervision.py --baseline 8f2a7a3 --interleave
```

## PR #35 follow-up: failure preservation and recoverable configuration repair (2026-10-25)

This follow-up starts from `f47afc6`, the merge of PR #35. Parsed worker failures survive reply errors, internal shutdown and stream retirement. Unexplained post-launch exits receive the supervision retry; deterministic startup and explicit operational failures remain terminal. A verified, actively owned retry can accept queued submissions from other TVs while retaining exclusive checkout execution. Unrelated recovery and restarted retries remain blocking.

Cleanup repairs record field-specific old/new configurations and operation IDs before changing bindings. Repository, Python and Git corrections preserve independently newer sibling/preferences values and every unrelated setting. Guided maintenance repair requires intact operation-target evidence and archives damaged bytes or symlinks without following them. Verified initial maintenance operations can be replaced after configuration changes; retry phases retain their stricter recovery rules. Pending Detach and configuration-repair intent survive worker completion.

The recovery store remains format 1 and operation journals remain format 2. Existing journals without the optional repair/diagnostic fields remain readable. Diagnostics keep an 8 KiB primary cause and the last eight distinct 2 KiB secondary causes, with full details appended to no-follow journal-local logs when possible. Encoding checks the entire 2 MiB store, removes optional diagnostic detail first and rejects oversized essential metadata without replacing the last good store. A serial writer performs ordered durable commits outside the service actor, skips unchanged bytes, coalesces progress and waits for critical acknowledgements. Persistence uncertainty blocks ordinary writes while permitting retained recovery evidence.

Frozen-source validation passed **362 Swift core tests with six opt-in skips**, including compilation/rendering/animation of all 23 local scenes. **162 Release tests passed with one opt-in skip**, covering service, persistence and installed-resource behavior. Python **3.9.6 and 3.15.0 each passed all 119 worker tests**, with no skips. The core skips were three unrelated catalog performance probes, the worker profile (run subsequently in Release), live LAN/TLS and live Codex publication; Release skipped only live Codex publication.

New regressions cover parsed-fault/reply races, unexplained exits, queued acceptance during an owned retry, field-specific sibling rebinding, failed/uncertain intent publication, referenced-record deletion, legacy missing participants, corrupt and dangling maintenance configuration, exact target rejection, interrupted binding replay, initial-operation replacement, and Detach intent surviving finalization. Storage regressions hold a recovery write while querying and stopping the service, verify retained patch bytes, assert ordered and unchanged writes, and exercise Unicode diagnostic bounds, capacity rejection and symlink-safe logs.

Release persistence profiling compares the actor source from merged PR #35 with the current service using the same native launch machinery and filesystem. Five samples per interpreter alternate baseline/current order, with 200 worker stage events followed by a clarification result. Counts include `journal.json`, `recovery.json` and `detached-checkouts.json`; unchanged operation/process evidence writes are excluded from both sides. Each metadata replacement fsyncs the file and parent directory. Results are local measurements, with structural write assertions in tests and no CI timing thresholds.

| Child interpreter | Fixture median, baseline → current | Service CPU median, baseline → current | Metadata replacements | Metadata fsyncs |
| --- | --- | --- | --- | --- |
| Python 3.9.6 | 412.604 → 205.520 ms | 0.278623 → 0.054610 s | 618 → 4 | 1236 → 8 |
| Python 3.15.0 | 250.370 → 73.034 ms | 0.213480 → 0.031876 s | 618 → 4 | 1236 → 8 |

The separate Release idle-supervision profile measured **33.48 polls/s** and **0.3623% of one CPU core**.

All **five isolated Mac UI tests passed**, including the new guided-repair case that retains exact corrupt configuration bytes. Both Release app builds passed with signing disabled. Both Mac copies and the tvOS copy of each Python resource match source, neither app contains bytecode caches, and the packaged worker accepted the selected library's checker identity. The packaged checker compiled **66 authoring assets plus shader/snippet templates for macOS and tvOS**; Mac GPU verification passed **seven profile checks** on Apple M2 Pro.

Final evidence is in `/tmp/holodeck-recovery-*`: `python39.log`, `python315.log`, `core-verified.log`, `acceptance-{release,ui,mac-build,tv-build,package,metal,gpu}.log`, `acceptance-{hashes,progress}.json`, and `profile-{39,315}.json`. Runtime/UI source hashes remained unchanged through the final native acceptance run. Development failures and the superseded Release run are excluded from these results.

Physical Apple TV, simulator runtime, live LAN/TLS and real Codex publication were not run. No checker artifact, library lock, Linux CI, live installation or request settings changed. A later rollout must drain requests before replacing the matching native host and bundled worker.

Reproduction commands:

```sh
/usr/bin/python3 -B tools/test_shader_requests.py
python3 -B tools/test_shader_requests.py
HOLODECK_AUTHORING_FIXTURE=/Volumes/Pro2T/HolodeckShaders HOLODECK_GPU_TESTS=1 swift test --package-path HolodeckCore
HOLODECK_PROFILE_WORKER=1 swift test --package-path HolodeckCore -c release --filter 'ShaderRequestTests|ShaderLibraryToolTests|RequestPersistenceTests'
python3 -B tools/profile_request_persistence.py --baseline f47afc6 --python /usr/bin/python3
python3 -B tools/profile_request_persistence.py --baseline f47afc6 --python /opt/homebrew/bin/python3
```

## PR #36 follow-up: persistence faults and recovery coordination (2026-10-25)

This follow-up starts at `aade843`, the merge of PR #36. Native settlement/evidence errors now take precedence over a parsed ordinary worker failure. The initiating diagnostic remains available separately, and `waitForExit()` preserves unverifiable ownership/evidence rather than permitting ordinary cleanup.

The service and serial writer share a generation-tagged storage fault carrying the initiating operation and affected files. Critical caller mutations retain accepted logical state and in-memory file before-images (including explicit absence), acknowledge only durable writes, and restore rejected submissions, answers and settings. Recovery/Detach intent and confirmed ownership/publication facts are independent of caller rollback. Storage recovery keeps ordinary scheduling blocked until restoration and accepted-state durability checks succeed; older completions cannot clear a newer fault. A bounded `storage-recovery.json` summary retains accepted-state hashes and diagnostics, never rollback bytes. After restart, unverifiable uncertainty requires explicit verification or manual journal repair. This is intentionally not a general durable transaction log.

Storage faults have a separate **Storage Recovery** row with **Retry Recovery** and **Open Recovery Journal**, including when no checkout recovery entry exists. Persistent faults promptly fail pending Rebuild waiters. Temporary critical commits register one deferred scheduling wakeup, without starting background reconciliation merely because initialization wrote metadata. Record deletion commits an optional pending-deletion record before touching its directory; advancing that accepted rollback boundary cannot fail. Physical cleanup and final record removal are idempotent, and a later failure does not reject the accepted deletion.

Explicit cleanup recovery can migrate missing/mismatched format-1 operation bindings only after exact-checkout validation and settlement; ordinary launches and unrelated format-2 mismatches remain strict. Repair replay recognizes only the current app's trusted bundled shader-tool relocation in preferences; captured request tools remain unchanged. Maintenance repair rejects pending Detach and conflicting proposals, and resumes matching saved intent without generating replacement IDs. Public-operation regressions exercise the reported stale-reconciliation concern; no speculative cancellation or paused-retry policy change was made.

Rollback retains hashes of all of a caller's proposed contents, so an earlier write remains recognizable after a later restoration write fails. Only metadata bytes stay cached after acceptance; payload screenshots and sources are released. Fault generations, including failed recovery writes, govern stale-completion filtering and the shared scheduling gate.

Progress snapshots supersede only covered files/revisions. Recovery-only barriers preserve pending journal progress. Immutable snapshots are coalesced before encoding on the serial writer, with unchanged-byte avoidance and existing capacity limits. Maintenance proposals are prepared outside the actor, cached by entry/configuration/binding generation, and revalidated by the repair action. Recovery status generation reads memory only. Release testing exposed an inherited-context assertion in the first wakeup implementation; the final wakeup uses an explicit actor hop and does not inherit a caller mutation token.

Regressions cover the six disposable review reproductions, errors before/after atomic replacement, failed/conflicting rollback, stale fault completion, restart without rollback bytes, rejected answers, durable repair preservation, accepted deletion interrupted during final metadata persistence, scheduling under overlapping commits, trusted relocation, legacy binding boundaries, repeated/conflicting maintenance repair, partial-file supersession, encoding work and responsive cached status under a held proposal read. Existing conservative ownership, interruption, paused-retry, retained-file and unlimited-implementation tests remain in the acceptance run.

The frozen-source Debug run passed **378 Swift core tests with six opt-in skips**, including local scene compilation/rendering/animation. Python **3.9.6 and 3.15.0 each passed all 119 worker tests**, with no failures or skips. The Python 3.15 log includes a subprocess `ResourceWarning`; its named process had exited when checked. No Python worker/checker source or lock changed in this follow-up.

The frozen-source Release run passed **178 service, persistence and packaged-resource tests with one opt-in skip**. The skipped Release case requires explicit credentials and a disposable checkout for real Codex publication. The Debug skips cover unrelated catalog performance probes, the worker profile (run in Release), live LAN/TLS and real Codex publication.

All **six isolated Mac UI tests passed**, including standalone Storage Recovery, guided configuration repair, retained-file Detach, Rebuild recovery and queued cancellation/deletion. Both Release app builds passed with signing disabled. Every packaged Python resource copy matches source, both apps contain no bytecode caches, and the packaged worker accepted the selected library's checker identity. The packaged checker compiled **68 authoring assets plus shader/snippet templates for macOS and tvOS**; Mac GPU verification passed **seven profile checks** on Apple M2 Pro. Runtime/UI/regression-source fingerprints matched before and after all eight native acceptance steps.

The Release idle-supervision profile measured **33.03 polls/s** and **0.4412% of one CPU core**. Slow-storage regressions query and stop the service while a writer is held, keep critical acknowledgements pending, and exercise status requests while a proposal read is held. These are bounded responsiveness checks, with structural encoding/write assertions rather than CI timing thresholds.

Persistence profiling loads both the service and writer from merged PR #36 (`aade843`) and uses the common native launch/settlement machinery. Five warm samples per child interpreter alternate baseline/current order on the same filesystem, with 200 stage events followed by clarification. Baseline encoding counts include payloads encoded before enqueue; current counts include surviving encodes after coalescing. The harness measures metadata replacements and their file/directory fsyncs independently. The earlier PR #35 commands describe that historical harness.

| Child interpreter | Fixture median, baseline → current | Service CPU median, baseline → current | Metadata encodings | Metadata replacements | Metadata fsyncs |
| --- | --- | --- | --- | --- | --- |
| Python 3.9.6 | 114.201 → 106.608 ms | 0.032599 → 0.027465 s | 618 → 18 | 4 → 4 | 8 → 8 |
| Python 3.15.0 | 55.510 → 47.268 ms | 0.028598 → 0.022703 s | 618 → 18 | 4 → 4 | 8 → 8 |

The fixture performs **97.1% fewer metadata encodes**, preserving the existing write/fsync reduction from PR #36. Results are local observations; structural regression tests enforce coalescing and unchanged-write behavior.

Final evidence is in `/tmp/holodeck-pr37-*`: `python39.log`, `python-current.log`, `native-{core,release,ui,mac-build,tv-build,package,metal,gpu}.log`, `native-{hashes,progress}.json`, and `profile{39,315}.json`. All eight final native steps passed with unchanged runtime/UI/regression-source hashes. Development runs, the executor-assertion run and the one-sample profile smoke test are excluded from final results.

Physical Apple TV and tvOS simulator runtime checks, live LAN/TLS and real Codex publication were not run. No live installation, request-enabling preference, checker artifact, library lock, Linux CI, merge or deployment changed. A later rollout must drain requests before replacing the matching native host and bundled worker.

Reproduction commands:

```sh
/usr/bin/python3 -B tools/test_shader_requests.py
python3 -B tools/test_shader_requests.py
HOLODECK_AUTHORING_FIXTURE=/Volumes/Pro2T/HolodeckShaders HOLODECK_GPU_TESTS=1 swift test --package-path HolodeckCore
HOLODECK_PROFILE_WORKER=1 swift test --package-path HolodeckCore -c release --filter 'ShaderRequestTests|ShaderLibraryToolTests|RequestPersistenceTests'
python3 -B tools/profile_request_persistence.py --baseline aade843 --samples 5 --stages 200 --python /usr/bin/python3
python3 -B tools/profile_request_persistence.py --baseline aade843 --samples 5 --stages 200 --python /opt/homebrew/bin/python3
```
