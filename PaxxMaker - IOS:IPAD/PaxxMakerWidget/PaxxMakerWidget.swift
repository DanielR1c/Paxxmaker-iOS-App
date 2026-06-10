import WidgetKit
import SwiftUI

private func lz(en: String, de: String, fr: String, es: String) -> String {
    let code = Locale.current.language.languageCode?.identifier ?? "en"
    switch code { case "de": return de; case "fr": return fr; case "es": return es; default: return en }
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
        let data = PrinterWidgetData.load(id: configuration.printer?.id)
        let refresh = Date().addingTimeInterval(data.isActive ? 300 : 1800)
        return Timeline(entries: [PrinterEntry(date: .now, configuration: configuration, data: data)],
                        policy: .after(refresh))
    }
}

// MARK: - Shared helpers
private func tempCell(_ label: String, _ value: String) -> some View {
    VStack(spacing: 2) {
        Text(label)
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.65))
        Text(value)
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
    }
    .frame(maxWidth: .infinity)
}

private func thinDivider() -> some View {
    Rectangle()
        .fill(Color.white.opacity(0.25))
        .frame(width: 1, height: 28)
}

private func progressRing(progress: Double, size: CGFloat, lineWidth: CGFloat) -> some View {
    ZStack {
        Circle()
            .stroke(Color.white.opacity(0.2), lineWidth: lineWidth)
        Circle()
            .trim(from: 0, to: progress)
            .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .shadow(color: .white.opacity(0.35), radius: 4)
        VStack(spacing: 0) {
            Text("\(Int(progress * 100))")
                .font(.system(size: size * 0.31, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("%")
                .font(.system(size: size * 0.13, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
        }
    }
    .frame(width: size, height: size)
}

private func gradientBackground(_ color: Color) -> some View {
    LinearGradient(
        colors: [color, color.opacity(0.55)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Small Widget (2×2)
struct SmallWidgetView: View {
    let data: PrinterWidgetData
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(alignment: .top) {
                Text(data.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Spacer()
                Circle().fill(.white)
                    .frame(width: 6, height: 6)
                    .opacity(data.isActive ? 1 : 0.3)
                    .shadow(color: .white.opacity(0.8), radius: data.isActive ? 4 : 0)
            }

            Text(data.stateLabel)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.top, 2)

            Spacer(minLength: 6)

            // Ring centered
            HStack {
                Spacer()
                progressRing(progress: data.progress, size: 62, lineWidth: 7)
                Spacer()
            }

            Spacer(minLength: 4)

            if data.isActive && data.eta > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "timer").font(.system(size: 9, weight: .semibold))
                    Text(data.formattedETA).fixedSize()
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            }

            Spacer(minLength: 4)

            // Temp pill
            HStack(spacing: 4) {
                Image(systemName: "flame.fill").font(.system(size: 9, weight: .semibold))
                Text("\(Int(data.extruderTemp))°").fixedSize()
                Spacer(minLength: 6)
                Image(systemName: "square.fill").font(.system(size: 9, weight: .semibold))
                Text("\(Int(data.bedTemp))°").fixedSize()
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(14)
        .containerBackground(for: .widget) {
            gradientBackground(data.themeColor)
        }
    }
}

// MARK: - Medium Widget (4×2)
struct MediumWidgetView: View {
    let data: PrinterWidgetData
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Left: state info + progress
            VStack(alignment: .leading, spacing: 5) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(data.name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                    Text(data.stateLabel)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }

                Spacer(minLength: 0)

                if data.isActive, !data.shortFilename.isEmpty {
                    Text(data.shortFilename)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2)).frame(height: 5)
                        Capsule().fill(Color.white)
                            .frame(width: max(5, geo.size.width * data.progress), height: 5)
                    }
                }.frame(height: 5)

                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        Image(systemName: "flame.fill").font(.system(size: 9, weight: .semibold))
                        Text("\(Int(data.extruderTemp))°").fixedSize()
                    }
                    HStack(spacing: 3) {
                        Image(systemName: "square.fill").font(.system(size: 9, weight: .semibold))
                        Text("\(Int(data.bedTemp))°").fixedSize()
                    }
                    if data.isActive && data.eta > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "timer").font(.system(size: 9, weight: .semibold))
                            Text(data.formattedETA).fixedSize()
                        }
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            }

            // Right: big percentage
            VStack(spacing: 2) {
                Spacer()
                Text("\(Int(data.progress * 100))")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
            }
            .frame(width: 62)
        }
        .padding(16)
        .containerBackground(for: .widget) {
            gradientBackground(data.themeColor)
        }
    }
}

