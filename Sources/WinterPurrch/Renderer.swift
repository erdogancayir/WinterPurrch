import Metal
import MetalKit
import QuartzCore
import simd

struct SpriteInstance {
    var px: Float, py: Float, r: Float, alpha: Float
    var kind: Float, seed: Float, ext: Float, pad: Float
    var a: Float = 0, b: Float = 0, c: Float = 0, d: Float = 0
    var e: Float = 0, f: Float = 0, g: Float = 0, h: Float = 0
}

struct HeapVertex {
    var px: Float, py: Float, depth: Float, pad: Float
}

struct Uniforms {
    var size: SIMD2<Float>
    var time: Float
    var scale: Float
    var opacity: Float
    var pad0: Float = 0, pad1: Float = 0, pad2: Float = 0
}

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct U { float2 size; float time; float scale; float opacity; float pad0; float pad1; float pad2; };
struct Sprite { float px, py, r, alpha, kind, seed, ext, pad, a, b, c, d, e, f, g, h; };
struct HV { float px, py, depth, pad; };

struct SOut { float4 pos [[position]]; float2 uv; float r; float alpha; float kind; float seed; float facing; float4 ex; float4 ex2; };
struct HOut { float4 pos [[position]]; float depth; float2 world; };

float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

vertex SOut spriteV(uint vid [[vertex_id]], uint iid [[instance_id]],
                    const device Sprite* s [[buffer(0)]], constant U& u [[buffer(1)]]) {
    Sprite sp = s[iid];
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    float2 p = float2(sp.px, sp.py) + corner * sp.r * sp.ext;
    SOut o;
    o.pos = float4(p / u.size * 2.0 - 1.0, 0, 1);
    o.uv = corner * sp.ext;
    o.r = sp.r * u.scale;
    o.alpha = sp.alpha;
    o.kind = sp.kind;
    o.seed = sp.seed;
    o.facing = sp.pad;
    o.ex = float4(sp.a, sp.b, sp.c, sp.d);
    o.ex2 = float4(sp.e, sp.f, sp.g, sp.h);
    return o;
}

// Signed distance to a segment, for the carrot.
float segDist(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}


float dot2(float2 v) { return dot(v, v); }
float fillA(float d, float px) { return 1.0 - smoothstep(-px, px, d); }
float sdEll(float2 p, float2 c, float2 r) { return (length((p - c) / r) - 1.0) * min(r.x, r.y); }
float sdBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}
float sdTriangle(float2 p, float2 p0, float2 p1, float2 p2) {
    float2 e0 = p1 - p0, e1 = p2 - p1, e2 = p0 - p2;
    float2 v0 = p - p0, v1 = p - p1, v2 = p - p2;
    float2 pq0 = v0 - e0 * clamp(dot(v0, e0) / dot(e0, e0), 0.0, 1.0);
    float2 pq1 = v1 - e1 * clamp(dot(v1, e1) / dot(e1, e1), 0.0, 1.0);
    float2 pq2 = v2 - e2 * clamp(dot(v2, e2) / dot(e2, e2), 0.0, 1.0);
    float s = sign(e0.x * e2.y - e0.y * e2.x);
    float2 d = min(min(float2(dot(pq0, pq0), s * (v0.x * e0.y - v0.y * e0.x)),
                       float2(dot(pq1, pq1), s * (v1.x * e1.y - v1.y * e1.x))),
                       float2(dot(pq2, pq2), s * (v2.x * e2.y - v2.y * e2.x)));
    return -sqrt(d.x) * sign(d.y);
}
float sdHeart(float2 p) {
    p.x = abs(p.x);
    if (p.y + p.x > 1.0) return sqrt(dot2(p - float2(0.25, 0.75))) - sqrt(2.0) / 4.0;
    return sqrt(min(dot2(p - float2(0.0, 1.0)), dot2(p - 0.5 * max(p.x + p.y, 0.0)))) * sign(p.x - p.y);
}
// Premultiplied "over".
float4 over(float4 dst, float3 c, float a) { return float4(c * a + dst.rgb * (1.0 - a), a + dst.a * (1.0 - a)); }

