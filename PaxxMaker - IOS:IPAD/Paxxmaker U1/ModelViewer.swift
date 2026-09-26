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
    /// Which head prints this object (1-based, U1 only).
    @Published var extruder: Int = 1
    /// The object's own process settings; nil = the general ones.
    @Published var settings: QuickSettings? = nil
    /// Colour painting (heads per face, with Orca-style subdivision); nil
    /// until the first fill or brush stroke.
    private(set) var selector: PaintSelector? = nil
    @Published private(set) var paintedHeads: Set<Int> = []
    private(set) var paintVersion = 0
    /// One entry per fill, brush stroke or clear: the touched subtrees as they were.
    private var undoStack: [[Int32: PaintSelector.Snap]] = []
    @Published private(set) var undoCount = 0
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
        return b.min.x >= -0.01 && b.min.y >= -0.01 && b.max.x <= bed.x + 0.01 && b.max.y <= bed.y + 0.01 && b.max.z <= bed.z + 0.01
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

    func reset() { rotation = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)); scale = SIMD3(repeating: 1); offset = .zero }

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

    private func selectorOrCreate() -> PaintSelector {
        if let s = selector { return s }
        let s = PaintSelector(raw: mesh.vertices)
        selector = s
        return s
    }

    /// Orca's paint_color strings per original triangle, for the slicer.
    var paintStrings: [Int: String] { selector?.serialize() ?? [:] }

    private func state(for head: Int) -> UInt8 { head == extruder ? 0 : UInt8(max(1, min(4, head))) }

    /// Fills the face (or the rounding) the tap landed on with `head`;
    /// `angle` is how far a neighbouring facet may tilt and still belong to it.
    /// Painting with the object's own head is the eraser.
    func fill(from tri: Int, head: Int, angle: Float = 5) {
        let sel = selectorOrCreate()
        sel.beginAction()
        sel.fill(from: tri, state: state(for: head), angle: angle)
        let snaps = sel.endAction()
        push(snaps)
        lastFill = snaps.isEmpty ? nil : (tri, head)
        paintChanged()
    }

    /// The last fill, so moving the angle slider can redo it right away
    /// instead of making people undo and tap again.
    private(set) var lastFill: (tri: Int, head: Int)? = nil

    /// Runs the last fill again with a different angle.
    func refill(angle: Float) {
        guard let f = lastFill, let sel = selector, let snaps = undoStack.popLast() else { return }
        sel.restore(snaps)
        undoCount = undoStack.count
        fill(from: f.tri, head: f.head, angle: angle)
    }

    /// The painting as saved with the project, and the way back in.
    var paintSnapshot: [Int32: PaintSelector.Snap] { selector?.fullSnapshot() ?? [:] }

    func restorePaint(_ snaps: [Int32: PaintSelector.Snap]) {
        guard !snaps.isEmpty else { return }
        let sel = selectorOrCreate()
        sel.restore(snaps)
        undoStack.removeAll(); undoCount = 0
        paintChanged()
    }

    private func push(_ snaps: [Int32: PaintSelector.Snap]) {
        guard !snaps.isEmpty else { return }
        undoStack.append(snaps)
        if undoStack.count > 30 { undoStack.removeFirst() }
        undoCount = undoStack.count
    }

    /// Takes back the last fill, stroke or clear.
    func undoPaint() {
        lastFill = nil
        guard let sel = selector, let snaps = undoStack.popLast() else { return }
        sel.restore(snaps)
        undoCount = undoStack.count
        paintChanged()
    }

    var hasPaint: Bool { !(selector?.isEmpty ?? true) }

    /// One brush dab at a point on the placed object (bed coordinates, mm),
    /// seen along `viewDir`. The stroke publishes nothing until `endStroke`;
    /// the scene refreshes itself meanwhile.
    func dab(atBed p: SIMD3<Float>, radius: Float, viewDir: SIMD3<Float>, orig: Int, head: Int) {
        lastFill = nil
        let sel = selectorOrCreate()
        if !strokeOpen { sel.beginAction(); strokeOpen = true }
        let inv = matrix.inverse
        let c4 = inv * SIMD4<Float>(p, 1)
        let s = max((scale.x + scale.y + scale.z) / 3, 1e-4)
        let r = radius / s
        sel.edgeLimitSqr = pow(max(r / 5, 0.35 / s), 2)
        sel.dab(at: SIMD3(c4.x, c4.y, c4.z), radius: r, dir: simd_normalize(rotation.inverse.act(viewDir)),
                startOrig: orig, state: state(for: head))
    }

    func endStroke() {
        selector?.finishStroke()
        if strokeOpen, let sel = selector { push(sel.endAction()); strokeOpen = false }
        paintChanged()
    }

    private func paintChanged() {
        paintVersion += 1
        paintedHeads = Set(selector?.usedStates ?? [])
    }

    func clearPaint() {
        lastFill = nil
        guard let sel = selector, !sel.isEmpty else { return }
        sel.beginAction()
        sel.clearAll()
        push(sel.endAction())
        paintChanged()
    }

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

    init(bed: BedSize) { self.bed = bed }

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

    func add(_ mesh: TriMesh) {
        let p = ModelPlacement(mesh: mesh, bed: bed)
        // Forward the object's changes so views observing the plate redraw.
        subs[p.id] = p.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        objects.append(p)
        selectedID = p.id
        if objects.count > 1 { arrange() }
    }

    func remove(_ id: UUID) {
        objects.removeAll { $0.id == id }
        subs[id] = nil
        if selectedID == id { selectedID = objects.last?.id }
    }

    /// Row-wise packing with a gap, then the whole group is centred on the
    /// bed — like Orca, which never leaves parts hugging the front-left corner.
    func arrange(gap: Float = 6) {
        struct Slot { let o: ModelPlacement; var x: Float; var y: Float; let w: Float; let d: Float }
        var slots: [Slot] = []
        var x: Float = 0, y: Float = 0, rowH: Float = 0
        for o in objects {
            o.offset = .zero
            let b = o.placedBounds
            let w = b.max.x - b.min.x, d = b.max.y - b.min.y
            if x + w > bed.x && x > 0 { x = 0; y += rowH + gap; rowH = 0 }
            slots.append(Slot(o: o, x: x, y: y, w: w, d: d))
            x += w + gap
            rowH = max(rowH, d)
        }
        guard !slots.isEmpty else { return }
        let totalW = slots.map { $0.x + $0.w }.max() ?? 0
        let totalD = slots.map { $0.y + $0.d }.max() ?? 0
        // Shift so the group's centre sits on the bed centre; offsets are
        // relative to the bed centre, so that is (slot centre − group centre).
        for sl in slots {
            sl.o.offset = SIMD2(sl.x + sl.w / 2 - totalW / 2, sl.y + sl.d / 2 - totalD / 2)
        }
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
    /// Orca's default prime_tower_width by the depth the tower reaches with
    /// several colours (it grows with the purges; Orca's own default spot
    /// leaves 50 mm) — so the block on the plate is what the slice needs.
    let towerSize = SIMD2<Float>(30, 50)

    var usedHeads: Set<Int> {
        var s = Set<Int>()
        for o in objects { s.insert(o.extruder); s.formUnion(o.paintedHeads) }
        return s
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
    private let towerBrim: Float = 3

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
            let amb = SCNNode(); amb.light = SCNLight(); amb.light?.type = .ambient; amb.light?.intensity = 400
            root.addChildNode(amb)

            camera.camera = SCNCamera()
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
            for (id, n) in nodes where !live.contains(id) { n.removeFromParentNode(); nodes[id] = nil; keys[id] = nil; leafSources[id] = nil }
            for o in plate.objects {
                let node = nodes[o.id] ?? { let n = SCNNode(); n.name = o.id.uuidString; objectsNode.addChildNode(n); nodes[o.id] = n; return n }()
                let selected = o.id == plate.selectedID
                // The shift is only the node's position: a drag moves the
                // object at frame rate instead of rebuilding its mesh each time.
                node.position = SCNVector3(o.offset.x, 0, -o.offset.y)
                // Selecting only tints the material — no rebuild for that.
                Self.tint(node, selected: selected)
                let key = "\(o.rotation.vector)|\(o.scale)|\(o.fitsBed)|\(o.extruder)|\(o.paintVersion)|\(parent.headColors.count)"
                guard keys[o.id] != key else { continue }
                keys[o.id] = key
                buildAsync(o)
            }
            syncTower()
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
            let key = "\(r.min)|\(height)|\(collides)|\(plate.towerSelected)"
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
            var leaves: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, UInt8, Int32)]?
            var base: SIMD4<Float>
            var headCols: [SIMD4<Float>]
            var fits: Bool
        }

        private func job(for o: ModelPlacement) -> GeometryJob {
            var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
            (parent.headColors[safe: o.extruder - 1] ?? parent.accent).getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
            let headCols: [SIMD4<Float>] = (0..<4).map { i in
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                (parent.headColors[safe: i] ?? parent.accent).getRed(&r, green: &g, blue: &b, alpha: &a)
                return SIMD4(Float(r), Float(g), Float(b), 1)
            }
            var leaves: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, UInt8, Int32)]? = nil
            if let sel = o.selector {
                var l: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, UInt8, Int32)] = []
                l.reserveCapacity(o.mesh.triangleCount + o.mesh.triangleCount / 4)
                sel.forEachLeaf { a, b, c, st, src in l.append((a, b, c, st, src)) }
                leaves = l
            }
            return GeometryJob(matrix: o.matrix(offset: .zero), raw: o.mesh.vertices, leaves: leaves,
                               base: SIMD4(Float(ar), Float(ag), Float(ab), 1), headCols: headCols,
                               fits: o.fitsBed)
        }

        /// Placed triangles with normals, overhang colouring and paint —
        /// pure computation, safe off the main thread.
        static func build(_ j: GeometryJob) -> (SCNGeometry, [Int32]?) {
            let c0 = j.matrix.columns.0, c1 = j.matrix.columns.1, c2 = j.matrix.columns.2, c3 = j.matrix.columns.3
            @inline(__always) func place(_ v: SIMD3<Float>) -> SIMD3<Float> { let p = c0 * v.x + c1 * v.y + c2 * v.z + c3; return SIMD3(p.x, p.y, p.z) }
            let n = j.leaves.map { $0.count * 3 } ?? j.raw.count
            let overhangLimit: Float = -sin(45 * Float.pi / 180)
            var pos = [SCNVector3](); pos.reserveCapacity(n)
            var nor = [SCNVector3](); nor.reserveCapacity(n)
            var col = [SIMD4<Float>](); col.reserveCapacity(n)
            let red = SIMD4<Float>(0.95, 0.25, 0.2, 1)
            let outside = SIMD4<Float>(0.95, 0.6, 0.1, 1)
            @inline(__always) func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, painted: SIMD4<Float>?) {
                var nn = simd_cross(b - a, c - a)
                let len = simd_length(nn); if len > 0 { nn /= len }
                let overhang = nn.z < overhangLimit && !(a.z < 0.05 && b.z < 0.05 && c.z < 0.05)
                let colour = !j.fits ? outside : (painted ?? (overhang ? red : j.base))
                pos.append(toScene(a)); pos.append(toScene(b)); pos.append(toScene(c))
                let sn = toScene(nn); nor.append(sn); nor.append(sn); nor.append(sn)
                col.append(colour); col.append(colour); col.append(colour)
            }
            var sources: [Int32]? = nil
            if let leaves = j.leaves {
                var src: [Int32] = []; src.reserveCapacity(leaves.count)
                for (a, b, c, st, s) in leaves {
                    add(place(a), place(b), place(c), painted: st > 0 ? j.headCols[Int(st) - 1] : nil)
                    src.append(s)
                }
                sources = src
            } else {
                let raw = j.raw
                for i in 0..<(raw.count / 3) {
                    add(place(raw[i * 3]), place(raw[i * 3 + 1]), place(raw[i * 3 + 2]), painted: nil)
                }
            }
            let count = pos.count
            let colData = col.withUnsafeBufferPointer { Data(buffer: $0) }
            let colSrc = SCNGeometrySource(data: colData, semantic: .color, vectorCount: count, usesFloatComponents: true,
                                           componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
            let idx = (0..<count).map { Int32($0) }
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: pos), SCNGeometrySource(normals: nor), colSrc],
                                elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
            g.firstMaterial?.lightingModel = .blinn
            g.firstMaterial?.isDoubleSided = true
            return (g, sources)
        }

        /// Synchronous build (brush strokes refresh in place).
        private func geometry(for o: ModelPlacement) -> SCNGeometry {
            generation[o.id, default: 0] += 1                    // a slower background build must not overwrite this
            let (g, src) = Self.build(job(for: o))
            leafSources[o.id] = src
            return g
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
                    self.leafSources[id] = src
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
                if parent.brushRadius == nil { obj.fill(from: orig, head: head, angle: parent.fillAngle) }
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
            let hits = view.hitTest(point, options: [.searchMode: NSNumber(value: SCNHitTestSearchMode.all.rawValue),
                                                     .categoryBitMask: NSNumber(value: 1)])
            guard let hit = hits.first(where: { $0.node.name == obj.id.uuidString }) else { return }
            let w = hit.worldCoordinates
            let cam = view.pointOfView?.worldPosition ?? SCNVector3(0, 0, 0)
            let d = SIMD3<Float>(w.x - cam.x, w.y - cam.y, w.z - cam.z)
            let orig = Int(leafSources[obj.id]?[safe: hit.faceIndex] ?? Int32(hit.faceIndex))
            obj.dab(atBed: SIMD3(w.x, -w.z, w.y), radius: radius, viewDir: SIMD3(d.x, -d.z, d.y), orig: orig, head: head)
            let now = CACurrentMediaTime()
            if now - lastPaintRefresh > 0.07, let node = nodes[obj.id] {
                node.geometry = geometry(for: obj)
                Self.tint(node, selected: true)
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
        printerID = printer.id.uuidString
        projectID = nil
        projectName = ""
        plate = p
    }

    /// Opens a saved plate, with everything on it.
    @discardableResult
    func open(_ project: PlateProject, printer: PrinterConfig) -> Bool {
        guard let p = PlateStore.load(project, bed: BedSize.for(printer)) else { return false }
        plate = p
        printerID = printer.id.uuidString
        projectID = project.id
        projectName = project.name
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
    @State private var brushSize: Double = 6
    /// Fill tool: how far a facet may tilt against the tapped one and still be
    /// filled. Small keeps a face and the radius beside it apart.
    @AppStorage("paint_fill_angle") private var fillAngle: Double = 5
    @State private var confirmClear = false
    /// The tool whose panel is open above the icon row.
    enum Tool: Hashable { case head, rotate, face, scale, paint, arrange, reset }
    @State private var activeTool: Tool? = nil
    @State private var showPicker = false
    @State private var loadError: String? = nil
    @State private var showSlice = false
    /// Saving the plate as a project.
    @ObservedObject private var session = SlicerSession.shared
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
                                   paintHead: paintMode ? paintHead : nil, brushRadius: paintMode && paintBrush ? Float(brushSize) : nil,
                                   fillAngle: Float(fillAngle)) { obj, normal in
                        haptic(.light)
                        plate.selectedID = obj.id
                        withAnimation { obj.layOnFace(normal: normal) }
                        faceMode = false
                    }
                    .background(Color.black.opacity(0.85))

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
                    Button { showPicker = true } label: { Image(systemName: "plus") }
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
        printerType == .snapmakerU1 ? [.head, .rotate, .face, .scale, .paint, .arrange, .reset] : [.rotate, .face, .scale, .arrange, .reset]
    }

    /// One big icon per tool; a tap opens its panel (or acts at once).
    private var toolRow: some View {
        HStack(spacing: 6) {
            ForEach(tools, id: \.self) { tool in
                let active = activeTool == tool || (tool == .face && faceMode) || (tool == .paint && paintMode)
                Button { haptic(.light); tap(tool) } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            if tool == .head, let sel {
                                Circle().fill(headColor(sel.extruder - 1) ?? Color.secondary.opacity(0.35))
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 0.5))
                                    .frame(width: 24, height: 24)
                                Text("\(sel.extruder)").font(.system(size: 12, weight: .bold))
                                    .foregroundColor((headColor(sel.extruder - 1).map { UIColor($0).isLight } ?? true) ? .black : .white)
                            } else {
                                Image(systemName: icon(for: tool)).font(.system(size: 22, weight: .medium))
                            }
                        }
                        .frame(height: 26)
                        Text(title(for: tool)).font(.system(size: 9, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity).frame(height: 58)
                    .background(RoundedRectangle(cornerRadius: 14).fill(active ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.15)))
                    .foregroundColor(active ? .white : .primary)
                }
                .buttonStyle(.plain)
                .disabled(sel == nil && tool != .arrange)
            }
        }
    }

    private func icon(for tool: Tool) -> String {
        switch tool {
        case .head: return "circle.fill"
        case .rotate: return "rotate.3d"
        case .face: return "square.3.layers.3d.down.left"
        case .scale: return "arrow.up.left.and.arrow.down.right"
        case .paint: return "paintbrush.pointed.fill"
        case .arrange: return "rectangle.3.group"
        case .reset: return "arrow.counterclockwise"
        }
    }

    private func title(for tool: Tool) -> String {
        switch tool {
        case .head: return lz(en: "Head", de: "Kopf", fr: "Tête", es: "Cabezal", pt: "Cabeça", it: "Testa", zh: "喷头")
        case .rotate: return lz(en: "Rotate", de: "Drehen", fr: "Tourner", es: "Girar", pt: "Girar", it: "Ruota", zh: "旋转")
        case .face: return lz(en: "Lay flat", de: "Auflegen", fr: "À plat", es: "Apoyar", pt: "Apoiar", it: "Appoggia", zh: "放平")
        case .scale: return lz(en: "Scale", de: "Größe", fr: "Échelle", es: "Escala", pt: "Escala", it: "Scala", zh: "缩放")
        case .paint: return lz(en: "Paint", de: "Bemalen", fr: "Peindre", es: "Pintar", pt: "Pintar", it: "Colora", zh: "上色")
        case .arrange: return lz(en: "Arrange", de: "Anordnen", fr: "Ranger", es: "Ordenar", pt: "Organizar", it: "Disponi", zh: "排列")
        case .reset: return lz(en: "Reset", de: "Reset", fr: "Réinit.", es: "Restabl.", pt: "Repor", it: "Ripristina", zh: "重置")
        }
    }

    private func tap(_ tool: Tool) {
        sizeFocus = nil
        switch tool {
        case .arrange:
            withAnimation { plate.arrange() }
        case .reset:
            withAnimation { sel?.reset() }
            sel?.clearPaint()
        case .face:
            faceMode.toggle()
            if faceMode { paintMode = false; withAnimation { activeTool = nil } }
        default:
            withAnimation { activeTool = activeTool == tool ? nil : tool }
            paintMode = activeTool == .paint
            if paintMode { faceMode = false; paintHead = sel?.extruder ?? 1 }
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
                Text(uniformScale
                     ? lz(en: "Lock closed: all axes together. Tap the lock to change axes separately.",
                          de: "Schloss zu: alle Achsen gemeinsam. Tippe das Schloss, um Achsen einzeln zu ändern.",
                          fr: "Cadenas fermé : tous les axes ensemble. Touche le cadenas pour régler chaque axe séparément.",
                          es: "Candado cerrado: todos los ejes juntos. Toca el candado para cambiar cada eje por separado.",
                          pt: "Cadeado fechado: todos os eixos juntos. Toque no cadeado para alterar cada eixo separadamente.",
                          it: "Lucchetto chiuso: tutti gli assi insieme. Tocca il lucchetto per modificare ogni asse separatamente.",
                          zh: "已锁定：所有轴一起缩放。点击锁可单独调整各轴。")
                     : lz(en: "Lock open: each axis on its own — the model gets distorted.",
                          de: "Schloss offen: jede Achse für sich – das Modell wird verzerrt.",
                          fr: "Cadenas ouvert : chaque axe séparément – le modèle est déformé.",
                          es: "Candado abierto: cada eje por separado – el modelo se deforma.",
                          pt: "Cadeado aberto: cada eixo separadamente – o modelo é distorcido.",
                          it: "Lucchetto aperto: ogni asse per sé – il modello viene deformato.",
                          zh: "已解锁：各轴单独缩放，模型会变形。"))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .onChange(of: sizeFocus) { old, new in
                if let old { apply(old) }
                if let new { fieldText = fieldValue(new) }
            }
        case .paint:
            VStack(alignment: .leading, spacing: 8) {
                headRow(selected: paintHead) { h in paintHead = h }
                HStack(spacing: 10) {
                    // Undo on the far left, Clear (with a confirmation) on the far
                    // right — they must not sit next to each other.
                    Button { haptic(.light); sel?.undoPaint() } label: {
                        Image(systemName: "arrow.uturn.backward").imageScale(.large)
                            .frame(width: 36, height: 30)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .disabled((sel?.undoCount ?? 0) == 0)
                    .opacity((sel?.undoCount ?? 0) == 0 ? 0.35 : 1)
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
                    .disabled(!(sel?.hasPaint ?? false))
                    .opacity((sel?.hasPaint ?? false) ? 1 : 0.35)
                    .accessibilityLabel(lz(en: "Clear painting", de: "Bemalung leeren", fr: "Effacer la peinture", es: "Borrar pintura", pt: "Limpar pintura", it: "Cancella colorazione", zh: "清除上色"))
                    .confirmationDialog(lz(en: "Remove all painting on this object?", de: "Gesamte Bemalung dieses Objekts entfernen?", fr: "Supprimer toute la peinture de cet objet ?", es: "¿Quitar toda la pintura de este objeto?", pt: "Remover toda a pintura deste objeto?", it: "Rimuovere tutta la colorazione di questo oggetto?", zh: "移除此对象的全部上色？"),
                                        isPresented: $confirmClear, titleVisibility: .visible) {
                        Button(lz(en: "Clear painting", de: "Bemalung leeren", fr: "Effacer", es: "Borrar", pt: "Limpar", it: "Cancella", zh: "清除"), role: .destructive) { sel?.clearPaint() }
                        Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {}
                    }
                }
                Text(paintBrush
                     ? lz(en: "Drag over the object: the brush paints head \(paintHead) and splits faces along its edge, like Orca.",
                          de: "Über das Objekt streichen: der Pinsel malt Kopf \(paintHead) und teilt Flächen an seinem Rand, wie in Orca.",
                          fr: "Glisse sur l'objet : le pinceau peint la tête \(paintHead) et divise les faces à son bord, comme Orca.",
                          es: "Arrastra sobre el objeto: el pincel pinta el cabezal \(paintHead) y divide las caras en su borde, como Orca.",
                          pt: "Arraste sobre o objeto: o pincel pinta a cabeça \(paintHead) e divide as faces na borda, como no Orca.",
                          it: "Trascina sull'oggetto: il pennello colora la testa \(paintHead) e divide le facce al bordo, come Orca.",
                          zh: "在对象上拖动：画笔涂上喷头 \(paintHead)，并像 Orca 一样沿边缘细分面。")
                     : lz(en: "Tap a surface: it gets head \(paintHead). The slider is the edge angle — small keeps a face and the radius next to it apart, large takes more along. The object's own head erases.",
                          de: "Tippe auf eine Fläche: sie bekommt Kopf \(paintHead). Der Regler ist der Kantenwinkel — klein trennt Fläche und Radius, groß nimmt mehr mit. Der eigene Kopf des Objekts radiert.",
                          fr: "Touche une surface : elle passe à la tête \(paintHead). Le curseur est l'angle d'arête — petit sépare une face et le congé voisin, grand en prend davantage. La tête de l'objet efface.",
                          es: "Toca una superficie: recibe el cabezal \(paintHead). El deslizador es el ángulo de arista — pequeño separa la cara del radio contiguo, grande abarca más. El cabezal propio borra.",
                          pt: "Toque numa superfície: recebe a cabeça \(paintHead). O cursor é o ângulo de aresta — pequeno separa a face do raio ao lado, grande abrange mais. A cabeça do objeto apaga.",
                          it: "Tocca una superficie: prende la testa \(paintHead). Il cursore è l'angolo di spigolo — piccolo separa la faccia dal raccordo accanto, grande ne prende di più. La testa dell'oggetto cancella.",
                          zh: "点击一个面：分配给喷头 \(paintHead)。滑块是边缘角度——小则把平面和旁边的圆角分开，大则连带更多。对象自身的喷头用于擦除。"))
                    .font(.caption2).foregroundStyle(.secondary)
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

