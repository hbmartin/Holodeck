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

## Original physical LAN check

An Apple TV 4K running tvOS 26.6 discovered the Mac's advertised service, resolved it locally, completed TLS pairing, showed the same six-digit code as the Mac settings view, and downloaded the real 23-scene authoring library after clicking **Approve**. The default scene played successfully. Relaunch restored cached playback and reauthenticated to the remembered Mac without another approval.

A second physical run stopped the Mac server after the remembered-host reconnect. The TV reported disconnection, then relaunched and played the cached default scene with the server unavailable. Both physical LAN UI runs passed.

The opt-in physical test uses real production transport and runtime Metal compilation, with isolated test Keychain credentials and disk storage. On this TV, its system profile picker had to be dismissed before Holodeck could become active. Discovery now starts from the foreground lifecycle; with no usable cache, the TV opens the picker to make connection and approval states visible.

## Remaining device checks

The router-level WAN-blocked test was skipped at the user's request. Physical permission denial/recovery, Mac sleep/wake, and minimum macOS 15 runtime checks remain manual release checks. Automated privacy/error mapping, revocation, TLS pinning, and offline-cache tests do not substitute for testing those OS and router behaviors.

Run instructions and test opt-ins are in [the local shader library workflow](shader-catalog-workflow.md).
