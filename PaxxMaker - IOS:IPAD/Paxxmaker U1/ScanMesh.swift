import Foundation
import simd
import RealityKit

// MARK: - From a scan to something a printer can print
//
// Object Capture delivers a textured USDZ in metres, gravity pointing down its
// −Y axis. A printer wants millimetres, Z up, a flat face on the bed and a
// closed surface. Everything between the two happens here, without anyone
// having to touch the mesh:
//
//   1. read the triangles (RealityKit), metres → mm, Y-up → Z-up
//   2. weld the vertices so neighbouring triangles share them
//   3. drop loose fragments (bits of table, specks the reconstruction kept)
//   4. cut the bottom flat a little above the lowest point — the underside of
//      a scan is its noisiest part, and a flat face is what sticks to the bed
//   5. close the cut with a proper cap (rings and islands included) and fill
//      any small holes left elsewhere
//   6. put it on z = 0, centred
//
// No UIKit: this file also compiles on the Mac, which is where it is tested.

nonisolated enum ScanMesh {

    struct Report: Equatable {
        var trianglesIn = 0
        var trianglesOut = 0
        var removedParts = 0
        var cutHeight: Float = 0          // mm taken off the bottom
        var capsAdded = 0                 // outlines closed on the cut plane
        var holesFilled = 0               // other openings closed
        var openEdgesLeft = 0             // 0 = closed surface
        var size = SIMD3<Float>(repeating: 0)
        var volume: Float = 0             // mm³, for a plausibility check
        var watertight: Bool { openEdgesLeft == 0 }
    }

    enum Failure: Error { case unreadable, empty, tooSmall, implausibleSize }

    // MARK: 1 – reading

    /// Triangles of every model in the file, placed by their transforms, in
    /// millimetres with Z up. Read through RealityKit on purpose: it applies
    /// the file's own unit (`metersPerUnit`), where ModelIO hands back raw
    /// numbers — Apple's own USDZ files come in centimetres, and a wrong
    /// scale is the one mistake a copy must not have.
    @MainActor
    static func triangles(fromModelFile url: URL) async throws -> [SIMD3<Float>] {
        let root = try await Entity(contentsOf: url)
        var out: [SIMD3<Float>] = []
        func visit(_ e: Entity) {
            if let model = e.components[ModelComponent.self] {
                let world = e.transformMatrix(relativeTo: nil)
                let contents = model.mesh.contents
                for inst in contents.instances {
                    guard let m = contents.models[inst.model] else { continue }
                    let t = world * inst.transform
                    for part in m.parts {
                        let pos = part.positions.elements
                        guard let idx = part.triangleIndices?.elements else { continue }
                        var k = 0
                        while k + 2 < idx.count {
                            for j in 0..<3 {
                                let i = Int(idx[k + j])
                                guard i < pos.count else { continue }
                                let p = t * SIMD4<Float>(pos[i], 1)
                                out.append(SIMD3(p.x, p.y, p.z))
                            }
                            k += 3
                        }
                    }
                }
            }
            for c in e.children { visit(c) }
        }
        visit(root)
        guard !out.isEmpty, out.count % 3 == 0 else { throw Failure.empty }
        // RealityKit: metres, Y up, Z towards the viewer. Printer: mm, Z up,
        // Y away from the front. (x, y, z) → (x, −z, y) is a proper rotation,
        // so every triangle keeps its winding.
        return out.map { SIMD3($0.x * 1000, -$0.z * 1000, $0.y * 1000) }
    }

    // MARK: 2–6 – making it printable

    /// `cut` = millimetres to take off the bottom; nil picks it from the size.
    static func prepare(_ raw: [SIMD3<Float>], cut: Float? = nil) throws -> (vertices: [SIMD3<Float>], report: Report) {
        var report = Report()
        report.trianglesIn = raw.count / 3
        var mesh = Indexed(raw)
        guard !mesh.tris.isEmpty else { throw Failure.empty }

        report.removedParts = mesh.keepMainParts()
        // Close small openings first: one that reaches the bottom would
        // otherwise merge with the cut outline into a single crooked patch.
        report.holesFilled = mesh.fillSmallHoles(maxEdges: 400)
        // The cap faces outwards (down); the rest has to agree with that.
        mesh.orientOutwards()

        guard let lo = mesh.minZ, let hi = mesh.maxZ, hi - lo > 1 else { throw Failure.tooSmall }
        guard hi - lo < 5000 else { throw Failure.implausibleSize }
        let height = hi - lo
        let h = min(max(cut ?? mesh.settledCutHeight(bottom: lo, height: height), 0), height * 0.5)
        report.cutHeight = h
        if h > 0 {
            var zc = lo + h
            // No vertex exactly on the plane — keeps every triangle clearly
            // above, below or crossing it.
            var guardCount = 0
            while mesh.pos.contains(where: { abs($0.z - zc) < 1e-4 }) && guardCount < 20 { zc += 2e-4; guardCount += 1 }
            mesh.cut(at: zc)
            report.capsAdded = mesh.capPlane(at: zc)
        }
        report.holesFilled += mesh.fillSmallHoles(maxEdges: 400)
        mesh.orientOutwards()
        report.openEdgesLeft = mesh.boundaryHalfEdges().count

        var verts = mesh.soup()
        guard !verts.isEmpty else { throw Failure.empty }
        var mn = SIMD3<Float>(repeating: .greatestFiniteMagnitude), mx = -mn
        for v in verts { mn = simd_min(mn, v); mx = simd_max(mx, v) }
        let shift = SIMD3<Float>((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, mn.z)
        for i in verts.indices { verts[i] -= shift }
        report.size = mx - mn
        report.trianglesOut = verts.count / 3
        report.volume = abs(signedVolume(verts))
        return (verts, report)
    }

    /// A model lowered into the bed: everything below Z = 0 goes, the cut
    /// is closed with a face lying on the bed. Returns the new triangles and,
    /// for each, the input triangle it came from (-1 for the cap) and whether
    /// it was cut — enough to carry the painting over.
    static func cutAtBed(_ soup: [SIMD3<Float>]) -> (vertices: [SIMD3<Float>], source: [Int32], clipped: [Bool]) {
        var mesh = Indexed(soup)
        var zc: Float = 0
        var guardCount = 0
        while mesh.pos.contains(where: { abs($0.z - zc) < 1e-4 }) && guardCount < 20 { zc += 2e-4; guardCount += 1 }
        mesh.cut(at: zc)
        _ = mesh.capPlane(at: zc)
        var v = mesh.soup()
        for i in v.indices { v[i].z -= zc }
        return (v, mesh.source, mesh.clipped)
    }

    static func signedVolume(_ v: [SIMD3<Float>]) -> Float {
        var s: Double = 0
        var i = 0
        while i + 2 < v.count {
            s += Double(simd_dot(v[i], simd_cross(v[i + 1], v[i + 2])))
            i += 3
        }
        return Float(s / 6)
    }

    // MARK: - Indexed mesh

    struct Indexed {
        var pos: [SIMD3<Float>] = []
        var tris: [SIMD3<Int32>] = []
        /// For every triangle: the input triangle it came from (-1 = added
        /// here, e.g. a cap), and whether it was cut down to a smaller piece.
        /// Painting hangs on triangle numbers, so a cut has to say which new
        /// triangle stands for which old one.
        var source: [Int32] = []
        var clipped: [Bool] = []

        init(_ raw: [SIMD3<Float>]) {
            // 64-bit keys: a file in the wrong unit can have coordinates far
            // beyond what 32 bits hold at this resolution — that trapped.
            var index: [SIMD3<Int64>: Int32] = [:]
            index.reserveCapacity(raw.count / 2)
            func id(_ p: SIMD3<Float>) -> Int32 {
                let d = SIMD3<Double>(p) * 1e4
                let q = SIMD3<Int64>(Int64(d.x.rounded()), Int64(d.y.rounded()), Int64(d.z.rounded()))
                if let i = index[q] { return i }
                let i = Int32(pos.count); index[q] = i; pos.append(p); return i
            }
            func usable(_ p: SIMD3<Float>) -> Bool { p.x.isFinite && p.y.isFinite && p.z.isFinite && abs(p.x) < 1e9 && abs(p.y) < 1e9 && abs(p.z) < 1e9 }
            var i = 0
            while i + 2 < raw.count {
                defer { i += 3 }
                guard usable(raw[i]), usable(raw[i + 1]), usable(raw[i + 2]) else { continue }
                let t = SIMD3(id(raw[i]), id(raw[i + 1]), id(raw[i + 2]))
                if t.x != t.y && t.y != t.z && t.x != t.z { tris.append(t); source.append(Int32(i / 3)); clipped.append(false) }
            }
        }

        var minZ: Float? { usedVertices().map { pos[Int($0)].z }.min() }
        var maxZ: Float? { usedVertices().map { pos[Int($0)].z }.max() }

        private func usedVertices() -> [Int32] {
            var seen = [Bool](repeating: false, count: pos.count)
            var out: [Int32] = []
            for t in tris { for k in 0..<3 where !seen[Int(t[k])] { seen[Int(t[k])] = true; out.append(t[k]) } }
            return out
        }

        func soup() -> [SIMD3<Float>] {
            var v: [SIMD3<Float>] = []; v.reserveCapacity(tris.count * 3)
            for t in tris { v.append(pos[Int(t.x)]); v.append(pos[Int(t.y)]); v.append(pos[Int(t.z)]) }
            return v
        }

        private func area(_ t: SIMD3<Int32>) -> Float {
            simd_length(simd_cross(pos[Int(t.y)] - pos[Int(t.x)], pos[Int(t.z)] - pos[Int(t.x)])) / 2
        }

        /// Keeps the biggest connected piece and anything at least a tenth of
        /// its size (a scan of two separate parts); the rest is noise.
        mutating func keepMainParts() -> Int {
            var parent = Array(0..<Int32(pos.count))
            func find(_ x: Int32) -> Int32 {
                var r = x; while parent[Int(r)] != r { r = parent[Int(r)] }
                var c = x; while parent[Int(c)] != r { let n = parent[Int(c)]; parent[Int(c)] = r; c = n }
                return r
            }
            for t in tris {
                let a = find(t.x), b = find(t.y), c = find(t.z)
                parent[Int(b)] = a; parent[Int(find(c))] = a
            }
            var areaBy: [Int32: Float] = [:]
            for t in tris { areaBy[find(t.x), default: 0] += area(t) }
            guard let biggest = areaBy.values.max(), areaBy.count > 1 else { return 0 }
            let keep = Set(areaBy.filter { $0.value >= biggest * 0.1 }.keys)
            let kept = tris.indices.filter { keep.contains(find(tris[$0].x)) }
            tris = kept.map { tris[$0] }; source = kept.map { source[$0] }; clipped = kept.map { clipped[$0] }
            return areaBy.count - keep.count
        }

        /// The surface cut at height `zc`: enclosed area (holes subtracted) and
        /// the size of the outline. For an outward-facing surface each crossed
        /// triangle leaves a piece of outline running from where its rim goes
        /// down to where it comes back up.
        func section(at zc: Float) -> (area: Float, width: Float, depth: Float) {
            var s: Double = 0
            var mn = SIMD2<Float>(repeating: .greatestFiniteMagnitude), mx = -mn
            for t in tris {
                let v = [pos[Int(t.x)], pos[Int(t.y)], pos[Int(t.z)]]
                var down: SIMD3<Float>? = nil, up: SIMD3<Float>? = nil
                for k in 0..<3 {
                    let a = v[k], b = v[(k + 1) % 3]
                    let ia = a.z > zc, ib = b.z > zc
                    guard ia != ib else { continue }
                    let p = a + (b - a) * ((zc - a.z) / (b.z - a.z))
                    if ia { down = p } else { up = p }
                    mn = simd_min(mn, SIMD2(p.x, p.y)); mx = simd_max(mx, SIMD2(p.x, p.y))
                }
                if let d = down, let u = up { s += Double(d.x) * Double(u.y) - Double(u.x) * Double(d.y) }
            }
            return mx.x < mn.x ? (0, 0, 0) : (Float(s / 2), mx.x - mn.x, mx.y - mn.y)
        }
        func sectionArea(at zc: Float) -> Float { section(at: zc).area }

        /// How much to take off the bottom. The underside of a scan is its
        /// noisiest part: a blobby fill where the camera never looked, or a
        /// rim of table the masking left on. Below a flat base the section
        /// changes quickly — area and outline both — and it settles once the
        /// plane is clear of it; the cut goes there. A rounded underside never
        /// settles, and then only the minimum goes, so the object keeps its
        /// height. Growing is not enough to count as settled: a leftover rim
        /// is bigger than the object, not smaller.
        func settledCutHeight(bottom lo: Float, height: Float) -> Float {
            let minimum: Float = 0.4, step: Float = 0.2, look: Float = 0.6
            let maximum = min(3.0, height * 0.1)
            guard maximum > minimum else { return min(minimum, height * 0.1) }
            func close(_ a: Float, _ b: Float, _ tol: Float) -> Bool { b > 0 && abs(a - b) <= b * tol }
            var h = minimum
            while h <= maximum + 1e-4 {
                let here = section(at: lo + h), above = section(at: lo + h + look)
                if close(here.area, above.area, 0.08), close(here.width, above.width, 0.04), close(here.depth, above.depth, 0.04) {
                    return h
                }
                h += step
            }
            return minimum
        }

        /// Removes everything below `zc`; triangles crossing it are clipped,
        /// with one shared new vertex per crossed edge.
        mutating func cut(at zc: Float) {
            var edgePoint: [SIMD2<Int32>: Int32] = [:]
            func cross(_ a: Int32, _ b: Int32) -> Int32 {
                let key = SIMD2(min(a, b), max(a, b))
                if let i = edgePoint[key] { return i }
                let pa = pos[Int(key.x)], pb = pos[Int(key.y)]
                let t = (zc - pa.z) / (pb.z - pa.z)
                var p = pa + (pb - pa) * t
                p.z = zc
                let i = Int32(pos.count); pos.append(p); edgePoint[key] = i
                return i
            }
            var out: [SIMD3<Int32>] = []
            var outSource: [Int32] = [], outClipped: [Bool] = []
            out.reserveCapacity(tris.count)
            for (k0, t) in tris.enumerated() {
                let v = [t.x, t.y, t.z]
                let above = v.map { pos[Int($0)].z > zc }
                let n = above.filter { $0 }.count
                if n == 3 { out.append(t); outSource.append(source[k0]); outClipped.append(clipped[k0]); continue }
                if n == 0 { continue }
                // Sutherland–Hodgman against z ≥ zc, order kept.
                var poly: [Int32] = []
                for k in 0..<3 {
                    let a = v[k], b = v[(k + 1) % 3]
                    let ia = above[k], ib = above[(k + 1) % 3]
                    if ia { poly.append(a) }
                    if ia != ib { poly.append(cross(a, b)) }
                }
                for k in 1..<(poly.count - 1) {
                    out.append(SIMD3(poly[0], poly[k], poly[k + 1])); outSource.append(source[k0]); outClipped.append(true)
                }
            }
            tris = out; source = outSource; clipped = outClipped
        }

        /// Directed edges that no other triangle uses the other way round —
        /// the rim of every opening.
        func boundaryHalfEdges() -> [SIMD2<Int32>] {
            var count: [SIMD2<Int32>: Int] = [:]
            count.reserveCapacity(tris.count * 3)
            for t in tris { for k in 0..<3 { count[SIMD2(t[k], t[(k + 1) % 3]), default: 0] += 1 } }
            var out: [SIMD2<Int32>] = []
            for (e, _) in count where count[SIMD2(e.y, e.x)] == nil { out.append(e) }
            return out
        }

        /// Openings as closed vertex loops, in the direction the rim edges run.
        func boundaryLoops() -> [[Int32]] {
            var next: [Int32: [Int32]] = [:]
            for e in boundaryHalfEdges() { next[e.x, default: []].append(e.y) }
            var loops: [[Int32]] = []
            while let start = next.first(where: { !$0.value.isEmpty })?.key {
                var loop: [Int32] = [start]
                var cur = start
                var steps = 0
                while steps < 1_000_000 {
                    guard var list = next[cur], let n = list.popLast() else { break }
                    next[cur] = list
                    if n == start { break }
                    loop.append(n); cur = n; steps += 1
                }
                if loop.count >= 3 { loops.append(loop) }
            }
            return loops
        }

        /// Closes every outline lying on the cut plane. Outlines inside other
        /// outlines are holes (a ring standing on the bed), inside those again
        /// islands — found by containment, so the result does not depend on
        /// how the scan happens to be wound. The cap faces down.
        mutating func capPlane(at zc: Float) -> Int {
            let loops = boundaryLoops().filter { l in l.allSatisfy { abs(pos[Int($0)].z - zc) < 1e-3 } }
            guard !loops.isEmpty else { return 0 }
            // Seen from below (x, −y) the cap is counter-clockwise, which is
            // what the ear clipper produces.
            func p2(_ i: Int32) -> SIMD2<Double> { SIMD2(Double(pos[Int(i)].x), -Double(pos[Int(i)].y)) }
            let polys = loops.map { $0.map(p2) }
            let depth = polys.indices.map { i in
                polys.indices.filter { j in j != i && Polygon2D.contains(polys[j], polys[i][0]) }.count
            }
            var capped = 0
            for o in polys.indices where depth[o] % 2 == 0 {
                // Holes of this outline: one level deeper and inside it.
                let holes = polys.indices.filter { h in depth[h] == depth[o] + 1 && Polygon2D.contains(polys[o], polys[h][0]) }
                var outer = loops[o]
                if Polygon2D.signedArea(outer.map(p2)) < 0 { outer.reverse() }
                var holeLoops = holes.map { loops[$0] }
                for k in holeLoops.indices where Polygon2D.signedArea(holeLoops[k].map(p2)) > 0 { holeLoops[k].reverse() }
                let merged = Polygon2D.bridge(outer: outer, holes: holeLoops, point: p2)
                let tri = Polygon2D.earClip(merged, point: p2)
                tris.append(contentsOf: tri)
                source.append(contentsOf: [Int32](repeating: -1, count: tri.count))
                clipped.append(contentsOf: [Bool](repeating: false, count: tri.count))
                capped += 1
            }
            return capped
        }

        /// Closes the remaining small openings, each in its own best-fit plane.
        mutating func fillSmallHoles(maxEdges: Int) -> Int {
            var filled = 0
            for loop in boundaryLoops() where loop.count <= maxEdges {
                // The patch runs against the rim, so its triangles line up with
                // their neighbours.
                let poly = Array(loop.reversed())
                var nrm = SIMD3<Double>(repeating: 0)
                for k in poly.indices {
                    let a = SIMD3<Double>(pos[Int(poly[k])]), b = SIMD3<Double>(pos[Int(poly[(k + 1) % poly.count])])
                    nrm += SIMD3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
                }
                guard simd_length(nrm) > 1e-12 else { continue }
                nrm = simd_normalize(nrm)
                let ref: SIMD3<Double> = abs(nrm.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
                let u = simd_normalize(simd_cross(ref, nrm)), w = simd_cross(nrm, u)
                func p2(_ i: Int32) -> SIMD2<Double> { let p = SIMD3<Double>(pos[Int(i)]); return SIMD2(simd_dot(p, u), simd_dot(p, w)) }
                let patch = Polygon2D.earClip(poly, point: p2)
                tris.append(contentsOf: patch)
                source.append(contentsOf: [Int32](repeating: -1, count: patch.count))
                clipped.append(contentsOf: [Bool](repeating: false, count: patch.count))
                filled += 1
            }
            return filled
        }

        /// A closed surface wound inside-out has a negative volume; turn it.
        mutating func orientOutwards() {
            if signedVolume(soup()) < 0 { tris = tris.map { SIMD3($0.x, $0.z, $0.y) } }
        }
    }
}

// MARK: - Plane polygons

nonisolated enum Polygon2D {
    static func signedArea(_ p: [SIMD2<Double>]) -> Double {
        var s = 0.0
        for i in p.indices { let a = p[i], b = p[(i + 1) % p.count]; s += a.x * b.y - b.x * a.y }
        return s / 2
    }

    /// Even–odd rule.
    static func contains(_ poly: [SIMD2<Double>], _ q: SIMD2<Double>) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > q.y) != (b.y > q.y), q.x < (b.x - a.x) * (q.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    private static func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }

    private static func segmentsCross(_ p1: SIMD2<Double>, _ p2: SIMD2<Double>, _ q1: SIMD2<Double>, _ q2: SIMD2<Double>) -> Bool {
        let d1 = cross(q1, q2, p1), d2 = cross(q1, q2, p2), d3 = cross(p1, p2, q1), d4 = cross(p1, p2, q2)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    /// Joins holes to the outline with a slit each (outer counter-clockwise,
    /// holes clockwise), rightmost hole first — the classic way to turn a
    /// polygon with holes into one the ear clipper can take.
    static func bridge(outer: [Int32], holes: [[Int32]], point: (Int32) -> SIMD2<Double>) -> [Int32] {
        var poly = outer
        let sorted = holes.sorted { a, b in (a.map { point($0).x }.max() ?? 0) > (b.map { point($0).x }.max() ?? 0) }
        for (hi, hole) in sorted.enumerated() {
            guard let mIndex = hole.indices.max(by: { point(hole[$0]).x < point(hole[$1]).x }) else { continue }
            let m = point(hole[mIndex])
            // Every edge a slit must not cross: the polygon so far and the
            // holes still waiting.
            var edges: [(SIMD2<Double>, SIMD2<Double>)] = []
            for i in poly.indices { edges.append((point(poly[i]), point(poly[(i + 1) % poly.count]))) }
            for h in sorted[hi...] { for i in h.indices { edges.append((point(h[i]), point(h[(i + 1) % h.count]))) } }
            let candidates = poly.indices.sorted { simd_distance_squared(point(poly[$0]), m) < simd_distance_squared(point(poly[$1]), m) }
            var chosen: Int? = nil
            for c in candidates {
                let p = point(poly[c])
                if simd_distance_squared(p, m) < 1e-18 { chosen = c; break }
                if !edges.contains(where: { e in segmentsCross(m, p, e.0, e.1) }) { chosen = c; break }
            }
            guard let at = chosen else { continue }
            var ring: [Int32] = []
            for k in 0...hole.count { ring.append(hole[(mIndex + k) % hole.count]) }   // …back to M
            poly.insert(contentsOf: ring + [poly[at]], at: at + 1)
        }
        return poly
    }

    /// Ear clipping for a counter-clockwise polygon (slits allowed). Always
    /// terminates: when no clean ear is left, the flattest corner is cut.
    static func earClip(_ loop: [Int32], point: (Int32) -> SIMD2<Double>) -> [SIMD3<Int32>] {
        var idx = loop
        var out: [SIMD3<Int32>] = []
        let pts = Dictionary(loop.map { ($0, point($0)) }, uniquingKeysWith: { a, _ in a })
        func pt(_ i: Int32) -> SIMD2<Double> { pts[i]! }
        func inside(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Bool {
            cross(a, b, p) > 1e-12 && cross(b, c, p) > 1e-12 && cross(c, a, p) > 1e-12
        }
        var i = 0
        var misses = 0
        while idx.count > 3 {
            let n = idx.count
            let ia = idx[(i + n - 1) % n], ib = idx[i % n], ic = idx[(i + 1) % n]
            let a = pt(ia), b = pt(ib), c = pt(ic)
            var ear = cross(a, b, c) > 1e-12
            if ear {
                for j in idx where j != ia && j != ib && j != ic {
                    let p = pt(j)
                    if p == a || p == b || p == c { continue }
                    if inside(p, a, b, c) { ear = false; break }
                }
            }
            if ear || misses > n {
                if ear || cross(a, b, c) > -1e-9 { out.append(SIMD3(ia, ib, ic)) }
                idx.remove(at: i % n)
                misses = 0
                if i >= idx.count { i = 0 }
            } else {
                i = (i + 1) % n
                misses += 1
            }
        }
        if idx.count == 3, cross(pt(idx[0]), pt(idx[1]), pt(idx[2])) > 1e-12 { out.append(SIMD3(idx[0], idx[1], idx[2])) }
        return out
    }
}