// The cat, side on. Units are the cat's size; y = 0 is the ground under its feet.
// ex: x blink, y startle, z moving, w pose (0 walk, 1 sit, 2 sleep, 3 airborne, 4 playing).
float4 drawCat(float2 uv, float px, float phase, float facing, float4 ex, float4 ex2, float time) {
    float2 q = float2(uv.x * facing, uv.y + 1.0);
    // Tumbling: turn the whole cat about its middle.
    if (ex2.z != 0.0) {
        float2 c0 = float2(0.0, 0.75);
        float ca = cos(ex2.z), sa = sin(ex2.z);
        float2 d = q - c0;
        q = c0 + float2(ca * d.x - sa * d.y, sa * d.x + ca * d.y);
    }
    // Shaking snow off: everything above the paws whips from side to side.
    float shaking = ex2.x;
    q.x += sin(time * 44.0) * 0.11 * shaking * smoothstep(0.15, 0.9, q.y);
    q.y += abs(sin(time * 44.0)) * 0.03 * shaking * smoothstep(0.15, 0.9, q.y);
    float pose = ex.w;
    bool sit = abs(pose - 1.0) < 0.5;
    bool sleep = abs(pose - 2.0) < 0.5;
    bool air = abs(pose - 3.0) < 0.5;
    bool play = abs(pose - 4.0) < 0.5;
    bool flop = abs(pose - 6.0) < 0.5;
    bool dig = abs(pose - 7.0) < 0.5;
    float sway = sin(time * 2.3);

    float2 bc = float2(0.0, 0.72), br = float2(0.78, 0.36);
    float2 hc = float2(0.8, 1.05);
    float hr = 0.34;
    if (sit)   { bc = float2(-0.18, 0.6); br = float2(0.48, 0.58); hc = float2(0.12, 1.32); }
    if (sleep) { bc = float2(0.0, 0.36); br = float2(0.82, 0.36); hc = float2(0.66, 0.42); }
    if (air)   { bc = float2(0.0, 0.85); br = float2(0.9, 0.31) * (1.0 + 0.12 * ex.y); hc = float2(0.92, 1.12); }
    if (play)  { bc = float2(-0.05, 0.56); br = float2(0.8, 0.32); hc = float2(0.78, 0.66); }
    if (dig)   { bc = float2(-0.05, 0.56); br = float2(0.8, 0.32); hc = float2(0.8, 0.5); }
    if (flop)  { bc = float2(0.0, 0.33); br = float2(0.84, 0.32); hc = float2(0.86, 0.36); }

    float body = sdEll(q, bc, br);
    if (play || dig) body = min(body, sdEll(q, float2(-0.52, 0.76), float2(0.36, 0.34)));
    float head = length(q - hc) - hr;
    float earL = sdTriangle(q, hc + float2(-0.30, 0.14), hc + float2(-0.22, 0.52), hc + float2(-0.02, 0.30));
    float earR = sdTriangle(q, hc + float2(0.04, 0.32), hc + float2(0.24, 0.52), hc + float2(0.30, 0.12));

    float legsNear = 1e3, legsFar = 1e3;
    if (!sit && !sleep && !flop) {
        float hipY = bc.y - br.y * 0.35;
        for (int i = 0; i < 4; i++) {
            float hx = (i == 0) ? -0.5 : (i == 1) ? -0.3 : (i == 2) ? 0.38 : 0.56;
            float off = (i == 0 || i == 3) ? 0.0 : 3.14159;
            float2 hip = float2(hx, hipY);
            float s = sin(phase + off) * ex.z;
            float2 foot = float2(hx + s * 0.22, 0.05 + max(0.0, cos(phase + off)) * 0.1 * ex.z);
            if (air) foot = hip + (i < 2 ? float2(-0.4, -0.28) : float2(0.4, -0.28));
            if (play) {
                hip.y = (i < 2) ? 0.66 : 0.45;
                if (i == 2) foot = float2(0.62 + 0.32 * max(0.0, sin(phase)), 0.05 + 0.38 * max(0.0, sin(phase)));
                else if (i == 3) foot = float2(0.7, 0.04);
                else foot = float2(hx, 0.04);
            }
            if (dig) {
                hip.y = (i < 2) ? 0.66 : 0.42;
                float ph = phase + (i == 2 ? 0.0 : 3.14159);
                if (i >= 2) foot = float2(0.68 + 0.16 * sin(ph), 0.03 + 0.2 * max(0.0, sin(ph)));
                else foot = float2(hx, 0.04);
            }
            float dl = segDist(q, hip, foot) - 0.085;
            if (i == 0 || i == 2) legsNear = min(legsNear, dl); else legsFar = min(legsFar, dl);
        }
    }
    if (flop) {
        // On its back-ish, paws up and splayed.
        for (int i = 0; i < 4; i++) {
            float hx = (i == 0) ? -0.5 : (i == 1) ? -0.3 : (i == 2) ? 0.35 : 0.55;
            float wob = sin(time * 3.0 + float(i)) * 0.04;
            float2 hip = float2(hx, 0.5);
            float2 foot = float2(hx + 0.18 * (i < 2 ? -1.0 : 1.0) + wob, 0.92 + 0.08 * float(i % 2));
            float dl = segDist(q, hip, foot) - 0.085;
            if (i == 0 || i == 2) legsNear = min(legsNear, dl); else legsFar = min(legsFar, dl);
        }
    }
    if (sit) {
        legsNear = min(legsNear, segDist(q, float2(0.18, 0.62), float2(0.2, 0.05)) - 0.08);
        legsFar = min(legsFar, segDist(q, float2(0.02, 0.62), float2(0.04, 0.05)) - 0.08);
        legsNear = min(legsNear, sdEll(q, float2(-0.32, 0.09), float2(0.24, 0.1)));
    }

    float2 t0, t1, t2;
    if (sit) { t0 = float2(-0.55, 0.12); t1 = float2(-0.9, 0.1); t2 = float2(-1.12, 0.28 + 0.1 * sway); }
    else if (sleep) { t0 = float2(-0.78, 0.25); t1 = float2(-0.55, 0.06); t2 = float2(0.25, 0.07); }
    else if (flop) { t0 = float2(-0.78, 0.3); t1 = float2(-1.08, 0.16); t2 = float2(-1.32, 0.1 + 0.05 * sway); }
    else {
        t0 = bc + float2(-br.x * 0.9, br.y * 0.3);
        t1 = t0 + float2(-0.32, 0.32 + 0.08 * sway);
        t2 = t1 + float2(-0.06 + 0.15 * sway, 0.34);
        if (air) { t1 = t0 + float2(-0.4, 0.15); t2 = t1 + float2(-0.3, 0.1 + 0.3 * ex.y); }
        if (play || dig) { t1 = t0 + float2(-0.3, 0.4 + 0.1 * sin(time * 9.0)); t2 = t1 + float2(-0.1 + 0.2 * sin(time * 9.0), 0.3); }
    }
    float tail = min(segDist(q, t0, t1), segDist(q, t1, t2)) - (0.075 + 0.06 * ex.y);

    float D = min(min(min(body, head), min(earL, earR)), min(min(legsNear, legsFar), tail));
    float3 ink = float3(0.22, 0.12, 0.07);
    float3 fur = float3(0.96, 0.62, 0.27);
    float3 furDark = float3(0.78, 0.43, 0.16);
    float stripes = smoothstep(0.35, 0.8, sin(q.x * 13.0 + q.y * 2.0));

    float4 o = float4(0);
    o = over(o, ink, fillA(D - 0.05, px));
    o = over(o, furDark * 0.9, fillA(legsFar, px));
    o = over(o, mix(fur, furDark, stripes * 0.8), fillA(tail, px));
    float3 bodyCol = mix(fur, furDark, stripes * 0.7);
    float belly = smoothstep(bc.y - br.y * 0.2, bc.y - br.y * 0.85, q.y);
    bodyCol = mix(bodyCol, float3(1.0, 0.93, 0.82), belly * 0.65);
    o = over(o, bodyCol, fillA(body, px));
    o = over(o, ink, fillA(legsNear - 0.035, px));
    o = over(o, fur, fillA(legsNear, px));
    o = over(o, ink, fillA(head - 0.04, px));
    float brow = smoothstep(0.4, 0.9, sin((q.x - hc.x) * 22.0)) * step(hc.y + 0.14, q.y);
    o = over(o, mix(fur, furDark, brow * 0.7), fillA(head, px));
    // Clumps of snow stuck in the fur, mostly on its back and head.
    if (ex2.y > 0.01) {
        float2 cell = floor(q * 3.6);
        float2 f = fract(q * 3.6) - 0.5 - (float2(hash21(cell + 1.3), hash21(cell + 5.9)) - 0.5) * 0.3;
        float n = hash21(cell + 3.1);
        float blob = length(f * float2(1.0, 1.4)) - (0.36 + 0.16 * hash21(cell + 9.7));
        float onTop = smoothstep(bc.y - 0.05, bc.y + br.y * 0.6, q.y) + step(hc.y - 0.1, q.y) * step(length(q - hc), hr);
        float stuck = step(n, ex2.y * 0.95) * clamp(onTop, 0.0, 1.0) * fillA(min(body, head), px);
        o = over(o, float3(0.97, 0.98, 1.0), fillA(blob, px * 3.6) * stuck);
    }
    o = over(o, ink, fillA(min(earL, earR) - 0.035, px));
    o = over(o, fur, fillA(min(earL, earR), px));
    float inL = sdTriangle(q, hc + float2(-0.25, 0.2), hc + float2(-0.21, 0.42), hc + float2(-0.08, 0.3));
    float inR = sdTriangle(q, hc + float2(0.08, 0.32), hc + float2(0.21, 0.43), hc + float2(0.25, 0.18));
    o = over(o, float3(0.98, 0.66, 0.66), fillA(min(inL, inR), px));

    float2 mz = hc + float2(0.17, -0.12);
    o = over(o, float3(1.0, 0.95, 0.88), fillA(sdEll(q, mz, float2(0.16, 0.1)), px));
    float closed = (sleep || flop) ? 1.0 : ex.x;
    float eyeH = mix(0.075, 0.014, closed);
    float2 e1 = hc + float2(0.03, 0.07), e2 = hc + float2(0.21, 0.08);
    float eyes = min(sdEll(q, e1, float2(0.05, eyeH)), sdEll(q, e2, float2(0.045, eyeH)));
    if (ex.y > 0.5 && !sleep) eyes = min(length(q - e1) - 0.08, length(q - e2) - 0.072);
    o = over(o, float3(0.1, 0.13, 0.08), fillA(eyes, px));
    if (closed < 0.5) {
        float shine = min(length(q - e1 - float2(0.015, 0.025)) - 0.018, length(q - e2 - float2(0.015, 0.025)) - 0.016);
        o = over(o, float3(1.0), fillA(shine, px));
    }
    o = over(o, float3(0.95, 0.45, 0.5), fillA(length(q - (hc + float2(0.31, -0.06))) - 0.04, px));
    if (flop) {
        // Tongue out.
        o = over(o, float3(0.2, 0.08, 0.08), fillA(sdEll(q, hc + float2(0.22, -0.22), float2(0.06, 0.075)) - 0.03, px));
        o = over(o, float3(0.98, 0.5, 0.58), fillA(sdEll(q, hc + float2(0.22, -0.22), float2(0.06, 0.075)), px));
    }
    float wh = min(segDist(q, mz + float2(0.1, 0.0), mz + float2(0.46, 0.05)),
                   segDist(q, mz + float2(0.1, -0.03), mz + float2(0.44, -0.11)));
    o = over(o, float3(0.35, 0.25, 0.2), fillA(wh - 0.012, px) * 0.8);
    return o;
}

