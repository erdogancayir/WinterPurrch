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

// The cat: a fluffy grey-and-white kitten with big eyes. Units are the cat's size; y = 0 is the ground under its feet.
// The body is seen side on and the face always turns to the viewer; sitting, it faces the viewer entirely.
// ex: x blink, y startle, z moving, w pose (0 walk, 1 sit, 2 sleep, 3 airborne, 4 playing, 5 shaking, 6 flopped,
// 7 digging, 8 petted). ex2: x shake, y snow in its fur, z tumble angle.
struct Coat { float3 main; float3 dark; float3 white; float3 iris; float3 irisLight; float fluff; float stripes; float blaze; float chub; };

// 0: the grey-and-white longhair. 1: its friend, a chubby ginger tabby with short fur and amber eyes.
Coat coatFor(float i) {
    Coat k;
    if (i < 0.5) {
        k.main = float3(0.58, 0.59, 0.63); k.dark = float3(0.43, 0.44, 0.48); k.white = float3(0.985, 0.98, 0.97);
        k.iris = float3(0.27, 0.55, 0.53); k.irisLight = float3(0.47, 0.78, 0.7);
        k.fluff = 1.0; k.stripes = 0.0; k.blaze = 1.0; k.chub = 1.0;
    } else {
        k.main = float3(0.98, 0.67, 0.34); k.dark = float3(0.84, 0.46, 0.17); k.white = float3(1.0, 0.96, 0.9);
        k.iris = float3(0.76, 0.5, 0.08); k.irisLight = float3(0.98, 0.8, 0.32);
        k.fluff = 0.3; k.stripes = 1.0; k.blaze = 0.0; k.chub = 1.1;
    }
    return k;
}
constant float3 catPink = float3(0.97, 0.7, 0.73);
constant float3 catLine = float3(0.3, 0.3, 0.35);

// A soft, tufted edge: pushes an outline out and in around `c`.
float fur(float2 p, float2 c, float k) {
    float2 d = p - c;
    float a = atan2(d.y, d.x);
    float t = 0.5 + 0.5 * sin(a * k + sin(a * 3.0) * 2.0);
    return t * t * (3.0 - 2.0 * t) * 0.7;   // rounded tufts rather than spikes
}

float catEars(float2 q, float2 hc, float s) {
    float l = sdTriangle(q, hc + float2(-0.43, 0.12) * s, hc + float2(-0.36, 0.68) * s, hc + float2(-0.05, 0.4) * s);
    float r = sdTriangle(q, hc + float2(0.05, 0.4) * s, hc + float2(0.36, 0.68) * s, hc + float2(0.43, 0.12) * s);
    return min(l, r) - 0.045 * s;
}

float catInnerEars(float2 q, float2 hc, float s) {
    float l = sdTriangle(q, hc + float2(-0.35, 0.22) * s, hc + float2(-0.32, 0.56) * s, hc + float2(-0.13, 0.4) * s);
    float r = sdTriangle(q, hc + float2(0.13, 0.4) * s, hc + float2(0.32, 0.56) * s, hc + float2(0.35, 0.22) * s);
    return min(l, r) - 0.02 * s;
}

float catHead(float2 q, float2 hc, float s, Coat k) {
    float round = length(q - hc) - 0.44 * s;
    float cheeks = sdEll(q, hc + float2(0.0, -0.1) * s, float2(0.53, 0.35) * s);
    return min(round, cheeks) - 0.03 * s * k.fluff * fur(q, hc, 18.0);
}

