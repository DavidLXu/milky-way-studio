#include <metal_stdlib>
using namespace metal;

// -----------------------------------------------------------------------------
// Shared layouts. Keep these in sync with ShaderTypes.swift.
// -----------------------------------------------------------------------------

struct SceneUniforms {
    float4 resolution;       // width, height, 1/width, 1/height
    float4 cameraPos;        // xyz, pattern angle
    float4 cameraRight;      // xyz, tanHalfFov
    float4 cameraUp;         // xyz, aspect
    float4 cameraForward;    // xyz, time (Myr)
    float4 params0;          // dust, ---, ---, ---
    float4 params1;          // exposure, brightness, ---, ---
    float4 params2;          // steps, sampleIndex, seed, outputSRGB
    float4 params3;          // BH: temperature, brightness, disk outer, doppler
    float4 params4;          // BH: jets, unused, unused, unused
};

struct CompositeUniforms {
    float4 resolution;       // width, height, 1/width, 1/height
    float4 params0;          // exposure, bloom, vignette, grain
    float4 params1;          // sampleCount, time, chromatic, outputSRGB
    float4 params2;          // x: BH soft-focus radius (1080p-relative pixels)
};

struct BloomUniforms {
    float4 texel;            // 1/w, 1/h, directionX, directionY
    float4 params;           // mode, threshold, knee, sampleScale
};

struct BuildUniforms {
    float4 params;           // seed, arm boost, dust boost, time
};

struct VOut {
    float4 position [[position]];
    float2 uv;
};

// -----------------------------------------------------------------------------
// Full screen triangle
// -----------------------------------------------------------------------------

vertex VOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    VOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

// -----------------------------------------------------------------------------
// Noise
// -----------------------------------------------------------------------------

