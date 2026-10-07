import SwiftUI
import SceneKit
import Combine
import UniformTypeIdentifiers
import Compression

// MARK: - EasyPrint, stage 1: look at a model and orient it, on the phone.
// STL files are parsed here (no library), shown on the printer's real bed with
// SceneKit, and turned by gestures, 90° buttons or "lay on face". Overhangs
// are shaded red the way the slicer preview does it. The result is a 4×4
// transform that stage 2 hands to the slicer on the Mac — nothing on the Mac
// is touched by this screen.

// MARK: Mesh

struct TriMesh {
    var vertices: [SIMD3<Float>] = []      // 3 per triangle, flat (per-face shading)
    var name: String = ""

    nonisolated init() {}

    nonisolated var triangleCount: Int { vertices.count / 3 }

    /// Binary STL of the mesh as held here — what goes to PaxxMaker-Connect, so
    /// both sides number the triangles identically (needed for painting).
    var stlData: Data {
        var d = Data(count: 80)
        var n = UInt32(triangleCount); d.append(Data(bytes: &n, count: 4))
        d.reserveCapacity(84 + triangleCount * 50)
        var zero: UInt16 = 0
        for i in 0..<triangleCount {
            var nrm = simd_cross(vertices[i * 3 + 1] - vertices[i * 3], vertices[i * 3 + 2] - vertices[i * 3])
            let len = simd_length(nrm); if len > 0 { nrm /= len }
            for v in [nrm, vertices[i * 3], vertices[i * 3 + 1], vertices[i * 3 + 2]] {
                var x = v.x, y = v.y, z = v.z
                d.append(Data(bytes: &x, count: 4)); d.append(Data(bytes: &y, count: 4)); d.append(Data(bytes: &z, count: 4))
            }
            d.append(Data(bytes: &zero, count: 2))
        }
        return d
    }

    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard let f = vertices.first else { return (.zero, .zero) }
        var lo = f, hi = f
        for v in vertices { lo = simd_min(lo, v); hi = simd_max(hi, v) }
        return (lo, hi)
    }

    func transformed(_ m: simd_float4x4) -> TriMesh {
        var out = self
        out.vertices = vertices.map { v in
            let p = m * SIMD4<Float>(v, 1)
            return SIMD3<Float>(p.x, p.y, p.z)
        }
        return out
    }
}

enum ModelFileError: LocalizedError {
    case unreadable, unsupported, empty
    var errorDescription: String? {
        switch self {
        case .unreadable: return lz(en: "The file could not be read.", de: "Die Datei konnte nicht gelesen werden.", fr: "Impossible de lire le fichier.", es: "No se pudo leer el archivo.", pt: "Não foi possível ler o arquivo.", it: "Impossibile leggere il file.", zh: "无法读取文件。")
        case .unsupported: return lz(en: "Only STL files are supported.", de: "Nur STL-Dateien werden unterstützt.", fr: "Seuls les fichiers STL sont pris en charge.", es: "Solo se admiten archivos STL.", pt: "Apenas arquivos STL são suportados.", it: "Sono supportati solo file STL.", zh: "仅支持 STL 文件。")
        case .empty: return lz(en: "The file contains no geometry.", de: "Die Datei enthält keine Geometrie.", fr: "Le fichier ne contient aucune géométrie.", es: "El archivo no contiene geometría.", pt: "O arquivo não contém geometria.", it: "Il file non contiene geometria.", zh: "文件不包含几何体。")
        }
    }
}

enum ModelLoader {
    nonisolated static func load(url: URL) throws -> TriMesh {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw ModelFileError.unreadable }
        guard url.pathExtension.lowercased() == "stl" else { throw ModelFileError.unsupported }
        var mesh = try STLParser.parse(data)
        guard mesh.triangleCount > 0 else { throw ModelFileError.empty }
        mesh.name = url.deletingPathExtension().lastPathComponent
        return mesh
    }
}

// MARK: STL (binary and ASCII)

enum STLParser {
    nonisolated static func parse(_ data: Data) throws -> TriMesh {
        // Binary: 80-byte header, uint32 count, 50 bytes per triangle. An ASCII
        // file starts with "solid" but so may a binary header — the size check
        // decides.
        if data.count >= 84 {
            let n = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }
            if data.count == 84 + Int(n) * 50 { return parseBinary(data, count: Int(n)) }
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii),
              text.lowercased().hasPrefix("solid") else { throw ModelFileError.unreadable }
        return parseASCII(text)
    }

    nonisolated private static func parseBinary(_ data: Data, count: Int) -> TriMesh {
        var mesh = TriMesh()
        mesh.vertices.reserveCapacity(count * 3)
        data.withUnsafeBytes { raw in
            var off = 84
            for _ in 0..<count {
                off += 12                                  // normal — recomputed anyway
                for _ in 0..<3 {
                    let x = raw.loadUnaligned(fromByteOffset: off, as: Float.self)
                    let y = raw.loadUnaligned(fromByteOffset: off + 4, as: Float.self)
                    let z = raw.loadUnaligned(fromByteOffset: off + 8, as: Float.self)
                    mesh.vertices.append(SIMD3(x, y, z))
                    off += 12
                }
                off += 2                                   // attribute byte count
            }
        }
        return mesh
    }

    nonisolated private static func parseASCII(_ text: String) -> TriMesh {
        var mesh = TriMesh()
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("vertex") else { continue }
            let p = t.split(separator: " ", omittingEmptySubsequences: true)
            guard p.count >= 4, let x = Float(p[1]), let y = Float(p[2]), let z = Float(p[3]) else { continue }
            mesh.vertices.append(SIMD3(x, y, z))
        }
        mesh.vertices.removeLast(mesh.vertices.count % 3)
        return mesh
    }
}

// MARK: Bed sizes (mm) — what the model sits on

struct BedSize {
    var x: Float, y: Float, z: Float

    /// The printable area. Klipper only knows its axis travel (larger than the
    /// bed), so this is the type default, or what the user entered in the
    /// slicer tab; stage 2 takes it from the Orca printer profile.
    static func `for`(_ config: PrinterConfig) -> BedSize {
        // The U1 is one machine with one bed — 270 × 270 × 270 from Snapmaker's
        // own profile (printable_area 0.5…270.5). Not editable.
        if config.type == .snapmakerU1 { return `for`(.snapmakerU1) }
        if let s = UserDefaults.standard.array(forKey: "bed_size_\(config.name)") as? [Double], s.count >= 3,
           s[0] > 10, s[1] > 10, s[2] > 10 {
            return BedSize(x: Float(s[0]), y: Float(s[1]), z: Float(s[2]))
        }
        return `for`(config.type)
    }
    static func save(_ b: BedSize, for config: PrinterConfig) {
        UserDefaults.standard.set([Double(b.x), Double(b.y), Double(b.z)], forKey: "bed_size_\(config.name)")
    }
    /// Axis travel as reported by Klipper, if the printer has been online.
    static func travel(for config: PrinterConfig) -> BedSize? {
        guard let s = UserDefaults.standard.array(forKey: "axis_travel_\(config.name)") as? [Double], s.count >= 3 else { return nil }
        return BedSize(x: Float(s[0]), y: Float(s[1]), z: Float(s[2]))
    }

    static func `for`(_ type: PrinterConfig.PrinterType) -> BedSize {
        switch type {
        case .snapmakerU1: return BedSize(x: 270, y: 270, z: 270)
        case .singleNozzle: return BedSize(x: 220, y: 220, z: 250)
        }
    }
}

// MARK: Placement of one object

/// The two things that can be painted on an object, as in Orca: colour
/// (which head prints a face) and fuzzy skin.
enum PaintLayer: Hashable { case color, fuzzy }

/// A height range of the whole plate printed with another head — Orca's
/// height range modifier with its own extruder (sent per object as
/// layer_config_ranges). Heights in mm above the bed.
struct LayerBand: Codable, Equatable, Identifiable {
    var id = UUID()
    var head: Int
    var from: Float
    var to: Float
}

