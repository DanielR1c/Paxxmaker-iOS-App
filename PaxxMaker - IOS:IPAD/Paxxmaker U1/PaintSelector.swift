import Foundation
import simd

// MARK: - Colour painting with triangle subdivision, Orca's way.
// A port of the essentials of OrcaSlicer's TriangleSelector: every original
// triangle owns a tree of splits (one, two or three sides cut at their
// midpoints — same child order as Orca's perform_split), leaves carry the
// head. The brush (a sphere) splits triangles it only partly covers until
// their edges are shorter than a limit, exactly like Orca's cursor, and the
// tree is written as Orca's paint_color nibble stream, so the 3MF that
// reaches OrcaSlicer is what Orca itself would have saved.

final class PaintSelector {
    struct Tri {
        var v: SIMD3<Int32>
        var state: UInt8 = 0                      // 0 = the object's head, 1…4 = head
        var splits: UInt8 = 0                     // number of split sides
        var special: UInt8 = 0                    // the split side (1) / the kept side (2) / 0
        var children = SIMD4<Int32>(repeating: -1)
        var valid = true
        var isSplit: Bool { splits > 0 }
        var childCount: Int { splits == 0 ? 0 : Int(splits) + 1 }
    }

    private(set) var vertices: [SIMD3<Float>]
    private(set) var tris: [Tri]
    let origCount: Int
    private var neighbors: [SIMD3<Int32>]         // originals: across edge (i, i+1)
    private var faceNormals: [SIMD3<Float>]       // originals, unit, raw space
    private var midpoints: [UInt64: Int32] = [:]  // edge → midpoint vertex, shared by both sides
    private var freeTris: [Int32] = []
    private var touched = Set<Int32>()            // originals changed by the current stroke
    /// Subtrees as they were before the current action, for undo.
    private var actionSnaps: [Int32: Snap] = [:]

    /// One original triangle's subtree: enough to rebuild it, since a split
    /// is fully determined by its side count and special side.
    struct Snap: Codable { var state: UInt8; var splits: UInt8; var special: UInt8; var children: [Snap] }

    /// The whole painting, for saving a plate: every original triangle that
    /// carries a head or was split. Restored with `restore`, the same way undo
    /// puts a stroke back.
    func fullSnapshot() -> [Int32: Snap] {
        var out: [Int32: Snap] = [:]
        for o in 0..<origCount where tris[o].isSplit || tris[o].state != 0 { out[Int32(o)] = snapshot(Int32(o)) }
        return out
    }

    /// Edges longer than this get split when the brush crosses them.
    var edgeLimitSqr: Float = 1

    init(raw: [SIMD3<Float>]) {
        let n = raw.count / 3
        var index: [SIMD3<Float>: Int32] = [:]
        index.reserveCapacity(n * 2)
        var verts: [SIMD3<Float>] = []
        verts.reserveCapacity(n * 2)
        var ids = [Int32](repeating: 0, count: n * 3)
        for i in 0..<n * 3 {
            let q = SIMD3<Float>((raw[i].x * 1e4).rounded() / 1e4, (raw[i].y * 1e4).rounded() / 1e4, (raw[i].z * 1e4).rounded() / 1e4)
            if let id = index[q] { ids[i] = id } else { let id = Int32(verts.count); index[q] = id; verts.append(q); ids[i] = id }
        }
        vertices = verts
        origCount = n
        var t: [Tri] = []; t.reserveCapacity(n * 2)
        var normals: [SIMD3<Float>] = []; normals.reserveCapacity(n)
        for i in 0..<n {
            t.append(Tri(v: SIMD3(ids[i * 3], ids[i * 3 + 1], ids[i * 3 + 2])))
            let c = simd_cross(raw[i * 3 + 1] - raw[i * 3], raw[i * 3 + 2] - raw[i * 3])
            let l = simd_length(c); normals.append(l > 0 ? c / l : SIMD3(0, 0, 1))
        }
        tris = t
        faceNormals = normals
        var nb = [SIMD3<Int32>](repeating: SIMD3(repeating: -1), count: n)
        var open: [UInt64: Int32] = [:]
        open.reserveCapacity(n * 2)
        for i in 0..<n {
            for side in 0..<3 {
                let a = ids[i * 3 + side], b = ids[i * 3 + (side + 1) % 3]
                let key = Self.edgeKey(a, b)
                if let other = open.removeValue(forKey: key) {
                    nb[i][side] = other / 3
                    nb[Int(other / 3)][Int(other % 3)] = Int32(i)
                } else {
                    open[key] = Int32(i * 3 + side)
                }
            }
        }
        neighbors = nb
    }