static inline float hash31(float3 p3) {
    p3 = fract(p3 * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static inline float hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static inline float2 hash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

static inline float vnoise(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = hash31(i + float3(0.0, 0.0, 0.0));
    float n100 = hash31(i + float3(1.0, 0.0, 0.0));
    float n010 = hash31(i + float3(0.0, 1.0, 0.0));
    float n110 = hash31(i + float3(1.0, 1.0, 0.0));
    float n001 = hash31(i + float3(0.0, 0.0, 1.0));
    float n101 = hash31(i + float3(1.0, 0.0, 1.0));
    float n011 = hash31(i + float3(0.0, 1.0, 1.0));
    float n111 = hash31(i + float3(1.0, 1.0, 1.0));
    float nx00 = mix(n000, n100, f.x);
    float nx10 = mix(n010, n110, f.x);
    float nx01 = mix(n001, n101, f.x);
    float nx11 = mix(n011, n111, f.x);
    float nxy0 = mix(nx00, nx10, f.y);
    float nxy1 = mix(nx01, nx11, f.y);
    return mix(nxy0, nxy1, f.z);
}

static inline float fbm3(float3 p, int octaves) {
    float sum = 0.0;
    float amp = 0.5;
    for (int i = 0; i < octaves; ++i) {
        sum += amp * vnoise(p);
        p = p * 2.03 + float3(11.7, 5.3, 17.1);
        amp *= 0.5;
    }
    return sum;
}

static inline float vnoisePeriodic(float3 p, int period) {
    int3 i = int3(floor(p));
    float3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);

    int3 i000 = ((i + int3(0, 0, 0)) % period + period) % period;
    int3 i100 = ((i + int3(1, 0, 0)) % period + period) % period;
    int3 i010 = ((i + int3(0, 1, 0)) % period + period) % period;
    int3 i110 = ((i + int3(1, 1, 0)) % period + period) % period;
    int3 i001 = ((i + int3(0, 0, 1)) % period + period) % period;
    int3 i101 = ((i + int3(1, 0, 1)) % period + period) % period;
    int3 i011 = ((i + int3(0, 1, 1)) % period + period) % period;
    int3 i111 = ((i + int3(1, 1, 1)) % period + period) % period;

    float n000 = hash31(float3(i000));
    float n100 = hash31(float3(i100));
    float n010 = hash31(float3(i010));
    float n110 = hash31(float3(i110));
    float n001 = hash31(float3(i001));
    float n101 = hash31(float3(i101));
    float n011 = hash31(float3(i011));
    float n111 = hash31(float3(i111));

    float nx00 = mix(n000, n100, f.x);
    float nx10 = mix(n010, n110, f.x);
    float nx01 = mix(n001, n101, f.x);
    float nx11 = mix(n011, n111, f.x);
    float nxy0 = mix(nx00, nx10, f.y);
    float nxy1 = mix(nx01, nx11, f.y);
    return mix(nxy0, nxy1, f.z);
}

static inline float fbmTile(float3 uv, int basePeriod, int octaves) {
    float sum = 0.0;
    float amp = 0.5;
    int period = basePeriod;
    for (int i = 0; i < octaves; ++i) {
        sum += amp * vnoisePeriodic(uv * float(period), period);
        period *= 2;
        amp *= 0.5;
    }
    return sum;
}

static inline float wrapPi(float x) {
    return x - 6.28318530718 * floor((x + 3.14159265359) / 6.28318530718);
}

static inline float luminance(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

static inline float3 blackbodyTint(float t) {
    // Artistic blackbody approximation, t in 0..1 (cool -> hot).
    float3 cool = float3(1.00, 0.48, 0.22);
    float3 solar = float3(1.00, 0.90, 0.72);
    float3 hot = float3(0.62, 0.76, 1.00);
    if (t < 0.5) {
        return mix(cool, solar, smoothstep(0.0, 0.5, t));
    }
    return mix(solar, hot, smoothstep(0.5, 1.0, t));
}

// -----------------------------------------------------------------------------
// Galaxy volume construction
// -----------------------------------------------------------------------------

kernel void build_detail(texture3d<float, access::write> outTex [[texture(0)]],
                         uint3 gid [[thread_position_in_grid]]) {
    const uint dim = 128;
    if (gid.x >= dim || gid.y >= dim || gid.z >= dim) return;

    float3 uv = (float3(gid) + 0.5) / float(dim);
    float r = fbmTile(uv, 4, 4);
    float g = fbmTile(uv + float3(0.17, 0.31, 0.07), 8, 3);
    float b = fbmTile(uv + float3(0.53, 0.11, 0.37), 16, 2);
    float a = hash31(float3(gid) * 1.371 + 0.5);
    outTex.write(float4(r, g, b, a), gid);
}

kernel void build_galaxy(texture3d<float, access::write> outTex [[texture(0)]],
                         constant BuildUniforms &u [[buffer(0)]],
                         uint3 gid [[thread_position_in_grid]]) {
    const uint W = 640;
    const uint H = 320;
    const uint D = 640;
    if (gid.x >= W || gid.y >= H || gid.z >= D) return;

    // Volume bounds: x,z in [-26,26], y in [-4,4]. The galaxy fades out
    // several kpc before the texture edge so the sampling box is never visible.
    float3 p = float3(
        (float(gid.x) + 0.5) / float(W) * 52.0 - 26.0,
        (float(gid.y) + 0.5) / float(H) * 8.0 - 4.0,
        (float(gid.z) + 0.5) / float(D) * 52.0 - 26.0
    );

    const float PI = 3.14159265359;
    float r = max(length(p.xz), 0.001);
    float phi = atan2(p.z, p.x);

    // A gentle, flared, warped disk.
    float warp = 0.24 * pow(r / 16.0, 1.7) * sin(phi + 0.65);
    float y = p.y - warp;
    float hz = 0.235 + 0.0140 * r;
    float thick = 4.5;

    float thinZ = exp(-0.5 * pow(y / hz, 2.0));
    float thickZ = exp(-0.5 * pow(y / (hz * thick), 2.0));
    float disk = exp(-r / 3.10) * (0.88 * thinZ + 0.12 * thickZ);
    disk *= 1.0 - smoothstep(12.5, 19.5, r);

    // Central bulge and bar.
    float rb = sqrt(pow(p.x / 1.48, 2.0) + pow(p.z / 1.15, 2.0) + pow(y / 0.66, 2.0));
    float bulge = exp(-2.15 * pow(rb, 0.62));
    float nucleus = exp(-7.0 * rb);

    float barAngle = 1.02;
    float2 bq = float2(cos(barAngle) * p.x + sin(barAngle) * p.z,
                       -sin(barAngle) * p.x + cos(barAngle) * p.z);
    float barR = sqrt(pow(bq.x / 3.25, 2.0) + pow(bq.y / 0.72, 2.0));
    float bar = (1.0 - smoothstep(0.35, 1.10, barR)) *
                exp(-0.5 * pow(y / 0.46, 2.0));
    float barLane = exp(-0.5 * pow(bq.y / 0.30, 2.0)) *
                    exp(-0.5 * pow(bq.x / 2.8, 2.0)) *
                    exp(-0.5 * pow(y / 0.10, 2.0));

    float n1 = fbm3(float3(p.x * 0.31, y * 1.22, p.z * 0.31) + float3(2.7, 0.3, 4.1), 3);
    float n2 = fbm3(float3(p.x * 0.92, y * 2.7, p.z * 0.92) + float3(9.2, 5.1, 1.8), 3);
    float n3 = vnoise(float3(p.x * 3.4, y * 7.5, p.z * 3.4) + float3(4.1, 2.2, 7.9));
    float n4 = vnoise(float3(p.x * 8.2, y * 15.0, p.z * 8.2) + float3(1.3, 6.8, 3.2));

    // Two dominant density-wave arms plus a weaker pair. The arms are broad
    // and clumpy; a second, much broader component fills the inter-arm disk.
    float pitchA = tan(24.0 * PI / 180.0);
    float pitchB = tan(31.0 * PI / 180.0);
    float baseA = phi + log(max(r, 1.8) / 3.2) / pitchA;
    float baseB = phi + log(max(r, 1.8) / 3.2) / pitchB;
    float phaseA = 2.0 * baseA + 4.24;
    float phaseB = 2.0 * baseB + 4.24 + PI;

    float armWidthA = (0.195 + 0.115 * smoothstep(3.0, 15.0, r)) * (0.80 + 0.48 * n2);
    float armWidthB = (0.175 + 0.100 * smoothstep(3.0, 15.0, r)) * (0.82 + 0.44 * n2);
    float dA = wrapPi(phaseA + (n1 - 0.5) * 0.58 + (n2 - 0.5) * 0.20);
    float dB = wrapPi(phaseB + (n2 - 0.5) * 0.46);
    float armA = exp(-0.5 * pow(dA / armWidthA, 2.0));
    float armB = exp(-0.5 * pow(dB / armWidthB, 2.0));

    // A broad, dusty envelope around each arm.
    float broadA = exp(-0.5 * pow(dA / (armWidthA * 2.25), 2.0));
    float broadB = exp(-0.5 * pow(dB / (armWidthB * 2.15), 2.0));
    float armEnv = smoothstep(0.8, 2.2, r) * (1.0 - smoothstep(13.0, 18.8, r));
    float armMask = max(armA, 0.70 * armB) * armEnv;
    float broadMask = max(broadA, 0.68 * broadB) * armEnv;

    // A patchy inner spiral / nuclear dust lane helps fill the core.
    float pitchI = tan(24.0 * PI / 180.0);
    float phaseI = 2.0 * (phi + log(max(r, 0.7) / 1.25) / pitchI) + 0.5;
    float dI = wrapPi(phaseI + (n1 - 0.5) * 0.55);
    float innerArm = exp(-0.5 * pow(dI / 0.30, 2.0)) *
                     smoothstep(0.55, 1.2, r) * (1.0 - smoothstep(4.0, 6.8, r));

    // Inter-arm flocculence: cloud complexes, spurs and feathers.
    float floc = smoothstep(0.38, 0.80, n2 * 0.58 + n3 * 0.27 + n4 * 0.15);
    float cloudPatch = smoothstep(0.50, 0.84, n4 * 0.55 + n3 * 0.45);
    float spur = smoothstep(0.52, 0.86, n4) * smoothstep(0.30, 0.68, n2);

    // Feathery star-forming clumps along the arms.
    float clump = smoothstep(0.30, 0.76, n2 * 0.60 + n3 * 0.28 + n4 * 0.12);
    float young = armMask * (0.18 + 2.80 * clump) + broadMask * 0.22 + innerArm * 0.55;
    float hiiNoise = vnoise(float3(p.x * 8.5, y * 16.0, p.z * 8.5) + float3(17.0, 2.4, 5.1));
    float hii = smoothstep(0.665, 0.855, hiiNoise) * pow(max(armMask, innerArm * 0.8), 1.9);
    hii *= smoothstep(0.28, 0.66, n2) * smoothstep(0.38, 0.72, clump);
    hii *= pow(thinZ, 1.35);

    // Dust lanes on the inner edge of both arm systems, plus a broad dusty
    // envelope and cold clouds that fill the disk.
    float laneA = exp(-0.5 * pow(wrapPi(phaseA - 0.48 + (n2 - 0.5) * 0.38) / 0.100, 2.0));
    float laneB = exp(-0.5 * pow(wrapPi(phaseB - 0.46 + (n2 - 0.5) * 0.40) / 0.092, 2.0));
    float lane = max(laneA, 0.70 * laneB);
    lane *= smoothstep(2.0, 3.5, r) * (1.0 - smoothstep(14.5, 19.0, r));

    float dustBase = 0.075 * exp(-r / 3.7) * exp(-0.5 * pow(y / 0.145, 2.0));
    float dustArm = 60.0 * lane * exp(-0.5 * pow(y / 0.095, 2.0)) * (0.35 + 1.25 * n2);
    float dustBroad = 1.2 * broadMask * exp(-0.5 * pow(y / 0.180, 2.0)) * (0.35 + 1.10 * n3);
    float dustInner = 16.0 * innerArm * exp(-0.5 * pow(y / 0.095, 2.0)) * (0.3 + n2);
    float dustFloc = 0.8 * floc * exp(-0.5 * pow(y / 0.200, 2.0)) * (0.35 + n4);
    float dustCloud = 3.2 * cloudPatch * disk * (0.25 + 1.4 * n4);
    float dustSpur = 3.0 * spur * disk * (0.3 + n3);
    float dustRing = 4.0 * exp(-pow((r - 2.95) / 0.34, 2.0)) * exp(-0.5 * pow(y / 0.11, 2.0));
        // Cold, filamentary clouds give the disk its patchy, dusty texture.
    float cloudN = fbm3(float3(p.x * 3.10, y * 8.5, p.z * 3.10) + float3(31.0, 4.0, 12.0), 4);
    float filN = 1.0 - abs(2.0 * fbm3(float3(p.x * 1.45, y * 4.6, p.z * 1.45) + float3(6.2, 8.4, 19.0), 3) - 1.0);
    float cloudMask = smoothstep(0.55, 0.84, cloudN) * smoothstep(0.18, 0.72, n2);
    float filament = pow(filN, 3.5) * smoothstep(0.22, 0.78, n3);
    float dustCloudy = (5.0 * cloudMask + 3.0 * filament) *
                       exp(-0.5 * pow(y / 0.135, 2.0)) *
                       (0.35 + 0.90 * disk);

    float dust = (dustBase + dustArm + dustBroad + dustInner + dustFloc +
                  dustCloud + dustSpur + dustRing + dustCloudy +
                  10.0 * barLane * (0.4 + n2)) *
                 (0.32 + 1.15 * n3);

    float veil = smoothstep(0.46, 0.78, n3 * 0.55 + n2 * 0.45);
    dust += 2.0 * veil * armMask * exp(-0.5 * pow(y / 0.11, 2.0));
    dust *= 0.22 + 1.55 * pow(n4, 0.95);
    dust = clamp(dust, 0.0, 110.0);

    // Stellar populations: warm old disk, golden bulge, blue arms, pink HII.
    float3 cOld = float3(1.00, 0.47, 0.19);
    float3 cDisk = float3(1.00, 0.69, 0.43);
    float3 cYoung = float3(0.34, 0.55, 1.00);
    float3 cHII = float3(1.00, 0.095, 0.225);
    float3 cBar = float3(1.00, 0.62, 0.32);

    float oldDisk = disk * (0.66 + 0.50 * n1) * (1.0 - 0.60 * armMask);
    float broadLight = disk * broadMask * 0.18;
    float armLight = exp(-r / 3.10) * thinZ * young * 3.8;
    cDisk = mix(cDisk, float3(0.70, 0.79, 1.00), smoothstep(5.0, 16.0, r) * 0.30);
    float flocLight = disk * floc * 0.30;
    float centralFade = smoothstep(0.7, 3.2, r);
    float hiiLight = hii * 18.0 * centralFade;

    float3 emit = float3(0.0);
    emit += cOld * bulge * 3.5;
    emit += float3(1.00, 0.78, 0.52) * nucleus * 1.6;
    emit += cBar * bar * 1.40;
    emit += cDisk * oldDisk * 0.48;
    emit += cDisk * broadLight * centralFade;
    float cloudGlow = smoothstep(0.34, 0.72, n2 * 0.72 + n1 * 0.28) * disk;
    emit += mix(cDisk, cYoung, 0.42) * cloudGlow * 1.55 * centralFade;
    emit += cYoung * armLight * centralFade;
    emit += mix(cDisk, cYoung, 0.45) * flocLight * centralFade;

    // Dense sub-resolution star clouds and clusters make the disk granular,
    // especially in the edge-on view.
    float tinyStars = pow(smoothstep(0.48, 0.92, n4), 3.0) * disk;
    emit += float3(0.62, 0.78, 1.00) * tinyStars * 0.8 * centralFade;

    float clusters = pow(smoothstep(0.56, 0.90, n4), 3.0) * max(armMask, broadMask * 0.55) *
                     (0.30 + 0.70 * clump);
    clusters *= thinZ;
    emit += float3(0.62, 0.80, 1.00) * clusters * 3.8 * centralFade;
    emit += cHII * hiiLight;

    // A sparse halo of old stars and a faint extended disk.
    float halo = exp(-r / 7.5) * exp(-0.5 * pow(y / 1.05, 2.0)) * 0.0030;
    halo *= 1.0 - smoothstep(2.1, 3.2, abs(y));
    emit += cDisk * halo;

    // Smoothly extinguish the field before the volume boundary, otherwise the
    // rectangular sampling box becomes visible as a faint cut-off slab.
    float boundary = (1.0 - smoothstep(18.0, 21.4, r)) *
                     (1.0 - smoothstep(2.7, 3.7, abs(y)));
    emit *= boundary;
    dust *= boundary;

    float4 result = float4(max(emit, float3(0.0)), dust);
    outTex.write(result, gid);
}

// -----------------------------------------------------------------------------
// High-resolution dust modulation volume (2x linear resolution of the base)
// -----------------------------------------------------------------------------

kernel void build_dust_high(texture3d<float, access::write> outTex [[texture(0)]],
                            uint3 gid [[thread_position_in_grid]]) {
    const uint W = 1024;
    const uint H = 256;
    const uint D = 1024;
    if (gid.x >= W || gid.y >= H || gid.z >= D) return;

    float3 p = float3(
        (float(gid.x) + 0.5) / float(W) * 52.0 - 26.0,
        (float(gid.y) + 0.5) / float(H) * 8.0 - 4.0,
        (float(gid.z) + 0.5) / float(D) * 52.0 - 26.0
    );

    const float PI = 3.14159265359;
    float r = max(length(p.xz), 0.001);
    float phi = atan2(p.z, p.x);
    float y = p.y;

    float pitchA = tan(24.0 * PI / 180.0);
    float pitchB = tan(31.0 * PI / 180.0);
    float baseA = phi + log(max(r, 1.8) / 3.2) / pitchA;
    float baseB = phi + log(max(r, 1.8) / 3.2) / pitchB;
    float dA = wrapPi(2.0 * baseA + 4.24);
    float dB = wrapPi(2.0 * baseB + 4.24 + PI);
    float armA = exp(-0.5 * pow(dA / 0.30, 2.0));
    float armB = exp(-0.5 * pow(dB / 0.25, 2.0));
    float arm = max(armA, 0.72 * armB);

    float laneA = exp(-0.5 * pow(wrapPi(2.0 * baseA + 4.24 - 0.48) / 0.13, 2.0));
    float laneB = exp(-0.5 * pow(wrapPi(2.0 * baseB + 4.24 + PI - 0.46) / 0.12, 2.0));
    float lane = max(laneA, 0.70 * laneB);

    float n1 = fbm3(float3(p.x * 2.1, y * 6.0, p.z * 2.1) + float3(11.0, 3.0, 7.0), 4);
    float n2 = vnoise(float3(p.x * 5.5, y * 12.0, p.z * 5.5) + float3(4.0, 9.0, 2.0));
    float ridged = 1.0 - abs(2.0 * fbm3(float3(p.x * 3.6, y * 8.0, p.z * 3.6) + float3(21.0, 1.0, 5.0), 3) - 1.0);

    float cloud = smoothstep(0.34, 0.74, n1 * 0.72 + n2 * 0.28);
    float factor = mix(0.38, 2.15, cloud);
    factor *= 0.55 + 0.85 * pow(ridged, 2.2);
    factor *= mix(1.0, 0.18, lane * 0.85);
    factor *= 0.75 + 0.55 * n2;

    float disk = (1.0 - smoothstep(16.0, 21.5, r)) *
                 (1.0 - smoothstep(2.4, 3.9, abs(y)));
    factor = mix(1.0, clamp(factor, 0.12, 2.6), disk);
    outTex.write(float4(factor, 0.0, 0.0, 1.0), gid);
}

// -----------------------------------------------------------------------------
// Shared physical mass model (Hernquist bulge + Miyamoto-Nagai disk + NFW halo)
// -----------------------------------------------------------------------------

static inline float vCircular(float r) {
    const float G = 4.30091e-6;
    float radius = max(r, 0.02);
    float vb2 = G * 1.0e10 * radius / pow(radius + 0.8, 2.0);
    float vd2 = G * 7.0e10 * radius * radius /
                pow(radius * radius + 4.0 * 4.0, 1.5);
    float c = 8.0;
    float x = radius / 25.0;
    float f = log(1.0 + x) - x / (1.0 + x);
    float fc = log(1.0 + c) - c / (1.0 + c);
    float vh2 = G * 1.2e12 * (f / fc) / radius;
    return sqrt(max(0.0, vb2 + vd2 + vh2));
}

static inline float omegaOf(float r) {
    float radius = max(r, 0.18);
    return vCircular(radius) / radius * 0.0010227;
}

// -----------------------------------------------------------------------------
// Star field
// -----------------------------------------------------------------------------

static inline float3 starField(float3 rd, float2 resolution, uint seed) {
    // Cube-face parameterisation: no atan2 meridian seam.
    float3 a = abs(rd);
    float2 uv;
    float face;
    if (a.x >= a.y && a.x >= a.z) {
        uv = rd.yz / a.x;
        face = rd.x > 0.0 ? 0.0 : 1.0;
    } else if (a.y >= a.z) {
        uv = rd.xz / a.y;
        face = rd.y > 0.0 ? 2.0 : 3.0;
    } else {
        uv = rd.xy / a.z;
        face = rd.z > 0.0 ? 4.0 : 5.0;
    }

    float2 sp = uv * 62.0;
    float2 base = floor(sp);
    float pixel = max(1.0 / resolution.y, 1e-5);
    float sigma = max(0.045, pixel * 62.0 * 1.12);

    float3 col = float3(0.0);
    for (int j = -1; j <= 1; ++j) {
        for (int i = -1; i <= 1; ++i) {
            float2 id = base + float2(float(i), float(j));
            float2 rnd = hash22(id + float2(face * 137.0 + float(seed) * 0.017, 17.3));
            float2 pos = id + 0.16 + 0.68 * rnd;
            float2 delta = sp - pos;
            float d2 = dot(delta, delta);
            if (d2 > 0.24) continue;

            float rarity = hash21(id * 1.37 + face * 19.1 + 5.11);
            float brightness = pow(rarity, 95.0) * 2.4 + pow(rarity, 24.0) * 0.0045;
            if (brightness < 0.0010) continue;

            float psf = exp(-0.5 * d2 / (sigma * sigma));
            float spikes = (exp(-abs(delta.x) / (sigma * 0.60)) * exp(-abs(delta.y) / (sigma * 6.0)) +
                            exp(-abs(delta.y) / (sigma * 0.60)) * exp(-abs(delta.x) / (sigma * 6.0))) * 0.020;
            float tint = hash21(id + 31.7 + face);
            float3 c = blackbodyTint(tint);
            col += c * (psf + spikes) * brightness * 1.2;
        }
    }
    return col;
}

// -----------------------------------------------------------------------------
// Scene: ray-march the emissive/absorbing galaxy volume
// -----------------------------------------------------------------------------

fragment float4 galaxy_fragment(VOut in [[stage_in]],
                                texture3d<float> galaxyTex [[texture(0)]],
                                texture3d<float> detailTex [[texture(1)]],
                                texture3d<float> dustHighTex [[texture(2)]],
                                constant SceneUniforms &u [[buffer(0)]]) {
    constexpr sampler volSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    constexpr sampler detSampler(coord::normalized, filter::linear, address::repeat);

    float2 uv = in.uv;
    float2 resolution = u.resolution.xy;
    uint sampleIndex = uint(u.params2.y);
    uint seed = uint(u.params2.z);

    // Sub-pixel jitter for accumulation / anti-aliasing.
    float2 jitter = hash22(in.position.xy + float2(float(sampleIndex) * 17.17, float(seed) * 0.73)) - 0.5;
    float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    ndc += jitter * 2.0 / resolution;

    float tanHalf = u.cameraRight.w;
    float aspect = u.cameraUp.w;
    float3 rd = normalize(u.cameraForward.xyz +
                          u.cameraRight.xyz * (ndc.x * tanHalf * aspect) +
                          u.cameraUp.xyz * (ndc.y * tanHalf));
    float3 ro = u.cameraPos.xyz;

    // Rotate the density-wave pattern. The axisymmetric disk is unchanged;
    // the bar, arms, dust lanes and HII regions rotate together.
    float angle = u.cameraPos.w;
    float ca = cos(angle);
    float sa = sin(angle);

    // A smooth ellipsoid proxy bounds the galaxy. It is cheaper than a large
    // box and never produces a visible rectangular silhouette.
    float3 ell = float3(24.0, 4.3, 24.0);
    float3 roS = ro / ell;
    float3 rdS = rd / ell;
    float aq = dot(rdS, rdS);
    float bq = 2.0 * dot(roS, rdS);
    float cq = dot(roS, roS) - 1.0;
    float disc = bq * bq - 4.0 * aq * cq;

    float3 bg = starField(rd, resolution, seed);

    if (disc <= 0.0) {
        return float4(bg, 1.0);
    }
    float sq = sqrt(disc);
    float tEnter = (-bq - sq) / (2.0 * aq);
    float tExit = (-bq + sq) / (2.0 * aq);
    if (tExit <= max(tEnter, 0.0)) {
        return float4(bg, 1.0);
    }
    tEnter = max(tEnter, 0.0);

    uint steps = uint(clamp(u.params2.x, 32.0, 512.0));
    float dt = (tExit - tEnter) / float(steps);
    float t = tEnter + dt * hash21(in.position.xy + float2(float(sampleIndex) * 3.7, 11.0));

    float3 trans = float3(1.0);
    float3 color = float3(0.0);
    float dustStrength = u.params0.x;

    for (uint i = 0; i < steps; ++i) {
        float3 p = ro + rd * t;
        float3 q = float3(ca * p.x + sa * p.z, p.y, -sa * p.x + ca * p.z);
        float3 uvw = float3(q.x * (1.0 / 52.0) + 0.5,
                            q.y * (1.0 / 8.0) + 0.5,
                            q.z * (1.0 / 52.0) + 0.5);

        float4 v = galaxyTex.sample(volSampler, uvw);
        if (any(uvw < 0.0) || any(uvw > 1.0)) {
            t += dt;
            continue;
        }

        // Differential rotation of the interstellar medium. The large-scale
        // density wave has a constant pattern speed; dust and gas follow the
        // physical rotation curve, so they stream through the arms and shear.
        float rC = max(length(q.xz), 0.18);
        float omega = omegaOf(rC);   // rad / Myr, from the mass model
        float dTheta = (omega - 0.024) * u.cameraForward.w * u.params0.z;
        float cs = cos(dTheta);
        float sn = sin(dTheta);
        float2 qd = float2(cs * q.x + sn * q.z, -sn * q.x + cs * q.z);
        float3 qDetail = float3(qd.x, q.y, qd.y);

        // Fine structure from a small tileable noise volume: filaments,
        // granulation and a subtle population of resolved-like stars.
        float4 d1 = detailTex.sample(detSampler, qDetail * 0.082 + float3(0.17, 0.41, 0.73));
        float4 d2 = d1;
        if (u.params0.y > 0.5) {
            d2 = detailTex.sample(detSampler, qDetail * 0.335 + float3(0.53, 0.11, 0.31));
        }

        float3 emit = v.rgb;
        float dust = v.a;
        float ridge = 1.0 - abs(2.0 * d2.g - 1.0);
        emit *= 0.48 + 1.00 * d1.r;
        dust *= 0.12 + 1.05 * d2.g + 1.20 * pow(ridge, 2.0);

        if (u.params0.w > 0.5) {
            float3 hUvw = float3(q.x * (1.0 / 52.0) + 0.5,
                                q.y * (1.0 / 8.0) + 0.5,
                                q.z * (1.0 / 52.0) + 0.5);
            if (all(hUvw > 0.0) && all(hUvw < 1.0)) {
                dust *= dustHighTex.sample(volSampler, hUvw).r;
            }
        }

        float tau = max(dust, 0.0) * dustStrength * dt;
        float3 tr = exp(-tau * float3(0.75, 1.00, 1.32));
        color += trans * emit * (dt * 0.92);
        trans *= tr;

        t += dt;
        if (max(trans.r, max(trans.g, trans.b)) < 0.0025) break;
    }

    color += trans * bg;
    return float4(color, 1.0);
}

// -----------------------------------------------------------------------------
// Black hole: Schwarzschild geodesics + relativistic thin accretion disk
// Units: Rs = 1, c = 1, M = 1/2. The camera distance is in gravitational radii.
// -----------------------------------------------------------------------------

static inline float3 blackbodyRGB(float T) {
    float t = clamp(T, 1200.0, 40000.0);
    // Planck at approximate R/G/B wavelengths (microns).
    float lr = 0.62, lg = 0.55, lb = 0.46;
    float br = 1.0 / (pow(lr, 5.0) * max(1e-8, exp(14388.0 / (lr * t)) - 1.0));
    float bg = 1.0 / (pow(lg, 5.0) * max(1e-8, exp(14388.0 / (lg * t)) - 1.0));
    float bb = 1.0 / (pow(lb, 5.0) * max(1e-8, exp(14388.0 / (lb * t)) - 1.0));
    float3 c = float3(br, bg, bb);
    float m = max(c.r, max(c.g, c.b));
    return c / max(m, 1e-8);
}

static inline float4 sampleDiskVolume(float3 p, float time,
                                      constant SceneUniforms &u) {
    float r = length(p.xz);
    float rIn = 3.0;
    float rOut = max(5.0, u.params3.z);
    if (r < rIn * 0.97) return float4(0.0);
    if (r > rOut * 1.45) return float4(0.0);

    float t = clamp((r - rIn) / max(rOut - rIn, 0.001), 0.0, 1.0);
    float thicknessScale = clamp(u.params4.y, 0.2, 2.0);
    float h = mix(0.035, 0.26, t * t) * thicknessScale;
    float y = p.y;
    if (abs(y) > 3.4 * h) return float4(0.0);

    float vertical = exp(-0.5 * y * y / max(h * h, 1e-5));
    float radial = smoothstep(rIn, rIn + 0.30, r) *
                   (1.0 - smoothstep(rOut - 1.3, rOut, r));
    if (radial * vertical < 1e-4) return float4(0.0);

    float omega = sqrt(0.5 / (r * r * r));
    float phi = atan2(p.z, p.x);
    float phase = phi - omega * time * 2.2;
    float3 q = float3(cos(phase) * r, sin(phase) * r, y * 1.8) * 0.72;
    float n1 = fbm3(q + float3(2.1, 7.3, 4.4), 4);
    float n2 = vnoise(q * 3.3 + float3(8.0, 1.0, 3.0));
    float n3 = vnoise(q * 7.0 + float3(1.5, 9.0, 6.0));
    float n4 = vnoise(q * 5.7 + float3(4.2, 2.7, 8.1));
    float clump = 0.46 * n1 + 0.28 * n2 + 0.16 * n3 + 0.10 * n4;
    float spiral = 0.5 + 0.5 * sin(phi * 2.0 - time * 1.1 - r * 3.4);
    float filament = pow(max(0.0, n2 - 0.56) * 2.2, 2.0);
    float hotSpot = pow(max(0.0, n3 - 0.64) * 2.8, 3.0);
    clump = mix(clump, clump * (0.65 + 0.55 * spiral), 0.24);
    clump = pow(clamp(clump, 0.0, 1.0), 1.28);

    float beta = sqrt(0.5 / r);
    float gamma = 1.0 / sqrt(max(0.02, 1.0 - beta * beta));
    float3 toCamera = normalize(u.cameraPos.xyz - p);
    float3 phiHat = normalize(float3(-p.z, 0.0, p.x));
    float doppler = 1.0 / max(0.05, gamma * (1.0 - beta * dot(phiHat, toCamera)));
    float grav = sqrt(max(0.0, 1.0 - 1.0 / r));
    float g = grav * doppler;
    if (u.params3.w < 0.5) g = 1.0;
    g = clamp(g, 0.10, 4.5);

    float x = rIn / r;
    float profile = pow(x, 0.75) * pow(max(0.0, 1.0 - sqrt(x)), 0.25);
    float T = u.params3.x * 2.25 * profile;
    float Tobs = T * g;

    float3 diskColor = blackbodyRGB(Tobs);
    float dl = dot(diskColor, float3(0.2126, 0.7152, 0.0722));
    diskColor = mix(float3(dl), diskColor, 1.25);
    diskColor = mix(diskColor, float3(1.0, 0.42, 0.16),
                    smoothstep(6500.0, 3000.0, Tobs) * 0.28);

    float g4 = g * g * g * g;
    float3 emission = diskColor *
        (0.28 + 1.05 * clump + 1.35 * filament + 0.9 * hotSpot) *
        g4 * u.params3.y;

    // A soft hot inner rim; vertical thickness makes it blend into the flow.
    float rim = exp(-pow((r - rIn * 1.10) / (0.28 * rIn), 2.0));
    emission += blackbodyRGB(Tobs * 1.12) * rim * 1.8 * u.params3.y * g4;

    float density = radial * vertical *
        (0.36 + 0.78 * clump + 0.65 * filament + 0.35 * hotSpot);
    // A low-density corona/atmosphere. It fills the dark gaps between the
    // higher-order lensed images and gives the flow a soft outer edge.
    float halo = exp(-abs(y) / max(0.12, 0.62 * thicknessScale)) * radial;
    density += halo * 0.16;
    emission += diskColor * halo * 0.10 * g4 * u.params3.y;

    if (r > rOut) {
        float outerGlow = exp(-(r - rOut) / 1.9) *
                          exp(-abs(y) / max(0.16, 0.80 * thicknessScale));
        float3 outerColor = blackbodyRGB(max(2200.0, Tobs));
        emission += outerColor * outerGlow * 0.045 * u.params3.y;
        density += outerGlow * 0.035;
    }
    return float4(emission, density);
}

static inline float3 bhSky(float3 dir, float2 resolution, uint seed) {
    float3 c = starField(dir, resolution, seed);
    float3 axisA = normalize(float3(0.74, 0.18, -0.64));
    float latA = dot(dir, axisA);
    float bandA = exp(-pow(latA / 0.30, 2.0));
    float coreA = exp(-pow(latA / 0.12, 2.0));
    c += float3(0.040, 0.060, 0.115) * bandA;
    c += float3(0.085, 0.115, 0.190) * coreA * (0.65 + 0.35 * sin(dir.x * 19.0));
    c *= 1.0 - 0.22 * (1.0 - smoothstep(0.0, 0.07, abs(latA)));
    float3 axisB = normalize(float3(-0.56, 0.46, 0.69));
    float latB = dot(dir, axisB);
    c += float3(0.065, 0.045, 0.030) * exp(-pow(latB / 0.24, 2.0));
    c += float3(0.130, 0.090, 0.055) * exp(-pow(latB / 0.09, 2.0)) *
         (0.6 + 0.4 * cos(dir.z * 15.0));
    return c * 0.60;
}

fragment float4 blackhole_fragment(VOut in [[stage_in]],
                                   constant SceneUniforms &u [[buffer(0)]]) {
    float2 uv = in.uv;
    float2 resolution = u.resolution.xy;
    uint sampleIndex = uint(u.params2.y);
    uint seed = uint(u.params2.z);

    float2 jitter = hash22(in.position.xy + float2(float(sampleIndex) * 17.17,
                                                   float(seed) * 0.73)) - 0.5;
    float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    ndc += jitter * 2.0 / resolution;

    float tanHalf = u.cameraRight.w;
    float aspect = u.cameraUp.w;
    float3 rd = normalize(u.cameraForward.xyz +
                          u.cameraRight.xyz * (ndc.x * tanHalf * aspect) +
                          u.cameraUp.xyz * (ndc.y * tanHalf));
    float3 ro = u.cameraPos.xyz;
    float r0 = length(ro);
    if (r0 < 1.25) return float4(0.0);

    float3 planeN = cross(ro, rd);
    if (dot(planeN, planeN) < 1e-12) {
        planeN = cross(ro, float3(0.0, 1.0, 0.0));
    }
    planeN = normalize(planeN);
    float3 e1 = normalize(ro);
    float3 e2 = normalize(cross(planeN, e1));

    float vr = dot(rd, e1);
    float vt = dot(rd, e2);
    if (vt < 0.0) {
        e2 = -e2;
        vt = -vt;
    }
    float uu = 1.0 / r0;
    float du = -vr / max(r0 * vt, 1e-6);

    float phi = 0.0;
    float uPrev = uu;
    float phiPrev = 0.0;
    float3 pPrev = ro;
    float3 col = float3(0.0);
    float trans = 1.0;
    float closestApproach = r0;
    int diskCrossings = 0;
    bool inDisk = false;

    int steps = int(clamp(u.params2.x, 64.0, 900.0));
    bool escaped = false;
    bool captured = false;

    float time = u.cameraForward.w;
    float stepJitter = 0.76 + 0.48 * hash22(float2(float(sampleIndex) * 1.7,
                                                  float(seed) * 3.1)).x;
    float traceJitter = hash22(float2(float(sampleIndex) * 5.3,
                                      float(seed) * 1.9)).x;

    for (int i = 0; i < steps; ++i) {
        float rCur = 1.0 / max(uu, 1e-6);
        float dphi = (0.010 + 0.018 * smoothstep(0.005, 0.20, uu)) * stepJitter;
        // Resolve the vertical structure of the disk where it matters.
        if (rCur > 2.8 && rCur < u.params3.z * 1.08 && abs(pPrev.y) < 0.9) {
            dphi = min(dphi, 0.0038) * stepJitter;
        }

        // RK4 for u'' = -u + 1.5 u^2 (Schwarzschild, Rs=1).
        float k1u = du;
        float k1d = -uu + 1.5 * uu * uu;
        float u2 = uu + 0.5 * dphi * k1u;
        float d2 = du + 0.5 * dphi * k1d;
        float k2u = d2;
        float k2d = -u2 + 1.5 * u2 * u2;
        float u3 = uu + 0.5 * dphi * k2u;
        float d3 = du + 0.5 * dphi * k2d;
        float k3u = d3;
        float k3d = -u3 + 1.5 * u3 * u3;
        float u4 = uu + dphi * k3u;
        float d4 = du + dphi * k3d;
        float k4u = d4;
        float k4d = -u4 + 1.5 * u4 * u4;

        float uNext = uu + dphi * (k1u + 2.0 * k2u + 2.0 * k3u + k4u) / 6.0;
        float duNext = du + dphi * (k1d + 2.0 * k2d + 2.0 * k3d + k4d) / 6.0;
        float phiNext = phi + dphi;

        if (uNext <= 0.0 || !isfinite(uNext)) {
            escaped = true;
            uu = max(uu, 1e-5);
            du = duNext;
            phi = phiNext;
            break;
        }

        float3 pNext = (cos(phiNext) * e1 + sin(phiNext) * e2) / max(uNext, 1e-7);
        closestApproach = min(closestApproach, 1.0 / max(uNext, 1e-7));

        // Horizon.
        if (1.0 / uNext < 1.0005) {
            captured = true;
            break;
        }

        float invU = 1.0 / max(uNext, 1e-6);
        float drdphi = -duNext * invU * invU;
        float ds = sqrt(drdphi * drdphi + invU * invU) * dphi;

        // Volumetric accretion flow: integrate a soft, vertically extended disk.
        // Stratified stochastic sampling suppresses step-quantization rings.
        float sampleF = 0.5 + 0.34 * (hash22(float2(float(i) * 2.3 + traceJitter * 31.0,
                                                     float(sampleIndex) * 7.1 + traceJitter)).x - 0.5);
        float3 pSample = mix(pPrev, pNext, sampleF);
        float4 disk = sampleDiskVolume(pSample, time, u);
        if (disk.a > 1e-5) {
            if (!inDisk) {
                diskCrossings++;
                inDisk = true;
            }
            float orderWeight = diskCrossings <= 1 ? 1.0 :
                                (diskCrossings == 2 ? 0.55 : 0.18);
            col += trans * disk.rgb * ds * orderWeight;
            trans *= exp(-disk.a * ds * 1.05);
        } else {
            inDisk = false;
        }

        // Optional optically thin relativistic jet, integrated along the geodesic.
        if (u.params4.x > 0.5) {
            float y = pNext.y;
            float rho = length(pNext.xz);
            float h = abs(y);
            if (h > 1.2) {
                float w = 0.28 + 0.055 * h;
                float jet = exp(-rho * rho / (w * w)) * exp(-h / 11.0) *
                            smoothstep(1.1, 3.0, h);
                float jn = 0.55 + 0.65 * vnoise(float3(rho * 3.0, y * 0.6, phiNext * 2.0));
                float3 jc = mix(float3(0.28, 0.55, 1.0), float3(0.85, 0.97, 1.0),
                                smoothstep(0.0, 10.0, h));
                col += trans * jc * jet * jn * ds * 0.11;
            }
        }

        pPrev = pNext;
        uPrev = uNext;
        phiPrev = phiNext;
        uu = uNext;
        du = duNext;
        phi = phiNext;

        if (uu < 1.0e-5) {
            escaped = true;
            break;
        }
        if (trans < 0.002) break;
    }

    // A soft, optical-style shadow edge. The geodesic capture itself is sharp;
    // this term only softens the transition for rays grazing the photon sphere.
    float naturalShadow = captured ? 1.0 :
        (1.0 - smoothstep(1.02, 2.05, closestApproach));

    if (!captured) {
        // Asymptotic direction of the traced ray.
        float3 dir;
        if (uu > 1e-8) {
            float invU = 1.0 / uu;
            float drdphi = -du * invU * invU;
            dir = normalize((drdphi * cos(phi) - invU * sin(phi)) * e1 +
                            (drdphi * sin(phi) + invU * cos(phi)) * e2);
        } else {
            dir = normalize(pPrev);
        }
        float3 bg = bhSky(dir, resolution, seed + 7717u);
        col += trans * bg * (1.0 - 0.94 * naturalShadow);
    }

    return float4(col, 1.0);
}

// -----------------------------------------------------------------------------
// Independent star particle layer
// -----------------------------------------------------------------------------

struct StarParticle {
    float4 posSize;
    float4 colorBrightness;
    float4 velocity;
};

struct StarOut {
    float4 position [[position]];
    float2 uv;
    float3 color;
};

vertex StarOut star_vertex(uint vid [[vertex_id]],
                           uint iid [[instance_id]],
                           device const StarParticle *stars [[buffer(0)]],
                           constant SceneUniforms &u [[buffer(1)]],
                           texture3d<float> dustTex [[texture(0)]],
                           texture3d<float> dustHighTex [[texture(1)]]) {
    constexpr sampler dustSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    StarParticle s = stars[iid];

    float3 p = s.posSize.xyz;
    if (u.params1.y < 0.5) {
        float r = length(p.xz);
        float omega = omegaOf(max(r, 0.18));
        float angle = omega * u.cameraForward.w;
        float ca = cos(angle);
        float sa = sin(angle);
        p.xz = float2(ca * p.x - sa * p.z, sa * p.x + ca * p.z);
    }

    float3 ro = u.cameraPos.xyz;
    float3 rel = p - ro;
    float z = dot(rel, u.cameraForward.xyz);
    if (z <= 0.5) {
        StarOut out;
        out.position = float4(2.0, 2.0, 2.0, 1.0);
        out.uv = float2(0.0);
        out.color = float3(0.0);
        return out;
    }

    // Per-star extinction by integrating the dusty volume between the star
    // and the camera. This is what makes stars behind a lane genuinely redder
    // instead of simply being drawn on top of the galaxy.
    float3 seg = ro - p;
    float dist = length(seg);
    float3 dir = seg / max(dist, 1e-3);
    float tau = 0.0;
    float pattern = 0.024 * u.cameraForward.w;
    float cp = cos(-pattern);
    float sp = sin(-pattern);
    for (int i = 1; i <= 8; ++i) {
        float t = dist * float(i) / 8.0;
        float3 q = p + dir * t;
        float3 qp = float3(cp * q.x - sp * q.z, q.y, sp * q.x + cp * q.z);
        float3 uvw = float3(qp.x * (1.0 / 52.0) + 0.5,
                            qp.y * (1.0 / 8.0) + 0.5,
                            qp.z * (1.0 / 52.0) + 0.5);
        if (all(uvw > 0.0) && all(uvw < 1.0)) {
            float h = 1.0;
            if (u.params0.w > 0.5) {
                h = dustHighTex.sample(dustSampler, uvw).r;
            }
            tau += dustTex.sample(dustSampler, uvw).a * h * u.params0.x * (dist / 8.0);
        }
    }
    float3 tr = exp(-tau * float3(0.75, 1.00, 1.32));

    float tanHalf = u.cameraRight.w;
    float aspect = u.cameraUp.w;
    float2 ndc = float2(dot(rel, u.cameraRight.xyz) / (z * tanHalf * aspect),
                        dot(rel, u.cameraUp.xyz) / (z * tanHalf));

    float2 corners[6] = {
        float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
        float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0)
    };
    float2 corner = corners[vid];
    float sizePixels = s.posSize.w * (u.resolution.y / 1080.0);
    float2 jitter = hash22(float2(float(iid) * 0.73, float(uint(u.params2.y)) * 1.37)) - 0.5;
    float2 offset = (corner * sizePixels * 2.0 + jitter * 2.0) / u.resolution.xy;

    StarOut out;
    out.position = float4(ndc + offset, 0.0, 1.0);
    out.uv = corner;
    out.color = s.colorBrightness.xyz * s.colorBrightness.w * tr;
    return out;
}

fragment float4 star_fragment(StarOut in [[stage_in]]) {
    float r2 = dot(in.uv, in.uv);
    if (r2 > 1.0) discard_fragment();
    float psf = exp(-5.0 * r2) + 0.12 * exp(-1.4 * r2);
    return float4(in.color * psf, 1.0);
}

// -----------------------------------------------------------------------------
// Restricted N-body integrator for the star layer
// -----------------------------------------------------------------------------

static inline float3 starAcceleration(float3 p, float t) {
    float r = max(length(p.xz), 0.25);
    float vc = vCircular(r);
    float vk = vc * 0.0010227;             // kpc / Myr
    float ar = -(vk * vk) / r;

    float phi = atan2(p.z, p.x);
    float pitch = tan(24.0 * 3.14159265359 / 180.0);
    float phase = 2.0 * (phi + log(max(r, 1.8) / 3.2) / pitch - 0.024 * t) + 4.24;
    float amp = 0.040 * (vk * vk) / r;
    ar += amp * sin(phase);
    float at = 0.55 * amp * cos(phase);

    float2 rad = p.xz / r;
    float2 tan = float2(-rad.y, rad.x);
    float3 a = float3(rad.x * ar + tan.x * at, 0.0, rad.y * ar + tan.y * at);
    a.y = -0.0081 * p.y;                   // 0.09 rad/Myr vertical oscillation
    return a;
}

kernel void integrate_stars(device StarParticle *stars [[buffer(0)]],
                            constant BuildUniforms &u [[buffer(1)]],
                            uint iid [[thread_position_in_grid]]) {
    float dt = u.params.x;
    float t = u.params.y;
    StarParticle s = stars[iid];
    float3 p = s.posSize.xyz;
    float3 v = s.velocity.xyz;

    // Leapfrog (kick-drift-kick)
    float3 a0 = starAcceleration(p, t);
    v += a0 * (0.5 * dt);
    p += v * dt;
    float3 a1 = starAcceleration(p, t + dt);
    v += a1 * (0.5 * dt);

    float r = length(p.xz);
    if (r > 24.0) {
        p.xz *= 24.0 / r;
        v.xz *= 0.82;
    }
    if (abs(p.y) > 4.0) {
        p.y = clamp(p.y, -4.0, 4.0);
        v.y *= 0.82;
    }

    stars[iid].posSize = float4(p, s.posSize.w);
    stars[iid].velocity = float4(v, 0.0);
}

// -----------------------------------------------------------------------------
// Bloom
// -----------------------------------------------------------------------------


// -----------------------------------------------------------------------------
// Solar system: Keplerian planets, moons, Saturn rings, belts and orbit lines
// -----------------------------------------------------------------------------

struct SolarPlanet {
    float4 posRadius;   // xyz AU, display radius AU
    float4 color;       // rgb, unused
    float4 orbit;       // a AU, e, varpi rad, orbit-line alpha
    float4 flags;       // type, ring strength, ring tilt rad, active
};

static inline float solarRaySphere(float3 ro, float3 rd, float3 c, float r) {
    float3 oc = ro - c;
    float b = dot(oc, rd);
    float cc = dot(oc, oc) - r * r;
    float h = b * b - cc;
    if (h < 0.0) return -1.0;
    h = sqrt(h);
    float t0 = -b - h;
    float t1 = -b + h;
    if (t0 > 1e-4) return t0;
    if (t1 > 1e-4) return t1;
    return -1.0;
}

static inline float3 solarSurface(int type, float3 n, float3 base, float seed) {
    float3 np = n * 2.6 + float3(seed * 7.1, seed * 3.7, seed * 5.3);
    float grain = fbm3(np, 4);
    float fine = fbm3(np * 3.7 + 4.0, 3);

    if (type == 0) { // Mercury
        float craters = smoothstep(0.58, 0.74, fbm3(np * 3.2, 4));
        return base * (0.62 + 0.42 * grain) * (0.9 + 0.14 * craters);
    }
    if (type == 1) { // Venus
        float cloud = 0.5 + 0.5 * sin(n.y * 12.0 + fbm3(np * 1.8, 4) * 5.0);
        return mix(base * 0.72, float3(1.0, 0.92, 0.72), cloud * 0.55);
    }
    if (type == 2) { // Earth
        float land = fbm3(np * 2.2, 5);
        float continents = smoothstep(0.47, 0.55, land);
        float3 ocean = float3(0.025, 0.11, 0.30) * (0.8 + 0.35 * fine);
        float3 ground = mix(float3(0.09, 0.22, 0.08), float3(0.42, 0.34, 0.18), fine);
        float3 col = mix(ocean, ground, continents);
        float clouds = smoothstep(0.52, 0.70, fbm3(np * 4.5 + 11.0, 5));
        col = mix(col, float3(0.92, 0.95, 0.98), clouds * 0.82);
        float ice = smoothstep(0.78, 0.92, abs(n.y));
        col = mix(col, float3(0.82, 0.90, 0.96), ice);
        return col;
    }
    if (type == 3) { // Mars
        float dust = 0.5 + 0.5 * fbm3(np * 2.8, 4);
        float3 col = mix(float3(0.42, 0.16, 0.075), float3(0.83, 0.40, 0.20), dust);
        float cap = smoothstep(0.84, 0.97, abs(n.y));
        return mix(col, float3(0.92, 0.90, 0.86), cap * 0.8);
    }
    if (type == 4) { // Jupiter
        float bands = 0.5 + 0.5 * sin(n.y * 28.0 + fbm3(np * 2.0, 4) * 3.2);
        float3 col = mix(float3(0.55, 0.38, 0.24), float3(0.95, 0.84, 0.65), bands);
        float swirl = fbm3(np * 4.0 + 7.0, 4);
        col = mix(col, float3(0.86, 0.66, 0.46), swirl * 0.35);
        float3 spotDir = normalize(float3(0.55, -0.22, 0.80));
        float spot = smoothstep(0.16, 0.03, distance(n, spotDir));
        col = mix(col, float3(0.68, 0.24, 0.14), spot);
        return col;
    }
    if (type == 5) { // Saturn
        float bands = 0.5 + 0.5 * sin(n.y * 22.0 + fbm3(np * 1.7, 4) * 2.4);
        return mix(float3(0.70, 0.58, 0.38), float3(0.96, 0.89, 0.68), bands);
    }
    if (type == 6) { // Uranus
        return mix(float3(0.37, 0.70, 0.76), float3(0.65, 0.88, 0.91),
                   0.5 + 0.5 * sin(n.y * 8.0 + fine * 1.5));
    }
    if (type == 7) { // Neptune
        float bands = 0.5 + 0.5 * sin(n.y * 11.0 + fbm3(np * 2.5, 4) * 3.0);
        return mix(float3(0.09, 0.22, 0.58), float3(0.28, 0.48, 0.86), bands);
    }
    if (type == 8) { // Moon
        float craters = smoothstep(0.50, 0.72, fbm3(np * 4.0, 4));
        return base * (0.60 + 0.38 * grain) * (0.88 + 0.16 * craters);
    }
    if (type == 13) { // Titan
        return mix(base * 0.7, float3(0.95, 0.76, 0.42), 0.45 + 0.35 * grain);
    }
    if (type == 14) { // Pluto
        float heart = smoothstep(0.18, 0.02, distance(n, normalize(float3(0.3, 0.2, 0.9))));
        return mix(base * (0.6 + 0.4 * grain), float3(0.90, 0.82, 0.70), heart * 0.5);
    }
    // Io / Europa / Ganymede / Callisto
    if (type == 9) {
        return mix(float3(0.86, 0.72, 0.18), float3(0.95, 0.85, 0.42), 0.5 + 0.5 * sin(fine * 19.0));
    }
    if (type == 10) {
        return mix(float3(0.78, 0.80, 0.78), float3(0.96, 0.94, 0.88), 0.5 + 0.5 * sin(fine * 12.0));
    }
    if (type == 11) {
        return mix(float3(0.44, 0.40, 0.35), float3(0.72, 0.68, 0.60), 0.5 + 0.5 * grain);
    }
    if (type == 12) {
        return mix(float3(0.24, 0.22, 0.20), float3(0.48, 0.42, 0.35), 0.6 + 0.4 * grain);
    }
    return base * (0.7 + 0.4 * grain);
}

fragment float4 solar_fragment(VOut in [[stage_in]],
                               constant SceneUniforms &u [[buffer(0)]],
                               const device SolarPlanet *planets [[buffer(1)]]) {
    uint sampleIndex = uint(u.params2.y);
    float2 jitter = (hash22(in.position.xy + float(sampleIndex) * 17.31) - 0.5) / u.resolution.xy;
    float2 scr = (in.position.xy + jitter) / u.resolution.xy * 2.0 - 1.0;
    float aspect = u.cameraUp.w;
    float tanHalf = u.cameraRight.w;
    float3 rd = normalize(u.cameraForward.xyz
                         + u.cameraRight.xyz * (scr.x * tanHalf * aspect)
                         + u.cameraUp.xyz * (scr.y * tanHalf));
    float3 ro = u.cameraPos.xyz;
    float days = u.cameraForward.w;

    float3 col = starField(rd, u.resolution.xy, uint(u.params2.z)) * 0.62;
    float showOrbits = u.params3.y;
    float showBelts = u.params3.z;
    float showMoons = u.params3.w;
    int focusIndex = int(u.params4.w);
    float lineWidth = max(u.params4.x, 0.0007);
    float sunRadius = 0.145;

    // Orbit rings, drawn as thin circles in the ecliptic plane.
    if (showOrbits > 0.5 && abs(rd.y) > 1e-4) {
        float tPlane = -ro.y / rd.y;
        if (tPlane > 0.0) {
            float3 p = ro + rd * tPlane;
            float rp = length(p.xz);
            for (int i = 0; i < 16; ++i) {
                SolarPlanet pl = planets[i];
                if (pl.flags.w < 0.5 || pl.orbit.w <= 0.0) continue;
                float a = pl.orbit.x;
                float e = pl.orbit.y;
                float varpi = pl.orbit.z;
                float x = cos(varpi) * p.x + sin(varpi) * p.z;
                float z = -sin(varpi) * p.x + cos(varpi) * p.z;
                float nu = atan2(z, x);
                float rOrbit = a * (1.0 - e * e) / max(0.05, 1.0 + e * cos(nu));
                float d = abs(rp - rOrbit);
                float alpha = exp(-d / lineWidth) * pl.orbit.w * 0.55;
                col += pl.color.rgb * alpha;
            }
        }
    }

    // Asteroid and Kuiper belts as faint procedural dust rings.
    if (showBelts > 0.5 && abs(rd.y) > 1e-4) {
        float tPlane = -ro.y / rd.y;
        if (tPlane > 0.0) {
            float3 p = ro + rd * tPlane;
            float r = length(p.xz);
            if (r > 2.05 && r < 3.35) {
                float n = hash21(floor(p.xz * 26.0) + 7.1);
                float band = 0.5 + 0.5 * sin(r * 44.0 + n * 6.0);
                col += float3(0.42, 0.34, 0.24) * (0.006 + 0.012 * n * band);
            }
            if (r > 29.0 && r < 49.0) {
                float n = hash21(floor(p.xz * 12.0) + 3.7);
                col += float3(0.30, 0.34, 0.38) * 0.008 * n;
            }
        }
    }

    // Sun.
    float sunT = solarRaySphere(ro, rd, float3(0.0), sunRadius);
    float3 sunDir = normalize(-ro);
    float cosA = clamp(dot(rd, sunDir), -1.0, 1.0);
    float ang = acos(cosA);
    float glow = exp(-ang * 44.0) * 0.24 + exp(-ang * 13.0) * 0.006;
    col += float3(1.0, 0.56, 0.23) * glow * u.params4.y;

    if (sunT > 0.0) {
        float3 hit = ro + rd * sunT;
        float3 n = normalize(hit);
        float limb = pow(max(dot(n, -rd), 0.0), 0.30);
        float spots = smoothstep(0.72, 0.90, fbm3(n * 7.0 + 2.0, 4));
        float3 sun = float3(1.0, 0.68, 0.34) * (1.25 * limb + 0.35 * (1.0 - limb));
        sun *= (1.0 - 0.30 * spots);
        col = sun;
    }

    // Planets and moons.
    int best = -1;
    float bestT = 1e30;
    for (int i = 0; i < 16; ++i) {
        SolarPlanet pl = planets[i];
        if (pl.flags.w < 0.5) continue;
        if (pl.flags.x >= 8.0 && showMoons < 0.5) continue;
        // In a close-up, do not let a foreground planet block the target.
        if (focusIndex > 0 && pl.flags.x < 8.0 && i != focusIndex - 1) continue;
        float minR = u.params4.z * (pl.flags.x >= 8.0 ? 0.8 : 1.35);
        float rr = max(pl.posRadius.w, minR);
        float t = solarRaySphere(ro, rd, pl.posRadius.xyz, rr);
        if (t > 0.0 && t < bestT) {
            bestT = t;
            best = i;
        }
    }

    if (best >= 0 && (sunT < 0.0 || bestT < sunT)) {
        SolarPlanet pl = planets[best];
        float3 center = pl.posRadius.xyz;
        float minR = u.params4.z * (pl.flags.x >= 8.0 ? 0.8 : 1.35);
        float displayedRadius = max(pl.posRadius.w, minR);
        float3 hit = ro + rd * bestT;
        float3 n = normalize(hit - center);
        float3 base = pl.color.rgb;
        int type = int(pl.flags.x);
        float3 surface = solarSurface(type, n, base, 3.17 + float(type) * 0.71);
        float3 L = normalize(-hit);
        float diff = max(dot(n, L), 0.0);

        // In a close-up, ignore shadows from planets that are hidden by the
        // focus filter; otherwise a foreground transit can black out half of
        // the target for no visible reason.
        float shadow = 1.0;
        if (focusIndex <= 0) {
            for (int j = 0; j < 16; ++j) {
                if (j == best) continue;
                SolarPlanet other = planets[j];
                if (other.flags.w < 0.5) continue;
                if (solarRaySphere(hit + n * 0.0008, L, other.posRadius.xyz, other.posRadius.w) > 0.0) {
                    shadow = 0.36;
                    break;
                }
            }
        }

        float rim = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);
        float3 lit = surface * (0.11 + 1.30 * diff * shadow);
        if (type == 2) lit += float3(0.10, 0.22, 0.42) * rim * 0.85;
        else lit += base * rim * 0.34 + base * 0.012;
        col = lit;

        // Saturn / Uranus rings: a thin annulus in the planet's equatorial plane.
        if (pl.flags.y > 0.5) {
            float tilt = pl.flags.z;
            float3 rn = normalize(float3(0.0, cos(tilt), sin(tilt)));
            float denom = dot(rd, rn);
            if (abs(denom) > 1e-5) {
                float tr = dot(center - ro, rn) / denom;
                if (tr > 0.0 && tr < bestT) {
                    float3 rp = ro + rd * tr;
                    float rr = length(rp - center) / max(displayedRadius, 1e-5);
                    if (rr > 1.28 && rr < 2.35) {
                        float bands = 0.55 + 0.45 * sin(rr * 46.0 + fbm3(rp * 3.0, 3) * 5.0);
                        float edge = smoothstep(1.28, 1.42, rr) * (1.0 - smoothstep(2.18, 2.35, rr));
                        float alpha = pl.flags.y * edge * (0.12 + 0.42 * bands);
                        float3 rc = mix(float3(0.78, 0.70, 0.54), float3(0.95, 0.88, 0.72), bands);
                        col = col * (1.0 - alpha) + rc * alpha * 0.9;
                    }
                }
            }
        }
    }

    // Soft marker halos keep the planets readable when their true angular
    // size is only a few pixels. They are intentionally subtle and are not
    // part of the physical surface shading.
    for (int i = 0; i < 16; ++i) {
        SolarPlanet pl = planets[i];
        if (pl.flags.w < 0.5) continue;
        if (pl.flags.x >= 8.0) continue;
        float3 oc = pl.posRadius.xyz - ro;
        float b = dot(oc, rd);
        if (b < 0.0) continue;
        float3 cp = ro + rd * b;
        float d = length(cp - pl.posRadius.xyz);
        float r = max(pl.posRadius.w, u.params4.z * 1.35);
        float halo = exp(-d / max(r * 5.0, 0.004)) * 0.055;
        col += pl.color.rgb * halo;
    }

    return float4(col, 1.0);
}

