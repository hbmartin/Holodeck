# Holodeck

A Metal scene viewer for tvOS 26.0 and later and Apple silicon Macs running macOS 15 or later. Shaders are downloaded as Metal source and compiled at runtime; no precompiled Metal library is required.

## Controls

- Launch restores the last successfully activated shader full screen. A first launch downloads the catalog before starting its default shader (currently Plasma). A saved ID no longer in the catalog also resolves to its default. If a remembered shader fails to compile, the picker reports the error and keeps that saved ID until another shader succeeds.
- Press **Select** to open the shader picker, use directional input to browse, and press **Select** to load a shader.
- **Back** dismisses the picker while playback or startup loading is available. After startup compilation fails, Back returns to the Home screen from idle recovery. During a pending recovery selection, the first Back cancels it; the next Back returns Home. While a shader is loading, the current one keeps running. Dismissing a pending selection retains the current shader.
- During startup, Back leaves the startup shader loading and restores its loading hint. If you dismiss a different pending selection before any shader is active, that selection is canceled and the latest resolved startup shader loads again, provided startup has not failed. Reopening the picker focuses the active shader; compilation results and interruptions preserve your place while browsing.
- Animation and drawing pause when the scene becomes inactive.

## Mac viewer

Open the **HolodeckMac** scheme in Xcode and run on My Mac. It uses a single SwiftUI window with a collapsible sidebar, metadata preview images, category groups, and scene name/description search. Arrow keys and mouse selections load scenes immediately. Favorites are stored locally and combine with the search filter; filtering never changes playback.

Every launch starts the published catalog default at time zero. Window geometry and sidebar visibility are restored. The selected scene's title, category, description, and favorite button appear beneath the viewer. The interface follows system appearance, and full screen preserves the layout. Use **Command-F** to focus search and **Control-Command-S** to toggle the sidebar. The toolbar and app menu offer **Check for Scene Updates**, bypassing automatic refresh throttling.

Mac refreshes update the library immediately and replace an active shader when its source changes, restarting animation only after successful compilation. Metadata-only changes keep animation running; removed scenes can continue playing. Initial download and activation failures show retryable modal alerts and preserve working content. Background download failures appear inline beside cached scenes. Catalog loading proceeds even when Metal is unavailable, with cached rows visible and disabled. Missing preview images use the metadata colors.

The Mac render area is always 16:9 with black letterboxing. It targets 30 fps and adapts Retina drawable resolution through 100%, 85%, 70%, and 50% scales. One-second GPU timing windows lower the scale after two consecutive averages above 25 ms and raise it after five below 16 ms. Scene, size, display, and activity changes reset measurements with a two-second warm-up. Unavailable timing holds the current resolution. Unfocused, minimized, closed, and sleeping viewers pause animation without accumulating inactive time. Normal system display sleep remains enabled.

## Shared core

Both viewers support ordered curated collections and mood/motion filters. TV retains one horizontal scene row with selectors above it; Back closes an option chooser before dismissing the picker. Mac combines collections and filters with tag search and local favorites. Reset Filters clears browsing constraints without changing playback. Filters last for the current session. Older catalogs fall back to Procedural and Materials collections and hide unavailable discovery controls.

`HolodeckCore` is a local Swift package used by both app targets. It contains catalog models and validation, revision-pinned networking and atomic disk caching, preview fetching, source-aware compilation, the Metal renderer and animation clock, injectable dependencies, viewer/session state, favorites persistence, filtering, and adaptive rendering policy. UIKit focus and Siri Remote behavior stay in the TV target; SwiftUI and AppKit window/view adapters stay in the Mac target.

`ViewerSession` exposes catalog refresh (including forced checks), scene selection, pending cancellation, activity, and retry. `ViewerPolicy.tv` restores the last successful scene and retains active shaders across updates. `ViewerPolicy.mac` starts the catalog default and replaces changed active shaders. `RenderingPolicy.tv` retains native 60 fps rendering; `.mac` enables adaptive 30 fps rendering. Concurrent catalog refreshes share one service-owned download. Cancelling a caller immediately ends its wait; the download continues and can update the cache after every caller leaves. Catalog and selection failures have independent retry/dismissal IDs. Dismissed errors stay dismissed; successful explicit selection clears the preceding selection error. Selection failures survive unrelated refreshes. Cached update failures appear inline with Retry in both viewers, without interrupting playback or opening the TV picker.

## Shader catalog

See [Shader repositories and catalog workflow](docs/shader-catalog-workflow.md) for the repository relationship, an add-a-shader walkthrough, and publishing and runtime control-flow diagrams.

