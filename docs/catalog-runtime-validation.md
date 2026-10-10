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

The ordinary skipped tests are the live publication check and two performance comparisons. Their separate opt-in runs passed. Cache read instrumentation verifies that loading runs off the main thread; validation and ImageIO decoding are isolated to the catalog actor. Successful repeated thumbnail requests return the same decoded image. Evicting decoded images reuses encoded memory without disk reads. The existing publication and disk formats require no migration, publisher changes or credentials.

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