float4 catFace(float4 o, float2 q, float2 fc, float s, float blink, float startle, bool happy, bool tongue, float px, Coat k, float turn) {
    // Turned away from the viewer, the face slides towards the front of the head and the far eye narrows.
    fc += float2(0.26 * turn, -0.02 * turn) * s;
    o = over(o, k.white, fillA(sdEll(q, fc + float2(0.0, -0.17) * s, float2(0.31 - 0.08 * turn, 0.21) * s), px * 2.0));
    o = over(o, k.white, fillA(sdEll(q, fc + float2(0.0, 0.08) * s, float2(0.07, 0.3) * s), px * 3.0) * k.blaze);
    float2 look = float2(0.03 * turn, 0.0) * s;
    for (int i = 0; i < 2; i++) {
        float sx = i == 0 ? -1.0 : 1.0;
        float far = i == 0 ? turn * 1.15 : 0.0;       // the eye further from where it is looking
        float2 e = fc + float2(sx * 0.17 * (1.0 - 0.3 * turn) + 0.04 * far, 0.04) * s;
        o = over(o, float3(0.98, 0.6, 0.65), fillA(length(q - (fc + float2(sx * 0.26 * (1.0 - 0.3 * turn), -0.14) * s)) - 0.065 * s * (1.0 - 0.4 * far), px * 4.0) * 0.4);
        if (happy) {
            float2 ac = e + float2(0.0, -0.04) * s;
            float arc = max(abs(length((q - ac) / float2(1.0 - 0.45 * far, 1.0)) - 0.07 * s) - 0.014 * s, ac.y - q.y);
            o = over(o, catLine, fillA(arc, px));
            continue;
        }
        float2 er = float2(0.115 * (1.0 - 0.5 * far), 0.13) * s * (1.0 + 0.12 * startle);
        float sclera = sdEll(q, e, er);
        o = over(o, float3(0.2, 0.2, 0.25), fillA(sclera - 0.016 * s, px));
        o = over(o, float3(1.0), fillA(sclera, px));
        float2 ic = e + float2(0.0, 0.012) * s + look;
        float2 d = (q - ic) / float2(1.0 - 0.45 * far, 1.0);
        float r = length(d);
        o = over(o, k.iris, fillA(max(r - 0.09 * s, sclera), px));
        o = over(o, k.irisLight, fillA(max(r - 0.062 * s, sclera), px * 3.0) * 0.7);
        o = over(o, float3(0.05, 0.06, 0.08), fillA(max(r - (0.05 + 0.02 * startle) * s, sclera), px));
        o = over(o, float3(1.0), fillA(length(q - (ic + float2(0.032, 0.037) * s)) - 0.027 * s * (1.0 - 0.4 * far), px));
        o = over(o, float3(1.0), fillA(length(q - (ic + float2(-0.028, -0.032) * s)) - 0.013 * s, px));
        if (blink > 0.01) {
            float lid = max(sclera - 0.018 * s, e.y + er.y * (1.0 - 2.0 * blink) - q.y);
            o = over(o, k.main, fillA(lid, px));
        }
    }
    float2 nc = fc + float2(0.03 * turn, 0.0) * s;
    float nose = sdTriangle(q, nc + float2(-0.05, -0.065) * s, nc + float2(0.05, -0.065) * s, nc + float2(0.0, -0.112) * s);
    o = over(o, float3(0.92, 0.52, 0.58), fillA(nose - 0.016 * s, px));
    float2 m1 = nc + float2(-0.046 * (1.0 - 0.4 * turn), -0.125) * s, m2 = nc + float2(0.046, -0.125) * s;
    float w = min(abs(length(q - m1) - 0.046 * s * (1.0 - 0.4 * turn)), abs(length(q - m2) - 0.046 * s)) - 0.011 * s;
    w = max(w, q.y - (nc.y - 0.125 * s));
    o = over(o, float3(0.38, 0.26, 0.27), fillA(w, px));
    if (tongue) {
        o = over(o, float3(0.95, 0.48, 0.56), fillA(sdEll(q, nc + float2(0.0, -0.205) * s, float2(0.05, 0.065) * s), px));
    }
    for (int i = 0; i < 2; i++) {
        float sx = i == 0 ? -1.0 : 1.0;
        float len = i == 0 ? 1.0 - 0.6 * turn : 1.0;
        float2 a = nc + float2(sx * 0.2 * (1.0 - 0.3 * turn), -0.15) * s;
        float wh = min(segDist(q, a, a + float2(sx * 0.34, 0.06) * s * len),
                       segDist(q, a + float2(0.0, -0.03) * s, a + float2(sx * 0.32, -0.07) * s * len));
        o = over(o, float3(0.86, 0.86, 0.9), fillA(wh - 0.007 * s, px) * 0.85);
    }
    return o;
}

float4 catHeadFull(float4 o, float2 q, float2 hc, float s, float blink, float startle, bool happy, bool tongue, float px, Coat k, float turn) {
    float head = catHead(q, hc, s, k);
    float ears = catEars(q, hc, s);
    o = over(o, catLine, fillA(min(head, ears) - 0.025 * s, px) * 0.9);
    o = over(o, k.main, fillA(ears, px));
    o = over(o, catPink, fillA(catInnerEars(q, hc, s), px));
    float shade = 0.92 + 0.08 * smoothstep(hc.y - 0.4 * s, hc.y + 0.4 * s, q.y);
    o = over(o, k.main * shade, fillA(head, px));
    if (k.stripes > 0.5) {
        // Tabby markings: an "M" on the forehead and stripes on the cheeks.
        float m = 1e3;
        for (int i = -1; i <= 1; i++) {
            float x = float(i) * 0.11 + 0.12 * turn;
            m = min(m, segDist(q, hc + float2(x, 0.17) * s, hc + float2(x * 0.8, 0.36) * s));
        }
        for (int i = 0; i < 2; i++) {
            float sx = i == 0 ? -1.0 : 1.0;
            m = min(m, segDist(q, hc + float2(sx * 0.5, -0.02) * s, hc + float2(sx * 0.36, 0.0) * s));
        }
        o = over(o, k.dark, fillA(max(m - 0.028 * s, head), px * 2.0) * 0.85);
    }
    return catFace(o, q, hc, s, blink, startle, happy, tongue, px, k, turn);
}

