# Catalog runtime validation

Checked on October 9, 2026 using an Apple M2 Pro, macOS 27.0.1, Xcode 27.0 and a tvOS 27.0 simulator. The implementation preserves the merged discovery work: collections, tags, mood/motion filters, legacy manifests and cached JSON. Both apps continue shipping without bundled catalog assets.

The changes are grouped into three reviewable stages:

| Stage | Implementation | Verification |
| --- | --- | --- |
| Catalog/runtime correctness | Immutable prepared catalogs, stored source hashes, strict timezone-bearing dates, BOM-preserving UTF-8, lazy actor cache loading, commit-pinned raw assets, bounded chunk downloads and monotonic throttling | Dates/offsets/malformed values, UTF-8/BOM persistence, legacy/discovery compatibility, 16 MiB cache boundary, 72-shader publication with one REST lookup, atomic writes, chunk limits/HTTP errors/cancellation, shared refreshes and clock boundaries |
| Startup recovery and fixtures | Explicit recovery before first activation, latest startup resolution, reconciliation after every refresh outcome, stable focus/filters and isolated offline fixtures | Back after failure, canceled selections, startup source updates/removal, explicit retry, preference preservation, new sessions after throttled/unchanged/failed checks, cached playback before a held network response and fixture flags without a supplied suite |
| Preview performance and polish | Verified-data and decoded-image LRU caches, request coalescing, off-UI ImageIO thumbnails, identical-hash retention, retry of unavailable images and opaque TV fallback cards | Cache reuse/eviction, coalesced image identity, late completion after cell reuse, image retention, fallback opacity and optimized comparisons |

| Check | Result |
| --- | --- |
| Shared-core correctness tests on macOS | 59 passed (full suite plus the added cache-boundary test); three opt-in tests skipped in the ordinary run |
| Shared-core tests on tvOS simulator | 59 passed; three opt-in tests skipped |
| TV controller/card tests | 27 passed on the final preview implementation |
| TV remote UI tests | 17 passed, including discovery filters and startup failure/Back/recovery without a supplied defaults suite |
| Mac UI tests | 5 passed; every-scene/arrow-selection test repeated successfully after the preview retry refinement |
| Separate live publication check | Passed: downloaded, compiled, rendered and animated eight scenes and verified all preview hashes at publication `2df7c725215cff13b39b2d3b6c0245a775d79360` |
| Optimized performance comparisons | Both passed |

The ordinary skipped tests are the live publication check and two performance comparisons. Their separate opt-in runs passed. Cache read instrumentation verifies that loading runs off the main thread; validation is isolated to the catalog actor; ImageIO decoding now runs on a separate bounded worker queue. Successful repeated thumbnail requests return the same decoded image. Evicting decoded images reuses encoded memory without disk reads. The existing publication and disk formats require no migration, publisher changes or credentials.

## Optimized measurements

Built with `swift test -c release`. Download timings use deterministic URLProtocol delivery in 16 KiB chunks, measuring the actual delegate against the previous bounded `URLSession.AsyncBytes` loop. They exclude real network latency. The 1,353,577-byte fixture took a median **19.90 ms** with the byte loop and **0.83 ms** with the delegate across five samples after two warmups, about **24× faster**.

For 50 repeated requests for one 1280×720 preview, the previous disk read/hash/full-decode path took **588.44 ms** and performed 50 reads. Warm thumbnail-cache requests took **1.51 ms** and performed **zero reads, hashes or decodes**, returning the same `CGImage`. Decoded memory was **3,686,400 bytes** for the full image and **921,600 bytes** for the 640-pixel TV thumbnail. These are local comparisons; target-device timing remains a release check.

Reproduce from the app repository:

```sh
swift test --package-path HolodeckCore
HOLODECK_PROFILE=1 swift test --package-path HolodeckCore -c release --filter CatalogPerformanceTests
HOLODECK_LIVE_CATALOG=1 swift test --package-path HolodeckCore --filter testLivePublishedCatalog
xcodebuild -project Holodeck.xcodeproj -scheme Holodeck -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' -parallel-testing-enabled NO test
xcodebuild -project Holodeck.xcodeproj -scheme HolodeckMac -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO test
```