// A mug of coffee, steaming while it is fresh. Units are the mug's size.
float4 drawMug(float2 p, float px, float steam, float time, float seed) {
    float4 o = float4(0);
    float bodyD = sdBox(p, float2(0.72, 0.85), 0.2);
    float handle = abs(length(p - float2(0.78, 0.05)) - 0.34) - 0.1;
    handle = max(handle, 0.7 - p.x);
    float D = min(bodyD, handle);
    o = over(o, float3(0.2, 0.12, 0.08), fillA(D - 0.1, px));
    o = over(o, float3(0.84, 0.18, 0.18), fillA(handle, px));
    float band = 1.0 - smoothstep(0.16, 0.2, abs(p.y + 0.1));
    o = over(o, mix(float3(0.86, 0.2, 0.2), float3(0.98, 0.96, 0.93), band), fillA(bodyD, px));
    o = over(o, float3(0.36, 0.2, 0.1), fillA(sdEll(p, float2(0.0, 0.76), float2(0.56, 0.1)), px));
    if (steam > 0.01) {
        for (int i = 0; i < 2; i++) {
            float fi = float(i);
            float x0 = -0.25 + fi * 0.5 + sin(p.y * 4.0 - time * 3.0 + fi * 2.0 + seed) * 0.15;
            float fade = smoothstep(0.95, 1.2, p.y) * (1.0 - smoothstep(1.5, 2.3, p.y)) * steam;
            o = over(o, float3(0.97, 0.97, 1.0), fillA(abs(p.x - x0) - 0.08, px) * fade * 0.75);
        }
    }
    return o;
}

