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
            guard let g = geometry(of: o.placed, colour: colour) else { continue }
            scene.rootNode.addChildNode(SCNNode(geometry: g))
            let b = o.placedBounds
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
        // Orca's own angle: from the front left, slightly above.
        let dir = simd_normalize(SIMD3<Float>(-0.6, -1, 0.75))
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
        g.firstMaterial?.lightingModel = .blinn
        g.firstMaterial?.isDoubleSided = true
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