/// One object's placement: rotation and scale about its own centre, then a
/// position on the bed. Recomputed into one matrix for the slicer.
final class ModelPlacement: ObservableObject, Identifiable {
    let id = UUID()
    @Published var rotation = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1))
    /// Scale along the object's own axes — all equal unless the lock in the
    /// size panel is open. Scaling in object space keeps the shape when the
    /// object is turned afterwards.
    @Published var scale = SIMD3<Float>(repeating: 1)
    @Published var offset = SIMD2<Float>(0, 0)       // XY shift from bed centre
    /// How far the object is lowered into the bed (mm). What ends up below
    /// the bed is cut off when slicing — a flat face to stand on.
    @Published var sink: Float = 0
    /// Which head prints this object (1-based, U1 only).
    @Published var extruder: Int = 1
    /// The object's own process settings; nil = the general ones.
    @Published var settings: QuickSettings? = nil
    /// Colour painting (heads per face, with Orca-style subdivision); nil
    /// until the first fill or brush stroke.
    private(set) var selector: PaintSelector? = nil
    /// Painted fuzzy skin — Orca's second painting on the same triangles
    /// (state 1 = fuzzy), written as paint_fuzzy_skin. With "Fuzzy Skin:
    /// Painted only" Orca roughens exactly these faces.
    private(set) var fuzzySelector: PaintSelector? = nil
    @Published private(set) var paintedHeads: Set<Int> = []
    @Published private(set) var hasFuzzy = false
    private(set) var paintVersion = 0
    /// One entry per fill, brush stroke or clear: the touched subtrees as
    /// they were — one history per painting.
    private var undoStacks: [PaintLayer: [[Int32: PaintSelector.Snap]]] = [:]
    @Published private(set) var undoCounts: [PaintLayer: Int] = [:]
    func undoCount(_ layer: PaintLayer = .color) -> Int { undoCounts[layer] ?? 0 }
    private var strokeOpen = false
    let mesh: TriMesh
    var bed: BedSize
    /// Centre of the raw mesh; rotation and scale pivot here.
    let pivot: SIMD3<Float>
    var name: String { mesh.name }

    init(mesh: TriMesh, bed: BedSize) {
        self.mesh = mesh
        self.bed = bed
        let b = mesh.bounds
        pivot = (b.min + b.max) / 2
    }

    /// Full transform in bed coordinates: origin at the bed's front-left
    /// corner, Z up, model resting on Z = 0.
    var matrix: simd_float4x4 { matrix(offset: offset) }

    // The placement without the XY shift and its bounds, computed once per
    // rotation/scale. Everything else (bounds, fit check, drag, brush) is then
    // a few floats instead of a pass over the whole mesh — which made every
    // SwiftUI update crawl on big models.
    private var cacheRotation = simd_quatf(vector: SIMD4(repeating: .nan))
    private var cacheScale = SIMD3<Float>(repeating: .nan)
    private var cacheBase = matrix_identity_float4x4
    private var cacheBounds: (min: SIMD3<Float>, max: SIMD3<Float>) = (.zero, .zero)

    private func base() -> (simd_float4x4, (min: SIMD3<Float>, max: SIMD3<Float>)) {
        if cacheScale == scale, cacheRotation.vector == rotation.vector { return (cacheBase, cacheBounds) }
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(-pivot, 1)                                     // centre at origin
        let rs = simd_float4x4(rotation) * simd_float4x4(diagonal: SIMD4(scale.x, scale.y, scale.z, 1))
        m = rs * m
        // Bounds of the rotated, scaled mesh in one pass without a copy.
        let c0 = m.columns.0, c1 = m.columns.1, c2 = m.columns.2, c3 = m.columns.3
        var lo = SIMD4<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD4<Float>(repeating: -.greatestFiniteMagnitude)
        for v in mesh.vertices {
            let p = c0 * v.x + c1 * v.y + c2 * v.z + c3
            lo = simd_min(lo, p); hi = simd_max(hi, p)
        }
        if mesh.vertices.isEmpty { lo = .zero; hi = .zero }
        // Drop onto the bed and move to the bed centre.
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4(bed.x / 2 - (lo.x + hi.x) / 2, bed.y / 2 - (lo.y + hi.y) / 2, -lo.z, 1)
        cacheBase = t * m
        let shift = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        cacheBounds = (SIMD3(lo.x, lo.y, lo.z) + shift, SIMD3(hi.x, hi.y, hi.z) + shift)
        cacheRotation = rotation; cacheScale = scale
        return (cacheBase, cacheBounds)
    }

    /// Rotation, scale, drop onto the bed and centre — the XY shift is a
    /// separate, cheap translation so dragging never rebuilds geometry.
    func matrix(offset o: SIMD2<Float>) -> simd_float4x4 {
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4(o.x, o.y, 0, 1)
        return t * base().0
    }

    var placed: TriMesh { mesh.transformed(matrix) }
    var placedBounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        let b = base().1
        let s = SIMD3<Float>(offset.x, offset.y, 0)
        return (b.min + s, b.max + s)
    }

    var fitsBed: Bool {
        let b = placedBounds
        return b.min.x >= -0.01 && b.min.y >= -0.01 && b.max.x <= bed.x + 0.01 && b.max.y <= bed.y + 0.01 && b.max.z - sink <= bed.z + 0.01
    }

    /// The deepest the object may go: half a millimetre of it must stay.
    var maxSink: Float { max(0, placedSize.z - 0.5) }

    /// Area the object stands on at the current depth (mm²). Straight from
    /// the triangles, no copy of the mesh: each one crossing the plane adds
    /// its piece of the outline.
    func contactArea(at depth: Float? = nil) -> Float {
        let z = depth ?? sink
        let m = matrix(offset: .zero)
        let c0 = m.columns.0, c1 = m.columns.1, c2 = m.columns.2, c3 = m.columns.3
        let v = mesh.vertices
        var s: Double = 0
        var i = 0
        while i + 2 < v.count {
            @inline(__always) func w(_ u: SIMD3<Float>) -> SIMD3<Float> { let q = c0 * u.x + c1 * u.y + c2 * u.z + c3; return SIMD3(q.x, q.y, q.z) }
            let p = (w(v[i]), w(v[i + 1]), w(v[i + 2]))
            @inline(__always) func at(_ k: Int) -> SIMD3<Float> { k == 0 ? p.0 : (k == 1 ? p.1 : p.2) }
            var down: SIMD3<Float>? = nil, up: SIMD3<Float>? = nil
            for k in 0..<3 {
                let a = at(k), b = at((k + 1) % 3)
                let ia = a.z > z, ib = b.z > z
                guard ia != ib else { continue }
                let x = a + (b - a) * ((z - a.z) / (b.z - a.z))
                if ia { down = x } else { up = x }
            }
            if let d = down, let u = up { s += Double(d.x) * Double(u.y) - Double(u.x) * Double(d.y) }
            i += 3
        }
        return abs(Float(s / 2))
    }

    /// What goes to the slicer: the mesh with its transform and painting —
    /// or, when lowered into the bed, the part above it, cut and closed on
    /// the phone. OrcaSlicer would lift a sunk object back onto the bed
    /// (tested), so the cut cannot be left to it. The painting follows the
    /// pieces: whole triangles keep theirs, cut ones keep a single head, the
    /// new bottom face gets the object's own.
    func printedPart() -> (mesh: TriMesh, transform: simd_float4x4, paint: [Int: String], fuzzy: [Int: String]) {
        let paint = paintStrings, fuzzy = fuzzyStrings
        guard sink > 0.001 else { return (mesh, matrix, paint, fuzzy) }
        var world = matrix
        world.columns.3.z -= sink
        let c0 = world.columns.0, c1 = world.columns.1, c2 = world.columns.2, c3 = world.columns.3
        let soup = mesh.vertices.map { v -> SIMD3<Float> in let q = c0 * v.x + c1 * v.y + c2 * v.z + c3; return SIMD3(q.x, q.y, q.z) }
        let cut = ScanMesh.cutAtBed(soup)
        var m = TriMesh()
        m.vertices = cut.vertices
        m.name = mesh.name
        func remap(_ strings: [Int: String], _ sel: PaintSelector?) -> [Int: String] {
            var out: [Int: String] = [:]
            for (j, src) in cut.source.enumerated() where src >= 0 {
                guard let str = strings[Int(src)] else { continue }
                if !cut.clipped[j] || !(sel?.isSplit(original: Int(src)) ?? false) { out[j] = str }
            }
            return out
        }
        return (m, matrix_identity_float4x4, remap(paint, selector), remap(fuzzy, fuzzySelector))
    }

    /// Size of the placed object along the bed axes.
    var placedSize: SIMD3<Float> { let b = placedBounds; return b.max - b.min }

    // Size the object would have at 100 % with its current rotation — the
    // reference for the percent fields, one mesh pass per rotation.
    private var cacheUnitRotation = simd_quatf(vector: SIMD4(repeating: .nan))
    private var cacheUnitSize = SIMD3<Float>(repeating: 1)
    var unitSize: SIMD3<Float> {
        if cacheUnitRotation.vector == rotation.vector { return cacheUnitSize }
        let r = simd_float3x3(rotation)
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in mesh.vertices { let p = r * v; lo = simd_min(lo, p); hi = simd_max(hi, p) }
        cacheUnitSize = mesh.vertices.isEmpty ? SIMD3(repeating: 1) : simd_max(hi - lo, SIMD3(repeating: 1e-4))
        cacheUnitRotation = rotation
        return cacheUnitSize
    }

    /// Scale so the placed size along one bed axis (0 = X, 1 = Y, 2 = Z)
    /// becomes `mm`: the whole object uniformly, or — with the lock open —
    /// only along that axis. The object axis lying closest to the bed axis
    /// is stretched; for a tilted object a few passes home in on the size.
    func setPlacedSize(axis: Int, mm target: Float, uniform: Bool) {
        guard target > 0.05 else { return }
        let cur = placedSize[axis]
        guard cur > 1e-4 else { return }
        if uniform {
            scale = simd_max(scale * (target / cur), SIMD3(repeating: 0.001))
            return
        }
        let r = simd_float3x3(rotation)
        let share = SIMD3(abs(r.columns.0[axis]), abs(r.columns.1[axis]), abs(r.columns.2[axis]))
        var j = 0
        if share.y > share[j] { j = 1 }
        if share.z > share[j] { j = 2 }
        for _ in 0..<8 {
            let now = placedSize[axis]
            if abs(now - target) < 0.01 { break }
            scale[j] = max(0.001, scale[j] * target / now)
        }
    }

    func rotate(axis: SIMD3<Float>, degrees: Float) {
        let q = simd_quatf(angle: degrees * .pi / 180, axis: simd_normalize(axis))
        rotation = simd_normalize(q * rotation)
    }

    /// Turn the model so the face with this (placed-space) normal points
    /// straight down — Orca's "lay on face".
    func layOnFace(normal n: SIMD3<Float>) {
        let from = simd_normalize(n), to = SIMD3<Float>(0, 0, -1)
        let d = simd_dot(from, to)
        if d > 0.9999 { return }
        let q: simd_quatf
        if d < -0.9999 {
            q = simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0))
        } else {
            q = simd_normalize(simd_quatf(angle: acos(d), axis: simd_normalize(simd_cross(from, to))))
        }
        rotation = simd_normalize(q * rotation)
    }

    func reset() { rotation = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)); scale = SIMD3(repeating: 1); offset = .zero; sink = 0 }

    // MARK: smallest footprint

    /// Turns the object about the vertical axis so the rectangle around its
    /// outline seen from above is as small as possible (minimum-area bounding
    /// rectangle: one side of it always lies along an edge of the convex
    /// hull), then puts the long side along X.
    func turnToSmallestFootprint() {
        let (m, _) = base()
        let c0 = m.columns.0, c1 = m.columns.1, c2 = m.columns.2, c3 = m.columns.3
        // Outline at 0.5 mm: per column of the grid only the front- and
        // backmost point — the hull of those is the hull of the object.
        let cell: Float = 0.5
        var lo: [Int: Float] = [:], hi: [Int: Float] = [:]
        for v in mesh.vertices {
            let p = c0 * v.x + c1 * v.y + c2 * v.z + c3
            guard p.x.isFinite, p.y.isFinite else { continue }
            let k = Int((p.x / cell).rounded(.down))
            lo[k] = min(lo[k] ?? .greatestFiniteMagnitude, p.y)
            hi[k] = max(hi[k] ?? -.greatestFiniteMagnitude, p.y)
        }
        var pts: [SIMD2<Float>] = []
        for (k, y) in lo { let x = (Float(k) + 0.5) * cell; pts.append(SIMD2(x, y)); pts.append(SIMD2(x, hi[k] ?? y)) }
        let hull = Self.convexHull(pts)
        guard hull.count >= 3 else { return }
        func extent(_ a: Float) -> (w: Float, d: Float) {
            let ca = cos(a), sa = sin(a)
            var x0 = Float.greatestFiniteMagnitude, x1 = -Float.greatestFiniteMagnitude, y0 = x0, y1 = x1
            for p in hull {
                let x = p.x * ca - p.y * sa, y = p.x * sa + p.y * ca
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
            return (x1 - x0, y1 - y0)
        }
        let now = extent(0)
        var best: (a: Float, area: Float) = (0, now.w * now.d)
        for i in 0..<hull.count {
            let e = hull[(i + 1) % hull.count] - hull[i]
            guard simd_length(e) > 1e-4 else { continue }
            let a = -atan2(e.y, e.x)                       // turns this edge onto the X axis
            let r = extent(a)
            if r.w * r.d < best.area - 1e-3 { best = (a, r.w * r.d) }
        }
        var angle = best.a
        // Only worth a turn when it really saves room (more than 1 %).
        if best.area > now.w * now.d * 0.99 { angle = 0 }
        let r = extent(angle)
        if r.d > r.w + 0.01 { angle += .pi / 2 }
        // Smallest equivalent turn, so nothing flips around for no reason.
        while angle > .pi / 2 + 1e-4 { angle -= .pi }
        while angle < -.pi / 2 - 1e-4 { angle += .pi }
        guard abs(angle) > 1e-3 else { return }
        rotation = simd_normalize(simd_quatf(angle: angle, axis: SIMD3(0, 0, 1)) * rotation)
    }

    /// Andrew's monotone chain, counter-clockwise.
    private static func convexHull(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let p = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard p.count > 2 else { return p }
        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [SIMD2<Float>] = [], upper: [SIMD2<Float>] = []
        for q in p {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        for q in p.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    // MARK: footprint

    // The placed object seen from above as occupied 1 mm cells (without the
    // XY shift), computed once per rotation/scale. The prime tower is checked
    // against this instead of the bounding box, so it may stand in a hole of
    // an object — Orca slices that without complaint.
    private static let fpCell: Float = 1
    private var fpRotation = simd_quatf(vector: SIMD4(repeating: .nan))
    private var fpScale = SIMD3<Float>(repeating: .nan)
    private var fpOrigin = SIMD2<Float>(0, 0)
    private var fpWidth = 0, fpHeight = 0
    private var fpCells: [Bool] = []

    private func footprint() -> (origin: SIMD2<Float>, w: Int, h: Int, cells: [Bool]) {
        if fpScale == scale, fpRotation.vector == rotation.vector { return (fpOrigin, fpWidth, fpHeight, fpCells) }
        let (m, b) = base()
        let cell = Self.fpCell
        let origin = SIMD2(floor(b.min.x / cell) * cell, floor(b.min.y / cell) * cell)
        let w = max(1, Int(ceil((b.max.x - origin.x) / cell)) + 1)
        let h = max(1, Int(ceil((b.max.y - origin.y) / cell)) + 1)
        var cells = [Bool](repeating: false, count: w * h)
        let c0 = m.columns.0, c1 = m.columns.1, c2 = m.columns.2, c3 = m.columns.3
        @inline(__always) func place(_ v: SIMD3<Float>) -> SIMD2<Float> { let p = c0 * v.x + c1 * v.y + c2 * v.z + c3; return SIMD2(p.x, p.y) }
        let verts = mesh.vertices
        var i = 0
        while i + 2 < verts.count {
            Self.rasterize(place(verts[i]), place(verts[i + 1]), place(verts[i + 2]), origin: origin, cell: cell, w: w, h: h, into: &cells)
            i += 3
        }
        fpRotation = rotation; fpScale = scale; fpOrigin = origin; fpWidth = w; fpHeight = h; fpCells = cells
        return (origin, w, h, cells)
    }

    /// Marks the cells a triangle covers: tiny triangles by their box, big
    /// ones cell by cell with a separating-axis test against the square.
    private static func rasterize(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, origin: SIMD2<Float>, cell: Float,
                                  w: Int, h: Int, into cells: inout [Bool]) {
        let lo = simd_min(simd_min(a, b), c), hi = simd_max(simd_max(a, b), c)
        guard lo.x.isFinite, lo.y.isFinite, hi.x.isFinite, hi.y.isFinite else { return }
        let x0 = max(0, Int((lo.x - origin.x) / cell)), x1 = min(w - 1, Int((hi.x - origin.x) / cell))
        let y0 = max(0, Int((lo.y - origin.y) / cell)), y1 = min(h - 1, Int((hi.y - origin.y) / cell))
        if x1 < x0 || y1 < y0 { return }
        if (x1 - x0 + 1) * (y1 - y0 + 1) <= 4 {
            for y in y0...y1 { for x in x0...x1 { cells[y * w + x] = true } }
            return
        }
        // Triangle edge normals and the triangle's extent along each.
        let n0 = SIMD2(-(b.y - a.y), b.x - a.x), n1 = SIMD2(-(c.y - b.y), c.x - b.x), n2 = SIMD2(-(a.y - c.y), a.x - c.x)
        let t0 = (min(simd_dot(n0, a), simd_dot(n0, c)), max(simd_dot(n0, a), simd_dot(n0, c)))
        let t1 = (min(simd_dot(n1, b), simd_dot(n1, a)), max(simd_dot(n1, b), simd_dot(n1, a)))
        let t2 = (min(simd_dot(n2, c), simd_dot(n2, b)), max(simd_dot(n2, c), simd_dot(n2, b)))
        @inline(__always) func separated(_ n: SIMD2<Float>, _ t: (Float, Float), _ sx: Float, _ sy: Float) -> Bool {
            let p0 = simd_dot(n, SIMD2(sx, sy)), p1 = simd_dot(n, SIMD2(sx + cell, sy))
            let p2 = simd_dot(n, SIMD2(sx, sy + cell)), p3 = simd_dot(n, SIMD2(sx + cell, sy + cell))
            let smin = min(min(p0, p1), min(p2, p3)), smax = max(max(p0, p1), max(p2, p3))
            return smax < t.0 || smin > t.1
        }
        for y in y0...y1 {
            let sy = origin.y + Float(y) * cell
            for x in x0...x1 {
                let sx = origin.x + Float(x) * cell
                if separated(n0, t0, sx, sy) || separated(n1, t1, sx, sy) || separated(n2, t2, sx, sy) { continue }
                cells[y * w + x] = true
            }
        }
    }

    /// Does the object's real footprint touch this rectangle (bed coordinates)?
    func footprintOverlaps(min rmin: SIMD2<Float>, max rmax: SIMD2<Float>) -> Bool {
        let fp = footprint()
        let cell = Self.fpCell
        let lo = rmin - offset - fp.origin, hi = rmax - offset - fp.origin
        guard hi.x >= 0, hi.y >= 0, lo.x <= Float(fp.w) * cell, lo.y <= Float(fp.h) * cell else { return false }
        let x0 = max(0, Int(floor(lo.x / cell))), x1 = min(fp.w - 1, Int(floor(hi.x / cell)))
        let y0 = max(0, Int(floor(lo.y / cell))), y1 = min(fp.h - 1, Int(floor(hi.y / cell)))
        if x1 < x0 || y1 < y0 { return false }
        for y in y0...y1 {
            for x in x0...x1 where fp.cells[y * fp.w + x] { return true }
        }
        return false
    }

    // MARK: painting

    private func selector(_ layer: PaintLayer) -> PaintSelector? { layer == .color ? selector : fuzzySelector }
    func paintSelector(_ layer: PaintLayer) -> PaintSelector? { selector(layer) }
    /// Original triangles the last fill changed — drawn at once as an overlay.
    private(set) var lastChanged: Set<Int32> = []
    /// Original triangles the running brush stroke has changed.
    var strokeTouched: Set<Int32> { selector(strokeLayer)?.strokeTouched ?? [] }

    private func selectorOrCreate(_ layer: PaintLayer = .color) -> PaintSelector {
        if let s = selector(layer) { return s }
        let s = PaintSelector(raw: mesh.vertices)
        if layer == .color { selector = s } else { fuzzySelector = s }
        return s
    }

    /// Orca's paint_color strings per original triangle, for the slicer.
    var paintStrings: [Int: String] { selector?.serialize() ?? [:] }
    /// Orca's paint_fuzzy_skin strings per original triangle.
    var fuzzyStrings: [Int: String] { fuzzySelector?.serialize() ?? [:] }

    /// Colour: the head (the object's own one erases). Fuzzy skin: anything
    /// above 0 paints it, 0 erases.
    private func state(for head: Int, _ layer: PaintLayer) -> UInt8 {
        if layer == .fuzzy { return head > 0 ? 1 : 0 }
        return head == extruder ? 0 : UInt8(max(1, min(4, head)))
    }

    /// Fills the face (or the rounding) the tap landed on with `head`;
    /// `angle` is how far a neighbouring facet may tilt and still belong to it.
    /// Painting with the object's own head is the eraser.
    func fill(from tri: Int, head: Int, angle: Float = 5, layer: PaintLayer = .color) {
        let sel = selectorOrCreate(layer)
        sel.beginAction()
        sel.fill(from: tri, state: state(for: head, layer), angle: angle)
        let snaps = sel.endAction()
        push(snaps, layer)
        lastChanged = Set(snaps.keys)
        lastFill = snaps.isEmpty ? nil : (tri, head, layer)
        paintChanged()
    }

    /// The last fill, so moving the angle slider can redo it right away
    /// instead of making people undo and tap again.
    private(set) var lastFill: (tri: Int, head: Int, layer: PaintLayer)? = nil

    /// Runs the last fill again with a different angle.
    func refill(angle: Float) {
        guard let f = lastFill, let sel = selector(f.layer), let snaps = undoStacks[f.layer]?.popLast() else { return }
        sel.restore(snaps)
        undoCounts[f.layer] = undoStacks[f.layer]?.count ?? 0
        fill(from: f.tri, head: f.head, angle: angle, layer: f.layer)
    }

    /// The painting as saved with the project, and the way back in.
    var paintSnapshot: [Int32: PaintSelector.Snap] { selector?.fullSnapshot() ?? [:] }
    var fuzzySnapshot: [Int32: PaintSelector.Snap] { fuzzySelector?.fullSnapshot() ?? [:] }

    func restorePaint(_ snaps: [Int32: PaintSelector.Snap], layer: PaintLayer = .color) {
        guard !snaps.isEmpty else { return }
        let sel = selectorOrCreate(layer)
        sel.restore(snaps)
        undoStacks[layer] = []; undoCounts[layer] = 0
        paintChanged()
    }

    private func push(_ snaps: [Int32: PaintSelector.Snap], _ layer: PaintLayer) {
        guard !snaps.isEmpty else { return }
        var st = undoStacks[layer] ?? []
        st.append(snaps)
        if st.count > 30 { st.removeFirst() }
        undoStacks[layer] = st
        undoCounts[layer] = st.count
    }

    /// Takes back the last fill, stroke or clear of that painting.
    func undoPaint(_ layer: PaintLayer = .color) {
        lastFill = nil
        guard let sel = selector(layer), let snaps = undoStacks[layer]?.popLast() else { return }
        sel.restore(snaps)
        undoCounts[layer] = undoStacks[layer]?.count ?? 0
        paintChanged()
    }

    var hasPaint: Bool { !(selector?.isEmpty ?? true) }
    func hasPaint(_ layer: PaintLayer) -> Bool { !(selector(layer)?.isEmpty ?? true) }

    /// One brush dab at a point on the placed object (bed coordinates, mm),
    /// seen along `viewDir`. The stroke publishes nothing until `endStroke`;
    /// the scene refreshes itself meanwhile.
    private var strokeLayer: PaintLayer = .color
    func dab(atBed p: SIMD3<Float>, radius: Float, viewDir: SIMD3<Float>, orig: Int, head: Int, layer: PaintLayer = .color) {
        lastFill = nil
        let sel = selectorOrCreate(layer)
        if !strokeOpen { sel.beginAction(); strokeOpen = true; strokeLayer = layer }
        let inv = matrix.inverse
        let c4 = inv * SIMD4<Float>(p, 1)
        let s = max((scale.x + scale.y + scale.z) / 3, 1e-4)
        let r = radius / s
        sel.edgeLimitSqr = pow(max(r / 5, 0.35 / s), 2)
        sel.dab(at: SIMD3(c4.x, c4.y, c4.z), radius: r, dir: simd_normalize(rotation.inverse.act(viewDir)),
                startOrig: orig, state: state(for: head, layer))
    }

    func endStroke() {
        let sel = selector(strokeLayer)
        sel?.finishStroke()
        if strokeOpen, let sel { push(sel.endAction(), strokeLayer); strokeOpen = false }
        paintChanged()
    }

    private func paintChanged() {
        paintVersion += 1
        paintedHeads = Set(selector?.usedStates ?? [])
        hasFuzzy = !(fuzzySelector?.isEmpty ?? true)
    }

    func clearPaint(_ layer: PaintLayer = .color) {
        lastFill = nil
        guard let sel = selector(layer), !sel.isEmpty else { return }
        sel.beginAction()
        sel.clearAll()
        push(sel.endAction(), layer)
        paintChanged()
    }

    /// Both paintings, e.g. for Reset.
    func clearAllPaint() { clearPaint(.color); clearPaint(.fuzzy) }

    /// Per-face overhang flags for the current placement: a face counts when
    /// it points down more than `threshold` degrees past horizontal, unless it
    /// lies on the bed.
    func overhangFlags(threshold: Float = 45) -> [Bool] {
        let m = matrix(offset: .zero)
        let c0 = m.columns.0, c1 = m.columns.1, c2 = m.columns.2, c3 = m.columns.3
        let v = mesh.vertices
        let limit = -sin(threshold * .pi / 180)
        var out = [Bool](repeating: false, count: v.count / 3)
        for i in 0..<out.count {
            let pa = c0 * v[i * 3].x + c1 * v[i * 3].y + c2 * v[i * 3].z + c3
            let pb = c0 * v[i * 3 + 1].x + c1 * v[i * 3 + 1].y + c2 * v[i * 3 + 1].z + c3
            let pc = c0 * v[i * 3 + 2].x + c1 * v[i * 3 + 2].y + c2 * v[i * 3 + 2].z + c3
            let a = SIMD3(pa.x, pa.y, pa.z), b = SIMD3(pb.x, pb.y, pb.z), c = SIMD3(pc.x, pc.y, pc.z)
            let n = simd_cross(b - a, c - a)
            let len = simd_length(n)
            guard len > 0 else { continue }
            let nz = n.z / len
            let onBed = a.z < 0.05 && b.z < 0.05 && c.z < 0.05
            out[i] = nz < limit && !onBed
        }
        return out
    }
}

// MARK: The plate — several objects, one selected

final class PlateModel: ObservableObject {
    @Published var objects: [ModelPlacement] = []
    @Published var selectedID: UUID? = nil
    private(set) var bed: BedSize
    private var subs: [UUID: AnyCancellable] = [:]

    init(bed: BedSize) {
        self.bed = bed
        committed = snapshot()
        // Every change to the plate or an object passes through here; once
        // things have been still for a moment the state before counts as one
        // step — a slider drag or a drag on the bed is one undo, not hundreds.
        historySub = objectWillChange.sink { [weak self] _ in self?.scheduleCommit() }
    }

    // MARK: undo (one step per settled change)

    /// Everything a step can change, with the objects themselves kept alive
    /// so a removed one comes back with its mesh and painting.
    private struct PlateState {
        struct Obj { let o: ModelPlacement; let rotation: SIMD4<Float>; let scale: SIMD3<Float>; let offset: SIMD2<Float>; let sink: Float; let extruder: Int }
        var objects: [Obj]
        var towerPos: SIMD2<Float>?
        var bands: [LayerBand]
        var pauses: [Float]
        func same(as other: PlateState) -> Bool {
            guard objects.count == other.objects.count, towerPos == other.towerPos, bands == other.bands, pauses == other.pauses else { return false }
            for (a, b) in zip(objects, other.objects) {
                if a.o !== b.o || a.rotation != b.rotation || a.scale != b.scale || a.offset != b.offset || a.sink != b.sink || a.extruder != b.extruder { return false }
            }
            return true
        }
    }
    private var history: [PlateState] = []
    private var committed: PlateState! = nil
    private var historySub: AnyCancellable? = nil
    private var pendingCommit: DispatchWorkItem? = nil
    private var restoring = false
    @Published private(set) var undoSteps = 0

    private func snapshot() -> PlateState {
        PlateState(objects: objects.map { .init(o: $0, rotation: $0.rotation.vector, scale: $0.scale, offset: $0.offset, sink: $0.sink, extruder: $0.extruder) },
                   towerPos: towerPos, bands: layerBands, pauses: pauseHeights)
    }

    private func scheduleCommit() {
        guard !restoring else { return }
        pendingCommit?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.commit() }
        pendingCommit = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    private func commit() {
        let now = snapshot()
        guard !now.same(as: committed) else { return }
        history.append(committed)
        if history.count > 50 { history.removeFirst() }
        committed = now
        undoSteps = history.count
    }

    /// Back one step.
    func undo() {
        pendingCommit?.cancel()
        commit()                                  // a change still settling counts first
        guard let prev = history.popLast() else { return }
        restoring = true
        for id in Set(objects.map(\.id)).subtracting(prev.objects.map(\.o.id)) { subs[id] = nil }
        for s in prev.objects {
            let o = s.o
            if subs[o.id] == nil { attach(o) }
            o.rotation = simd_quatf(vector: s.rotation)
            o.scale = s.scale
            o.offset = s.offset
            o.sink = s.sink
            o.extruder = s.extruder
        }
        objects = prev.objects.map(\.o)
        towerPos = prev.towerPos
        layerBands = prev.bands
        pauseHeights = prev.pauses
        if !objects.contains(where: { $0.id == selectedID }) { selectedID = objects.last?.id }
        committed = snapshot()
        undoSteps = history.count
        // Let the published changes of the restore pass before listening again.
        DispatchQueue.main.async { self.restoring = false }
    }

    /// A freshly opened plate starts without history.
    func resetHistory() {
        pendingCommit?.cancel()
        history.removeAll()
        committed = snapshot()
        undoSteps = 0
    }

    private func attach(_ p: ModelPlacement) {
        // Forward the object's changes so views observing the plate redraw.
        subs[p.id] = p.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Another printer was picked while the plate stayed: keep the objects and
    /// put them on the new bed rather than starting over.
    func setBed(_ b: BedSize) {
        guard b.x != bed.x || b.y != bed.y || b.z != bed.z else { return }
        bed = b
        for o in objects { o.bed = b }
        towerPos = nil            // the old spot belonged to the old bed
        arrange()
        objectWillChange.send()
    }

    var selected: ModelPlacement? { objects.first { $0.id == selectedID } }

    /// Objects prepared elsewhere (a saved plate, loaded in the background)
    /// go onto the plate as they are — no arranging, no history.
    func adopt(_ placements: [ModelPlacement]) {
        for p in placements {
            p.bed = bed
            attach(p)
            objects.append(p)
        }
        selectedID = objects.first?.id
        resetHistory()
    }

    /// `arrange: false` when a saved plate is rebuilt — its objects come with
    /// their own positions, which a re-arrange per added object would undo.
    func add(_ mesh: TriMesh, arrange rearrange: Bool = true) {
        let p = ModelPlacement(mesh: mesh, bed: bed)
        attach(p)
        objects.append(p)
        selectedID = p.id
        if rearrange && objects.count > 1 { arrange() }
    }

    /// A second copy of an object with everything done to it — turn, size,
    /// sinking, head, own settings and both paintings — set down beside it.
    func duplicate(_ id: UUID) {
        guard let i = objects.firstIndex(where: { $0.id == id }) else { return }
        let src = objects[i]
        let p = ModelPlacement(mesh: src.mesh, bed: bed)
        p.rotation = src.rotation
        p.scale = src.scale
        p.sink = src.sink
        p.extruder = src.extruder
        p.settings = src.settings
        p.restorePaint(src.paintSnapshot, layer: .color)
        p.restorePaint(src.fuzzySnapshot, layer: .fuzzy)
        attach(p)
        objects.insert(p, at: i + 1)
        selectedID = p.id
        // Right beside the original if there is room, else pack the plate.
        let b = src.placedBounds
        let w = b.max.x - b.min.x, d = b.max.y - b.min.y, gap = Self.arrangeGap
        var others = objects.filter { $0.id != p.id }.map(\.placedBounds)
        if showsTower {
            let t = towerRect
            others.append((SIMD3(t.min.x - towerBrim, t.min.y - towerBrim, 0), SIMD3(t.max.x + towerBrim, t.max.y + towerBrim, 0)))
        }
        for step in [SIMD2<Float>(w + gap, 0), SIMD2(-(w + gap), 0), SIMD2(0, d + gap), SIMD2(0, -(d + gap))] {
            p.offset = src.offset + step
            let pb = p.placedBounds
            let free = !others.contains { o in
                pb.min.x < o.max.x + gap / 2 && pb.max.x > o.min.x - gap / 2 && pb.min.y < o.max.y + gap / 2 && pb.max.y > o.min.y - gap / 2
            }
            if p.fitsBed && free { return }
        }
        arrange()
    }

    func remove(_ id: UUID) {
        objects.removeAll { $0.id == id }
        subs[id] = nil
        if selectedID == id { selectedID = objects.last?.id }
    }

    /// Minimum distance between objects (mm), set in the Arrange panel.
    static var arrangeGap: Float {
        let v = UserDefaults.standard.double(forKey: "arrange_gap")
        return v > 0 ? Float(v) : 6
    }

    /// Arranging: the rectangle around all objects together — the area the
    /// printer probes before printing — as small as possible. Objects are set
    /// one by one right against the ones already placed, each where that
    /// rectangle grows least (then squarer, then nearer the middle). Several
    /// orders (and, with `minimizeFootprint`, quarter turns) are tried and
    /// the smallest rectangle wins; at the end the group is centred on the
    /// bed. `minimizeFootprint` first also turns every object about the
    /// vertical axis to its own smallest rectangle; how it stands stays.
    func arrange(gap: Float = PlateModel.arrangeGap, minimizeFootprint: Bool = false) {
        if minimizeFootprint { for o in objects { o.turnToSmallestFootprint() } }
        guard !objects.isEmpty else { return }
        let sizes = objects.map { o -> SIMD2<Float> in
            o.offset = .zero
            let b = o.placedBounds
            return SIMD2(b.max.x - b.min.x, b.max.y - b.min.y)
        }
        // The prime tower gets the back of the plate — close to the tool
        // docks — and the objects the room in front of it.
        let tower = showsTower
        let towerInset = towerBrim + 2
        let usableDepth = tower ? max(bed.y - (towerSize.y + 2 * towerBrim + gap + 2), bed.y * 0.3) : bed.y
        let idx = Array(sizes.indices)
        let orders: [[Int]] = [
            idx.sorted { sizes[$0].x * sizes[$0].y > sizes[$1].x * sizes[$1].y },
            idx.sorted { max(sizes[$0].x, sizes[$0].y) > max(sizes[$1].x, sizes[$1].y) },
            idx.sorted { sizes[$0].x > sizes[$1].x },
            idx.sorted { sizes[$0].y > sizes[$1].y },
        ]
        var best: ArrangeResult? = nil
        for order in orders {
            for turns in minimizeFootprint ? [false, true] : [false] {
                let r = Self.greedyArrange(sizes, order: order, bed: SIMD2(bed.x, usableDepth), gap: gap, allowTurn: turns)
                // Clearly smaller wins; about equal: fewer turns, then squarer.
                if best == nil || r.area < best!.area * 0.995
                    || (r.area < best!.area * 1.005 && (r.turns, r.squareness) < (best!.turns, best!.squareness)) { best = r }
            }
        }
        guard let res = best else { return }
        let lo = res.centres.enumerated().map { $0.element - res.sizes[$0.offset] / 2 }.reduce(SIMD2<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
        let hi = res.centres.enumerated().map { $0.element + res.sizes[$0.offset] / 2 }.reduce(SIMD2<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
        // Centred across the bed, and in the depth in front of the tower.
        let shift = SIMD2(bed.x / 2, usableDepth / 2) - (lo + hi) / 2
        for (i, o) in objects.enumerated() {
            if res.turned[i] { o.rotate(axis: SIMD3(0, 0, 1), degrees: 90) }
            // Offset 0 = the object's box centred on the bed centre.
            o.offset = res.centres[i] + shift - SIMD2(bed.x / 2, bed.y / 2)
        }
        if tower {
            // Behind the middle of the group, at the back edge, never turned.
            let w = towerSize.x, d = towerSize.y
            let midX = (lo.x + hi.x) / 2 + shift.x
            towerPos = SIMD2(min(max(midX - w / 2, towerInset), bed.x - w - towerInset), bed.y - towerInset - d)
        }
    }

    private struct ArrangeResult {
        var centres: [SIMD2<Float>]; var sizes: [SIMD2<Float>]; var turned: [Bool]
        var area: Float; var turns: Int; var squareness: Float
    }

    /// One placing pass in the given order (see `arrange`).
    private static func greedyArrange(_ sizes: [SIMD2<Float>], order: [Int], bed: SIMD2<Float>, gap: Float, allowTurn: Bool) -> ArrangeResult {
        struct Rect { var lo: SIMD2<Float>; var hi: SIMD2<Float> }
        let centre = bed / 2, margin: Float = 2
        var centres = [SIMD2<Float>](repeating: .zero, count: sizes.count)
        var used = sizes, turned = [Bool](repeating: false, count: sizes.count)
        var placed: [Rect] = []
        var pile: Rect? = nil
        for i in order {
            var best: (score: Float, c: SIMD2<Float>, turn: Bool)? = nil
            for turn in allowTurn ? [false, true] : [false] {
                let s = turn ? SIMD2(sizes[i].y, sizes[i].x) : sizes[i]
                let h = s / 2
                // Touching positions: beside each placed box, flush with its edges.
                var xs: Set<Float> = [centre.x], ys: Set<Float> = [centre.y]
                for r in placed {
                    xs.formUnion([r.hi.x + gap + h.x, r.lo.x - gap - h.x, r.lo.x + h.x, r.hi.x - h.x])
                    ys.formUnion([r.hi.y + gap + h.y, r.lo.y - gap - h.y, r.lo.y + h.y, r.hi.y - h.y])
                }
                for x in xs {
                    for y in ys {
                        let c = SIMD2(x, y)
                        let lo = c - h, hi = c + h
                        if placed.contains(where: { lo.x < $0.hi.x + gap - 0.01 && hi.x > $0.lo.x - gap + 0.01 && lo.y < $0.hi.y + gap - 0.01 && hi.y > $0.lo.y - gap + 0.01 }) { continue }
                        let plo = pile.map { simd_min($0.lo, lo) } ?? lo, phi = pile.map { simd_max($0.hi, hi) } ?? hi
                        let p = phi - plo
                        var score = p.x * p.y + 0.05 * abs(p.x - p.y) * max(p.x, p.y) + 0.01 * simd_distance(c, centre)
                        if p.x > bed.x - 2 * margin || p.y > bed.y - 2 * margin { score += 1e9 }     // must fit the bed
                        if best == nil || score < best!.score { best = (score, c, turn) }
                    }
                }
            }
            guard let b = best else { continue }
            let s = b.turn ? SIMD2(sizes[i].y, sizes[i].x) : sizes[i]
            let r = Rect(lo: b.c - s / 2, hi: b.c + s / 2)
            placed.append(r)
            centres[i] = b.c; used[i] = s; turned[i] = b.turn
            pile = pile.map { Rect(lo: simd_min($0.lo, r.lo), hi: simd_max($0.hi, r.hi)) } ?? r
        }
        let p = (pile?.hi ?? .zero) - (pile?.lo ?? .zero)
        return ArrangeResult(centres: centres, sizes: used, turned: turned, area: p.x * p.y,
                             turns: turned.filter { $0 }.count, squareness: abs(p.x - p.y))
    }

    var allFit: Bool { objects.allSatisfy(\.fitsBed) }

    /// Geometry builds running in the background (spinner while > 0).
    @Published var building = 0
    /// A model file being read (spinner).
    @Published var loading = false

    // MARK: prime tower (multi-material)

    /// Shown and sent to the slicer when several heads print (U1).
    var towerEnabled = false
    /// Front-left corner of the prime tower in bed mm — Orca's wipe_tower_x/y.
    /// nil = automatic corner; set once the user drags it.
    @Published var towerPos: SIMD2<Float>? = nil
    @Published var towerSelected = false
    /// The prime tower as Orca prints it: the profile's prime_tower_width
    /// across, and as deep as the purges need — Orca does not state that, it
    /// follows from the purge volume per layer. Measured: 2 colours ≈ 6–13 mm
    /// (with a 5 mm brim around). Until a slice told the real depth (see
    /// `rememberTower`), an estimate by the number of heads is shown.
    var towerSize: SIMD2<Float> { SIMD2(Self.towerWidth, Self.towerDepth(heads: usedHeads.count)) }

    static var towerWidth: Float {
        let v = UserDefaults.standard.double(forKey: "prime_tower_width")
        return v > 5 ? Float(v) : 35
    }
    static func towerDepth(heads: Int) -> Float {
        let learned = UserDefaults.standard.double(forKey: "prime_tower_depth_\(max(heads, 2))")
        if learned > 2 { return Float(learned) }
        return 6 + 7 * Float(max(heads, 2) - 1)
    }
    /// Orca's prime_tower_brim_width — the room kept free around the tower.
    static var towerBrimWidth: Float {
        let v = UserDefaults.standard.object(forKey: "prime_tower_brim_width") as? Double ?? 5
        return Float(max(0, v))
    }

    /// What a slice showed: width and depth of the tower actually printed
    /// for this many heads — from then on the plate shows that.
    static func rememberTower(width: Float, depth: Float, heads: Int) {
        if width > 5 { UserDefaults.standard.set(Double(width), forKey: "prime_tower_width") }
        if depth > 2 { UserDefaults.standard.set(Double(depth), forKey: "prime_tower_depth_\(max(heads, 2))") }
    }

    var usedHeads: Set<Int> {
        var s = Set<Int>()
        for o in objects { s.insert(o.extruder); s.formUnion(o.paintedHeads) }
        s.formUnion(activeBands.map(\.head))
        return s
    }

    // MARK: pauses

    /// Heights (mm) at which the printer pauses — before the first layer
    /// above each one. Inserted into the G-code when it is sent.
    @Published var pauseHeights: [Float] = []

    /// A new pause in the middle of the largest stretch without one.
    func addPause() {
        let h = printHeight
        guard h > 0.6 else { return }
        let marks = [0] + pauseHeights.sorted() + [h]
        var best: (Float, Float) = (0, h)
        for i in 0..<(marks.count - 1) where marks[i + 1] - marks[i] > best.1 - best.0 || (best == (0, h) && i == 0) {
            best = (marks[i], marks[i + 1])
        }
        let z = ((best.0 + best.1) / 2 * 10).rounded() / 10
        guard z > 0.2, z < h - 0.1, !pauseHeights.contains(where: { abs($0 - z) < 0.15 }) else { return }
        pauseHeights.append(z)
        pauseHeights.sort()
    }

    // MARK: layer colours

    /// Height ranges in another colour (several heads only), lowest first.
    @Published var layerBands: [LayerBand] = []

    /// The highest printed point on the plate (mm).
    var printHeight: Float { objects.map { $0.placedSize.z - $0.sink }.max() ?? 0 }

    /// Bands that reach into something printed.
    var activeBands: [LayerBand] { layerBands.filter { $0.to > $0.from && $0.from < printHeight } }

    /// A new band: the upper half of the largest free stretch of height —
    /// or, when everything is coloured already, the upper half of the largest
    /// band. In a head not yet used for a band. Up to four bands.
    func addBand(heads: [Int]) {
        let h = printHeight
        guard h > 0.4, layerBands.count < 4 else { return }
        let taken = Set(layerBands.map(\.head))
        let own = Set(objects.map(\.extruder))
        let head = heads.first { !taken.contains($0) && !own.contains($0) } ?? heads.first { !taken.contains($0) } ?? 1
        let sorted = layerBands.sorted { $0.from < $1.from }
        var gaps: [(Float, Float)] = []
        var z: Float = 0
        for b in sorted {
            if b.from - z > 0.4 { gaps.append((z, b.from)) }
            z = max(z, b.to)
        }
        if h - z > 0.4 { gaps.append((z, h)) }
        func snap(_ v: Float) -> Float { (v * 10).rounded() / 10 }
        if let g = gaps.max(by: { $0.1 - $0.0 < $1.1 - $1.0 }) {
            layerBands.append(LayerBand(head: head, from: snap((g.0 + g.1) / 2), to: snap(g.1)))
        } else if let big = sorted.max(by: { $0.to - $0.from < $1.to - $1.from }), big.to - big.from > 0.8,
                  let i = layerBands.firstIndex(where: { $0.id == big.id }) {
            let mid = snap((big.from + big.to) / 2)
            layerBands[i].to = mid
            layerBands.append(LayerBand(head: head, from: mid, to: big.to))
        }
        layerBands.sort { $0.from < $1.from }
    }
    var showsTower: Bool { towerEnabled && usedHeads.count > 1 }

    /// Object footprints with the margin the slicer's brim needs.
    private func footprints(margin: Float = 12) -> [(SIMD2<Float>, SIMD2<Float>)] {
        objects.map { o in
            let b = o.placedBounds
            return (SIMD2(b.min.x - margin, b.min.y - margin), SIMD2(b.max.x + margin, b.max.y + margin))
        }
    }

    private func overlaps(_ p: SIMD2<Float>, _ boxes: [(SIMD2<Float>, SIMD2<Float>)]) -> Bool {
        boxes.contains { b in p.x < b.1.x && p.x + towerSize.x > b.0.x && p.y < b.1.y && p.y + towerSize.y > b.0.y }
    }

    /// The first free corner (back-left first, like Orca's default), else a
    /// grid scan — the same rule PaxxMaker-Connect applies.
    func autoTowerPos() -> SIMD2<Float> {
        let boxes = footprints()
        let inset: Float = 12                         // brim and skirt need room at the edge
        var candidates: [SIMD2<Float>] = [SIMD2(inset, bed.y - inset - towerSize.y), SIMD2(bed.x - inset - towerSize.x, bed.y - inset - towerSize.y),
                                          SIMD2(inset, inset), SIMD2(bed.x - inset - towerSize.x, inset)]
        var y = bed.y - inset - towerSize.y
        while y >= inset { var x = inset; while x <= bed.x - inset - towerSize.x { candidates.append(SIMD2(x, y)); x += 20 }; y -= 20 }
        return candidates.first { !overlaps($0, boxes) } ?? candidates[0]
    }

    /// Where the tower stands right now (manual or automatic).
    var towerRect: (min: SIMD2<Float>, max: SIMD2<Float>) {
        let p = towerPos ?? autoTowerPos()
        return (p, p + towerSize)
    }

    /// Room the tower's brim needs around it.
    private var towerBrim: Float { Self.towerBrimWidth }

    /// The tower (with brim) must not touch an object's real footprint —
    /// standing in a hole of a part is fine, Orca slices that.
    var towerCollides: Bool {
        let r = towerRect
        return objects.contains { $0.footprintOverlaps(min: r.min - towerBrim, max: r.max + towerBrim) }
    }

    /// Orca refuses a tower whose brim leaves the printable area.
    var towerNearEdge: Bool {
        let r = towerRect
        return r.min.x - towerBrim < 0 || r.min.y - towerBrim < 0 || r.max.x + towerBrim > bed.x || r.max.y + towerBrim > bed.y
    }

    func moveTower(to p: SIMD2<Float>) {
        let inset: Float = 8
        towerPos = SIMD2(min(max(p.x, inset), bed.x - towerSize.x - inset), min(max(p.y, inset), bed.y - towerSize.y - inset))
    }
}

// MARK: SceneKit view
//
// Model and bed live in PRINTER coordinates (X right, Y away, Z up). SceneKit
// is Y-up and its built-in camera control orbits around Y — building the
// scene Z-up made the view tumble around the wrong axis and the X/Y/Z buttons
// looked wrong against the bed. So every point is converted on the way in:
// scene(x, y, z) = (bed.x, bed.z, -bed.y). All maths stays in bed space.

@inline(__always) private func toScene(_ v: SIMD3<Float>) -> SCNVector3 { SCNVector3(v.x, v.z, -v.y) }

struct ModelSceneView: UIViewRepresentable {
    @ObservedObject var plate: PlateModel
    var accent: UIColor
    /// U1: the filament colour loaded in each head — objects take the colour
    /// of the head they are assigned to.
    var headColors: [UIColor] = []
    var faceMode: Bool
    /// While painting: the head a tapped region gets (nil = not painting).
    var paintHead: Int? = nil
    /// Brush radius in mm while the brush tool is active (nil = fill tool).
    var brushRadius: Float? = nil
    /// How far a facet may tilt against the tapped one and still be filled.
    var fillAngle: Float = 5
    /// Which painting is edited and shown: colour or fuzzy skin.
    var paintLayer: PaintLayer = .color
    /// A long press on an object (outside painting): offer duplicate/remove.
    var onLongPress: (ModelPlacement) -> Void = { _ in }
    var onFaceTap: (ModelPlacement, SIMD3<Float>) -> Void

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.backgroundColor = .clear
        v.antialiasingMode = .multisampling4X
        v.allowsCameraControl = true
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.inertiaEnabled = true
        v.autoenablesDefaultLighting = false
        v.scene = context.coordinator.buildScene()
        v.pointOfView = context.coordinator.camera
        v.delegate = context.coordinator
        // The camera controller installs its own recognizers; without the
        // delegate ours are silently blocked.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        v.addGestureRecognizer(tap)
        // Dragging an object moves it on the bed; a drag that starts on empty
        // space is left to the camera.
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:)))
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        v.addGestureRecognizer(pan)
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.held(_:)))
        hold.delegate = context.coordinator
        hold.minimumPressDuration = 0.5
        v.addGestureRecognizer(hold)
        context.coordinator.view = v
        context.coordinator.sync()
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, SCNSceneRendererDelegate {
        var parent: ModelSceneView
        weak var view: SCNView?
        let root = SCNNode()
        let objectsNode = SCNNode()
        let camera = SCNNode()
        private var plateNode: SCNNode?
        private var belowPlate = false

        /// Looking up from under the bed (to check overhangs) the plate would
        /// hide everything, so it fades out while the camera is below it.
        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let pov = renderer.pointOfView, let plate = plateNode else { return }
            let below = pov.worldPosition.y < 0
            guard below != belowPlate else { return }
            belowPlate = below
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.25
            plate.opacity = below ? 0.15 : 1
            SCNTransaction.commit()
        }
        private var nodes: [UUID: SCNNode] = [:]
        private var keys: [UUID: String] = [:]
        private var dragging: ModelPlacement? = nil
        private var dragStartOffset = SIMD2<Float>(0, 0)
        private var dragStartPoint = SIMD2<Float>(0, 0)
        private var painting: ModelPlacement? = nil
        private var lastPaintRefresh: TimeInterval = 0
        private var towerNode: SCNNode? = nil
        private var towerKey = ""
        private var generation: [UUID: Int] = [:]
        private var draggingTower = false
        private var towerDragStart = SIMD2<Float>(0, 0)
        /// Rendered triangle → original triangle, per object (painting splits faces).
        private var leafSources: [UUID: [Int32]] = [:]

        init(_ p: ModelSceneView) { parent = p }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Our pan must not run together with the camera's pan.
            if g is UIPanGestureRecognizer || other is UIPanGestureRecognizer { return false }
            return true
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard g is UIPanGestureRecognizer, let view else { return true }
            // Start point = current location minus the movement so far.
            let pan = g as! UIPanGestureRecognizer
            let loc = pan.location(in: view), t = pan.translation(in: view)
            let start = CGPoint(x: loc.x - t.x, y: loc.y - t.y)
            // The selected prime tower is dragged like an object.
            if parent.plate.towerSelected, let first = view.hitTest(start, options: [.categoryBitMask: NSNumber(value: 1)]).first, first.node.name == "tower" {
                draggingTower = true
                towerDragStart = parent.plate.towerRect.min
                dragStartPoint = bedPoint(at: start) ?? .zero
                view.allowsCameraControl = false
                return true
            }
            // Only the selected object is dragged or painted; a pan over
            // anything else turns the camera, so the view can be rotated
            // freely and an object is picked by tapping first.
            guard let obj = object(at: start), obj.id == parent.plate.selectedID else { return false }
            if parent.brushRadius != nil, parent.paintHead != nil {
                painting = obj
                view.allowsCameraControl = false
                brush(at: start)
                return true
            }
            dragging = obj
            dragStartOffset = obj.offset
            dragStartPoint = bedPoint(at: start) ?? .zero
            view.allowsCameraControl = false
            return true
        }

        func buildScene() -> SCNScene {
            let scene = SCNScene()
            scene.rootNode.addChildNode(root)
            let bed = parent.plate.bed

            let plate = SCNNode(geometry: SCNBox(width: CGFloat(bed.x), height: 1.2, length: CGFloat(bed.y), chamferRadius: 0))
            plate.geometry?.firstMaterial?.diffuse.contents = UIColor(white: 0.18, alpha: 1)
            plate.geometry?.firstMaterial?.lightingModel = .constant
            plate.position = toScene(SIMD3(bed.x / 2, bed.y / 2, -0.6))
            plate.name = "bed"
            root.addChildNode(plate)
            plateNode = plate
            root.addChildNode(gridNode(bed))

            let box = SCNNode(geometry: SCNBox(width: CGFloat(bed.x), height: CGFloat(bed.z), length: CGFloat(bed.y), chamferRadius: 0))
            box.geometry?.firstMaterial?.fillMode = .lines
            box.geometry?.firstMaterial?.diffuse.contents = UIColor.white.withAlphaComponent(0.12)
            box.geometry?.firstMaterial?.lightingModel = .constant
            box.position = toScene(SIMD3(bed.x / 2, bed.y / 2, bed.z / 2))
            box.categoryBitMask = 2
            root.addChildNode(box)

            for (dir, colour) in [(SIMD3<Float>(1, 0, 0), UIColor.systemRed), (SIMD3<Float>(0, 1, 0), UIColor.systemGreen), (SIMD3<Float>(0, 0, 1), UIColor.systemBlue)] {
                let src = SCNGeometrySource(vertices: [toScene(.zero), toScene(dir * 25)])
                let el = SCNGeometryElement(indices: [Int32(0), Int32(1)], primitiveType: .line)
                let g = SCNGeometry(sources: [src], elements: [el])
                g.firstMaterial?.diffuse.contents = colour
                g.firstMaterial?.lightingModel = .constant
                let n = SCNNode(geometry: g); n.categoryBitMask = 2
                root.addChildNode(n)
            }

            root.addChildNode(objectsNode)

            let key = SCNNode(); key.light = SCNLight(); key.light?.type = .directional; key.light?.intensity = 900
            key.position = toScene(SIMD3(bed.x, -bed.y * 0.5, bed.z * 2))
            key.look(at: toScene(SIMD3(bed.x / 2, bed.y / 2, 0)))
            root.addChildNode(key)
            let fill = SCNNode(); fill.light = SCNLight(); fill.light?.type = .directional; fill.light?.intensity = 350
            fill.position = toScene(SIMD3(-bed.x * 0.5, bed.y * 1.5, bed.z))
            fill.look(at: toScene(SIMD3(bed.x / 2, bed.y / 2, 0)))
            root.addChildNode(fill)
            let amb = SCNNode(); amb.light = SCNLight(); amb.light?.type = .ambient; amb.light?.intensity = 250   // less flat light: more shape
            root.addChildNode(amb)

            camera.camera = SCNCamera()
            // A light that travels with the view: whichever side one looks at,
            // faces turned away get darker — relief stays readable.
            let head = SCNNode(); head.light = SCNLight(); head.light?.type = .directional; head.light?.intensity = 520
            camera.addChildNode(head)
            camera.camera?.zFar = 5000
            camera.camera?.fieldOfView = 45
            camera.position = toScene(SIMD3(bed.x / 2, -bed.y * 1.2, bed.z * 1.0))
            camera.look(at: toScene(SIMD3(bed.x / 2, bed.y / 2, bed.z * 0.2)))
            scene.rootNode.addChildNode(camera)
            return scene
        }

        private func gridNode(_ bed: BedSize) -> SCNNode {
            var verts: [SCNVector3] = []
            var i: Float = 0
            while i <= bed.x + 0.01 { verts.append(toScene(SIMD3(i, 0, 0))); verts.append(toScene(SIMD3(i, bed.y, 0))); i += 10 }
            i = 0
            while i <= bed.y + 0.01 { verts.append(toScene(SIMD3(0, i, 0))); verts.append(toScene(SIMD3(bed.x, i, 0))); i += 10 }
            let src = SCNGeometrySource(vertices: verts)
            let idx = (0..<verts.count).map { Int32($0) }
            let el = SCNGeometryElement(indices: idx, primitiveType: .line)
            let g = SCNGeometry(sources: [src], elements: [el])
            g.firstMaterial?.diffuse.contents = UIColor.white.withAlphaComponent(0.13)
            g.firstMaterial?.lightingModel = .constant
            let n = SCNNode(geometry: g); n.categoryBitMask = 2
            return n
        }

        /// Adds/removes/rebuilds object nodes to match the plate. Only objects
        /// whose placement changed are re-meshed.
        func sync() {
            let plate = parent.plate
            let live = Set(plate.objects.map(\.id))
            for (id, n) in nodes where !live.contains(id) { n.removeFromParentNode(); nodes[id] = nil; keys[id] = nil; leafSources[id] = nil; overlays[id] = nil }
            for o in plate.objects {
                let node = nodes[o.id] ?? { let n = SCNNode(); n.name = o.id.uuidString; objectsNode.addChildNode(n); nodes[o.id] = n; return n }()
                let selected = o.id == plate.selectedID
                // The shift is only the node's position: a drag moves the
                // object at frame rate instead of rebuilding its mesh each time.
                node.position = SCNVector3(o.offset.x, -o.sink, -o.offset.y)
                // Selecting only tints the material — no rebuild for that.
                Self.tint(node, selected: selected)
                applyBands(node)
                let key = "\(o.rotation.vector)|\(o.scale)|\(o.fitsBed)|\(o.extruder)|\(o.paintVersion)|\(parent.headColors.count)|\(o.sink)|\(parent.paintLayer)"
                guard keys[o.id] != key else { continue }
                keys[o.id] = key
                buildAsync(o)
            }
            syncTower()
            syncPauses()
        }

        /// A thin yellow sheet across the bed at every pause height.
        private var pauseNodes: [SCNNode] = []
        private var pauseKey = ""
        private func syncPauses() {
            let plate = parent.plate
            let key = plate.pauseHeights.map { String(format: "%.2f", $0) }.joined(separator: ",") + "|\(plate.bed.x)"
            guard key != pauseKey else { return }
            pauseKey = key
            pauseNodes.forEach { $0.removeFromParentNode() }
            pauseNodes = plate.pauseHeights.map { z in
                let box = SCNBox(width: CGFloat(plate.bed.x), height: 0.25, length: CGFloat(plate.bed.y), chamferRadius: 0)
                box.firstMaterial?.diffuse.contents = UIColor.systemYellow.withAlphaComponent(0.28)
                box.firstMaterial?.lightingModel = .constant
                box.firstMaterial?.isDoubleSided = true
                box.firstMaterial?.writesToDepthBuffer = false
                let n = SCNNode(geometry: box)
                n.categoryBitMask = 2                     // never picked
                n.position = toScene(SIMD3(plate.bed.x / 2, plate.bed.y / 2, z))
                root.addChildNode(n)
                return n
            }
        }

        /// Unselected objects are dimmed a little so the active one stands out.
        static func tint(_ node: SCNNode, selected: Bool) {
            node.geometry?.firstMaterial?.multiply.contents = UIColor(white: selected ? 1 : 0.55, alpha: 1)
        }

        /// The prime tower as a translucent block the user can tap and drag;
        /// red when it overlaps an object (Orca would refuse to slice).
        private func syncTower() {
            let plate = parent.plate
            guard plate.showsTower else {
                towerNode?.removeFromParentNode(); towerNode = nil; towerKey = ""
                return
            }
            let r = plate.towerRect
            let height = max(plate.objects.map { $0.placedBounds.max.z }.max() ?? 20, 20)
            let collides = plate.towerCollides || plate.towerNearEdge
            let key = "\(r.min)|\(r.max)|\(height)|\(collides)|\(plate.towerSelected)"
            guard key != towerKey else { return }
            towerKey = key
            let node = towerNode ?? { let n = SCNNode(); n.name = "tower"; n.categoryBitMask = 1; root.addChildNode(n); towerNode = n; return n }()
            let box = SCNBox(width: CGFloat(plate.towerSize.x), height: CGFloat(height), length: CGFloat(plate.towerSize.y), chamferRadius: 0.5)
            let colour: UIColor = collides ? .systemRed : (plate.towerSelected ? .systemTeal : .systemGray)
            box.firstMaterial?.diffuse.contents = colour.withAlphaComponent(plate.towerSelected ? 0.6 : 0.4)
            box.firstMaterial?.lightingModel = .blinn
            box.firstMaterial?.isDoubleSided = true
            node.geometry = box
            node.position = toScene(SIMD3((r.min.x + r.max.x) / 2, (r.min.y + r.max.y) / 2, height / 2))
        }

        /// Everything the geometry build needs, gathered on the main thread so
        /// the heavy part can run in the background.
        struct GeometryJob {
            var matrix: simd_float4x4
            var raw: [SIMD3<Float>]
            /// The painting, frozen (no copy) — walked in the background.
            var painting: PaintSelector.Frozen?
            var base: SIMD4<Float>
            var headCols: [SIMD4<Float>]
            var fits: Bool
            /// Lowered into the bed by this much: the part below is not drawn.
            var sink: Float = 0
            /// Showing the fuzzy-skin painting: its faces in their own colour.
            var fuzzyView = false
        }

        /// Filament colours are drawn as they are.
        static func shade(_ c: SIMD4<Float>) -> SIMD4<Float> { c }

        /// Layer colours drawn by height on the GPU: moving a slider only
        /// changes these values, the object is not rebuilt. World Y is the
        /// height above the bed (the node is already lowered by its sink).
        static let bandShader = """
        #pragma arguments
        float4 bandFrom;
        float4 bandTo;
        float4 bandC0;
        float4 bandC1;
        float4 bandC2;
        float4 bandC3;
        #pragma body
        if (_surface.diffuse.a > 0.995) {
            float z = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).y;
            if (z >= bandFrom.x && z < bandTo.x) { _surface.diffuse = bandC0; }
            else if (z >= bandFrom.y && z < bandTo.y) { _surface.diffuse = bandC1; }
            else if (z >= bandFrom.z && z < bandTo.z) { _surface.diffuse = bandC2; }
            else if (z >= bandFrom.w && z < bandTo.w) { _surface.diffuse = bandC3; }
        }
        _surface.diffuse.a = 1.0;
        """

        /// Puts the plate's layer colours into an object's material.
        private func applyBands(_ node: SCNNode) {
            guard let m = node.geometry?.firstMaterial else { return }
            let bands = parent.paintLayer == .fuzzy ? [] : Array(parent.plate.activeBands.prefix(4))
            var from = [Float](repeating: -1, count: 4), to = [Float](repeating: -1, count: 4)
            var cols = [SIMD4<Float>](repeating: .zero, count: 4)
            for (i, b) in bands.enumerated() {
                from[i] = b.from; to[i] = b.to
                var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, a: CGFloat = 0
                (parent.headColors[safe: b.head - 1] ?? parent.accent).getRed(&r, green: &g, blue: &bl, alpha: &a)
                cols[i] = Self.shade(SIMD4(Float(r), Float(g), Float(bl), 1))
            }
            m.setValue(SCNVector4(from[0], from[1], from[2], from[3]), forKey: "bandFrom")
            m.setValue(SCNVector4(to[0], to[1], to[2], to[3]), forKey: "bandTo")
            for i in 0..<4 { m.setValue(SCNVector4(cols[i].x, cols[i].y, cols[i].z, 1), forKey: "bandC\(i)") }
        }

        /// OrcaSlicer's own look (its gouraud shader): two lights fixed to the
        /// view — top-left and front-right — over a 0.3 ambient, never brighter
        /// than 0.96, so white keeps its shading and every colour stays true;
        /// plus a fine highlight. On top, a little of what plastic mirrors at
        /// grazing angles (brighter above, darker below): rounded edges and
        /// steps of dark parts stay readable without greying the colour.
        static let lookShader = """
        float3 n = normalize(_surface.normal);
        float3 v = normalize(-_surface.position);
        if (dot(n, v) < 0.0) { n = -n; }
        float3 lt = float3(-0.4574957, 0.4574957, 0.7624929);
        float3 lf = float3(0.6985074, 0.1397015, 0.6985074);
        float diff = 0.3 + 0.48 * max(dot(n, lt), 0.0) + 0.18 * max(dot(n, lf), 0.0);
        float spec = 0.12 * pow(max(dot(v, reflect(-lt, n)), 0.0), 20.0);
        float fres = 0.02 + 0.32 * pow(1.0 - max(dot(n, v), 0.0), 4.0);
        float env = mix(0.12, 0.85, 0.5 + 0.5 * n.y);
        float3 col = mix(_surface.diffuse.rgb * diff, float3(env), fres) + spec;
        _output.color.rgb = col * _surface.multiply.rgb;
        """

        /// The material every object is drawn with (with or without layer colours).
        static func gloss(_ m: SCNMaterial?, bands: Bool = false) {
            m?.lightingModel = .constant
            m?.shaderModifiers = bands ? [.surface: bandShader, .fragment: lookShader] : [.fragment: lookShader]
        }

        /// Painted fuzzy skin on screen — a colour no filament is likely to have.
        static let fuzzyColour = SIMD4<Float>(0.93, 0.36, 0.86, 1)

        private func job(for o: ModelPlacement) -> GeometryJob {
            var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
            (parent.headColors[safe: o.extruder - 1] ?? parent.accent).getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
            let headCols: [SIMD4<Float>] = (0..<4).map { i in
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                (parent.headColors[safe: i] ?? parent.accent).getRed(&r, green: &g, blue: &b, alpha: &a)
                return Self.shade(SIMD4(Float(r), Float(g), Float(b), 1))
            }
            let fuzzyView = parent.paintLayer == .fuzzy
            // Collecting 1.5 million pieces here used to stall the main
            // thread; the frozen painting is handed over as it is.
            let painting = (fuzzyView ? o.fuzzySelector : o.selector)?.frozen
            return GeometryJob(matrix: o.matrix(offset: .zero), raw: o.mesh.vertices, painting: painting,
                               base: Self.shade(SIMD4(Float(ar), Float(ag), Float(ab), 1)), headCols: headCols,
                               fits: o.fitsBed, sink: o.sink, fuzzyView: fuzzyView)
        }

        /// Placed triangles with normals, overhang colouring and paint —
        /// pure computation, safe off the main thread.
        static func build(_ j: GeometryJob) -> (SCNGeometry, [Int32]?) {
            let c0 = j.matrix.columns.0, c1 = j.matrix.columns.1, c2 = j.matrix.columns.2, c3 = j.matrix.columns.3
            @inline(__always) func place(_ v: SIMD3<Float>) -> SIMD3<Float> { let p = c0 * v.x + c1 * v.y + c2 * v.z + c3; return SIMD3(p.x, p.y, p.z) }
            let n = j.painting != nil ? j.raw.count + j.raw.count / 4 : j.raw.count
            let overhangLimit: Float = -sin(45 * Float.pi / 180)
            var pos = [SCNVector3](); pos.reserveCapacity(n)
            var nor = [SCNVector3](); nor.reserveCapacity(n)
            var col = [SIMD4<Float>](); col.reserveCapacity(n)
            let red = SIMD4<Float>(0.95, 0.25, 0.2, 1)
            let outside = SIMD4<Float>(0.95, 0.6, 0.1, 1)
            let marked = SIMD4<Float>(1, 1, 1, 0.99)
            let floor = j.sink
            @inline(__always) func put(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, painted: SIMD4<Float>?) {
                var nn = simd_cross(b - a, c - a)
                let len = simd_length(nn); if len > 0 { nn /= len }
                let overhang = nn.z < overhangLimit && !(a.z < floor + 0.05 && b.z < floor + 0.05 && c.z < floor + 0.05)
                // Alpha 0.99 marks colours of their own (painting, overhang,
                // outside): the layer-colour shader leaves those alone.
                let colour = !j.fits ? outside * marked : (painted.map { $0 * marked } ?? (overhang ? red * marked : j.base))
                pos.append(toScene(a)); pos.append(toScene(b)); pos.append(toScene(c))
                let sn = toScene(nn); nor.append(sn); nor.append(sn); nor.append(sn)
                col.append(colour); col.append(colour); col.append(colour)
            }
            /// Only what stands above the bed is drawn; a triangle crossing it
            /// is cut there. Returns how many pieces were drawn.
            @inline(__always) func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, painted: SIMD4<Float>?) -> Int {
                if floor <= 0 || (a.z >= floor && b.z >= floor && c.z >= floor) { put(a, b, c, painted: painted); return 1 }
                if a.z < floor && b.z < floor && c.z < floor { return 0 }
                var poly: [SIMD3<Float>] = []
                let v = [a, b, c]
                for k in 0..<3 {
                    let p = v[k], q = v[(k + 1) % 3]
                    let ip = p.z >= floor, iq = q.z >= floor
                    if ip { poly.append(p) }
                    if ip != iq { var x = p + (q - p) * ((floor - p.z) / (q.z - p.z)); x.z = floor; poly.append(x) }
                }
                guard poly.count >= 3 else { return 0 }
                for k in 1..<(poly.count - 1) { put(poly[0], poly[k], poly[k + 1], painted: painted) }
                return poly.count - 2
            }
            var sources: [Int32]? = nil
            if let painting = j.painting {
                var src: [Int32] = []; src.reserveCapacity(n / 3)
                painting.forEachLeaf { a, b, c, st, s in
                    let n = add(place(a), place(b), place(c), painted: st > 0 ? (j.fuzzyView ? fuzzyColour : j.headCols[Int(st) - 1]) : nil)
                    for _ in 0..<n { src.append(s) }
                }
                sources = src
            } else {
                let raw = j.raw
                // Without painting, picking maps drawn triangles back to the
                // mesh through this list as soon as a cut changes the count.
                var src: [Int32] = []
                if floor > 0 { src.reserveCapacity(raw.count / 3) }
                for i in 0..<(raw.count / 3) {
                    let n = add(place(raw[i * 3]), place(raw[i * 3 + 1]), place(raw[i * 3 + 2]), painted: nil)
                    if floor > 0 { for _ in 0..<n { src.append(Int32(i)) } }
                }
                if floor > 0 { sources = src }
            }
            let count = pos.count
            let colData = col.withUnsafeBufferPointer { Data(buffer: $0) }
            let colSrc = SCNGeometrySource(data: colData, semantic: .color, vectorCount: count, usesFloatComponents: true,
                                           componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
            let idx = (0..<count).map { Int32($0) }
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: pos), SCNGeometrySource(normals: nor), colSrc],
                                elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
            gloss(g.firstMaterial, bands: true)
            g.firstMaterial?.isDoubleSided = true
            return (g, sources)
        }

        /// While painting, only the changed pieces are drawn — as a thin
        /// layer just above the surface — instead of rebuilding the whole
        /// object on every dab (1.5 million triangles made that lag). The
        /// full rebuild then runs in the background and replaces the layer.
        private var overlays: [UUID: SCNNode] = [:]

        private func showOverlay(_ o: ModelPlacement, originals: Set<Int32>) {
            guard !originals.isEmpty, let node = nodes[o.id],
                  let sel = o.paintSelector(parent.paintLayer) else { return }
            let j = job(for: o)
            let painting = sel.frozen
            let c0 = j.matrix.columns.0, c1 = j.matrix.columns.1, c2 = j.matrix.columns.2, c3 = j.matrix.columns.3
            @inline(__always) func place(_ v: SIMD3<Float>) -> SIMD3<Float> { let p = c0 * v.x + c1 * v.y + c2 * v.z + c3; return SIMD3(p.x, p.y, p.z) }
            var pos: [SCNVector3] = [], nor: [SCNVector3] = [], col: [SIMD4<Float>] = []
            painting.forEachLeaf(of: originals) { a0, b0, c0v, st, _ in
                var a = place(a0), b = place(b0), c = place(c0v)
                if j.sink > 0, a.z < j.sink, b.z < j.sink, c.z < j.sink { return }
                var n = simd_cross(b - a, c - a)
                let len = simd_length(n); guard len > 0 else { return }
                n /= len
                // Lifted a hair along the face so it covers the old colour.
                let lift = n * 0.04
                a += lift; b += lift; c += lift
                let colour = st > 0 ? (j.fuzzyView ? Self.fuzzyColour : j.headCols[Int(st) - 1]) : j.base
                pos.append(toScene(a)); pos.append(toScene(b)); pos.append(toScene(c))
                let sn = toScene(n); nor.append(sn); nor.append(sn); nor.append(sn)
                col.append(colour); col.append(colour); col.append(colour)
            }
            guard !pos.isEmpty else { return }
            let colData = col.withUnsafeBufferPointer { Data(buffer: $0) }
            let colSrc = SCNGeometrySource(data: colData, semantic: .color, vectorCount: col.count, usesFloatComponents: true,
                                           componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: pos), SCNGeometrySource(normals: nor), colSrc],
                                elements: [SCNGeometryElement(indices: (0..<Int32(pos.count)).map { $0 }, primitiveType: .triangles)])
            Self.gloss(g.firstMaterial)
            g.firstMaterial?.isDoubleSided = true
            let layer = overlays[o.id] ?? {
                let n = SCNNode()
                n.categoryBitMask = 4                  // never picked: hits map to the object's own triangles
                node.addChildNode(n)
                overlays[o.id] = n
                return n
            }()
            layer.geometry = g
        }

        private func dropOverlay(_ id: UUID) {
            overlays[id]?.removeFromParentNode()
            overlays[id] = nil
        }

        /// Background build; the result lands on the node only if nothing
        /// newer was requested meanwhile. The plate shows a spinner meanwhile.
        private func buildAsync(_ o: ModelPlacement) {
            let gen = (generation[o.id] ?? 0) + 1
            generation[o.id] = gen
            let j = job(for: o)
            let id = o.id
            let plate = parent.plate
            // sync() runs inside a SwiftUI update; publish the counter one tick later.
            DispatchQueue.main.async { plate.building += 1 }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let (g, src) = Self.build(j)
                DispatchQueue.main.async {
                    plate.building = max(0, plate.building - 1)
                    guard let self, self.generation[id] == gen, let node = self.nodes[id] else { return }
                    node.geometry = g
                    Self.tint(node, selected: plate.selectedID == id)
                    self.applyBands(node)
                    self.leafSources[id] = src
                    // The new geometry has the painting: the overlay can go —
                    // unless a stroke is running on this object right now.
                    if self.painting?.id != id { self.dropOverlay(id) }
                }
            }
        }

        // MARK: picking

        private func object(at point: CGPoint) -> ModelPlacement? {
            guard let view else { return nil }
            let hits = view.hitTest(point, options: [.searchMode: NSNumber(value: SCNHitTestSearchMode.all.rawValue),
                                                     .categoryBitMask: NSNumber(value: 1)])
            for h in hits {
                if let id = h.node.name.flatMap(UUID.init), let o = parent.plate.objects.first(where: { $0.id == id }) { return o }
            }
            return nil
        }

        /// Where a screen point meets the bed plane (Z = 0), in bed coordinates.
        private func bedPoint(at point: CGPoint) -> SIMD2<Float>? {
            guard let view else { return nil }
            let near = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0))
            let far  = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 1))
            // Scene Y is bed Z: intersect with y = 0.
            let dy = far.y - near.y
            guard abs(dy) > 1e-6 else { return nil }
            let t = -near.y / dy
            let x = near.x + (far.x - near.x) * t
            let z = near.z + (far.z - near.z) * t
            return SIMD2(x, -z)                       // scene z = -bed y
        }

        @objc func tapped(_ gr: UITapGestureRecognizer) {
            guard let view else { return }
            // A tap into the scene also puts the number pad away.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            let point = gr.location(in: view)
            let hits = view.hitTest(point, options: [.searchMode: NSNumber(value: SCNHitTestSearchMode.all.rawValue),
                                                     .categoryBitMask: NSNumber(value: 1)])
            if hits.first?.node.name == "tower" {
                parent.plate.towerSelected = true
                return
            }
            guard let hit = hits.first(where: { $0.node.name.flatMap(UUID.init) != nil }),
                  let id = hit.node.name.flatMap(UUID.init),
                  let obj = parent.plate.objects.first(where: { $0.id == id }) else {
                // Tap on empty space: keep the selection, nothing else.
                return
            }
            parent.plate.towerSelected = false
            if let head = parent.paintHead {
                parent.plate.selectedID = obj.id
                let orig = Int(leafSources[obj.id]?[safe: hit.faceIndex] ?? Int32(hit.faceIndex))
                if parent.brushRadius == nil {
                    obj.fill(from: orig, head: head, angle: parent.fillAngle, layer: parent.paintLayer)
                    showOverlay(obj, originals: obj.lastChanged)
                }
            } else if parent.faceMode {
                let sn = hit.localNormal
                var n = SIMD3<Float>(sn.x, -sn.z, sn.y)
                if simd_length(n) < 0.001 {
                    let v = obj.placed.vertices
                    let i = hit.faceIndex * 3
                    guard i + 2 < v.count else { return }
                    n = simd_cross(v[i + 1] - v[i], v[i + 2] - v[i])
                }
                parent.onFaceTap(obj, n)
            } else {
                parent.plate.selectedID = obj.id
            }
        }

        /// Long press on an object: select it and let the screen offer
        /// duplicate / remove. Not while painting — there a press is a dab.
        @objc func held(_ gr: UILongPressGestureRecognizer) {
            guard gr.state == .began, let view, parent.paintHead == nil, !parent.faceMode,
                  dragging == nil, painting == nil,
                  let obj = object(at: gr.location(in: view)) else { return }
            parent.plate.towerSelected = false
            parent.plate.selectedID = obj.id
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            parent.onLongPress(obj)
        }

        @objc func panned(_ gr: UIPanGestureRecognizer) {
            guard let view else { return }
            if draggingTower {
                switch gr.state {
                case .changed:
                    if let p = bedPoint(at: gr.location(in: view)) { parent.plate.moveTower(to: towerDragStart + (p - dragStartPoint)) }
                case .ended, .cancelled, .failed:
                    draggingTower = false
                    view.allowsCameraControl = true
                default: break
                }
                return
            }
            if let obj = painting {
                switch gr.state {
                case .changed:
                    brush(at: gr.location(in: view))
                case .ended, .cancelled, .failed:
                    showOverlay(obj, originals: obj.strokeTouched)
                    painting = nil
                    view.allowsCameraControl = true
                    obj.endStroke()
                default: break
                }
                return
            }
            guard let obj = dragging else { return }
            switch gr.state {
            case .changed:
                guard let p = bedPoint(at: gr.location(in: view)) else { return }
                obj.offset = dragStartOffset + (p - dragStartPoint)
            case .ended, .cancelled, .failed:
                dragging = nil
                view.allowsCameraControl = true
            default: break
            }
        }

        /// One dab of the brush where the finger is; the object's geometry
        /// is refreshed a few times a second while the stroke runs.
        private func brush(at point: CGPoint) {
            guard let view, let obj = painting, let head = parent.paintHead, let radius = parent.brushRadius else { return }
            // Only this object, nearest hit — not every triangle of the plate.
            guard let objNode = nodes[obj.id] else { return }
            let hits = view.hitTest(point, options: [.searchMode: NSNumber(value: SCNHitTestSearchMode.closest.rawValue),
                                                     .rootNode: objNode,
                                                     .categoryBitMask: NSNumber(value: 1)])
            guard let hit = hits.first(where: { $0.node === objNode }) else { return }
            let w = hit.worldCoordinates
            let cam = view.pointOfView?.worldPosition ?? SCNVector3(0, 0, 0)
            let d = SIMD3<Float>(w.x - cam.x, w.y - cam.y, w.z - cam.z)
            let orig = Int(leafSources[obj.id]?[safe: hit.faceIndex] ?? Int32(hit.faceIndex))
            // The node sits lower by the sink; the mesh maths does not.
            obj.dab(atBed: SIMD3(w.x, -w.z, w.y + obj.sink), radius: radius, viewDir: SIMD3(d.x, -d.z, d.y), orig: orig, head: head, layer: parent.paintLayer)
            let now = CACurrentMediaTime()
            if now - lastPaintRefresh > 0.04 {
                showOverlay(obj, originals: obj.strokeTouched)
                lastPaintRefresh = now
            }
        }
    }
}