float4 drawHeart(float2 uv, float px) {
    float2 q = uv * 0.62 + float2(0.0, 0.4);
    float d = sdHeart(q) / 0.62;
    float4 o = over(float4(0), float3(0.55, 0.06, 0.16), fillA(d - 0.12, px));
    return over(o, float3(0.97, 0.32, 0.45), fillA(d, px));
}

fragment float4 spriteF(SOut in [[stage_in]], constant U& u [[buffer(0)]]) {
    float2 uv = in.uv;
    float d = length(uv);
    if (in.kind > 4.5) {
        float px = 1.0 / max(in.r, 1.0);
        float4 c;
        if (in.kind < 5.5) c = drawCat(uv, px, in.seed, in.facing, in.ex, in.ex2, u.time);
        else if (in.kind < 6.5) c = drawMug(uv, px, in.ex.x, u.time, in.seed);
        else c = drawHeart(uv, px);
        return c * in.alpha;
    }
    if (in.kind < 0.5) {
        float core = 1.0 - smoothstep(0.3, 1.0, d);
        float a = core * in.alpha * u.opacity;
        float3 c = float3(0.97, 0.985, 1.0);
        return float4(c * a, a);
    }
    float aa = 1.5 / max(in.r, 1.0);
    float4 outc = float4(0);

    // The ball itself.
    float edge = 1.0 - smoothstep(1.0 - aa, 1.0, d);
    if (edge > 0.0) {
        float z = sqrt(max(0.0, 1.0 - d * d));
        float3 n = float3(uv, z);
        float3 L = normalize(float3(-0.45, 0.65, 0.62));
        float diff = max(0.0, dot(n, L));
        float grain = hash21(floor((uv + in.seed) * max(in.r, 4.0) * 0.4));
        float3 shadow = float3(0.68, 0.75, 0.89);
        float3 c = mix(shadow, float3(1.0), 0.22 + 0.78 * diff);
        c -= grain * 0.06;
        c -= smoothstep(0.8, 1.0, d) * 0.06;
        float spec = pow(max(0.0, dot(reflect(-L, n), float3(0, 0, 1))), 24.0);
        c += spec * 0.15;
        outc = float4(min(c, 1.0), 1.0) * edge;
    }

    if (in.kind > 1.5 && in.kind < 3.5) {
        // A snowman's face: coal eyes, a carrot nose and a coal smile.
        float px = aa * 1.2;
        float eyes = min(length(uv - float2(-0.32, 0.25)), length(uv - float2(0.30, 0.27)));
        float eye = 1.0 - smoothstep(0.11 - px, 0.11 + px, eyes);
        float smile = 1e3;
        for (int i = 0; i < 5; i++) {
            float t = (float(i) - 2.0) * 0.17;
            float2 c = float2(t * 1.6, -0.32 - 0.6 * (0.09 - t * t) * 1.5);
            smile = min(smile, length(uv - c));
        }
        float mouth = 1.0 - smoothstep(0.065 - px, 0.065 + px, smile);
        float coal = max(eye, mouth) * edge;
        outc = mix(outc, float4(0.08, 0.08, 0.1, 1.0), coal);
        float carrot = segDist(uv, float2(-0.02, 0.02), float2(0.62, -0.06));
        float width = mix(0.11, 0.025, clamp((uv.x + 0.02) / 0.64, 0.0, 1.0));
        float nose = 1.0 - smoothstep(width - px, width + px, carrot);
        outc = mix(outc, float4(0.95, 0.47, 0.12, 1.0), nose);
    }
    if (in.kind > 3.5) {
        // A snowman's body: coal buttons and two twig arms.
        float px = aa * 1.2;
        float b = 1e3;
        for (int i = 0; i < 3; i++) { b = min(b, length(uv - float2(0.0, 0.42 - float(i) * 0.36))); }
        float buttons = (1.0 - smoothstep(0.085 - px, 0.085 + px, b)) * edge;
        outc = mix(outc, float4(0.08, 0.08, 0.1, 1.0), buttons);
        float s = uv.x < 0.0 ? -1.0 : 1.0;
        float2 q = float2(abs(uv.x), uv.y);
        float arm = segDist(q, float2(0.8, 0.12), float2(1.75, 0.62));
        arm = min(arm, segDist(q, float2(1.45, 0.46), float2(1.6, 0.82)));
        arm = min(arm, segDist(q, float2(1.5, 0.49), float2(1.85, 0.42)));
        float armA = (1.0 - smoothstep(0.045 - px, 0.045 + px, arm)) * (1.0 - edge);
        (void)s;
        outc = mix(outc, float4(0.36, 0.22, 0.12, 1.0), armA);
    }
    if (in.kind > 2.5 && in.kind < 3.5) {
        // A top hat with a red band.
        float px = aa * 1.2;
        float brim = step(abs(uv.x), 0.78) * step(0.72, uv.y) * step(uv.y, 0.86);
        float crown = step(abs(uv.x), 0.5) * step(0.84, uv.y) * step(uv.y, 1.62);
        float band = step(abs(uv.x), 0.505) * step(0.88, uv.y) * step(uv.y, 1.02);
        float hat = max(brim, crown);
        float shade = 0.12 + 0.08 * (uv.x * -0.5 + 0.5);
        float4 hatc = float4(float3(shade), 1.0);
        hatc = mix(hatc, float4(0.78, 0.12, 0.14, 1.0), band);
        (void)px;
        outc = mix(outc, hatc, hat);
    }
    float a = in.alpha * u.opacity;
    return float4(outc.rgb * a, outc.a * a);
}

