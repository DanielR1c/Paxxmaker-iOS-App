import SwiftUI
import SceneKit
import simd

// Preview image for the printer's file list. OrcaSlicer renders its
// thumbnails with OpenGL, which a headless command line has no context for —
// PaxxMaker-Connect therefore never gets one. So the phone draws the plate
// itself and the picture is written into the G-code the way every slicer
// does it (verified against a file the U1 wrote):
//
//   ; THUMBNAIL_BLOCK_START
//   ;
//   ; thumbnail begin 300x300 <number of base64 characters>
//   ; <base64, 78 characters per line>
//   ; thumbnail end
//   ; THUMBNAIL_BLOCK_END

enum PlateThumbnail {

    /// The plate as seen from the front left, on a transparent background.
    /// Rendered off screen so it also works while no view is on screen.
    static func render(plate: PlateModel, headColors: [UIColor], accent: UIColor, size: CGFloat = 300) -> UIImage? {
        guard !plate.objects.isEmpty, let device = MTLCreateSystemDefaultDevice() else { return nil }
        let scene = SCNScene()
        scene.background.contents = UIColor.clear

        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for o in plate.objects {
            let colour = headColors[safe: o.extruder - 1] ?? accent
            let g: SCNGeometry?
            let bands = plate.activeBands
            if (o.selector != nil && o.hasPaint) || !bands.isEmpty {
                // Painted or with layer colours: every piece in the colour of
                // the head that prints it.
                g = paintedGeometry(of: o, selector: o.hasPaint ? o.selector : nil, bands: bands,
                                    base: colour, headColors: headColors, accent: accent)
            } else {
                // What gets printed: a model lowered into the bed without the
                // part below it.
                let shown = o.sink > 0.001 ? o.printedPart().mesh : o.placed
                g = geometry(of: shown, colour: colour)
            }
            guard let g else { continue }
            scene.rootNode.addChildNode(SCNNode(geometry: g))
            var b = o.placedBounds
            b.max.z -= o.sink
            lo = simd_min(lo, b.min); hi = simd_max(hi, b.max)
        }
        guard lo.x <= hi.x else { return nil }

        let centre = (lo + hi) / 2
        let extent = max(simd_length(hi - lo), 1)
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.usesOrthographicProjection = true
        cam.camera?.orthographicScale = Double(extent) * 0.62   // a little air around the model
        cam.camera?.zNear = 1; cam.camera?.zFar = Double(extent) * 8
        // Orca's own angle: from the front left, slightly above. `dir` points
        // from the eye to the model (it had the wrong sign and looked at the
        // plate from behind and below — only the unpainted bottom showed).
        let dir = simd_normalize(SIMD3<Float>(0.6, 1, -0.75))
        let eye = centre - dir * extent * 2.2
        cam.position = toScene(eye)
        cam.look(at: toScene(centre), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(cam)

        for (pos, intensity) in [(SIMD3<Float>(-1, -1.4, 2), 900.0), (SIMD3<Float>(1.4, 0.8, 1), 450.0)] {
            let l = SCNNode()
            l.light = SCNLight(); l.light?.type = .omni; l.light?.intensity = intensity
            l.position = toScene(centre + pos * extent)
            scene.rootNode.addChildNode(l)
        }
        let amb = SCNNode()
        amb.light = SCNLight(); amb.light?.type = .ambient; amb.light?.intensity = 420
        scene.rootNode.addChildNode(amb)

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cam
        return renderer.snapshot(atTime: 0, with: CGSize(width: size, height: size), antialiasingMode: .multisampling4X)
    }

    /// Printer coordinates (Z up) → SceneKit (Y up), as in the plate view.
    private static func toScene(_ v: SIMD3<Float>) -> SCNVector3 { SCNVector3(v.x, v.z, -v.y) }

    private static func geometry(of mesh: TriMesh, colour: UIColor) -> SCNGeometry? {
        guard mesh.triangleCount > 0 else { return nil }
        var pos: [SCNVector3] = []; pos.reserveCapacity(mesh.vertices.count)
        var nor: [SCNVector3] = []; nor.reserveCapacity(mesh.vertices.count)
        for i in 0..<mesh.triangleCount {
            let a = mesh.vertices[i * 3], b = mesh.vertices[i * 3 + 1], c = mesh.vertices[i * 3 + 2]
            var n = simd_cross(b - a, c - a)
            let len = simd_length(n); if len > 0 { n /= len }
            pos.append(toScene(a)); pos.append(toScene(b)); pos.append(toScene(c))
            let sn = toScene(n); nor.append(sn); nor.append(sn); nor.append(sn)
        }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: pos), SCNGeometrySource(normals: nor)],
                            elements: [SCNGeometryElement(indices: (0..<pos.count).map { Int32($0) }, primitiveType: .triangles)])
        g.firstMaterial?.diffuse.contents = colour
        ModelSceneView.Coordinator.gloss(g.firstMaterial)
        g.firstMaterial?.isDoubleSided = true
        return g
    }

    /// A painted object: the painting's pieces, placed like on the plate
    /// (lowered objects without what lies under the bed), one group per head
    /// with that head's colour as its material. (Per-vertex colours came out
    /// black in the off-screen render; materials are what already worked.)
    private static func paintedGeometry(of o: ModelPlacement, selector: PaintSelector?, bands: [LayerBand], base: UIColor,
                                        headColors: [UIColor], accent: UIColor) -> SCNGeometry? {
        var m = o.matrix
        m.columns.3.z -= o.sink
        let c0 = m.columns.0, c1 = m.columns.1, c2 = m.columns.2, c3 = m.columns.3
        @inline(__always) func place(_ v: SIMD3<Float>) -> SIMD3<Float> { let p = c0 * v.x + c1 * v.y + c2 * v.z + c3; return SIMD3(p.x, p.y, p.z) }
        var pos: [SCNVector3] = [], nor: [SCNVector3] = []
        var groups: [UInt8: [Int32]] = [:]            // head (0 = the object's own) → vertex indices
        func piece(_ a0: SIMD3<Float>, _ b0: SIMD3<Float>, _ c0v: SIMD3<Float>, _ painted: UInt8) {
            let a = place(a0), b = place(b0), c = place(c0v)
            if a.z < 0 && b.z < 0 && c.z < 0 { return }
            let st = painted
            var n = simd_cross(b - a, c - a)
            let len = simd_length(n); if len > 0 { n /= len }
            let i = Int32(pos.count)
            pos.append(toScene(a)); pos.append(toScene(b)); pos.append(toScene(c))
            let sn = toScene(n); nor.append(sn); nor.append(sn); nor.append(sn)
            groups[st, default: []].append(contentsOf: [i, i + 1, i + 2])
        }
        if let selector {
            selector.forEachLeaf { a, b, c, st, _ in piece(a, b, c, st) }
        } else {
            let v = o.mesh.vertices
            var k = 0
            while k + 2 < v.count { piece(v[k], v[k + 1], v[k + 2], 0); k += 3 }
        }
        guard !pos.isEmpty else { return nil }
        let states = groups.keys.sorted()
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: pos), SCNGeometrySource(normals: nor)],
                            elements: states.map { SCNGeometryElement(indices: groups[$0]!, primitiveType: .triangles) })
        g.materials = states.map { st in
            let mat = SCNMaterial()
            mat.diffuse.contents = st > 0 ? (headColors[safe: Int(st) - 1] ?? accent) : base
            // Same look as the plate view (OrcaSlicer's lighting).
            ModelSceneView.Coordinator.gloss(mat, bands: st == 0 && !bands.isEmpty)
            mat.isDoubleSided = true
            // Unpainted faces take the layer colours by height, exactly per
            // pixel — the same shader as the plate view (world Y = height).
            if st == 0, !bands.isEmpty {
                var from = [Float](repeating: -1, count: 4), to = [Float](repeating: -1, count: 4)
                for (k, b) in bands.prefix(4).enumerated() { from[k] = b.from; to[k] = b.to }
                mat.setValue(SCNVector4(from[0], from[1], from[2], from[3]), forKey: "bandFrom")
                mat.setValue(SCNVector4(to[0], to[1], to[2], to[3]), forKey: "bandTo")
                for k in 0..<4 {
                    var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, a: CGFloat = 0
                    if let b = bands[safe: k] { (headColors[safe: b.head - 1] ?? accent).getRed(&r, green: &g, blue: &bl, alpha: &a) }
                    mat.setValue(SCNVector4(Float(r), Float(g), Float(bl), 1), forKey: "bandC\(k)")
                }
            }
            return mat
        }
        return g
    }

    /// Writes the picture into the G-code — 48×48 for the file list, 300×300
    /// for the detail view, right after the header block like Orca does.
    static func inject(into gcode: Data, image: UIImage) -> Data {
        var blocks = ""
        for px in [48, 300] {
            guard let png = scaled(image, to: CGFloat(px))?.pngData() else { continue }
            let b64 = png.base64EncodedString()
            var body = ""
            var i = b64.startIndex
            while i < b64.endIndex {
                let j = b64.index(i, offsetBy: 78, limitedBy: b64.endIndex) ?? b64.endIndex
                body += "; " + b64[i..<j] + "\n"
                i = j
            }
            blocks += "; THUMBNAIL_BLOCK_START\n;\n; thumbnail begin \(px)x\(px) \(b64.count)\n"
            blocks += body + "; thumbnail end\n; THUMBNAIL_BLOCK_END\n\n"
        }
        guard !blocks.isEmpty, let data = blocks.data(using: .utf8) else { return gcode }
        var out = gcode
        // After "; HEADER_BLOCK_END" when Orca wrote one, else right at the top
        // — parsers read the thumbnail from the first lines of the file.
        var at = out.startIndex
        if let marker = out.range(of: Data("; HEADER_BLOCK_END".utf8), options: [], in: out.startIndex..<min(out.index(out.startIndex, offsetBy: 65536, limitedBy: out.endIndex) ?? out.endIndex, out.endIndex)),
           let nl = out.range(of: Data("\n".utf8), options: [], in: marker.upperBound..<out.endIndex) {
            at = nl.upperBound
        }
        out.insert(contentsOf: data, at: at)
        return out
    }

    private static func scaled(_ image: UIImage, to side: CGFloat) -> UIImage? {
        let f = UIGraphicsImageRendererFormat.default()
        f.opaque = false; f.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: f).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
    }
}

extension String {
    /// A file name the printer accepts: the model's name without path,
    /// extension or characters that would break the upload.
    var asPrintFileName: String {
        var s = (self as NSString).lastPathComponent
        if let dot = s.lastIndex(of: "."), dot != s.startIndex { s = String(s[s.startIndex..<dot]) }
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        s = s.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        if s.count > 60 { s = String(s.prefix(60)) }
        return s.isEmpty ? "PaxxMaker" : s
    }
}
