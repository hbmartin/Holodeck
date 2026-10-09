# Holodeck

A Metal scene viewer for tvOS 26.0 and later and Apple silicon Macs running macOS 15 or later. Shaders are downloaded as Metal source and compiled at runtime; no precompiled Metal library is required.

## Controls

- Launch restores the last successfully activated shader full screen. A first launch downloads the catalog before starting its default shader (currently Plasma). A saved ID no longer in the catalog also resolves to its default. If a remembered shader fails to compile, the picker reports the error and keeps that saved ID until another shader succeeds.
- Press **Select** to open the shader picker, use directional input to browse, and press **Select** to load a shader.
- **Back** dismisses the picker. While a shader is loading, the current one keeps running. Dismissing a pending selection retains the current shader.
- During startup, Back leaves the startup shader loading and restores its loading hint. If you dismiss a different pending selection before any shader is active, that selection is canceled and the resolved startup shader loads again. Reopening the picker focuses the active shader; compilation results and interruptions preserve your place while browsing.
- Animation and drawing pause when the scene becomes inactive.

## Mac viewer

Open the **HolodeckMac** scheme in Xcode and run on My Mac. It uses a single SwiftUI window with a collapsible sidebar, metadata preview images, category groups, and scene name/description search. Arrow keys and mouse selections load scenes immediately. Favorites are stored locally and combine with the search filter; filtering never changes playback.

Every launch starts the published catalog default at time zero. Window geometry and sidebar visibility are restored. The selected scene's title, category, description, and favorite button appear beneath the viewer. The interface follows system appearance, and full screen preserves the layout. Use **Command-F** to focus search and **Control-Command-S** to toggle the sidebar. The toolbar and app menu offer **Check for Scene Updates**, bypassing automatic refresh throttling.

Mac refreshes update the library immediately and replace an active shader when its source changes, restarting animation only after successful compilation. Metadata-only changes keep animation running; removed scenes can continue playing. Download and activation failures show retryable modal alerts and preserve working content. Missing preview images use the metadata colors.

The Mac render area is always 16:9 with black letterboxing. It targets 30 fps and adapts Retina drawable resolution through 100%, 85%, 70%, and 50% scales. One-second GPU timing windows lower the scale after two consecutive averages above 25 ms and raise it after five below 16 ms. Scene, size, display, and activity changes reset measurements with a two-second warm-up. Unavailable timing holds the current resolution. Unfocused, minimized, closed, and sleeping viewers pause animation without accumulating inactive time. Normal system display sleep remains enabled.

## Shared core

Both viewers support ordered curated collections and mood/motion filters. TV retains one horizontal scene row with selectors above it; Back closes an option chooser before dismissing the picker. Mac combines collections and filters with tag search and local favorites. Reset Filters clears browsing constraints without changing playback. Filters last for the current session. Older catalogs fall back to Procedural and Materials collections and hide unavailable discovery controls.

`HolodeckCore` is a local Swift package used by both app targets. It contains catalog models and validation, revision-pinned networking and atomic disk caching, preview fetching, source-aware compilation, the Metal renderer and animation clock, injectable dependencies, viewer/session state, favorites persistence, filtering, and adaptive rendering policy. UIKit focus and Siri Remote behavior stay in the TV target; SwiftUI and AppKit window/view adapters stay in the Mac target.

`ViewerSession` exposes catalog refresh (including forced checks), scene selection, pending cancellation, activity, and retry. `ViewerPolicy.tv` restores the last successful scene and retains active shaders across updates. `ViewerPolicy.mac` starts the catalog default and replaces changed active shaders. `RenderingPolicy.tv` retains native 60 fps rendering; `.mac` enables adaptive 30 fps rendering. Concurrent catalog refreshes share one operation and return the same result.

## Shader catalog

See [Shader repositories and catalog workflow](docs/shader-catalog-workflow.md) for the repository relationship, an add-a-shader walkthrough, and publishing and runtime control-flow diagrams.

[HolodeckShaders](https://github.com/hbmartin/HolodeckShaders) owns shader bodies, shared Metal helpers, metadata and generated previews. Its publishing workflow validates content and tvOS Metal compilation before replacing the public `published` branch with one complete snapshot. Follow that repository's authoring instructions to add a shader; no app release is needed for catalog updates.

The app resolves `published` to a commit, then downloads the manifest and sources at that exact revision. It validates schema version 1, metadata, unique IDs, paths, dates and SHA-256 hashes before atomically caching and activating a snapshot. Failed refreshes retain the previous catalog. Refreshes run in the background at launch and foreground return, throttled to once per 15 minutes once a usable catalog exists, including failed refresh attempts. With an empty cache, Select retries a failed download immediately. GitHub rate limits and network errors leave offline content usable.

The app ships with no shader catalog, source or preview images. Startup uses the most recent valid downloaded disk snapshot. If no valid cache exists, the app shows “Downloading shaders…”; a connection failure asks the user to connect and press Select to retry. First launch requires internet. Cached sources remain available offline, but tvOS may evict cache files, in which case a new download is required. The picker updates names, previews and localized update dates while preserving focus by shader ID. On TV, the active shader continues until a new selection; if it disappears from the catalog, it can finish playing and the next launch uses the catalog default. Images load asynchronously, are cached by hash, and fall back to card gradients when unavailable.

`ShaderCompiler` compiles complete source libraries on its actor executor, with the existing `vertexShader`, `fragmentShader` and 16-byte buffer-0 uniform contract. Pipelines are cached by shader ID and source hash; selecting a revised shader recompiles it. Only the latest selection can activate a pipeline. Compilation diagnostics go to the console; the picker reports failures and allows another selection.

## Dependencies

Runtime services use Point-Free's `swift-dependencies` through shared `DependencyValues` accessors: Metal device, renderer factory, shader compiler factory, monotonic animation time, and shader preferences. The catalog service additionally injects networking, disk storage and refresh time; tests use recorded repository content in test-only resources with networking disabled or stubbed. These fixtures are linked only to test targets and excluded from the shipping app; UI tests inject them through their launch environment, including empty-cache download and retry scenarios. The startup hint uses the built-in continuous clock. The scene constructs the storyboard controller in a dependency scope; the controller propagates that scope to its renderer and tasks. The renderer retains its compiler and time closure rather than resolving dependencies on each frame.

Preferences store `holodeck.lastShaderID` in UserDefaults only after a current selection activates successfully. Canceled, superseded, and failed selections leave the saved ID untouched. Tests override dependencies before controller construction, use a TestClock and isolated preferences, and explicitly opt into real GPU compilation where required. UI tests use a separate UserDefaults suite per test, including a relaunch test that reuses its suite.

## Validation

Run portable tests from the package on Mac, and the same **HolodeckCore** scheme on a TV simulator. They cover catalog validation, cache behavior, forced/throttled/coalesced refreshes, rendering and animation, source-aware pipelines, differing startup/update policies, cancellation, failure recovery, favorites/search, and adaptive resolution. Test-only catalog resources are excluded from both shipping apps. Live repository verification is opt-in to keep routine tests independent of the network.

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
