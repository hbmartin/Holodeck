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

The Mac loads this folder at startup and when you press **Reload Shaders**. Symlinks and special files are rejected; every source component must be UTF-8. Directory edits remain unpublished until reload. A complete candidate is validated before replacing the current immutable, app-owned publication. Revisions hash the exact sorted-key schema-2 manifest bytes; update dates use authoring-file modification times. Collections, discovery labels, and source comments are preserved. Previews render at 1280×720 and three seconds; failed renders use metadata-color gradients with per-shader diagnostics in Settings, and reload retries them. Sharing continues with the viewer window closed, stops during sleep or quit, and resumes after wake.

The TV browses `_holodeck._tcp` in Bonjour's `local.` domain. One Mac connects automatically; several Macs show a chooser. A remembered Mac is retained when unavailable. If alternatives remain available for five seconds while no connection or pairing is viable, the TV opens the chooser once for that absence. **Change Mac** also allows an explicit switch; discovery churn does not close a working connection. On first connection, compare the six-digit code on TV with **Settings → Shader Library** on Mac and click **Approve**. The code comes from that TLS connection. A persistent Mac public-key pin and random per-TV Keychain credential authenticate later connections. **Revoke** stops further downloads; cached playback remains usable. The TV removes the revoked token from its saved pairing while retaining the Mac selection and public-key pin.

All TV catalog, source, and preview requests travel through the selected Mac over TLS 1.3. Service and address resolution use multicast-only DNS-SD, connections require a private or link-local numeric address on the discovered interface, and certificate network fetching is disabled. There are no runtime GitHub downloads or public-network fallback paths. The certificate-generation library is linked only on Mac.

TV refreshes run at launch, foreground return, reconnection, and **Check for Scene Updates**. Ordinary attempts retain the existing 15-minute monotonic throttle; reconnection and explicit checks bypass it. Catalog requests coalesce, transfers are bounded and time out after 30 seconds, idle connections use TCP keepalive, unauthenticated connections expire five minutes after acceptance, hashes are checked, and the complete TV cache is written atomically. Revision-specific allowlisted assets stay available during active downloads across reloads.

The app ships with no shader assets. Verified schema-2 caches remain playable offline after upgrade. Older local cache formats and 40-character publications are rejected without migration; rebuild the library from the authoring folder when available. TV starts cached playback before checking the Mac. With no cache, configure and open the Mac app, allow local-network access, and approve the TV. TV keeps its active pipeline across updates; changed source takes effect on selection or subsequent launch. Missing previews use gradients. The Mac retains its source-replacement behavior. tvOS can evict cache files, requiring another local download.

Preview downloads coalesce by hash. Actor-owned LRU caches hold up to 16 MiB of verified encoded data and 32 MiB of decoded images; memory hits skip disk reads, hashing and decoding. ImageIO runs on a separate worker queue with at most two concurrent decodes, leaving the catalog actor responsive. TV aspect-fill thumbnails use laid-out card bounds, display scale and the 1.045 focus enlargement, rounding upward in 64-pixel buckets with a 2048-pixel cap; Mac previews use 176 pixels. Resizing or a larger scale retains the displayed image until its replacement succeeds. Metadata and publication changes retain images whose hashes have not changed.

Connectivity-related preview failures wait for connection recovery and retry immediately when it succeeds. Other failed preview downloads retry on demand after 30 seconds, doubling to a five-minute ceiling. An unavailable asset fails only its request and keeps the connection alive. Hash/signature and decode failures are suppressed for that publication, path and hash until a new publication or service instance. At most 500 failure records are retained. Memory warnings on TV and warning/critical memory pressure on Mac clear both memory caches while retaining catalog state, disk files and retry records. In-flight requests still complete, but work started before trimming cannot refill the caches.

`ShaderCompiler` compiles complete source libraries on its actor executor, with the existing `vertexShader`, `fragmentShader` and 16-byte buffer-0 uniform contract. Pipelines are cached by shader ID and source hash; selecting a revised shader recompiles it. Only the latest selection can activate a pipeline. Compilation diagnostics go to the console; the picker reports failures and allows another selection.

## Shader requests from Apple TV

During playback, Select offers **Gallery** (default focus) or **Input**. Input captures the actual shader source, metadata, clean frame and animation time before opening system text entry. An approved TV can submit an independent request, answer clarifications and receive the resulting shader. Manual requests keep playback running with progress and lock browsing while connected; cached browsing returns during a Mac outage.

