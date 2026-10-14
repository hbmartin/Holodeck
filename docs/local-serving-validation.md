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
