import ActivityKit
import WidgetKit
import SwiftUI

struct PaxxMakerWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PaxxMakerWidgetAttributes.self) { context in
            LiveActivityBannerView(context: context)
        } dynamicIsland: { context in
            // Minimal Dynamic Island — only a tiny progress arc + % shown
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.printerName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(Int(context.state.progress * 100))%")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(stateColor(context.state.printState))
                        .monospacedDigit()
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.secondary.opacity(0.18)).frame(height: 4)
                            Capsule()
                                .fill(stateColor(context.state.printState))
                                .frame(width: max(4, geo.size.width * context.state.progress), height: 4)
                        }
                    }
                    .frame(height: 4)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                }
            } compactLeading: {
                Image(systemName: "printer.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(stateColor(context.state.printState))
            } compactTrailing: {
                Text("\(Int(context.state.progress * 100))%")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(stateColor(context.state.printState))
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "printer.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(stateColor(context.state.printState))
            }
        }
    }

    func stateColor(_ state: String) -> Color {
        switch state {
        case "printing": return .green
        case "paused":   return .orange
        case "error":    return .red
        default:         return .secondary
        }
    }
}

private struct LiveActivityBannerView: View {
    let context: ActivityViewContext<PaxxMakerWidgetAttributes>

    private var stateColor: Color {
        switch context.state.printState {
        case "printing": return .green
        case "paused":   return .orange
        case "error":    return .red
        default:         return .secondary
        }
    }

    private var etaString: String {
        let p = context.state.progress
        let elapsed = context.state.timeElapsed
        guard p > 0.02, elapsed > 0 else { return "" }
        let remaining = Int(Double(elapsed) / p * (1.0 - p))
        let h = remaining / 3600
        let m = (remaining % 3600) / 60
        if h > 0 { return "~\(h)h \(m)m" }
        if m > 0 { return "~\(m)m" }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: stateColor.opacity(0.6), radius: 4)
                Text(context.attributes.printerName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(Int(context.state.progress * 100))%")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.15))
                        .frame(height: 6)
                    Capsule()
                        .fill(stateColor)
                        .frame(width: max(6, geo.size.width * context.state.progress), height: 6)
                }
            }
            .frame(height: 6)

            HStack {
                let shortName = (context.attributes.filename.components(separatedBy: "/").last ?? context.attributes.filename)
                    .replacingOccurrences(of: ".gcode", with: "")
                    .replacingOccurrences(of: ".gco", with: "")
                if !shortName.isEmpty {
                    Text(shortName)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer()
                if !etaString.isEmpty {
                    Text(etaString)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(16)
        .activityBackgroundTint(Color(white: 0.08))
        .activitySystemActionForegroundColor(.white)
    }
}

#Preview("Notification", as: .content, using: PaxxMakerWidgetAttributes(printerName: "PaxxMaker U1", filename: "benchy.gcode")) {
    PaxxMakerWidgetLiveActivity()
} contentStates: {
    PaxxMakerWidgetAttributes.ContentState(printState: "printing", progress: 0.45, extruderTemp: 230, bedTemp: 60, timeElapsed: 2700)
    PaxxMakerWidgetAttributes.ContentState(printState: "paused",   progress: 0.72, extruderTemp: 195, bedTemp: 55, timeElapsed: 4320)
}