Run the shared-core scheme from `HolodeckCore/` for tvOS. Deployment targets remain macOS 15 and tvOS 26. Those minimum versions and a physical Apple TV were unavailable for this check.

## Follow-up review fixes

The follow-up preserves service-owned catalog downloads: callers cancel their own wait promptly, while a download with no remaining viewers can still publish its validated snapshot. Gated tests cover pre-cancellation, one cancelled waiter, all waiters leaving, a new waiter joining, viewer shutdown and twenty cancellation/completion races. Each successful flight writes one snapshot.

Viewer state separates cached update notices from selection failures. Refreshes and automatic source replacements preserve user selection errors, and stale retry/dismissal actions cannot clear newer failures. Selecting without a renderer has no state or event side effects. The Mac retains a renderer-unavailable message after alert dismissal and disables scene selection. Compiler and catalog failures include context in unified logs.

Malformed optional discovery is discarded per shader during decoding and programmatic validation, while core fields, collections and source hashes remain strict. Tests exercise missing motion, wrong types, count/length/empty-value failures, normalization/deduplication, unchanged source bytes, sanitized disk round trips and legacy compatibility.

Both viewers use prepared discovery options and a shared filter cache keyed by publication and all filter inputs. The public filter tolerates duplicate shader IDs and builds a first-wins lookup only when a collection is supplied. An optimized 500-scene comparison over 1,000 repeated redraws took **1,131.09 ms** for repeated filtering and **19.45 ms** for cached results, with one computation. This comparison includes result-ID extraction and equality checks on both paths; it measures local repeated filtering rather than whole-app frame time.

Mac checks cover hidden-sidebar Command-F twice, the Control-Command-S sidebar toggle, native fullscreen entry/exit, inline update retry, unavailable Metal, and single usable windows after hiding, minimizing and closing. Fullscreen tests use the native menu action instead of assuming an OS keyboard mapping or exact display bounds. TV checks cover chooser dismissal on user activation, startup preservation, selection errors after refresh, current-control/card focus after refresh, and inline retry without automatically opening the picker. The existing native chooser and authored All ordering remain in place.

| Follow-up check | Result |
| --- | --- |
| Shared-core tests on macOS | 71 passed; four opt-in tests skipped |
| Shared-core tests on tvOS 27 simulator | 71 passed; four opt-in tests skipped |
| TV controller/card tests | 29 passed |
| TV remote UI tests | 19 passed |
| Mac UI test build | Passed, including the latest window-restoration helpers |
| Mac UI tests | Final full-suite pass deferred at the user's request. Cached retry, hidden-sidebar Command-F, discovery filtering, renderer/download errors, and every-scene/arrow selection passed in the last partial run. Fullscreen, search/favorites persistence, and window reopening failed in that run. Window-restoration helpers were adjusted afterward; these three checks still need a UI run. |
| Optimized download, preview and 500-scene filter comparisons | Three passed |
| Mac and TV Release builds | Passed |

## Catalog recovery and destination-sized previews

The latest follow-up replaces recovery-error copy-back with canonical catalog and selection failures. Pending explicit selection temporarily hides its preceding error; cancellation reveals only an undismissed error. Successful explicit selection clears it, while automatic replacement preserves unrelated failures. Retry/dismissal match operation IDs. Mac catalog inspection starts at model initialization independently of Metal, and attachment joins the existing refresh. Cache inspection uses “Loading scenes…”; downloading text begins only when no valid cache was found.

TV idle startup recovery disables Menu interception so Back reaches Home immediately. A pending recovery selection consumes the first Back to cancel, then releases subsequent Back presses. Spinner state comes from pending selection or initial catalog loading, including resumed startup. Picker layout restores its intended opening focus after UIKit layout callbacks and requests focus through the collection view itself, including immediate close/reopen transitions.

TV thumbnails account for aspect fill, card bounds, display scale and the 1.045 focus margin. Destination and thumbnail dimensions round upward in 64-pixel buckets, with a 2048-pixel cap. ImageIO source dimensions and orientation determine the decode size. Cards retain their displayed image while larger requests run or fail, and check both request identity and hash on completion.

