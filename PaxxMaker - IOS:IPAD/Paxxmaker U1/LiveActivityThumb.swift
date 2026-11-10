import Foundation
import UIKit

/// The current print's thumbnail for the Live Activity. A Live Activity can't
/// load anything from the network, so the app fetches the slicer thumbnail
/// from Moonraker, scales it down and leaves it in the App Group container;
/// the widget reads it from there (PaxxMakerWidgetAttributes.thumbnail).
enum LiveActivityThumb {
    static let group = "group.paxxmaker.u1"
    private static var inFlight = Set<String>()
    private static let lock = NSLock()

    /// One download per file at a time (synchronous, so the lock is fine).
    private static func claim(_ key: String) -> Bool {
        lock.withLock { inFlight.insert(key).inserted }
    }
    private static func release(_ key: String) {
        lock.withLock { _ = inFlight.remove(key) }
    }

    /// Fetches the thumbnail of `filename` unless it is already there.
    /// True when a new image was written (then the activity should redraw).
    @discardableResult
    static func ensure(baseURL: String, apiKey: String, filename: String, printer: String) async -> Bool {
        guard !filename.isEmpty, !baseURL.isEmpty, baseURL != "__demo__",
              let defaults = UserDefaults(suiteName: group),
              let target = PaxxMakerWidgetAttributes.thumbnailURL(printer: printer) else { return false }
        if defaults.string(forKey: "la_thumb_for_\(printer)") == filename,
           FileManager.default.fileExists(atPath: target.path) { return false }
        let key = printer + "|" + filename
        guard claim(key) else { return false }
        defer { release(key) }

        func request(_ s: String) -> URLRequest? {
            guard let url = URL(string: s) else { return nil }
            var r = URLRequest(url: url, timeoutInterval: 8)
            if !apiKey.isEmpty { r.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
            return r
        }
        guard let enc = filename.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let meta = request("\(baseURL)/server/files/metadata?filename=\(enc)"),
              let (data, _) = try? await URLSession.shared.data(for: meta),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let thumbs = result["thumbnails"] as? [[String: Any]],
              let best = thumbs.max(by: { ($0["size"] as? Int ?? 0) < ($1["size"] as? Int ?? 0) }),
              let rel = best["relative_path"] as? String else { return false }
        // The thumbnail lies next to the G-code (relative to its folder).
        let folder = (filename as NSString).deletingLastPathComponent
        let path = folder.isEmpty ? rel : folder + "/" + rel
        guard let encPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let img = request("\(baseURL)/server/files/gcodes/\(encPath)"),
              let (imgData, resp) = try? await URLSession.shared.data(for: img),
              (resp as? HTTPURLResponse)?.statusCode ?? 200 < 300,
              let image = UIImage(data: imgData) else { return false }
        // Small: Live Activities refuse large images.
        let side: CGFloat = 120
        let s = min(side / max(image.size.width, 1), side / max(image.size.height, 1), 1)
        let size = CGSize(width: (image.size.width * s).rounded(), height: (image.size.height * s).rounded())
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let png = small.pngData(), (try? png.write(to: target, options: .atomic)) != nil else { return false }
        defaults.set(filename, forKey: "la_thumb_for_\(printer)")
        return true
    }
}
