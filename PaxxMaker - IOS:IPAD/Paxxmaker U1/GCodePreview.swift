import SwiftUI
import MetalKit
import Combine
import simd

// MARK: - EasyPrint, stage 3: the sliced result, drawn like Orca's preview.
// The G-code is parsed on the phone into extrusion segments tagged with
// Orca's ;TYPE: feature, ;WIDTH:/;HEIGHT:, the layer and the tool. A Metal
// renderer draws every segment as a lit prism of that width and height
// (instanced: one shared shape, the vertex shader places it), built the way
// Orca's own GCodeViewer does. Colours are Orca's palette by feature, or the
// filament colours loaded in the printer, with a layer slider. Parsing is
// byte-level — a 2 h print is a few hundred thousand segments and takes
// well under a second.

struct GCodeToolpaths {
    enum Feature: Int, CaseIterable {
        case outerWall, innerWall, overhangWall, sparseInfill, solidInfill, topSurface, bottomSurface, ironing, bridge,
             support, supportInterface, skirt, brim, gapFill, wipeTower, custom, other

        /// Orca/Bambu names first, then PrusaSlicer's and Cura's — files on the
        /// printer may come from any of them.
        nonisolated static func from(_ s: Substring) -> Feature {
            let t = s.trimmingCharacters(in: .whitespaces).lowercased()
            if t.hasPrefix("outer wall") || t.hasPrefix("external perimeter") || t == "wall-outer" { return .outerWall }
            if t.hasPrefix("inner wall") || t.hasPrefix("perimeter") || t == "wall-inner" { return .innerWall }
            if t.hasPrefix("overhang") { return .overhangWall }
            if t.hasPrefix("sparse infill") || t.hasPrefix("internal infill") || t == "fill" { return .sparseInfill }
            if t.hasPrefix("internal solid") || t.hasPrefix("solid infill") { return .solidInfill }
            if t.hasPrefix("top surface") || t.hasPrefix("top solid") || t == "skin" { return .topSurface }
            if t.hasPrefix("bottom surface") { return .bottomSurface }
            if t.hasPrefix("ironing") { return .ironing }
            if t.hasPrefix("bridge") || t.hasPrefix("internal bridge") { return .bridge }
            if t.hasPrefix("support interface") || t.hasPrefix("support material interface") || t == "support-interface" { return .supportInterface }
            if t.hasPrefix("support") { return .support }
            if t.hasPrefix("skirt/brim") { return .skirt }
            if t.hasPrefix("skirt") { return .skirt }
            if t.hasPrefix("brim") { return .brim }
            if t.hasPrefix("gap") { return .gapFill }
            if t.hasPrefix("prime tower") || t.hasPrefix("wipe tower") || t == "prime-tower" { return .wipeTower }
            if t.hasPrefix("custom") { return .custom }
            return .other
        }

        /// Orca's Extrusion_Role_Colors.
        var color: SIMD4<Float> {
            switch self {
            case .outerWall:        return SIMD4(1.00, 0.49, 0.22, 1)
            case .innerWall:        return SIMD4(1.00, 0.90, 0.30, 1)
            case .overhangWall:     return SIMD4(0.12, 0.12, 1.00, 1)
            case .sparseInfill:     return SIMD4(0.69, 0.19, 0.16, 1)
            case .solidInfill:      return SIMD4(0.59, 0.33, 0.80, 1)
            case .topSurface:       return SIMD4(0.94, 0.25, 0.25, 1)
            case .bottomSurface:    return SIMD4(0.40, 0.36, 0.78, 1)
            case .ironing:          return SIMD4(1.00, 0.55, 0.41, 1)
            case .bridge:           return SIMD4(0.30, 0.50, 0.73, 1)
            case .support:          return SIMD4(0.00, 1.00, 0.00, 1)
            case .supportInterface: return SIMD4(0.00, 0.50, 0.00, 1)
            case .skirt:            return SIMD4(0.00, 0.53, 0.43, 1)
            case .brim:             return SIMD4(0.00, 0.23, 0.43, 1)
            case .gapFill:          return SIMD4(1.00, 1.00, 1.00, 1)
            case .wipeTower:        return SIMD4(0.70, 0.89, 0.67, 1)
            case .custom:           return SIMD4(0.37, 0.82, 0.58, 1)
            case .other:            return SIMD4(0.90, 0.70, 0.70, 1)
            }
        }

        var label: String {
            switch self {
            case .outerWall: return lz(en: "Outer wall", de: "Außenwand", fr: "Paroi ext.", es: "Pared ext.", pt: "Parede ext.", it: "Parete est.", zh: "外墙")
            case .innerWall: return lz(en: "Inner wall", de: "Innenwand", fr: "Paroi int.", es: "Pared int.", pt: "Parede int.", it: "Parete int.", zh: "内墙")
            case .overhangWall: return lz(en: "Overhang", de: "Überhang", fr: "Surplomb", es: "Voladizo", pt: "Balanço", it: "Sbalzo", zh: "悬空")
            case .sparseInfill: return lz(en: "Infill", de: "Infill", fr: "Remplissage", es: "Relleno", pt: "Preenchimento", it: "Riempimento", zh: "填充")
            case .solidInfill: return lz(en: "Solid infill", de: "Massiv", fr: "Plein", es: "Sólido", pt: "Sólido", it: "Solido", zh: "实心填充")
            case .topSurface: return lz(en: "Top surface", de: "Oberseite", fr: "Dessus", es: "Superior", pt: "Topo", it: "Sopra", zh: "顶面")
            case .bottomSurface: return lz(en: "Bottom surface", de: "Unterseite", fr: "Dessous", es: "Inferior", pt: "Base", it: "Sotto", zh: "底面")
            case .ironing: return lz(en: "Ironing", de: "Bügeln", fr: "Lissage", es: "Planchado", pt: "Alisamento", it: "Stiratura", zh: "熨烫")
            case .bridge: return lz(en: "Bridge", de: "Brücke", fr: "Pont", es: "Puente", pt: "Ponte", it: "Ponte", zh: "桥接")
            case .support: return "Support"
            case .supportInterface: return lz(en: "Support interface", de: "Support-Kontakt", fr: "Interface support", es: "Interfaz soporte", pt: "Interface suporte", it: "Interfaccia supporto", zh: "支撑接触面")
            case .skirt: return "Skirt"
            case .brim: return "Brim"
            case .gapFill: return lz(en: "Gap fill", de: "Lückenfüllung", fr: "Combler", es: "Relleno huecos", pt: "Preencher vãos", it: "Riempi gap", zh: "缝隙填充")
            case .wipeTower: return lz(en: "Prime tower", de: "Reinigungsturm", fr: "Tour de purge", es: "Torre de purga", pt: "Torre de purga", it: "Torre di spurgo", zh: "擦料塔")
            case .custom, .other: return lz(en: "Other", de: "Sonstiges", fr: "Autre", es: "Otro", pt: "Outro", it: "Altro", zh: "其他")
            }
        }
    }

