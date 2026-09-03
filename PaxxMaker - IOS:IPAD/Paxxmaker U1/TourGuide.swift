import SwiftUI
import Combine

// MARK: - Interactive guided tour
// A one-time walkthrough that points at real UI and (for some steps) requires the
// user to actually tap it to advance. Spans three SwiftUI contexts — the tab bar,
// the Settings list and the printer-edit sheet — coordinated through this shared
// object plus per-context overlays.
enum TourStep: Int {
    case inactive
    case intro          // "What's new" card + OK
    case spoolman       // highlight Spoolman toggle → OK (tour switches to Settings tab)
    case printer        // highlight top printer row → OK
    case serverPush     // highlight Server Push (tour opens the printer sheet) → OK
    case finished
}

@MainActor
final class TourGuide: ObservableObject {
    @Published var step: TourStep = .inactive
    // Global-space frames of highlight targets, reported by the target views.
    @Published var spoolmanFrame: CGRect = .zero
    @Published var printerFrame: CGRect = .zero
    @Published var serverPushFrame: CGRect = .zero

    var isActive: Bool { step != .inactive && step != .finished }

    func start() { step = .intro }
    func finish() { step = .finished }

    // Every step now just needs an OK — the tour drives the navigation itself.
    func advanceFromIntro()   { if step == .intro { step = .spoolman } }
    func confirmSpoolman()    { if step == .spoolman { step = .printer } }
    func confirmPrinter()     { if step == .printer { step = .serverPush } }
    func confirmServerPush()  { if step == .serverPush { finish() } }
}

// MARK: - Frame reporting
private struct TourFrameKey: PreferenceKey {
    static var defaultValue: [TourStep: CGRect] = [:]
    static func reduce(value: inout [TourStep: CGRect], nextValue: () -> [TourStep: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Report this view's global frame so the tour overlay can highlight it.
    func tourTarget(_ step: TourStep) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: TourFrameKey.self, value: [step: geo.frame(in: .global)])
            }
        )
    }

    /// Collect reported frames into the guide (attach near the root of a context).
    func collectTourFrames(_ guide: TourGuide) -> some View {
        onPreferenceChange(TourFrameKey.self) { frames in
            if let f = frames[.spoolman] { guide.spoolmanFrame = f }
            if let f = frames[.printer] { guide.printerFrame = f }
            if let f = frames[.serverPush] { guide.serverPushFrame = f }
        }
    }
}

// MARK: - Spotlight overlay
// A dimmed layer with a rounded cutout over `hole`. When `interactive` is true,
// the hole passes touches through to the real element beneath (tap-to-advance);
// otherwise the whole thing is tappable to dismiss via the callout button.
struct TourSpotlight: View {
    let hole: CGRect?
    let interactive: Bool

    var body: some View {
        GeometryReader { geo in
            // Convert the reported global frame into this container's local space.
            let origin = geo.frame(in: .global).origin
            ZStack {
                if let hole, hole != .zero {
                    let g = hole.insetBy(dx: -8, dy: -8)
                    let cx = g.midX - origin.x
                    let cy = g.midY - origin.y
                    Rectangle()
                        .fill(Color.black.opacity(0.62))
                        .reverseMask {
                            RoundedRectangle(cornerRadius: 12)
                                .frame(width: g.width, height: g.height)
                                .position(x: cx, y: cy)
                        }
                        .allowsHitTesting(!interactive)  // let taps reach the hole
                    // A highlight ring around the target.
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white, lineWidth: 3)
                        .frame(width: g.width, height: g.height)
                        .position(x: cx, y: cy)
                        .allowsHitTesting(false)
                } else {
                    Rectangle().fill(Color.black.opacity(0.62))
                        .allowsHitTesting(!interactive)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }
}

// Cutout helper.
extension View {
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask(
            ZStack {
                Rectangle()
                mask().blendMode(.destinationOut)
            }
            .compositingGroup()
        )
    }
}

// MARK: - Callout bubble (text + optional OK button + arrow direction)
struct TourCallout: View {
    let title: String
    let text: String
    var okTitle: String? = nil          // nil → no button (waiting for a real tap)
    var onOK: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let okTitle {
                Button { onOK?() } label: {
                    Text(okTitle).fontWeight(.semibold)
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(Color.accentColor).foregroundColor(.white).cornerRadius(12)
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14)
        .padding(.horizontal, 18)
    }
}