// MARK: Screen

/// Keeps the plate alive while the slicer screens come and go: leaving the
/// plate view to switch printers used to throw the model, its orientation and
/// its painting away.
final class SlicerSession: ObservableObject {
    static let shared = SlicerSession()
    @Published var plate: PlateModel? = nil
    /// Which printer the plate was built for, to notice a switch.
    var printerID: String = ""
    /// The saved project this plate belongs to, if it was saved or opened.
    @Published var projectID: String? = nil
    @Published var projectName: String = ""

    func start(mesh: TriMesh, printer: PrinterConfig) {
        let p = PlateModel(bed: BedSize.for(printer))
        p.towerEnabled = printer.type == .snapmakerU1
        applyTowerPosition(p, printer: printer)
        p.add(mesh)
        p.resetHistory()
        printerID = printer.id.uuidString
        projectID = nil
        projectName = ""
        plate = p
    }

    /// Opens a saved plate, with everything on it.
    /// The plate view opens right away with a "loading" badge; the models
    /// (and their painting) are read in the background and appear when ready.
    @discardableResult
    func open(_ project: PlateProject, printer: PrinterConfig) -> Bool {
        let bed = BedSize.for(printer)
        let p = PlateModel(bed: bed)
        p.towerEnabled = project.towerEnabled
        if let t = project.towerPos, t.count == 2 { p.towerPos = SIMD2(t[0], t[1]) }
        p.layerBands = project.layerBands ?? []
        p.pauseHeights = project.pauseHeights ?? []
        p.loading = true
        plate = p
        printerID = printer.id.uuidString
        projectID = project.id
        projectName = project.name
        Task.detached(priority: .userInitiated) {
            let parsed = PlateStore.loadMeshes(project)
            await MainActor.run {
                p.adopt(PlateStore.placements(parsed, bed: bed))
                p.loading = false
            }
        }
        return true
    }