Enable requests in **Mac Settings → Codex Shader Requests** after choosing a clean, existing checkout with authoring schema 1 and the script-free migration on `origin/main`. Select a model explicitly; High reasoning is the default. Setup verifies Codex login, model/image/JSON compatibility, Git access and identity, Python and both Metal SDK compilers. The app bundles its rendering CLI. Enabling makes this checkout app-managed; source work must already be committed on remote main. Model/reasoning settings belong to Holodeck and are captured with each request.

One persistent worker implements or repairs a shader, checks allowed files, independently invokes the bundled authoring checker for provenance, CPU/GPU profiles and macOS/tvOS compilation, renders source-bound 1280×720 samples at 0, 3 and 10 seconds, and obtains a separate read-only AI image verdict. New shaders get unused IDs; edits keep their IDs. Shared helper changes trigger review of every affected shader. The host commits and pushes normally to main, repeats verification after push races, and installs a prepared catalog only after a successful push. Completion waits for TV download and activation; an unchanged request avoids an empty commit.

Host Git operations skip local hooks through per-command overrides and compare the committed file bytes with the verified candidate before pushing. Unrelated checkout transformations are supported, while source/index/metadata transformations and submodules are rejected. Each attempt checks pristine main before invoking Codex. Failed technical/render checks are repeated against the baseline to distinguish shader defects from host or baseline failures: shader defects keep repairing without an attempt limit, while operational failures terminate with retained diagnostics and owned-work cleanup. Activation repairs retain previous publications separately from the current attempt, including recovery after a lost push acknowledgement. Output and source-affected shaders require successful previews; unrelated preview warnings remain visible in Settings. A worker interrupted by sleep resumes from its checkpoint even if wake occurs before its exit is observed.

When cleanup fails, **Settings → Checkout Recovery** allows correcting the owned repository and Python/Git paths and retrying. **Detach Checkout** disables requests and retains unpublished files and evidence. Detachment is remembered independently of request records and survives their deletion and app restarts. To reuse that checkout, make it clean and run **Verify Setup and Enable**; setup takes its lease and retires only the acknowledged owner marker after every check succeeds. Reuse requires the original canonical repository path and, when recorded, the acknowledged checkout ID; aliases resolving to that path work. A copied or moved folder cannot consume the original acknowledgement, and a moved detached folder must return to its original location before reuse. Foreign owners remain rejected.

Startup restores a valid cache before activating ordinary queued requests, rebuilding when needed after interrupted-owner recovery and cleanup. **Rebuild Library** always prepares a fresh schema-2 publication from clean local `main` under the checkout lease, without fetching, switching branches, or invoking Codex. Recorded recovery failures end the publication call with a visible error and release the reload indicator. After successful recovery, the service automatically retries the remembered publication before ordinary queued jobs, preserving a forced rebuild. The error remains visible while retrying; a further operational failure ends that attempt for explicit retry. Retry intent is session-local and is cleared by disabling requests, detachment or checkout replacement.

Ignored files are outside host enforcement: their additions, edits and deletions are neither inventoried nor restored or removed. Every actual publication input must still be verified and present in the commit; the host never force-adds ignored files.

**HolodeckMac → Shader Requests** opens the queue, outcomes, commits, live logs and retained verification frames. Only queued work can be cancelled. Records and evidence remain until Delete Record. The worker parks clarification and activation waits, prioritizes manual jobs over automatic ones, and recovers owned patches, CLI sessions and remote commit state after interruption.

Foreground TV playback targets up to 30 fps at native resolution, adjusted to a compatible display cadence. After two warm-up seconds, ten continuous seconds below 90% of that attainable cadence request a visual-preserving optimization. Performance jobs allow browsing and only switch the scene if it is still active. A slow result offers Retry or Dismiss. tvOS omits Metal's drawable-presentation callback: telemetry consumes completed GPU frames on display ticks, counting at most one update per tick and reporting GPU time separately. It is an estimate of delivered updates, not direct compositor presentation timestamps. Performance evidence informs optimization and does not gate commits.

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

