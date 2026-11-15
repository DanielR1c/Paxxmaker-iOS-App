import SwiftUI
import UIKit
import Combine

// iPhone Duo (Apple's foldable, iOS 27.1+): what the app needs to know to lay
// itself out for each pose — closed (cover display, like any iPhone), open
// (inner display, nearly square, 669 × 951 pt), and partially open (the fold
// becomes a "division" reserved region: tabletop when it runs across, book
// when it runs down). Everything here is inert on every other iPhone and iPad:
// `isFoldable` is false there, so no layout changes.

@MainActor
final class DuoState: ObservableObject {
    static let shared = DuoState()

    /// A foldable iPhone: a known model, or one that reported a hinge.
    @Published private(set) var isFoldable = DuoState.modelIsFoldable
    /// The inner (large) display is in use — the device is open.
    @Published private(set) var isOpen = false
    /// The hinge as the system reports it (iOS 27.1).
    @Published private(set) var hinge: Pose = .unknown
    /// The active fold, in global coordinates — only while partially open.
    @Published private(set) var fold: CGRect? = nil
    /// Camera / status cut-outs the system reserves, in global coordinates.
    @Published private(set) var occlusions: [CGRect] = []
    /// Size of the whole window.
    @Published private(set) var windowSize: CGSize = .zero

    enum Pose: Equatable { case unknown, closed, partiallyOpen, fullyOpen }

    /// Partially open with the fold running across: the top half stands up
    /// like a laptop screen, the bottom half lies flat.
    var tabletop: Bool { isOpen && fold.map { $0.width > $0.height } ?? false }
    /// Partially open with the fold running down the middle, like a book.
    var book: Bool { isOpen && fold.map { $0.height >= $0.width } ?? false }
    var isLandscape: Bool { windowSize.width > windowSize.height }

    nonisolated static let modelIsFoldable: Bool = {
        var id = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        if id.isEmpty {
            var u = utsname()
            uname(&u)
            id = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        // iPhone Duo. Later foldables report a hinge and are caught by that.
        return ["iPhone19,4"].contains(id)
    }()

    fileprivate func update(size: CGSize) {
        if windowSize != size { windowSize = size }
        // The cover display is phone-sized; the inner one is wider than any
        // phone is narrow (669 pt and up).
        let open = isFoldable && min(size.width, size.height) >= 600
        if isOpen != open { isOpen = open }
    }
    fileprivate func update(hinge new: Pose) {
        if new != .unknown, !isFoldable { isFoldable = true }
        if hinge != new { hinge = new }
    }
    fileprivate func update(fold: CGRect?, occlusions: [CGRect]) {
        if self.fold != fold { self.fold = fold }
        if self.occlusions != occlusions { self.occlusions = occlusions }
    }

    /// How far a cut-out reaches into `rect` (global) from its top-right corner —
    /// what a header there has to leave free.
    func trailingClearance(for rect: CGRect) -> CGFloat {
        guard isFoldable else { return 0 }
        var reach: CGFloat = 0
        for o in occlusions where o.intersects(rect) {
            reach = max(reach, rect.maxX - o.minX)
        }
        return max(0, reach)
    }
}

/// Watches window size, hinge and reserved regions. Applied once at the root.
struct DuoObserver: ViewModifier {
    func body(content: Content) -> some View {
        if DuoState.modelIsFoldable || ProcessInfo.processInfo.environment["PAXX_FORCE_DUO"] != nil {
            content
                .background(DuoProbe())
                .modifier(HingeWatch())
        } else if #available(iOS 27.1, *) {
            // An unknown model may still be foldable — the hinge tells.
            content.modifier(HingeWatch())
        } else {
            content
        }
    }
}

private struct HingeWatch: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, new in
                let pose: DuoState.Pose
                switch new.hinge?.status {
                case .some(.closed): pose = .closed
                case .some(.partiallyOpen): pose = .partiallyOpen
                case .some(.fullyOpen): pose = .fullyOpen
                default: pose = .unknown
                }
                DuoState.shared.update(hinge: pose)
            }
        } else {
            content
        }
    }
}