    /// GPU layout, mirrored by `Segment` in the shader source (36 bytes).
    struct Segment {
        var ax: Float, ay: Float, az: Float
        var bx: Float, by: Float, bz: Float
        var w: Float, h: Float
        var meta: UInt32                     // feature | tool << 8
        var feature: Feature { Feature(rawValue: Int(meta & 0xFF)) ?? .other }
        var tool: UInt8 { UInt8((meta >> 8) & 0xFF) }
    }

    nonisolated init() {}

    var segments: [Segment] = []       // extrusions in file order (= layer order)
    var layerStart: [Int] = []         // first segment index per layer, plus a final sentinel
    var travels: [Segment] = []
    var travelStart: [Int] = []
    var layerZ: [Float] = []           // z per layer index
    var featuresUsed: Set<Feature> = []
    var toolsUsed: Set<UInt8> = []
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) = (.zero, .zero)

    var layerCount: Int { layerZ.count }

    /// Byte-level G-code parse. Handles G0/G1 with X/Y/Z/E, G2/G3 arcs (I/J or R),
    /// G90/G91, M82/M83, G92 E, Tn, ;TYPE:, ;WIDTH:, ;HEIGHT:, ;LAYER_CHANGE / ;Z:.
    nonisolated static func parse(_ data: Data) -> GCodeToolpaths {
        var out = GCodeToolpaths()
        var x: Float = 0, y: Float = 0, z: Float = 0, e: Float = 0
        var absolute = true, absoluteE = false          // Orca defaults to M83
        var feature: Feature = .other
        var tool: UInt8 = 0
        var width: Float = 0.42, height: Float = 0.2
        var layer: Int32 = -1
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        out.segments.reserveCapacity(data.count / 40)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            let n = p.count
            var i = 0
            @inline(__always) func number(_ j: inout Int) -> Float? {
                var k = j; var neg = false; var val: Float = 0; var frac: Float = 0; var scale: Float = 0.1; var any = false
                if k < n, p[k] == 45 { neg = true; k += 1 } else if k < n, p[k] == 43 { k += 1 }
                while k < n, p[k] >= 48, p[k] <= 57 { val = val * 10 + Float(p[k] - 48); k += 1; any = true }
                if k < n, p[k] == 46 {
                    k += 1
                    while k < n, p[k] >= 48, p[k] <= 57 { frac += Float(p[k] - 48) * scale; scale *= 0.1; k += 1; any = true }
                }
                guard any else { return nil }
                j = k
                return neg ? -(val + frac) : (val + frac)
            }
            /// One move: an extrusion box when extruding, else a travel line.
            @inline(__always) func emit(_ ax: Float, _ ay: Float, _ az: Float, _ bx: Float, _ by: Float, _ bz: Float, _ extruding: Bool) {
                if extruding, ax != bx || ay != by {
                    if out.layerStart.isEmpty {              // extrusion before the first layer tag
                        layer = 0; out.layerZ.append(bz); out.layerStart.append(0); out.travelStart.append(out.travels.count)
                    }
                    out.segments.append(Segment(ax: ax, ay: ay, az: az, bx: bx, by: by, bz: bz, w: width, h: height,
                                                meta: UInt32(feature.rawValue) | UInt32(tool) << 8))
                    if layer >= 0, Int(layer) < out.layerZ.count { out.layerZ[Int(layer)] = bz }   // slicers without ;Z:
                    if feature != .custom && feature != .other {      // purge lines would blow up the framing
                        lo = simd_min(lo, simd_min(SIMD3(ax, ay, az), SIMD3(bx, by, bz)))
                        hi = simd_max(hi, simd_max(SIMD3(ax, ay, az), SIMD3(bx, by, bz)))
                    }
                    out.featuresUsed.insert(feature); out.toolsUsed.insert(tool)
                } else if ax != bx || ay != by || az != bz, !out.layerStart.isEmpty {
                    out.travels.append(Segment(ax: ax, ay: ay, az: az, bx: bx, by: by, bz: bz, w: 0, h: 0, meta: 0))
                }
            }
            /// True when the comment at `j` (the ';') continues with `s`.
            @inline(__always) func tag(_ j: Int, _ end: Int, _ s: StaticString) -> Bool {
                let c = s.utf8CodeUnitCount
                guard end - j > c else { return false }
                let q = s.utf8Start
                for t in 0..<c where p[j + 1 + t] != q[t] { return false }
                return true
            }
            while i < n {
                // line bounds
                var end = i
                while end < n, p[end] != 10 { end += 1 }
                var j = i
                while j < end, p[j] == 32 || p[j] == 9 { j += 1 }
                if j < end {
                    let c = p[j]
                    if c == 59 {                                   // ';' comment
                        if tag(j, end, "TYPE:") {
                            let s = String(decoding: UnsafeBufferPointer(start: p.baseAddress! + j + 6, count: end - j - 6), as: UTF8.self)
                            feature = Feature.from(Substring(s))
                        } else if tag(j, end, "WIDTH:") {
                            var k = j + 7
                            if let v = number(&k), v > 0.01, v < 5 { width = v }
                        } else if tag(j, end, "HEIGHT:") {
                            var k = j + 8
                            if let v = number(&k), v > 0.01, v < 5 { height = v }
                        } else if tag(j, end, "LAYER_CHANGE") || (tag(j, end, "LAYER:") && !tag(j, end, "LAYER:0")) || (tag(j, end, "LAYER:0") && layer < 0) {
                            // Orca/PrusaSlicer ;LAYER_CHANGE, Cura ;LAYER:n
                            layer += 1
                            out.layerZ.append(z)
                            out.layerStart.append(out.segments.count)
                            out.travelStart.append(out.travels.count)
                        } else if tag(j, end, "Z:") {
                            var k = j + 3
                            if let v = number(&k), layer >= 0, Int(layer) < out.layerZ.count { out.layerZ[Int(layer)] = v }
                        }
                    } else if c == 71 {                            // 'G'
                        var k = j + 1
                        let code = number(&k) ?? -1
                        if code >= 0 && code <= 3 {
                            var nx = x, ny = y, nz = z, de: Float = 0, hasE = false
                            var ci: Float = 0, cj: Float = 0, cr: Float = 0, hasIJ = false, hasR = false
                            while k < end {
                                let ch = p[k]
                                if ch == 59 { break }
                                if ch == 32 || ch == 9 { k += 1; continue }
                                k += 1
                                guard let v = number(&k) else { continue }
                                switch ch {
                                case 88: nx = absolute ? v : x + v          // X
                                case 89: ny = absolute ? v : y + v          // Y
                                case 90: nz = absolute ? v : z + v          // Z
                                case 69: hasE = true; de = absoluteE ? v - e : v; if absoluteE { e = v } else { e += v }   // E
                                case 73: ci = v; hasIJ = true               // I
                                case 74: cj = v; hasIJ = true               // J
                                case 82: cr = v; hasR = true                // R
                                default: break
                                }
                            }
                            let extruding = hasE && de > 0.00001
                            if code >= 2, hasIJ || hasR, nx != x || ny != y || hasIJ {
                                // Arc (Orca's arc fitting): chords with ≤ 0.0125 mm deviation, as Orca's
                                // GCodeProcessor does for Klipper (ArcWelder::arc_discretization_steps).
                                var cx = x + ci, cy = y + cj
                                if !hasIJ {
                                    let dx = nx - x, dy = ny - y, d = (dx * dx + dy * dy).squareRoot()
                                    let hh = max(cr * cr - d * d / 4, 0).squareRoot()
                                    let sgn: Float = ((code == 2) != (cr < 0)) ? 1 : -1
                                    cx = (x + nx) / 2 + sgn * (-dy / d) * hh
                                    cy = (y + ny) / 2 + sgn * (dx / d) * hh
                                }
                                let r = ((x - cx) * (x - cx) + (y - cy) * (y - cy)).squareRoot()
                                let a0 = atan2(y - cy, x - cx)
                                var sweep = atan2(ny - cy, nx - cx) - a0
                                if code == 2 { if sweep >= -1e-5 { sweep -= 2 * .pi } } else { if sweep <= 1e-5 { sweep += 2 * .pi } }
                                let step = max(2 * acos(max(-1, 1 - 0.0125 / max(r, 0.013))), 0.015)
                                let n = max(1, min(400, Int((abs(sweep) / step).rounded(.up))))
                                var px = x, py = y, pz = z
                                for s in 1...n {
                                    let t = Float(s) / Float(n)
                                    let a = a0 + sweep * t
                                    let qx = s == n ? nx : cx + r * cos(a), qy = s == n ? ny : cy + r * sin(a), qz = z + (nz - z) * t
                                    emit(px, py, pz, qx, qy, qz, extruding)
                                    px = qx; py = qy; pz = qz
                                }
                            } else {
                                emit(x, y, z, nx, ny, nz, extruding)
                            }
                            x = nx; y = ny; z = nz
                        } else if code == 90 { absolute = true }
                        else if code == 91 { absolute = false }
                        else if code == 92 {
                            while k < end {
                                let ch = p[k]; if ch == 59 { break }
                                if ch == 32 { k += 1; continue }
                                k += 1
                                guard let v = number(&k) else { continue }
                                if ch == 69 { e = v }
                            }
                        }
                    } else if c == 77 {                            // 'M'
                        var k = j + 1
                        let code = number(&k) ?? -1
                        if code == 82 { absoluteE = true } else if code == 83 { absoluteE = false }
                    } else if c == 84 {                            // 'T'
                        var k = j + 1
                        if let v = number(&k), v >= 0, v < 16 { tool = UInt8(v) }
                    }
                }
                i = end + 1
            }
        }
        // Drop trailing layer tags that got no extrusion.
        while out.layerStart.count > 1, out.layerStart.last == out.segments.count {
            out.layerStart.removeLast(); out.layerZ.removeLast(); out.travelStart.removeLast()
        }
        out.layerStart.append(out.segments.count)
        out.travelStart.append(out.travels.count)
        if lo.x <= hi.x { out.bounds = (lo, hi) }
        else if let f = out.segments.first { out.bounds = (SIMD3(f.ax, f.ay, f.az), SIMD3(f.bx, f.by, f.bz)) }
        return out
    }
}

