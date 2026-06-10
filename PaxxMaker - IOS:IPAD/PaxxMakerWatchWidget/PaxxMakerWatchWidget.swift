import WidgetKit
import SwiftUI
import AppIntents

private func lz(en: String, de: String, fr: String, es: String) -> String {
    let code = Locale.current.language.languageCode?.identifier ?? "en"
    switch code { case "de": return de; case "fr": return fr; case "es": return es; default: return en }
}

// MARK: - Data Model

struct WatchComplicationData: Codable {
    var id: String = ""
    var printerName: String = "PaxxMaker"
    var progress: Double = 0
    var printState: String = "standby"
    var themeHex: String = "0A84FF"
    var timeElapsed: Int = 0

    var stateLabel: String {
        switch printState {
        case "printing": return lz(en: "Printing", de: "Druckt", fr: "Impression", es: "Imprimiendo")
        case "paused":   return lz(en: "Paused", de: "Pause", fr: "Pause", es: "Pausado")
        case "error":    return lz(en: "Error", de: "Fehler", fr: "Erreur", es: "Error")
        case "complete": return lz(en: "Done", de: "Fertig", fr: "Terminé", es: "Listo")
        case "standby":  return lz(en: "Ready", de: "Bereit", fr: "Prêt", es: "Listo")
        default:         return "–"
        }
    }

    var isActive: Bool { printState == "printing" || printState == "paused" }

    var themeColor: Color {
        guard themeHex.count == 6, let val = UInt64(themeHex, radix: 16) else { return .blue }
        return Color(red: Double((val >> 16) & 0xFF) / 255,
                     green: Double((val >> 8)  & 0xFF) / 255,
                     blue:  Double( val        & 0xFF) / 255)
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

    var etaShort: String {
        let h = eta / 3600
        let m = (eta % 3600) / 60
        if h > 0 { return "\(h)h" }
        if m > 0 { return "\(m)m" }
        return "–"
    }

    static func load(for printerID: String? = nil) -> WatchComplicationData {
        let all = loadAll()
        if let pid = printerID, !pid.isEmpty, pid != "__none__" {
            return all.first { $0.id == pid } ?? all.first ?? WatchComplicationData()
        }
        if let first = all.first { return first }
        // Legacy fallback
        guard let defaults = UserDefaults(suiteName: "group.paxxmaker.u1"),
              let data = defaults.data(forKey: "watch_complication"),
              let decoded = try? JSONDecoder().decode(WatchComplicationData.self, from: data)
        else { return WatchComplicationData() }
        return decoded
    }

    static func loadAll() -> [WatchComplicationData] {
        guard let defaults = UserDefaults(suiteName: "group.paxxmaker.u1"),
              let data = defaults.data(forKey: "watch_all_printers"),
              let decoded = try? JSONDecoder().decode([WatchComplicationData].self, from: data)
        else { return [] }
        return decoded
    }
}

// MARK: - Printer Entity & Query

struct WatchPrinterEntity: AppEntity {
    var id: String
    var name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Drucker"
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
    static var defaultQuery = WatchPrinterEntityQuery()
}

struct WatchPrinterEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WatchPrinterEntity] {
        WatchComplicationData.loadAll()
            .filter { identifiers.contains($0.id) }
            .map { WatchPrinterEntity(id: $0.id, name: $0.printerName) }
    }

    func suggestedEntities() async throws -> [WatchPrinterEntity] {
        let entities = WatchComplicationData.loadAll()
            .map { WatchPrinterEntity(id: $0.id, name: $0.printerName) }
        guard !entities.isEmpty else {
            return [WatchPrinterEntity(id: "__none__", name: lz(en: "No printer – open app", de: "Kein Drucker – App öffnen", fr: "Aucune imprimante – ouvrir l'app", es: "Sin impresora – abrir app"))]
        }
        return entities
    }

    func defaultResult() async -> WatchPrinterEntity? { nil }
}

// MARK: - Configuration Intent

struct SelectWatchPrinterIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Select Printer"
    static var description = IntentDescription("Select the printer for this widget.")

    @Parameter(title: "Printer")
    var printer: WatchPrinterEntity?
}

// MARK: - Timeline Entry & Provider

struct WatchComplicationEntry: TimelineEntry {
    let date: Date
    let data: WatchComplicationData
}

struct WatchComplicationProvider: AppIntentTimelineProvider {
    typealias Entry = WatchComplicationEntry
    typealias Intent = SelectWatchPrinterIntent

    func placeholder(in context: Context) -> WatchComplicationEntry {
        WatchComplicationEntry(date: .now, data: WatchComplicationData(
            id: "preview", printerName: "PaxxMaker", progress: 0.72, printState: "printing",
            themeHex: "0A84FF", timeElapsed: 8100))
    }

    func snapshot(for configuration: SelectWatchPrinterIntent, in context: Context) async -> WatchComplicationEntry {
        WatchComplicationEntry(date: .now, data: WatchComplicationData.load(for: configuration.printer?.id))
    }

    func timeline(for configuration: SelectWatchPrinterIntent, in context: Context) async -> Timeline<WatchComplicationEntry> {
        let entry = WatchComplicationEntry(
            date: .now,
            data: WatchComplicationData.load(for: configuration.printer?.id)
        )
        // Policy .never: Watch app calls reloadAllTimelines() when new data arrives
        return Timeline(entries: [entry], policy: .never)
    }

