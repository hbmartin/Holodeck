# Holodeck

A Metal showcase for tvOS 26.0 and later with five animated procedural effects and three ray-marched material spheres. Shaders are downloaded as Metal source and compiled at runtime; no precompiled Metal library is required.

## Controls

- Launch restores the last successfully activated shader full screen. A first launch downloads the catalog before starting its default shader (currently Plasma). A saved ID no longer in the catalog also resolves to its default. If a remembered shader fails to compile, the picker reports the error and keeps that saved ID until another shader succeeds.
- Press **Select** to open the shader picker, use directional input to browse, and press **Select** to load a shader.
- **Back** dismisses the picker. While a shader is loading, the current one keeps running. Dismissing a pending selection retains the current shader.
- During startup, Back leaves the startup shader loading and restores its loading hint. If you dismiss a different pending selection before any shader is active, that selection is canceled and the resolved startup shader loads again. Reopening the picker focuses the active shader; compilation results and interruptions preserve your place while browsing.
- Animation and drawing pause when the scene becomes inactive.

## Shader catalog

See [Shader repositories and catalog workflow](docs/shader-catalog-workflow.md) for the repository relationship, an add-a-shader walkthrough, and publishing and runtime control-flow diagrams.

[HolodeckShaders](https://github.com/hbmartin/HolodeckShaders) owns shader bodies, shared Metal helpers, metadata and generated previews. Its publishing workflow validates content and tvOS Metal compilation before replacing the public `published` branch with one complete snapshot. Follow that repository's authoring instructions to add a shader; no app release is needed for catalog updates.

The app resolves `published` to a commit, then downloads the manifest and sources at that exact revision. It validates schema version 1, metadata, unique IDs, paths, dates and SHA-256 hashes before atomically caching and activating a snapshot. Failed refreshes retain the previous catalog. Refreshes run in the background at launch and foreground return, throttled to once per 15 minutes once a usable catalog exists, including failed refresh attempts. With an empty cache, Select retries a failed download immediately. GitHub rate limits and network errors leave offline content usable.

The app ships with no shader catalog, source or preview images. Startup uses the most recent valid downloaded disk snapshot. If no valid cache exists, the app shows “Downloading shaders…”; a connection failure asks the user to connect and press Select to retry. First launch requires internet. Cached sources remain available offline, but tvOS may evict cache files, in which case a new download is required. The picker updates names, previews and localized update dates while preserving focus by shader ID. The active shader continues until a new selection; if it disappears from the catalog, it can finish playing and the next launch uses the catalog default. Images load asynchronously, are cached by hash, and fall back to card gradients when unavailable.

`ShaderCompiler` compiles complete source libraries on its actor executor, with the existing `vertexShader`, `fragmentShader` and 16-byte buffer-0 uniform contract. Pipelines are cached by shader ID and source hash; selecting a revised shader recompiles it. Only the latest selection can activate a pipeline. Compilation diagnostics go to the console; the picker reports failures and allows another selection.

## Dependencies

Runtime services use Point-Free's `swift-dependencies` through internal `DependencyValues` keys: Metal device, renderer factory, shader compiler factory, monotonic animation time, and shader preferences. The catalog service additionally injects networking, disk storage and refresh time; tests use recorded repository content in test-only resources with networking disabled or stubbed. These fixtures are linked only to test targets and excluded from the shipping app; UI tests inject them through their launch environment, including empty-cache download and retry scenarios. The startup hint uses the built-in continuous clock. The scene constructs the storyboard controller in a dependency scope; the controller propagates that scope to its renderer and tasks. The renderer retains its compiler and time closure rather than resolving dependencies on each frame.

Preferences store `holodeck.lastShaderID` in UserDefaults only after a current selection activates successfully. Canceled, superseded, and failed selections leave the saved ID untouched. Tests override dependencies before controller construction, use a TestClock and isolated preferences, and explicitly opt into real GPU compilation where required. UI tests use a separate UserDefaults suite per test, including a relaunch test that reuses its suite.

## Validation

Run the Holodeck scheme's tests on a tvOS 26 or later Apple TV simulator. The unit tests compile all eight shaders, render floating-point frames, check coverage and animation, and save PNG attachments. Catalog tests verify pinned downloads, a ninth shader, schema and asset rejection, atomic cache writes, offline cached startup, first-launch download and retry, refresh throttling, image hashes and revised-source compilation. They also verify cache reuse, uniform layout, stale selections, failure recovery, and paused time. UI tests exercise all eight selections, focus restoration, Back dismissal, and background/resume, with screenshots saved in the test result bundle.

```sh
xcodebuild -project Holodeck.xcodeproj -scheme Holodeck \
  -sdk appletvsimulator \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' \
  -parallel-testing-enabled NO test
```

The minimum deployment target is tvOS 26.0. Verify shader rendering, remote navigation, and background/resume on tvOS 26 before release.
