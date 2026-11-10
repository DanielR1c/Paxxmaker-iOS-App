import WidgetKit
import SwiftUI

private func lz(en: String, de: String, fr: String, es: String, pt: String = "", it: String = "", zh: String = "") -> String {
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

// MARK: - Timeline Entry
struct PrinterEntry: TimelineEntry {
    let date: Date
    let configuration: SelectPrinterIntent
    let data: PrinterWidgetData
}

// MARK: - AppIntent Timeline Provider
struct PrinterTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> PrinterEntry {
        PrinterEntry(date: .now, configuration: SelectPrinterIntent(), data: .placeholder)
    }
    func snapshot(for configuration: SelectPrinterIntent, in context: Context) async -> PrinterEntry {
        PrinterEntry(date: .now, configuration: configuration,
                     data: PrinterWidgetData.load(id: configuration.printer?.id))
    }
    func timeline(for configuration: SelectPrinterIntent, in context: Context) async -> Timeline<PrinterEntry> {
        // For Server-Push printers this pulls the latest known status from the
        // Cloudflare Worker — reachable over any network, unlike the printer's
        // own LAN IP — so the widget stays current while away from home WiFi.
        // Local-only printers fall back to the plain cached value untouched.
        let data = await PrinterWidgetData.loadFresh(id: configuration.printer?.id)
        // 5 min while active, 30 min idle — frequent enough to feel "live"
        // without hammering the Cloudflare quota on every timeline reload.
        let refresh = Date().addingTimeInterval(data.isActive ? 300 : 1800)
        return Timeline(entries: [PrinterEntry(date: .now, configuration: configuration, data: data)],
                        policy: .after(refresh))
    }
}

// MARK: - Shared helpers
// The look follows the Live Activity: the print's thumbnail with a status dot,
// the print's name, the time left and a slim progress bar in the state colour
// — on a calm background (light or dark with the system) that carries only a
// hint of the printer's theme colour.

private func modernBackground(_ accent: Color) -> some View {
    ZStack {
        Color(.systemBackground)
        LinearGradient(colors: [accent.opacity(0.30), accent.opacity(0.08)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private func stateDotColor(_ data: PrinterWidgetData) -> Color {
    data.printState == "standby" || data.printState == "unknown" ? .gray : data.stateColor
}

private func stateIcon(_ state: String) -> String {
    switch state {
    case "paused":   return "pause.fill"
    case "error":    return "exclamationmark"
    case "complete": return "checkmark"
    default:         return "printer.fill"
    }
}

/// Thumbnail of the current print (or the printer symbol) in a rounded tile,
/// with the state as a dot (printing) or a small badge — as in the Live Activity.
private struct PrintThumb: View {
    let data: PrinterWidgetData
    let size: CGFloat
    var body: some View {
        let color = stateDotColor(data)
        Group {
            if let img = data.thumbnail {
                Image(uiImage: img).resizable().scaledToFit().padding(size * 0.07)
            } else {
                Image(systemName: "printer.fill")
                    .font(.system(size: size * 0.40, weight: .semibold))
                    .foregroundStyle(data.themeColor)
            }
        }
        .frame(width: size, height: size)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            Group {
                if data.printState == "printing" || data.printState == "standby" || data.printState == "unknown" {
                    Circle().fill(color)
                        .frame(width: size * 0.2, height: size * 0.2)
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                } else {
                    Image(systemName: stateIcon(data.printState))
                        .font(.system(size: size * 0.16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: size * 0.3, height: size * 0.3)
                        .background(color, in: Circle())
                }
            }
            .offset(x: size * 0.06, y: size * 0.06)
        }
    }
}

private func progressBar(_ progress: Double, _ color: Color, height: CGFloat = 4) -> some View {
    GeometryReader { geo in
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.12))
            Capsule().fill(color)
                .frame(width: max(height, geo.size.width * min(1, max(0, progress))))
        }
    }
    .frame(height: height)
}

private func percentText(_ progress: Double, size: CGFloat) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 1) {
        Text("\(Int(progress * 100))")
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
        Text("%")
            .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
    }
}

/// Small temperature/time chip: symbol + value.
private func chip(_ symbol: String, _ value: String) -> some View {
    HStack(spacing: 3) {
        Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
        Text(value).fixedSize()
    }
}

private func titleLine(_ data: PrinterWidgetData) -> String {
    data.isActive && !data.shortFilename.isEmpty ? data.shortFilename : data.name
}

/// "Snapmaker U1 · Printing" under the print's name, or only the state.
private func subtitleLine(_ data: PrinterWidgetData) -> String {
    data.isActive && !data.shortFilename.isEmpty ? "\(data.name) · \(data.stateLabel)" : data.stateLabel
}

