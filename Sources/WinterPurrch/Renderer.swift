import Metal
import MetalKit
import QuartzCore
import simd

struct SpriteInstance {
    var px: Float, py: Float, r: Float, alpha: Float
    var kind: Float, seed: Float, ext: Float, pad: Float
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
struct Sprite { float px, py, r, alpha, kind, seed, ext, pad; };
struct HV { float px, py, depth, pad; };

struct SOut { float4 pos [[position]]; float2 uv; float r; float alpha; float kind; float seed; };
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
    return o;
}

// Signed distance to a segment, for the carrot.
float segDist(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}

fragment float4 spriteF(SOut in [[stage_in]], constant U& u [[buffer(0)]]) {
    float2 uv = in.uv;
    float d = length(uv);
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
    }
}