float4 drawCat(float2 uv, float px, float phase, float facing, float4 ex, float4 ex2, float time) {
    Coat k = coatFor(floor(ex2.w + 0.001));
    // How far the head is turned away from the viewer, towards where it is going.
    float turn = 1.0 - clamp(fract(ex2.w) * 2.0, 0.0, 1.0);
    float2 q = float2(uv.x * facing, uv.y + 1.0);
    if (ex2.z != 0.0) {
        float2 c0 = float2(0.0, 0.75);
        float ca = cos(ex2.z), sa = sin(ex2.z);
        float2 d = q - c0;
        q = c0 + float2(ca * d.x - sa * d.y, sa * d.x + ca * d.y);
    }
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
    bool pet = abs(pose - 8.0) < 0.5;
    bool groom = abs(pose - 9.0) < 0.5;       // licking a paw and washing its face
    bool groomBack = abs(pose - 10.0) < 0.5;  // turned round, licking its back
    bool lick = abs(pose - 11.0) < 0.5;       // washing its friend's head
    bool enjoy = abs(pose - 12.0) < 0.5;      // being washed, eyes shut
    float sway = sin(time * 2.3);
    float4 o = float4(0);

    if (sit || pet || groom || lick || enjoy) {
        // Sitting up, facing the viewer.
        float2 hc = float2(0.0, 1.5);
        float s = 1.1;
        if (lick) hc += float2(0.2, -0.06);      // leaning in to its friend
        if (enjoy) hc += float2(0.1, -0.04);     // tilting its head into it
        float body = min(sdEll(q, float2(0.0, 0.52), float2(0.6 * k.chub, 0.52)), sdEll(q, float2(0.0, 0.95), float2(0.43 * k.chub, 0.42)));
        body -= 0.03 * k.fluff * fur(q, float2(0.0, 0.75), 20.0);
        float haunch = min(sdEll(q, float2(-0.46, 0.25), float2(0.27, 0.25)), sdEll(q, float2(0.46, 0.25), float2(0.27, 0.25)));
        float2 t0 = float2(0.4, 0.12), t1 = float2(0.86, 0.14), t2 = float2(1.02, 0.46 + 0.08 * sway);
        float tail = min(segDist(q, t0, t1), segDist(q, t1, t2)) - 0.14 - 0.03 * k.fluff * fur(q, t1, 12.0) - 0.05 * ex.y;
        float legs, paws;
        if (pet) {
            // Holding a heart up to its chest.
            legs = min(segDist(q, float2(-0.32, 1.0), float2(-0.19, 0.86)), segDist(q, float2(0.32, 1.0), float2(0.19, 0.86))) - 0.11;
            paws = min(length(q - float2(-0.17, 0.84)), length(q - float2(0.17, 0.84))) - 0.095;
        } else if (groom) {
            // One paw up at its mouth.
            legs = segDist(q, float2(-0.17, 0.78), float2(-0.17, 0.1)) - 0.115;
            paws = sdEll(q, float2(-0.18, 0.07), float2(0.14, 0.08));
        } else {
            legs = min(segDist(q, float2(-0.17, 0.78), float2(-0.17, 0.1)), segDist(q, float2(0.17, 0.78), float2(0.17, 0.1))) - 0.115;
            paws = min(sdEll(q, float2(-0.18, 0.07), float2(0.14, 0.08)), sdEll(q, float2(0.18, 0.07), float2(0.14, 0.08)));
        }
        float backPaws = min(sdEll(q, float2(-0.5, 0.05), float2(0.15, 0.07)), sdEll(q, float2(0.5, 0.05), float2(0.15, 0.07)));
        float D = min(min(min(body, haunch), min(tail, legs)), min(paws, backPaws));
        o = over(o, catLine, fillA(D - 0.025, px) * 0.9);
        o = over(o, mix(k.main, k.dark, smoothstep(0.7, 1.05, q.x)), fillA(tail, px));
        o = over(o, k.dark, fillA(tail, px) * k.stripes * smoothstep(0.5, 0.85, sin(length(q - t0) * 16.0)) * 0.8);
        o = over(o, k.main * 0.95, fillA(haunch, px));
        o = over(o, k.white, fillA(backPaws, px));
        o = over(o, k.main, fillA(body, px));
        if (k.stripes > 0.5) {
            float band = smoothstep(0.5, 0.85, sin(q.y * 12.0)) * smoothstep(0.22, 0.45, abs(q.x));
            o = over(o, k.dark, fillA(body, px) * band * 0.75);
        }
        // White bib down the chest and belly.
        o = over(o, k.white, fillA(max(sdEll(q, float2(0.0, 0.72), float2(0.31, 0.6)), body), px * 3.0));
        if (pet) {
            float2 hp = (q - float2(0.0, 0.52)) / 0.42;
            float hd = sdHeart(float2(hp.x, hp.y)) * 0.42;
            o = over(o, float3(0.55, 0.08, 0.16), fillA(hd - 0.02, px));
            o = over(o, float3(0.97, 0.35, 0.42), fillA(hd, px));
            o = over(o, float3(1.0, 0.75, 0.78), fillA(length(q - float2(-0.1, 0.8)) - 0.045, px * 2.0) * 0.8);
        }
        o = over(o, catLine, fillA(legs - 0.022, px) * 0.6);
        o = over(o, k.main, fillA(legs, px));
        o = over(o, k.white, fillA(paws, px));
        o = over(o, catLine, fillA(abs(paws) - 0.008, px) * 0.4);
        o = catHeadFull(o, q, hc, s, ex.x, ex.y, pet || groom || lick || enjoy, groom || lick, px, k,
                        lick ? 1.0 : (groom || enjoy ? 0.0 : turn));
        if (groom) {
            // The paw at its mouth: licked, then drawn up over the cheek.
            float wv = sin(time * 6.0);
            float2 up = float2(0.24 + 0.05 * wv, 1.2 + 0.12 * max(0.0, wv));
            float arm = segDist(q, float2(0.3, 0.95), up) - 0.12;
            float paw = length(q - up) - 0.15;
            o = over(o, catLine, fillA(min(arm, paw) - 0.022, px) * 0.9);
            o = over(o, k.main, fillA(arm, px));
            o = over(o, k.white, fillA(paw, px));
            float pad = sdEll(q, up + float2(0.0, -0.035), float2(0.065, 0.05));
            float toes = min(min(length(q - (up + float2(-0.065, 0.055))), length(q - (up + float2(0.0, 0.08)))),
                             length(q - (up + float2(0.065, 0.055)))) - 0.03;
            o = over(o, float3(0.95, 0.6, 0.66), fillA(min(pad, toes), px));
        }
    } else {
        float2 bc = float2(0.0, 0.66), br = float2(0.74, 0.36);
        float2 hc = float2(0.74, 1.12);
        float s = 0.95;
        if (sleep) { bc = float2(-0.05, 0.38); br = float2(0.84, 0.37); hc = float2(0.62, 0.6); s = 0.88; }
        if (air)   { bc = float2(0.0, 0.85); br = float2(0.88, 0.32) * (1.0 + 0.12 * ex.y); hc = float2(0.86, 1.18); }
        if (play)  { bc = float2(-0.05, 0.56); br = float2(0.78, 0.32); hc = float2(0.78, 0.82); }
        if (dig)   { bc = float2(-0.05, 0.56); br = float2(0.78, 0.32); hc = float2(0.8, 0.68); }
        if (groomBack) { bc = float2(0.0, 0.4); br = float2(0.84, 0.38); hc = float2(-0.22, 0.88 + 0.04 * sin(time * 7.0)); }
        if (flop)  { bc = float2(0.0, 0.34); br = float2(0.84, 0.32); hc = float2(0.86, 0.46); }

        br.y *= k.chub;
        if (sleep) br.y *= 1.0 + 0.035 * sin(time * 2.2);   // breathing
        float body = sdEll(q, bc, br);
        if (play || dig) body = min(body, sdEll(q, float2(-0.52, 0.76), float2(0.36, 0.34)));
        body -= 0.03 * k.fluff * fur(q, bc, 22.0);

        float legsNear = 1e3, legsFar = 1e3;
        if (!sleep && !flop && !groomBack) {
            float hipY = bc.y - br.y * 0.35;
            for (int i = 0; i < 4; i++) {
                float hx = (i == 0) ? -0.48 : (i == 1) ? -0.3 : (i == 2) ? 0.36 : 0.54;
                float off = (i == 0 || i == 3) ? 0.0 : 3.14159;
                float2 hip = float2(hx, hipY);
                float sw = sin(phase + off) * ex.z;
                float2 foot = float2(hx + sw * 0.22, 0.06 + max(0.0, cos(phase + off)) * 0.1 * ex.z);
                if (air) foot = hip + (i < 2 ? float2(-0.4, -0.28) : float2(0.4, -0.28));
                if (play) {
                    hip.y = (i < 2) ? 0.66 : 0.45;
                    if (i == 2) foot = float2(0.62 + 0.32 * max(0.0, sin(phase)), 0.06 + 0.38 * max(0.0, sin(phase)));
                    else if (i == 3) foot = float2(0.7, 0.05);
                    else foot = float2(hx, 0.05);
                }
                if (dig) {
                    hip.y = (i < 2) ? 0.66 : 0.42;
                    float ph = phase + (i == 2 ? 0.0 : 3.14159);
                    if (i >= 2) foot = float2(0.68 + 0.16 * sin(ph), 0.05 + 0.2 * max(0.0, sin(ph)));
                    else foot = float2(hx, 0.05);
                }
                float dl = segDist(q, hip, foot) - 0.1;
                if (i == 0 || i == 2) legsNear = min(legsNear, dl); else legsFar = min(legsFar, dl);
            }
        }
        if (flop) {
            for (int i = 0; i < 4; i++) {
                float hx = (i == 0) ? -0.5 : (i == 1) ? -0.3 : (i == 2) ? 0.35 : 0.55;
                float wob = sin(time * 3.0 + float(i)) * 0.04;
                float2 foot = float2(hx + 0.18 * (i < 2 ? -1.0 : 1.0) + wob, 0.92 + 0.08 * float(i % 2));
                float dl = segDist(q, float2(hx, 0.5), foot) - 0.1;
                if (i == 0 || i == 2) legsNear = min(legsNear, dl); else legsFar = min(legsFar, dl);
            }
        }

        float2 t0, t1, t2;
        if (sleep) { t0 = float2(-0.6, 0.4); t1 = t0; t2 = t0; }   // drawn wrapped round the front instead
        else if (groomBack) { t0 = float2(-0.78, 0.25); t1 = float2(-0.55, 0.06); t2 = float2(0.3, 0.08); }
        else if (flop) { t0 = float2(-0.78, 0.3); t1 = float2(-1.08, 0.16); t2 = float2(-1.32, 0.12 + 0.05 * sway); }
        else {
            t0 = bc + float2(-br.x * 0.9, br.y * 0.3);
            t1 = t0 + float2(-0.32, 0.32 + 0.08 * sway);
            t2 = t1 + float2(-0.06 + 0.15 * sway, 0.34);
            if (air) { t1 = t0 + float2(-0.4, 0.15); t2 = t1 + float2(-0.3, 0.1 + 0.3 * ex.y); }
            if (play || dig) { t1 = t0 + float2(-0.3, 0.4 + 0.1 * sin(time * 9.0)); t2 = t1 + float2(-0.1 + 0.2 * sin(time * 9.0), 0.3); }
        }
        float tail = min(segDist(q, t0, t1), segDist(q, t1, t2)) - 0.13 - 0.03 * k.fluff * fur(q, t1, 12.0) - 0.06 * ex.y;

        float head = catHead(q, hc, s, k);
        float D = min(min(body, min(head, catEars(q, hc, s))), min(min(legsNear, legsFar), tail));
        o = over(o, catLine, fillA(D - 0.025, px) * 0.9);
        float3 legFar = k.main * 0.82;
        o = over(o, legFar, fillA(legsFar, px));
        o = over(o, k.white * 0.86, fillA(max(legsFar, q.y - 0.24), px));
        o = over(o, mix(k.main, k.dark, smoothstep(0.0, 0.3, length(q - t2))), fillA(tail, px));
        o = over(o, k.dark, fillA(tail, px) * k.stripes * smoothstep(0.5, 0.85, sin(length(q - t0) * 16.0)) * 0.8);
        float shade = 0.9 + 0.1 * smoothstep(bc.y - br.y, bc.y + br.y, q.y);
        o = over(o, k.main * shade, fillA(body, px));
        if (k.stripes > 0.5) {
            float band = smoothstep(0.5, 0.85, sin(q.x * 11.0 + sin(q.y * 6.0) * 0.6));
            o = over(o, k.dark, fillA(body, px) * band * smoothstep(bc.y - 0.05, bc.y + br.y * 0.5, q.y) * 0.8);
        }
        // White underside and chest.
        float belly = smoothstep(bc.y - 0.02, bc.y - 0.2, q.y);
        float chest = smoothstep(bc.x + br.x * 0.35, bc.x + br.x * 0.8, q.x);
        o = over(o, k.white, fillA(body, px) * clamp(max(belly, chest), 0.0, 1.0));
        o = over(o, catLine, fillA(legsNear - 0.022, px) * 0.6);
        o = over(o, k.main, fillA(legsNear, px));
        o = over(o, k.white, fillA(max(legsNear, q.y - 0.24), px));
        if (ex2.y > 0.01) {
            float2 cell = floor(q * 3.6);
            float2 f = fract(q * 3.6) - 0.5 - (float2(hash21(cell + 1.3), hash21(cell + 5.9)) - 0.5) * 0.3;
            float n = hash21(cell + 3.1);
            float blob = length(f * float2(1.0, 1.4)) - (0.36 + 0.16 * hash21(cell + 9.7));
            float onTop = smoothstep(bc.y - 0.05, bc.y + br.y * 0.6, q.y);
            float stuck = step(n, ex2.y * 0.95) * onTop * fillA(body, px);
            o = over(o, float3(0.97, 0.98, 1.0), fillA(blob, px * 3.6) * stuck);
        }
        bool happy = sleep || flop || groomBack;
        o = catHeadFull(o, q, hc, s, ex.x, ex.y, happy, flop || groomBack, px, k, groomBack || sleep ? 0.0 : turn);
        if (sleep) {
            // Curled up: chin on its front paws, tail wrapped round the front with its darker tip.
            float paws = min(sdEll(q, float2(0.48, 0.1), float2(0.17, 0.085)), sdEll(q, float2(0.76, 0.09), float2(0.16, 0.08)));
            o = over(o, catLine, fillA(paws - 0.022, px) * 0.8);
            o = over(o, k.white, fillA(paws, px));
            // From behind the rump, round under the body, tapering, the tip curled up.
            float2 w0 = float2(-0.9, 0.4), w1 = float2(-0.86, 0.14), w2 = float2(-0.6, 0.04), w3 = float2(0.18, 0.06);
            float2 w4 = float2(0.36, 0.17 + 0.02 * sway);
            float path = min(min(segDist(q, w0, w1), segDist(q, w1, w2)), min(segDist(q, w2, w3), segDist(q, w3, w4)));
            float taper = mix(0.12, 0.065, smoothstep(-0.7, 0.36, q.x));
            float wrap = path - taper - 0.025 * k.fluff * fur(q, w2, 12.0);
            o = over(o, catLine, fillA(wrap - 0.025, px) * 0.9);
            float3 tailCol = mix(k.dark, k.main, smoothstep(0.06, 0.3, length(q - w4)));
            o = over(o, tailCol, fillA(wrap, px));
            o = over(o, k.dark, fillA(wrap, px) * k.stripes * smoothstep(0.5, 0.85, sin(q.x * 14.0)) * 0.8);
        }
        if (ex2.y > 0.01) {
            float2 cell = floor(q * 4.0);
            float2 f = fract(q * 4.0) - 0.5;
            float stuck = step(hash21(cell + 2.2), ex2.y * 0.8) * step(hc.y + 0.1, q.y) * fillA(head, px);
            o = over(o, float3(0.97, 0.98, 1.0), fillA(length(f) - 0.38, px * 4.0) * stuck);
        }
    }
    return o;
}