    private static func edgeKey(_ a: Int32, _ b: Int32) -> UInt64 {
        UInt64(UInt32(min(a, b))) << 32 | UInt64(UInt32(max(a, b)))
    }

    // MARK: queries

    var isEmpty: Bool { !tris.prefix(origCount).contains { $0.isSplit || $0.state != 0 } }

    var usedStates: Set<Int> {
        var s = Set<Int>()
        for t in tris where t.valid && !t.isSplit && t.state != 0 { s.insert(Int(t.state)) }
        return s
    }

    /// Every leaf with its vertices, head and original triangle, in original order.
    func forEachLeaf(_ body: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, UInt8, Int32) -> Void) {
        for o in 0..<origCount { visitLeaves(Int32(o), source: Int32(o), body) }
    }

    private func visitLeaves(_ i: Int32, source: Int32, _ body: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, UInt8, Int32) -> Void) {
        let t = tris[Int(i)]
        if t.isSplit {
            for c in 0..<t.childCount { visitLeaves(t.children[c], source: source, body) }
        } else {
            body(vertices[Int(t.v.x)], vertices[Int(t.v.y)], vertices[Int(t.v.z)], t.state, source)
        }
    }

    // MARK: undo

    func beginAction() { actionSnaps.removeAll(keepingCapacity: true) }
    func endAction() -> [Int32: Snap] { let out = actionSnaps; actionSnaps.removeAll(); return out }
    private func record(_ orig: Int32) { if actionSnaps[orig] == nil { actionSnaps[orig] = snapshot(orig) } }

    func snapshot(_ i: Int32) -> Snap {
        let t = tris[Int(i)]
        return Snap(state: t.state, splits: t.splits, special: t.special,
                    children: (0..<t.childCount).map { snapshot(t.children[$0]) })
    }

    func restore(_ snaps: [Int32: Snap]) {
        for (orig, snap) in snaps { undivide(orig); apply(orig, snap) }
    }

    private func apply(_ i: Int32, _ s: Snap) {
        tris[Int(i)].state = s.state
        guard s.splits > 0, Int(s.splits) + 1 == s.children.count else { return }
        tris[Int(i)].splits = s.splits
        tris[Int(i)].special = s.special
        performSplit(i)
        let t = tris[Int(i)]
        for c in 0..<t.childCount { apply(t.children[c], s.children[c]) }
    }

    /// Everything back to the object's head (undoable via the recorded snaps).
    func clearAll() {
        for o in 0..<origCount where tris[o].isSplit || tris[o].state != 0 {
            record(Int32(o)); undivide(Int32(o)); tris[o].state = 0
        }
    }

    // MARK: painting

    /// Bucket fill on whole original triangles: from the tapped triangle over
    /// every neighbour that is still within `angle` of it.
    ///
    /// Measuring against the *tapped* triangle is what keeps a face and the
    /// rounding beside it apart. Orca (and this app until now) compares each
    /// facet with the one it grew out of, and since a radius is tessellated in
    /// small steps, every single step passes the test — the fill walks around
    /// the rounding and takes the next face with it. Against the tapped facet
    /// the steps add up, so the fill stops where the surface turns away.
    func fill(from orig: Int, state: UInt8, angle: Float) {
        guard orig >= 0, orig < origCount else { return }
        let limit = cos(min(max(angle, 0.5), 179) * .pi / 180)
        let seedNormal = faceNormals[orig]
        var seen = [Bool](repeating: false, count: origCount)
        var stack = [Int32(orig)]; seen[orig] = true
        while let t = stack.popLast() {
            record(t)
            undivide(t)
            tris[Int(t)].state = state
            let nt = faceNormals[Int(t)]
            for side in 0..<3 {
                let o = neighbors[Int(t)][side]
                guard o >= 0, !seen[Int(o)] else { continue }
                let no = faceNormals[Int(o)]
                // …and no single step may be a sharp edge either, so a fold
                // back into the tapped plane stays a separate face.
                guard simd_dot(seedNormal, no) >= limit, simd_dot(nt, no) >= limit else { continue }
                seen[Int(o)] = true
                stack.append(o)
            }
        }
    }

    /// One brush dab: a sphere at `centre` (raw mesh space) with `radius`,
    /// seen along `dir` — Orca's select_patch with a Sphere cursor. Triangles
    /// the sphere only partly covers are split (edges longer than the limit)
    /// and the pieces inside painted.
    func dab(at centre: SIMD3<Float>, radius: Float, dir: SIMD3<Float>, startOrig: Int, state: UInt8) {
        guard startOrig >= 0, startOrig < origCount else { return }
        let r2 = radius * radius
        var visited = [Bool](repeating: false, count: origCount)
        var queue = [Int32(startOrig)]
        var head = 0
        while head < queue.count {
            let f = queue[head]; head += 1
            if visited[Int(f)] { continue }
            visited[Int(f)] = true
            record(f)
            if selectRecursive(f, state: state, centre: centre, r2: r2, radius: radius) {
                touched.insert(f)
                for side in 0..<3 {
                    let n = neighbors[Int(f)][side]
                    if n >= 0, !visited[Int(n)], simd_dot(faceNormals[Int(n)], dir) < 0 { queue.append(n) }
                }
            }
        }
    }

    /// Merge children that ended up alike (Orca's remove_useless_children) —
    /// called when the stroke ends.
    func finishStroke() {
        for f in touched { removeUselessChildren(f) }
        touched.removeAll()
    }

    private func verticesInside(_ t: Tri, _ c: SIMD3<Float>, _ r2: Float) -> Int {
        var n = 0
        for i in 0..<3 where simd_length_squared(vertices[Int(t.v[i])] - c) < r2 { n += 1 }
        return n
    }

    private func pointerInTriangle(_ t: Tri, _ p: SIMD3<Float>) -> Bool {
        let p1 = vertices[Int(t.v.x)], p2 = vertices[Int(t.v.y)], p3 = vertices[Int(t.v.z)]
        let v0 = p2 - p1, v1 = p3 - p1, v2 = p - p1
        let d00 = simd_dot(v0, v0), d01 = simd_dot(v0, v1), d11 = simd_dot(v1, v1), d20 = simd_dot(v2, v0), d21 = simd_dot(v2, v1)
        let denom = d00 * d11 - d01 * d01
        guard abs(denom) > 1e-12 else { return false }
        let v = (d11 * d20 - d01 * d21) / denom, w = (d00 * d21 - d01 * d20) / denom, u = 1 - v - w
        return u >= 0 && u <= 1 && v >= 0 && v <= 1 && w >= 0 && w <= 1
    }

    private func edgeInside(_ t: Tri, _ c: SIMD3<Float>, _ radius: Float) -> Bool {
        for side in 0..<3 {
            let a = vertices[Int(t.v[side])], b = vertices[Int(t.v[(side + 1) % 3])]
            let ab = b - a
            let l2 = simd_length_squared(ab)
            let s = l2 > 0 ? min(max(simd_dot(c - a, ab) / l2, 0), 1) : 0
            if simd_length(a + ab * s - c) < radius { return true }
        }
        return false
    }

    @discardableResult
    private func selectRecursive(_ i: Int32, state: UInt8, centre: SIMD3<Float>, r2: Float, radius: Float) -> Bool {
        guard tris[Int(i)].valid else { return false }
        let t = tris[Int(i)]
        let inside = verticesInside(t, centre, r2)
        if inside == 0, !pointerInTriangle(t, centre), !edgeInside(t, centre, radius) { return false }
        if inside == 3 {
            undivide(i)
            tris[Int(i)].state = state
            return true
        }
        if !t.isSplit, t.state == state { return true }
        splitTriangle(i)
        let s = tris[Int(i)]
        guard s.isSplit else { return true }
        for c in 0..<s.childCount { selectRecursive(s.children[c], state: state, centre: centre, r2: r2, radius: radius) }
        return true
    }

    // MARK: splitting (TriangleSelector::split_triangle / perform_split)

    private func midpoint(_ a: Int32, _ b: Int32) -> Int32 {
        let key = Self.edgeKey(a, b)
        if let m = midpoints[key] { return m }
        let m = Int32(vertices.count)
        vertices.append((vertices[Int(a)] + vertices[Int(b)]) * 0.5)
        midpoints[key] = m
        return m
    }

    private func push(_ a: Int32, _ b: Int32, _ c: Int32, state: UInt8) -> Int32 {
        let t = Tri(v: SIMD3(a, b, c), state: state)
        if let i = freeTris.popLast() { tris[Int(i)] = t; return i }
        tris.append(t)
        return Int32(tris.count - 1)
    }

    private func splitTriangle(_ i: Int32) {
        guard !tris[Int(i)].isSplit else { return }
        let t = tris[Int(i)]
        let p0 = vertices[Int(t.v.x)], p1 = vertices[Int(t.v.y)], p2 = vertices[Int(t.v.z)]
        // Side p is the edge opposite vertex p.
        let sides = [simd_length_squared(p2 - p1), simd_length_squared(p0 - p2), simd_length_squared(p1 - p0)]
        var toSplit: [Int] = []
        var keep = -1
        for p in 0..<3 { if sides[p] > edgeLimitSqr { toSplit.append(p) } else { keep = p } }
        guard !toSplit.isEmpty else { return }
        tris[Int(i)].splits = UInt8(toSplit.count)
        tris[Int(i)].special = UInt8(toSplit.count == 2 ? keep : toSplit[0])
        performSplit(i)
    }

    private func performSplit(_ i: Int32) {
        let t = tris[Int(i)]
        let s = Int(t.special)
        let v0 = t.v[s], v1 = t.v[(s + 1) % 3], v2 = t.v[(s + 2) % 3]
        var ch = SIMD4<Int32>(repeating: -1)
        switch t.splits {
        case 1:
            let m = midpoint(v1, v2)
            ch[0] = push(v0, v1, m, state: t.state)
            ch[1] = push(m, v2, v0, state: t.state)
        case 2:
            let m01 = midpoint(v0, v1), m20 = midpoint(v0, v2)
            ch[0] = push(v0, m01, m20, state: t.state)
            ch[1] = push(m01, v1, m20, state: t.state)
            ch[2] = push(v1, v2, m20, state: t.state)
        default:
            let m01 = midpoint(v0, v1), m12 = midpoint(v1, v2), m20 = midpoint(v2, v0)
            ch[0] = push(v0, m01, m20, state: t.state)
            ch[1] = push(m01, v1, m12, state: t.state)
            ch[2] = push(m12, v2, m20, state: t.state)
            ch[3] = push(m01, m12, m20, state: t.state)
        }
        tris[Int(i)].children = ch
    }

    private func undivide(_ i: Int32) {
        let t = tris[Int(i)]
        guard t.isSplit else { return }
        for c in 0..<t.childCount {
            let child = t.children[c]
            undivide(child)
            tris[Int(child)].valid = false
            freeTris.append(child)
        }
        tris[Int(i)].splits = 0
        tris[Int(i)].special = 0
        tris[Int(i)].children = SIMD4(repeating: -1)
    }

    private func removeUselessChildren(_ i: Int32) {
        let t = tris[Int(i)]
        guard t.isSplit else { return }
        for c in 0..<t.childCount where tris[Int(t.children[c])].isSplit { removeUselessChildren(t.children[c]) }
        let first = tris[Int(t.children[0])].state
        for c in 0..<t.childCount {
            let ch = tris[Int(t.children[c])]
            if ch.isSplit || ch.state != first { return }
        }
        undivide(i)
        tris[Int(i)].state = first
    }

    // MARK: serialisation (TriangleSelector::serialize + get_triangle_as_string)

    /// Orca's paint_color strings, keyed by original triangle; only triangles
    /// that are split or painted.
    func serialize() -> [Int: String] {
        var out: [Int: String] = [:]
        var bits: [Bool] = []
        for o in 0..<origCount {
            let t = tris[o]
            guard t.isSplit || t.state != 0 else { continue }
            bits.removeAll(keepingCapacity: true)
            appendBits(Int32(o), into: &bits)
            var s = ""
            var off = 0
            while off < bits.count {
                var n = 0
                for b in 0..<4 where off + b < bits.count && bits[off + b] { n |= 1 << b }
                off += 4
                s.insert(Character(String(n, radix: 16, uppercase: true)), at: s.startIndex)
            }
            out[o] = s
        }
        return out
    }

    private func appendBits(_ i: Int32, into bits: inout [Bool]) {
        let t = tris[Int(i)]
        let sp = Int(t.splits)
        bits.append(sp & 1 != 0); bits.append(sp & 2 != 0)
        if sp > 0 {
            let s = Int(t.special)
            bits.append(s & 1 != 0); bits.append(s & 2 != 0)
            for c in stride(from: t.childCount - 1, through: 0, by: -1) { appendBits(t.children[c], into: &bits) }
        } else {
            let n = Int(t.state)
            if n >= 3 {
                bits.append(true); bits.append(true)
                for b in 0..<4 { bits.append((n - 3) & (1 << b) != 0) }
            } else {
                bits.append(n & 1 != 0); bits.append(n & 2 != 0)
            }
        }
    }
}