    // Required on watchOS: the face customization has no widget picker,
    // so we provide one pre-configured recommendation per printer.
    func recommendations() -> [AppIntentRecommendation<SelectWatchPrinterIntent>] {
        WatchComplicationData.loadAll().map { data in
            let intent = SelectWatchPrinterIntent()
            intent.printer = WatchPrinterEntity(id: data.id, name: data.printerName)
            return AppIntentRecommendation(intent: intent, description: data.printerName)
        }
    }
}

// MARK: - Circular Complication

struct CircularComplicationView: View {
    let data: WatchComplicationData

    var body: some View {
        ZStack {
            if data.isActive {
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: data.progress)
                    .stroke(data.themeColor,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 5)
            }
            TimelineView(.periodic(from: .now, by: 2.0)) { ctx in
                let showETA = data.isActive && data.eta > 0 &&
                              Int(ctx.date.timeIntervalSinceReferenceDate / 2.0) % 2 == 1
                if showETA {
                    VStack(spacing: 0) {
                        Text(data.etaShort)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        Text("ETA")
                            .font(.system(size: 8, weight: .medium))
                            .opacity(0.65)
                    }
                } else {
                    VStack(spacing: 0) {
                        Text("\(Int(data.progress * 100))")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                        Text("%")
                            .font(.system(size: 9, weight: .medium))
                            .opacity(0.65)
                    }
                }
            }
        }
    }
}

// MARK: - Rectangular Complication

struct RectangularComplicationView: View {
    let data: WatchComplicationData

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if data.isActive {
                HStack {
                    Text(data.stateLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if data.timeElapsed > 0 {
                        Text(data.formattedTime)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: data.progress)
                    .progressViewStyle(.linear)
                    .tint(data.themeColor)
                HStack {
                    if data.eta > 0 {
                        Text("ETA \(data.formattedETA)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    Spacer()
                    Text("\(Int(data.progress * 100))%")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
            } else {
                Text(data.stateLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Inline Complication

struct InlineComplicationView: View {
    let data: WatchComplicationData

    var body: some View {
        if data.isActive {
            TimelineView(.periodic(from: .now, by: 2.0)) { ctx in
                let showETA = data.eta > 0 &&
                              Int(ctx.date.timeIntervalSinceReferenceDate / 2.0) % 2 == 1
                if showETA {
                    Text("\(data.printerName) ETA \(data.formattedETA)")
                } else {
                    Text("\(data.printerName) \(Int(data.progress * 100))% · \(data.stateLabel)")
                }
            }
        } else {
            Text("\(data.printerName) · \(data.stateLabel)")
        }
    }
}

// MARK: - Corner Complication

struct CornerComplicationView: View {
    let data: WatchComplicationData

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2.0)) { ctx in
            let showETA = data.isActive && data.eta > 0 &&
                          Int(ctx.date.timeIntervalSinceReferenceDate / 2.0) % 2 == 1
            ZStack {
                // Center: percentage or ETA (no printer name)
                if data.isActive {
                    if showETA {
                        Text(data.etaShort)
                            .font(.system(size: 22, weight: .black, design: .rounded))
                            .minimumScaleFactor(0.4)
                            .lineLimit(1)
                    } else {
                        Text("\(Int(data.progress * 100))%")
                            .font(.system(size: 22, weight: .black, design: .rounded))
                            .minimumScaleFactor(0.4)
                            .lineLimit(1)
                    }
                } else {
                    Text(data.stateLabel)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.4)
                        .lineLimit(1)
                        .opacity(0.8)
                }
            }
            // Progress bar curved along the outside bezel
            .widgetLabel {
                if data.isActive {
                    Gauge(value: data.progress) { EmptyView() }
                        .gaugeStyle(.accessoryLinear)
                        .tint(data.themeColor)
                } else {
                    Text(data.stateLabel)
                }
            }
        }
    }
}

// MARK: - Entry View

struct PaxxMakerWatchWidgetEntryView: View {
    let entry: WatchComplicationEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            CircularComplicationView(data: entry.data)
        case .accessoryRectangular:
            RectangularComplicationView(data: entry.data)
        case .accessoryInline:
            InlineComplicationView(data: entry.data)
        case .accessoryCorner:
            CornerComplicationView(data: entry.data)
        default:
            CircularComplicationView(data: entry.data)
        }
    }
}

// MARK: - Widget

struct PaxxMakerWatchWidget: Widget {
    let kind: String = "PaxxMakerWatchWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectWatchPrinterIntent.self,
            provider: WatchComplicationProvider()
        ) { entry in
            PaxxMakerWatchWidgetEntryView(entry: entry)
                .containerBackground(entry.data.themeColor.gradient, for: .widget)
        }
        .configurationDisplayName("PaxxMaker")
        .description(lz(en: "Your 3D print progress", de: "Fortschritt deines 3D-Drucks", fr: "Progression de votre impression 3D", es: "Progreso de tu impresión 3D"))
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCorner
        ])
    }
}

// MARK: - Previews

#Preview("Circular", as: .accessoryCircular) {
    PaxxMakerWatchWidget()
} timeline: {
    WatchComplicationEntry(date: .now, data: WatchComplicationData(
        id: "u1", printerName: "U1", progress: 0.72, printState: "printing", themeHex: "0A84FF", timeElapsed: 8100))
}

#Preview("Rectangular", as: .accessoryRectangular) {
    PaxxMakerWatchWidget()
} timeline: {
    WatchComplicationEntry(date: .now, data: WatchComplicationData(
        id: "u1", printerName: "Snapmaker U1", progress: 0.72, printState: "printing", themeHex: "0A84FF", timeElapsed: 8100))
}