ImageIO runs on an internal queue with two concurrent operations. Gated tests hold both workers, confirm catalog calls remain responsive, and verify concurrency and coalescing. Preview failure records are bounded at 500 and keyed by publication, path and hash. Injected-clock tests cover the 30/60/120/240/300-second retry progression, cooldown boundaries and success reset. Validation/decode failures are suppressed until a new publication or instance; cancellation creates no failure record. Memory trimming preserves disk/catalog/retry state and prevents flights started before a trim from repopulating either cache while still returning their results.

Implicit fixture preferences and favorites now stay in memory. Named suites retain relaunch persistence, and failed suite creation falls back to memory. A cleanup-only launch deletes the named defaults domain and fixture disk cache, then uses empty offline/in-memory services to prevent recreation. Both UI suites invoke it in teardown after their final relaunch. Core tests verify fallback, persistence and cleanup with the fixture disk-cache path.

| Latest check | Result |
| --- | --- |
| Core tests on macOS | 83 passed; four opt-in tests skipped |
| Core tests on tvOS 27 simulator | 83 passed; four opt-in tests skipped |
| TV controller/card tests | 31 passed, including resize failures, same-hash stale completion, scale changes, Menu recognition and resumed startup spinner. Immediate close/reopen focus regression also passed ten consecutive iterations. |
| TV remote UI tests | 19 passed, including idle recovery Back to Home and recovery after resuming. Default-launch focus and startup recovery passed again after the final focus refinement. |
| Mac UI test compilation | Passed, including cached rows without Metal and cleanup teardown |
| Mac UI execution | Deferred as previously agreed. The earlier fullscreen, favorites-persistence and window-reopen checks remain unverified after helper changes. |
| Optimized comparisons | All three passed: download 18.736 ms → 0.536 ms; repeated filtering 613.140 ms → 8.567 ms; 50 warm preview requests 528.859 ms → 1.512 ms |
| Mac and TV Release builds | Passed |

The preview comparison uses the preserved 640-pixel API to compare against the earlier full-decode path; production TV sizing now depends on the destination. Measurements exclude real network latency and are local to this machine. Deployment-target OS versions and a physical Apple TV remain unavailable. Service-owned downloads, injected clocks, both strict memory budgets and the existing LRU implementation are retained. There is no catalog/disk-format migration.

## Catalog notices, retry scheduling and window storage

Checked on October 10, 2026 with the same Mac and tvOS 27 simulator. `CatalogService.refreshOutcome(force:)` distinguishes updated and unchanged checks from throttled and disabled checks. The existing optional-returning `refresh(force:)` remains available. Viewer sessions retain catalog failures through refresh startup and skipped checks, clearing them after a successful check, a newly applied publication, or an explicit dismissal/retry. Coalesced callers still cancel independently while the service owns publication and persistence.

TV reactivation requires an attached renderer; Mac and custom policies retain the permissive default. Catalog-loading and failure events respect the renderer-unavailable warning and suppress loading hints. Native Mac alert sheets capture one immutable failure each, present renderer errors first with only OK, and then present session errors with Retry and OK. Their completion handlers act on the captured identity, preserving newer failures and waiting for a usable viewer window.

TV cells retain one request task during transient preview cooldowns. `waitForPreviewRetry(_:)` uses the injected service clock and existing backoff records; permanent failures stay suppressed until reuse, service replacement or a changed full preview descriptor. Publication changes can retry an unchanged image hash. Shared pixel bucketing validates positive finite dimensions and retains the 64-pixel buckets and 2048 cap. A single focus-scale constant supplies both destination sizing and appearance.

Named UI-test suites still persist window geometry across relaunches. Implicit fixture launches and cleanup launches disable frame autosave. Explicit cleanup removes only its named AppKit frame, defaults suite and cache; its cleanup window cannot recreate that frame. The live window frame and historical preferences are preserved.

Mac UI helpers leave native menus closed during normal-window launches, use mouse resize events and read the app's sandboxed preferences from the real user home rather than Xcode's redirected runner home. Storage assertions wait for writes/removals to reach disk, verify restored dimensions and detect added frame entries while allowing prior cleanup writes to finish.