/// One labelled value in a soft panel cell (large widget).
private func valueCell(_ label: String, _ value: String) -> some View {
    VStack(spacing: 2) {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        Text(value)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
    .frame(maxWidth: .infinity)
}

private func spoolDot(_ slot: SpoolSlotData, size: CGFloat) -> some View {
    Circle()
        .fill(slot.detected
              ? AnyShapeStyle(LinearGradient(colors: [slot.color, slot.gradientEnd],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
              : AnyShapeStyle(Color.primary.opacity(0.08)))
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
        .shadow(color: slot.detected ? slot.color.opacity(0.35) : .clear, radius: 4, y: 1)
}

// MARK: - Small Widget (2×2)
struct SmallWidgetView: View {
    let data: PrinterWidgetData
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                PrintThumb(data: data, size: 50)
                Spacer(minLength: 4)
                if data.isActive {
                    percentText(data.progress, size: 26)
                }
            }
            Spacer(minLength: 6)
            Text(titleLine(data))
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Text(data.etaLeft ?? subtitleLine(data))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 1)
            if data.isActive {
                progressBar(data.progress, data.stateColor)
                    .padding(.top, 9)
            } else {
                HStack(spacing: 10) {
                    chip("flame.fill", "\(Int(data.extruderTemp))°")
                    chip("square.fill", "\(Int(data.bedTemp))°")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 7)
            }
        }
        .containerBackground(for: .widget) { modernBackground(data.themeColor) }
    }
}

// MARK: - Medium Widget (4×2)
struct MediumWidgetView: View {
    let data: PrinterWidgetData
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            PrintThumb(data: data, size: 100)
            VStack(alignment: .leading, spacing: 0) {
                Text(titleLine(data))
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                Text(subtitleLine(data))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 1)
                Spacer(minLength: 4)
                if data.isActive {
                    HStack(alignment: .firstTextBaseline) {
                        percentText(data.progress, size: 30)
                        Spacer(minLength: 4)
                        if let eta = data.etaLeft {
                            Text(eta)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    progressBar(data.progress, data.stateColor)
                        .padding(.top, 4)
                    Spacer(minLength: 6)
                }
                HStack(spacing: 12) {
                    chip("flame.fill", "\(Int(data.extruderTemp))°")
                    chip("square.fill", "\(Int(data.bedTemp))°")
                    if let ct = data.chamberTemp { chip("cube.transparent", "\(Int(ct))°") }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            }
        }
        .containerBackground(for: .widget) { modernBackground(data.themeColor) }
    }
}