// MARK: Renderer

private struct Uniforms {
    var viewProj: simd_float4x4
    var view: simd_float4x4
    var byTool: UInt32 = 0
    var alpha: Float = 1
    var pad2: UInt32 = 0, pad3: UInt32 = 0
}

private struct SimpleVertex {
    var x: Float, y: Float, z: Float
    var r: Float, g: Float, b: Float, a: Float
    init(_ p: SIMD3<Float>, _ c: SIMD4<Float>) { x = p.x; y = p.y; z = p.z; r = c.x; g = c.y; b = c.z; a = c.w }
}

/// Turntable camera in G-code space (Z up): yaw around Z, pitch above the bed.
private struct OrbitCamera {
    var target = SIMD3<Float>(0, 0, 0)
    var distance: Float = 300
    var yaw: Float = -.pi / 2
    var pitch: Float = 0.6

    var eye: SIMD3<Float> {
        target + distance * SIMD3(cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), sin(pitch))
    }
    /// Camera-space right/up in world coordinates (for two-finger pan).
    var axes: (right: SIMD3<Float>, up: SIMD3<Float>) {
        let f = simd_normalize(target - eye)
        let s = simd_normalize(simd_cross(f, SIMD3(0, 0, 1)))
        return (s, simd_cross(s, f))
    }
    var view: simd_float4x4 {
        let e = eye
        let f = simd_normalize(target - e)
        let s = simd_normalize(simd_cross(f, SIMD3(0, 0, 1)))
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (SIMD4(s.x, u.x, -f.x, 0), SIMD4(s.y, u.y, -f.y, 0), SIMD4(s.z, u.z, -f.z, 0),
                                       SIMD4(-simd_dot(s, e), -simd_dot(u, e), simd_dot(f, e), 1)))
    }
    static func projection(aspect: Float, fov: Float = 45 * .pi / 180, near: Float = 1, far: Float = 6000) -> simd_float4x4 {
        let ys = 1 / tan(fov / 2), xs = ys / aspect, zs = far / (near - far)
        return simd_float4x4(columns: (SIMD4(xs, 0, 0, 0), SIMD4(0, ys, 0, 0), SIMD4(0, 0, zs, -1), SIMD4(0, 0, near * zs, 0)))
    }
}

