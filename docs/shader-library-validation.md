# Shader library and discovery validation

Validation on October 9, 2026 used an Apple M2 Pro, macOS 27.0.1, Xcode 27.0 (27A266a), and a tvOS 27 simulator. The app implementation starts from the existing shared-core/Mac baseline `733f2fe`.

| Check | Result |
| --- | --- |
| Producer and library Python tests, including opt-in GPU composition | 15 passed |
| Eight snippet examples compiled for macOS and tvOS | Passed |
| Eight snippet examples sampled at 0, 3 and 10 seconds, 640×360 | Rendered and visually inspected |
| Unlisted shader combining glowing-ribbons and value-noise/cosine-palette | Compiled for both SDKs; three distinct 320×180 samples |
| Eight publication previews regenerated at default 1280×720 / 3 seconds | Receipts updated; all PNG and assembled source hashes unchanged |
| Publication metadata, assets and tvOS compilation | Passed |
| Shared-core tests on macOS | 37 passed; opt-in live publication test initially skipped |
| Shared-core tests on tvOS simulator | 37 passed; opt-in live publication test initially skipped |
| TV UI suite | 16 passed |
| TV app suite | 25 passed |
| Mac UI suite | 5 passed |
| Separate opt-in live publication test on macOS | Passed: downloaded, compiled, rendered and animated all eight scenes; verified previews and offline cache |

The compatibility tests preserve the previous decoder, verify old caches with the new decoder, round-trip discovery metadata through refresh/storage, and retain a usable snapshot after an invalid collection update. Filter tests cover collection order, combined mood/motion/search/favorites, and empty results. UI tests cover TV focus/chooser/Back recovery and Mac search/favorites/reset. Existing offline, cancellation, source replacement, animation clock and removed-active-scene tests remain passing.

The first expanded publication came from authoring commit `46e2c5a`; the final publication is `2df7c725215cff13b39b2d3b6c0245a775d79360`, from authoring commit `f269e8c`. [Publication CI passed](https://github.com/hbmartin/HolodeckShaders/actions/runs/37980776403). Its manifest exactly matches the locally validated snapshot: four ordered collections, all eight original shader IDs, Plasma as default, and unchanged source/PNG hashes. The published tree contains only the manifest and 16 source/preview files.

The first anonymous live check encountered GitHub's network-wide public API quota. After its reset, the same check passed without app/network-policy changes. A Mac refresh from the previous catalog added mood/motion controls and active-scene discovery, exposed the authored collections, and retained Plasma as the active scene through Atmospheric filtering and Reset.

Reproduce the authoring checks in HolodeckShaders:

```sh
HOLODECK_GPU_TESTS=1 python3 -m unittest discover -s tools -p 'test_*.py'
python3 tools/library.py validate --compile
python3 tools/catalog.py validate
```

Run `swift test` inside HolodeckCore for macOS. For tvOS, run `xcodebuild -scheme HolodeckCore -destination 'platform=tvOS Simulator,name=Apple TV' -parallel-testing-enabled NO test` from the package directory; the app project's library scheme has no test action. Run the Holodeck and HolodeckMac project schemes for their platform UI suites. Set `HOLODECK_LIVE_CATALOG=1` when running `RenderingTests.testLivePublishedCatalogCompilesRendersAndAnimates` to verify the current GitHub publication, previews and cache.

## Release checks

macOS 15, tvOS 26 and a physical Apple TV were unavailable for this implementation check. Verify those targets before releasing the updated apps. Sampled stills establish render correctness and aid visual review; they do not establish motion quality or target-device performance. Snippet costs are documented estimates; no device performance benchmark is claimed.