[HolodeckShaders](https://github.com/hbmartin/HolodeckShaders) owns shader bodies, shared Metal helpers, metadata and generated previews. Its publishing workflow validates content and tvOS Metal compilation before replacing the public `published` branch with one complete snapshot. Follow that repository's authoring instructions to add a shader; no app release is needed for catalog updates.

The app resolves `published` with one GitHub REST API request per eligible check, then downloads the manifest, sources and previews from `raw.githubusercontent.com` at that exact commit. Downloads accumulate bounded data chunks with a 30-second timeout. It validates schema version 1, unique IDs, paths, timezone-bearing ISO-8601 dates (with or without fractional seconds) and SHA-256 hashes before atomically caching and activating a snapshot. Discovery labels are trimmed, lowercased and deduplicated. Malformed optional discovery is logged and removed from that shader; core catalog and source validation remain strict. Source bytes, including a UTF-8 BOM, survive decoding and persistence. Failed refreshes retain the previous catalog. Refreshes run in the background at launch and foreground return, throttled by a monotonic clock to once per 15 minutes once a usable catalog exists, including failed refresh attempts. With an empty cache, Select retries a failed download immediately. GitHub rate limits and network errors leave offline content usable.

Service construction performs no disk reads. Its actor loads and validates the existing JSON cache once, preparing immutable `ValidatedCatalog` values with parsed dates, verified source hashes and collections. Sessions apply cached state before waiting for the network and reconcile current service state after every refresh outcome, including errors. No cache migration is required.

The app ships with no shader catalog, source or preview images. Startup uses the most recent valid downloaded disk snapshot. During cache inspection, the app shows “Loading scenes…”. If no valid cache exists, it then shows “Downloading shaders…”; a connection failure asks the user to connect and press Select to retry. First launch requires internet. Cached sources remain available offline, but tvOS may evict cache files, in which case a new download is required. The picker updates names, previews and localized update dates while preserving filters and focus by shader ID. If that ID disappears, focus prefers a visible active shader, then startup/default, then the first visible result. On TV, the active shader continues until a new selection; if it disappears from the catalog, it can finish playing and the next launch uses the catalog default. Images load asynchronously and fall back to opaque card gradients when unavailable.

Preview downloads coalesce by hash. Actor-owned LRU caches hold up to 16 MiB of verified encoded data and 32 MiB of decoded images; memory hits skip disk reads, hashing and decoding. ImageIO runs on a separate worker queue with at most two concurrent decodes, leaving the catalog actor responsive. TV aspect-fill thumbnails use laid-out card bounds, display scale and the 1.045 focus enlargement, rounding upward in 64-pixel buckets with a 2048-pixel cap; Mac previews use 176 pixels. Resizing or a larger scale retains the displayed image until its replacement succeeds. Metadata and publication changes retain images whose hashes have not changed.

Failed preview downloads retry on demand after 30 seconds, doubling to a five-minute ceiling. Hash/signature and decode failures are suppressed for that publication, path and hash until a new publication or service instance. At most 500 failure records are retained. Memory warnings on TV and warning/critical memory pressure on Mac clear both memory caches while retaining catalog state, disk files and retry records. In-flight requests still complete, but work started before trimming cannot refill the caches.

`ShaderCompiler` compiles complete source libraries on its actor executor, with the existing `vertexShader`, `fragmentShader` and 16-byte buffer-0 uniform contract. Pipelines are cached by shader ID and source hash; selecting a revised shader recompiles it. Only the latest selection can activate a pipeline. Compilation diagnostics go to the console; the picker reports failures and allows another selection.

## Dependencies

Runtime services use Point-Free's `swift-dependencies` through shared `DependencyValues` accessors: Metal device, renderer factory, shader compiler factory, monotonic animation time, and shader preferences. The catalog service additionally injects networking, disk storage and refresh time; tests use recorded repository content in test-only resources with networking disabled or stubbed. These fixtures are linked only to test targets and excluded from the shipping app; UI tests inject them through their launch environment, including empty-cache download and retry scenarios. The startup hint uses the built-in continuous clock. The scene constructs the storyboard controller in a dependency scope; the controller propagates that scope to its renderer and tasks. The renderer retains its compiler and time closure rather than resolving dependencies on each frame.

Preferences store `holodeck.lastShaderID` in UserDefaults only after a current selection activates successfully. Canceled, superseded, and failed selections leave the saved ID untouched. Tests override dependencies before controller construction, use a TestClock and isolated preferences, and explicitly opt into real GPU compilation where required. Implicit UI fixture sessions use in-memory preferences. Relaunch tests explicitly supply an isolated defaults suite; failed suite creation falls back to memory. After the final relaunch, a cleanup-only launch removes the named domain and fixture disk cache and uses empty offline/in-memory services. Startup hold/fail controls require a valid fixture and resolve the same saved ID/default as the session. `CatalogService.offline(initialCatalog:storage:)` supplies a fresh disabled service for each test.

## Validation

Run portable tests from the package on Mac, and the same **HolodeckCore** scheme on a TV simulator. They cover catalog validation, cache behavior, forced/throttled/coalesced refreshes, rendering and animation, source-aware pipelines, differing startup/update policies, cancellation, failure recovery, favorites/search, and adaptive resolution. Test-only catalog resources are excluded from both shipping apps. Live repository verification is opt-in to keep routine tests independent of the network.

See [catalog runtime validation](docs/catalog-runtime-validation.md) for the correctness checks and optimized download/preview measurements. Run the opt-in comparisons with `HOLODECK_PROFILE=1 swift test --package-path HolodeckCore -c release --filter CatalogPerformanceTests`.

The **Holodeck** scheme retains TV controller and Siri Remote UI tests. **HolodeckMac** contains Mac UI tests for every scene, arrow selection, search/favorites, persistence, default startup, sidebar/full screen, window reopening, and modal errors. Tests use isolated defaults suites and injected offline catalogs.

```sh
swift test --package-path HolodeckCore
HOLODECK_LIVE_CATALOG=1 swift test --package-path HolodeckCore

xcodebuild -project Holodeck.xcodeproj -scheme HolodeckMac \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO test

# From HolodeckCore/:
xcodebuild -scheme HolodeckCore \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' \
  -parallel-testing-enabled NO test
```

```sh
xcodebuild -project Holodeck.xcodeproj -scheme Holodeck \
  -sdk appletvsimulator \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' \
  -parallel-testing-enabled NO test
```

Deployment targets are tvOS 26.0 and macOS 15.0; the Mac app builds only for arm64. This is a local-development target, without a notarization or App Store distribution workflow. Verify on the minimum OS versions and physical devices before release; a deployment target alone does not confirm runtime compatibility.