vertex HOut heapV(uint vid [[vertex_id]], const device HV* v [[buffer(0)]], constant U& u [[buffer(1)]]) {
    HV h = v[vid];
    HOut o;
    o.pos = float4(float2(h.px, h.py) / u.size * 2.0 - 1.0, 0, 1);
    o.depth = h.depth;
    o.world = float2(h.px, h.py);
    return o;
}

fragment float4 heapF(HOut in [[stage_in]], constant U& u [[buffer(0)]]) {
    float d = max(in.depth, 0.0);
    float3 top = float3(0.995, 0.997, 1.0);
    float3 deep = float3(0.80, 0.86, 0.95);
    float3 c = mix(top, deep, smoothstep(0.0, 26.0, d));
    c -= (1.0 - smoothstep(0.0, 1.2, d)) * 0.02;
    c -= hash21(floor(in.world * 0.8)) * 0.035;
    float2 cell = floor(in.world / 2.0);
    float sp = hash21(cell + 7.0);
    if (sp > 0.994 && d < 8.0) {
        float tw = 0.5 + 0.5 * sin(u.time * 2.5 + sp * 900.0);
        c += tw * tw * 0.45 * float3(0.85, 0.92, 1.0);
    }
    // Soften the top edge over about a pixel, in place of multisampling.
    float a = u.opacity * clamp(d * u.scale + 0.35, 0.0, 1.0);
    return float4(min(c, 1.0) * a, a);
}
"""

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let spritePipeline: MTLRenderPipelineState
    private let heapPipeline: MTLRenderPipelineState
    private let inFlight = DispatchSemaphore(value: 3)
    private var spriteBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var heapBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var frame = 0
    private var lastTime = CACurrentMediaTime()
    private var sprites: [SpriteInstance] = []
    private var heap: [HeapVertex] = []

    /// Called once a frame before drawing, with the time since the last frame.
    var onFrame: (Float) -> Void = { _ in }
    let simulation: SnowSimulation

    convenience init?(view: MTKView, simulation: SnowSimulation) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice() else { return nil }
        self.init(device: device, pixelFormat: view.colorPixelFormat, sampleCount: view.sampleCount,
                  simulation: simulation)
    }

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat, sampleCount: Int, simulation: SnowSimulation) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.simulation = simulation
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            func pipeline(_ v: String, _ f: String) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = library.makeFunction(name: v)
                d.fragmentFunction = library.makeFunction(name: f)
                d.rasterSampleCount = sampleCount
                let a = d.colorAttachments[0]!
                a.pixelFormat = pixelFormat
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = .one
                a.sourceAlphaBlendFactor = .one
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: d)
            }
            spritePipeline = try pipeline("spriteV", "spriteF")
            heapPipeline = try pipeline("heapV", "heapF")
        } catch {
            NSLog("WinterPurrch: shader error: \(error)")
            return nil
        }
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastTime, 0), 1.0 / 20))
        lastTime = now
        onFrame(dt)

        buildGeometry()
        inFlight.wait()
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else {
            inFlight.signal()
            return
        }
        encode(encoder, size: view.bounds.size, scale: Float(view.drawableSize.width / max(view.bounds.width, 1)))
        let semaphore = inFlight
        commands.addCompletedHandler { _ in semaphore.signal() }
        commands.present(drawable)
        commands.commit()
    }

    /// Draws the current state into an encoder whose target is `size` points at `scale` pixels per point.
    func encode(_ encoder: MTLRenderCommandEncoder, size: CGSize, scale: Float) {
        frame = (frame + 1) % 3
        var uniforms = Uniforms(size: SIMD2(Float(size.width), Float(size.height)),
                                time: simulation.time, scale: scale, opacity: simulation.settings.opacity)

        if !heap.isEmpty {
            let buffer = ensure(&heapBuffers, frame, bytes: heap.count * MemoryLayout<HeapVertex>.stride)
            heap.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            encoder.setRenderPipelineState(heapPipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: heap.count)
        }
        if !sprites.isEmpty {
            let buffer = ensure(&spriteBuffers, frame, bytes: sprites.count * MemoryLayout<SpriteInstance>.stride)
            sprites.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            encoder.setRenderPipelineState(spritePipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: sprites.count)
        }
        encoder.endEncoding()
    }

    /// Renders the current state to an image, for the self-test.
    func snapshot(width: Int, height: Int, background: MTLClearColor) -> CGImage? {
        buildGeometry()
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                          mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let target = device.makeTexture(descriptor: td) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = background
        pass.colorAttachments[0].storeAction = .store
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encode(encoder, size: CGSize(width: width, height: height), scale: 1)
        commands.commit()
        commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    private func ensure(_ ring: inout [MTLBuffer?], _ i: Int, bytes: Int) -> MTLBuffer {
        if let b = ring[i], b.length >= bytes { return b }
        let b = device.makeBuffer(length: max(bytes * 3 / 2, 16384), options: .storageModeShared)!
        ring[i] = b
        return b
    }

    func buildGeometry() {
        let sim = simulation
        sprites.removeAll(keepingCapacity: true)
        heap.removeAll(keepingCapacity: true)

        for l in sim.ledges.values {
            let n = l.h.count
            var i = 0
            while i < n - 1 {
                defer { i += 1 }
                guard l.visible[i], l.visible[i + 1] else { continue }
                let h0 = l.h[i], h1 = l.h[i + 1]
                guard h0 > 0.08 || h1 > 0.08 else { continue }
                let xa = l.centerX(i), xb = l.centerX(i + 1)
                let y = l.y
                let bl = HeapVertex(px: xa, py: y, depth: h0, pad: 0)
                let tl = HeapVertex(px: xa, py: y + h0, depth: 0, pad: 0)
                let br = HeapVertex(px: xb, py: y, depth: h1, pad: 0)
                let tr = HeapVertex(px: xb, py: y + h1, depth: 0, pad: 0)
                heap.append(contentsOf: [bl, tl, tr, bl, tr, br])
            }
        }

        for f in sim.flakes {
            let a: Float = f.kind == .flake ? (0.35 + f.depth * 0.6) : 0.95
            sprites.append(SpriteInstance(px: f.p.x, py: f.p.y, r: f.r, alpha: a, kind: 0, seed: f.seed, ext: 1, pad: 0))
        }
        for b in sim.balls {
            let kind: Float = b.body ? 4 : (b.hat ? 3 : (b.face ? 2 : 1))
            let ext: Float = b.body ? 1.95 : (b.hat ? 1.7 : 1.05)
            sprites.append(SpriteInstance(px: b.p.x, py: b.p.y, r: b.r, alpha: 1, kind: kind, seed: b.seed,
                                          ext: ext, pad: 0))
        }
        for m in sim.mugs {
            let c = m.center
            sprites.append(SpriteInstance(px: c.x, py: c.y, r: Mug.size, alpha: 1, kind: 6, seed: m.offset, ext: 2.4,
                                          pad: 1, a: max(0, 1 - m.age / 150)))
        }
        if let cat = sim.cat, cat.state != .away {
            let c = cat.p + SIMD2(0, cat.size)
            sprites.append(SpriteInstance(px: c.x, py: c.y, r: cat.size, alpha: 1, kind: 5, seed: cat.phase, ext: 1.8,
                                          pad: cat.facing, a: cat.blink, b: cat.startle,
                                          c: cat.state == .walking ? 1 : 0, d: cat.pose,
                                          e: cat.state == .shaking ? min(1, cat.shake * 2) : 0, f: cat.snowy,
                                          g: cat.angle))
            if cat.carrying {
                let m = cat.p + SIMD2(cat.facing * cat.size * 1.12, cat.size * 0.62)
                sprites.append(SpriteInstance(px: m.x, py: m.y, r: Mug.size * 0.8, alpha: 1, kind: 6, seed: 0, ext: 2.4,
                                              pad: 1, a: 1))
            }
        }
        for h in sim.hearts {
            sprites.append(SpriteInstance(px: h.p.x, py: h.p.y, r: 5 * (sim.cat?.size ?? 18) / 18, alpha: min(1, h.life * 2), kind: 7, seed: 0,
                                          ext: 1.3, pad: 1))
        }
    }
}