/// Compiled at runtime so the project needs no Metal toolchain to build.
private let toolpathShaderSource = """
#include <metal_stdlib>
using namespace metal;

// Mirrors GCodeToolpaths.Segment (36 bytes, 4-byte aligned).
struct Segment {
    packed_float3 a;
    packed_float3 b;
    float w;          // extrusion width
    float h;          // layer height
    uint meta;        // feature | tool << 8
};

struct Uniforms {
    float4x4 viewProj;
    float4x4 view;
    uint byTool;
    float alpha;      // multiplies vertex alpha (translucent plate seen from below)
    uint pad2, pad3;
};

struct SimpleVertex {
    packed_float3 p;
    packed_float4 c;
};

struct BoxOut {
    float4 pos [[position]];
    float3 vpos;
    float3 vnormal;
    float4 color;
};

// One prism per segment, as Orca's GCodeViewer builds them: a rhombus cross
// section (top vertex at nozzle height, widest at half height, bottom vertex
// one layer down) with a normal per edge, so the shading across each face
// runs smoothly from lit top to dark side — the "sausage" look. Extended by
// half a width at both ends so joints close. Corner = vertex_id & 3
// (top, right, bottom, left), end = vertex_id & 4.
vertex BoxOut toolpath_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              constant Segment *segs [[buffer(0)]],
                              constant Uniforms &u [[buffer(1)]],
                              constant float4 *colors [[buffer(2)]]) {
    Segment s = segs[iid];
    float3 a = float3(s.a), b = float3(s.b);
    float3 d = b - a;
    float len = length(d);
    float3 t = len > 1e-6 ? d / len : float3(1, 0, 0);
    float3 r = float3(t.y, -t.x, 0);
    float rl = length(r);
    r = rl > 1e-4 ? r / rl : float3(1, 0, 0);
    float3 up = cross(r, t);
    float hw = 0.5 * s.w, hh = 0.5 * s.h;
    uint c = vid & 3u;
    float along = (vid & 4u) ? len + hw : -hw;
    float3 centre = a - hh * up + t * along;
    float3 off = c == 0u ? up * hh : (c == 1u ? r * hw : (c == 2u ? -up * hh : -r * hw));
    float3 nrm = c == 0u ? up : (c == 1u ? r : (c == 2u ? -up : -r));
    float3 p = centre + off;
    BoxOut o;
    o.vpos = (u.view * float4(p, 1)).xyz;
    o.vnormal = (u.view * float4(nrm, 0)).xyz;
    o.pos = u.viewProj * float4(p, 1);
    uint feature = s.meta & 0xFFu, tool = (s.meta >> 8) & 0xFFu;
    o.color = u.byTool ? colors[32 + min(tool, 15u)] : colors[min(feature, 31u)];
    return o;
}

// Orca's two eye-space lights (gouraud_light shader), per fragment.
fragment float4 toolpath_fragment(BoxOut in [[stage_in]]) {
    float3 N = normalize(in.vnormal);
    float3 V = normalize(-in.vpos);
    const float3 LT = float3(-0.4574957, 0.4574957, 0.7624929);
    const float3 LF = float3(0.6985074, 0.1397015, 0.6985074);
    float i = 0.3 + max(dot(N, LT), 0.0) * 0.48 + max(dot(N, LF), 0.0) * 0.18;
    float spec = pow(max(dot(N, normalize(LT + V)), 0.0), 20.0) * 0.075;
    return float4(in.color.rgb * i + spec, 1);
}

// Travel moves: a line per segment (2 vertices per instance).
vertex BoxOut travel_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            constant Segment *segs [[buffer(0)]],
                            constant Uniforms &u [[buffer(1)]]) {
    Segment s = segs[iid];
    float3 p = (vid & 1u) ? float3(s.b) : float3(s.a);
    BoxOut o;
    o.vpos = 0;
    o.vnormal = 0;
    o.pos = u.viewProj * float4(p, 1);
    o.color = float4(0.35, 0.55, 0.85, 1);
    return o;
}

vertex BoxOut simple_vertex(uint vid [[vertex_id]],
                            constant SimpleVertex *v [[buffer(0)]],
                            constant Uniforms &u [[buffer(1)]]) {
    BoxOut o;
    o.vpos = 0;
    o.vnormal = 0;
    o.pos = u.viewProj * float4(float3(v[vid].p), 1);
    o.color = float4(v[vid].c) * float4(1, 1, 1, u.alpha);
    return o;
}

fragment float4 simple_fragment(BoxOut in [[stage_in]]) {
    return in.color;
}
"""

final class ToolpathRenderer: NSObject, MTKViewDelegate {
    private static var cachedLibrary: MTLLibrary?
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let boxPipeline: MTLRenderPipelineState
    private let travelPipeline: MTLRenderPipelineState
    private let simplePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let depthReadOnly: MTLDepthStencilState
    private let cubeIndices: MTLBuffer
    private var segBuffer: MTLBuffer?
    private var travelBuffer: MTLBuffer?
    private var plateBuffer: MTLBuffer?
    private var gridBuffer: MTLBuffer?
    private var plateCount = 0, gridCount = 0
    private var colors = [SIMD4<Float>](repeating: SIMD4(0.7, 0.7, 0.7, 1), count: 48)   // 0..31 feature, 32..47 tool

