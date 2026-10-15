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

The 11 skipped core checks comprise three profiling tests (`HOLODECK_PROFILE`), one live Bonjour/TLS test (`HOLODECK_LAN_TEST`), two supplied-authoring tests (`HOLODECK_AUTHORING_FIXTURE`), the real Codex publication test (`HOLODECK_REQUEST_FIXTURE_CONFIG`), and four GPU opt-ins (`HOLODECK_GPU_TESTS`). Physical-device testing was not rerun. Strict schema-2 verification, queued-only cancellation, unlimited genuine shader-defect retries, pushed-commit preservation and network compatibility remain covered. Legacy migration, the separate symlink-OID refactor (#9) and performance optimization work (#15) remain deferred. This follow-up is committed and pushed to the existing PR; no history rewrite, merge or deployment.
