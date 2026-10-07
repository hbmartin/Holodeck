import Foundation

nonisolated struct ShaderDefinition: Identifiable, Sendable {
    enum Category: String, Sendable {
        case procedural = "PROCEDURAL"
        case material = "3D MATERIAL"
    }

    let id: String
    let title: String
    let category: Category
    let description: String
    let colors: [SIMD3<Float>]
    /// A complete Metal library, including the vertex and fragment entry points.
    let source: String
}

nonisolated enum ShaderCatalog {
    static let shaders: [ShaderDefinition] = [
        effect("plasma", "Plasma", "Liquid color, flowing through an electric field.",
               colors: [SIMD3(0.40, 0.16, 0.96), SIMD3(1.0, 0.28, 0.50)], body: plasma),
        effect("aurora", "Aurora", "Curtains of light beneath a midnight sky.",
               colors: [SIMD3(0.04, 0.72, 0.53), SIMD3(0.17, 0.28, 0.76)], body: aurora),
        effect("waves", "Waves", "Luminous ribbons moving in overlapping tides.",
               colors: [SIMD3(0.03, 0.56, 0.90), SIMD3(0.31, 0.12, 0.72)], body: waves),
        effect("kaleidoscope", "Kaleidoscope", "A shifting mosaic of mirrored color.",
               colors: [SIMD3(0.90, 0.29, 0.16), SIMD3(0.61, 0.13, 0.77)], body: kaleidoscope),
        effect("starfield", "Starfield", "Drift through layers of distant constellations.",
               colors: [SIMD3(0.10, 0.14, 0.35), SIMD3(0.31, 0.40, 0.76)], body: starfield),
        material("chrome", "Chrome", "A polished sphere reflecting a moving light studio.",
                 colors: [SIMD3(0.36, 0.43, 0.53), SIMD3(0.81, 0.87, 0.94)], kind: 0),
        material("brushed-gold", "Brushed Gold", "Warm metal with fine grain and soft reflections.",
                 colors: [SIMD3(0.44, 0.24, 0.07), SIMD3(0.96, 0.71, 0.27)], kind: 1),
        material("iridescent", "Iridescent", "An interference finish that changes with the light.",
                 colors: [SIMD3(0.29, 0.76, 0.77), SIMD3(0.80, 0.27, 0.72)], kind: 2)
    ]

    static var initialShader: ShaderDefinition { shaders[0] }

    private static func effect(_ id: String, _ title: String, _ description: String,
                               colors: [SIMD3<Float>], body: String) -> ShaderDefinition {
        ShaderDefinition(id: id, title: title, category: .procedural,
                         description: description, colors: colors,
                         source: commonSource + body + fragmentEntry)
    }

    private static func material(_ id: String, _ title: String, _ description: String,
                                 colors: [SIMD3<Float>], kind: Int) -> ShaderDefinition {
        let body = materialHelpers + """

        float3 shade(float2 p, float t, float2 pixel) {
            return shadeMaterial(p, t, \(kind));
        }

        """
        return ShaderDefinition(id: id, title: title, category: .material,
                                description: description, colors: colors,
                                source: commonSource + body + fragmentEntry)
    }

    private static let commonSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct ShaderUniforms {
        float2 resolution;
        float time;
        float padding;
    };

    struct RasterData { float4 position [[position]]; };

    vertex RasterData vertexShader(uint id [[vertex_id]]) {
        const float2 positions[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
        RasterData out;
        out.position = float4(positions[id], 0, 1);
        return out;
    }

    float hash21(float2 p) {
        float3 q = fract(float3(p.x, p.y, p.x) * 0.1031);
        q += dot(q, q.yzx + 33.33);
        return fract((q.x + q.y) * q.z);
    }

    float noise2(float2 p) {
        float2 i = floor(p), f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash21(i), hash21(i + float2(1, 0)), f.x),
                   mix(hash21(i + float2(0, 1)), hash21(i + 1.0), f.x), f.y);
    }

    float fbm(float2 p) {
        float result = 0.0, amplitude = 0.5;
        for (int i = 0; i < 4; ++i) {
            result += amplitude * noise2(p);
            p = float2(p.x * 1.6 - p.y * 1.2, p.x * 1.2 + p.y * 1.6) + 5.7;
            amplitude *= 0.5;
        }
        return result;
    }

    float3 palette(float x) {
        return 0.5 + 0.5 * cos(6.2831853 * (x + float3(0.0, 0.33, 0.67)));
    }

    """

    private static let fragmentEntry = """

    fragment float4 fragmentShader(RasterData in [[stage_in]],
                                   constant ShaderUniforms &u [[buffer(0)]]) {
        float2 p = (in.position.xy - u.resolution * 0.5) / max(u.resolution.y, 1.0);
        p.y = -p.y;
        float3 color = shade(p, u.time, in.position.xy);
        return float4(clamp(color, 0.0, 1.0), 1.0);
    }

    """

    private static let plasma = """
    float3 shade(float2 p, float t, float2 pixel) {
        float2 q = p * 5.0;
        float field = sin(q.x + t * 0.7) + sin(q.y * 1.3 - t * 0.5);
        field += sin((q.x + q.y) * 0.8 + t * 0.4);
        field += sin(length(q + float2(sin(t * 0.3), cos(t * 0.4))) * 2.0 - t);
        float3 color = palette(field * 0.14 + t * 0.025);
        return color * (0.55 + 0.45 * smoothstep(-3.0, 3.0, field));
    }

    """

    private static let aurora = """
    float3 shade(float2 p, float t, float2 pixel) {
        float3 sky = mix(float3(0.004, 0.008, 0.035), float3(0.018, 0.045, 0.10), p.y + 0.5);
        float stars = pow(hash21(floor(pixel / 3.0)), 120.0);
        sky += stars * (0.18 + 0.12 * sin(t + hash21(floor(pixel / 3.0)) * 20.0));
        for (int i = 0; i < 3; ++i) {
            float layer = float(i);
            float drift = fbm(float2(p.x * 3.0 + t * 0.06 + layer * 7.0, t * 0.04));
            float center = 0.05 + layer * 0.09 + 0.18 * sin(p.x * 3.0 + drift * 5.0);
            float curtain = exp(-abs(p.y - center) * (9.0 + layer * 3.0));
            float rays = 0.35 + 0.65 * fbm(float2(p.x * 35.0 + layer * 9.0, p.y * 2.0 - t * 0.25));
            float3 tint = mix(float3(0.02, 0.85, 0.38), float3(0.34, 0.10, 0.85), p.y + 0.4);
            sky += tint * curtain * rays * 0.55;
        }
        return sky;
    }

    """

    private static let waves = """
    float3 shade(float2 p, float t, float2 pixel) {
        float3 color = float3(0.005, 0.012, 0.035);
        for (int i = 0; i < 7; ++i) {
            float n = float(i);
            float y = 0.22 * sin(p.x * (3.0 + n * 0.35) + t * 0.65 + n * 0.7);
            y += 0.07 * sin(p.x * 8.0 - t * 0.35 + n) + (n - 3.0) * 0.065;
            float distance = abs(p.y - y);
            float ribbon = exp(-distance * 55.0) + 0.18 * exp(-distance * 12.0);
            color += palette(n * 0.08 + t * 0.015 + p.x * 0.08) * ribbon * 0.55;
        }
        return color;
    }

    """

    private static let kaleidoscope = """
    float3 shade(float2 p, float t, float2 pixel) {
        float radius = length(p);
        float angle = atan2(p.y, p.x) + t * 0.12;
        float sector = 6.2831853 / 10.0;
        angle = abs(fract(angle / sector + 0.5) - 0.5) * sector;
        float2 q = float2(cos(angle), sin(angle)) * radius;
        q = q * 7.0 + float2(t * 0.12, t * -0.08);
        float pattern = sin(q.x * 3.0 + sin(q.y * 4.0)) * cos(q.y * 3.0 - t * 0.5);
        float edges = pow(1.0 - abs(sin(pattern * 4.0 + radius * 12.0)), 5.0);
        return palette(pattern * 0.25 + radius * 0.6 + t * 0.025) * (0.20 + edges * 0.8);
    }

    """

    private static let starfield = """
    float3 shade(float2 p, float t, float2 pixel) {
        float3 color = float3(0.005, 0.008, 0.025);
        float nebula = fbm(p * 3.5 + float2(t * 0.01, 0.0));
        color += float3(0.06, 0.025, 0.12) * pow(nebula, 3.0);
        for (int i = 0; i < 3; ++i) {
            float layer = float(i);
            float scale = 22.0 + layer * 14.0;
            float2 q = p * scale + float2(t * (0.18 + layer * 0.13), t * 0.025);
            float2 cell = floor(q), local = fract(q) - 0.5;
            float seed = hash21(cell + layer * 19.0);
            float2 offset = float2(hash21(cell + 8.3), hash21(cell + 3.1)) * 0.6 - 0.3;
            float distance = length(local - offset);
            float star = exp(-distance * distance * 1800.0) * step(0.78, seed);
            float twinkle = 0.65 + 0.35 * sin(t * 0.8 + seed * 50.0);
            color += mix(float3(0.55, 0.70, 1.0), float3(1.0, 0.76, 0.48), seed) * star * twinkle;
        }
        return color;
    }

    """

    private static let materialHelpers = """
    float3 studioEnvironment(float3 direction, float t, float roughness) {
        float3 color = mix(float3(0.018, 0.026, 0.045), float3(0.32, 0.40, 0.52),
                           smoothstep(-0.4, 0.9, direction.y));
        float3 light = normalize(float3(-0.65 + 0.3 * sin(t * 0.3), 0.7, 0.8));
        float exponent = mix(180.0, 12.0, roughness);
        color += float3(3.2, 3.0, 2.8) * pow(max(dot(direction, light), 0.0), exponent);
        color += float3(0.65, 1.1, 1.8) * pow(max(dot(direction, normalize(float3(0.9, 0.2, -0.6))), 0.0), exponent * 0.5);
        color += float3(0.8) * exp(-abs(direction.x + 0.35) * mix(60.0, 8.0, roughness))
                 * smoothstep(-0.1, 0.3, direction.y);
        return color;
    }

    float sceneDistance(float3 p) {
        return length(p) - 0.85;
    }

    float3 shadeMaterial(float2 p, float t, int kind) {
        float3 origin = float3(0.0, 0.15, 3.4);
        float3 ray = normalize(float3(p * 2.0, -1.8));
        float distance = 0.0;
        bool hit = false;
        for (int stepIndex = 0; stepIndex < 64; ++stepIndex) {
            float stepDistance = sceneDistance(origin + ray * distance);
            if (stepDistance < 0.001) { hit = true; break; }
            distance += stepDistance;
            if (distance > 12.0) break;
        }
        float3 background = float3(0.018, 0.026, 0.045) + float3(0.035, 0.045, 0.065) * exp(-length(p) * 2.0);
        // Intersect the studio floor analytically so the marching limit cannot distort its horizon.
        float floorDistance = ray.y < -0.0001 ? (-1.02 - origin.y) / ray.y : 1e10;
        if (!hit || floorDistance < distance) {
            if (floorDistance >= 12.0) return background;
            float3 position = origin + ray * floorDistance;
            float contact = 0.35 + 0.65 * smoothstep(0.0, 1.8, length(position.xz));
            float grid = 0.5 + 0.5 * cos(position.x * 3.0) * cos(position.z * 3.0);
            float3 floorColor = float3(0.06, 0.075, 0.10) * (0.85 + grid * 0.15) * contact;
            return mix(floorColor, background, smoothstep(3.0, 12.0, floorDistance));
        }

        float3 position = origin + ray * distance;
        float3 normal = normalize(position);
        float facing = max(dot(normal, -ray), 0.0);
        float roughness = kind == 1 ? 0.30 : 0.075;
        float3 base = kind == 1 ? float3(1.0, 0.64, 0.19) : float3(0.72, 0.80, 0.88);
        if (kind == 1) {
            float grain = sin(position.y * 650.0 + noise2(position.xz * 90.0) * 4.0);
            normal = normalize(normal + float3(0.0, grain * 0.018, 0.0));
            base *= 0.93 + grain * 0.07;
        } else if (kind == 2) {
            base = 0.45 + 0.45 * cos(float3(0.0, 2.1, 4.2) + facing * 13.0 + position.y * 3.0);
            roughness = 0.14;
        }
        float3 fresnel = base + (1.0 - base) * pow(1.0 - facing, 5.0);
        float3 reflection = studioEnvironment(reflect(ray, normal), t, roughness);
        float3 lightDirection = normalize(float3(-0.6, 0.8, 1.0));
        float diffuse = max(dot(normal, lightDirection), 0.0);
        float3 color = reflection * fresnel + base * (0.06 + diffuse * 0.12);
        return color / (1.0 + color);
    }

    """
}