// MARK: - Large Widget (4×4)
struct LargeWidgetView: View {
    let data: PrinterWidgetData
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                PrintThumb(data: data, size: 84)
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleLine(data))
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(1)
                    Text(subtitleLine(data))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if data.isActive {
                        HStack(alignment: .firstTextBaseline) {
                            percentText(data.progress, size: 32)
                            Spacer(minLength: 4)
                            if let eta = data.etaLeft {
                                Text(eta)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
            if data.isActive {
                progressBar(data.progress, data.stateColor, height: 5)
                    .padding(.top, 10)
                Spacer(minLength: 12)
            } else {
                // Not printing: the values right below the header, the spare
                // room at the bottom — not a gap in the middle.
                Color.clear.frame(height: 14)
            }

            // Temperatures and time
            HStack(spacing: 0) {
                valueCell(lzShared(en: "Nozzle", de: "Düse", fr: "Buse", es: "Boquilla", pt: "Bico", it: "Ugello", zh: "喷嘴"), "\(Int(data.extruderTemp))°C")
                valueCell(lzShared(en: "Bed", de: "Bett", fr: "Plateau", es: "Cama", pt: "Mesa", it: "Piatto", zh: "热床"), "\(Int(data.bedTemp))°C")
                if let ct = data.chamberTemp {
                    valueCell(lzShared(en: "Chamber", de: "Bauraum", fr: "Caisson", es: "Cámara", pt: "Câmara", it: "Camera", zh: "腔体"), "\(Int(ct))°C")
                }
                if data.isActive && data.timeElapsed > 0 {
                    valueCell(lzShared(en: "Elapsed", de: "Verstrichen", fr: "Écoulé", es: "Transcurrido", pt: "Decorrido", it: "Trascorso", zh: "已用"), data.formattedTime)
                }
            }
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if data.motorTempX != nil || data.motorTempY != nil {
                HStack(spacing: 0) {
                    if let mx = data.motorTempX { valueCell("Motor X", "\(Int(mx))°C") }
                    if let my = data.motorTempY { valueCell("Motor Y", "\(Int(my))°C") }
                }
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.top, 8)
            }

            if !data.spoolSlots.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(data.spoolSlots.enumerated()), id: \.offset) { _, slot in
                        VStack(spacing: 5) {
                            spoolDot(slot, size: 28)
                            Text(slot.detected ? slot.material : "–")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(slot.detected ? .primary : .secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .containerBackground(for: .widget) { modernBackground(data.themeColor) }
    }
}

// MARK: - Spool Small Widget (2×2)
struct SpoolSmallWidgetView: View {
    let data: PrinterWidgetData
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(data.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            let slots = data.spoolSlots.isEmpty
                ? (0..<4).map { _ in SpoolSlotData(colorHex: "888888", material: "–", detected: false) }
                : data.spoolSlots
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(Array(slots.prefix(4).enumerated()), id: \.offset) { i, slot in
                    VStack(spacing: 4) {
                        spoolDot(slot, size: 34)
                        let temp = data.extruderTemps.indices.contains(i) ? data.extruderTemps[i] : 0
                        Text(temp > 0 ? "\(Int(temp))°" : "–")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .containerBackground(for: .widget) { modernBackground(data.themeColor) }
    }
}

// MARK: - Spool Medium Widget (4×2)
struct SpoolMediumWidgetView: View {
    let data: PrinterWidgetData
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(data.name)
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            let slots = data.spoolSlots.isEmpty
                ? (0..<4).map { _ in SpoolSlotData(colorHex: "888888", material: "–", detected: false) }
                : data.spoolSlots
            HStack(spacing: 0) {
                ForEach(Array(slots.prefix(4).enumerated()), id: \.offset) { i, slot in
                    VStack(spacing: 6) {
                        spoolDot(slot, size: 44)
                            .overlay {
                                if !slot.detected {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        Text(slot.detected ? slot.material : "–")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(slot.detected ? .primary : .secondary)
                            .lineLimit(1)
                        let temp = data.extruderTemps.indices.contains(i) ? data.extruderTemps[i] : 0
                        Text(temp > 0 ? "\(Int(temp))°" : "–")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .containerBackground(for: .widget) { modernBackground(data.themeColor) }
    }
}

// MARK: - Entry View + PaxxMaker Widget
struct PaxxMakerWidgetEntryView: View {
    let entry: PrinterEntry
    @Environment(\.widgetFamily) var family
    var body: some View {
        switch family {
        case .systemSmall:  SmallWidgetView(data: entry.data)
        case .systemLarge:  LargeWidgetView(data: entry.data)
        default:            MediumWidgetView(data: entry.data)
        }
    }
}

struct PaxxMakerWidget: Widget {
    let kind = "PaxxMakerWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectPrinterIntent.self,
                               provider: PrinterTimelineProvider()) { entry in
            PaxxMakerWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(lz(en: "PaxxMaker Progress", de: "PaxxMaker Fortschritt", fr: "Progression PaxxMaker", es: "Progreso PaxxMaker", pt: "Progresso PaxxMaker", it: "Avanzamento PaxxMaker", zh: "PaxxMaker 进度"))
        .description(lz(en: "Printer status & progress.", de: "Druckerstatus & Fortschritt.", fr: "État & progression de l'imprimante.", es: "Estado y progreso de la impresora.", pt: "Status e progresso da impressora.", it: "Stato e avanzamento della stampante.", zh: "打印机状态与进度。"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Spool Widget Entry View + Widget
struct SpoolWidgetEntryView: View {
    let entry: PrinterEntry
    @Environment(\.widgetFamily) var family
    var body: some View {
        switch family {
        case .systemSmall: SpoolSmallWidgetView(data: entry.data)
        default:           SpoolMediumWidgetView(data: entry.data)
        }
    }
}

struct SpoolWidget: Widget {
    let kind = "SpoolWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectPrinterIntent.self,
                               provider: PrinterTimelineProvider()) { entry in
            SpoolWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(lz(en: "PaxxMaker Spools", de: "PaxxMaker Spulen", fr: "Bobines PaxxMaker", es: "Carretes PaxxMaker", pt: "Bobinas PaxxMaker", it: "Bobine PaxxMaker", zh: "PaxxMaker 料盘"))
        .description(lz(en: "Filament spools overview.", de: "Filament-Spulen Übersicht.", fr: "Aperçu des bobines de filament.", es: "Vista general de carretes de filamento.", pt: "Visão geral das bobinas de filamento.", it: "Panoramica delle bobine di filamento.", zh: "耗材料盘概览。"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Previews
#Preview("Small", as: .systemSmall, widget: { PaxxMakerWidget() }) {
    PrinterEntry(date: .now, configuration: SelectPrinterIntent(), data: .placeholder)
}

#Preview("Medium", as: .systemMedium, widget: { PaxxMakerWidget() }) {
    PrinterEntry(date: .now, configuration: SelectPrinterIntent(), data: .placeholder)
}

#Preview("Large", as: .systemLarge, widget: { PaxxMakerWidget() }) {
    PrinterEntry(date: .now, configuration: SelectPrinterIntent(), data: .placeholder)
}

#Preview("Spool Small", as: .systemSmall, widget: { SpoolWidget() }) {
    PrinterEntry(date: .now, configuration: SelectPrinterIntent(), data: .placeholder)
}

#Preview("Spool Medium", as: .systemMedium, widget: { SpoolWidget() }) {
    PrinterEntry(date: .now, configuration: SelectPrinterIntent(), data: .placeholder)
}