    private var camera = OrbitCamera()
    private var home = OrbitCamera()
    private var fitRadius: Float = 50
    private var needsFit = true
    var instanceCount = 0
    var travelCount = 0
    var byTool = false
    var showTravel = false

    init?(bed: BedSize, paths: GCodeToolpaths) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        if Self.cachedLibrary == nil { Self.cachedLibrary = try? device.makeLibrary(source: toolpathShaderSource, options: nil) }
        guard let lib = Self.cachedLibrary else { return nil }
        self.device = device; self.queue = queue
        func pipeline(_ v: String, _ f: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            d.colorAttachments[0].isBlendingEnabled = true
            d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[0].sourceAlphaBlendFactor = .one
            d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            d.depthAttachmentPixelFormat = .depth32Float
            d.rasterSampleCount = 4
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let bp = pipeline("toolpath_vertex", "toolpath_fragment"),
              let tp = pipeline("travel_vertex", "simple_fragment"),
              let sp = pipeline("simple_vertex", "simple_fragment") else { return nil }
        boxPipeline = bp; travelPipeline = tp; simplePipeline = sp
        let dd = MTLDepthStencilDescriptor(); dd.depthCompareFunction = .less; dd.isDepthWriteEnabled = true
        guard let ds = device.makeDepthStencilState(descriptor: dd) else { return nil }
        depthState = ds
        dd.isDepthWriteEnabled = false
        guard let dr = device.makeDepthStencilState(descriptor: dd) else { return nil }
        depthReadOnly = dr
        // Rhombus prism, CCW seen from outside: vertices 0–3 = top/right/bottom/left
        // at the start, 4–7 the same at the end; four side faces and two caps.
        let idx: [UInt16] = [0,1,5, 0,5,4, 1,2,6, 1,6,5, 2,3,7, 2,7,6, 3,0,4, 3,4,7, 0,3,2, 0,2,1, 4,5,6, 4,6,7]
        guard let ib = device.makeBuffer(bytes: idx, length: idx.count * 2, options: .storageModeShared) else { return nil }
        cubeIndices = ib
        super.init()
        for f in GCodeToolpaths.Feature.allCases { colors[f.rawValue] = f.color }
        load(bed: bed, paths: paths)
    }

    private func load(bed: BedSize, paths: GCodeToolpaths) {
        if !paths.segments.isEmpty {
            segBuffer = paths.segments.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        }
        if !paths.travels.isEmpty {
            travelBuffer = paths.travels.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        }
        // Plate and 10 mm grid.
        let pc = SIMD4<Float>(0.17, 0.17, 0.18, 1), gc = SIMD4<Float>(0.30, 0.30, 0.32, 1)
        let plate = [SimpleVertex(SIMD3(0, 0, -0.05), pc), SimpleVertex(SIMD3(bed.x, 0, -0.05), pc), SimpleVertex(SIMD3(bed.x, bed.y, -0.05), pc),
                     SimpleVertex(SIMD3(0, 0, -0.05), pc), SimpleVertex(SIMD3(bed.x, bed.y, -0.05), pc), SimpleVertex(SIMD3(0, bed.y, -0.05), pc)]
        var grid: [SimpleVertex] = []
        var i: Float = 0
        while i <= bed.x + 0.01 { grid.append(SimpleVertex(SIMD3(i, 0, 0), gc)); grid.append(SimpleVertex(SIMD3(i, bed.y, 0), gc)); i += 10 }
        i = 0
        while i <= bed.y + 0.01 { grid.append(SimpleVertex(SIMD3(0, i, 0), gc)); grid.append(SimpleVertex(SIMD3(bed.x, i, 0), gc)); i += 10 }
        plateBuffer = plate.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        gridBuffer = grid.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        plateCount = plate.count; gridCount = grid.count

        let b = paths.segments.isEmpty ? (min: SIMD3<Float>(0, 0, 0), max: SIMD3<Float>(bed.x, bed.y, 0)) : paths.bounds
        let centre = (b.min + b.max) / 2
        fitRadius = max(simd_length(b.max - b.min) / 2, 15)
        home = OrbitCamera(target: SIMD3(centre.x, centre.y, centre.z * 0.7), distance: fitRadius * 4, yaw: -.pi / 2, pitch: 0.55)
        camera = home
        needsFit = true
    }

    /// Model's bounding sphere just inside the narrower (portrait: horizontal) field of view.
    private func fit(aspect: Float) {
        let halfV: Float = 45 * .pi / 360
        let halfH = atan(tan(halfV) * aspect)
        home.distance = fitRadius / sin(min(halfV, halfH)) * 1.05
        camera = home
        needsFit = false
    }

    func setToolColors(_ tc: [SIMD4<Float>]) {
        for (i, c) in tc.prefix(16).enumerated() { colors[32 + i] = c }
    }

    // MARK: gestures
    func orbit(dx: Float, dy: Float) {
        camera.yaw -= dx * 0.008
        camera.pitch = min(max(camera.pitch + dy * 0.008, -1.5), 1.5)
    }
    func zoom(by scale: Float) {
        camera.distance = min(max(camera.distance / scale, 5), 20000)
    }
    func pan(dx: Float, dy: Float) {
        let (r, u) = camera.axes
        let k = camera.distance * 0.0016
        camera.target -= r * dx * k
        camera.target += u * dy * k
    }
    func reset() { camera = home }

    // MARK: MTKViewDelegate
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let aspect = Float(max(view.drawableSize.width, 1) / max(view.drawableSize.height, 1))
        if needsFit { fit(aspect: aspect) }
        var u = Uniforms(viewProj: OrbitCamera.projection(aspect: aspect) * camera.view, view: camera.view, byTool: byTool ? 1 : 0)
        enc.setDepthStencilState(depthState)
        enc.setFrontFacing(.counterClockwise)

