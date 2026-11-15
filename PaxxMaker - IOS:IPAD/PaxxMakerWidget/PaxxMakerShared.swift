import ActivityKit
import SwiftUI

func lzShared(en: String, de: String, fr: String, es: String, pt: String = "", it: String = "", zh: String = "") -> String {
    // Follow the language chosen in the app (mirrored into the shared app
    // group); only fall back to the system language if it was never set.
    let code = UserDefaults(suiteName: "group.paxxmaker.u1")?.string(forKey: "app_language")
        ?? Locale.current.language.languageCode?.identifier ?? "en"
    switch code {
    case "de": return de
    case "fr": return fr
    case "es": return es
    case "pt": return pt.isEmpty ? en : pt
    case "it": return it.isEmpty ? en : it
    case "zh": return zh.isEmpty ? en : zh
    default: return en
    }
}

// Shared between main app target AND widget extension target.
// In Xcode → File Inspector → Target Membership: check BOTH targets.

let paxxAppGroupID = "group.paxxmaker.u1"

// MARK: - Spool slot data
struct SpoolSlotData: Codable {
    var colorHex: String
    var material: String
    var detected: Bool

    var color: Color {
        guard colorHex.count == 6, let val = UInt64(colorHex, radix: 16) else { return .gray }
        return Color(red: Double((val >> 16) & 0xFF) / 255,
                     green: Double((val >> 8)  & 0xFF) / 255,
                     blue:  Double( val        & 0xFF) / 255)
    }

    // Gradient end: matches the spoolCircle in the app — same color faded to 55 % opacity.
    var gradientEnd: Color { color.opacity(0.55) }
}

// MARK: - Per-printer serialized entry (written by main app)
struct PrinterWidgetEntry: Codable, Identifiable {
    var id: String        // printer name used as stable key
    var name: String
    var printState: String
    var filename: String
    var progress: Double
    var extruderTemp: Double
    var bedTemp: Double
    var timeElapsed: Int
    var themeHex: String
    var spoolSlots: [SpoolSlotData]?
    var motorTempX: Double?
    var motorTempY: Double?
    var chamberTemp: Double?
    var extruderTemps: [Double]?

    static func loadAll() -> [PrinterWidgetEntry] {
        guard let defaults = UserDefaults(suiteName: paxxAppGroupID),
              let data = defaults.data(forKey: "w_all_printers"),
              let list = try? JSONDecoder().decode([PrinterWidgetEntry].self, from: data)
        else { return [] }
        return list
    }

    var asWidgetData: PrinterWidgetData {
        PrinterWidgetData(name: name, printState: printState, filename: filename,
                          progress: progress, extruderTemp: extruderTemp,
                          bedTemp: bedTemp, timeElapsed: timeElapsed, themeHex: themeHex,
                          spoolSlots: spoolSlots ?? [],
                          motorTempX: motorTempX, motorTempY: motorTempY, chamberTemp: chamberTemp,
                          extruderTemps: extruderTemps ?? [extruderTemp])
    }
}


// MARK: - Widget display data
struct PrinterWidgetData {
    let name: String
    let printState: String
    let filename: String
    let progress: Double
    let extruderTemp: Double
    let bedTemp: Double
    let timeElapsed: Int
    let themeHex: String
    let spoolSlots: [SpoolSlotData]
    var motorTempX: Double?
    var motorTempY: Double?
    var chamberTemp: Double?
    var extruderTemps: [Double] = []

    // Load a specific printer by id, or first available
    static func load(id: String? = nil) -> PrinterWidgetData {
        let all = PrinterWidgetEntry.loadAll()
        if let id, let entry = all.first(where: { $0.id == id }) { return entry.asWidgetData }
        return all.first?.asWidgetData ?? .placeholder
    }

    // Cloudflare-free: the widget shows the local app-group cache written by the
    // app. It makes ZERO Worker requests. Live status away from home is covered
    // by the Live Activity (pushed to the phone) — a widget can't read a Live
    // Activity anyway, and doesn't need to. Because nothing reads /status, the
    // Worker no longer keeps a per-print KV snapshot (that was the KV-write hog).
    static func loadFresh(id: String? = nil) async -> PrinterWidgetData {
        return load(id: id)
    }

    static var placeholder: PrinterWidgetData {
        PrinterWidgetData(name: "PaxxMaker", printState: "standby", filename: "",
                          progress: 0, extruderTemp: 0, bedTemp: 0, timeElapsed: 0,
                          themeHex: "0A84FF", spoolSlots: [])
    }

    var stateColor: Color {
        switch printState {
        case "printing": return .green
        case "paused":   return .orange
        case "error":    return .red
        case "complete": return .blue
        default:         return .secondary
        }
    }

    var stateLabel: String {
        switch printState {
        case "printing": return lzShared(en: "Printing", de: "Druckt", fr: "Impression", es: "Imprimiendo", pt: "Imprimindo", it: "Stampa in corso", zh: "打印中")
        case "paused":   return lzShared(en: "Paused", de: "Pause", fr: "Pause", es: "Pausado", pt: "Pausado", it: "In pausa", zh: "已暂停")
        case "error":    return lzShared(en: "Error", de: "Fehler", fr: "Erreur", es: "Error", pt: "Erro", it: "Errore", zh: "错误")
        case "complete": return lzShared(en: "Done", de: "Fertig", fr: "Terminé", es: "Listo", pt: "Concluído", it: "Fatto", zh: "完成")
        case "standby":  return lzShared(en: "Ready", de: "Bereit", fr: "Prêt", es: "Listo", pt: "Pronto", it: "Pronto", zh: "就绪")
        // "unknown" = the app has not reached the printer yet (or not lately)
        default:         return lzShared(en: "No connection", de: "Keine Verbindung", fr: "Pas de connexion", es: "Sin conexión", pt: "Sem conexão", it: "Nessuna connessione", zh: "未连接")
        }
    }

