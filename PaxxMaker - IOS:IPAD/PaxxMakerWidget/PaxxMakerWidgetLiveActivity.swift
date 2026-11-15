import ActivityKit
import WidgetKit
import SwiftUI

struct PaxxMakerWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PaxxMakerWidgetAttributes.self) { context in
            LiveActivityBannerView(context: context)
                // A tap opens the app on this printer, not on the last tab.
                .widgetURL(Self.printerURL(context.attributes.printerName))
        } dynamicIsland: { context in
            let color = LAStyle.color(context.state.printState)
            let file = context.attributes.shownFile(context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LALeading(image: context.attributes.thumbnail(context.state),
                              progress: context.state.shownProgress, state: context.state.printState, size: 38)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.isEmpty ? context.attributes.printerName : file)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Text(LAStyle.subtitle(context.attributes.printerName, context.state, showPrinter: !file.isEmpty))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(Int(context.state.shownProgress * 100))%")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(color)
                            .monospacedDigit()
                        if let eta = LAStyle.eta(context.state) {
                            Text(eta).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .padding(.trailing, 4)
                }
            } compactLeading: {
                LAProgressRing(progress: context.state.shownProgress, state: context.state.printState, size: 18, line: 2.5)
            } compactTrailing: {
                Text("\(Int(context.state.shownProgress * 100))%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                    .monospacedDigit()
            } minimal: {
                LAProgressRing(progress: context.state.shownProgress, state: context.state.printState, size: 18, line: 2.5)
            }
            .keylineTint(color)
            .widgetURL(Self.printerURL(context.attributes.printerName))
        }
    }

    /// paxxmaker://printer?name=… — handled by the app's onOpenURL.
    static func printerURL(_ name: String) -> URL? {
        var c = URLComponents()
        c.scheme = "paxxmaker"; c.host = "printer"
        c.queryItems = [URLQueryItem(name: "name", value: name)]
        return c.url
    }
}

/// Colours, texts and the time left — shared by the banner and the island.
private enum LAStyle {
    static func color(_ state: String) -> Color {
        switch state {
        case "printing": return .green
        case "paused":   return .orange
        case "error":    return .red
        case "complete": return .blue
        default:         return .secondary
        }
    }
    static func icon(_ state: String) -> String {
        switch state {
        case "paused":   return "pause.fill"
        case "error":    return "exclamationmark"
        case "complete": return "checkmark"
        default:         return "printer.fill"
        }
    }
    static func stateText(_ state: String) -> String {
        switch state {
        case "printing": return lzShared(en: "Printing", de: "Druckt", fr: "Impression", es: "Imprimiendo", pt: "Imprimindo", it: "In stampa", zh: "打印中")
        case "paused":   return lzShared(en: "Paused", de: "Pausiert", fr: "En pause", es: "En pausa", pt: "Pausado", it: "In pausa", zh: "已暂停")
        case "error":    return lzShared(en: "Error", de: "Fehler", fr: "Erreur", es: "Error", pt: "Erro", it: "Errore", zh: "错误")
        case "complete": return lzShared(en: "Done", de: "Fertig", fr: "Terminé", es: "Terminado", pt: "Concluído", it: "Finito", zh: "完成")
        default:         return lzShared(en: "Ready", de: "Bereit", fr: "Prêt", es: "Listo", pt: "Pronto", it: "Pronto", zh: "就绪")
        }
    }
    /// "PaxxMaker U1 · Druckt" (or only the state when the printer is the title).
    static func subtitle(_ printer: String, _ state: PaxxMakerWidgetAttributes.ContentState, showPrinter: Bool) -> String {
        showPrinter ? "\(printer) · \(stateText(state.printState))" : stateText(state.printState)
    }
    /// Time left, estimated from the time so far: "noch 1 h 20 min".
    static func eta(_ state: PaxxMakerWidgetAttributes.ContentState) -> String? {
        let p = state.shownProgress
        guard state.printState == "printing" || state.printState == "paused",
              p > 0.02, p < 1, state.timeElapsed > 0 else { return nil }
        let remaining = Int(Double(state.timeElapsed) / p * (1.0 - p))
        let h = remaining / 3600, m = (remaining % 3600) / 60
        let t = h > 0 ? "\(h) h \(m) min" : (m > 0 ? "\(m) min" : "< 1 min")
        return lzShared(en: "\(t) left", de: "noch \(t)", fr: "encore \(t)", es: "faltan \(t)", pt: "faltam \(t)", it: "ancora \(t)", zh: "剩余 \(t)")
    }
}

/// Progress ring with the state's symbol in the middle.
private struct LAProgressRing: View {
    let progress: Double
    let state: String
    let size: CGFloat
    let line: CGFloat
    var body: some View {
        let color = LAStyle.color(state)
        ZStack {
            Circle().stroke(color.opacity(0.22), lineWidth: line)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: LAStyle.icon(state))
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}

/// Left of the activity: the print's thumbnail (left by the app), with the
/// state as a small badge — or, without a thumbnail, the progress ring.
private struct LALeading: View {
    let image: UIImage?
    let progress: Double
    let state: String
    let size: CGFloat
    var body: some View {
        if let image {
            let color = LAStyle.color(state)
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .padding(size * 0.06)
                .frame(width: size, height: size)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    // Paused, error, done: a badge; while printing a plain dot.
                    Group {
                        if state == "printing" {
                            Circle().fill(color).frame(width: size * 0.24, height: size * 0.24)
                        } else {
                            Image(systemName: LAStyle.icon(state))
                                .font(.system(size: size * 0.2, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: size * 0.36, height: size * 0.36)
                                .background(color, in: Circle())
                        }
                    }
                    .offset(x: size * 0.1, y: size * 0.1)
                }
        } else {
            LAProgressRing(progress: progress, state: state, size: size * 0.92, line: size * 0.1)
                .frame(width: size, height: size)
        }
    }
}

/// Lock screen / banner: one slim row on the system's translucent background —
/// ring, print name, percent — and a hairline progress bar underneath.
private struct LiveActivityBannerView: View {
    let context: ActivityViewContext<PaxxMakerWidgetAttributes>
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        let state = context.state
        let color = LAStyle.color(state.printState)
        let file = context.attributes.shownFile(state)
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                LALeading(image: context.attributes.thumbnail(state),
                          progress: state.shownProgress, state: state.printState, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.isEmpty ? context.attributes.printerName : file)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(LAStyle.subtitle(context.attributes.printerName, state, showPrinter: !file.isEmpty))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(state.shownProgress * 100))%")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if let eta = LAStyle.eta(state) {
                        Text(eta)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.2))
                    Capsule()
                        .fill(color.opacity(dimmed ? 0.6 : 1))
                        .frame(width: max(3, geo.size.width * min(1, state.shownProgress)))
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // A light, see-through tint over the system blur — the wallpaper
        // shows through instead of a black block.
        .activityBackgroundTint(Color.black.opacity(0.18))
        .activitySystemActionForegroundColor(.white)
    }
}

#Preview("Notification", as: .content, using: PaxxMakerWidgetAttributes(printerName: "PaxxMaker U1", filename: "benchy.gcode")) {
    PaxxMakerWidgetLiveActivity()
} contentStates: {
    PaxxMakerWidgetAttributes.ContentState(printState: "printing", progress: 0.45, extruderTemp: 230, bedTemp: 60, timeElapsed: 2700)
    PaxxMakerWidgetAttributes.ContentState(printState: "paused",   progress: 0.72, extruderTemp: 195, bedTemp: 55, timeElapsed: 4320, filename: "benchy.gcode")
}