        // From below the plate would hide the print: draw it last, translucent,
        // without writing depth.
        let fromBelow = camera.eye.z < 0
        enc.setRenderPipelineState(simplePipeline)
        enc.setCullMode(.none)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        if !fromBelow, let pb = plateBuffer { enc.setVertexBuffer(pb, offset: 0, index: 0); enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: plateCount) }
        if let gb = gridBuffer { enc.setVertexBuffer(gb, offset: 0, index: 0); enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: gridCount) }

        if let sb = segBuffer, instanceCount > 0 {
            enc.setRenderPipelineState(boxPipeline)
            enc.setCullMode(.back)
            enc.setVertexBuffer(sb, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            colors.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 2) }
            enc.drawIndexedPrimitives(type: .triangle, indexCount: 36, indexType: .uint16, indexBuffer: cubeIndices, indexBufferOffset: 0,
                                      instanceCount: instanceCount)
        }
        if showTravel, let tb = travelBuffer, travelCount > 0 {
            enc.setRenderPipelineState(travelPipeline)
            enc.setCullMode(.none)
            enc.setVertexBuffer(tb, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: 2, instanceCount: travelCount)
        }
        if fromBelow, let pb = plateBuffer {
            var t = u; t.alpha = 0.2
            enc.setRenderPipelineState(simplePipeline)
            enc.setDepthStencilState(depthReadOnly)
            enc.setCullMode(.none)
            enc.setVertexBuffer(pb, offset: 0, index: 0)
            enc.setVertexBytes(&t, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: plateCount)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

struct ToolpathMetalView: UIViewRepresentable {
    let paths: GCodeToolpaths
    let bed: BedSize
    var maxLayer: Int
    /// How much of the top layer is drawn (0…1), Orca's horizontal slider.
    var layerFraction: Double = 1
    var byTool: Bool
    var showTravel: Bool
    var toolColors: [SIMD4<Float>]

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView()
        v.colorPixelFormat = .bgra8Unorm
        v.depthStencilPixelFormat = .depth32Float
        v.sampleCount = 4
        v.clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
        v.enableSetNeedsDisplay = true
        v.isPaused = true
        if let r = ToolpathRenderer(bed: bed, paths: paths) {
            v.device = r.device
            v.delegate = r
            context.coordinator.renderer = r
        }
        context.coordinator.attach(to: v)
        apply(context.coordinator, v)
        return v
    }

    func updateUIView(_ uiView: MTKView, context: Context) { apply(context.coordinator, uiView) }

    private func apply(_ c: Coordinator, _ v: MTKView) {
        guard let r = c.renderer else { return }
        let top = min(max(0, maxLayer), paths.layerStart.count - 2)
        let f = min(max(layerFraction, 0), 1)
        if top >= 0 {
            let a = paths.layerStart[top], b = paths.layerStart[top + 1]
            r.instanceCount = a + Int((Double(b - a) * f).rounded())
            let ta = paths.travelStart[safe: top] ?? 0, tb = paths.travelStart[safe: top + 1] ?? ta
            r.travelCount = ta + Int((Double(tb - ta) * f).rounded())
        } else {
            r.instanceCount = 0; r.travelCount = 0
        }
        r.byTool = byTool
        r.showTravel = showTravel
        r.setToolColors(toolColors)
        v.setNeedsDisplay()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var renderer: ToolpathRenderer?
        weak var view: MTKView?

        func attach(to v: MTKView) {
            view = v
            let orbit = UIPanGestureRecognizer(target: self, action: #selector(onOrbit(_:)))
            orbit.maximumNumberOfTouches = 1
            let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
            pan.minimumNumberOfTouches = 2; pan.maximumNumberOfTouches = 2
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
            let tap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap(_:)))
            tap.numberOfTapsRequired = 2
            for g in [orbit, pan, pinch, tap] as [UIGestureRecognizer] { g.delegate = self; v.addGestureRecognizer(g) }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }

        @objc private func onOrbit(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: view)
            renderer?.orbit(dx: Float(t.x), dy: Float(t.y))
            g.setTranslation(.zero, in: view)
            view?.setNeedsDisplay()
        }
        @objc private func onPan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: view)
            renderer?.pan(dx: Float(t.x), dy: Float(t.y))
            g.setTranslation(.zero, in: view)
            view?.setNeedsDisplay()
        }
        @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
            renderer?.zoom(by: Float(g.scale))
            g.scale = 1
            view?.setNeedsDisplay()
        }
        @objc private func onDoubleTap(_ g: UITapGestureRecognizer) {
            renderer?.reset()
            view?.setNeedsDisplay()
        }
    }
}

// MARK: Screen

/// Orca's vertical layer slider: top = last layer.
struct VerticalLayerSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { g in
            let thumb: CGFloat = 26
            let h = max(g.size.height - thumb, 1)
            let span = max(range.upperBound - range.lowerBound, 0.0001)
            let frac = CGFloat((value - range.lowerBound) / span)
            ZStack(alignment: .top) {
                Capsule().fill(Color.white.opacity(0.22)).frame(width: 6).frame(maxWidth: .infinity).padding(.vertical, thumb / 2)
                Capsule().fill(Color.accentColor).frame(width: 6, height: max(frac * h, 0)).frame(maxWidth: .infinity)
                    .offset(y: (1 - frac) * h + thumb / 2)
                Circle().fill(.white).frame(width: thumb, height: thumb).shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(y: (1 - frac) * h)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let f = 1 - min(max((v.location.y - thumb / 2) / h, 0), 1)
                value = (range.lowerBound + Double(f) * span).rounded()
            })
        }
        .frame(width: 44)
    }
}