fragment float4 bloom_fragment(VOut in [[stage_in]],
                               texture2d<float> src [[texture(0)]],
                               constant BloomUniforms &u [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    float2 texel = u.texel.xy;
    int mode = int(u.params.x + 0.5);

    if (mode == 0) {
        // Prefilter / threshold. src is the raw accumulation buffer.
        float3 c = src.sample(s, uv).rgb * u.params.w;
        float l = luminance(c);
        float threshold = u.params.y;
        float knee = u.params.z;
        float soft = clamp(l - threshold + knee, 0.0, 2.0 * knee);
        soft = soft * soft / (4.0 * knee + 1e-4);
        float contrib = max(soft, l - threshold) / max(l, 1e-4);
        return float4(c * contrib, 1.0);
    } else if (mode == 1) {
        // Downsample with a 4-tap box.
        float3 c = src.sample(s, uv + texel * float2(-1.0, -1.0)).rgb;
        c += src.sample(s, uv + texel * float2( 1.0, -1.0)).rgb;
        c += src.sample(s, uv + texel * float2(-1.0,  1.0)).rgb;
        c += src.sample(s, uv + texel * float2( 1.0,  1.0)).rgb;
        return float4(c * 0.25, 1.0);
    } else {
        // Separable Gaussian blur.
        float2 dir = u.texel.zw;
        float3 c = src.sample(s, uv).rgb * 0.2270270270;
        c += src.sample(s, uv + dir * 1.3846153846 * texel).rgb * 0.3162162162;
        c += src.sample(s, uv - dir * 1.3846153846 * texel).rgb * 0.3162162162;
        c += src.sample(s, uv + dir * 3.2307692308 * texel).rgb * 0.0702702703;
        c += src.sample(s, uv - dir * 3.2307692308 * texel).rgb * 0.0702702703;
        return float4(c, 1.0);
    }
}

// -----------------------------------------------------------------------------
// Composite / tone map
// -----------------------------------------------------------------------------

static inline float3 acesFilm(float3 x) {
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0);
}

