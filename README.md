# Holodeck

A Metal scene viewer for tvOS 26.0 and later and Apple silicon Macs running macOS 15 or later. Shaders are downloaded as Metal source and compiled at runtime; no precompiled Metal library is required.

- **[User quickstart](docs/quickstart.md):** configure your Mac, approve your TV, and start playing scenes.
- **[Technical reference](docs/local-shader-serving.md):** architecture, publication, discovery, TLS pairing, protocol, caching, and developer setup.
- **[Authoring workflow](docs/shader-catalog-workflow.md):** folder format and publication overview.

## Controls

- Launch restores the last successfully activated shader full screen. A first launch discovers your Mac and waits for approval before downloading its local catalog and starting the default shader. A saved ID no longer in the catalog also resolves to its default. If a remembered shader fails to compile, the picker reports the error and keeps that saved ID until another shader succeeds.
- Press **Select**, then **Gallery**, to open the shader picker, use directional input to browse, and press **Select** to load a shader.
- **Back** dismisses the picker while playback or startup loading is available. After startup compilation fails, Back returns to the Home screen from idle recovery. During a pending recovery selection, the first Back cancels it; the next Back returns Home. While a shader is loading, the current one keeps running. Dismissing a pending selection retains the current shader.
- During startup, Back leaves the startup shader loading and restores its loading hint. If you dismiss a different pending selection before any shader is active, that selection is canceled and the latest resolved startup shader loads again, provided startup has not failed. Reopening the picker focuses the active shader; compilation results and interruptions preserve your place while browsing.
- Animation and drawing pause when the scene becomes inactive. Temporary interruptions preserve the Mac connection and pairing; entering the background stops discovery and networking.

## Mac viewer

Open the **HolodeckMac** scheme in Xcode and run on My Mac. It uses a single SwiftUI window with a collapsible sidebar, metadata preview images, category groups, and scene name/description search. Arrow keys and mouse selections load scenes immediately. Favorites are stored locally and combine with the search filter; filtering never changes playback.

Every launch loads the configured authoring folder and starts its catalog default at time zero. Window geometry and sidebar visibility are restored. The selected scene's title, category, description, and favorite button appear beneath the viewer. The interface follows system appearance, and full screen preserves the layout. Use **Command-F** to focus search and **Control-Command-S** to toggle the sidebar. The toolbar and app menu offer **Reload Shaders**. **Settings → Shader Library** contains folder selection, serving status, TV approvals, and revocation controls.

Mac refreshes update the library immediately and replace an active shader when its source changes, restarting animation only after successful compilation. Metadata-only changes keep animation running; removed scenes can continue playing. Invalid folder loads name the offending file and preserve the previous served library. Activation failures show retryable modal alerts and preserve working content. Background download failures appear inline beside cached scenes. Catalog loading proceeds even when Metal is unavailable, with cached rows visible and disabled. Missing preview images use the metadata colors.

The Mac render area is always 16:9 with black letterboxing. It targets 30 fps and adapts Retina drawable resolution through 100%, 85%, 70%, and 50% scales. One-second GPU timing windows lower the scale after two consecutive averages above 25 ms and raise it after five below 16 ms. Scene, size, display, and activity changes reset measurements with a two-second warm-up. Unavailable timing holds the current resolution. Unfocused, minimized, closed, and sleeping viewers pause animation without accumulating inactive time. Normal system display sleep remains enabled.

## Shared core

Both viewers support ordered curated collections and mood/motion filters. TV retains one horizontal scene row with selectors above it; Back closes an option chooser before dismissing the picker. Mac combines collections and filters with tag search and local favorites. Reset Filters clears browsing constraints without changing playback. Filters last for the current session. Older catalogs fall back to Procedural and Materials collections and hide unavailable discovery controls.

`HolodeckCore` is a local Swift package used by both app targets. It contains catalog models and validation, revision-pinned networking and atomic disk caching, preview fetching, source-aware compilation, the Metal renderer and animation clock, injectable dependencies, viewer/session state, favorites persistence, filtering, and adaptive rendering policy. UIKit focus and Siri Remote behavior stay in the TV target; SwiftUI and AppKit window/view adapters stay in the Mac target.