struct GCodePreviewView: View {
    let gcode: Data
    let bed: BedSize
    let printerName: String
    var toolColorHexes: [String] = []
    /// True when the colours above come from the slicer (the filament chosen
    /// for this slice). Then they are shown as they are; a file on the printer
    /// instead asks Spoolman first and falls back to what OrcaSlicer wrote.
    var colorsFromSlicer = false
    /// What is loaded per head — vendor/material from the printer, or the
    /// Spoolman spool — shown in the legend of the filament view.
    var toolLabels: [String] = []
    /// When given, the labels are read from this printer (and Spoolman).
    var printerService: PrinterService? = nil
    /// Fresh G-code from the slicer asks "send" or "send and print"; a file
    /// that already sits on the printer just prints.
    var offerSendOnly = true
    /// Called with `true` to send and start, `false` to only send.
    var onPrint: ((Bool) -> Void)? = nil
    @State private var askPrint = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("app_language") private var appLanguage: String = "en"
    @State private var paths: GCodeToolpaths? = nil
    @State private var maxLayer: Double = 0
    @State private var layerFraction: Double = 1
    /// The preview opens by line type — that is what shows how it prints;
    /// the filament colours are one tap away.
    @State private var byTool = false
    @State private var showTravel = false
    @State private var loadedLabels: [String] = []
    /// Colour of the Spoolman spool per head, empty when none is assigned.
    @State private var spoolColors: [String] = []
    /// What OrcaSlicer wrote into the file (`filament_colour`).
    @State private var gcodeColors: [String] = []
    private var labels: [String] { loadedLabels.isEmpty ? toolLabels : loadedLabels }

    /// The colour shown per head. Straight from the slicer when the preview
    /// belongs to a slice; for a file on the printer the Spoolman spool that
    /// is loaded there, and without Spoolman what OrcaSlicer put in the file.
    /// A head with no colour anywhere prints "grey".
    private func hex(forHead i: Int) -> String {
        if colorsFromSlicer { return toolColorHexes[safe: i] ?? "" }
        for candidate in [spoolColors[safe: i] ?? "", gcodeColors[safe: i] ?? "", toolColorHexes[safe: i] ?? ""]
        where !candidate.isEmpty { return candidate }
        return ""
    }

    private var toolColors: [SIMD4<Float>] {
        (0..<4).map { i in
            let h = hex(forHead: i)
            if !h.isEmpty, let c = UIColor(Color(hex: h) ?? .clear).cgColor.components, c.count >= 3 {
                return SIMD4(Float(c[0]), Float(c[1]), Float(c[2]), 1)
            }
            return SIMD4(0.72, 0.72, 0.72, 1)
        }
    }

    /// OrcaSlicer's own filament colours, from the settings block at the end
    /// of the file: `; filament_colour = #FFFFFF;#1F6BFF`.
    private static func orcaColors(in data: Data) -> [String] {
        let tailStart = max(0, data.count - 200_000)
        let tail = data.subdata(in: tailStart..<data.count)
        guard let text = String(data: tail, encoding: .utf8) ?? String(data: tail, encoding: .isoLatin1) else { return [] }
        for key in ["filament_colour", "extruder_colour"] {
            guard let range = text.range(of: "; \(key) = ") else { continue }
            let line = text[range.upperBound...].prefix { $0 != "\n" && $0 != "\r" }
            let parts = line.split(separator: ";", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.contains(where: { $0.count >= 4 }) { return parts }
        }
        return []
    }
    private var multiHead: Bool { toolColorHexes.count > 1 || (paths?.toolsUsed.count ?? 0) > 1 }

    var body: some View {
        NavigationStack {
            Group {
                if let p = paths {
                    VStack(spacing: 0) {
                        ZStack(alignment: .topLeading) {
                            ToolpathMetalView(paths: p, bed: bed, maxLayer: Int(maxLayer), layerFraction: layerFraction,
                                              byTool: byTool, showTravel: showTravel, toolColors: toolColors)
                            legend(p).padding(10)
                            layerSlider(p)
                        }
                        controls(p)
                    }
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(lz(en: "Reading G-code…", de: "G-Code wird gelesen…", fr: "Lecture du G-code…", es: "Leyendo G-code…", pt: "Lendo G-code…", it: "Leggo il G-code…", zh: "正在读取 G-code…")).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(lz(en: "Preview", de: "Vorschau", fr: "Aperçu", es: "Vista previa", pt: "Pré-visualização", it: "Anteprima", zh: "预览"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lz(en: "Close", de: "Schließen", fr: "Fermer", es: "Cerrar", pt: "Fechar", it: "Chiudi", zh: "关闭")) { dismiss() }
                }
                if onPrint != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(lz(en: "Print", de: "Drucken", fr: "Imprimer", es: "Imprimir", pt: "Imprimir", it: "Stampa", zh: "打印")) {
                            if offerSendOnly { askPrint = true } else { onPrint?(true); dismiss() }
                        }
                    }
                }
            }
            .confirmationDialog(printerName, isPresented: $askPrint, titleVisibility: .visible) {
                Button(lz(en: "Send and print", de: "Senden und drucken", fr: "Envoyer et imprimer", es: "Enviar e imprimir", pt: "Enviar e imprimir", it: "Invia e stampa", zh: "发送并打印")) { onPrint?(true); dismiss() }
                Button(lz(en: "Send to printer only", de: "Nur an Drucker senden", fr: "Envoyer seulement", es: "Solo enviar a la impresora", pt: "Apenas enviar para a impressora", it: "Invia soltanto", zh: "仅发送到打印机")) { onPrint?(false); dismiss() }
                Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {}
            } message: {
                Text(lz(en: "Upload the G-code to the printer and start right away, or just store it there.",
                        de: "G-Code an den Drucker übertragen und sofort starten – oder nur dort ablegen.",
                        fr: "Envoyer le G-code à l'imprimante et lancer tout de suite, ou seulement l'y déposer.",
                        es: "Subir el G-code a la impresora y empezar ya, o solo guardarlo allí.",
                        pt: "Enviar o G-code para a impressora e começar já, ou apenas guardá-lo lá.",
                        it: "Invia il G-code alla stampante e avvia subito, oppure salvalo soltanto.",
                        zh: "将 G-code 上传到打印机并立即开始，或仅保存到打印机。"))
            }
            .task {
                let d = gcode
                let parsed = await Task.detached(priority: .userInitiated) { GCodeToolpaths.parse(d) }.value
                paths = parsed
                maxLayer = Double(max(0, parsed.layerCount - 1))
                layerFraction = 1
            }
            .task {
                guard !colorsFromSlicer else { return }
                gcodeColors = Self.orcaColors(in: gcode)
            }
            .task {
                if let svc = printerService {
                    let info = await svc.loadedFilamentInfo()
                    loadedLabels = info.map(\.label)
                    spoolColors = info.map(\.colorHex)
                }
            }
            .onChange(of: maxLayer) { _, _ in layerFraction = 1 }
        }
    }