| Check | Result |
| --- | --- |
| Core tests on macOS | 89 passed; four opt-in tests skipped |
| Core tests on tvOS 27 simulator | 89 passed; four opt-in tests skipped |
| TV controller/card tests | 36 passed |
| TV remote UI tests | 19 passed |
| Repeated preview recovery and remote focus checks | Four preview tests and both chooser-return/stale-filter-focus tests each passed three consecutive iterations |
| Mac UI test compilation | Passed, including sequential alerts, stale actions and frame-storage regressions |
| Mac UI execution | Serial full suite on macOS 27.0.1 / Xcode 27.0: 12 passed and one failed. Sequential renderer/catalog alerts, stale actions, explicit frame persistence/cleanup, implicit fixture storage, cached retry, discovery, scene selection, search/favorites and window reopening passed. The existing fullscreen exit check timed out waiting for its menu to open. |
| Mac and TV Release builds | Passed |

The remaining Mac failure is `testNativeFullScreenPreservesSidebarAndPlayback`: XCTest times out waiting for the Exit Full Screen menu-open notification. A separate native fixture inspection confirmed fullscreen entry and exit, but automated fullscreen exit remains unverified. This failure is recorded separately; no fullscreen implementation change is included. The final serial run executed all 13 tests with one failure.

Focus restoration, cache insertion after trimming and discovery sanitization are unchanged. The repeated remote focus checks passed without an implementation change. Catalog JSON, disk formats, retry intervals, cache budgets and deployment targets are unchanged; no storage migration or broad preferences cleanup is introduced.

## Alert recovery and fixture infrastructure

Checked on October 10, 2026 with macOS 27.0.1, Xcode 27.0 and the tvOS 27 Apple TV 4K (3rd generation) simulator. Native sheets now reconcile their captured operation against canonical failure state and abort when that operation clears or no longer qualifies for a modal alert. Presentation remains owned until the completion handler runs, and captured retry/dismissal actions retain their identity checks. Repeated unresolved catalog failures reuse their identity when the message is unchanged; explicit dismissal/retry, changed content and successful recovery reset that lifecycle. Selection failures retain separate identities for separate attempts, including identical error messages.

Successful refresh outcomes apply the service's current catalog once and share their failure-clearing branch. The public outcome cases and optional-return compatibility API remain available. Cancellation classification is shared by the service and TV cell for both `CancellationError` and `URLError.cancelled`; retry keys, cooldowns, immediate retry after transport cancellation and the post-sleep cancellation check are unchanged.

Mac presentation injection lives in a DEBUG-only driver and reaches the coordinator through an injected observer. Fixture factories no longer delete storage. Mac and TV setup invoke explicit shared cleanup before creating preferences/services; Mac setup also removes its named AppKit frame. Mac UI teardown shares an idempotent cleanup handle with explicit cleanup assertions and waits for the cleanup viewer window before terminating. Preferences reads reject missing files by default and propagate unreadable or malformed files; the implicit-storage check retains a verified named frame as a positive control. Core catalog fixtures and refresh gates are shared within the existing core test target.

| Check | Result |
| --- | --- |
| Core tests on macOS | 91 passed; four opt-in tests skipped |
| Core tests on tvOS 27 simulator | 91 passed; four opt-in tests skipped |
| TV controller/card tests | 37 passed, including current-cell recovery after both cancellation representations |
| TV remote UI tests | 19 passed |
| New Mac reactivation recovery regression | Passed: unavailable Metal plus fail-once catalog recovery closes the pending sheet and restores usable catalog controls |
| Preferences-reader errors | Passed with final code: missing files require explicit permission, malformed/non-dictionary plists fail, and unreadable-directory errors propagate even when missing files are allowed |
| Mac UI full suite and three consecutive fullscreen iterations | Pending: focused fullscreen/keyboard runs encountered a system SecurityAgent dialog intercepting native input. The dialog requires user handling before acceptance can be established. |
| Mac and TV Release builds | Passed |

The fullscreen helpers explicitly open View, reveal the menu bar at the display's top edge and wait up to 15 seconds for menu and window transitions. They use coordinate clicks inside the already-open menu to avoid XCTest reopening the ancestor menu. Renderer Return retains the AppKit default button; a sheet-scoped Escape handler invokes the same OK action. Keyboard dismissal and fullscreen acceptance remain unverified until native input is available. No deployment target, persisted format, renderer refresh policy or preview retry policy changed.