// MARK: - Large Widget (4×4)
struct LargeWidgetView: View {
    let data: PrinterWidgetData
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header: state text + ring side-by-side
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(data.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                        Circle().fill(.white)
                            .frame(width: 6, height: 6)
                            .opacity(data.isActive ? 1 : 0.3)
                            .shadow(color: .white.opacity(0.8), radius: data.isActive ? 4 : 0)
                    }
                    Text(data.stateLabel)
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    if data.isActive && !data.shortFilename.isEmpty {
                        Text(data.shortFilename)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                            .padding(.top, 1)
                    }
                }
                Spacer()
                progressRing(progress: data.progress, size: 92, lineWidth: 10)
            }

            Spacer(minLength: 14)

            // Main temp panel
            HStack(spacing: 0) {
                tempCell("Extruder", "\(Int(data.extruderTemp))°C")
                thinDivider()
                tempCell("Bett", "\(Int(data.bedTemp))°C")
                if data.isActive && data.timeElapsed > 0 {
                    thinDivider()
                    tempCell("Verstr.", data.formattedTime)
                }
                if data.isActive && data.eta > 0 {
                    thinDivider()
                    tempCell("ETA", data.formattedETA)
                }
            }
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))

            // Motor / chamber panel
            if data.motorTempX != nil || data.motorTempY != nil || data.chamberTemp != nil {
                Spacer(minLength: 8)
                HStack(spacing: 0) {
                    if let mx = data.motorTempX {
                        tempCell("Motor X", "\(Int(mx))°C")
                        if data.motorTempY != nil || data.chamberTemp != nil { thinDivider() }
                    }
                    if let my = data.motorTempY {
                        tempCell("Motor Y", "\(Int(my))°C")
                        if data.chamberTemp != nil { thinDivider() }
                    }
                    if let ct = data.chamberTemp {
                        tempCell("Bauraum", "\(Int(ct))°C")
                    }
                }
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
            }

            // Spool panel
            if !data.spoolSlots.isEmpty {
                Spacer(minLength: 8)
                HStack(spacing: 0) {
                    ForEach(Array(data.spoolSlots.enumerated()), id: \.offset) { _, slot in
                        VStack(spacing: 5) {
                            Circle()
                                .fill(slot.detected
                                    ? AnyShapeStyle(LinearGradient(
                                        colors: [slot.color, slot.gradientEnd],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                                    : AnyShapeStyle(Color.white.opacity(0.15)))
                                .frame(width: 30, height: 30)
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                                .shadow(color: slot.detected ? slot.color.opacity(0.5) : .clear, radius: 5)
                            Text(slot.detected ? slot.material : "–")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(slot.detected ? 0.85 : 0.4))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .containerBackground(for: .widget) {
            gradientBackground(data.themeColor)
        }
    }
}

// MARK: - Spool Small Widget (2×2)
struct SpoolSmallWidgetView: View {
    let data: PrinterWidgetData
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(data.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            Spacer(minLength: 0)
            let slots = data.spoolSlots.isEmpty
                ? (0..<4).map { _ in SpoolSlotData(colorHex: "888888", material: "–", detected: false) }
                : data.spoolSlots
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(Array(slots.prefix(4).enumerated()), id: \.offset) { i, slot in
                    VStack(spacing: 4) {
                        Circle()
                            .fill(slot.detected
                                ? AnyShapeStyle(LinearGradient(
                                    colors: [slot.color, slot.gradientEnd],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                                : AnyShapeStyle(Color.white.opacity(0.15)))
                            .frame(width: 32, height: 32)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                            .shadow(color: slot.detected ? slot.color.opacity(0.45) : .clear, radius: 5)
                        let temp = data.extruderTemps.indices.contains(i) ? data.extruderTemps[i] : 0
                        Text(temp > 0 ? "\(Int(temp))°" : "–")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
            }
        }
        .padding(13)
        .containerBackground(for: .widget) {
            gradientBackground(data.themeColor)
        }
    }
}

// MARK: - Spool Medium Widget (4×2)
struct SpoolMediumWidgetView: View {
    let data: PrinterWidgetData
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(data.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Spacer(minLength: 0)
            let slots = data.spoolSlots.isEmpty
                ? (0..<4).map { _ in SpoolSlotData(colorHex: "888888", material: "–", detected: false) }
                : data.spoolSlots
            HStack(spacing: 0) {
                ForEach(Array(slots.prefix(4).enumerated()), id: \.offset) { i, slot in
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(slot.detected
                                    ? AnyShapeStyle(LinearGradient(
                                        colors: [slot.color, slot.gradientEnd],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                                    : AnyShapeStyle(Color.white.opacity(0.12)))
                                .frame(width: 44, height: 44)
                                .shadow(color: slot.detected ? slot.color.opacity(0.5) : .clear, radius: 8, y: 3)
                            Circle()
                                .strokeBorder(Color.white.opacity(slot.detected ? 0.25 : 0.1), lineWidth: 1.5)
                                .frame(width: 44, height: 44)
                            if slot.detected {
                                Circle().fill(Color.white.opacity(0.22)).frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.4))
                            }
                        }
                        Text(slot.detected ? slot.material : "–")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(slot.detected ? 0.85 : 0.4))
                            .lineLimit(1)
                        let temp = data.extruderTemps.indices.contains(i) ? data.extruderTemps[i] : 0
                        Text(temp > 0 ? "\(Int(temp))°" : "–")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(14)
        .containerBackground(for: .widget) {
            gradientBackground(data.themeColor)
        }
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
        .configurationDisplayName(lz(en: "PaxxMaker Progress", de: "PaxxMaker Fortschritt", fr: "Progression PaxxMaker", es: "Progreso PaxxMaker"))
        .description(lz(en: "Printer status & progress.", de: "Druckerstatus & Fortschritt.", fr: "État & progression de l'imprimante.", es: "Estado y progreso de la impresora."))
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
        .configurationDisplayName(lz(en: "PaxxMaker Spools", de: "PaxxMaker Spulen", fr: "Bobines PaxxMaker", es: "Carretes PaxxMaker"))
        .description(lz(en: "Filament spools overview.", de: "Filament-Spulen Übersicht.", fr: "Aperçu des bobines de filament.", es: "Vista general de carretes de filamento."))
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