    /// Top right: the layer slider with its number on top and Z below.
    @ViewBuilder private func layerSlider(_ p: GCodeToolpaths) -> some View {
        HStack(alignment: .top) {
            Spacer()
            VStack(spacing: 6) {
                Text("\(Int(maxLayer) + 1)").font(.caption.weight(.semibold)).monospacedDigit()
                Text("/ \(p.layerCount)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                VerticalLayerSlider(value: $maxLayer, range: 0...Double(max(0, p.layerCount - 1)))
                if let z = p.layerZ[safe: Int(maxLayer)] {
                    Text(String(format: "%.2f", z)).font(.caption2).monospacedDigit()
                    Text("mm").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 4)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .frame(height: 300)
            .padding(10)
        }
    }

    @ViewBuilder private func legend(_ p: GCodeToolpaths) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if byTool {
                ForEach(Array(p.toolsUsed).sorted(), id: \.self) { t in
                    HStack(spacing: 6) {
                        Circle().fill(color(toolColors[safe: Int(t)] ?? SIMD4(0.7, 0.7, 0.7, 1)))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 0.5)).frame(width: 10, height: 10)
                        let name = (labels[safe: Int(t)] ?? "").trimmingCharacters(in: .whitespaces)
                        if multiHead {
                            Text(lz(en: "Head", de: "Kopf", fr: "Tête", es: "Cabezal", pt: "Cabeça", it: "Testa", zh: "喷头") + " \(t + 1)" + (name.isEmpty ? "" : " · " + name)).font(.caption2)
                        } else {
                            Text(name.isEmpty ? lz(en: "Loaded filament", de: "Eingelegtes Filament", fr: "Filament chargé", es: "Filamento cargado", pt: "Filamento carregado", it: "Filamento caricato", zh: "已装耗材") : name).font(.caption2)
                        }
                    }
                }
            } else {
                ForEach(GCodeToolpaths.Feature.allCases.filter { p.featuresUsed.contains($0) && $0 != .custom && $0 != .other }, id: \.rawValue) { f in
                    HStack(spacing: 6) {
                        Circle().fill(color(f.color)).frame(width: 9, height: 9)
                        Text(f.label).font(.caption2)
                    }
                }
            }
            Text("\(p.segments.count) " + lz(en: "moves", de: "Bewegungen", fr: "mouvements", es: "movimientos", pt: "movimentos", it: "movimenti", zh: "段"))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func color(_ c: SIMD4<Float>) -> Color { Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)) }

    /// Moves in the current layer, for the step slider.
    private func layerMoves(_ p: GCodeToolpaths) -> Int {
        let l = Int(maxLayer)
        guard l >= 0, l + 1 < p.layerStart.count else { return 0 }
        return p.layerStart[l + 1] - p.layerStart[l]
    }

    @ViewBuilder private func controls(_ p: GCodeToolpaths) -> some View {
        let moves = layerMoves(p)
        VStack(spacing: 10) {
            HStack {
                Text(lz(en: "Step", de: "Schritt", fr: "Étape", es: "Paso", pt: "Passo", it: "Passo", zh: "步"))
                Slider(value: $layerFraction, in: 0...1)
                Text("\(Int((Double(moves) * layerFraction).rounded())) / \(moves)").monospacedDigit().font(.footnote)
                    .frame(width: 96, alignment: .trailing)
            }
            HStack {
                Picker("", selection: $byTool) {
                    Text(lz(en: "Line type", de: "Linientyp", fr: "Type de ligne", es: "Tipo de línea", pt: "Tipo de linha", it: "Tipo di linea", zh: "线条类型")).tag(false)
                    Text(lz(en: "Filament colour", de: "Filamentfarbe", fr: "Couleur du filament", es: "Color del filamento", pt: "Cor do filamento", it: "Colore filamento", zh: "耗材颜色")).tag(true)
                }.pickerStyle(.segmented)
                Toggle(isOn: $showTravel) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").font(.caption)
                }
                .toggleStyle(.button).controlSize(.small)
                .help(lz(en: "Travel moves", de: "Verfahrwege", fr: "Déplacements", es: "Desplazamientos", pt: "Deslocamentos", it: "Spostamenti", zh: "空驶"))
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
    }
}

extension PrinterService {
    /// What is loaded per head, for the preview legend and its colour dots:
    /// the Spoolman spool assigned to the head when there is one, else vendor
    /// and material as the printer reports them. The colour stays empty
    /// without Spoolman, so the preview can fall back to OrcaSlicer's.
    func loadedFilamentInfo() async -> [(label: String, colorHex: String)] {
        var out: [(label: String, colorHex: String)] = (0..<4).map { i in
            ([slotVendors[safe: i] ?? "", slotMaterials[safe: i] ?? ""].filter { !$0.isEmpty }.joined(separator: " "), "")
        }
        let host = UserDefaults.standard.string(forKey: "spoolman_url") ?? ""
        guard !host.isEmpty, let svc = SpoolmanService(rawHost: host) else { return out }
        for i in 0..<4 {
            let id: Int
            if printerType == .snapmakerU1 {
                id = (mcSlotSpools[safe: i] ?? 0) > 0 ? mcSlotSpools[i] : ((fwSlotSpoolIds[safe: i] ?? 0) > 0 ? fwSlotSpoolIds[i] : 0)
            } else {
                id = i == 0 ? (activeSpoolId ?? 0) : 0
            }
            guard id > 0, let sp = try? await svc.spool(id) else { continue }
            let name = [sp.filament.vendor?.name ?? "", sp.filament.name ?? sp.filament.material ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            if !name.isEmpty { out[i].label = name }
            // Spoolman stores "1F6BFF"; a gradient spool lists several — the
            // first one stands for the spool.
            let colour = (sp.filament.multi_color_hexes?.split(separator: ",").first.map(String.init))
                ?? sp.filament.color_hex ?? ""
            out[i].colorHex = colour.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        }
        return out
    }
}