/// Reads the window's size and the system's reserved regions.
private struct DuoProbe: View {
    @ObservedObject private var duo = DuoState.shared
    var body: some View {
        GeometryReader { g in
            let size = CGSize(width: g.size.width + g.safeAreaInsets.leading + g.safeAreaInsets.trailing,
                              height: g.size.height + g.safeAreaInsets.top + g.safeAreaInsets.bottom)
            Color.clear
                .onAppear { read(g, size) }
                .onChange(of: size) { _, s in read(g, s) }
                .task(id: "\(size)|\(duo.hinge)") {
                    // Regions (the fold, the camera) settle a moment after the
                    // hinge moves — read again a few times.
                    for ms in [150, 400, 900, 1600] {
                        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                        if Task.isCancelled { return }
                        read(g, size)
                    }
                }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func read(_ g: GeometryProxy, _ size: CGSize) {
        DuoState.shared.update(size: size)
        if #available(iOS 27.1, *) {
            let origin = g.frame(in: .global).origin
            func global(_ r: CGRect) -> CGRect { r.offsetBy(dx: origin.x, dy: origin.y) }
            let fold = g.reservedRegions(kind: .division).first(where: \.isActive).map { global($0.frame) }
            let occ = g.reservedRegions(kind: .occlusion).filter(\.isActive).map { global($0.frame) }
            DuoState.shared.update(fold: fold, occlusions: occ)
            DuoCoverInsets.apply()
        }
    }
}

extension View {
    /// Root of the app: keeps `DuoState` current.
    func duoObserved() -> some View { modifier(DuoObserver()) }
}

/// Open iPhone Duo across (and the iPad): lists and forms would run ~800 pt
/// wide — hard to read. The page keeps a comfortable width in the middle.
///
/// Done with extra safe area, not `contentMargins`: content margins travel
/// down the environment into every sheet and cover opened from the page —
/// the slicer's plate view got 145 pt margins in its 176 pt tool column and
/// the column slid off the screen. A safe area stays with this page.
/// One structure for every width (no if/else around `content`): turning the
/// Duo swapped such a branch and rebuilt the tab — the slicer dropped back to
/// its first page.
private struct DuoReadableWidth: ViewModifier {
    @ObservedObject private var duo = DuoState.shared
    @State private var width: CGFloat = 0
    // iPad: see IPadReadableColumn — the extra safe area never reached the
    // lists inside the tab's navigation stack there.
    private var wideDevice: Bool { duo.isOpen }
    func body(content: Content) -> some View {
        // `width` is the page inside its safe area (the Duo's system column
        // is already left out), so equal margins centre the content there.
        let margin: CGFloat = wideDevice && width > 720 ? ((width - 660) / 2).rounded() : 0
        content
            .safeAreaPadding(.horizontal, margin)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// iPad: Settings, Spoolman and the slicer page ran the full 13" width. Put
/// INSIDE the page's navigation container (on the list), so the list becomes a
/// centred column of readable width while the navigation bar keeps its full
/// width — framing the whole page pulled its buttons into the tab bar.
private struct IPadReadableColumn: ViewModifier {
    @State private var width: CGFloat = 0
    func body(content: Content) -> some View {
        let on = UIDevice.current.userInterfaceIdiom == .pad && !DuoState.shared.isFoldable && width > 720
        content
            .frame(maxWidth: on ? 700 : .infinity)
            .frame(maxWidth: .infinity)
            .background {
                if on { Color(.systemGroupedBackground).ignoresSafeArea() }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

extension View {
    func duoReadableWidth() -> some View { modifier(DuoReadableWidth()) }
    func iPadReadableColumn() -> some View { modifier(IPadReadableColumn()) }
}


/// iPhone Duo, closed (cover display): camera, clock and the vertical tab bar
/// share one side column (84 pt). Each tab's navigation area already stops
/// before it — but the page inside is given the tab bar's width as an inset
/// once more, which left an empty band in the middle (content ended ~168 pt
/// from the edge). That second inset is taken back, only on the cover display;
/// open, other iPhones and iPad: untouched (0).
@MainActor
enum DuoCoverInsets {
    /// The side with the system column (clock, camera, the vertical tab bar)
    /// — on the iPhone Duo closed and open alike. Empty elsewhere.
    static var coverSide: Edge.Set {
        guard DuoState.shared.isFoldable,
              let win = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?.safeAreaInsets else { return [] }
        if win.right > 40 { return .trailing }
        if win.left > 40 { return .leading }
        return []
    }

    /// Inset a page had before we touched it — read while our own value was 0,
    /// so repeated calls never drift.
    private static var base: [ObjectIdentifier: UIEdgeInsets] = [:]
    /// Frame and window insets the base was read for — a new pose or size
    /// makes it stale (it then pushed a page wider than its view).
    private static var baseKey: [ObjectIdentifier: String] = [:]

    static func apply() {
        let duo = DuoState.shared
        guard let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              let tabs = findTabBarController(window.rootViewController) else { return }
        let w = window.bounds.width
        let sys = window.safeAreaInsets
        _ = duo
        let cs = coverSide
        let side = cs == .trailing ? 1 : (cs == .leading ? -1 : 0)
        let active = side != 0
        var retry = false
        // iOS 26+ tabs (UITab) leave `viewControllers` empty — the pages are children.
        for tab in tabs.children {
            for nav in navigationControllers(in: tab) {
                for page in nav.viewControllers where page.isViewLoaded {
                    let id = ObjectIdentifier(page)
                    var add = page.additionalSafeAreaInsets
                    let key = "\(page.view.convert(page.view.bounds, to: window))|\(sys)"
                    // Split screen: a page narrower than the space beside the
                    // strip never lies under the strip (the split view cuts it
                    // off there), wherever it is scrolled to — so no side
                    // inset at all, set straight away. Going through the reset
                    // below on every scroll made the pages twitch, and a page
                    // that started off screen came in narrower.
                    let frame = page.view.convert(page.view.bounds, to: window)
                    if frame.width < w - sys.left - sys.right - 1 {
                        let cur = page.view.safeAreaInsets
                        var a = add
                        if side > 0 { a.right = min(0, add.right - cur.right); a.left = 0 }
                        else if side < 0 { a.left = min(0, add.left - cur.left); a.right = 0 }
                        else { a.left = 0; a.right = 0 }
                        baseKey[id] = key
                        if a != add {
                            page.additionalSafeAreaInsets = a
                            nav.navigationBar.setNeedsLayout()
                            nav.view.setNeedsLayout()
                        }
                        // Upright (the window has a top inset), a split page's
                        // navigation puts its bar at the status bar's height —
                        // in the row of clock and camera — as long as it has no
                        // extra inset of its own; with any, it uses the safe
                        // area like a single page. So it keeps 1 pt there.
                        var navAdd = nav.additionalSafeAreaInsets
                        let navFrame = nav.view.convert(nav.view.bounds, to: window)
                        let inheritedTop = navFrame.minY + nav.view.safeAreaInsets.top - navAdd.top
                        let wantTop: CGFloat = inheritedTop > 1 ? 1 : 0
                        if navAdd.top != wantTop {
                            navAdd.top = wantTop
                            nav.additionalSafeAreaInsets = navAdd
                            nav.view.setNeedsLayout()
                        }
                        continue
                    }
                    if baseKey[id] != key {
                        baseKey[id] = key
                        if add.left != 0 || add.right != 0 {
                            // Start over from the plain inset after the next layout.
                            page.additionalSafeAreaInsets = .zero
                            retry = true
                            continue
                        }
                    }
                    if add.left == 0 && add.right == 0 { base[id] = page.view.safeAreaInsets }
                    let b = base[id] ?? page.view.safeAreaInsets
                    // How far the page really reaches into the system column.
                    let f = page.view.convert(page.view.bounds, to: window)
                    if active && side > 0 {
                        let real = max(0, f.maxX - (w - sys.right))
                        add.right = min(0, real - b.right); add.left = 0
                    } else if active && side < 0 {
                        let real = max(0, sys.left - f.minX)
                        add.left = min(0, real - b.left); add.right = 0
                    } else {
                        add.left = 0; add.right = 0
                    }
                    if add != page.additionalSafeAreaInsets {
                        page.additionalSafeAreaInsets = add
                        // The bar lays its buttons out from the old inset otherwise.
                        nav.navigationBar.setNeedsLayout()
                        nav.view.setNeedsLayout()
                    }
                }
            }
        }
        if retry { DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { apply() } }
    }

    private static func navigationControllers(in vc: UIViewController) -> [UINavigationController] {
        if let n = vc as? UINavigationController { return [n] }
        return vc.children.flatMap { navigationControllers(in: $0) }
    }

    private static func findTabBarController(_ vc: UIViewController?) -> UITabBarController? {
        guard let vc else { return nil }
        if let t = vc as? UITabBarController { return t }
        for c in vc.children { if let t = findTabBarController(c) { return t } }
        return nil
    }
}

/// iPhone Duo: how wide each printer page's trailing bar buttons are (the
/// glass capsule with lock and "…"), so the page-centred printer name keeps
/// clear of them. Keyed by the printer's service object.
@MainActor final class DuoBarMetrics: ObservableObject {
    static let shared = DuoBarMetrics()
    @Published private(set) var trailingWidth: [ObjectIdentifier: CGFloat] = [:]
    func setTrailingWidth(_ w: CGFloat, for owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        if abs((trailingWidth[id] ?? -100) - w) > 0.5 { trailingWidth[id] = w }
    }
}

/// EditButton in the app's language: the system one takes the device language,
/// so an English app on a German device said "Bearbeiten".
struct AppEditButton: View {
    @Environment(\.editMode) private var editMode
    var body: some View {
        let editing = editMode?.wrappedValue.isEditing == true
        Button(editing
               ? lz(en: "Done", de: "Fertig", fr: "OK", es: "Listo", pt: "OK", it: "Fine", zh: "完成")
               : lz(en: "Edit", de: "Bearbeiten", fr: "Modifier", es: "Editar", pt: "Editar", it: "Modifica", zh: "编辑")) {
            withAnimation { editMode?.wrappedValue = editing ? .inactive : .active }
        }
        .fontWeight(editing ? .semibold : .regular)
    }
}