    /// Writes the plate away — under its own name, or under a new one.
    @discardableResult
    func save(as name: String, printer: PrinterConfig) -> Bool {
        guard let plate, !plate.objects.isEmpty else { return false }
        guard let p = try? PlateStore.save(plate: plate, printerID: printer.id.uuidString,
                                           name: name, id: projectID) else { return false }
        projectID = p.id
        projectName = p.name
        return true
    }

    /// Reopening with another printer chosen: same objects, new bed.
    func adopt(printer: PrinterConfig) {
        guard let p = plate, printerID != printer.id.uuidString else { return }
        p.setBed(BedSize.for(printer))
        p.towerEnabled = printer.type == .snapmakerU1
        applyTowerPosition(p, printer: printer)
        printerID = printer.id.uuidString
    }

    func clear() { plate = nil; printerID = ""; projectID = nil; projectName = "" }

    private func applyTowerPosition(_ p: PlateModel, printer: PrinterConfig) {
        if let saved = UserDefaults.standard.array(forKey: "wipe_tower_\(printer.name)") as? [Double], saved.count == 2 {
            p.towerPos = SIMD2(Float(saved[0]), Float(saved[1]))
        } else {
            p.towerPos = nil
        }
    }
}

struct ModelOrientView: View {
    let printerType: PrinterConfig.PrinterType
    var accentHex: String = "3B82F6"
    @ObservedObject var plate: PlateModel
    @EnvironmentObject var printerServices: PrinterServicesManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("app_language") private var appLanguage: String = "en"
    @State private var faceMode = false
    @State private var paintMode = false
    @State private var paintHead = 1
    @State private var paintBrush = false
    /// Which painting the brush works on; single-nozzle printers only have fuzzy skin.
    @State private var chosenPaintLayer: PaintLayer = .color
    /// What the brush works on. Without several heads there is no colour
    /// painting at all — only fuzzy skin.
    private var paintLayer: PaintLayer { printerType == .snapmakerU1 ? chosenPaintLayer : .fuzzy }
    /// Fuzzy skin: erase instead of paint.
    @State private var fuzzyErase = false
    /// Long-pressed object: offer duplicate / remove.
    @State private var pressed: ModelPlacement? = nil
    @State private var brushSize: Double = 6
    /// Fill tool: how far a facet may tilt against the tapped one and still be
    /// filled. Small keeps a face and the radius beside it apart.
    @AppStorage("paint_fill_angle") private var fillAngle: Double = 5
    @State private var confirmClear = false
    /// The tool whose panel is open above the icon row.
    enum Tool: Hashable { case undo, head, rotate, face, sink, scale, paint, layers, pause, arrange, reset }
    @State private var activeTool: Tool? = nil
    @State private var showPicker = false
    @State private var loadError: String? = nil
    @State private var showSlice = false
    /// Saving the plate as a project.
    @ObservedObject private var session = SlicerSession.shared
    @State private var showScan = false
    @State private var showLibrary = false
    @State private var askName = false
    @State private var nameText = ""
    @State private var savedFlash = false
    /// The "building view" badge, but only for builds that take a moment —
    /// small models rebuild faster than the badge could be read.
    @State private var showBuilding = false
    /// Size panel fields: mm per bed axis, percent per bed axis (lock open)
    /// or one percent for everything (lock closed). What is typed lives in
    /// `fieldText` and is applied when the field is left.
    enum SizeField: Hashable { case mm(Int), pct(Int), pctAll }
    @FocusState private var sizeFocus: SizeField?
    @State private var fieldText = ""
    /// Closed lock: every axis scales together, as in Orca.
    @AppStorage("scale_uniform") private var uniformScale = true
    /// How far one tap on a rotate arrow turns the object.
    @AppStorage("rotate_step") private var rotateStep: Double = 90
    /// Arrange panel, as in Orca: turn objects to save room, and the gap.
    @AppStorage("arrange_rotate") private var arrangeRotate = true
    @AppStorage("arrange_gap") private var arrangeGap: Double = 6
    var printerConfig: PrinterConfig? = nil