`ViewerSession` exposes catalog refresh (including forced checks), scene selection, pending cancellation, activity, and retry. `ViewerPolicy.tv` restores the last successful scene and retains active shaders across updates. `ViewerPolicy.mac` starts the catalog default and replaces changed active shaders. `RenderingPolicy.tv` retains native drawable resolution at 30 fps; `.mac` enables adaptive 30 fps rendering. Concurrent catalog refreshes share one service-owned download. A forced viewer refresh during an existing pass queues one coalesced follow-up; its returned task waits for that pass too. Cancelling a caller immediately ends its wait; the download continues and can update the cache after every caller leaves. Catalog and selection failures have independent retry/dismissal IDs. Dismissed errors stay dismissed; successful explicit selection clears the preceding selection error. Selection failures survive unrelated refreshes. Cached update failures appear inline with Retry in both viewers, without interrupting playback or opening the TV picker.

## Shader catalog

Start with the [user quickstart](docs/quickstart.md). The [workflow guide](docs/shader-catalog-workflow.md) covers authoring; the [technical reference](docs/local-shader-serving.md) details transport, storage, and playback behavior.

Choose a local [HolodeckShaders](https://github.com/hbmartin/HolodeckShaders) authoring folder in **HolodeckMac → Settings → Shader Library**. It must contain `index.json`, `shared/`, and `shaders/`, including each indexed shader's metadata and body. The personal Mac app is unsandboxed and saves the selected folder bookmark. The Mac assembles sources natively and generates cached previews; serving requires no Git commits, Python, repository scripts, or Xcode installation.

The Mac loads this folder at startup and when you press **Reload Shaders**. Directory edits remain unpublished until reload. A complete candidate is validated before replacing the current immutable, app-owned publication. Revisions are canonical SHA-256 content digests; update dates use authoring-file modification times. Collections, discovery labels, and source comments are preserved. Previews render at 1280×720 and three seconds; failed renders use metadata-color gradients with per-shader diagnostics in Settings, and reload retries them. Sharing continues with the viewer window closed, stops during sleep or quit, and resumes after wake.

The TV browses `_holodeck._tcp` in Bonjour's `local.` domain. One Mac connects automatically; several Macs show a chooser. A remembered Mac is retained when unavailable. If alternatives remain available for five seconds while no connection or pairing is viable, the TV opens the chooser once for that absence. **Change Mac** also allows an explicit switch; discovery churn does not close a working connection. On first connection, compare the six-digit code on TV with **Settings → Shader Library** on Mac and click **Approve**. The code comes from that TLS connection. A persistent Mac public-key pin and random per-TV Keychain credential authenticate later connections. **Revoke** stops further downloads; cached playback remains usable. The TV removes the revoked token from its saved pairing while retaining the Mac selection and public-key pin.

All TV catalog, source, and preview requests travel through the selected Mac over TLS 1.3. Service and address resolution use multicast-only DNS-SD, connections require a private or link-local numeric address on the discovered interface, and certificate network fetching is disabled. There are no runtime GitHub downloads or public-network fallback paths. The certificate-generation library is linked only on Mac.

TV refreshes run at launch, foreground return, reconnection, and **Check for Scene Updates**. Ordinary attempts retain the existing 15-minute monotonic throttle; reconnection and explicit checks bypass it. Catalog requests coalesce, transfers are bounded and time out after 30 seconds, idle connections use TCP keepalive, unauthenticated connections expire five minutes after acceptance, hashes are checked, and the complete TV cache is written atomically. Revision-specific allowlisted assets stay available during active downloads across reloads.

The app ships with no shader assets. Existing downloaded caches, including 40-character publication revisions, remain playable after upgrade. TV starts cached playback before checking the Mac. With no cache, configure and open the Mac app, allow local-network access, and approve the TV. TV keeps its active pipeline across updates; changed source takes effect on selection or subsequent launch. Missing previews use gradients. The Mac retains its source-replacement behavior. tvOS can evict cache files, requiring another local download.

Preview downloads coalesce by hash. Actor-owned LRU caches hold up to 16 MiB of verified encoded data and 32 MiB of decoded images; memory hits skip disk reads, hashing and decoding. ImageIO runs on a separate worker queue with at most two concurrent decodes, leaving the catalog actor responsive. TV aspect-fill thumbnails use laid-out card bounds, display scale and the 1.045 focus enlargement, rounding upward in 64-pixel buckets with a 2048-pixel cap; Mac previews use 176 pixels. Resizing or a larger scale retains the displayed image until its replacement succeeds. Metadata and publication changes retain images whose hashes have not changed.

Connectivity-related preview failures wait for connection recovery and retry immediately when it succeeds. Other failed preview downloads retry on demand after 30 seconds, doubling to a five-minute ceiling. An unavailable asset fails only its request and keeps the connection alive. Hash/signature and decode failures are suppressed for that publication, path and hash until a new publication or service instance. At most 500 failure records are retained. Memory warnings on TV and warning/critical memory pressure on Mac clear both memory caches while retaining catalog state, disk files and retry records. In-flight requests still complete, but work started before trimming cannot refill the caches.

`ShaderCompiler` compiles complete source libraries on its actor executor, with the existing `vertexShader`, `fragmentShader` and 16-byte buffer-0 uniform contract. Pipelines are cached by shader ID and source hash; selecting a revised shader recompiles it. Only the latest selection can activate a pipeline. Compilation diagnostics go to the console; the picker reports failures and allows another selection.

## Shader requests from Apple TV

During playback, Select offers **Gallery** (default focus) or **Input**. Input captures the actual shader source, metadata, clean frame and animation time before opening system text entry. An approved TV can submit an independent request, answer clarifications and receive the resulting shader. Manual requests keep playback running with progress and lock browsing while connected; cached browsing returns during a Mac outage.

Enable requests in **Mac Settings → Codex Shader Requests** after choosing a clean, existing checkout with the native shader-tool migration on `origin/main`. Select a model explicitly; High reasoning is the default. Setup verifies Codex login, model/image/JSON compatibility, Git access and identity, Python and both Metal SDK compilers. The app bundles its rendering CLI. Enabling makes this checkout app-managed; source work must already be committed on remote main. Model/reasoning settings belong to Holodeck and are captured with each request.

One persistent worker implements or repairs a shader, checks allowed files, independently runs authoring/license/GPU tests and macOS/tvOS compilation, renders source-bound 1280×720 samples at 0, 3 and 10 seconds, and obtains a separate read-only AI image verdict. New shaders get unused IDs; edits keep their IDs. Shared helper changes trigger review of every affected shader. The host commits and pushes normally to main, repeats verification after push races, and installs a prepared catalog only after a successful push. Completion waits for TV download and activation; an unchanged request avoids an empty commit.

Host Git operations skip local hooks through per-command overrides and compare the committed file bytes with the verified candidate before pushing. Each attempt checks pristine main before invoking Codex. Failed technical/render checks are repeated against the baseline to distinguish shader defects from host or baseline failures: shader defects keep repairing without an attempt limit, while operational failures terminate with retained diagnostics and owned-work cleanup. Activation repairs retain previous publications separately from the current attempt, including recovery after a lost push acknowledgement.

**HolodeckMac → Shader Requests** opens the queue, outcomes, commits, live logs and retained verification frames. Only queued work can be cancelled. Records and evidence remain until Delete Record. The worker parks clarification and activation waits, prioritizes manual jobs over automatic ones, and recovers owned patches, CLI sessions and remote commit state after interruption.

Foreground TV playback targets 30 fps at native resolution. After two warm-up seconds, ten continuous seconds below 27 delivered fps request a visual-preserving optimization. Performance jobs allow browsing and only switch the scene if it is still active. A slow result offers Retry or Dismiss. tvOS omits Metal's drawable-presentation callback: telemetry consumes completed GPU frames on display ticks, counting at most one update per tick and reporting GPU time separately. It is an estimate of delivered updates, not direct compositor presentation timestamps. Performance evidence informs optimization and does not gate commits.

See [the request implementation reference](docs/local-shader-serving.md#shader-request-control-and-execution) and [validation results](docs/local-serving-validation.md#shader-requests-validation).

## Dependencies

Runtime services use Point-Free's `swift-dependencies` through shared `DependencyValues` accessors: Metal device, renderer factory, shader compiler factory, monotonic animation time, and shader preferences. The catalog service additionally injects a `CatalogSource`, disk storage and refresh time; tests use recorded repository content in test-only resources with networking disabled or stubbed. These fixtures are linked only to test targets and excluded from the shipping app; UI tests inject them through their launch environment, including empty-cache download and retry scenarios. The startup hint uses the built-in continuous clock. The scene constructs the storyboard controller in a dependency scope; the controller propagates that scope to its renderer and tasks. The renderer retains its compiler and time closure rather than resolving dependencies on each frame.

Preferences store `holodeck.lastShaderID` in UserDefaults only after a current selection activates successfully. Canceled, superseded, and failed selections leave the saved ID untouched. Tests override dependencies before controller construction, use a TestClock and isolated preferences, and explicitly opt into real GPU compilation where required. Implicit UI fixture sessions use in-memory preferences. Relaunch tests explicitly supply an isolated defaults suite; failed suite creation falls back to memory. After the final relaunch, a cleanup-only launch removes the named domain and fixture disk cache and uses empty offline/in-memory services. Startup hold/fail controls require a valid fixture and resolve the same saved ID/default as the session. `CatalogService.offline(initialCatalog:storage:)` supplies a fresh disabled service for each test.

## Validation

Run portable shared-core tests from the package on Mac and the TV app unit tests on a TV simulator. They cover catalog validation, cache behavior, forced/throttled/coalesced refreshes, rendering and animation, source-aware pipelines, differing startup/update policies, cancellation, failure recovery, favorites/search, and adaptive resolution. Test-only catalog resources are excluded from both shipping apps. Local authoring verification is opt-in and never downloads a public catalog.

See [local serving validation](docs/local-serving-validation.md) for current checks. [Catalog runtime validation](docs/catalog-runtime-validation.md) records historical download/preview measurements. Run the opt-in comparisons with `HOLODECK_PROFILE=1 swift test --package-path HolodeckCore -c release --filter CatalogPerformanceTests`.

The **Holodeck** scheme retains TV controller and Siri Remote UI tests. **HolodeckMac** contains Mac UI tests for every scene, arrow selection, search/favorites, persistence, default startup, sidebar/full screen, window reopening, and modal errors. Tests use isolated defaults suites and injected offline catalogs.

```sh
swift test --package-path HolodeckCore
HOLODECK_LAN_TEST=1 HOLODECK_AUTHORING_FIXTURE=/absolute/path/to/HolodeckShaders swift test --package-path HolodeckCore

xcodebuild -project Holodeck.xcodeproj -scheme HolodeckMac \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  HOLODECK_TEST_BUNDLE_SUFFIX=.RecoveryTests test

xcodebuild -project Holodeck.xcodeproj -scheme Holodeck \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' \
  -parallel-testing-enabled NO -only-testing:HolodeckTests test
```

```sh
xcodebuild -project Holodeck.xcodeproj -scheme Holodeck \
  -sdk appletvsimulator \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' \
  -parallel-testing-enabled NO HOLODECK_TEST_BUNDLE_SUFFIX=.RecoveryTests test
```

The test bundle suffix isolates app installations and containers from the normal development apps. It changes only app and test target identifiers; dependencies retain their own identifiers. Production builds omit it.

Deployment targets are tvOS 26.0 and macOS 15.0; the Mac app builds only for arm64. This is a local-development target, without a notarization or App Store distribution workflow. Verify on the minimum OS versions and physical devices before release; a deployment target alone does not confirm runtime compatibility.

## Shader tooling

The shared package also provides a macOS CLI for sample renders and GPU regression probes:

```sh
swift build --package-path HolodeckCore -c release --product holodeck-shader-tool
mkdir -p "$HOME/.local/bin"
install HolodeckCore/.build/release/holodeck-shader-tool "$HOME/.local/bin/holodeck-shader-tool"
holodeck-shader-tool --version
holodeck-shader-tool render scene.metal preview.png --time 3
holodeck-shader-tool probe render scene.metal times.json frames.json
```

The CLI shares offscreen rendering, pipeline construction, PNG encoding, and the 16-byte uniform contract with the native loader. `probe compute` accepts two-number sample rows and returns unsigned 32-bit results from `regressionProbe`; `probe render` returns raw float frames, nonfinite counts, and GPU timings. Invalid arguments and GPU failures return nonzero with diagnostics. Gradient fallback is limited to native catalog publication.

HolodeckShaders resolves an installed major-version-1 CLI through `HOLODECK_SHADER_TOOL` set to an absolute executable path, or through `PATH` when no override is set; it does not build a sibling checkout. Its Python callers disconnect stdin and allow 120 seconds per sample render and 300 seconds per probe batch, adjustable through positive finite `HOLODECK_RENDER_TIMEOUT_SECONDS` and `HOLODECK_PROBE_TIMEOUT_SECONDS` values. Version checks have a separate five-second deadline. The CLI is separate from the shipping Mac/TV app targets. GitHub shader publication is retired, with the existing legacy `published` branch frozen.

Generic GPU probe regressions live in HolodeckCore and use self-contained Metal fixtures through `ShaderTool.run`, without an installed CLI or shader checkout. Run them with `HOLODECK_GPU_TESTS=1 swift test --package-path HolodeckCore --filter ShaderToolGPURegressionTests`. Without opt-in they skip; with opt-in, unavailable Metal fails the tests. Tests against HolodeckShaders' actual shared Metal uniform layout and fragment clamp remain there, alongside scene geometry, seed, parser, and long-uptime regressions. CPU geometry and parser tests run without GPU opt-in.
