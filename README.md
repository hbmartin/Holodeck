# Holodeck

A tvOS 27 Metal showcase with five animated procedural effects and three ray-marched material spheres. All shaders are Swift strings compiled at runtime; no precompiled Metal library is required.

## Controls

- Launch opens Plasma full screen.
- Press **Select** to open the shader picker, use directional input to browse, and press **Select** to load a shader.
- **Back** dismisses the picker. While a shader is loading, the current one keeps running. Dismissing a pending selection retains the current shader.
- Animation and drawing pause when the scene becomes inactive.

## Adding a shader

The catalog is in `Holodeck/ShaderCatalog.swift`. Add an `effect(...)` entry with a unique ID, title, description, two card colors, and a multiline Metal body. The shared source supplies the full-screen vertex shader, uniforms, noise helpers, and fragment entry point. Your body implements:

```metal
float3 shade(float2 p, float time, float2 pixel) {
    return palette(length(p) - time * 0.1);
}
```

`p` is centered with positive Y pointing up, measured relative to drawable height so proportions survive size changes. `pixel` is the fragment's pixel coordinate. Return linear RGB; the fragment entry clamps it and writes opaque alpha to an sRGB drawable.

For a completely self-contained implementation, add a `ShaderDefinition` whose `source` contains `vertexShader` and `fragmentShader`. The vertex entry generates a triangle using `vertex_id`, and the fragment entry receives this uniform block at buffer index 0:

```metal
struct ShaderUniforms {
    float2 resolution; // Drawable size in pixels
    float time;        // Active animation seconds since selection
    float padding;
};
```

`ShaderCompiler` compiles source and creates pipelines on its actor executor. Pipelines are cached by the immutable catalog ID for the process lifetime. Only the latest selection can activate a completed pipeline. Compilation diagnostics go to the console; the picker reports failures and allows another selection.

## Validation

Run the Holodeck scheme's tests on a tvOS 27 Apple TV simulator. The unit tests compile all eight shaders, render floating-point frames, check coverage and animation, and save PNG attachments. They also verify cache reuse, uniform layout, stale selections, failure recovery, and paused time. UI tests exercise all eight selections, focus restoration, Back dismissal, and background/resume, with screenshots saved in the test result bundle.

```sh
xcodebuild -project Holodeck.xcodeproj -scheme Holodeck \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' \
  -parallel-testing-enabled NO test
```

The connected Arrowhead device currently runs tvOS 26.6 and cannot run this app's retained tvOS 27.0 target.