// A kid on a skateboard: red bobble hat, striped scarf, yellow puffer jacket. Units: y = 0 under the wheels.
// ex: x crouch, y kickflip (0...1), z spin, w tilt. ex2: x grab.
float4 drawSkater(float2 uv, float px, float phase, float facing, float4 ex, float4 ex2) {
    float2 q = float2(uv.x * facing, uv.y + 1.25);
    float crouch = ex.x, flip = ex.y, spin = ex.z, tilt = ex.w, grab = ex2.x;
    float rot = spin + tilt;
    if (rot != 0.0) {
        float2 c0 = float2(0.0, 1.1);
        float ca = cos(rot), sa = sin(rot);
        float2 d = q - c0;
        q = c0 + float2(ca * d.x + sa * d.y, -sa * d.x + ca * d.y);
    }
    float4 o = float4(0);

    // The board, turning about its long axis in a kickflip. Lifted to the hand in a grab.
    float lift = grab * 0.12;
    float fl = cos(flip * 6.2831853);
    float thin = max(abs(fl), 0.12);
    float2 bq = q - float2(0.0, 0.24 + lift);
    float kick = 0.1 * smoothstep(0.6, 0.95, abs(bq.x));
    float deck = sdBox(float2(bq.x, (bq.y - kick * sign(fl) * thin) / thin), float2(0.92, 0.05), 0.05) * thin;
    float2 wl = float2(-0.56, 0.24 + lift - 0.14 * fl), wr = float2(0.56, 0.24 + lift - 0.14 * fl);
    float wheels = min(length(q - wl), length(q - wr)) - 0.085;
    float trucks = min(segDist(q, float2(-0.56, 0.24 + lift), wl), segDist(q, float2(0.56, 0.24 + lift), wr)) - 0.035;
    float3 deckCol = fl > 0.0 ? float3(0.16, 0.66, 0.72) : float3(0.98, 0.45, 0.4);
    o = over(o, catLine, fillA(min(deck, min(wheels, trucks)) - 0.025, px) * 0.9);
    if (fl > 0.0) {
        o = over(o, float3(0.62, 0.64, 0.68), fillA(trucks, px));
        o = over(o, float3(0.98, 0.9, 0.4), fillA(wheels, px));
        o = over(o, deckCol, fillA(deck, px));
        o = over(o, float3(0.18, 0.18, 0.22), fillA(max(deck, (0.24 + lift + 0.02 * thin) - q.y), px));   // grip tape
    } else {
        o = over(o, deckCol, fillA(deck, px));
        o = over(o, float3(1.0, 0.95, 0.85), fillA(max(deck, abs(bq.x) - 0.25), px) * 0.8);                 // a stripe under the deck
        o = over(o, float3(0.62, 0.64, 0.68), fillA(trucks, px));
        o = over(o, float3(0.98, 0.9, 0.4), fillA(wheels, px));
    }

    // The rider, knees bending as it crouches.
    float cr = crouch * 0.22 + grab * 0.12;
    float2 hip = float2(0.0, 1.05 - cr);
    float2 footB = float2(-0.38, 0.34 + lift), footF = float2(0.38, 0.34 + lift);
    float2 kneeB = float2(-0.34, 0.7 - cr * 0.5), kneeF = float2(0.36, 0.72 - cr * 0.5);
    float legs = min(min(segDist(q, hip + float2(-0.1, 0.0), kneeB), segDist(q, kneeB, footB)),
                     min(segDist(q, hip + float2(0.1, 0.0), kneeF), segDist(q, kneeF, footF))) - 0.1;
    float shoes = min(sdEll(q, footB + float2(0.0, 0.03), float2(0.16, 0.075)), sdEll(q, footF + float2(0.03, 0.03), float2(0.16, 0.075)));
    float2 bc = float2(0.02, 1.38 - cr);
    float body = sdEll(q, bc, float2(0.34, 0.4));
    float2 sh = bc + float2(0.0, 0.2);
    float2 handB = float2(-0.8, 1.45 - cr + 0.14 * sin(phase));
    float2 handF = grab > 0.5 ? float2(0.5, 0.42 + lift) : float2(0.78, 1.5 - cr - 0.14 * sin(phase));
    float2 elbowB = mix(sh, handB, 0.5) + float2(0.0, 0.08);
    float2 elbowF = mix(sh, handF, 0.5) + float2(0.08, grab > 0.5 ? 0.0 : 0.1);
    float arms = min(min(segDist(q, sh, elbowB), segDist(q, elbowB, handB)), min(segDist(q, sh, elbowF), segDist(q, elbowF, handF))) - 0.09;
    float mitts = min(length(q - handB), length(q - handF)) - 0.1;
    float2 hc = float2(0.1, 2.05 - cr);
    float head = length(q - hc) - 0.42;
    float hat = max(sdEll(q, hc + float2(-0.02, 0.1), float2(0.46, 0.42)), (hc.y + 0.1) - q.y);
    float band = sdBox(q - (hc + float2(-0.02, 0.15)), float2(0.46, 0.065), 0.04);
    float2 pc = hc + float2(-0.08, 0.56);
    float pom = length(q - pc) - 0.13 - 0.02 * fur(q, pc, 10.0);
    float2 n = hc + float2(-0.04, -0.42);
    float2 s1 = n + float2(-0.36, 0.06 + 0.07 * sin(phase * 2.0));
    float2 s2 = s1 + float2(-0.32, 0.03 + 0.11 * sin(phase * 2.0 + 1.5));
    float scarfTail = min(segDist(q, n, s1), segDist(q, s1, s2)) - 0.065;
    float scarf = min(sdBox(q - n, float2(0.3, 0.07), 0.05), scarfTail);
    float D = min(min(min(legs, shoes), min(body, arms)), min(min(mitts, head), min(min(hat, pom), min(scarf, band))));

    o = over(o, catLine, fillA(D - 0.03, px) * 0.9);
    o = over(o, float3(0.24, 0.32, 0.56), fillA(legs, px));
    o = over(o, float3(0.96, 0.96, 0.98), fillA(shoes, px));
    o = over(o, float3(0.86, 0.22, 0.22), fillA(max(shoes, q.y - (footB.y - 0.01)), px));
    float3 scarfCol = mix(float3(0.18, 0.62, 0.68), float3(0.96, 0.96, 0.96), step(0.5, fract((q.x + q.y) * 4.0)));
    o = over(o, scarfCol, fillA(scarfTail, px));
    float quilt = smoothstep(0.75, 0.95, sin(q.y * 20.0)) * 0.12;
    o = over(o, float3(1.0, 0.77, 0.22) * (1.0 - quilt), fillA(body, px));
    o = over(o, float3(0.96, 0.7, 0.17), fillA(arms, px));
    o = over(o, float3(0.86, 0.2, 0.22), fillA(mitts, px));
    o = over(o, scarfCol, fillA(sdBox(q - n, float2(0.3, 0.07), 0.05), px));
    o = over(o, float3(1.0, 0.87, 0.76), fillA(head, px));
    o = over(o, float3(0.98, 0.6, 0.62), fillA(length(q - (hc + float2(0.24, -0.13))) - 0.075, px * 3.0) * 0.55);
    float2 e1 = hc + float2(0.12, -0.01), e2 = hc + float2(0.31, -0.01);
    o = over(o, float3(0.12, 0.1, 0.12), fillA(min(sdEll(q, e1, float2(0.045, 0.06)), sdEll(q, e2, float2(0.042, 0.058))), px));
    o = over(o, float3(1.0), fillA(min(length(q - e1 - float2(0.015, 0.02)), length(q - e2 - float2(0.015, 0.02))) - 0.016, px));
    float2 mc = hc + float2(0.25, -0.15);
    float smile = max(abs(length(q - mc) - 0.075) - 0.018, q.y - mc.y);
    o = over(o, float3(0.45, 0.2, 0.22), fillA(smile, px));
    o = over(o, float3(0.86, 0.16, 0.2), fillA(hat, px));
    o = over(o, float3(0.97, 0.97, 0.97), fillA(band, px));
    o = over(o, float3(0.98, 0.98, 0.98), fillA(pom, px));
    return o;
}