    var shortFilename: String {
        (filename.components(separatedBy: "/").last ?? filename)
            .replacingOccurrences(of: ".gcode", with: "")
            .replacingOccurrences(of: ".gco",   with: "")
    }

    var formattedTime: String {
        let h = timeElapsed / 3600
        let m = (timeElapsed % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    var eta: Int {
        guard progress > 0.01 && timeElapsed > 0 else { return 0 }
        return Int(Double(timeElapsed) / progress * (1.0 - progress))
    }

    var formattedETA: String {
        let h = eta / 3600
        let m = (eta % 3600) / 60
        if h > 0 { return "~\(h)h \(m)m" }
        if m > 0 { return "~\(m)m" }
        return "–"
    }

    var themeColor: Color {
        guard themeHex.count == 6, let val = UInt64(themeHex, radix: 16) else { return .blue }
        return Color(red: Double((val >> 16) & 0xFF) / 255,
                     green: Double((val >> 8)  & 0xFF) / 255,
                     blue:  Double( val        & 0xFF) / 255)
    }

    var isActive: Bool { printState == "printing" || printState == "paused" }

    /// The current print's thumbnail — the same file the app leaves for the
    /// Live Activity (LiveActivityThumb), only when it belongs to this file.
    var thumbnail: UIImage? {
        guard isActive, !filename.isEmpty,
              UserDefaults(suiteName: paxxAppGroupID)?.string(forKey: "la_thumb_for_\(name)") == filename,
              let url = PaxxMakerWidgetAttributes.thumbnailURL(printer: name) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// "19 min left" — worded like the Live Activity.
    var etaLeft: String? {
        guard isActive, eta > 0 else { return nil }
        let h = eta / 3600, m = (eta % 3600) / 60
        let t = h > 0 ? "\(h) h \(m) min" : (m > 0 ? "\(m) min" : "< 1 min")
        return lzShared(en: "\(t) left", de: "noch \(t)", fr: "encore \(t)", es: "faltan \(t)", pt: "faltam \(t)", it: "ancora \(t)", zh: "剩余 \(t)")
    }
}

// MARK: - Live Activity attributes (must match definition in ContentView.swift)
struct PaxxMakerWidgetAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var printState: String
        var progress: Double
        var extruderTemp: Double
        var bedTemp: Double
        var timeElapsed: Int
        /// Position in the file, sent alongside the slicer estimate by the
        /// printer bridge. Optional: pushes from an older bridge still decode.
        var progressFile: Double? = nil
        /// The file being printed. Optional and in the state (not only in the
        /// attributes, which can't change): an activity started in the
        /// background before the name was known shows it from the next update.
        var filename: String? = nil

        /// What to display. Follows the user's choice in Settings → Extra
        /// Features; falls back to the slicer value when an older bridge
        /// doesn't send the file position.
        var shownProgress: Double {
            let useFile = UserDefaults(suiteName: "group.paxxmaker.u1")?
                .bool(forKey: "progress_use_file") ?? false
            return useFile ? (progressFile ?? progress) : progress
        }
    }
    var printerName: String
    var filename: String

    /// Last known file name per printer, written by the app — the fallback
    /// while pushes from an older worker don't carry it.
    static func rememberFile(_ name: String, printer: String) {
        guard !name.isEmpty else { return }
        UserDefaults(suiteName: "group.paxxmaker.u1")?.set(name, forKey: "la_file_\(printer)")
    }

    /// Where the app leaves the current print's thumbnail (LiveActivityThumb).
    static func thumbnailURL(printer: String) -> URL? {
        let safe = String(printer.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.paxxmaker.u1")?
            .appendingPathComponent("la_thumb_\(safe).png")
    }

    /// The current print's thumbnail, if the app has left it for this file.
    func thumbnail(_ state: ContentState) -> UIImage? {
        let d = UserDefaults(suiteName: "group.paxxmaker.u1")
        var raw = state.filename ?? ""
        if raw.isEmpty { raw = filename }
        if raw.isEmpty { raw = d?.string(forKey: "la_file_\(printerName)") ?? "" }
        guard !raw.isEmpty, d?.string(forKey: "la_thumb_for_\(printerName)") == raw,
              let url = Self.thumbnailURL(printer: printerName) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// The print's name as shown: without folder and extension.
    func shownFile(_ state: ContentState) -> String {
        var raw = state.filename ?? ""
        if raw.isEmpty { raw = filename }
        if raw.isEmpty { raw = UserDefaults(suiteName: "group.paxxmaker.u1")?.string(forKey: "la_file_\(printerName)") ?? "" }
        var n = raw.components(separatedBy: "/").last ?? raw
        for ext in [".gcode", ".gco", ".g"] where n.lowercased().hasSuffix(ext) {
            n = String(n.dropLast(ext.count)); break
        }
        return n
    }
}