The shared package provides a macOS CLI for native renders/probes and library verification through its bundled [HolodeckShaderCheck](https://github.com/hbmartin/HolodeckShaderCheck) artifact. Version 1.1.0 adds the `library` interface without changing raw render/probe syntax.

```sh
swift build --package-path HolodeckCore -c release --product holodeck-shader-tool --force-resolved-versions
mkdir -p "$HOME/.local/bin"
task_shader_tool_bin=$(swift build --package-path HolodeckCore -c release --show-bin-path --force-resolved-versions)
install "$task_shader_tool_bin/holodeck-shader-tool" "$HOME/.local/bin/holodeck-shader-tool"
ditto "$task_shader_tool_bin/HolodeckCore_HolodeckCore.bundle" "$HOME/.local/bin/HolodeckCore_HolodeckCore.bundle"
holodeck-shader-tool --version
holodeck-shader-tool library info --json
holodeck-shader-tool library validate /path/to/HolodeckShaders --compile
holodeck-shader-tool library validate /path/to/HolodeckShaders --gpu
holodeck-shader-tool library render /path/to/HolodeckShaders shader plasma --times 0,3,10
holodeck-shader-tool render scene.metal preview.png --time 3
holodeck-shader-tool probe render scene.metal times.json frames.json
```

Use Xcode 27 / Swift 6.4 for the checked-in native dependency graph and keep resolved dependency versions frozen. Library CI runs portable CPU checks on Linux; macOS/tvOS compilation and GPU checks run explicitly on a local Mac.

Install the resource bundle beside the executable; a bare binary remains sufficient only for the legacy raw GPU commands. Mac app packaging copies both automatically. Library commands use checker 1.0.3 and verify the bundled zipapp against `shader_checker.lock.json` (release, source commit, interface and SHA-256), then launch isolated Python with disconnected stdin. They accept `--python /absolute/interpreter`, defaulting to `/usr/bin/python3` (3.9 or later). No downloads, package installation, sibling checkout or candidate-checkout Python imports occur at runtime. Missing, modified or incompatible checker resources return exit 2. The checker release, its checksum and the shader library's matching checker lock must be updated together; copy a verified release artifact without rebuilding or editing its bytes.

`library` forwards `info`, `validate`, `assemble`, and `render` to the checker. Static validation includes provenance, unlisted assets, temporary template instances and CPU profiles; `--compile` adds every shader/snippet and shader/snippet template for macOS and tvOS, and `--gpu` adds compilation plus actual GPU profiles. The native CLI supplies its own executable as the GPU backend, using raw `render`/`probe` calls to prevent delegation loops. Checker exit codes remain 0 (pass), 1 (failed checks), and 2 (usage/tooling). Static checks also run independently through the checker zipapp or wheel without Metal, Xcode or Holodeck.

The CLI shares offscreen rendering, pipeline construction, PNG encoding, and the 16-byte uniform contract with the native loader. `probe compute` accepts two-number sample rows and returns unsigned 32-bit results from `regressionProbe`; `probe render` returns raw float frames, nonfinite counts, and GPU timings. GPU failures return nonzero with diagnostics. Gradient fallback is limited to native catalog publication.

The standalone checker resolves a major-version-1 GPU backend through an explicit absolute `--shader-tool` path, `HOLODECK_SHADER_TOOL`, or PATH. Invalid explicit overrides do not fall back. Version checks disconnect stdin and retain a five-second deadline. Each sample render has a 120-second deadline and each probe batch 300 seconds; positive finite `HOLODECK_RENDER_TIMEOUT_SECONDS` and `HOLODECK_PROBE_TIMEOUT_SECONDS` override operation deadlines. App-managed request validation uses the bundled checker and the configured Python interpreter, with existing host cancellation and baseline/candidate classification.

Generic GPU tests remain in HolodeckCore: `HOLODECK_GPU_TESTS=1 swift test --package-path HolodeckCore --filter ShaderToolGPURegressionTests`. Real-library shared contracts, geometry, exact numeric parsing, seed and long-uptime oracles live in HolodeckShaderCheck and are selected by `authoring.json` profiles. Its integration tests use an explicit library root.

For the script-free authoring cutover, drain active requests and update the app before switching the managed checkout. The worker checks checker interface 1 and authoring schema 1 instead of requiring repository scripts. Its provenance boundary permits scoped additions to `sourceRequirements`/`upstreamRequirements`, preserving existing obligations, upstream definitions and profile/schema settings. Older request workers require the previous library checkout; ordinary catalog loading remains compatible. GitHub shader publication remains retired.