// A robin, side on: brown back, orange-red breast, white belly. Units: y = 0 at its feet.
float4 drawBird(float2 uv, float px, float phase, float facing, float flying, float peck) {
    float2 q = float2(uv.x * facing, uv.y + 0.6);
    if (peck > 0.0) {
        // Bobbing forward to peck.
        float a = peck * 0.6;
        float2 c0 = float2(0.0, 0.15);
        float ca = cos(a), sa = sin(a);
        float2 d = q - c0;
        q = c0 + float2(ca * d.x - sa * d.y, sa * d.x + ca * d.y);
    }
    float body = sdEll(q, float2(0.0, 0.55), float2(0.55, 0.42));
    float head = length(q - float2(0.42, 0.9)) - 0.3;
    float tail = sdTriangle(q, float2(-0.42, 0.6), float2(-1.05, 0.98), float2(-0.98, 0.74)) - 0.04;
    float beak = sdTriangle(q, float2(0.66, 0.95), float2(0.92, 0.88), float2(0.66, 0.82));
    float legs = flying > 0.5 ? 1e3 : min(segDist(q, float2(-0.06, 0.22), float2(-0.1, 0.0)), segDist(q, float2(0.12, 0.22), float2(0.16, 0.0))) - 0.03;
    float wing;
    if (flying > 0.5) {
        float w = sin(phase) * 1.0;
        float2 sh = float2(-0.05, 0.78);
        float2 d = q - sh;
        float cw = cos(w), sw = sin(w);
        d = float2(cw * d.x + sw * d.y, -sw * d.x + cw * d.y);
        wing = sdEll(d, float2(-0.32, 0.12), float2(0.46, 0.16));
    } else {
        wing = sdEll(q, float2(-0.12, 0.62), float2(0.42, 0.22));
    }
    float D = min(min(min(body, head), min(tail, beak)), min(legs, wing));
    float3 brown = float3(0.47, 0.36, 0.3);
    float4 o = float4(0);
    o = over(o, catLine, fillA(D - 0.05, px) * 0.9);
    o = over(o, float3(0.35, 0.25, 0.2), fillA(legs, px));
    o = over(o, brown * 0.9, fillA(tail, px));
    o = over(o, brown, fillA(body, px));
    // Orange-red breast and a white belly.
    float breast = smoothstep(-0.2, 0.15, q.x) * (1.0 - smoothstep(0.78, 0.9, q.y));
    o = over(o, float3(0.95, 0.45, 0.22), fillA(body, px) * breast);
    o = over(o, float3(0.98, 0.96, 0.92), fillA(body, px) * (1.0 - smoothstep(0.22, 0.36, q.y)));
    o = over(o, brown, fillA(head, px));
    o = over(o, float3(0.95, 0.45, 0.22), fillA(max(head, -(0.86 - q.y)), px) * smoothstep(0.35, 0.55, q.x));
    o = over(o, float3(0.98, 0.75, 0.2), fillA(beak, px));
    float2 e = float2(0.5, 0.96);
    o = over(o, float3(0.08, 0.07, 0.08), fillA(length(q - e) - 0.065, px));
    o = over(o, float3(1.0), fillA(length(q - e - float2(0.02, 0.025)) - 0.022, px));
    o = over(o, catLine, fillA(wing - 0.04, px) * 0.6);
    o = over(o, float3(0.38, 0.28, 0.23), fillA(wing, px));
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

// A sleepy "z".
float4 drawZ(float2 uv, float px) {
    float2 a = float2(-0.55, 0.55), b = float2(0.55, 0.55), c = float2(-0.55, -0.55), d = float2(0.55, -0.55);
    float z = min(min(segDist(uv, a, b), segDist(uv, b, c)), segDist(uv, c, d));
    float4 o = over(float4(0), float3(0.25, 0.32, 0.5), fillA(z - 0.26, px));
    return over(o, float3(0.95, 0.97, 1.0), fillA(z - 0.13, px));
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
        else if (in.kind < 7.5) c = drawHeart(uv, px);
        else if (in.kind < 8.5) c = drawZ(uv, px);
        else if (in.kind < 9.5) c = drawSkater(uv, px, in.seed, in.facing, in.ex, in.ex2);
        else if (in.kind > 11.5) {
            // A fairy light: a coloured bulb with a soft glow, twinkling.
            float tw = 0.65 + 0.35 * sin(u.time * (1.5 + fract(in.seed * 7.3) * 2.0) + in.seed * 40.0);
            float3 col = in.ex.xyz;
            float glow = exp(-d * d * 2.2) * 0.55 * tw;
            float bulb = 1.0 - smoothstep(0.34, 0.42, length(uv * float2(1.0, 0.8) - float2(0.0, -0.05)));
            float3 lit = mix(col, float3(1.0), 0.45 * bulb * tw);
            float a = max(glow, bulb * (0.55 + 0.45 * tw));
            c = float4(lit * a, a);
        }
        else if (in.kind > 10.5) c = drawBird(uv, px, in.seed, in.facing, in.ex.x, in.ex.y);
        else {
            // The laser dot: a hot white core in a red glow.
            float flicker = 0.92 + 0.08 * sin(u.time * 40.0);
            float glow = exp(-d * d * 1.6) * 0.75 * flicker;
            float core = 1.0 - smoothstep(0.32, 0.42, d);
            float3 col = mix(float3(1.0, 0.1, 0.12), float3(1.0, 0.9, 0.9), core * (1.0 - smoothstep(0.0, 0.25, d)));
            float a = max(glow, core);
            c = float4(col * a, a);
        }
        return c * in.alpha;
    }
    if (in.kind < 0.5) {
        float core = 1.0 - smoothstep(0.3, 1.0, d);
        float a = core * in.alpha * u.opacity;
        float3 c = mix(float3(0.97, 0.985, 1.0), float3(0.8, 0.86, 1.0), u.pad0 * 0.5);
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
    // Moonlit at night: a cool blue cast.
    c = mix(c, c * float3(0.68, 0.76, 1.0), u.pad0 * 0.6);
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
                                time: simulation.time, scale: scale, opacity: simulation.settings.opacity,
                                pad0: simulation.night)

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

        let flakeSize = sim.settings.flakeSize
        for f in sim.flakes {
            let a: Float = f.kind == .flake ? (0.35 + f.depth * 0.6) : 0.95
            let r = f.kind == .flake ? f.r * flakeSize : f.r
            sprites.append(SpriteInstance(px: f.p.x, py: f.p.y, r: r, alpha: a, kind: 0, seed: f.seed, ext: 1, pad: 0))
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
        for cat in sim.cats where cat.state != .away {
            let c = cat.p + SIMD2(0, cat.size)
            sprites.append(SpriteInstance(px: c.x, py: c.y, r: cat.size, alpha: 1, kind: 5, seed: cat.phase, ext: 1.8,
                                          pad: cat.facing, a: cat.blink, b: cat.startle,
                                          c: cat.state == .walking ? 1 : 0, d: cat.pose,
                                          e: cat.state == .shaking ? min(1, cat.shake * 2) : 0, f: cat.snowy,
                                          g: cat.angle, h: Float(cat.coat) + min(cat.look, 0.999) * 0.5))
            if cat.carrying {
                let m = cat.p + SIMD2(cat.facing * cat.size * 1.12, cat.size * 0.62)
                sprites.append(SpriteInstance(px: m.x, py: m.y, r: Mug.size * 0.8, alpha: 1, kind: 6, seed: 0, ext: 2.4,
                                              pad: 1, a: 1))
            }
        }
        if let sk = sim.skater {
            let c = sk.p + SIMD2(0, sk.unit * 1.25)
            sprites.append(SpriteInstance(px: c.x, py: c.y, r: sk.unit, alpha: 1, kind: 9, seed: sk.phase, ext: 2.0,
                                          pad: sk.facing, a: sk.crouch, b: sk.flip, c: sk.spin, d: sk.tilt, e: sk.grab))
        }
        if sim.night > 0.05 {
            // Strings of fairy lights along the tops of the windows.
            let palette: [SIMD3<Float>] = [SIMD3(1, 0.25, 0.25), SIMD3(1, 0.8, 0.25), SIMD3(0.3, 0.95, 0.4), SIMD3(0.35, 0.6, 1)]
            for l in sim.ledges.values where l.kind == .window {
                let every = 16
                var i = every / 2
                while i < l.h.count {
                    defer { i += every }
                    guard l.visible[i] else { continue }
                    let n = (i / every + l.id) % palette.count
                    let col = palette[n]
                    sprites.append(SpriteInstance(px: l.centerX(i), py: l.y + l.h[i] + 5, r: 5.5, alpha: sim.night,
                                                  kind: 12, seed: Float(i) * 0.37 + Float(l.id), ext: 3, pad: 1,
                                                  a: col.x, b: col.y, c: col.z))
                }
            }
        }
        if let b = sim.bird {
            let c = b.p + SIMD2(0, b.unit * 0.6)
            sprites.append(SpriteInstance(px: c.x, py: c.y, r: b.unit, alpha: 1, kind: 11, seed: b.phase, ext: 1.7,
                                          pad: b.facing, a: b.flying ? 1 : 0, b: b.peck))
        }
        if let dot = sim.laser {
            sprites.append(SpriteInstance(px: dot.x, py: dot.y, r: 7, alpha: 1, kind: 10, seed: 0, ext: 2.6, pad: 1))
        }
        for h in sim.hearts {
            let grow: Float = h.isZ ? 0.7 + (1 - h.life) * 0.6 : 1
            sprites.append(SpriteInstance(px: h.p.x, py: h.p.y, r: 5 * (sim.cat?.size ?? 18) / 18 * grow, alpha: min(1, h.life * 2),
                                          kind: h.isZ ? 8 : 7, seed: 0,
                                          ext: 1.3, pad: 1))
        }
    }
}