static inline float3 linearToSRGB(float3 c) {
    c = clamp(c, 0.0, 1.0);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

static inline float ign(float2 p) {
    return fract(52.9829189 * fract(dot(p, float2(0.06711056, 0.00583715))));
}

fragment float4 composite_fragment(VOut in [[stage_in]],
                                   texture2d<float> sceneTex [[texture(0)]],
                                   texture2d<float> bloom0 [[texture(1)]],
                                   texture2d<float> bloom1 [[texture(2)]],
                                   texture2d<float> bloom2 [[texture(3)]],
                                   texture2d<float> bloom3 [[texture(4)]],
                                   texture2d<float> bloom4 [[texture(5)]],
                                   constant CompositeUniforms &u [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    float2 res = u.resolution.xy;
    float count = max(u.params1.x, 1.0);

    float3 scene;
    if (u.params2.x > 0.01) {
        // A small optical PSF for the black-hole mode. This softens the
        // photon ring / disk edges without touching the galaxy renderer.
        float2 px = float2(u.params2.x * res.y / 1080.0) / res;
        scene  = sceneTex.sample(s, uv).rgb * 0.25;
        scene += sceneTex.sample(s, uv + float2( px.x, 0.0)).rgb * 0.125;
        scene += sceneTex.sample(s, uv - float2( px.x, 0.0)).rgb * 0.125;
        scene += sceneTex.sample(s, uv + float2(0.0,  px.y)).rgb * 0.125;
        scene += sceneTex.sample(s, uv - float2(0.0,  px.y)).rgb * 0.125;
        scene += sceneTex.sample(s, uv + px).rgb * 0.0625;
        scene += sceneTex.sample(s, uv - px).rgb * 0.0625;
        scene += sceneTex.sample(s, uv + float2(px.x, -px.y)).rgb * 0.0625;
        scene += sceneTex.sample(s, uv + float2(-px.x, px.y)).rgb * 0.0625;
    } else {
        // Very subtle lens dispersion for the galaxy.
        float2 ca = (uv - 0.5) * (u.params1.z / res.y);
        scene.r = sceneTex.sample(s, uv + ca).r;
        scene.g = sceneTex.sample(s, uv).g;
        scene.b = sceneTex.sample(s, uv - ca).b;
    }
    scene /= count;

    float3 bloom = bloom0.sample(s, uv).rgb * 0.30 +
                   bloom1.sample(s, uv).rgb * 0.24 +
                   bloom2.sample(s, uv).rgb * 0.20 +
                   bloom3.sample(s, uv).rgb * 0.15 +
                   bloom4.sample(s, uv).rgb * 0.11;
    bloom *= 0.92;

    float3 col = scene + bloom * u.params0.y;

    // Exposure in stops.
    col *= exp2(u.params0.x);

    // Gentle filmic grade: cool shadows, warm highlights.
    float l = luminance(col);
    col = mix(col, col * float3(0.94, 0.98, 1.06), smoothstep(0.25, 0.0, l) * 0.35);
    col = mix(col, col * float3(1.04, 1.00, 0.95), smoothstep(0.8, 2.5, l) * 0.20);

    col = acesFilm(col);
    float sat = dot(col, float3(0.2126, 0.7152, 0.0722));
    col = mix(float3(sat), col, 1.18);

    // Vignette in display space.
    float2 vuv = (uv - 0.5) * float2(res.x / res.y, 1.0);
    float vignette = smoothstep(1.18, 0.28, length(vuv));
    col *= mix(1.0, vignette, u.params0.z);

    col = linearToSRGB(col);

    // Fine grain and ordered dither. Keeps large gradients from banding.
    float grain = (hash21(in.position.xy + float2(u.params1.y * 13.7, 4.2)) - 0.5);
    float dither = (ign(in.position.xy) - 0.5) / 255.0;
    col += grain * u.params0.w + dither;
    col = clamp(col, 0.0, 1.0);

    return float4(col, 1.0);
}