    init(plate: PlateModel, printerType: PrinterConfig.PrinterType, accentHex: String = "3B82F6", printerConfig: PrinterConfig? = nil) {
        self.printerType = printerType
        self.accentHex = accentHex
        self.printerConfig = printerConfig
        self.plate = plate
    }

    private var sel: ModelPlacement? { plate.selected }
    /// The printer's live channel info (U1): colour and material per head.
    private var service: PrinterService? { printerServices.services.first { $0.name == printerConfig?.name } }
    // Both sources survive the printer being offline: the channel info is
    // cached by PrinterService, the spool tile keeps its last content too.
    private func headColor(_ i: Int) -> Color? {
        if let hex = service?.slotColorHexes[safe: i], !hex.isEmpty { return Color(hex: hex) }
        if let slot = service?.filamentSlots[safe: i], slot.detected, slot.colorHex != "888888" { return Color(hex: slot.colorHex) }
        return nil
    }
    private func headLabel(_ i: Int) -> String {
        let m = service?.slotMaterials[safe: i] ?? ""
        if !m.isEmpty { return m }
        if let slot = service?.filamentSlots[safe: i], slot.detected, slot.material != "–" { return slot.material }
        return ""
    }
    private var headUIColors: [UIColor] {
        (0..<4).map { i in headColor(i).map { UIColor($0) } ?? UIColor(Color(hex: accentHex) ?? .blue) }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ModelSceneView(plate: plate, accent: UIColor(Color(hex: accentHex) ?? .blue),
                                   headColors: printerType == .snapmakerU1 ? headUIColors : [], faceMode: faceMode,
                                   paintHead: paintMode ? (paintLayer == .fuzzy ? (fuzzyErase ? 0 : 1) : paintHead) : nil,
                                   brushRadius: paintMode && paintBrush ? Float(brushSize) : nil,
                                   fillAngle: Float(fillAngle), paintLayer: paintMode ? paintLayer : .color,
                                   onLongPress: { o in pressed = o }) { obj, normal in
                        haptic(.light)
                        plate.selectedID = obj.id
                        withAnimation { obj.layOnFace(normal: normal) }
                        faceMode = false
                    }
                    .background(Color.black.opacity(0.85))
                    .confirmationDialog(pressed?.name ?? "", isPresented: Binding(get: { pressed != nil }, set: { if !$0 { pressed = nil } }),
                                        titleVisibility: .visible) {
                        if let o = pressed {
                            Button(lz(en: "Duplicate", de: "Duplizieren", fr: "Dupliquer", es: "Duplicar", pt: "Duplicar", it: "Duplica", zh: "复制")) {
                                haptic(.light); withAnimation { plate.duplicate(o.id) }
                            }
                            Button(lz(en: "Remove", de: "Entfernen", fr: "Supprimer", es: "Quitar", pt: "Remover", it: "Rimuovi", zh: "移除"), role: .destructive) {
                                haptic(.light); plate.remove(o.id)
                            }
                        }
                        Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {}
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        if let s = sel {
                            Text(s.name).font(.caption).bold().lineLimit(1)
                            let size = s.placedSize
                            Text(String(format: "%.1f × %.1f × %.1f mm", size.x, size.y, size.z))
                                .font(.caption).monospacedDigit()
                        }
                        Text("\(plate.objects.count) " + lz(en: "objects", de: "Objekte", fr: "objets", es: "objetos", pt: "objetos", it: "oggetti", zh: "个对象") +
                             " · \(plate.objects.reduce(0) { $0 + $1.mesh.triangleCount }) " +
                             lz(en: "triangles", de: "Dreiecke", fr: "triangles", es: "triángulos", pt: "triângulos", it: "triangoli", zh: "三角形"))
                            .font(.caption2).foregroundStyle(.secondary)
                        if !plate.allFit {
                            Label(lz(en: "Outside the print volume", de: "Außerhalb des Druckraums", fr: "Hors du volume d'impression", es: "Fuera del volumen de impresión", pt: "Fora do volume de impressão", it: "Fuori dal volume di stampa", zh: "超出打印范围"),
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundColor(.orange)
                        }
                        if faceMode {
                            Label(lz(en: "Tap the face that should lie on the bed", de: "Tippe auf die Fläche, die auf dem Bett liegen soll", fr: "Touche la face qui doit reposer sur le plateau", es: "Toca la cara que debe apoyarse en la cama", pt: "Toque na face que deve ficar na mesa", it: "Tocca la faccia che deve poggiare sul piano", zh: "点击要放在热床上的面"),
                                  systemImage: "hand.tap.fill")
                                .font(.caption).foregroundColor(.yellow)
                        }
                        if plate.showsTower {
                            if plate.towerNearEdge {
                                Label(lz(en: "Prime tower too close to the bed edge — drag it inwards", de: "Reinigungsturm zu nah am Druckbettrand — nach innen ziehen", fr: "Tour de purge trop près du bord du plateau — déplace-la vers l'intérieur", es: "Torre de purga demasiado cerca del borde de la cama — muévela hacia dentro", pt: "Torre de purga demasiado perto da borda da mesa — arraste-a para dentro", it: "Torre di spurgo troppo vicina al bordo del piano — spostala verso l'interno", zh: "擦料塔离热床边缘太近——请向内拖动"),
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundColor(.red)
                            } else if plate.towerCollides {
                                Label(lz(en: "Prime tower overlaps an object — drag it away", de: "Reinigungsturm überschneidet ein Objekt — wegziehen", fr: "La tour de purge chevauche un objet — déplace-la", es: "La torre de purga solapa un objeto — muévela", pt: "A torre de purga sobrepõe um objeto — arraste-a", it: "La torre di spurgo si sovrappone a un oggetto — spostala", zh: "擦料塔与对象重叠——请拖开"),
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundColor(.red)
                            } else if plate.towerSelected {
                                HStack(spacing: 8) {
                                    Label(lz(en: "Prime tower: drag to move", de: "Reinigungsturm: ziehen zum Verschieben", fr: "Tour de purge : glisse pour déplacer", es: "Torre de purga: arrastra para mover", pt: "Torre de purga: arraste para mover", it: "Torre di spurgo: trascina per spostare", zh: "擦料塔：拖动以移动"),
                                          systemImage: "square.stack.3d.up.fill")
                                        .font(.caption).foregroundColor(.teal)
                                    if plate.towerPos != nil {
                                        Button(lz(en: "Auto", de: "Automatisch", fr: "Auto", es: "Auto", pt: "Auto", it: "Auto", zh: "自动")) { plate.towerPos = nil }
                                            .font(.caption.weight(.semibold))
                                    }
                                }
                            } else {
                                Label(lz(en: "Grey block = prime tower (tap to move)", de: "Grauer Block = Reinigungsturm (antippen zum Verschieben)", fr: "Bloc gris = tour de purge (touche pour déplacer)", es: "Bloque gris = torre de purga (toca para mover)", pt: "Bloco cinza = torre de purga (toque para mover)", it: "Blocco grigio = torre di spurgo (tocca per spostare)", zh: "灰色方块 = 擦料塔（点击移动）"),
                                      systemImage: "square.stack.3d.up")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(10)

                    if activeTool == .pause {
                        PauseSlider(plate: plate)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                            .padding(.trailing, 10).padding(.top, 70).padding(.bottom, 12)
                    }
                    if activeTool == .layers {
                        // Heights on the right, like the layer slider of the preview.
                        LayerBandSlider(plate: plate, color: { headColor($0 - 1) ?? Color.secondary })
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                            .padding(.trailing, 10).padding(.top, 70).padding(.bottom, 12)
                    }

                    if plate.loading || showBuilding {
                        LoadingBadge(text: plate.loading
                                     ? lz(en: "Loading model…", de: "Modell wird geladen…", fr: "Chargement du modèle…", es: "Cargando modelo…", pt: "Carregando modelo…", it: "Carico il modello…", zh: "正在加载模型…")
                                     : lz(en: "Building view…", de: "Ansicht wird aufgebaut…", fr: "Construction de la vue…", es: "Generando vista…", pt: "Montando a vista…", it: "Costruisco la vista…", zh: "正在生成视图…"))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                controls
            }
            .navigationTitle(lz(en: "Plate", de: "Druckplatte", fr: "Plateau", es: "Placa", pt: "Mesa", it: "Piano", zh: "打印板"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lz(en: "Close", de: "Schließen", fr: "Fermer", es: "Cerrar", pt: "Fechar", it: "Chiudi", zh: "关闭")) { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            if session.projectName.isEmpty {
                                nameText = PlateStore.suggestedName(for: plate); askName = true
                            } else {
                                saveProject(named: session.projectName)
                            }
                        } label: {
                            Label(session.projectName.isEmpty
                                  ? lz(en: "Save", de: "Speichern", fr: "Enregistrer", es: "Guardar", pt: "Guardar", it: "Salva", zh: "保存")
                                  : lz(en: "Save \"\(session.projectName)\"", de: "„\(session.projectName)“ speichern", fr: "Enregistrer « \(session.projectName) »", es: "Guardar «\(session.projectName)»", pt: "Guardar \"\(session.projectName)\"", it: "Salva «\(session.projectName)»", zh: "保存“\(session.projectName)”"),
                                  systemImage: "square.and.arrow.down")
                        }
                        Button {
                            nameText = session.projectName.isEmpty ? PlateStore.suggestedName(for: plate) : session.projectName + " 2"
                            askName = true
                        } label: {
                            Label(lz(en: "Save as…", de: "Speichern unter…", fr: "Enregistrer sous…", es: "Guardar como…", pt: "Guardar como…", it: "Salva con nome…", zh: "另存为…"), systemImage: "square.and.arrow.down.on.square")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(plate.objects.isEmpty)
                    if ScanSupport.available || LibraryConfig.entryVisible {
                        Menu {
                            Button { showPicker = true } label: {
                                Label(lz(en: "Open model (STL)", de: "Modell öffnen (STL)", fr: "Ouvrir un modèle (STL)", es: "Abrir modelo (STL)", pt: "Abrir modelo (STL)", it: "Apri modello (STL)", zh: "打开模型（STL）"), systemImage: "doc")
                            }
                            if LibraryConfig.entryVisible {
                                Button { showLibrary = true } label: {
                                    Label(lz(en: "Find models", de: "Modelle suchen", fr: "Trouver des modèles", es: "Buscar modelos", pt: "Procurar modelos", it: "Cerca modelli", zh: "查找模型"), systemImage: "magnifyingglass")
                                }
                            }
                            if ScanSupport.available {
                                Button { showScan = true } label: {
                                    Label("Scan to Duplicate", systemImage: "camera.viewfinder")
                                }
                            }
                        } label: { Image(systemName: "plus") }
                    } else {
                        Button { showPicker = true } label: { Image(systemName: "plus") }
                    }
                    Button(lz(en: "Next", de: "Weiter", fr: "Suivant", es: "Siguiente", pt: "Avançar", it: "Avanti", zh: "继续")) { showSlice = true }
                        .disabled(plate.objects.isEmpty)
                }
                // The number pad has no return key — give it one.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(lz(en: "Done", de: "Fertig", fr: "OK", es: "Listo", pt: "OK", it: "Fine", zh: "完成")) { sizeFocus = nil }
                        .font(.body.weight(.semibold))
                }
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url):
                    // Big STLs take a while: read off the main thread, spinner meanwhile.
                    plate.loading = true
                    Task.detached(priority: .userInitiated) {
                        let r = Result { try ModelLoader.load(url: url) }
                        await MainActor.run {
                            plate.loading = false
                            switch r {
                            case .success(let m): plate.add(m)
                            case .failure(let e): loadError = e.localizedDescription
                            }
                        }
                    }
                case .failure(let e): loadError = e.localizedDescription
                }
            }
            .alert(lz(en: "Could not open", de: "Konnte nicht geöffnet werden", fr: "Ouverture impossible", es: "No se pudo abrir", pt: "Não foi possível abrir", it: "Impossibile aprire", zh: "无法打开"),
                   isPresented: Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(loadError ?? "") }
            .fullScreenCover(isPresented: $showScan) {
                ScanFlowView { mesh in plate.add(mesh) }
            }
            .fullScreenCover(isPresented: $showLibrary) {
                LibraryView { url in
                    plate.loading = true
                    Task.detached(priority: .userInitiated) {
                        let r = Result { try ModelLoader.load(url: url) }
                        await MainActor.run {
                            plate.loading = false
                            switch r {
                            case .success(let m): plate.add(m)
                            case .failure(let e): loadError = e.localizedDescription
                            }
                        }
                    }
                }
            }
            .plateNameAlert(lz(en: "Save plate", de: "Druckplatte speichern", fr: "Enregistrer le plateau", es: "Guardar la placa", pt: "Guardar a mesa", it: "Salva il piano", zh: "保存打印板"),
                            isPresented: $askName, text: $nameText) { name in
                // "Save as" starts a project of its own.
                if session.projectName != name { session.projectID = nil }
                saveProject(named: name)
            }
            .overlay(alignment: .top) {
                if savedFlash {
                    Text(lz(en: "Saved", de: "Gespeichert", fr: "Enregistré", es: "Guardado", pt: "Guardado", it: "Salvato", zh: "已保存"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .sheet(isPresented: $showSlice) {
                if let cfg = printerConfig {
                    SliceSettingsSheet(plate: plate, printer: cfg)
                }
            }
            // "Done" after a send closes the plate view as well; the tab bar
            // underneath then switches to the printer that got the file.
            .onReceive(NotificationCenter.default.publisher(for: .paxxShowPrinter)) { _ in dismiss() }
            .onChange(of: plate.selectedID) { _, _ in
                // A half-typed size belongs to the previous object: drop it.
                fieldText = ""; sizeFocus = nil
            }
            .task(id: plate.building > 0) {
                if plate.building > 0 {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if !Task.isCancelled { showBuilding = true }
                } else {
                    showBuilding = false
                }
            }
            .onChange(of: plate.towerPos) { _, p in
                guard let name = printerConfig?.name else { return }
                if let p { UserDefaults.standard.set([Double(p.x), Double(p.y)], forKey: "wipe_tower_\(name)") }
                else { UserDefaults.standard.removeObject(forKey: "wipe_tower_\(name)") }
            }
        }
    }

    @ViewBuilder private var controls: some View {
        VStack(spacing: 8) {
            // Object chips: tap to select, the x removes.
            if plate.objects.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(plate.objects) { o in
                            let active = o.id == plate.selectedID
                            HStack(spacing: 4) {
                                Text(o.name).font(.caption).lineLimit(1)
                                Button { haptic(.light); plate.remove(o.id) } label: {
                                    Image(systemName: "xmark.circle.fill").font(.caption)
                                }.buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(active ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.15)))
                            .foregroundColor(active ? .white : .primary)
                            .onTapGesture { plate.selectedID = o.id }
                            .contextMenu {
                                Button { withAnimation { plate.duplicate(o.id) } } label: {
                                    Label(lz(en: "Duplicate", de: "Duplizieren", fr: "Dupliquer", es: "Duplicar", pt: "Duplicar", it: "Duplica", zh: "复制"), systemImage: "plus.square.on.square")
                                }
                                Button(role: .destructive) { plate.remove(o.id) } label: {
                                    Label(lz(en: "Remove", de: "Entfernen", fr: "Supprimer", es: "Quitar", pt: "Remover", it: "Rimuovi", zh: "移除"), systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            if let tool = activeTool {
                panel(for: tool)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.12)))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            toolRow
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .onTapGesture { sizeFocus = nil }
    }

    private var tools: [Tool] {
        printerType == .snapmakerU1 ? [.undo, .head, .rotate, .face, .sink, .scale, .paint, .layers, .pause, .arrange, .reset] : [.undo, .rotate, .face, .sink, .scale, .paint, .pause, .arrange, .reset]
    }

    /// One big icon per tool; a tap opens its panel (or acts at once).
    /// With this many tools a row of equal shares got small on a phone, so
    /// they keep a comfortable size and the row scrolls sideways like a
    /// ribbon; where they all fit (iPad) they share the width as before.
    private var toolRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { toolButtons(width: nil) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { toolButtons(width: 74) }
                    .padding(.horizontal, 2)
            }
            .scrollClipDisabled()
        }
    }

    @ViewBuilder private func toolButtons(width: CGFloat?) -> some View {
        ForEach(tools, id: \.self) { tool in
            let active = activeTool == tool || (tool == .face && faceMode) || (tool == .paint && paintMode)
            Button { haptic(.light); tap(tool) } label: {
                VStack(spacing: 5) {
                    ZStack {
                        if tool == .head, let sel {
                            Circle().fill(headColor(sel.extruder - 1) ?? Color.secondary.opacity(0.35))
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 0.5))
                                .frame(width: 28, height: 28)
                            Text("\(sel.extruder)").font(.system(size: 14, weight: .bold))
                                .foregroundColor((headColor(sel.extruder - 1).map { UIColor($0).isLight } ?? true) ? .black : .white)
                        } else {
                            Image(systemName: icon(for: tool)).font(.system(size: 26, weight: .medium))
                        }
                    }
                    .frame(height: 30)
                    Text(title(for: tool)).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                }
                .frame(minWidth: 74, maxWidth: width ?? .infinity)
                .frame(width: width)
                .frame(height: 66)
                .background(RoundedRectangle(cornerRadius: 16).fill(active ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.15)))
                .foregroundColor(active ? .white : .primary)
            }
            .buttonStyle(.plain)
            .disabled(tool == .undo ? !canUndo : (sel == nil && tool != .arrange))
            .opacity(tool == .undo && !canUndo ? 0.4 : 1)
        }
    }

    /// While painting the band's undo takes back strokes, otherwise plate steps.
    private var canUndo: Bool {
        paintMode ? (sel?.undoCount(paintLayer) ?? 0) > 0 : plate.undoSteps > 0
    }

    private func icon(for tool: Tool) -> String {
        switch tool {
        case .undo: return "arrow.uturn.backward"
        case .head: return "circle.fill"
        case .rotate: return "rotate.3d"
        case .sink: return "arrow.down.to.line"
        case .face: return "square.3.layers.3d.down.left"
        case .scale: return "arrow.up.left.and.arrow.down.right"
        case .paint: return printerType == .snapmakerU1 ? "paintbrush.pointed.fill" : "aqi.medium"
        case .layers: return "slider.vertical.3"
        case .pause: return "pause.circle"
        case .arrange: return "rectangle.3.group"
        case .reset: return "arrow.counterclockwise"
        }
    }

    private func title(for tool: Tool) -> String {
        switch tool {
        case .undo: return lz(en: "Undo", de: "Rückgängig", fr: "Annuler", es: "Deshacer", pt: "Desfazer", it: "Annulla", zh: "撤销")
        case .head: return lz(en: "Head", de: "Kopf", fr: "Tête", es: "Cabezal", pt: "Cabeça", it: "Testa", zh: "喷头")
        case .rotate: return lz(en: "Rotate", de: "Drehen", fr: "Tourner", es: "Girar", pt: "Girar", it: "Ruota", zh: "旋转")
        case .face: return lz(en: "Lay flat", de: "Auflegen", fr: "À plat", es: "Apoyar", pt: "Apoiar", it: "Appoggia", zh: "放平")
        case .sink: return lz(en: "Sink", de: "Absenken", fr: "Enfoncer", es: "Hundir", pt: "Afundar", it: "Abbassa", zh: "下沉")
        case .scale: return lz(en: "Scale", de: "Größe", fr: "Échelle", es: "Escala", pt: "Escala", it: "Scala", zh: "缩放")
        // One head: the tool only paints fuzzy skin, and says so.
        case .paint: return printerType == .snapmakerU1
            ? lz(en: "Paint", de: "Bemalen", fr: "Peindre", es: "Pintar", pt: "Pintar", it: "Colora", zh: "上色")
            : "Fuzzy Skin"
        case .layers: return lz(en: "Layers", de: "Schichten", fr: "Couches", es: "Capas", pt: "Camadas", it: "Strati", zh: "分层")
        case .pause: return lz(en: "Pause", de: "Pause", fr: "Pause", es: "Pausa", pt: "Pausa", it: "Pausa", zh: "暂停")
        case .arrange: return lz(en: "Arrange", de: "Anordnen", fr: "Ranger", es: "Ordenar", pt: "Organizar", it: "Disponi", zh: "排列")
        case .reset: return lz(en: "Reset", de: "Reset", fr: "Réinit.", es: "Restabl.", pt: "Repor", it: "Ripristina", zh: "重置")
        }
    }

    private func tap(_ tool: Tool) {
        sizeFocus = nil
        switch tool {
        case .undo:
            if paintMode { sel?.undoPaint(paintLayer) } else { withAnimation { plate.undo() } }
        case .reset:
            withAnimation { sel?.reset() }
            sel?.clearAllPaint()
        case .face:
            faceMode.toggle()
            if faceMode { paintMode = false; withAnimation { activeTool = nil } }
        default:
            // Another tool ends "lay flat" — only one tool is active at a time.
            faceMode = false
            withAnimation { activeTool = activeTool == tool ? nil : tool }
            paintMode = activeTool == .paint
            if paintMode {
                faceMode = false; paintHead = sel?.extruder ?? 1
            }
        }
    }

    /// Orca's arrange options: may objects be turned to need less room, and
    /// how far apart they stay. Arranging happens on the button.
    @ViewBuilder private var arrangePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $arrangeRotate) {
                Text(lz(en: "Rotate to save space", de: "Zum Platzsparen drehen", fr: "Tourner pour gagner de la place", es: "Girar para ahorrar espacio", pt: "Girar para poupar espaço", it: "Ruota per risparmiare spazio", zh: "旋转以节省空间"))
                    .font(.caption.weight(.semibold))
            }
            HStack(spacing: 10) {
                Text(lz(en: "Min. distance", de: "Mindestabstand", fr: "Distance min.", es: "Distancia mín.", pt: "Distância mín.", it: "Distanza min.", zh: "最小间距"))
                    .font(.caption.weight(.semibold))
                Slider(value: $arrangeGap, in: 0...30, step: 1)
                Text(String(format: "%.0f mm", arrangeGap)).font(.caption.monospacedDigit()).frame(width: 46, alignment: .trailing)
            }
            Button {
                haptic(.light)
                withAnimation { plate.arrange(gap: Float(arrangeGap), minimizeFootprint: arrangeRotate) }
            } label: {
                Label(lz(en: "Arrange", de: "Anordnen", fr: "Ranger", es: "Ordenar", pt: "Organizar", it: "Disponi", zh: "排列"), systemImage: "rectangle.3.group")
                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(plate.objects.isEmpty)
        }
    }

    /// Lowering the object into the bed: what ends up below is cut off when
    /// slicing, which gives it a flat face to stand on.
    @ViewBuilder private var sinkPanel: some View {
        if let o = sel {
            let depth = Binding<Double>(get: { Double(o.sink) },
                                        set: { o.sink = min(max(0, Float($0)), o.maxSink) })
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(lz(en: "Lower into the bed", de: "In die Platte absenken", fr: "Enfoncer dans le plateau", es: "Hundir en la placa", pt: "Afundar na mesa", it: "Abbassa nel piano", zh: "沉入打印板"))
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(String(format: "%.1f mm", o.sink)).font(.caption.monospacedDigit())
                }
                HStack(spacing: 10) {
                    // Plus raises the model, minus takes it deeper — the
                    // symbols follow the height, not the depth value.
                    Button { haptic(.light); depth.wrappedValue -= 0.1 } label: { Image(systemName: "plus.circle.fill").imageScale(.large) }
                        .buttonStyle(.plain).disabled(o.sink <= 0)
                    Slider(value: depth, in: 0...Double(max(o.maxSink, 0.1)), step: 0.1)
                    Button { haptic(.light); depth.wrappedValue += 0.1 } label: { Image(systemName: "minus.circle.fill").imageScale(.large) }
                        .buttonStyle(.plain).disabled(o.sink >= o.maxSink)
                }
                HStack {
                    Text(lz(en: "Contact area", de: "Auflagefläche", fr: "Surface d'appui", es: "Superficie de apoyo", pt: "Área de apoio", it: "Superficie d'appoggio", zh: "接触面积")
                         + ": " + (o.sink > 0.001 ? String(format: "%.0f mm²", o.contactArea()) : "–"))
                    Spacer()
                    Text(lz(en: "Print height", de: "Druckhöhe", fr: "Hauteur", es: "Altura", pt: "Altura", it: "Altezza", zh: "打印高度")
                         + String(format: ": %.1f mm", o.placedSize.z - o.sink))
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    /// Writes the plate away and says so, briefly.
    private func saveProject(named name: String) {
        guard let cfg = printerConfig, session.save(as: name, printer: cfg) else { return }
        haptic(.light)
        withAnimation { savedFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation { savedFlash = false } }
    }

    @ViewBuilder private func panel(for tool: Tool) -> some View {
        switch tool {
        case .head:
            VStack(alignment: .leading, spacing: 6) {
                Text(lz(en: "Head that prints this object", de: "Kopf, der dieses Objekt druckt", fr: "Tête qui imprime cet objet", es: "Cabezal que imprime este objeto", pt: "Cabeça que imprime este objeto", it: "Testa che stampa questo oggetto", zh: "打印此对象的喷头"))
                    .font(.caption2).foregroundStyle(.secondary)
                headRow(selected: sel?.extruder ?? 1) { h in sel?.extruder = h }
            }
        case .sink:
            sinkPanel
        case .arrange:
            arrangePanel
        case .layers:
            layersPanel
        case .pause:
            pausePanel
        case .rotate:
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    axisButtons("X", axis: SIMD3(1, 0, 0), color: .red)
                    axisButtons("Y", axis: SIMD3(0, 1, 0), color: .green)
                    axisButtons("Z", axis: SIMD3(0, 0, 1), color: .blue)
                }
                // Quarter turns are the common case, but not the only one.
                HStack(spacing: 8) {
                    Text(lz(en: "Step", de: "Schritt", fr: "Pas", es: "Paso", pt: "Passo", it: "Passo", zh: "步进"))
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $rotateStep) {
                        ForEach([90.0, 45.0, 15.0, 5.0, 1.0], id: \.self) { Text("\(Int($0))°").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
        case .scale:
            VStack(spacing: 8) {
                // Size in mm as placed on the bed (rotation counts). Lock
                // closed: one axis typed, the whole model follows. Lock open:
                // only that axis changes.
                HStack(spacing: 6) {
                    Button { haptic(.light); sizeFocus = nil; uniformScale.toggle() } label: {
                        Image(systemName: uniformScale ? "lock.fill" : "lock.open")
                            .font(.system(size: 14, weight: .semibold)).frame(width: 22, height: 22)
                    }
                    .buttonStyle(.bordered).controlSize(.small).tint(uniformScale ? .accentColor : .orange)
                    sizeField(.mm(0), label: "X", color: .red)
                    sizeField(.mm(1), label: "Y", color: .green)
                    sizeField(.mm(2), label: "Z", color: .blue)
                    Text("mm").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    if uniformScale {
                        sizeField(.pctAll, label: nil, color: .clear, width: 56)
                        Text("%").foregroundStyle(.secondary)
                        Spacer()
                        ForEach([50, 100, 200], id: \.self) { pct in
                            Button("\(pct) %") { haptic(.light); fieldText = ""; sizeFocus = nil; sel?.scale = SIMD3(repeating: Float(pct) / 100) }
                                .font(.caption.weight(.semibold)).buttonStyle(.bordered).controlSize(.small)
                        }
                    } else {
                        sizeField(.pct(0), label: "X", color: .red)
                        sizeField(.pct(1), label: "Y", color: .green)
                        sizeField(.pct(2), label: "Z", color: .blue)
                        Text("%").foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    if sizeFocus != nil {
                        Button(lz(en: "Done", de: "Fertig", fr: "OK", es: "Listo", pt: "OK", it: "Fine", zh: "完成")) { sizeFocus = nil }
                            .font(.caption.weight(.semibold))
                    }
                }
            }
            .onChange(of: sizeFocus) { old, new in
                if let old { apply(old) }
                if let new { fieldText = fieldValue(new) }
            }
        case .paint:
            VStack(alignment: .leading, spacing: 8) {
                if printerType == .snapmakerU1 {
                    Picker("", selection: $chosenPaintLayer) {
                        Text(lz(en: "Colour", de: "Farbe", fr: "Couleur", es: "Color", pt: "Cor", it: "Colore", zh: "颜色")).tag(PaintLayer.color)
                        Text("Fuzzy Skin").tag(PaintLayer.fuzzy)
                    }
                    .pickerStyle(.segmented)
                }
                if paintLayer == .fuzzy {
                    Picker("", selection: $fuzzyErase) {
                        Label(lz(en: "Paint", de: "Auftragen", fr: "Appliquer", es: "Aplicar", pt: "Aplicar", it: "Applica", zh: "涂抹"), systemImage: "paintbrush.pointed").tag(false)
                        Label(lz(en: "Erase", de: "Entfernen", fr: "Effacer", es: "Borrar", pt: "Apagar", it: "Cancella", zh: "擦除"), systemImage: "eraser").tag(true)
                    }
                    .pickerStyle(.segmented)
                } else {
                    headRow(selected: paintHead) { h in paintHead = h }
                }
                HStack(spacing: 10) {
                    // Undo on the far left, Clear (with a confirmation) on the far
                    // right — they must not sit next to each other.
                    Button { haptic(.light); sel?.undoPaint(paintLayer) } label: {
                        Image(systemName: "arrow.uturn.backward").imageScale(.large)
                            .frame(width: 36, height: 30)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .disabled((sel?.undoCount(paintLayer) ?? 0) == 0)
                    .opacity((sel?.undoCount(paintLayer) ?? 0) == 0 ? 0.35 : 1)
                    .accessibilityLabel(lz(en: "Undo", de: "Rückgängig", fr: "Annuler", es: "Deshacer", pt: "Desfazer", it: "Annulla", zh: "撤销"))
                    Picker("", selection: $paintBrush) {
                        Text(lz(en: "Fill", de: "Füllen", fr: "Remplir", es: "Rellenar", pt: "Preencher", it: "Riempi", zh: "填充")).tag(false)
                        Text(lz(en: "Brush", de: "Pinsel", fr: "Pinceau", es: "Pincel", pt: "Pincel", it: "Pennello", zh: "画笔")).tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 140)
                    if paintBrush {
                        Slider(value: $brushSize, in: 1...25, step: 0.5)
                        Text(String(format: "%.0f", brushSize)).font(.caption).monospacedDigit().frame(width: 22, alignment: .trailing)
                    } else {
                        // Moving it repeats the last fill, so the effect is
                        // visible straight away instead of undo-and-tap-again.
                        Slider(value: $fillAngle, in: 1...60, step: 1) { editing in
                            if !editing { haptic(.light) }
                        }
                        .onChange(of: fillAngle) { _, new in sel?.refill(angle: Float(new)) }
                        Text("\(Int(fillAngle))°").font(.caption).monospacedDigit().frame(width: 28, alignment: .trailing)
                    }
                    Button(role: .destructive) { confirmClear = true } label: {
                        Image(systemName: "trash").imageScale(.medium).frame(width: 36, height: 30)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!(sel?.hasPaint(paintLayer) ?? false))
                    .opacity((sel?.hasPaint(paintLayer) ?? false) ? 1 : 0.35)
                    .accessibilityLabel(lz(en: "Clear painting", de: "Bemalung leeren", fr: "Effacer la peinture", es: "Borrar pintura", pt: "Limpar pintura", it: "Cancella colorazione", zh: "清除上色"))
                    .confirmationDialog(paintLayer == .fuzzy
                                        ? lz(en: "Remove all painted fuzzy skin on this object?", de: "Gesamtes gemaltes Fuzzy Skin dieses Objekts entfernen?", fr: "Supprimer tout le fuzzy skin peint de cet objet ?", es: "¿Quitar todo el fuzzy skin pintado de este objeto?", pt: "Remover todo o fuzzy skin pintado deste objeto?", it: "Rimuovere tutto il fuzzy skin dipinto di questo oggetto?", zh: "移除此对象上所有绘制的绒毛表面？")
                                        : lz(en: "Remove all painting on this object?", de: "Gesamte Bemalung dieses Objekts entfernen?", fr: "Supprimer toute la peinture de cet objet ?", es: "¿Quitar toda la pintura de este objeto?", pt: "Remover toda a pintura deste objeto?", it: "Rimuovere tutta la colorazione di questo oggetto?", zh: "移除此对象的全部上色？"),
                                        isPresented: $confirmClear, titleVisibility: .visible) {
                        Button(lz(en: "Clear painting", de: "Bemalung leeren", fr: "Effacer", es: "Borrar", pt: "Limpar", it: "Cancella", zh: "清除"), role: .destructive) { sel?.clearPaint(paintLayer) }
                        Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {}
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    private static func mm(_ v: Float) -> String { String(format: v >= 100 ? "%.0f" : "%.1f", v) }
    private static func pct(_ v: Float) -> String { String(format: abs(v - v.rounded()) < 0.05 ? "%.0f" : "%.1f", v) }

    /// What a size field shows while nobody types into it.
    private func fieldValue(_ f: SizeField) -> String {
        guard let s = sel else { return "" }
        switch f {
        case .mm(let a): return Self.mm(s.placedSize[a])
        case .pct(let a): return Self.pct(s.placedSize[a] / s.unitSize[a] * 100)
        case .pctAll: return Self.pct((s.scale.x + s.scale.y + s.scale.z) / 3 * 100)
        }
    }

    /// One size field: shows the current value until tapped, then what is
    /// typed; applying happens when the field is left.
    @ViewBuilder private func sizeField(_ f: SizeField, label: String?, color: Color, width: CGFloat = 52) -> some View {
        HStack(spacing: 3) {
            if let label { Text(label).font(.system(size: 11, weight: .bold)).foregroundColor(color) }
            TextField("0", text: Binding(get: { sizeFocus == f ? fieldText : fieldValue(f) }, set: { fieldText = $0 }))
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: width)
                .focused($sizeFocus, equals: f)
                .monospacedDigit()
        }
        .padding(.vertical, 6).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))
    }

    /// Put the typed value of a field onto the selected object.
    private func apply(_ f: SizeField) {
        guard let s = sel, let v = Float(fieldText.replacingOccurrences(of: ",", with: ".")), v > 0 else { return }
        switch f {
        case .mm(let a): s.setPlacedSize(axis: a, mm: v, uniform: uniformScale)
        case .pct(let a): s.setPlacedSize(axis: a, mm: v / 100 * s.unitSize[a], uniform: uniformScale)
        case .pctAll: s.scale = SIMD3(repeating: max(0.001, v / 100))
        }
    }

    /// The four heads with what is loaded in the printer: colour dot and material.
    @ViewBuilder private func headRow(selected: Int, choose: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                let active = selected == i + 1
                Button { haptic(.light); choose(i + 1) } label: {
                    HStack(spacing: 5) {
                        Circle().fill(headColor(i) ?? Color.secondary.opacity(0.3))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 0.5))
                            .frame(width: 12, height: 12)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(i + 1)").font(.system(size: 12, weight: .bold))
                            if !headLabel(i).isEmpty {
                                Text(headLabel(i)).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.7)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 6).padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 10).fill(active ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.15)))
                    .foregroundColor(active ? .white : .primary)
                }.buttonStyle(.plain)
            }
        }
    }

    /// Pauses: one row per height (finer with − / +, remove) and "+ Pause".
    /// The heights can also be dragged on the slider on the right.
    @ViewBuilder private var pausePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(plate.pauseHeights.enumerated()), id: \.offset) { i, z in
                HStack(spacing: 10) {
                    Image(systemName: "pause.circle.fill").foregroundColor(.yellow)
                    Text(lz(en: "Pause at", de: "Pause bei", fr: "Pause à", es: "Pausa a", pt: "Pausa a", it: "Pausa a", zh: "暂停于") + String(format: " %.1f mm", z))
                        .font(.caption.monospacedDigit())
                    Spacer()
                    Button { nudgePause(i, -0.2) } label: { Image(systemName: "minus.circle.fill").imageScale(.large) }.buttonStyle(.plain)
                    Button { nudgePause(i, 0.2) } label: { Image(systemName: "plus.circle.fill").imageScale(.large) }.buttonStyle(.plain)
                    Button(role: .destructive) {
                        haptic(.light)
                        withAnimation { if plate.pauseHeights.indices.contains(i) { plate.pauseHeights.remove(at: i) } }
                    } label: {
                        Image(systemName: "trash").frame(width: 34, height: 28)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                haptic(.light)
                withAnimation { plate.addPause() }
            } label: {
                Label(lz(en: "Add pause", de: "Pause hinzufügen", fr: "Ajouter une pause", es: "Añadir pausa", pt: "Adicionar pausa", it: "Aggiungi pausa", zh: "添加暂停"), systemImage: "plus")
                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(plate.printHeight <= 0.6)
        }
    }

    private func nudgePause(_ i: Int, _ d: Float) {
        guard plate.pauseHeights.indices.contains(i) else { return }
        haptic(.light)
        let z = ((plate.pauseHeights[i] + d) * 10).rounded() / 10
        plate.pauseHeights[i] = min(max(z, 0.2), max(0.2, plate.printHeight - 0.1))
        plate.pauseHeights.sort()
    }

    /// Layer colours: one row per band (head, heights, remove) and "+ colour".
    /// The heights are set with the slider on the right of the plate.
    @ViewBuilder private var layersPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($plate.layerBands) { $b in
                HStack(spacing: 10) {
                    Menu {
                        ForEach(0..<4, id: \.self) { i in
                            Button { b.head = i + 1 } label: {
                                Label("\(i + 1)" + (headLabel(i).isEmpty ? "" : "  " + headLabel(i)),
                                      systemImage: b.head == i + 1 ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(headColor(b.head - 1) ?? Color.secondary)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 0.5))
                                .frame(width: 16, height: 16)
                            Text("\(b.head)").font(.system(size: 13, weight: .bold))
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    Text(String(format: "%.1f – %.1f mm", b.from, min(b.to, plate.printHeight)))
                        .font(.caption.monospacedDigit())
                    Spacer()
                    Button(role: .destructive) {
                        haptic(.light)
                        withAnimation { plate.layerBands.removeAll { $0.id == b.id } }
                    } label: {
                        Image(systemName: "trash").frame(width: 34, height: 28)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                haptic(.light)
                withAnimation { plate.addBand(heads: [1, 2, 3, 4]) }
            } label: {
                Label(lz(en: "Add colour", de: "Farbe hinzufügen", fr: "Ajouter une couleur", es: "Añadir color", pt: "Adicionar cor", it: "Aggiungi colore", zh: "添加颜色"), systemImage: "plus")
                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(plate.layerBands.count >= 4 || plate.printHeight <= 0.4)
        }
    }

    @ViewBuilder private func axisButtons(_ label: String, axis: SIMD3<Float>, color: Color) -> some View {
        HStack(spacing: 0) {
            Button { haptic(.light); withAnimation { sel?.rotate(axis: axis, degrees: -Float(rotateStep)) } } label: {
                Image(systemName: "rotate.left").frame(maxWidth: .infinity).padding(.vertical, 9)
            }.buttonStyle(.plain)
            Text(label).font(.system(size: 13, weight: .bold)).foregroundColor(color).frame(width: 18)
            Button { haptic(.light); withAnimation { sel?.rotate(axis: axis, degrees: Float(rotateStep)) } } label: {
                Image(systemName: "rotate.right").frame(maxWidth: .infinity).padding(.vertical, 9)
            }.buttonStyle(.plain)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.15)))
    }
}

// MARK: Slicer tab

/// Own tab at the bottom: pick the printer (its bed), open a model, orient it.
/// Stage 2 adds the PaxxMaker-Connect connection and the slicing itself here.
struct SlicerView: View {
    @EnvironmentObject var settings: SettingsStore
    @AppStorage("app_language") private var appLanguage: String = "en"
    @AppStorage("slicer_printer_id") private var printerIDString: String = ""
    @State private var showPicker = false
    @State private var loadError: String? = nil
    @State private var bedRefresh = 0
    @State private var loading = false
    /// The plate outlives this screen, so switching printers in between does
    /// not cost the model.
    @ObservedObject private var session = SlicerSession.shared
    @State private var showPlate = false
    @State private var confirmDiscard = false
    /// Saved plates, newest first.
    @State private var projects: [PlateProject] = []
    @State private var editing: PlateProject? = nil
    /// Object scan (Beta): the cover, and a scan waiting for the plate view
    /// to open once the cover is gone.
    @State private var showScan = false
    @State private var showScanHelp = false
    /// Model library: the cover, and the file picked there, opened once the
    /// cover is gone.
    @State private var showLibrary = false
    @State private var libraryPick: URL? = nil
    @State private var scannedMesh: TriMesh? = nil
    /// "" = OrcaSlicer's settings in the app's language, "en" = in English.
    @AppStorage("orca_language") private var orcaLanguage: String = ""


    /// Plates that were put away earlier — each opens on the printer it
    /// belongs to.
    @ViewBuilder private var projectsSection: some View {
        if !projects.isEmpty {
            Section {
                ForEach(projects) { p in
                    Button {
                        // A plate opens on the printer it belongs to.
                        let target = settings.printers.first { $0.id.uuidString == p.printerID } ?? printer
                        guard let target else { return }
                        printerIDString = target.id.uuidString
                        if session.open(p, printer: target) { showPlate = true }
                    } label: {
                        PlateProjectRow(project: p, printerName: settings.printers.first { $0.id.uuidString == p.printerID }?.name)
                    }
                    .foregroundStyle(Color.primary)
                    .contextMenu {
                        Button {
                            editing = p
                        } label: {
                            Label(lz(en: "Rename / printer", de: "Name / Drucker", fr: "Nom / imprimante", es: "Nombre / impresora", pt: "Nome / impressora", it: "Nome / stampante", zh: "名称 / 打印机"), systemImage: "pencil")
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            PlateStore.delete(p.id)
                            if session.projectID == p.id { session.projectID = nil; session.projectName = "" }
                            projects = PlateStore.list()
                        } label: {
                            Label(lz(en: "Delete", de: "Löschen", fr: "Supprimer", es: "Eliminar", pt: "Excluir", it: "Elimina", zh: "删除"), systemImage: "trash")
                        }
                        Button {
                            editing = p
                        } label: {
                            Label(lz(en: "Edit", de: "Bearbeiten", fr: "Modifier", es: "Editar", pt: "Editar", it: "Modifica", zh: "编辑"), systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            } header: {
                Text(lz(en: "Saved plates", de: "Gespeicherte Druckplatten", fr: "Plateaux enregistrés", es: "Placas guardadas", pt: "Mesas guardadas", it: "Piani salvati", zh: "已保存的打印板"))
            } footer: {
                Text(lz(en: "Tap to carry on where you left off. Swipe a plate to rename or delete it.",
                        de: "Antippen und dort weitermachen, wo du aufgehört hast. Wischen zum Umbenennen oder Löschen.",
                        fr: "Touche pour reprendre où tu t'es arrêté. Balaie pour renommer ou supprimer.",
                        es: "Toca para seguir donde lo dejaste. Desliza para renombrar o eliminar.",
                        pt: "Toque para continuar de onde parou. Deslize para renomear ou excluir.",
                        it: "Tocca per riprendere da dove hai lasciato. Scorri per rinominare o eliminare.",
                        zh: "点击即可从上次的进度继续。滑动可重命名或删除。"))
            }
        }
    }

    /// A file from the model library onto the plate — read off the main
    /// thread like any opened STL, then shown.
    private func openLibraryModel(_ url: URL) {
        guard let p = printer else { return }
        loading = true
        Task.detached(priority: .userInitiated) {
            let r = Result { try ModelLoader.load(url: url) }
            await MainActor.run {
                loading = false
                switch r {
                case .success(let m):
                    if let plate = session.plate { session.adopt(printer: p); plate.add(m) } else { session.start(mesh: m, printer: p) }
                    showPlate = true
                case .failure(let e): loadError = e.localizedDescription
                }
            }
        }
    }

    /// What the "carry on" row says on its right: the model, or how many.
    private func plateSummary(_ plate: PlateModel) -> String {
        if plate.objects.count == 1 { return plate.objects[0].name }
        let word = lz(en: "objects", de: "Objekte", fr: "objets", es: "objetos", pt: "objetos", it: "oggetti", zh: "个对象")
        return "\(plate.objects.count) " + word
    }

    private var printer: PrinterConfig? {
        settings.printers.first { $0.id.uuidString == printerIDString } ?? settings.printers.first
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(lz(en: "Printer", de: "Drucker", fr: "Imprimante", es: "Impresora", pt: "Impressora", it: "Stampante", zh: "打印机"),
                           selection: Binding(get: { printer?.id.uuidString ?? "" }, set: { printerIDString = $0 })) {
                        ForEach(settings.printers) { p in
                            Label(p.name, systemImage: p.type.icon).tag(p.id.uuidString)
                        }
                    }
                    if let p = printer, p.type == .snapmakerU1 {
                        let bed = BedSize.for(p)
                        HStack {
                            Text(lz(en: "Printable area", de: "Bedruckbare Fläche", fr: "Zone imprimable", es: "Área imprimible", pt: "Área imprimível", it: "Area stampabile", zh: "可打印区域"))
                            Spacer()
                            Text(String(format: "%.0f × %.0f × %.0f mm", bed.x, bed.y, bed.z)).foregroundStyle(.secondary)
                        }
                    } else if let p = printer {
                        let bed = BedSize.for(p)
                        let _ = bedRefresh
                        NavigationLink {
                            BedSizePicker(printer: p) { size, label in
                                BedSize.save(size, for: p)
                                PrinterVolumes.setModelLabel(label, for: p)
                                bedRefresh += 1
                            }
                        } label: {
                            HStack {
                                Text(lz(en: "Build volume", de: "Druckvolumen", fr: "Volume d'impression", es: "Volumen de impresión", pt: "Volume de impressão", it: "Volume di stampa", zh: "打印空间"))
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(String(format: "%.0f × %.0f × %.0f mm", bed.x, bed.y, bed.z)).foregroundStyle(.secondary).monospacedDigit()
                                    Text(PrinterVolumes.modelLabel(for: p)
                                         ?? (PrinterVolumes.hasStoredBed(for: p)
                                             ? lz(en: "entered manually", de: "manuell eingetragen", fr: "saisi manuellement", es: "introducido a mano", pt: "inserido manualmente", it: "inserito a mano", zh: "手动输入")
                                             : lz(en: "default — tap to choose", de: "Standard — antippen zum Wählen", fr: "par défaut — touche pour choisir", es: "predeterminado — toca para elegir", pt: "padrão — toque para escolher", it: "predefinito — tocca per scegliere", zh: "默认——点击选择")))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .task(id: p.id) {
                            // Nothing chosen yet: ask Klipper what it runs on.
                            guard !PrinterVolumes.hasStoredBed(for: p), PrinterVolumes.modelLabel(for: p) == nil else { return }
                            if let k = await PrinterVolumes.detect(config: p) {
                                BedSize.save(k.bed, for: p)
                                PrinterVolumes.setModelLabel(k.label, for: p)
                                bedRefresh += 1
                            }
                        }
                    }
                } footer: {
                    if let p = printer, p.type != .snapmakerU1 {
                        Text(lz(en: "Please check your build volume.", de: "Bitte überprüfe dein Druckvolumen.", fr: "Vérifie ton volume d'impression.", es: "Comprueba tu volumen de impresión.", pt: "Verifique o seu volume de impressão.", it: "Controlla il tuo volume di stampa.", zh: "请核对你的打印空间。"))
                    }
                }

                Section(footer: Text(lz(
                    en: "Open an STL, orient it here and slice it in the next step.",
                    de: "STL öffnen, hier ausrichten und im nächsten Schritt slicen.",
                    fr: "Ouvre un STL, oriente-le ici et tranche-le à l'étape suivante.",
                    es: "Abre un STL, oriéntalo aquí y lamínalo en el siguiente paso.",
                    pt: "Abra um STL, oriente aqui e fatie no próximo passo.",
                    it: "Apri un STL, orientalo qui e fai lo slicing nel passo successivo.",
                    zh: "打开 STL，在此调整方向，下一步切片。"))) {
                    if let plate = session.plate, !plate.objects.isEmpty {
                        Button {
                            if let p = printer { session.adopt(printer: p) }
                            showPlate = true
                        } label: {
                            HStack {
                                Label(lz(en: "Continue editing", de: "Weiter bearbeiten", fr: "Continuer l'édition", es: "Seguir editando", pt: "Continuar editando", it: "Continua a modificare", zh: "继续编辑"),
                                      systemImage: "square.3.layers.3d.top.filled")
                                Spacer()
                                Text(plateSummary(plate))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .disabled(printer == nil)
                    }
                    // With a plate in hand, further models are added inside the
                    // plate view (the "+" up there) — no second door here.
                    if session.plate?.objects.isEmpty ?? true {
                        Button { showPicker = true } label: {
                            Label(lz(en: "Open model (STL)", de: "Modell öffnen (STL)", fr: "Ouvrir un modèle (STL)", es: "Abrir modelo (STL)", pt: "Abrir modelo (STL)", it: "Apri modello (STL)", zh: "打开模型（STL）"),
                                  systemImage: "cube.transparent")
                        }
                        .disabled(printer == nil)
                        if ScanSupport.available {
                            // Two tap targets in one row: borderless, or the
                            // whole row would start the scan.
                            HStack {
                                Button { showScan = true } label: {
                                    Label("Scan to Duplicate", systemImage: "camera.viewfinder")
                                }
                                .buttonStyle(.borderless)
                                .disabled(printer == nil)
                                Spacer()
                                Button { showScanHelp = true } label: {
                                    Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(lz(en: "About Scan to Duplicate", de: "Über Scan to Duplicate", fr: "À propos de Scan to Duplicate", es: "Acerca de Scan to Duplicate", pt: "Sobre o Scan to Duplicate", it: "Informazioni su Scan to Duplicate", zh: "关于 Scan to Duplicate"))
                                .popover(isPresented: $showScanHelp) {
                                    ScanHelpText()
                                        .presentationCompactAdaptation(.popover)
                                }
                            }
                        }
                        if LibraryConfig.entryVisible {
                            Button { showLibrary = true } label: {
                                Label(lz(en: "Find models", de: "Modelle suchen", fr: "Trouver des modèles", es: "Buscar modelos", pt: "Procurar modelos", it: "Cerca modelli", zh: "查找模型"),
                                      systemImage: "magnifyingglass")
                            }
                            .disabled(printer == nil)
                        }
                    }
                    if session.plate != nil {
                        Button(role: .destructive) { confirmDiscard = true } label: {
                            Label(lz(en: "Clear plate", de: "Druckplatte leeren", fr: "Vider le plateau", es: "Vaciar la placa", pt: "Esvaziar a mesa", it: "Svuota il piano", zh: "清空打印板"),
                                  systemImage: "trash")
                        }
                        .confirmationDialog(lz(en: "Remove the model and everything set on it?", de: "Modell und alles daran Eingestellte entfernen?", fr: "Supprimer le modèle et tous ses réglages ?", es: "¿Quitar el modelo y todo lo ajustado en él?", pt: "Remover o modelo e tudo o que foi ajustado nele?", it: "Rimuovere il modello e tutte le sue impostazioni?", zh: "移除模型及其所有设置？"),
                                            isPresented: $confirmDiscard, titleVisibility: .visible) {
                            Button(lz(en: "Clear plate", de: "Druckplatte leeren", fr: "Vider", es: "Vaciar", pt: "Esvaziar", it: "Svuota", zh: "清空"), role: .destructive) { session.clear() }
                            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {}
                        }
                    }
                }

                projectsSection

                ConnectSection()

                // Only worth asking when the app does not speak English anyway.
                if appLanguage != "en" {
                    Section {
                        Picker(lz(en: "OrcaSlicer language", de: "Sprache für OrcaSlicer", fr: "Langue d'OrcaSlicer", es: "Idioma de OrcaSlicer", pt: "Idioma do OrcaSlicer", it: "Lingua di OrcaSlicer", zh: "OrcaSlicer 语言"),
                               selection: $orcaLanguage) {
                            Text(lz(en: "Like the app", de: "Wie die App", fr: "Comme l'app", es: "Como la app", pt: "Como o app", it: "Come l'app", zh: "与 App 相同")).tag("")
                            Text("English").tag("en")
                        }
                    }
                }
            }
            .navigationTitle(lz(en: "PaxxMaker Slicer", de: "PaxxMaker-Slicer", fr: "PaxxMaker Slicer", es: "PaxxMaker Slicer", pt: "PaxxMaker Slicer", it: "PaxxMaker Slicer", zh: "PaxxMaker 切片"))
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url):
                    // Big STLs take a while: read off the main thread, spinner meanwhile.
                    loading = true
                    Task.detached(priority: .userInitiated) {
                        let r = Result { try ModelLoader.load(url: url) }
                        await MainActor.run {
                            loading = false
                            switch r {
                            case .success(let m):
                                guard let p = printer else { return }
                                if let plate = session.plate {
                                    session.adopt(printer: p)
                                    plate.add(m)
                                } else {
                                    session.start(mesh: m, printer: p)
                                }
                                showPlate = true
                            case .failure(let e): loadError = e.localizedDescription
                            }
                        }
                    }
                case .failure(let e): loadError = e.localizedDescription
                }
            }
            .overlay {
                if loading {
                    LoadingBadge(text: lz(en: "Loading model…", de: "Modell wird geladen…", fr: "Chargement du modèle…", es: "Cargando modelo…", pt: "Carregando modelo…", it: "Carico il modello…", zh: "正在加载模型…"))
                }
            }
            // Closing the plate view leaves the plate itself untouched — the
            // row above brings it back exactly as it was.
            .task { projects = PlateStore.list() }
            .sheet(item: $editing) { p in
                PlateProjectEditor(project: p) { name, printerID in
                    PlateStore.rename(p.id, to: name)
                    PlateStore.setPrinter(p.id, to: printerID)
                    if session.projectID == p.id { session.projectName = name }
                    projects = PlateStore.list()
                }
                .environmentObject(settings)
            }
            .fullScreenCover(isPresented: $showLibrary, onDismiss: {
                guard let url = libraryPick else { return }
                libraryPick = nil
                openLibraryModel(url)
            }) {
                LibraryView { url in libraryPick = url }
            }
            .fullScreenCover(isPresented: $showScan, onDismiss: {
                // Only one cover at a time: the plate opens once the scan is gone.
                guard let m = scannedMesh, let p = printer else { return }
                scannedMesh = nil
                if let plate = session.plate {
                    session.adopt(printer: p)
                    plate.add(m)
                } else {
                    session.start(mesh: m, printer: p)
                }
                showPlate = true
            }) {
                ScanFlowView { mesh in scannedMesh = mesh }
            }
            .fullScreenCover(isPresented: $showPlate, onDismiss: { projects = PlateStore.list() }) {
                if let plate = session.plate, let p = printer {
                    ModelOrientView(plate: plate, printerType: p.type,
                                    accentHex: PrinterServicesManager.resolveThemeHex(p.themeColor) ?? "3B82F6",
                                    printerConfig: p)
                }
            }
            .alert(lz(en: "Could not open", de: "Konnte nicht geöffnet werden", fr: "Ouverture impossible", es: "No se pudo abrir", pt: "Não foi possível abrir", it: "Impossibile aprire", zh: "无法打开"),
                   isPresented: Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(loadError ?? "") }
        }
    }
}

extension UIColor {
    /// Rough perceived brightness, to pick black or white text on a colour.
    var isLight: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.299 * r + 0.587 * g + 0.114 * b > 0.6
    }
}

/// A spinner with a word, centred over whatever is loading.
struct LoadingBadge: View {
    let text: String
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(1.3)
            Text(text).font(.subheadline)
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 8)
    }
}


// MARK: Layer colour slider

/// The plate's height from 0 to the top, with every colour band as a coloured
/// stretch and two handles (bottom and top end). The whole slider is one big
/// grip: a touch takes the nearest handle and drags it. Bands can not overlap,
/// stay at least 0.2 mm thick and snap to 0.1 mm.
struct LayerBandSlider: View {
    @ObservedObject var plate: PlateModel
    var color: (Int) -> Color
    /// The handle being dragged: band and which end.
    @State private var grabbed: (id: UUID, top: Bool)? = nil

    var body: some View {
        let top = max(plate.printHeight, 0.1)
        VStack(spacing: 6) {
            Text(String(format: "%.1f", top)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            GeometryReader { geo in
                let h = geo.size.height
                ZStack(alignment: .top) {
                    Capsule().fill(Color.white.opacity(0.18)).frame(width: 8)
                    ForEach(plate.layerBands) { b in
                        let y1 = y(min(b.to, top), top, h), y0 = y(b.from, top, h)
                        RoundedRectangle(cornerRadius: 3).fill(color(b.head))
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5))
                            .frame(width: 12, height: max(2, y0 - y1))
                            .offset(y: y1)
                        knob(b, top: true, y: y1, maxZ: top)
                        knob(b, top: false, y: y0, maxZ: top)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if grabbed == nil { grabbed = nearest(to: g.startLocation.y, height: h, maxZ: top) }
                        if let k = grabbed { move(k.id, top: k.top, toY: g.location.y, height: h, maxZ: top) }
                    }
                    .onEnded { _ in grabbed = nil })
            }
            Text("0").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(width: 92)
        .frame(maxHeight: 440)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func y(_ z: Float, _ top: Float, _ h: CGFloat) -> CGFloat { h * CGFloat(1 - min(max(z, 0), top) / top) }

    @ViewBuilder private func knob(_ b: LayerBand, top isTop: Bool, y: CGFloat, maxZ: Float) -> some View {
        let active = grabbed?.id == b.id && grabbed?.top == isTop
        HStack(spacing: 4) {
            Text(String(format: "%.1f", isTop ? min(b.to, maxZ) : b.from)).font(.system(size: 9, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .foregroundColor(.white)
            Circle().fill(color(b.head))
                .overlay(Circle().strokeBorder(Color.white, lineWidth: active ? 3 : 2))
                .overlay(Image(systemName: isTop ? "chevron.up" : "chevron.down").font(.system(size: 7, weight: .bold)).foregroundColor(.white).shadow(radius: 1))
                .frame(width: active ? 26 : 22, height: active ? 26 : 22)
                .shadow(radius: 2)
        }
        .offset(x: -14, y: y - (active ? 13 : 11))
        .allowsHitTesting(false)
    }

    /// The handle closest to where the finger went down (within 44 pt). Two
    /// handles on the same spot: above it the upper band's bottom end is
    /// meant, below it the lower band's top end.
    private func nearest(to touch: CGFloat, height h: CGFloat, maxZ: Float) -> (id: UUID, top: Bool)? {
        var best: (id: UUID, top: Bool, d: CGFloat)? = nil
        for b in plate.layerBands {
            for isTop in [true, false] {
                let hy = y(isTop ? min(b.to, maxZ) : b.from, maxZ, h)
                var d = abs(touch - hy)
                // Shared spot: prefer the band on the side of the finger.
                if (touch < hy && isTop) || (touch > hy && !isTop) { d += 3 }
                if d <= 44, best == nil || d < best!.d { best = (b.id, isTop, d) }
            }
        }
        return best.map { ($0.id, $0.top) }
    }

    /// Drags one end, kept between its neighbours and at least 0.2 mm thick.
    private func move(_ id: UUID, top isTop: Bool, toY y: CGFloat, height: CGFloat, maxZ: Float) {
        guard height > 0, let i = plate.layerBands.firstIndex(where: { $0.id == id }) else { return }
        var z = Float(1 - min(max(y / height, 0), 1)) * maxZ
        z = (z * 10).rounded() / 10
        let sorted = plate.layerBands.sorted { $0.from < $1.from }
        let k = sorted.firstIndex { $0.id == id } ?? 0
        let below = k > 0 ? sorted[k - 1].to : 0
        let above = k + 1 < sorted.count ? sorted[k + 1].from : maxZ
        var b = plate.layerBands[i]
        if isTop { b.to = min(max(z, b.from + 0.2), above) } else { b.from = max(min(z, min(b.to, maxZ) - 0.2), below) }
        if b != plate.layerBands[i] { plate.layerBands[i] = b }
    }
}

// MARK: Pause slider

/// The plate's height with a knob per pause. The whole slider is the grip:
/// a touch takes the nearest knob (within 44 pt) and drags it, 0.1 mm steps.
struct PauseSlider: View {
    @ObservedObject var plate: PlateModel
    @State private var grabbed: Int? = nil

    var body: some View {
        let top = max(plate.printHeight, 0.1)
        VStack(spacing: 6) {
            Text(String(format: "%.1f", top)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            GeometryReader { geo in
                let h = geo.size.height
                ZStack(alignment: .top) {
                    Capsule().fill(Color.white.opacity(0.18)).frame(width: 8)
                    ForEach(Array(plate.pauseHeights.enumerated()), id: \.offset) { i, z in
                        let yy = y(z, top, h), active = grabbed == i
                        HStack(spacing: 4) {
                            Text(String(format: "%.1f", z)).font(.system(size: 9, weight: .semibold).monospacedDigit())
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(Capsule().fill(Color.black.opacity(0.55)))
                                .foregroundColor(.white)
                            Circle().fill(Color.yellow)
                                .overlay(Circle().strokeBorder(Color.white, lineWidth: active ? 3 : 2))
                                .overlay(Image(systemName: "pause.fill").font(.system(size: 8, weight: .bold)).foregroundColor(.black))
                                .frame(width: active ? 26 : 22, height: active ? 26 : 22)
                                .shadow(radius: 2)
                        }
                        .offset(x: -14, y: yy - (active ? 13 : 11))
                        .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if grabbed == nil { grabbed = nearest(g.startLocation.y, h, top) }
                        guard let i = grabbed, plate.pauseHeights.indices.contains(i), h > 0 else { return }
                        var z = Float(1 - min(max(g.location.y / h, 0), 1)) * top
                        z = min(max((z * 10).rounded() / 10, 0.2), max(0.2, top - 0.1))
                        if plate.pauseHeights[i] != z { plate.pauseHeights[i] = z }
                    }
                    .onEnded { _ in grabbed = nil; plate.pauseHeights.sort() })
            }
            Text("0").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(width: 92)
        .frame(maxHeight: 440)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func y(_ z: Float, _ top: Float, _ h: CGFloat) -> CGFloat { h * CGFloat(1 - min(max(z, 0), top) / top) }

    private func nearest(_ touch: CGFloat, _ h: CGFloat, _ top: Float) -> Int? {
        var best: (Int, CGFloat)? = nil
        for (i, z) in plate.pauseHeights.enumerated() {
            let d = abs(touch - y(z, top, h))
            if d <= 44, best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }
}
