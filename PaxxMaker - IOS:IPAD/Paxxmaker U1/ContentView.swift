import SwiftUI
import WebKit
import Combine
import Darwin
import CoreNFC
import UserNotifications
import WidgetKit
import ActivityKit
import StoreKit
import WatchConnectivity
import AVKit
import AVFoundation

struct PrinterConfig: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var ip: String
    var type: PrinterType
    var isVisible: Bool = true
    var connectionMode: ConnectionMode = .local
    var octoEverywhereURL: String = ""
    var octoEverywhereAPIKey: String = ""
    var themeColor: String = "blue"
    var pushMode: PushMode = .off
    var cloudflareWorkerURL: String = ""
    var cloudflareNotifySecret: String = ""
    var smartPlugType: SmartPlugType = .tuya
    var smartPlugIP: String = ""
    var smartPlugDeviceID: String = ""
    var smartPlugLocalKey: String = ""

    enum SmartPlugType: String, Codable {
        case tuya = "tuya"
        case shelly = "shelly"
    }

    enum PushMode: String, Codable {
        case off = "off"
        case cloudflare = "cloudflare"
    }

    var effectiveBaseURL: String {
        if connectionMode == .octoEverywhere, !octoEverywhereURL.isEmpty {
            return octoEverywhereURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ip
    }

    enum ConnectionMode: String, Codable {
        case local = "local"
        case octoEverywhere = "octoeverywhere"
    }

    enum PrinterType: String, Codable, CaseIterable {
        case snapmakerU1 = "Snapmaker U1"
        case singleNozzle = "Single Nozzle"

        var extruderCount: Int {
            switch self {
            case .snapmakerU1: return 4
            case .singleNozzle: return 1
            }
        }
        var icon: String {
            switch self {
            case .snapmakerU1: return "printer.fill"
            case .singleNozzle: return "printer"
            }
        }
        var imageName: String {
            switch self {
            case .snapmakerU1: return "printer_u1"
            case .singleNozzle: return "printer_single"
            }
        }
    }
}

// MARK: - Custom GCode Command
enum PrinterTarget: String, Codable, CaseIterable {
    case both, singleNozzle, u1
    var label: String {
        switch self {
        case .both:         return lz(en: "Both", de: "Beide", fr: "Les deux", es: "Ambos")
        case .singleNozzle: return "Single Nozzle"
        case .u1:           return "Snapmaker U1"
        }
    }
    var imageName: String {
        switch self {
        case .both:         return "printer_both"
        case .singleNozzle: return "printer_single"
        case .u1:           return "printer_u1"
        }
    }
}

struct CustomCommand: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var gcode: String
    var printerTarget: PrinterTarget = .both
    var colorHex: String = "8B5CF6"
    var sfSymbol: String = "terminal.fill"
    var groupID: String = "default"

    var color: Color {
        guard colorHex.count == 6, let val = UInt64(colorHex, radix: 16) else { return .purple }
        return Color(red: Double((val >> 16) & 0xFF) / 255,
                     green: Double((val >> 8)  & 0xFF) / 255,
                     blue:  Double( val        & 0xFF) / 255)
    }
}

struct CustomCommandGroup: Identifiable, Codable {
    var id: String = UUID().uuidString
    var title: String = ""
}

// Wraps either a static DashboardTile or a dynamic custom command group tile
struct DashboardItem: Identifiable, Equatable {
    let rawID: String
    var id: String { rawID }
    var asStaticTile: DashboardTile? { DashboardTile(rawValue: rawID) }
    var customGroupID: String? { rawID.hasPrefix("cg_") ? String(rawID.dropFirst(3)) : nil }
    // Spacers: invisible placeholders that push adjacent tiles to the right
    var isSpacerItem: Bool { rawID.hasPrefix("__sp_") }
    static func tile(_ t: DashboardTile) -> DashboardItem { DashboardItem(rawID: t.rawValue) }
    static func group(_ gid: String) -> DashboardItem { DashboardItem(rawID: "cg_\(gid)") }
    // widthState 1 = half (default), 2 = third
    static func spacer(widthState: Int = 1) -> DashboardItem {
        let prefix = widthState == 2 ? "__sp_t_" : "__sp_h_"
        return DashboardItem(rawID: "\(prefix)\(UUID().uuidString)")
    }
}

// MARK: - Language
class LanguageStore: ObservableObject {
    @Published var current: String {
        didSet { UserDefaults.standard.set(current, forKey: "app_language") }
    }
    init() { current = UserDefaults.standard.string(forKey: "app_language") ?? "en" }
}

// MARK: - Theme
struct AppTheme {
    let key: String
    let color: Color
    let label: String
}

let appThemes: [AppTheme] = [
    AppTheme(key: "blue",   color: .blue,                              label: "Blue"),
    AppTheme(key: "indigo", color: .indigo,                            label: "Indigo"),
    AppTheme(key: "purple", color: .purple,                            label: "Purple"),
    AppTheme(key: "pink",   color: .pink,                              label: "Pink"),
    AppTheme(key: "red",    color: .red,                               label: "Red"),
    AppTheme(key: "orange", color: .orange,                            label: "Orange"),
    AppTheme(key: "yellow", color: Color(hue: 0.13, saturation: 0.9, brightness: 0.95), label: "Yellow"),
    AppTheme(key: "green",  color: .green,                             label: "Green"),
    AppTheme(key: "teal",   color: .teal,                              label: "Teal"),
    AppTheme(key: "mint",   color: .mint,                              label: "Mint"),
]


func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
    UIImpactFeedbackGenerator(style: style).impactOccurred()
}
func hapticNotification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
    UINotificationFeedbackGenerator().notificationOccurred(type)
}

func appTintColor() -> Color {
    let key = UserDefaults.standard.string(forKey: "app_theme_color") ?? "blue"
    return appThemes.first { $0.key == key }?.color ?? .blue
}

func lz(en: String, de: String, fr: String, es: String) -> String {
    switch UserDefaults.standard.string(forKey: "app_language") ?? "en" {
    case "de": return de
    case "fr": return fr
    case "es": return es
    default:   return en
    }
}

class SettingsStore: ObservableObject {
    @AppStorage("has_completed_onboarding") var hasCompletedOnboarding: Bool = false
    @AppStorage("selected_printer_index") var selectedPrinterIndex: Int = 0

    @Published var printers: [PrinterConfig] = [] {
        didSet { savePrinters() }
    }
    @Published var customCommands: [CustomCommand] = [] {
        didSet { saveCustomCommands() }
    }
    @Published var customCommandGroups: [CustomCommandGroup] = [] {
        didSet { saveCustomCommandGroups() }
    }

    func displayTitle(for groupID: String) -> String {
        let group = customCommandGroups.first { $0.id == groupID }
        let t = group?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? lz(en: "My Commands", de: "Eigene Befehle", fr: "Mes commandes", es: "Mis comandos") : t
    }

    var printer1IP: String {
        get { printers.first?.ip ?? "http://192.168.178.70" }
        set {
            if printers.isEmpty {
                printers.append(PrinterConfig(name: "Snapmaker U1", ip: newValue, type: .snapmakerU1))
            } else {
                printers[0].ip = newValue
            }
        }
    }
    var printer1Name: String {
        get { printers.first?.name ?? "Snapmaker U1" }
        set {
            if printers.isEmpty {
                printers.append(PrinterConfig(name: newValue, ip: "http://192.168.178.70", type: .snapmakerU1))
            } else {
                printers[0].name = newValue
            }
        }
    }

    init() {
        loadPrinters()
        loadCustomCommands()
        loadCustomCommandGroups()
        if printers.isEmpty {
            printers = [PrinterConfig(name: "Snapmaker U1", ip: "http://192.168.178.70", type: .snapmakerU1)]
        }
    }

    func savePrinters() {
        if let data = try? JSONEncoder().encode(printers) {
            UserDefaults.standard.set(data, forKey: "printers_config")
        }
        // Keep widget list in sync: remove entries for deleted printers
        let activeNames = Set(printers.map { $0.name })
        if let defaults = UserDefaults(suiteName: "group.paxxmaker.u1"),
           let raw = defaults.data(forKey: "w_all_printers"),
           var all = try? JSONDecoder().decode([PrinterWidgetEntryData].self, from: raw) {
            let before = all.count
            all.removeAll { !activeNames.contains($0.id) }
            if all.count != before, let encoded = try? JSONEncoder().encode(all) {
                defaults.set(encoded, forKey: "w_all_printers")
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    func loadPrinters() {
        if let data = UserDefaults.standard.data(forKey: "printers_config"),
           let decoded = try? JSONDecoder().decode([PrinterConfig].self, from: data) {
            printers = decoded
        }
    }

    func saveCustomCommands() {
        if let data = try? JSONEncoder().encode(customCommands) {
            UserDefaults.standard.set(data, forKey: "custom_commands")
        }
    }

    func loadCustomCommands() {
        if let data = UserDefaults.standard.data(forKey: "custom_commands"),
           let decoded = try? JSONDecoder().decode([CustomCommand].self, from: data) {
            customCommands = decoded
            return
        }
        // First run: load examples so user sees the expected format
        customCommands = [
            CustomCommand(
                name: lz(en: "Example: Klipper Macro", de: "Beispiel: Klipper Makro", fr: "Exemple: Macro Klipper", es: "Ejemplo: Macro Klipper"),
                gcode: "MY_MACRO PARAM=value",
                printerTarget: .both, colorHex: "8B5CF6", sfSymbol: "terminal.fill"),
            CustomCommand(
                name: lz(en: "Example: Console Command", de: "Beispiel: Konsolenbefehl", fr: "Exemple: Commande console", es: "Ejemplo: Comando consola"),
                gcode: "M503",
                printerTarget: .both, colorHex: "14B8A6", sfSymbol: "chevron.right.2"),
        ]
    }

    func saveCustomCommandGroups() {
        if let data = try? JSONEncoder().encode(customCommandGroups) {
            UserDefaults.standard.set(data, forKey: "custom_command_groups")
        }
    }

    func loadCustomCommandGroups() {
        if let data = UserDefaults.standard.data(forKey: "custom_command_groups"),
           let decoded = try? JSONDecoder().decode([CustomCommandGroup].self, from: data),
           !decoded.isEmpty {
            customCommandGroups = decoded
            return
        }
        // Migrate legacy single-tile title
        let legacyTitle = UserDefaults.standard.string(forKey: "custom_tile_title") ?? ""
        customCommandGroups = [CustomCommandGroup(id: "default", title: legacyTitle)]
    }
}

// MARK: - WebView
struct WebView: UIViewRepresentable {
    let url: URL
    var fitWidth: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        if fitWidth {
            webView.scrollView.isScrollEnabled = false
            webView.scrollView.contentInsetAdjustmentBehavior = .never
        } else {
            webView.allowsBackForwardNavigationGestures = true
        }
        context.coordinator.loadedURL = url
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only reload if the URL actually changed to avoid interrupting WebRTC streams
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            webView.load(URLRequest(url: url))
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard webView.scrollView.isScrollEnabled == false else { return }
            let js = """
            (function() {
                var s = document.createElement('style');
                s.textContent = 'html, body { margin: 0 !important; padding: 0 !important; }';
                document.head.appendChild(s);
                var sw = document.documentElement.scrollWidth;
                var vw = window.innerWidth;
                if (sw > 0 && vw > 0 && Math.abs(sw - vw) > 2) {
                    document.documentElement.style.zoom = (vw / sw);
                }
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}

// MARK: - FullscreenWebView
struct FullscreenWebView: View {
    let url: URL
    @State private var isFullscreen = false
    var body: some View {
        ZStack(alignment: .topTrailing) {
            WebView(url: url).ignoresSafeArea(isFullscreen ? .all : [])
            Button(action: {
                withAnimation(.easeInOut(duration: 0.3)) { isFullscreen.toggle() }
            }) {
                Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white).padding(10)
                    .background(Color.black.opacity(0.5)).clipShape(Circle())
            }
            .padding(isFullscreen ? 16 : 12)
        }
        .statusBar(hidden: isFullscreen)
    }
}

// MARK: - Models
struct PrinterFile: Identifiable {
    let id = UUID()
    let filename: String
    let size: Int
    let modified: Double
    var displayName: String { filename.replacingOccurrences(of: ".gcode", with: "") }
    var formattedSize: String {
        let kb = Double(size) / 1024
        return kb > 1024 ? String(format: "%.1f MB", kb/1024) : String(format: "%.0f KB", kb)
    }
    var formattedDate: String {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: modified))
    }
}

// Codable mirror of PrinterWidgetEntry — keeps widget data in sync without importing the widget target
private struct PrinterWidgetEntryData: Codable {
    var id: String; var name: String; var printState: String; var filename: String
    var progress: Double; var extruderTemp: Double; var bedTemp: Double
    var timeElapsed: Int; var themeHex: String
    var spoolSlots: [SlotMirror]?
    var motorTempX: Double?
    var motorTempY: Double?
    var chamberTemp: Double?
    var extruderTemps: [Double]?

    // Mirrors SpoolSlotData from PaxxMakerShared (same JSON keys)
    struct SlotMirror: Codable {
        var colorHex: String; var material: String; var detected: Bool
    }
}

// MARK: - Live Activity Attributes (must match PaxxMakerShared.swift in widget target)
struct PaxxMakerWidgetAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var printState: String
        var progress: Double
        var extruderTemp: Double
        var bedTemp: Double
        var timeElapsed: Int
    }
    var printerName: String
    var filename: String
}

struct FilamentSlot: Identifiable {
    let id: Int
    var color: Color
    var colorHex: String
    var material: String
    var detected: Bool
}

// MARK: - Color Extensions
extension Color {
    init?(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard h.count == 6, let val = UInt64(h, radix: 16) else { return nil }
        self.init(red: Double((val >> 16) & 0xFF)/255,
                  green: Double((val >> 8) & 0xFF)/255,
                  blue: Double(val & 0xFF)/255)
    }

    func toHex() -> String? {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return String(format: "%02X%02X%02X", Int(r*255), Int(g*255), Int(b*255))
    }
    var hexString: String { toHex() ?? "888888" }
}

// MARK: - Array Safe Subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - PrinterService
class PrinterService: ObservableObject {
    @Published var baseURL: String
    let name: String
    @Published var extruderCount: Int

    @Published var printState: String = "unknown"
    @Published var filename: String = ""
    @Published var progress: Double = 0.0
    @Published var extruderTemps: [Double] = [0.0, 0.0, 0.0, 0.0]
    @Published var extruderTargets: [Double] = [0.0, 0.0, 0.0, 0.0]
    @Published var bedTemp: Double = 0.0
    @Published var bedTarget: Double = 0.0
    @Published var chamberTemp: Double = 0.0
    @Published var hasChamber: Bool = false
    @Published var lastGCodeError: String? = nil
    @Published var fanSpeed: Double = 0.0
    @Published var cavityFanSpeed: Double = 0.0
    @Published var chamberLedOn: Bool = false
    @Published var isGCodeRunning: Bool = false   // idle_timeout.state == "Printing" outside of an actual file print
    @Published var speedFactor: Double = 1.0
    @Published var extrudeFactor: Double = 1.0
    @Published var motorTempX: Double? = nil
    @Published var motorTempY: Double? = nil
    @Published var mcuTemp: Double? = nil
    @Published var piTemp: Double? = nil
    @Published var currentDraw: Double = 0
    @Published var purifierDetected: Bool = false
    @Published var purifierExhaustSpeed: Double = 0
    @Published var purifierInnerSpeed: Double = 0
    @Published var purifierInnerRPM: Double = 0
    @Published var printTimeElapsed: Int = 0
    @Published var isLoading: Bool = false
    @Published var files: [PrinterFile] = []
    @Published var isLoadingFiles: Bool = false
    @Published var fileError: String? = nil
    @Published var fileThumbnails: [String: URL] = [:]
    @Published var filamentSlots: [FilamentSlot] = (0..<4).map {
        FilamentSlot(id: $0, color: .gray, colorHex: "888888", material: "–", detected: false)
    }
    @Published var nozzleDiameters: [Double] = [0.4, 0.4, 0.4, 0.4]
    @Published var nozzleDiametersLoaded: [Bool] = [false, false, false, false]
    @Published var switchCounts: [Int] = [0, 0, 0, 0]
    @Published var activeExtruderIndex: Int = -1
    @Published var isOnline: Bool = false
    @Published var lastSeenDate: Date? = nil
    @Published var printTimeRemaining: Int = 0
    @Published var extruderTempHistories: [[Double]] = Array(repeating: [], count: 4)
    @Published var bedTempHistory: [Double] = []
    var apiKey: String = ""
    var themeHex: String = "0A84FF"
    var printerType: PrinterConfig.PrinterType = .snapmakerU1
    @Published var singleNozzleFilamentColorHex: String = "FF8800"
    @Published var webcamConfigured: Bool = true  // true until API confirms no camera
    @Published var webcamStreamURL: URL?
    @Published var webcamRotation: Int = 0
    @Published var webcamMirrorH: Bool = false
    @Published var webcamMirrorV: Bool = false
    @Published var webcam2StreamURL: URL?
    @Published var webcam2Rotation: Int = 0
    @Published var webcam2MirrorH: Bool = false
    @Published var webcam2MirrorV: Bool = false
    private var webcamConfigLoaded = false
    @Published var totalJobs: Int = 0
    @Published var totalPrintTime: Double = 0
    @Published var totalFilamentUsedMm: Double = 0
    @Published var longestPrintTime: Double = 0

    var pushMode: PrinterConfig.PushMode = .off
    var cloudflareNotifySecret: String = ""
    var smartPlugType: PrinterConfig.SmartPlugType = .tuya
    var smartPlugIP: String = ""
    var smartPlugDeviceID: String = ""
    var smartPlugLocalKey: String = ""

    private var timer: Timer?
    private var filamentPollTick: Int = 0
    private var previousPrintState: String = "unknown"
    private var previousFilamentDetected: Bool? = nil
    private var currentPollInterval: TimeInterval = 3.0
    private var currentActivity: Activity<PaxxMakerWidgetAttributes>?
    private var activityTokenTask: Task<Void, Never>?

    init(baseURL: String, name: String, extruderCount: Int = 4, printerType: PrinterConfig.PrinterType = .snapmakerU1, apiKey: String = "") {
        self.baseURL = baseURL
        self.name = name
        self.extruderCount = extruderCount
        self.printerType = printerType
        self.apiKey = apiKey
        self.singleNozzleFilamentColorHex = UserDefaults.standard.string(forKey: "sn_filament_\(name)") ?? "FF8800"
        startPolling()
    }
    deinit { timer?.invalidate() }

    var offlineSinceLabel: String {
        guard let date = lastSeenDate else {
            return lz(en: "Offline", de: "Offline", fr: "Hors ligne", es: "Sin conexión")
        }
        let s = Int(-date.timeIntervalSinceNow)
        if s < 10 { return lz(en: "just now", de: "gerade eben", fr: "à l'instant", es: "ahora") }
        if s < 60 { return "\(s)s" }
        let m = s / 60
        return m < 60 ? "\(m)m" : "\(m/60)h \(m%60)m"
    }

    var isDemoMode: Bool { baseURL == "__demo__" }

    /// True when the printer is busy and shouldn't receive new commands.
    var isBusy: Bool { printState == "printing" || isGCodeRunning }

    func startPolling() {
        timer?.invalidate()
        registerInWidgetList()
        if isDemoMode {
            loadDemoData()
            return
        }
        fetchStatus()
        fetchHistoryTotals()
        if printerType == .snapmakerU1 {
            fetchFilamentSlots()
            fetchU1ExtendedStatus()
        }
        if !webcamConfigLoaded {
            fetchWebcamConfig()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.fetchStatus()
            if self.printerType == .snapmakerU1 {
                self.fetchU1ExtendedStatus()
                self.filamentPollTick += 1
                if self.filamentPollTick % 10 == 0 { self.fetchFilamentSlots() }
            }
        }
    }

    private func loadDemoData() {
        // Values match the demo screenshots (bracket print, extruder 1 active at 235°C)
        isOnline = true
        printState = "printing"
        filename = "support_bracket_v3.gcode"
        progress = 0.92
        extruderTemps   = [235.0, 30.0, 28.0, 27.0]
        extruderTargets = [235.0,  0.0,  0.0,  0.0]
        bedTemp = 70.0
        bedTarget = 70.0
        chamberTemp = 48.0
        hasChamber = true
        chamberLedOn = true
        fanSpeed = 0.7
        cavityFanSpeed = 0.5
        speedFactor = 1.0
        extrudeFactor = 1.0
        printTimeElapsed = 13_110   // ~3h 38m (derived: 1140s remaining / 8%)
        printTimeRemaining = 1_140  // 0h 19m
        activeExtruderIndex = 0     // extruder 1 (0-based)
        purifierDetected = true
        purifierExhaustSpeed = 0.0
        nozzleDiameters = [0.4, 0.4, 0.4, 0.8]
        switchCounts = [276, 163, 255, 208]
        totalJobs = 47
        totalPrintTime = 1_260_000
        longestPrintTime = 64_800
        totalFilamentUsedMm = 487_000
        filamentSlots = [
            FilamentSlot(id: 0, color: Color(hex: "F0F0F0") ?? .white,  colorHex: "F0F0F0", material: "Generic PETG",  detected: true),
            FilamentSlot(id: 1, color: Color(hex: "1A1A1A") ?? .black,  colorHex: "1A1A1A", material: "Generic PLA",   detected: true),
            FilamentSlot(id: 2, color: Color(hex: "D42020") ?? .red,    colorHex: "D42020", material: "PLA SnapSpeed", detected: true),
            FilamentSlot(id: 3, color: Color(hex: "F0F0F0") ?? .white,  colorHex: "F0F0F0", material: "Generic PETG",  detected: true),
        ]
        extruderTempHistories = [
            (0..<40).map { _ in Double.random(in: 233...237) },
            Array(repeating: 30.0, count: 40),
            Array(repeating: 28.0, count: 40),
            Array(repeating: 27.0, count: 40),
        ]
        bedTempHistory = (0..<40).map { _ in Double.random(in: 69.5...70.5) }
    }

    func fetchWebcamConfig() {
        guard !isDemoMode, let url = URL(string: "\(baseURL)/server/webcams/list") else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        let base = self.baseURL
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let webcams = result["webcams"] as? [[String: Any]] else { return }

            func buildURL(_ entry: [String: Any]) -> URL? {
                let path = entry["stream_url"] as? String ?? ""
                guard !path.isEmpty else { return nil }
                return URL(string: path.hasPrefix("http") ? path : "\(base)\(path)")
            }

            // Filter out screen/display feeds (Snapmaker has a touchscreen feed).
            // Keep enabled cameras first, disabled cameras as fallback.
            // Use positional ordering — cam1 = index 0, cam2 = index 1 — so the result
            // matches whatever order Moonraker / Klipper exposes, independent of URL patterns.
            let filtered = webcams.filter {
                let p = ($0["stream_url"] as? String ?? "").lowercased()
                let n = ($0["name"] as? String ?? "").lowercased()
                return !p.contains("/screen") && !n.contains("screen")
            }

            guard let cam = filtered.first else {
                DispatchQueue.main.async {
                    self?.webcamConfigured = false
                    self?.webcamStreamURL = nil
                    self?.webcam2StreamURL = nil
                    self?.webcamConfigLoaded = true
                }
                return
            }

            let cam2Entry: [String: Any]? = filtered.count > 1 ? filtered[1] : nil

            DispatchQueue.main.async {
                self?.webcamConfigured = true
                self?.webcamStreamURL = buildURL(cam)
                self?.webcamRotation = cam["rotation"] as? Int ?? 0
                self?.webcamMirrorH = cam["flip_horizontal"] as? Bool ?? false
                self?.webcamMirrorV = cam["flip_vertical"] as? Bool ?? false
                self?.webcam2StreamURL = cam2Entry.flatMap { buildURL($0) }
                self?.webcam2Rotation = cam2Entry?["rotation"] as? Int ?? 0
                self?.webcam2MirrorH = cam2Entry?["flip_horizontal"] as? Bool ?? false
                self?.webcam2MirrorV = cam2Entry?["flip_vertical"] as? Bool ?? false
                self?.webcamConfigLoaded = true
            }
        }.resume()
    }

    func fetchHistoryTotals() {
        guard let req = authorizedRequest(for: "\(baseURL)/server/history/totals") else { return }
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let totals = result["job_totals"] as? [String: Any] else { return }
            let jobs = totals["total_jobs"] as? Int ?? 0
            let printTime = totals["total_print_time"] as? Double ?? 0
            let filament = totals["total_filament_used"] as? Double ?? 0
            let longest = totals["longest_print"] as? Double ?? 0
            DispatchQueue.main.async {
                self?.totalJobs = jobs
                self?.totalPrintTime = printTime
                self?.totalFilamentUsedMm = filament
                self?.longestPrintTime = longest
            }
        }.resume()
    }


    func registerInWidgetList() {
        guard let defaults = UserDefaults(suiteName: "group.paxxmaker.u1") else { return }
        var all = (try? JSONDecoder().decode([PrinterWidgetEntryData].self,
                                             from: defaults.data(forKey: "w_all_printers") ?? Data())) ?? []
        if !all.contains(where: { $0.id == name }) {
            let placeholder = PrinterWidgetEntryData(
                id: name, name: name, printState: "unknown", filename: "",
                progress: 0, extruderTemp: 0, bedTemp: 0, timeElapsed: 0, themeHex: themeHex
            )
            all.append(placeholder)
            if let encoded = try? JSONEncoder().encode(all) {
                defaults.set(encoded, forKey: "w_all_printers")
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func authorizedRequest(for urlString: String, method: String = "GET") -> URLRequest? {
        guard !isDemoMode, let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        return req
    }

    private func updateIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<PrinterService, T>, _ newValue: T) {
        if self[keyPath: keyPath] != newValue { self[keyPath: keyPath] = newValue }
    }

    func fetchStatus() {
        let query: String
        if printerType == .singleNozzle {
            query = "print_stats&toolhead&extruder&heater_bed&display_status&virtual_sdcard&fan&gcode_move&temperature_sensor%20Board_MCU&temperature_host%20Raspberry_Pi&filament_switch_sensor%20RunoutSensor&configfile"
        } else {
            // Only guaranteed-to-exist Moonraker objects — optional U1 hardware is queried separately
            query = "print_stats&toolhead&extruder&extruder1&extruder2&extruder3&heater_bed&display_status&virtual_sdcard&temperature_sensor%20cavity&fan&fan_generic%20cavity_fan&gcode_move&led%20cavity_led&idle_timeout"
        }
        guard let req = authorizedRequest(for: "\(baseURL)/printer/objects/query?\(query)") else { return }
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let status = result["status"] as? [String: Any] else {
                DispatchQueue.main.async { self.updateIfChanged(\.isOnline, false) }
                return
            }
            DispatchQueue.main.async {
                self.updateIfChanged(\.isOnline, true)
                self.lastSeenDate = Date()
                let prevState = self.previousPrintState
                let ps = status["print_stats"] as? [String: Any]
                if let ps {
                    self.updateIfChanged(\.printState, ps["state"] as? String ?? "unknown")
                    self.updateIfChanged(\.filename, ps["filename"] as? String ?? "")
                    self.updateIfChanged(\.printTimeElapsed, Int(ps["print_duration"] as? Double ?? 0))
                }
                // display_status.progress matches what Mainsail/Klipper display shows (respects M73 gcode commands).
                // Falls back to virtual_sdcard.progress when display_status isn't set.
                let dispProg = (status["display_status"] as? [String: Any])?["progress"] as? Double
                let vsdProg  = (status["virtual_sdcard"] as? [String: Any])?["progress"] as? Double ?? 0.0
                self.updateIfChanged(\.progress, dispProg ?? vsdProg)
                let extruderKeys = ["extruder", "extruder1", "extruder2", "extruder3"]
                for (i, key) in extruderKeys.enumerated() {
                    if let ex = status[key] as? [String: Any] {
                        let temp = ex["temperature"] as? Double ?? 0.0
                        let target = ex["target"] as? Double ?? 0.0
                        if self.extruderTemps[i] != temp { self.extruderTemps[i] = temp }
                        if self.extruderTargets[i] != target { self.extruderTargets[i] = target }
                        if let nozzle = ex["nozzle_diameter"] as? Double {
                            if self.nozzleDiameters[i] != nozzle { self.nozzleDiameters[i] = nozzle }
                            self.nozzleDiametersLoaded[i] = true
                        }
                        if let sc = ex["switch_count"] as? Int, self.switchCounts[i] != sc {
                            self.switchCounts[i] = sc
                        }
                    }
                }
                if let bed = status["heater_bed"] as? [String: Any] {
                    self.updateIfChanged(\.bedTemp, bed["temperature"] as? Double ?? 0.0)
                    self.updateIfChanged(\.bedTarget, bed["target"] as? Double ?? 0.0)
                }
                if let cavity = status["temperature_sensor cavity"] as? [String: Any],
                   let temp = cavity["temperature"] as? Double {
                    self.updateIfChanged(\.hasChamber, true)
                    self.updateIfChanged(\.chamberTemp, temp)
                }
                if let fan = status["fan"] as? [String: Any] {
                    self.updateIfChanged(\.fanSpeed, fan["speed"] as? Double ?? 0.0)
                }
                if let th = status["toolhead"] as? [String: Any],
                   let activeKey = th["extruder"] as? String {
                    let keys = ["extruder", "extruder1", "extruder2", "extruder3"]
                    self.updateIfChanged(\.activeExtruderIndex, keys.firstIndex(of: activeKey) ?? -1)
                } else {
                    self.updateIfChanged(\.activeExtruderIndex, -1)
                }
                if let gm = status["gcode_move"] as? [String: Any] {
                    self.updateIfChanged(\.speedFactor, gm["speed_factor"] as? Double ?? 1.0)
                    self.updateIfChanged(\.extrudeFactor, gm["extrude_factor"] as? Double ?? 1.0)
                }
                // LED state from Moonraker: color_data is [[R, G, B, W]] — W > 0 means on
                if let led = status["led cavity_led"] as? [String: Any],
                   let colorData = led["color_data"] as? [[Double]],
                   let firstPixel = colorData.first {
                    let isOn = firstPixel.contains(where: { $0 > 0.01 })
                    self.updateIfChanged(\.chamberLedOn, isOn)
                }
                if let cf = status["fan_generic cavity_fan"] as? [String: Any] {
                    self.updateIfChanged(\.cavityFanSpeed, cf["speed"] as? Double ?? 0.0)
                }
                // idle_timeout.state == "Printing" means GCode is actively running
                // (homing, calibration, etc.) — distinct from an actual file print
                if let it = status["idle_timeout"] as? [String: Any],
                   let itState = it["state"] as? String {
                    let gcodeActive = itState == "Printing" && self.printState != "printing"
                    self.updateIfChanged(\.isGCodeRunning, gcodeActive)
                }
                if let mcuSensor = status["temperature_sensor Board_MCU"] as? [String: Any] {
                    self.mcuTemp = mcuSensor["temperature"] as? Double
                }
                if let piSensor = status["temperature_host Raspberry_Pi"] as? [String: Any] {
                    self.piTemp = piSensor["temperature"] as? Double
                }
                if self.printerType == .singleNozzle,
                   let runout = status["filament_switch_sensor RunoutSensor"] as? [String: Any] {
                    let detected = runout["filament_detected"] as? Bool ?? false
                    self.filamentSlots[0] = FilamentSlot(
                        id: 0,
                        color: detected ? (Color(hex: self.singleNozzleFilamentColorHex) ?? .orange) : .gray,
                        colorHex: detected ? self.singleNozzleFilamentColorHex : "888888",
                        material: detected ? lz(en: "Inserted", de: "Eingelegt", fr: "Inséré", es: "Insertado") : "–",
                        detected: detected)
                }
                if self.printerType == .singleNozzle,
                   let cf = status["configfile"] as? [String: Any],
                   let config = cf["config"] as? [String: Any],
                   let extruder = config["extruder"] as? [String: Any] {
                    let nozzle: Double? = (extruder["nozzle_diameter"] as? Double)
                        ?? ((extruder["nozzle_diameter"] as? String).flatMap { Double($0) })
                    if let n = nozzle, self.nozzleDiameters[0] != n {
                        self.nozzleDiameters[0] = n
                        self.nozzleDiametersLoaded[0] = true
                    }
                }
                if prevState == "printing" && self.printState == "complete" {
                    let bgDefaults = UserDefaults(suiteName: "group.paxxmaker.u1")
                    let bgHandled = (bgDefaults?.dictionary(forKey: "bg_prev_print_states") as? [String: String])?[self.name] == "complete"
                    if !bgHandled {
                        self.sendLocalNotification(
                            title: lz(en: "Print done!", de: "Druck fertig!", fr: "Impression terminée!", es: "¡Impresión lista!"),
                            body: self.filename.isEmpty ? self.name : "\(self.filename) · \(self.name)",
                            identifier: "print-done-\(self.name)"
                        )
                        hapticNotification(.success)
                    }
                } else if prevState == "printing" && self.printState == "error" {
                    let bgDefaults = UserDefaults(suiteName: "group.paxxmaker.u1")
                    let bgHandled = (bgDefaults?.dictionary(forKey: "bg_prev_print_states") as? [String: String])?[self.name] == "error"
                    if !bgHandled {
                        self.sendLocalNotification(
                            title: lz(en: "Print error", de: "Druckfehler", fr: "Erreur d'impression", es: "Error de impresión"),
                            body: "\(self.name)" + (self.filename.isEmpty ? "" : ": \(self.filename)"),
                            identifier: "print-err-\(self.name)"
                        )
                        hapticNotification(.error)
                    }
                } else if (prevState == "printing" || prevState == "paused") && self.printState == "cancelled" {
                    let bgDefaults = UserDefaults(suiteName: "group.paxxmaker.u1")
                    let bgHandled = (bgDefaults?.dictionary(forKey: "bg_prev_print_states") as? [String: String])?[self.name] == "cancelled"
                    if !bgHandled {
                        self.sendLocalNotification(
                            title: lz(en: "Print cancelled", de: "Druck abgebrochen", fr: "Impression annulée", es: "Impresión cancelada"),
                            body: "\(self.name)" + (self.filename.isEmpty ? "" : ": \(self.filename)"),
                            identifier: "print-cancelled-\(self.name)"
                        )
                        hapticNotification(.warning)
                    }
                }
                self.previousPrintState = self.printState

                if self.progress > 0.01 && self.printTimeElapsed > 0 {
                    let eta = Int(Double(self.printTimeElapsed) / self.progress * (1.0 - self.progress))
                    self.updateIfChanged(\.printTimeRemaining, eta)
                } else {
                    self.updateIfChanged(\.printTimeRemaining, 0)
                }

                let headCount = min(self.extruderTemps.count, 4)
                for i in 0..<headCount {
                    self.extruderTempHistories[i].append(self.extruderTemps[i])
                    if self.extruderTempHistories[i].count > 20 { self.extruderTempHistories[i].removeFirst() }
                }
                self.bedTempHistory.append(self.bedTemp)
                if self.bedTempHistory.count > 20 { self.bedTempHistory.removeFirst() }

                if self.printerType == .singleNozzle {
                    let nowDetected = self.filamentSlots[0].detected
                    if let prev = self.previousFilamentDetected, prev == true && nowDetected == false {
                        self.sendLocalNotification(
                            title: lz(en: "Filament runout!", de: "Filament leer!", fr: "Plus de filament !", es: "¡Filamento agotado!"),
                            body: self.name
                        )
                        hapticNotification(.warning)
                    }
                    self.previousFilamentDetected = nowDetected
                }

                let desiredInterval: TimeInterval = (self.printState == "printing") ? 1.0 : 8.0
                if desiredInterval != self.currentPollInterval {
                    self.currentPollInterval = desiredInterval
                    self.timer?.invalidate()
                    self.timer = Timer.scheduledTimer(withTimeInterval: desiredInterval, repeats: true) { [weak self] _ in
                        guard let self else { return }
                        self.fetchStatus()
                        if self.printerType == .snapmakerU1 {
                            self.fetchU1ExtendedStatus()
                            self.filamentPollTick += 1
                            if self.filamentPollTick % 10 == 0 { self.fetchFilamentSlots() }
                        }
                    }
                }

                if prevState != self.printState || self.printState == "printing" {
                    self.writeWidgetData()
                }
                self.updateLiveActivity(prevState: prevState)
            }
        }.resume()
    }

    func fetchU1ExtendedStatus() {
        guard printerType == .snapmakerU1 else { return }
        let query = "fan_generic%20cavity_fan&purifier&tmc2240%20stepper_x&tmc2240%20stepper_y&adc_current_sensor%20I_AD"
        guard let req = authorizedRequest(for: "\(baseURL)/printer/objects/query?\(query)") else { return }
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self,
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let status = result["status"] as? [String: Any] else { return }
            DispatchQueue.main.async {
                if let cf = status["fan_generic cavity_fan"] as? [String: Any] {
                    self.updateIfChanged(\.cavityFanSpeed, cf["speed"] as? Double ?? 0.0)
                }
                if let pur = status["purifier"] as? [String: Any] {
                    self.updateIfChanged(\.purifierDetected, pur["power_detected"] as? Bool ?? false)
                    if let ex = pur["exhaust_fan"] as? [String: Any] {
                        self.updateIfChanged(\.purifierExhaustSpeed, ex["speed"] as? Double ?? 0)
                    }
                    if let inn = pur["inner_fan"] as? [String: Any] {
                        self.updateIfChanged(\.purifierInnerSpeed, inn["speed"] as? Double ?? 0)
                        self.updateIfChanged(\.purifierInnerRPM, inn["rpm"] as? Double ?? 0)
                    }
                }
                if let tmcX = status["tmc2240 stepper_x"] as? [String: Any] {
                    self.motorTempX = tmcX["temperature"] as? Double
                }
                if let tmcY = status["tmc2240 stepper_y"] as? [String: Any] {
                    self.motorTempY = tmcY["temperature"] as? Double
                }
                if let adc = status["adc_current_sensor I_AD"] as? [String: Any] {
                    self.updateIfChanged(\.currentDraw, adc["current"] as? Double ?? 0)
                }

            }
        }.resume()
    }

    func writeWidgetData() {
        guard let defaults = UserDefaults(suiteName: "group.paxxmaker.u1") else { return }
        let slots = filamentSlots.map { slot -> PrinterWidgetEntryData.SlotMirror in
            let safeHex = slot.detected ? slot.colorHex : "888888"
            return PrinterWidgetEntryData.SlotMirror(colorHex: safeHex, material: slot.material, detected: slot.detected)
        }
        let entry = PrinterWidgetEntryData(
            id: name, name: name, printState: printState, filename: filename,
            progress: progress, extruderTemp: extruderTemps[0], bedTemp: bedTemp,
            timeElapsed: printTimeElapsed, themeHex: themeHex, spoolSlots: slots,
            motorTempX: motorTempX, motorTempY: motorTempY,
            chamberTemp: hasChamber ? chamberTemp : nil,
            extruderTemps: Array(extruderTemps.prefix(4))
        )
        var all = (try? JSONDecoder().decode([PrinterWidgetEntryData].self,
                                             from: defaults.data(forKey: "w_all_printers") ?? Data())) ?? []
        if let idx = all.firstIndex(where: { $0.id == name }) { all[idx] = entry } else { all.append(entry) }
        if let encoded = try? JSONEncoder().encode(all) {
            defaults.set(encoded, forKey: "w_all_printers")
            // Forward latest state to paired Apple Watch
            if WCSession.isSupported(),
               WCSession.default.activationState == .activated,
               WCSession.default.isPaired {
                try? WCSession.default.updateApplicationContext(["printers": encoded])
            }
        }
        if printState != previousPrintState { WidgetCenter.shared.reloadAllTimelines() }
        var bgStates = (defaults.dictionary(forKey: "bg_prev_print_states") as? [String: String]) ?? [:]
        if bgStates[name] != printState { bgStates[name] = printState; defaults.set(bgStates, forKey: "bg_prev_print_states") }

        // Write connection config so the Watch app can poll independently
        struct WatchDirectConfig: Codable {
            var id: String; var name: String; var baseURL: String; var apiKey: String; var themeHex: String
            var cfSecret: String?
            var pushMode: String?   // "cloudflare" only when server push is active
        }
        let cfg = WatchDirectConfig(
            id: name, name: name, baseURL: baseURL, apiKey: apiKey, themeHex: themeHex,
            cfSecret: cloudflareNotifySecret.isEmpty ? nil : cloudflareNotifySecret,
            pushMode: (pushMode == .cloudflare && !cloudflareNotifySecret.isEmpty) ? "cloudflare" : nil
        )
        var allCfgs = (try? JSONDecoder().decode([WatchDirectConfig].self,
                                                  from: defaults.data(forKey: "watch_printer_configs") ?? Data())) ?? []
        if let i = allCfgs.firstIndex(where: { $0.id == name }) { allCfgs[i] = cfg } else { allCfgs.append(cfg) }
        if let encoded = try? JSONEncoder().encode(allCfgs) { defaults.set(encoded, forKey: "watch_printer_configs") }
    }

    func updateLiveActivity(prevState: String) {
        let state = PaxxMakerWidgetAttributes.ContentState(
            printState: printState, progress: progress,
            extruderTemp: extruderTemps[0], bedTemp: bedTemp, timeElapsed: printTimeElapsed
        )
        if prevState != "printing" && printState == "printing" {
            let usePush = pushMode == .cloudflare && !cloudflareNotifySecret.isEmpty
            // Reuse existing Live Activity for this printer if one already exists (e.g. after app restart)
            if let existing = Activity<PaxxMakerWidgetAttributes>.activities.first(where: { $0.attributes.printerName == name }) {
                currentActivity = existing
                Task { await currentActivity?.update(.init(state: state, staleDate: nil)) }
                if usePush && activityTokenTask == nil { startObservingActivityToken() }
            } else {
                let attrs = PaxxMakerWidgetAttributes(printerName: name, filename: filename)
                let pt: ActivityKit.PushType? = usePush ? .token : nil
                currentActivity = try? Activity.request(attributes: attrs, content: .init(state: state, staleDate: nil), pushType: pt)
                if usePush { startObservingActivityToken() }
            }
        } else if printState == "printing" || printState == "paused" {
            Task { await currentActivity?.update(.init(state: state, staleDate: nil)) }
        } else if prevState == "printing" || prevState == "paused" {
            // End LA for any non-printing state — Klipper may skip "cancelled" and go directly to "standby"
            activityTokenTask?.cancel(); activityTokenTask = nil
            let isStillActive = ["printing", "paused"].contains(printState)
            guard !isStillActive else { return }
            let dismissal: ActivityUIDismissalPolicy = (printState == "complete") ? .after(.now + 30) : .after(.now + 4)
            Task { await currentActivity?.end(.init(state: state, staleDate: nil), dismissalPolicy: dismissal) }
            currentActivity = nil
        }
    }

    private func startObservingActivityToken() {
        activityTokenTask?.cancel()
        guard let activity = currentActivity else { return }
        let secret = cloudflareNotifySecret
        let printerID = name
        activityTokenTask = Task {
            for await tokenData in activity.pushTokenUpdates {
                let token = tokenData.map { String(format: "%02x", $0) }.joined()
                try? await CloudflarePushService.shared.registerActivityToken(
                    workerURL: CloudflarePushService.workerURL,
                    printerID: printerID,
                    activityToken: token,
                    secret: secret
                )
            }
        }
    }

    func sendLocalNotification(title: String, body: String, identifier: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        if !body.isEmpty { content.body = body }
        content.sound = .default
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    func fetchFilamentSlots() {
        guard printerType == .snapmakerU1 else { return }
        // Query the live print_task_config Klipper object — updated in real-time whenever
        // filament is loaded/changed, unlike print_task.json which only updates at print start.
        guard let req = authorizedRequest(for: "\(baseURL)/printer/objects/query?print_task_config") else { return }
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["result"] as? [String: Any],
               let status = result["status"] as? [String: Any],
               let config = status["print_task_config"] as? [String: Any],
               config["filament_type"] is [String] {
                DispatchQueue.main.async { self.applyFilamentJSON(config) }
                self.fetchLiveFilamentDetection()
            } else {
                // Fallback: read from file (stale after manual filament changes, but better than nothing)
                self.fetchFilamentFromFile()
            }
        }.resume()
    }

    private func fetchFilamentFromFile() {
        guard let req = authorizedRequest(for: "\(baseURL)/server/files/config/snapmaker/print_task.json") else {
            fetchFilamentSensorsFallback()
            return
        }
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, (200...299).contains(httpStatus),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["filament_type"] is [String] || json["filament_exist"] != nil else {
                self.fetchFilamentSensorsFallback()
                return
            }
            DispatchQueue.main.async { self.applyFilamentJSON(json) }
            self.fetchLiveFilamentDetection()
        }.resume()
    }

    private func applyFilamentJSON(_ json: [String: Any]) {
        let types = json["filament_type"] as? [String] ?? []
        let subTypes = json["filament_sub_type"] as? [String] ?? []
        let colorRGBA = json["filament_color_rgba"] as? [String] ?? []
        // filament_exist can be [Bool] (JSON true/false) or [NSNumber] (0/1 integers)
        let exists: [Bool] = {
            if let bools = json["filament_exist"] as? [Bool] { return bools }
            if let nums = json["filament_exist"] as? [NSNumber] { return nums.map { $0.boolValue } }
            return []
        }()
        let vendors = json["filament_vendor"] as? [String] ?? []

        for i in 0..<4 {
            let detected = i < exists.count ? exists[i] : false
            let type_ = i < types.count ? types[i] : "–"
            let subType = i < subTypes.count ? subTypes[i] : ""
            let vendor = i < vendors.count ? vendors[i] : ""
            let hexRGBA = i < colorRGBA.count ? colorRGBA[i] : "888888FF"
            let hexRGB = String(hexRGBA.prefix(6)).uppercased()
            let color = Color(hex: hexRGB) ?? .gray
            let material: String
            if !detected { material = "–" }
            else if !subType.isEmpty { material = "\(type_) \(subType)" }
            else if vendor != "Generic" && !vendor.isEmpty { material = "\(vendor) \(type_)" }
            else { material = type_ }
            filamentSlots[i] = FilamentSlot(id: i, color: detected ? color : .gray,
                                             colorHex: detected ? hexRGB : "888888",
                                             material: material, detected: detected)
        }
        writeWidgetData()
    }

    private func fetchLiveFilamentDetection() {
        let query = "filament_motion_sensor%20e0_filament&filament_motion_sensor%20e1_filament&filament_motion_sensor%20e2_filament&filament_motion_sensor%20e3_filament"
        guard let req = authorizedRequest(for: "\(baseURL)/printer/objects/query?\(query)") else { return }
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let status = result["status"] as? [String: Any] else { return }
            DispatchQueue.main.async {
                let sensors = ["e0_filament", "e1_filament", "e2_filament", "e3_filament"]
                for (i, sensor) in sensors.enumerated() {
                    guard i < self.filamentSlots.count,
                          let sensorData = status["filament_motion_sensor \(sensor)"] as? [String: Any] else { continue }
                    let liveDetected = sensorData["filament_detected"] as? Bool ?? false
                    let existing = self.filamentSlots[i]
                    guard existing.detected != liveDetected else { continue }
                    self.filamentSlots[i] = FilamentSlot(
                        id: i,
                        color: liveDetected ? existing.color : .gray,
                        colorHex: liveDetected ? existing.colorHex : "888888",
                        material: liveDetected ? existing.material : "–",
                        detected: liveDetected
                    )
                }
                self.writeWidgetData()
            }
        }.resume()
    }

    func fetchFilamentSensorsFallback() {
        let query = "filament_motion_sensor%20e0_filament&filament_motion_sensor%20e1_filament&filament_motion_sensor%20e2_filament&filament_motion_sensor%20e3_filament"
        guard let req = authorizedRequest(for: "\(baseURL)/printer/objects/query?\(query)") else { return }
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let status = result["status"] as? [String: Any] else { return }
            DispatchQueue.main.async {
                let sensors = ["e0_filament", "e1_filament", "e2_filament", "e3_filament"]
                for (i, sensor) in sensors.enumerated() {
                    let detected = (status["filament_motion_sensor \(sensor)"] as? [String: Any])?["filament_detected"] as? Bool ?? false
                    self?.filamentSlots[i] = FilamentSlot(id: i, color: detected ? .orange : .gray,
                                                          colorHex: detected ? "FF8800" : "888888",
                                                          material: detected ? "Eingelegt" : "–", detected: detected)
                }
                self?.writeWidgetData()
            }
        }.resume()
    }

    func setExtruderTemp(extruder: Int, target: Double) {
        let heater = extruder == 0 ? "extruder" : "extruder\(extruder)"
        sendGCode("SET_HEATER_TEMPERATURE HEATER=\(heater) TARGET=\(Int(target))")
    }

    func attachExtruder(_ index: Int) {
        sendGCode("T\(index)")
    }


    func homeAxes() {
        sendGCode("G28")
    }


    func homeZ() {
        sendGCode("G28 Z")
    }

    func setBedTemp(target: Double) {
        sendGCode("SET_HEATER_TEMPERATURE HEATER=heater_bed TARGET=\(Int(target))")
    }


    func toggleChamberLed() {
        chamberLedOn.toggle()
        if chamberLedOn {
            sendGCode("SET_LED LED=cavity_led RED=0 GREEN=0 BLUE=0 WHITE=1")
        } else {
            sendGCode("SET_LED LED=cavity_led RED=0 GREEN=0 BLUE=0 WHITE=0")
        }
    }

    func setSpeedFactor(_ factor: Double) {
        speedFactor = max(0.5, min(3.0, factor))
        sendGCode("M220 S\(Int(speedFactor * 100))")
    }

    func setExtrudeFactor(_ factor: Double) {
        extrudeFactor = max(0.5, min(2.0, factor))
        sendGCode("M221 S\(Int(extrudeFactor * 100))")
    }

    func setCavityFanSpeed(_ speed: Double) {
        cavityFanSpeed = speed
        sendGCode("SET_FAN_SPEED FAN=cavity_fan SPEED=\(String(format: "%.2f", speed))")
    }

    func loadFilamentAuto() {
        sendGCode("AUTO_FEEDING")
        scheduleFilamentRefresh()
    }
    func loadFilamentManual() {
        sendGCode("MANUAL_FEEDING")
        scheduleFilamentRefresh()
    }
    func unloadFilament() {
        sendGCode("INNER_FILAMENT_UNLOAD")
        scheduleFilamentRefresh()
    }
    func changeFilament() {
        sendGCode("M600")
        scheduleFilamentRefresh(delays: [5, 12, 22, 35])
    }

    private func scheduleFilamentRefresh(delays: [Double] = [3, 8, 16]) {
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.fetchStatus()
                if self.printerType == .snapmakerU1 {
                    self.fetchFilamentSlots()
                }
            }
        }
    }

    func setSNFilamentColor(_ hex: String) {
        singleNozzleFilamentColorHex = hex
        UserDefaults.standard.set(hex, forKey: "sn_filament_\(name)")
        if printerType == .singleNozzle && filamentSlots.indices.contains(0) && filamentSlots[0].detected {
            filamentSlots[0] = FilamentSlot(id: 0,
                                             color: Color(hex: hex) ?? .orange,
                                             colorHex: hex,
                                             material: filamentSlots[0].material,
                                             detected: true)
        }
    }

    func cleanNozzleRough() { sendGCode("ROUGHLY_CLEAN_NOZZLE") }
    func cleanNozzleRoughDiscard() { sendGCode("ROUGHLY_CLEAN_NOZZLE_WITH_DISCARD") }
    func cleanNozzleFine1() { sendGCode("FINELY_CLEAN_NOZZLE_STAGE_1") }
    func cleanNozzleFine2() { sendGCode("FINELY_CLEAN_NOZZLE_STAGE_2") }

    func calibrateBedMesh() { sendGCode("AUTO_BED_MESH_CALIBRATE") }
    func calibrateBedMeshKlipper() { sendGCode("BED_MESH_CALIBRATE") }
    func calibrateExtruderOffsets() { sendGCode("EXTRUDER_OFFSET_ACTION_PROBE_CALIBRATE_ALL") }
    func calibrateXYZ() { sendGCode("XYZ_OFFSET_CALIBRATE_ALL") }
    func calibrateShaper() { sendGCode("SHAPER_CALIBRATE") }
    func calibrateShaperX() { sendGCode("SHAPER_CALIBRATE AXIS=X") }
    func calibrateShaperY() { sendGCode("SHAPER_CALIBRATE AXIS=Y") }
    func calibrateScrewTilt() { sendGCode("SCREWS_TILT_CALCULATE") }

    func setFanSpeed(_ speed: Double) {
        fanSpeed = speed
        sendGCode("M106 S\(Int(speed * 255))")
    }

    func sendGCode(_ script: String) {
        guard var req = authorizedRequest(for: "\(baseURL)/printer/gcode/script", method: "POST") else { return }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["script": script])
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errObj = json["error"] as? [String: Any],
                   let msg = errObj["message"] as? String {
                    self?.lastGCodeError = "GCode: \(script)\n\n\(msg)"
                }
                self?.fetchStatus()
            }
        }.resume()
    }

    func sendCommand(_ command: String) {
        guard let req = authorizedRequest(for: "\(baseURL)/printer/print/\(command)", method: "POST") else { return }
        isLoading = true
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.async { self?.isLoading = false; self?.fetchStatus() }
        }.resume()
    }

    func emergencyStop() {
        if printerType == .snapmakerU1 {
            sendGCode("M112")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.fetchStatus() }
        } else {
            guard let req = authorizedRequest(for: "\(baseURL)/printer/emergency_stop", method: "POST") else { return }
            URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
                DispatchQueue.main.async { self?.fetchStatus() }
            }.resume()
        }
    }

    func fetchFiles() {
        isLoadingFiles = true; fileError = nil
        guard let req = authorizedRequest(for: "\(baseURL)/server/files/list") else { return }
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoadingFiles = false
                if let error = error { self.fileError = error.localizedDescription; return }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = json["result"] as? [[String: Any]] else {
                    self.fileError = "Fehler beim Laden"; return
                }
                self.files = result.compactMap { dict -> PrinterFile? in
                    guard let path = dict["path"] as? String,
                          path.hasSuffix(".gcode") || path.hasSuffix(".g") else { return nil }
                    return PrinterFile(filename: path, size: dict["size"] as? Int ?? 0,
                                       modified: dict["modified"] as? Double ?? 0)
                }.sorted { $0.modified > $1.modified }
                self.fetchFileThumbnails()
            }
        }.resume()
    }

    func fetchFileThumbnails() {
        let files = self.files
        for file in files {
            guard let encoded = file.filename.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let req = authorizedRequest(for: "\(baseURL)/server/files/metadata?filename=\(encoded)") else { continue }
            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                guard let self = self,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = json["result"] as? [String: Any],
                      let thumbs = result["thumbnails"] as? [[String: Any]],
                      !thumbs.isEmpty else { return }
                let largest = thumbs.max { ($0["size"] as? Int ?? 0) < ($1["size"] as? Int ?? 0) }
                guard let relativePath = largest?["relative_path"] as? String,
                      let url = URL(string: "\(self.baseURL)/server/files/gcodes/\(relativePath)") else { return }
                DispatchQueue.main.async { self.fileThumbnails[file.filename] = url }
            }.resume()
        }
    }

    func startPrint(filename: String) {
        guard var req = authorizedRequest(for: "\(baseURL)/printer/print/start", method: "POST") else { return }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let name = filename.components(separatedBy: "/").last ?? filename
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["filename": name])
        isLoading = true
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.async { self?.isLoading = false; self?.fetchStatus() }
        }.resume()
    }

    func deleteFile(filename: String) {
        guard let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let req = authorizedRequest(for: "\(baseURL)/server/files/gcodes/\(encoded)", method: "DELETE") else { return }
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.async { self?.fetchFiles() }
        }.resume()
    }

    func downloadFileData(filename: String, completion: @escaping (Data?) -> Void) {
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        guard let req = authorizedRequest(for: "\(baseURL)/server/files/gcodes/\(encoded)") else {
            completion(nil); return
        }
        URLSession.shared.dataTask(with: req) { data, _, _ in
            DispatchQueue.main.async { completion(data) }
        }.resume()
    }

    func uploadFileData(filename: String, data: Data, completion: @escaping (Bool) -> Void) {
        guard var req = authorizedRequest(for: "\(baseURL)/server/files/upload", method: "POST") else {
            completion(false); return
        }
        let boundary = "PaxxMaker-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let shortName = filename.components(separatedBy: "/").last ?? filename
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(shortName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { _, response, _ in
            let ok = (response as? HTTPURLResponse).map { $0.statusCode == 201 } ?? false
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }

    func formatTime(_ seconds: Int) -> String {
        let h = seconds/3600, m = (seconds%3600)/60, s = seconds%60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}


// MARK: - Extruder Card
struct ExtruderCard: View {
    let index: Int
    let temp: Double
    let target: Double
    let slot: FilamentSlot
    let nozzle: Double
    let nozzleLoaded: Bool
    let switchCount: Int
    let isActive: Bool
    let isPrinting: Bool
    var showAttachButton: Bool = true
    let onAttach: () -> Void
    let onSetTemp: (Double) -> Void

    @State private var showTempInput = false
    @State private var tempInput: String = ""

    var isHeating: Bool { target > 0 && temp < target - 2 }
    var isAtTemp: Bool { target > 0 && abs(temp - target) <= 2 }
    var statusColor: Color {
        if !slot.detected { return .gray }
        if isAtTemp { return .green }
        if isHeating { return .orange }
        return .gray
    }

    var body: some View {
        Button(action: { tempInput = "\(Int(target))"; showTempInput = true }) {
            ZStack(alignment: .topLeading) {
                // Glass base
                RoundedRectangle(cornerRadius: 12).fill(.thinMaterial)
                RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06))

                // Filament color gradient over full card
                let cardColor = slot.detected ? slot.color : Color(.systemGray4)
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(
                        colors: [cardColor.opacity(0.45), cardColor.opacity(0.08)],
                        startPoint: .top, endPoint: .bottom))

                // Active green tint
                if isActive {
                    RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.08))
                }

                // Content
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Ext. \(index + 1)")
                            .font(.caption).fontWeight(.semibold).foregroundColor(isActive ? .green : .secondary)
                        if isActive {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.green)
                        }
                        Spacer()
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                            .shadow(color: statusColor.opacity(0.6), radius: 3)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int(temp))")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("°C").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                            .padding(.bottom, 1)
                    }
                    Divider().opacity(0.3)
                    HStack(spacing: 6) {
                        if slot.detected {
                            Circle().fill(slot.color).frame(width: 10, height: 10)
                                .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                            Text(slot.material).font(.caption2).fontWeight(.medium).lineLimit(1)
                        } else {
                            Image(systemName: "questionmark.circle").font(.caption2).foregroundColor(.secondary)
                            Text(lz(en: "No Filament", de: "Kein Filament", fr: "Pas de filament", es: "Sin filamento")).font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        if target > 0 {
                            Text("→\(Int(target))°").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    Divider().opacity(0.3)
                    HStack(spacing: 4) {
                        Image(systemName: "circle.dotted").font(.caption2)
                            .foregroundColor(nozzleLoaded ? .secondary : .secondary.opacity(0.35))
                        Text(nozzleLoaded ? String(format: "%.1f mm", nozzle) : "–")
                            .font(.caption2).fontWeight(.medium)
                            .foregroundColor(nozzleLoaded ? .secondary : .secondary.opacity(0.35))
                        Spacer()
                        if switchCount > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.2.squarepath").font(.system(size: 9))
                                Text("\(switchCount)×").font(.caption2).fontWeight(.medium)
                            }
                            .foregroundColor(.secondary.opacity(0.7))
                        }
                    }
                    Divider().opacity(0.3)
                    if isActive {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.green)
                            Text(lz(en: "Active", de: "Aktiv", fr: "Actif", es: "Activo"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.green)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.green.opacity(0.15)))
                    } else if showAttachButton {
                        Button(action: { if !isPrinting { onAttach() } }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(lz(en: "Attach", de: "Greifen", fr: "Attacher", es: "Enganchar"))
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundColor(isPrinting ? .secondary : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(isPrinting
                                        ? AnyShapeStyle(Color.secondary.opacity(0.1))
                                        : AnyShapeStyle(LinearGradient(
                                            colors: [Color.blue, Color.blue.opacity(0.75)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing)))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isPrinting)
                    }
                }
                .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(isActive ? Color.green.opacity(0.6) : (slot.detected ? slot.color.opacity(0.35) : Color.clear),
                        lineWidth: isActive ? 1.5 : 1))
            .shadow(color: isActive ? Color.green.opacity(0.25) : Color.black.opacity(0.08),
                    radius: isActive ? 8 : 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .alert("Extruder \(index + 1)", isPresented: $showTempInput) {
            TextField(lz(en: "Target temp (°C)", de: "Zieltemperatur (°C)", fr: "Température cible (°C)", es: "Temperatura objetivo (°C)"), text: $tempInput).keyboardType(.numberPad)
            Button(lz(en: "Set", de: "Setzen", fr: "Définir", es: "Establecer")) { if let t = Double(tempInput) { onSetTemp(t) } }
            Button(lz(en: "Off", de: "Aus", fr: "Éteindre", es: "Apagar")) { onSetTemp(0) }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar"), role: .cancel) {}
        } message: { Text("\(slot.material) · \(lz(en: "Current", de: "Aktuell", fr: "Actuel", es: "Actual")): \(Int(temp))°C") }
    }
}

// MARK: - Rounded Corner Shape
struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: UIRectCorner
    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                          cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}

// MARK: - TempCard
struct TempCard: View {
    let icon: String; let label: String
    let current: Double; let target: Double; let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundColor(color)
                Text(label).font(.caption).foregroundColor(.secondary)
            }
            Text("\(Int(current))°C").font(.title2).bold()
            Text("Ziel: \(Int(target))°C").font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
    }
}

// MARK: - ControlButton
struct ControlButton: View {
    let label: String; let icon: String; let color: Color; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2)
                Text(label).font(.caption).bold()
            }
            .foregroundColor(.white).frame(maxWidth: .infinity)
            .padding().background(color).cornerRadius(12)
        }
    }
}

// MARK: - MJPEG Stream View
struct MJPEGStreamView: UIViewRepresentable {
    let streamURL: URL
    var rotation: Int = 0
    var mirrorH: Bool = false
    var mirrorV: Bool = false

    class Coordinator {
        var loadedURL: URL?
        var rotation: Int = -999
        var mirrorH: Bool = false
        var mirrorV: Bool = false
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    private func buildHTML() -> (html: String, base: URL?) {
        var parts: [String] = []
        if rotation != 0 { parts.append("rotate(\(rotation)deg)") }
        let sx = mirrorH ? -1 : 1
        let sy = mirrorV ? -1 : 1
        if mirrorH || mirrorV { parts.append("scale(\(sx),\(sy))") }
        let transform = parts.isEmpty ? "none" : parts.joined(separator: " ")
        let html = """
        <!DOCTYPE html><html><head>
        <style>html,body{margin:0;padding:0;background:#000;width:100%;height:100vh;display:flex;align-items:center;justify-content:center;overflow:hidden}img{max-width:100%;max-height:100%;object-fit:contain;transform:\(transform)}</style>
        </head><body><img src="\(streamURL.absoluteString)"></body></html>
        """
        let base = URL(string: streamURL.absoluteString.components(separatedBy: "/").prefix(3).joined(separator: "/"))
        return (html, base)
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: cfg)
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        let (html, base) = buildHTML()
        webView.loadHTMLString(html, baseURL: base)
        context.coordinator.loadedURL = streamURL
        context.coordinator.rotation = rotation
        context.coordinator.mirrorH = mirrorH
        context.coordinator.mirrorV = mirrorV
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let c = context.coordinator
        guard c.loadedURL != streamURL || c.rotation != rotation || c.mirrorH != mirrorH || c.mirrorV != mirrorV else { return }
        let (html, base) = buildHTML()
        webView.loadHTMLString(html, baseURL: base)
        c.loadedURL = streamURL
        c.rotation = rotation
        c.mirrorH = mirrorH
        c.mirrorV = mirrorV
    }
}

// MARK: - Single Nozzle Combined Card (Extruder + Bed + M600)
struct SingleNozzleCombinedCard: View {
    @ObservedObject var printer: PrinterService
    @State private var showExtruderTempInput = false
    @State private var extruderTempInput = ""
    @State private var showBedTempInput = false
    @State private var bedTempInput = ""
    @State private var showFilamentColorPicker = false
    @State private var filamentPickerColor: Color = .orange

    var slot: FilamentSlot { printer.filamentSlots[safe: 0] ?? FilamentSlot(id: 0, color: .gray, colorHex: "888888", material: "–", detected: false) }
    var extruderTemp: Double { printer.extruderTemps[safe: 0] ?? 0 }
    var extruderTarget: Double { printer.extruderTargets[safe: 0] ?? 0 }
    var isHeating: Bool { extruderTarget > 0 && extruderTemp < extruderTarget - 2 }
    var isAtTemp: Bool { extruderTarget > 0 && abs(extruderTemp - extruderTarget) < 3 }
    var statusColor: Color {
        if !slot.detected { return .gray }
        if isAtTemp { return .green }
        if isHeating { return .orange }
        return .gray
    }

    var body: some View {
        VStack(spacing: 0) {
            // Extruder row
            HStack(spacing: 12) {
                Button(action: { extruderTempInput = "\(Int(extruderTarget))"; showExtruderTempInput = true }) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "flame.fill").font(.caption2).foregroundColor(.orange)
                            Text("Extruder").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                            Circle().fill(statusColor).frame(width: 7, height: 7)
                                .shadow(color: statusColor.opacity(0.6), radius: 3)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("\(Int(extruderTemp))")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                            Text("°C").font(.system(size: 13)).foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if slot.detected {
                        Button(action: { filamentPickerColor = slot.color; showFilamentColorPicker = true }) {
                            HStack(spacing: 4) {
                                Circle().fill(slot.color).frame(width: 8, height: 8)
                                Text(slot.material).font(.caption2).fontWeight(.medium)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(lz(en: "No Filament", de: "Kein Filament", fr: "Pas de fil.", es: "Sin filamento"))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    let nozzle = printer.nozzleDiameters[safe: 0] ?? 0.4
                    let loaded = printer.nozzleDiametersLoaded[safe: 0] ?? false
                    Text(loaded ? String(format: "Ø %.1f mm", nozzle) : "Ø – mm")
                        .font(.caption2).foregroundColor(.secondary)
                    if extruderTarget > 0 {
                        Text("→ \(Int(extruderTarget))°C").font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            .padding(12)

            Divider().opacity(0.3).padding(.horizontal, 12)

            // Bed row
            Button(action: { bedTempInput = "\(Int(printer.bedTarget))"; showBedTempInput = true }) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.fill").font(.caption2).foregroundColor(.red)
                            Text(lz(en: "Bed", de: "Bett", fr: "Lit", es: "Cama"))
                                .font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("\(Int(printer.bedTemp))")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                            Text("°C").font(.system(size: 13)).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if printer.bedTarget > 0 {
                        Text("→ \(Int(printer.bedTarget))°C").font(.caption2).foregroundColor(.secondary)
                    }
                }
                .padding(12)
            }
            .buttonStyle(.plain)

            Divider().opacity(0.3).padding(.horizontal, 12)

            // M600 button
            Button(action: { haptic(); printer.changeFilament() }) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.2.squarepath").font(.system(size: 14, weight: .semibold))
                    Text(lz(en: "Change Filament (M600)", de: "Filament wechseln (M600)", fr: "Changer filament (M600)", es: "Cambiar filamento (M600)"))
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [.green, .green.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            }
            .buttonStyle(.plain)
            .padding(12)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(.thinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .alert("Extruder", isPresented: $showExtruderTempInput) {
            TextField(lz(en: "Target temp (°C)", de: "Zieltemperatur (°C)", fr: "Température cible (°C)", es: "Temperatura objetivo (°C)"), text: $extruderTempInput).keyboardType(.numberPad)
            Button(lz(en: "Set", de: "Setzen", fr: "Définir", es: "Establecer")) { if let t = Double(extruderTempInput) { printer.setExtruderTemp(extruder: 0, target: t) } }
            Button(lz(en: "Off", de: "Aus", fr: "Éteindre", es: "Apagar")) { printer.setExtruderTemp(extruder: 0, target: 0) }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar"), role: .cancel) {}
        }
        .alert(lz(en: "Bed Temperature", de: "Bett Temperatur", fr: "Température du plateau", es: "Temperatura de la cama"), isPresented: $showBedTempInput) {
            TextField(lz(en: "Target temp (°C)", de: "Zieltemperatur (°C)", fr: "Température cible (°C)", es: "Temperatura objetivo (°C)"), text: $bedTempInput).keyboardType(.numberPad)
            Button(lz(en: "Set", de: "Setzen", fr: "Définir", es: "Establecer")) { if let t = Double(bedTempInput) { printer.setBedTemp(target: t) } }
            Button(lz(en: "Off", de: "Aus", fr: "Éteindre", es: "Apagar")) { printer.setBedTemp(target: 0) }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar"), role: .cancel) {}
        }
        .sheet(isPresented: $showFilamentColorPicker) {
            VStack(spacing: 24) {
                Text(lz(en: "Filament Color", de: "Filamentfarbe", fr: "Couleur filament", es: "Color filamento"))
                    .font(.headline)
                ColorPicker(lz(en: "Color", de: "Farbe", fr: "Couleur", es: "Color"),
                            selection: $filamentPickerColor, supportsOpacity: false)
                    .padding(.horizontal)
                Button(lz(en: "Done", de: "Fertig", fr: "OK", es: "OK")) {
                    showFilamentColorPicker = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(32)
            .presentationDetents([.height(220)])
            .onChange(of: filamentPickerColor) { printer.setSNFilamentColor(filamentPickerColor.hexString) }
        }
    }
}

// MARK: - Temperature Sparkline
struct TempSparklineView: View {
    let extruderHistories: [[Double]]   // one array per head; single-nozzle only uses [0]
    let bedHistory: [Double]
    var extruderColors: [Color] = [.orange, .red, .green, .teal]

    var body: some View {
        GeometryReader { geo in
            let allVals = extruderHistories.flatMap { $0 } + bedHistory
            if allVals.count >= 4 {
                let minV = (allVals.min() ?? 0) - 2
                let maxV = (allVals.max() ?? 1) + 2
                let range = max(maxV - minV, 1)
                ZStack {
                    // Bed (blue, drawn first so extruder lines sit on top)
                    sparkPath(values: bedHistory, geo: geo, minV: minV, range: range)
                        .stroke(Color.blue.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    // One line per extruder head, colored by loaded filament
                    ForEach(extruderHistories.indices, id: \.self) { i in
                        if extruderHistories[i].count >= 2 {
                            let color = extruderColors[safe: i] ?? .orange
                            sparkPath(values: extruderHistories[i], geo: geo, minV: minV, range: range)
                                .stroke(color.opacity(0.9),
                                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        }
                    }
                }
            }
        }
    }

    private func sparkPath(values: [Double], geo: GeometryProxy, minV: Double, range: Double) -> Path {
        guard values.count >= 2 else { return Path() }
        let step = geo.size.width / CGFloat(values.count - 1)
        return Path { p in
            for (i, v) in values.enumerated() {
                let pt = CGPoint(
                    x: CGFloat(i) * step,
                    y: geo.size.height - CGFloat((v - minV) / range) * geo.size.height
                )
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
        }
    }
}

// MARK: - Dashboard Tile
enum DashboardTile: String, CaseIterable, Identifiable {
    case webcam, webcam2, status, screen, extruder, bed, filament, spools, cleaning, calibration, stats, smartPlug
    var id: String { rawValue }
    var label: String {
        switch self {
        case .webcam: return "Webcam"
        case .webcam2: return "Webcam 2"
        case .status: return lz(en: "Status & Control", de: "Status & Steuerung", fr: "Statut & Contrôle", es: "Estado & Control")
        case .screen: return lz(en: "Printer Screen", de: "Druckerbildschirm", fr: "Écran Imprimante", es: "Pantalla Impresora")
        case .extruder: return "Extruder"
        case .bed: return lz(en: "Bed & Chamber", de: "Heizbett & Bauraum", fr: "Plateau & Enceinte", es: "Cama & Cámara")
        case .filament: return lz(en: "Filament", de: "Filament", fr: "Filament", es: "Filamento")
        case .spools: return lz(en: "Spools", de: "Spulen", fr: "Bobines", es: "Bobinas")
        case .cleaning: return lz(en: "Nozzle Cleaning", de: "Düsen Reinigung", fr: "Nettoyage Buse", es: "Limpieza Boquilla")
        case .calibration: return lz(en: "Calibration", de: "Kalibrierung", fr: "Calibration", es: "Calibración")
        case .stats: return lz(en: "Statistics", de: "Statistiken", fr: "Statistiques", es: "Estadísticas")
        case .smartPlug: return lz(en: "Smart Plug", de: "Smart-Steckdose", fr: "Prise intelligente", es: "Enchufe inteligente")
        }
    }
    var icon: String {
        switch self {
        case .webcam: return "video.fill"
        case .webcam2: return "web.camera.fill"
        case .status: return "play.circle.fill"
        case .screen: return "display"
        case .extruder: return "thermometer"
        case .bed: return "square.fill"
        case .filament: return "arrow.2.squarepath"
        case .spools: return "cylinder.split.1x2.fill"
        case .cleaning: return "paintbrush.fill"
        case .calibration: return "slider.horizontal.3"
        case .stats: return "chart.bar.fill"
        case .smartPlug: return "powerplug.fill"
        }
    }
}

// MARK: - Tile Editor View
struct TileEditorView: View {
    @Binding var tileOrderString: String
    @AppStorage("hidden_tiles") private var hiddenTilesString: String = ""
    @Environment(\.dismiss) var dismiss
    @State private var items: [DashboardItem]
    let printerType: PrinterConfig.PrinterType
    let groups: [CustomCommandGroup]

    private static func staticItems(for printerType: PrinterConfig.PrinterType) -> [DashboardItem] {
        let singleNozzleHidden: Set<DashboardTile> = [.screen, .filament, .spools, .cleaning]
        return DashboardTile.allCases
            .filter { printerType == .singleNozzle ? !singleNozzleHidden.contains($0) : $0 != .cleaning }
            .map { .tile($0) }
    }

    init(tileOrderString: Binding<String>, printerType: PrinterConfig.PrinterType = .snapmakerU1, groups: [CustomCommandGroup] = []) {
        self._tileOrderString = tileOrderString
        self.printerType = printerType
        self.groups = groups
        let availableStatic = Self.staticItems(for: printerType)
        let groupItems = groups.map { DashboardItem.group($0.id) }
        let allAvailable = availableStatic + groupItems
        let saved = tileOrderString.wrappedValue.split(separator: ",")
            .map { String($0) }
            .compactMap { rawID -> DashboardItem? in
                // legacy "customCommands" → default group
                let id = rawID == "customCommands" ? "cg_default" : rawID
                return allAvailable.first { $0.rawID == id }
            }
        let missing = allAvailable.filter { a in !saved.contains(where: { $0.rawID == a.rawID }) }
        self._items = State(initialValue: saved + missing)
    }

    var hiddenSet: Set<String> { Set(hiddenTilesString.split(separator: ",").map(String.init)) }

    func label(for item: DashboardItem) -> String {
        if let t = item.asStaticTile { return t.label }
        if let gid = item.customGroupID {
            let title = groups.first { $0.id == gid }?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? lz(en: "My Commands", de: "Eigene Befehle", fr: "Mes commandes", es: "Mis comandos") : title
        }
        return item.rawID
    }
    func icon(for item: DashboardItem) -> String {
        item.asStaticTile?.icon ?? "terminal.fill"
    }
    func toggleHidden(_ item: DashboardItem) {
        var set = hiddenSet
        if set.contains(item.rawID) { set.remove(item.rawID) } else { set.insert(item.rawID) }
        hiddenTilesString = set.joined(separator: ",")
    }

    var body: some View {
        NavigationView {
            List {
                ForEach(items) { item in
                    let hidden = hiddenSet.contains(item.rawID)
                    HStack(spacing: 12) {
                        Image(systemName: icon(for: item))
                            .foregroundColor(hidden ? .secondary : (item.customGroupID != nil ? .purple : .blue))
                            .frame(width: 28)
                        Text(label(for: item))
                            .foregroundColor(hidden ? .secondary : .primary)
                        Spacer()
                        Button(action: { toggleHidden(item) }) {
                            Image(systemName: hidden ? "eye.slash" : "eye")
                                .foregroundColor(hidden ? .secondary : .blue)
                                .font(.system(size: 16))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onMove { from, to in
                    items.move(fromOffsets: from, toOffset: to)
                    tileOrderString = items.map(\.rawID).joined(separator: ",")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(lz(en: "Customize Tiles", de: "Kacheln anpassen", fr: "Personnaliser", es: "Personalizar"))
            .navigationBarItems(trailing: Button(lz(en: "Done", de: "Fertig", fr: "Terminé", es: "Listo")) { dismiss() })
        }
    }
}

// MARK: - Fan Slider Sheet
struct FanSliderSheet: View {
    let title: String
    let currentValue: Double
    let onSet: (Double) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var value: Double

    init(title: String, currentValue: Double, onSet: @escaping (Double) -> Void) {
        self.title = title
        self.currentValue = currentValue
        self.onSet = onSet
        self._value = State(initialValue: currentValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 20)

            Text(title)
                .font(.subheadline).fontWeight(.semibold)
                .foregroundColor(.secondary)
                .textCase(.uppercase).tracking(1)

            Text("\(Int(value * 100))%")
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.08), value: Int(value * 100))
                .padding(.vertical, 16)

            HStack(spacing: 14) {
                Image(systemName: "fan")
                    .font(.system(size: 13)).foregroundColor(.secondary)
                Slider(value: $value, in: 0...1)
                    .tint(.blue)
                Image(systemName: "fan.fill")
                    .font(.system(size: 22)).foregroundColor(.blue)
            }
            .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button(action: {
                    withAnimation { value = 0 }
                    onSet(0)
                    dismiss()
                }) {
                    Text(lz(en: "Off", de: "Aus", fr: "Éteindre", es: "Apagar"))
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(14)
                }
                .buttonStyle(.plain)

                Button(action: {
                    onSet(value)
                    dismiss()
                }) {
                    Text(lz(en: "Set", de: "Setzen", fr: "Définir", es: "Establecer"))
                        .font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color.blue).cornerRadius(14)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)

            Spacer()
        }
        .presentationDetents([.height(330)])
        .presentationDragIndicator(.hidden)
    }
}

private struct DashScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct HidePickerKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
}

private struct WobbleModifier: ViewModifier {
    var active: Bool
    @State private var angle: Double

    init(active: Bool, seed: Int = 0) {
        self.active = active
        // Each tile gets a unique starting angle so they wobble out of phase
        let t = Double(abs(seed) % 100) / 100.0   // 0.0 … 0.99
        self._angle = State(initialValue: t * 2.5 - 1.25)  // –1.25 … +1.25
    }

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(active ? angle : 0))
            .onAppear {
                withAnimation(.easeInOut(duration: 0.13).repeatForever(autoreverses: true)) {
                    angle = angle < 0 ? 1.25 : -1.25
                }
            }
    }
}

// MARK: - Confirmable Button (busy-check + confirmation dialog, used by calibration / filament / macros)
private struct ConfirmableButton: View {
    let label: String
    let icon: String
    let color: Color
    let confirmTitle: String
    let confirmMessage: String
    let printer: PrinterService
    let action: () -> Void

    @State private var showConfirm = false
    @State private var showBusy = false

    var body: some View {
        Button {
            haptic()
            if printer.isBusy {
                showBusy = true
            } else {
                showConfirm = true
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(colors: [color, color.opacity(0.65)],
                                        startPoint: .top, endPoint: .bottom))
                    .shadow(color: color.opacity(0.4), radius: 6, x: 0, y: 3)
            )
        }
        .buttonStyle(.plain)
        .confirmationDialog(confirmTitle, isPresented: $showConfirm, titleVisibility: .visible) {
            Button(lz(en: "Start", de: "Starten", fr: "Lancer", es: "Iniciar")) { action() }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar"), role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .alert(lz(en: "Printer busy", de: "Drucker beschäftigt", fr: "Imprimante occupée", es: "Impresora ocupada"),
               isPresented: $showBusy) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(printer.printState == "printing"
                 ? lz(en: "A print is running. Available once the print is done.",
                       de: "Ein Druck läuft. Nach dem Druck wieder verfügbar.",
                       fr: "Une impression est en cours.",
                       es: "Hay una impresión en curso.")
                 : lz(en: "A command is currently running. Please wait.",
                       de: "Es läuft gerade ein Befehl. Bitte warte bis er abgeschlossen ist.",
                       fr: "Une commande est en cours. Patientez.",
                       es: "Un comando está en curso. Espere."))
        }
    }
}

// Convenience init for CustomCommand (used by custom macro tiles)
private struct MacroButtonView: View {
    let cmd: CustomCommand
    let printer: PrinterService
    var body: some View {
        ConfirmableButton(
            label: cmd.name,
            icon: cmd.sfSymbol.isEmpty ? "terminal.fill" : cmd.sfSymbol,
            color: cmd.color,
            confirmTitle: cmd.name,
            confirmMessage: lz(en: "Run this command?", de: "Befehl ausführen?",
                               fr: "Exécuter cette commande\u{00A0}?", es: "¿Ejecutar este comando?"),
            printer: printer,
            action: { printer.sendGCode(cmd.gcode) }
        )
    }
}

// MARK: - Dashboard View
struct DashboardView: View {
    @ObservedObject var printer: PrinterService
    var printerID: String = ""
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("splitscreen_mode") private var splitscreenMode: Bool = false
    @AppStorage("current_splitscreen_count") private var storedSplitscreenCount: Int = 1
    @State private var isLandscape: Bool = false

    private static let defaultTileOrder     = "webcam,status,screen,extruder,bed,spools,filament,calibration,cleaning,stats"
    private static let defaultHalfWidth     = "filament,calibration"
    // iPad default: spools next to extruder, calibration+cleaning side-by-side
    private static let defaultTileOrderIPad = "webcam,status,screen,extruder,spools,bed,filament,calibration,cleaning,stats"
    private static let defaultHalfWidthIPad = "extruder,spools,calibration,cleaning"
    @State private var showEmergencyConfirm = false
    @State private var showPauseConfirm = false
    @State private var showResumeConfirm = false
    @State private var showCancelConfirm = false
    @State private var showHomingDialog = false
    @State private var showHomingBusy = false
    @State private var showBedTempInput = false
    @State private var bedTempInput = ""

    @State private var statusTileSize: Int = 0   // 0=full  1=no motor temps  2=no speed/flow either

    @State private var tileOrderString: String = DashboardView.defaultTileOrder
    @State private var hiddenTilesString: String = ""
    @State private var tileGridModeString: String = ""
    @State private var halfWidthString: String = DashboardView.defaultHalfWidth
    @State private var thirdWidthString: String = ""
    @State private var isEditMode = false
    @State private var draggedItem: DashboardItem? = nil
    @State private var dropTargetID: String? = nil
    @State private var slotDropTargetID: String? = nil
    @State private var showFanSheet = false
    @State private var fanSheetTitle = ""
    @State private var fanSheetValue: Double = 0
    @State private var fanSheetSetter: ((Double) -> Void)? = nil

    @State private var hideSegmentedPicker = false
    @State private var lastScrollOffset: CGFloat = 0

    var tileOrder: [DashboardItem] {
        let hidden = Set(hiddenTilesString.split(separator: ",").map(String.init))
        let parts = tileOrderString.split(separator: ",").map { String($0) }
        let saved: [DashboardItem] = parts.compactMap { rawID in
            if rawID.hasPrefix("__sp_") { return DashboardItem(rawID: rawID) }
            let id = rawID == "customCommands" ? "cg_default" : rawID
            if let t = DashboardTile(rawValue: id) { return .tile(t) }
            if id.hasPrefix("cg_") {
                let gid = String(id.dropFirst(3))
                if settings.customCommandGroups.contains(where: { $0.id == gid }) { return .group(gid) }
            }
            return nil
        }
        let existingStaticTiles = Set(saved.compactMap { $0.asStaticTile })
        let missingStatic = DashboardTile.allCases
            .filter { !existingStaticTiles.contains($0) }
            .map { DashboardItem.tile($0) }
        let existingGroupIDs = Set(saved.compactMap { $0.customGroupID })
        let missingGroups = settings.customCommandGroups
            .filter { !existingGroupIDs.contains($0.id) }
            .map { DashboardItem.group($0.id) }
        return (saved + missingStatic + missingGroups)
            .filter { !hidden.contains($0.rawID) }
            .filter {
                guard let gid = $0.customGroupID else { return true }
                return !settings.customCommands.filter { $0.groupID == gid }.isEmpty
            }
            .filter { item -> Bool in
                guard let t = item.asStaticTile else { return true }
                if t == .webcam    { return printer.webcamConfigured }
                if t == .webcam2   { return printer.webcam2StreamURL != nil }
                if t == .smartPlug { return !printer.smartPlugIP.isEmpty }
                return true
            }
    }

    var allTileItems: [DashboardItem] {
        let snExcluded: Set<DashboardTile> = [.screen, .filament, .spools, .cleaning]
        func isApplicable(_ t: DashboardTile) -> Bool {
            if t == .webcam    { return printer.webcamConfigured }
            if t == .webcam2   { return printer.webcam2StreamURL != nil }
            if t == .smartPlug { return !printer.smartPlugIP.isEmpty }
            return printer.printerType == .singleNozzle ? !snExcluded.contains(t) : t != .cleaning
        }
        let parts = tileOrderString.split(separator: ",").map { String($0) }
        let saved: [DashboardItem] = parts.compactMap { rawID in
            if rawID.hasPrefix("__sp_") { return DashboardItem(rawID: rawID) }
            let id = rawID == "customCommands" ? "cg_default" : rawID
            if let t = DashboardTile(rawValue: id) {
                return isApplicable(t) ? .tile(t) : nil
            }
            if id.hasPrefix("cg_") {
                let gid = String(id.dropFirst(3))
                if settings.customCommandGroups.contains(where: { $0.id == gid }) { return .group(gid) }
            }
            return nil
        }
        let existingStaticTiles = Set(saved.compactMap { $0.asStaticTile })
        let missingStatic = DashboardTile.allCases
            .filter { !existingStaticTiles.contains($0) && isApplicable($0) }
            .map { DashboardItem.tile($0) }
        let existingGroupIDs = Set(saved.compactMap { $0.customGroupID })
        let missingGroups = settings.customCommandGroups
            .filter { !existingGroupIDs.contains($0.id) }
            .map { DashboardItem.group($0.id) }
        return (saved + missingStatic + missingGroups)
            .filter {
                guard let gid = $0.customGroupID else { return true }
                return !settings.customCommands.filter { $0.groupID == gid }.isEmpty
            }
    }

    var dashHiddenSet: Set<String> { Set(hiddenTilesString.split(separator: ",").map(String.init)) }

    func toggleHiddenTile(_ item: DashboardItem) {
        var set = dashHiddenSet
        if set.contains(item.rawID) { set.remove(item.rawID) } else { set.insert(item.rawID) }
        hiddenTilesString = set.joined(separator: ",")
        UserDefaults.standard.set(hiddenTilesString, forKey: lKey("hidden_tiles"))
    }

    private func applyTileOrder(_ items: [DashboardItem]) {
        var t = Transaction(animation: nil)
        t.disablesAnimations = true
        withTransaction(t) {
            tileOrderString = items.map(\.rawID).joined(separator: ",")
            UserDefaults.standard.set(tileOrderString, forKey: lKey("dashboard_tile_order"))
        }
    }

    // Unified move: removes the tile, leaves a spacer at the source if it shared
    // a row with other real tiles, then places the tile before/after the target.
    private func moveTile(id: String, targetID: String, placeBefore: Bool) {
        var items = allTileItems
        guard let tileIdx = items.firstIndex(where: { $0.rawID == id }),
              items.firstIndex(where: { $0.rawID == targetID }) != nil,
              id != targetID else { return }

        let tileItem = items[tileIdx]
        let ews = effectiveWidthState(for: tileItem)

        let rows = tileRows(from: items)
        let sharedRow = rows.first { $0.contains { $0.rawID == id } }
        let sharesRow = (sharedRow?.filter { !$0.isSpacerItem }.count ?? 0) > 1

        items.remove(at: tileIdx)

        if sharesRow && ews > 0 {
            items.insert(.spacer(widthState: ews), at: tileIdx)
        }

        guard let newTargetIdx = items.firstIndex(where: { $0.rawID == targetID }) else { return }
        items.insert(tileItem, at: placeBefore ? newTargetIdx : newTargetIdx + 1)
        applyTileOrder(items)
    }

    func reorderItem(withID id: String, before targetID: String) {
        moveTile(id: id, targetID: targetID, placeBefore: true)
    }

    func reorderItem(withID id: String, after targetID: String) {
        moveTile(id: id, targetID: targetID, placeBefore: false)
    }

    // Swap two tiles in-place — no other tile moves.
    // Also swaps width states so the bin-packer produces identical rows for all other tiles.
    func swapTiles(id: String, with targetID: String) {
        var items = allTileItems
        guard let fromIdx = items.firstIndex(where: { $0.rawID == id }),
              let toIdx   = items.firstIndex(where: { $0.rawID == targetID }),
              fromIdx != toIdx else { return }

        let fromWidth = tileWidthState(items[fromIdx])
        let toWidth   = tileWidthState(items[toIdx])

        items.swapAt(fromIdx, toIdx)

        var t = Transaction(animation: nil)
        t.disablesAnimations = true
        withTransaction(t) {
            if fromWidth != toWidth {
                // Swap width states so each tile fills the other's grid slot size
                var halves = halfWidthTiles
                var thirds = thirdWidthTiles
                halves.remove(id);       halves.remove(targetID)
                thirds.remove(id);       thirds.remove(targetID)
                if fromWidth == 1 { halves.insert(targetID) } else if fromWidth == 2 { thirds.insert(targetID) }
                if toWidth   == 1 { halves.insert(id)       } else if toWidth   == 2 { thirds.insert(id) }
                halfWidthString  = halves.joined(separator: ",")
                thirdWidthString = thirds.joined(separator: ",")
                UserDefaults.standard.set(halfWidthString,  forKey: lKey("tile_half_width"))
                UserDefaults.standard.set(thirdWidthString, forKey: lKey("tile_third_width"))
            }
            tileOrderString = items.map(\.rawID).joined(separator: ",")
            UserDefaults.standard.set(tileOrderString, forKey: lKey("dashboard_tile_order"))
        }
    }

    var gridModeTiles: Set<String> { Set(tileGridModeString.split(separator: ",").map(String.init)) }

    func toggleGridMode(_ item: DashboardItem) {
        var set = gridModeTiles
        if set.contains(item.rawID) { set.remove(item.rawID) } else { set.insert(item.rawID) }
        tileGridModeString = set.joined(separator: ",")
        UserDefaults.standard.set(tileGridModeString, forKey: lKey("tile_grid_mode"))
    }

    func supportsGridMode(_ item: DashboardItem) -> Bool {
        item.rawID == DashboardTile.spools.rawValue
    }

    var halfWidthTiles: Set<String> { Set(halfWidthString.split(separator: ",").map(String.init)) }
    var thirdWidthTiles: Set<String> { Set(thirdWidthString.split(separator: ",").map(String.init)) }

    // Number of printers currently shown side by side (1 when not in splitscreen)
    var sideBySideCount: Int { splitscreenMode ? storedSplitscreenCount : 1 }

    // 0 = full width, 1 = half width (2 per row), 2 = third width (3 per row)
    func tileWidthState(_ item: DashboardItem) -> Int {
        if thirdWidthTiles.contains(item.rawID) { return 2 }
        if halfWidthTiles.contains(item.rawID) { return 1 }
        return 0
    }

    func setTileWidth(_ item: DashboardItem, state: Int) {
        var halves = halfWidthTiles
        var thirds = thirdWidthTiles
        halves.remove(item.rawID)
        thirds.remove(item.rawID)
        if state == 1 { halves.insert(item.rawID) }
        else if state == 2 { thirds.insert(item.rawID) }
        halfWidthString = halves.joined(separator: ",")
        thirdWidthString = thirds.joined(separator: ",")
        UserDefaults.standard.set(halfWidthString, forKey: lKey("tile_half_width"))
        UserDefaults.standard.set(thirdWidthString, forKey: lKey("tile_third_width"))
    }

    // Max allowed width state (0=full only, 1=full/half, 2=full/half/third) per context
    func maxWidthState(for item: DashboardItem) -> Int {
        let isIPad = horizontalSizeClass == .regular
        guard isIPad else {
            // iPhone: status/extruder/bed locked full
            let locked: Set<String> = [DashboardTile.extruder.rawValue, DashboardTile.bed.rawValue, DashboardTile.status.rawValue]
            return locked.contains(item.rawID) ? 0 : 1
        }
        let primaryTiles: Set<String> = [DashboardTile.webcam.rawValue, DashboardTile.status.rawValue, DashboardTile.screen.rawValue]
        let heavyTiles:   Set<String> = [DashboardTile.extruder.rawValue, DashboardTile.bed.rawValue]
        let count = sideBySideCount
        if isLandscape {
            if count >= 3 {
                // Landscape 3-split: webcam/status/screen/extruder/bed → full only; rest → full/half
                if primaryTiles.contains(item.rawID) || heavyTiles.contains(item.rawID) { return 0 }
                return 1
            }
            if count == 2 {
                // Landscape 2-split: webcam/status/screen/extruder/bed → full/half; rest → full/half/third
                if primaryTiles.contains(item.rawID) || heavyTiles.contains(item.rawID) { return 1 }
                return 2
            }
            // Landscape single: all → full/half/third
            return 2
        } else {
            if count >= 2 {
                // Portrait 2-split: webcam/status/screen/extruder/bed → full/half; rest → full/half/third
                if primaryTiles.contains(item.rawID) || heavyTiles.contains(item.rawID) { return 1 }
                return 2
            }
            // Portrait single: webcam/screen/extruder/bed → full/half; status+rest → full/half/third
            let portraitSingleHalf: Set<String> = [DashboardTile.webcam.rawValue, DashboardTile.screen.rawValue]
            if portraitSingleHalf.contains(item.rawID) || heavyTiles.contains(item.rawID) { return 1 }
            return 2
        }
    }

    // Actual display state: stored preference clamped to what the current context allows
    func effectiveWidthState(for item: DashboardItem) -> Int {
        if item.rawID.hasPrefix("__sp_t_") { return 2 }  // third-width spacer
        if item.isSpacerItem { return 1 }                 // half-width spacer
        return min(tileWidthState(item), maxWidthState(for: item))
    }

    // Cycles full → half → (third if allowed) → full
    func cycleWidth(_ item: DashboardItem) {
        let max = maxWidthState(for: item)
        setTileWidth(item, state: (tileWidthState(item) + 1) % (max + 1))
    }

    // Groups tiles into rows using a 6-unit bin: full=6, half=3, third=2.
    // Mixed half+third tiles on the same row are allowed as long as total ≤ 6.
    func tileRows(from items: [DashboardItem]) -> [[DashboardItem]] {
        func unitCount(_ item: DashboardItem) -> Int {
            switch effectiveWidthState(for: item) {
            case 2: return 2
            case 1: return 3
            default: return 6
            }
        }
        var rows: [[DashboardItem]] = []
        var currentRow: [DashboardItem] = []
        var remaining = 6
        for item in items {
            let u = unitCount(item)
            if u == 6 || u > remaining {
                if !currentRow.isEmpty { rows.append(currentRow) }
                if u == 6 {
                    rows.append([item])
                    currentRow = []
                    remaining = 6
                } else {
                    currentRow = [item]
                    remaining = 6 - u
                }
            } else {
                currentRow.append(item)
                remaining -= u
                if remaining == 0 {
                    rows.append(currentRow)
                    currentRow = []
                    remaining = 6
                }
            }
        }
        if !currentRow.isEmpty { rows.append(currentRow) }
        return rows
    }

    private func lKey(_ base: String) -> String { "\(base)_\(printerID)" }

    func loadLayout() {
        let ud = UserDefaults.standard
        let iPad = horizontalSizeClass == .regular
        tileOrderString = ud.string(forKey: lKey("dashboard_tile_order"))
            ?? (iPad ? DashboardView.defaultTileOrderIPad : DashboardView.defaultTileOrder)
        hiddenTilesString = ud.string(forKey: lKey("hidden_tiles")) ?? ""
        tileGridModeString = ud.string(forKey: lKey("tile_grid_mode")) ?? ""
        halfWidthString = ud.string(forKey: lKey("tile_half_width"))
            ?? (iPad ? DashboardView.defaultHalfWidthIPad : DashboardView.defaultHalfWidth)
        thirdWidthString = ud.string(forKey: lKey("tile_third_width")) ?? ""
        statusTileSize = ud.integer(forKey: lKey("status_tile_size"))   // 0 if not set = full height
    }

    var stateColor: Color {
        switch printer.printState {
        case "printing": return .green
        case "paused": return .orange
        case "error": return .red
        case "complete": return .blue
        default: return .gray
        }
    }
    var stateLabel: String {
        switch printer.printState {
        case "printing": return lz(en: "Printing", de: "Druckt", fr: "En cours", es: "Imprimiendo")
        case "paused":   return lz(en: "Paused",   de: "Pausiert", fr: "En pause", es: "Pausado")
        case "error":    return lz(en: "Error",    de: "Fehler",   fr: "Erreur",   es: "Error")
        case "complete": return lz(en: "Done",     de: "Fertig",   fr: "Terminé",  es: "Listo")
        case "standby":  return lz(en: "Ready",    de: "Bereit",   fr: "Prêt",     es: "Listo")
        default:         return lz(en: "Unknown",  de: "Unbekannt",fr: "Inconnu",  es: "Desconocido")
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 12) {
                    // Demo mode banner
                    if printer.isDemoMode {
                        HStack(spacing: 8) {
                            Image(systemName: "play.circle.fill").font(.system(size: 13, weight: .semibold))
                            Text(lz(en: "Demo Mode – No real printer connected", de: "Demo-Modus – Kein echter Drucker verbunden", fr: "Mode démo – Aucune imprimante connectée", es: "Modo demo – Sin impresora real"))
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color.purple.opacity(0.75))
                        .cornerRadius(14)
                        .padding(.horizontal, 16)
                    }

                    // Offline banner
                    if !printer.isOnline && !printer.isDemoMode {
                        HStack(spacing: 10) {
                            Image(systemName: "wifi.slash").font(.system(size: 13, weight: .semibold))
                            Text(lz(en: "Not connected", de: "Keine Verbindung", fr: "Non connecté", es: "Sin conexión"))
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Button {
                                haptic(.light)
                                printer.fetchStatus()
                            } label: {
                                Text(lz(en: "Retry", de: "Erneut", fr: "Réessayer", es: "Reintentar"))
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 5)
                                    .background(Color.white.opacity(0.22)).cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color.red.opacity(0.7))
                        .cornerRadius(14)
                        .padding(.horizontal, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    let rows = tileRows(from: isEditMode ? allTileItems : tileOrder)
                    ForEach(0..<rows.count, id: \.self) { rowIndex in
                        let row = rows[rowIndex]
                        let eWSes = row.map { effectiveWidthState(for: $0) }
                        let isMixedRow = eWSes.count > 1 && !eWSes.dropFirst().allSatisfy { $0 == eWSes[0] }
                        if isMixedRow {
                            // Mixed half+third: 6-unit Grid where each tile spans its unit count
                            let totalUnits = eWSes.reduce(0) { $0 + ($1 == 2 ? 2 : ($1 == 1 ? 3 : 6)) }
                            let remainingUnits = 6 - totalUnits
                            Grid(horizontalSpacing: 12, verticalSpacing: 0) {
                                GridRow {
                                    ForEach(row) { tile in
                                        let ews = effectiveWidthState(for: tile)
                                        let span = ews == 2 ? 2 : (ews == 1 ? 3 : 6)
                                        Group {
                                            if isEditMode {
                                                editableTile(for: tile)
                                            } else {
                                                tileView(for: tile)
                                                    .onLongPressGesture(minimumDuration: 0.4) {
                                                        haptic(.medium)
                                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isEditMode = true }
                                                    }
                                            }
                                        }
                                        .gridCellColumns(span)
                                    }
                                    if remainingUnits > 0 {
                                        emptySlotDropZone(
                                            slotID: "__slot_mixed_\(row.last?.rawID ?? "")_\(rowIndex)",
                                            anchorID: row.last?.rawID ?? ""
                                        )
                                        .gridCellColumns(remainingUnits)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        } else {
                            // Pure row: all tiles same width — use LazyVGrid
                            let ews0 = eWSes.first ?? 0
                            let colCount = ews0 == 2 ? 3 : (ews0 == 1 ? 2 : 1)
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: colCount),
                                spacing: 0
                            ) {
                                ForEach(row) { tile in
                                    Group {
                                        if isEditMode {
                                            editableTile(for: tile)
                                        } else {
                                            tileView(for: tile)
                                                .onLongPressGesture(minimumDuration: 0.4) {
                                                    haptic(.medium)
                                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isEditMode = true }
                                                }
                                        }
                                    }
                                }
                                if colCount > row.count {
                                    ForEach(0..<(colCount - row.count), id: \.self) { slotIdx in
                                        emptySlotDropZone(
                                            slotID: "__slot_\(row.last?.rawID ?? "")_\(rowIndex)_\(slotIdx)",
                                            anchorID: row.last?.rawID ?? ""
                                        )
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    Spacer(minLength: 20)
                }
                .padding(.top, 8)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: printer.isOnline)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: DashScrollOffsetKey.self,
                            value: geo.frame(in: .named("dashScroll")).minY
                        )
                    }
                )
            }
            .coordinateSpace(name: "dashScroll")
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .refreshable {
                printer.fetchStatus()
                printer.fetchHistoryTotals()
                if printer.printerType == .snapmakerU1 {
                    printer.fetchFilamentSlots()
                    printer.fetchU1ExtendedStatus()
                }
                printer.fetchWebcamConfig()
            }
            .onPreferenceChange(DashScrollOffsetKey.self) { offset in
                let delta = offset - lastScrollOffset
                if delta < -14 { withAnimation(.easeInOut(duration: 0.25)) { hideSegmentedPicker = true } }
                else if delta > 14 { withAnimation(.easeInOut(duration: 0.25)) { hideSegmentedPicker = false } }
                lastScrollOffset = offset
            }
        }
        .preference(key: HidePickerKey.self, value: hideSegmentedPicker)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: printer.printState)
        .ignoresSafeArea(edges: .top)
        .onAppear { loadLayout() }
        .onDisappear { isEditMode = false }
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { isLandscape = $0 }
        .toolbar {
            if printer.printState == "printing" || printer.printState == "paused" {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        hapticNotification(.error)
                        showEmergencyConfirm = true
                    } label: {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.red)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isEditMode {
                    Button(lz(en: "Done", de: "Fertig", fr: "Terminé", es: "Listo")) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isEditMode = false }
                    }
                    .fontWeight(.semibold)
                } else {
                    Button(action: { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isEditMode = true } }) {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
            }
        }
        .alert(lz(en: "Emergency Stop?", de: "Notfall Stop?", fr: "Arrêt d'urgence ?", es: "¿Parada de emergencia?"), isPresented: $showEmergencyConfirm) {
            Button(lz(en: "Stop", de: "Stoppen", fr: "Arrêter", es: "Detener"), role: .destructive) { printer.emergencyStop() }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar"), role: .cancel) {}
        } message: { Text(lz(en: "The printer will stop immediately.", de: "Der Drucker wird sofort gestoppt.", fr: "L'imprimante s'arrête immédiatement.", es: "La impresora se detendrá inmediatamente.")) }
        .alert(lz(en: "Pause Print?", de: "Druck pausieren?", fr: "Mettre en pause ?", es: "¿Pausar impresión?"), isPresented: $showPauseConfirm) {
            Button(lz(en: "Pause", de: "Pausieren", fr: "Pause", es: "Pausar"), role: .destructive) { printer.sendCommand("pause") }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar"), role: .cancel) {}
        } message: { Text(lz(en: "The print will be paused.", de: "Der Druck wird unterbrochen.", fr: "L'impression sera mise en pause.", es: "La impresión se pausará.")) }
        .alert(lz(en: "Resume Print?", de: "Druck fortsetzen?", fr: "Reprendre ?", es: "¿Reanudar impresión?"), isPresented: $showResumeConfirm) {
            Button(lz(en: "Resume", de: "Fortsetzen", fr: "Reprendre", es: "Reanudar")) { printer.sendCommand("resume") }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar"), role: .cancel) {}
        } message: { Text(lz(en: "The print will be resumed.", de: "Der Druck wird fortgesetzt.", fr: "L'impression reprendra.", es: "La impresión se reanudará.")) }
        .alert(lz(en: "Stop Print?", de: "Druck abbrechen?", fr: "Arrêter l'impression ?", es: "¿Detener impresión?"), isPresented: $showCancelConfirm) {
            Button(lz(en: "Stop", de: "Abbrechen", fr: "Arrêter", es: "Detener"), role: .destructive) { printer.sendCommand("cancel") }
            Button(lz(en: "Cancel", de: "Zurück", fr: "Annuler", es: "Cancelar"), role: .cancel) {}
        } message: { Text(lz(en: "The current print will be cancelled.", de: "Der aktuelle Druck wird abgebrochen.", fr: "L'impression en cours sera annulée.", es: "La impresión actual será cancelada.")) }
        .alert(lz(en: "Bed Temperature", de: "Bett Temperatur", fr: "Température du plateau", es: "Temperatura de la cama"), isPresented: $showBedTempInput) {
            TextField(lz(en: "Target temp (°C)", de: "Zieltemperatur (°C)", fr: "Température cible (°C)", es: "Temperatura objetivo (°C)"), text: $bedTempInput).keyboardType(.numberPad)
            Button(lz(en: "Set", de: "Setzen", fr: "Définir", es: "Establecer")) { if let t = Double(bedTempInput) { printer.setBedTemp(target: t) } }
            Button(lz(en: "Off", de: "Aus", fr: "Éteindre", es: "Apagar")) { printer.setBedTemp(target: 0) }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar"), role: .cancel) {}
        } message: { Text(lz(en: "Current: \(Int(printer.bedTemp))°C", de: "Aktuell: \(Int(printer.bedTemp))°C", fr: "Actuel : \(Int(printer.bedTemp))°C", es: "Actual: \(Int(printer.bedTemp))°C")) }
        .sheet(isPresented: $showFanSheet) {
            FanSliderSheet(title: fanSheetTitle, currentValue: fanSheetValue) { v in
                fanSheetSetter?(v)
            }
        }
        .alert(lz(en: "GCode Error", de: "GCode Fehler", fr: "Erreur GCode", es: "Error GCode"), isPresented: Binding(
            get: { printer.lastGCodeError != nil },
            set: { if !$0 { printer.lastGCodeError = nil } }
        )) {
            Button(lz(en: "OK", de: "OK", fr: "OK", es: "OK"), role: .cancel) { printer.lastGCodeError = nil }
        } message: {
            Text(printer.lastGCodeError ?? "")
        }
    }

    @ViewBuilder
    func emptySlotDropZone(slotID: String, anchorID: String) -> some View {
        let isTargetedHere = slotDropTargetID == slotID
        ZStack {
            // Filled background so the entire area is a valid drop target
            RoundedRectangle(cornerRadius: 20)
                .fill(isEditMode && isTargetedHere ? Color.accentColor.opacity(0.12) : Color.clear)
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(
                    isEditMode
                        ? (isTargetedHere ? Color.accentColor.opacity(0.9) : Color.blue.opacity(0.3))
                        : Color.clear,
                    style: isTargetedHere
                        ? StrokeStyle(lineWidth: 2.5)
                        : StrokeStyle(lineWidth: 2.5, dash: [8, 5])
                )
            if isEditMode && isTargetedHere {
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .frame(maxWidth: .infinity, minHeight: 100)
        .dropDestination(for: String.self) { droppedIDs, _ in
            guard let droppedID = droppedIDs.first else { return false }
            slotDropTargetID = nil
            if droppedID == anchorID {
                insertSpacerBefore(id: droppedID)
            } else {
                moveToEmptySlot(tileID: droppedID, afterID: anchorID)
            }
            return true
        } isTargeted: { isTargeted in
            guard isEditMode else { return }
            slotDropTargetID = isTargeted ? slotID : (slotDropTargetID == slotID ? nil : slotDropTargetID)
        }
    }

    @ViewBuilder
    func tileView(for item: DashboardItem) -> some View {
        if item.isSpacerItem {
            Color.clear
                .frame(maxWidth: .infinity, minHeight: 80)
        } else if let gid = item.customGroupID {
            customGroupTile(groupID: gid)
        } else if let tile = item.asStaticTile {
            staticTileView(for: tile)
        }
    }

    func deleteSpacerItem(_ item: DashboardItem) {
        var items = allTileItems
        items.removeAll { $0.rawID == item.rawID }
        applyTileOrder(items)
    }

    func insertSpacerBefore(id: String) {
        var items = allTileItems
        guard let idx = items.firstIndex(where: { $0.rawID == id }) else { return }
        let ws = tileWidthState(items[idx])
        items.insert(.spacer(widthState: ws), at: idx)
        applyTileOrder(items)
    }

    func moveToEmptySlot(tileID: String, afterID: String) {
        reorderItem(withID: tileID, after: afterID)
    }

    func replaceSpacer(_ spacer: DashboardItem, withTileID tileID: String) {
        var items = allTileItems
        guard let spacerIdx = items.firstIndex(where: { $0.rawID == spacer.rawID }),
              let tileIdx   = items.firstIndex(where: { $0.rawID == tileID }) else { return }
        let tile = items.remove(at: tileIdx)
        let insertAt = items.firstIndex(where: { $0.rawID == spacer.rawID }) ?? spacerIdx
        items.insert(tile, at: insertAt)
        items.removeAll { $0.rawID == spacer.rawID }
        applyTileOrder(items)
    }

    @ViewBuilder
    func editableTile(for item: DashboardItem) -> some View {
        if item.isSpacerItem {
            let isTargeted = dropTargetID == item.rawID
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(
                        isTargeted ? Color.accentColor.opacity(0.9) : Color.blue.opacity(0.3),
                        style: isTargeted
                            ? StrokeStyle(lineWidth: 2.5)
                            : StrokeStyle(lineWidth: 2.5, dash: [8, 5])
                    )
                if isTargeted {
                    Image(systemName: "plus")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Color.accentColor.opacity(0.85))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 20))
            .frame(maxWidth: .infinity, minHeight: 80)
            .scaleEffect(isTargeted ? 0.87 : 1.0)
            .modifier(WobbleModifier(active: isEditMode, seed: item.rawID.hashValue))
            .dropDestination(for: String.self) { droppedIDs, _ in
                guard let droppedID = droppedIDs.first,
                      !droppedID.hasPrefix("__sp_") else { return false }
                dropTargetID = nil
                replaceSpacer(item, withTileID: droppedID)
                return true
            } isTargeted: { isTargeted in
                dropTargetID = isTargeted ? item.rawID : (dropTargetID == item.rawID ? nil : dropTargetID)
            }
        } else {
        let isHidden = dashHiddenSet.contains(item.rawID)
        let ews = effectiveWidthState(for: item)
        let isHalf  = ews == 1
        let isThird = ews == 2
        ZStack {
            // Tile content — no interaction
            tileView(for: item)
                .opacity(isHidden ? 0.35 : 1.0)
                .allowsHitTesting(false)

            // Non-interactive dim overlay (visual only)
            if isHidden {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.black.opacity(0.38))
                    .allowsHitTesting(false)
            }

            // Full-cover hit substrate — gives .draggable() a surface to receive the
            // long-press from anywhere on the tile; no-op tap so it doesn't steal actions
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {}

            // Resize handle — shown only when context allows at least half-width
            if maxWidthState(for: item) > 0 {
            VStack(spacing: 0) {
                Spacer()
                HStack(spacing: 0) {
                    Spacer()
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(
                            isThird ? Color.orange.opacity(0.85) :
                            isHalf  ? Color.blue.opacity(0.8) :
                                      Color.black.opacity(0.55)
                        ))
                        .contentShape(Rectangle())
                        .padding(6)
                        .onTapGesture {
                            haptic(.light)
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { cycleWidth(item) }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 8, coordinateSpace: .local)
                                .onEnded { value in
                                    let cur = tileWidthState(item)
                                    let maxState = maxWidthState(for: item)
                                    if value.translation.width < -20 && cur < maxState {
                                        haptic(.light)
                                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { setTileWidth(item, state: cur + 1) }
                                    } else if value.translation.width > 20 && cur > 0 {
                                        haptic(.light)
                                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { setTileWidth(item, state: cur - 1) }
                                    }
                                }
                        )
                }
            }
            } // end resize handle

            // Height cycle button — only for the status tile
            if item.rawID == DashboardTile.status.rawValue {
            VStack(spacing: 0) {
                Spacer()
                HStack(spacing: 0) {
                    let heightIcon = statusTileSize == 0 ? "chevron.up" : statusTileSize == 1 ? "chevron.up" : "chevron.down"
                    let heightColor: Color = statusTileSize == 0 ? Color.black.opacity(0.55)
                                          : statusTileSize == 1 ? Color.blue.opacity(0.8)
                                          : Color.red.opacity(0.8)
                    Image(systemName: heightIcon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(heightColor))
                        .contentShape(Rectangle())
                        .padding(6)
                        .onTapGesture {
                            haptic(.light)
                            withAnimation(.easeInOut(duration: 0.2)) {
                                statusTileSize = (statusTileSize + 1) % 3
                                UserDefaults.standard.set(statusTileSize, forKey: lKey("status_tile_size"))
                            }
                        }
                    Spacer()
                }
            }
            } // end height button
        }
        // Eye button as overlay so its Spacer-free VStack doesn't block draggable's long-press
        .overlay(alignment: .top) {
            Button {
                haptic(.light)
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    toggleHiddenTile(item)
                }
            } label: {
                Image(systemName: isHidden ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(isHidden ? Color.red.opacity(0.7) : Color.black.opacity(0.5)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .modifier(WobbleModifier(active: isEditMode, seed: item.rawID.hashValue))
        .scaleEffect(dropTargetID == item.rawID ? 0.87 : 1.0)
        .overlay {
            if dropTargetID == item.rawID {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 2.5)
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: dropTargetID)
        .draggable(item.rawID)
        .dropDestination(for: String.self) { droppedIDs, _ in
            guard let droppedID = droppedIDs.first, droppedID != item.rawID else { return false }
            dropTargetID = nil
            swapTiles(id: droppedID, with: item.rawID)
            return true
        } isTargeted: { isTargeted in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) {
                dropTargetID = isTargeted ? item.rawID : (dropTargetID == item.rawID ? nil : dropTargetID)
            }
        }
        } // end else (non-spacer tile)
    }

    @ViewBuilder
    func customGroupTile(groupID: String) -> some View {
        let visibleCmds = settings.customCommands.filter { cmd in
            cmd.groupID == groupID && (
                cmd.printerTarget == .both
                || (cmd.printerTarget == .singleNozzle && printer.printerType == .singleNozzle)
                || (cmd.printerTarget == .u1 && printer.printerType == .snapmakerU1)
            )
        }
        if !visibleCmds.isEmpty {
            glassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(settings.displayTitle(for: groupID))
                        .font(.caption).fontWeight(.semibold)
                        .foregroundColor(.secondary).textCase(.uppercase).tracking(1)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(visibleCmds) { cmd in
                            MacroButtonView(cmd: cmd, printer: printer)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    func spoolCircle(slot: FilamentSlot) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(slot.detected
                          ? LinearGradient(colors: [slot.color, slot.color.opacity(0.55)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                          : LinearGradient(colors: [Color(white: 0.22), Color(white: 0.15)],
                                           startPoint: .top, endPoint: .bottom))
                    .frame(width: 42, height: 42)
                    .shadow(color: slot.detected ? slot.color.opacity(0.5) : .clear, radius: 8, x: 0, y: 3)
                Circle()
                    .strokeBorder(slot.detected ? Color.white.opacity(0.3) : Color.white.opacity(0.08), lineWidth: 1.5)
                    .frame(width: 42, height: 42)
                if slot.detected {
                    Circle().fill(Color.white.opacity(0.18)).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.25))
                }
            }
            Text(slot.detected ? slot.material : "–")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(slot.detected ? .primary : .secondary.opacity(0.35))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text("S\(slot.id + 1)")
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.45))
        }
    }

    @ViewBuilder
    func staticTileView(for tile: DashboardTile) -> some View {
        switch tile {
        case .webcam:
            if printer.isDemoMode {
                Image("DemoStream")
                    .resizable().scaledToFill()
                    .aspectRatio(16/9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            } else if printer.printerType == .singleNozzle,
               let streamURL = printer.webcamStreamURL ?? URL(string: "\(printer.baseURL)/webcam/?action=stream") {
                MJPEGStreamView(streamURL: streamURL,
                                rotation: printer.webcamRotation,
                                mirrorH: printer.webcamMirrorH,
                                mirrorV: printer.webcamMirrorV)
                    .aspectRatio(16/9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            } else {
                WebView(url: URL(string: "\(printer.baseURL)/webcam/webrtc")!)
                    .aspectRatio(16/9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            }

        case .webcam2:
            if let streamURL = printer.webcam2StreamURL {
                if streamURL.absoluteString.contains("webrtc") {
                    WebView(url: streamURL)
                        .aspectRatio(16/9, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                } else {
                    MJPEGStreamView(streamURL: streamURL,
                                    rotation: printer.webcam2Rotation,
                                    mirrorH: printer.webcam2MirrorH,
                                    mirrorV: printer.webcam2MirrorV)
                        .aspectRatio(16/9, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                }
            }

        case .status:
            glassCard {
                VStack(spacing: 10) {
                    HStack {
                        HStack(spacing: 6) {
                            Circle().fill(stateColor).frame(width: 10, height: 10)
                                .shadow(color: stateColor.opacity(0.8), radius: 4)
                            Text(stateLabel).font(.subheadline).bold().foregroundColor(stateColor)
                        }
                        Spacer()
                        if printer.isOnline {
                            Text("LIVE").font(.system(size: 10, weight: .bold)).foregroundColor(.green)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.green.opacity(0.15)).cornerRadius(5)
                        } else {
                            HStack(spacing: 3) {
                                Image(systemName: "wifi.slash").font(.system(size: 9))
                                Text(printer.offlineSinceLabel).font(.system(size: 10, weight: .bold))
                            }
                            .foregroundColor(.red)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.red.opacity(0.12)).cornerRadius(5)
                        }
                    }
                    if !printer.filename.isEmpty {
                        HStack {
                            Image(systemName: "doc.fill").font(.caption2).foregroundColor(.secondary)
                            Text(printer.filename).font(.caption).foregroundColor(.secondary).lineLimit(1)
                            Spacer()
                        }
                    }
                    VStack(spacing: 4) {
                        HStack {
                            Text(lz(en: "Progress", de: "Fortschritt", fr: "Progression", es: "Progreso")).font(.caption2).foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(printer.progress * 100))%").font(.caption2).bold()
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4).fill(Color(.systemGray5)).frame(height: 6)
                                RoundedRectangle(cornerRadius: 4).fill(stateColor)
                                    .frame(width: geo.size.width * min(max(printer.progress, 0), 1), height: 6)
                                    .animation(.linear(duration: 1.5), value: printer.progress)
                            }
                        }
                        .frame(height: 6)
                    }
                    if printer.extruderTempHistories[0].count >= 4 {
                        TempSparklineView(
                            extruderHistories: printer.extruderTempHistories,
                            bedHistory: printer.bedTempHistory,
                            extruderColors: printer.filamentSlots.map { slot in
                                slot.color == .gray ? .orange : slot.color
                            }
                        )
                        .frame(height: 26)
                        .padding(.vertical, 2)
                    }
                    if printer.printTimeElapsed > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "clock").font(.caption2).foregroundColor(.secondary)
                            Text(printer.formatTime(printer.printTimeElapsed)).font(.caption2).foregroundColor(.secondary)
                            Spacer()
                            if printer.printTimeRemaining > 0 {
                                Image(systemName: "timer").font(.caption2).foregroundColor(.secondary)
                                Text("~\(printer.formatTime(printer.printTimeRemaining))").font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        compactControlButton(label: lz(en: "Pause", de: "Pause", fr: "Pause", es: "Pausa"), icon: "pause.fill",
                            color: printer.printState == "printing" ? .orange : Color.orange.opacity(0.25),
                            active: printer.printState == "printing") {
                            if printer.printState == "printing" { showPauseConfirm = true }
                        }
                        compactControlButton(label: lz(en: "Resume", de: "Weiter", fr: "Reprendre", es: "Reanudar"), icon: "play.fill",
                            color: printer.printState == "paused" ? .green : Color.green.opacity(0.25),
                            active: printer.printState == "paused") {
                            if printer.printState == "paused" { showResumeConfirm = true }
                        }
                        compactControlButton(label: lz(en: "Stop", de: "Stopp", fr: "Arrêter", es: "Detener"), icon: "stop.fill",
                            color: (printer.printState == "printing" || printer.printState == "paused") ? .red : Color.red.opacity(0.25),
                            active: printer.printState == "printing" || printer.printState == "paused") {
                            if printer.printState == "printing" || printer.printState == "paused" { showCancelConfirm = true }
                        }
                    }

                    // Speed & Flow — hidden in Stufe 3
                    if statusTileSize < 2 {
                        HStack(spacing: 0) {
                            speedFlowControl(
                                label: lz(en: "Speed", de: "Tempo", fr: "Vitesse", es: "Velocidad"),
                                icon: "speedometer", value: printer.speedFactor, color: .blue,
                                onDecrease: { printer.setSpeedFactor(printer.speedFactor - 0.05) },
                                onIncrease: { printer.setSpeedFactor(printer.speedFactor + 0.05) }
                            )
                            Divider().frame(height: 36)
                            speedFlowControl(
                                label: lz(en: "Flow", de: "Flow", fr: "Débit", es: "Flujo"),
                                icon: "drop.fill", value: printer.extrudeFactor, color: .teal,
                                onDecrease: { printer.setExtrudeFactor(printer.extrudeFactor - 0.05) },
                                onIncrease: { printer.setExtrudeFactor(printer.extrudeFactor + 0.05) }
                            )
                        }
                        .background(Color.secondary.opacity(0.07)).cornerRadius(10)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    // Motor/MCU temps & current — hidden in Stufe 2 + 3
                    if statusTileSize == 0 {
                        HStack(spacing: 0) {
                            if printer.printerType == .singleNozzle {
                                hardwareInfoItem(label: "MCU", value: printer.mcuTemp.map { "\(Int($0))°C" } ?? "–", icon: "cpu", color: .orange)
                                Divider().frame(height: 28)
                                hardwareInfoItem(label: "Pi", value: printer.piTemp.map { "\(Int($0))°C" } ?? "–", icon: "thermometer.medium", color: .red)
                            } else {
                                hardwareInfoItem(label: "Motor X", value: printer.motorTempX.map { "\(Int($0))°C" } ?? "–", icon: "thermometer", color: .orange)
                                Divider().frame(height: 28)
                                hardwareInfoItem(label: "Motor Y", value: printer.motorTempY.map { "\(Int($0))°C" } ?? "–", icon: "thermometer", color: .orange)
                                Divider().frame(height: 28)
                                hardwareInfoItem(label: lz(en: "Current", de: "Strom", fr: "Courant", es: "Corriente"),
                                                 value: String(format: "%.1fA", printer.currentDraw), icon: "bolt.fill", color: .yellow)
                            }
                        }
                        .background(Color.secondary.opacity(0.07)).cornerRadius(10)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                }
            }

        case .screen:
            if printer.printerType == .singleNozzle {
                EmptyView()
            } else {
                ZStack {
                    Color.black
                    if printer.isDemoMode {
                        Image("DemoScreen")
                            .resizable()
                            .scaledToFill()
                    } else {
                        WebView(url: URL(string: "\(printer.baseURL)/screen/")!, fitWidth: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .aspectRatio(5/3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            }

        case .extruder:
            glassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Extruder").font(.caption).fontWeight(.semibold)
                        .foregroundColor(.secondary).textCase(.uppercase).tracking(1)

                    if printer.printerType == .singleNozzle {
                        SingleNozzleCombinedCard(printer: printer)
                    } else if printer.extruderCount == 1 {
                        ExtruderCard(
                            index: 0,
                            temp: printer.extruderTemps[safe: 0] ?? 0,
                            target: printer.extruderTargets[safe: 0] ?? 0,
                            slot: printer.filamentSlots[safe: 0] ?? FilamentSlot(id: 0, color: .gray, colorHex: "888888", material: "–", detected: false),
                            nozzle: printer.nozzleDiameters[safe: 0] ?? 0.4,
                            nozzleLoaded: printer.nozzleDiametersLoaded[safe: 0] ?? false,
                            switchCount: printer.switchCounts[safe: 0] ?? 0,
                            isActive: printer.activeExtruderIndex == 0,
                            isPrinting: printer.printState == "printing",
                            showAttachButton: false,
                            onAttach: { printer.attachExtruder(0) },
                            onSetTemp: { t in printer.setExtruderTemp(extruder: 0, target: t) }
                        )
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(0..<printer.extruderCount, id: \.self) { idx in
                                ExtruderCard(
                                    index: idx,
                                    temp: printer.extruderTemps[safe: idx] ?? 0,
                                    target: printer.extruderTargets[safe: idx] ?? 0,
                                    slot: printer.filamentSlots[safe: idx] ?? FilamentSlot(id: idx, color: .gray, colorHex: "888888", material: "–", detected: false),
                                    nozzle: printer.nozzleDiameters[safe: idx] ?? 0.4,
                                    nozzleLoaded: printer.nozzleDiametersLoaded[safe: idx] ?? false,
                                    switchCount: printer.switchCounts[safe: idx] ?? 0,
                                    isActive: printer.activeExtruderIndex == idx,
                                    isPrinting: printer.printState == "printing",
                                    showAttachButton: printer.printerType != .singleNozzle,
                                    onAttach: { printer.attachExtruder(idx) },
                                    onSetTemp: { t in printer.setExtruderTemp(extruder: idx, target: t) }
                                )
                            }
                        }
                    }
                }
            }

        case .filament:
            if printer.printerType == .singleNozzle {
                EmptyView()
            } else {
                glassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(lz(en: "Filament", de: "Filament", fr: "Filament", es: "Filamento"))
                            .font(.caption).fontWeight(.semibold)
                            .foregroundColor(.secondary).textCase(.uppercase).tracking(1)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ConfirmableButton(
                                label: lz(en: "Eject", de: "Auswerfen", fr: "Éjecter", es: "Expulsar"),
                                icon: "arrow.up.circle.fill", color: .orange,
                                confirmTitle: lz(en: "Eject Filament?", de: "Filament auswerfen?", fr: "Éjecter le filament ?", es: "¿Expulsar filamento?"),
                                confirmMessage: lz(en: "The filament will be unloaded.", de: "Das Filament wird ausgeworfen.", fr: "Le filament va être éjecté.", es: "El filamento será expulsado."),
                                printer: printer) { printer.unloadFilament() }
                            ConfirmableButton(
                                label: lz(en: "Flush", de: "Spülen", fr: "Purger", es: "Purgar"),
                                icon: "arrow.down.circle.fill", color: .teal,
                                confirmTitle: lz(en: "Flush Filament?", de: "Filament spülen?", fr: "Purger le filament ?", es: "¿Purgar filamento?"),
                                confirmMessage: lz(en: "A flush sequence will run.", de: "Eine Spülsequenz wird ausgeführt.", fr: "Une séquence de purge va démarrer.", es: "Se ejecutará una secuencia de purga."),
                                printer: printer) { printer.sendGCode("INNER_FLUSH_FILAMENT") }
                            ConfirmableButton(
                                label: lz(en: "Clean", de: "Reinigen", fr: "Nettoyer", es: "Limpiar"),
                                icon: "paintbrush.fill", color: .orange,
                                confirmTitle: lz(en: "Clean Nozzle?", de: "Düse reinigen?", fr: "Nettoyer la buse ?", es: "¿Limpiar boquilla?"),
                                confirmMessage: lz(en: "A nozzle cleaning sequence will run.", de: "Eine Düsenreinigung wird gestartet.", fr: "Une séquence de nettoyage de buse va démarrer.", es: "Se iniciará una secuencia de limpieza de boquilla."),
                                printer: printer) { printer.cleanNozzleRough() }
                            ConfirmableButton(
                                label: lz(en: "Clean + Purge", de: "Reinigen + Poop entsorgen", fr: "Nettoyer + Évacuer", es: "Limpiar + Desechar"),
                                icon: "trash.circle.fill", color: .red,
                                confirmTitle: lz(en: "Clean + Purge?", de: "Reinigen + Poop entsorgen?", fr: "Nettoyer + Évacuer ?", es: "¿Limpiar + Desechar?"),
                                confirmMessage: lz(en: "Cleaning and purge discard will run.", de: "Reinigen und Poop entsorgen wird gestartet.", fr: "Le nettoyage et l'évacuation vont démarrer.", es: "Se iniciará la limpieza y descarte."),
                                printer: printer) { printer.cleanNozzleRoughDiscard() }
                        }
                    }
                }
            }

        case .spools:
            if printer.printerType == .singleNozzle {
                EmptyView()
            } else {
            glassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(lz(en: "Spools", de: "Spulen", fr: "Bobines", es: "Bobinas"))
                        .font(.caption).fontWeight(.semibold)
                        .foregroundColor(.secondary).textCase(.uppercase).tracking(1)
                    let isGrid = effectiveWidthState(for: .tile(.spools)) > 0
                    if isGrid {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                            ForEach(printer.filamentSlots) { slot in
                                spoolCircle(slot: slot)
                            }
                        }
                    } else {
                        HStack(spacing: 0) {
                            ForEach(printer.filamentSlots) { slot in
                                spoolCircle(slot: slot)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
            } // end else singleNozzle

        case .cleaning:
            EmptyView()

        case .calibration:
            glassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(lz(en: "Calibration", de: "Kalibrierung", fr: "Calibration", es: "Calibración"))
                        .font(.caption).fontWeight(.semibold)
                        .foregroundColor(.secondary).textCase(.uppercase).tracking(1)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        if printer.printerType == .singleNozzle {
                            ConfirmableButton(
                                label: lz(en: "Bed Mesh", de: "Bett-Mesh", fr: "Maillage lit", es: "Malla cama"),
                                icon: "grid", color: .blue,
                                confirmTitle: lz(en: "Bed Mesh Calibrate?", de: "Bett-Mesh kalibrieren?", fr: "Calibrer le maillage ?", es: "¿Calibrar malla cama?"),
                                confirmMessage: lz(en: "This may take several minutes.", de: "Dies kann mehrere Minuten dauern.", fr: "Cela peut prendre plusieurs minutes.", es: "Esto puede tardar varios minutos."),
                                printer: printer) { printer.calibrateBedMeshKlipper() }
                            ConfirmableButton(
                                label: lz(en: "Screw Tilt", de: "Schrauben", fr: "Réglage vis", es: "Inclinación"),
                                icon: "arrow.up.and.down.and.arrow.left.and.right", color: .teal,
                                confirmTitle: lz(en: "Run Screw Tilt Adjust?", de: "Schrauben Abtasten starten?", fr: "Lancer réglage vis ?", es: "¿Ajustar inclinación?"),
                                confirmMessage: lz(en: "This may take several minutes.", de: "Dies kann mehrere Minuten dauern.", fr: "Cela peut prendre plusieurs minutes.", es: "Esto puede tardar varios minutos."),
                                printer: printer) { printer.calibrateScrewTilt() }
                            ConfirmableButton(
                                label: "Input Shaper X",
                                icon: "waveform.path", color: .orange,
                                confirmTitle: lz(en: "Run Input Shaper X?", de: "Input Shaper X starten?", fr: "Lancer Input Shaper X ?", es: "¿Ejecutar Input Shaper X?"),
                                confirmMessage: lz(en: "This may take several minutes.", de: "Dies kann mehrere Minuten dauern.", fr: "Cela peut prendre plusieurs minutes.", es: "Esto puede tardar varios minutos."),
                                printer: printer) { printer.calibrateShaperX() }
                            ConfirmableButton(
                                label: "Input Shaper Y",
                                icon: "waveform", color: .purple,
                                confirmTitle: lz(en: "Run Input Shaper Y?", de: "Input Shaper Y starten?", fr: "Lancer Input Shaper Y ?", es: "¿Ejecutar Input Shaper Y?"),
                                confirmMessage: lz(en: "This may take several minutes.", de: "Dies kann mehrere Minuten dauern.", fr: "Cela peut prendre plusieurs minutes.", es: "Esto puede tardar varios minutos."),
                                printer: printer) { printer.calibrateShaperY() }
                        } else {
                            ConfirmableButton(
                                label: lz(en: "Bed Mesh", de: "Bett-Mesh", fr: "Maillage lit", es: "Malla cama"),
                                icon: "grid", color: .blue,
                                confirmTitle: lz(en: "Bed Mesh Calibrate?", de: "Bett-Mesh kalibrieren?", fr: "Calibrer le maillage ?", es: "¿Calibrar malla cama?"),
                                confirmMessage: lz(en: "This may take several minutes.", de: "Dies kann mehrere Minuten dauern.", fr: "Cela peut prendre plusieurs minutes.", es: "Esto puede tardar varios minutos."),
                                printer: printer) { printer.calibrateBedMesh() }
                            ConfirmableButton(
                                label: lz(en: "Home All", de: "Alle homen", fr: "Homing complet", es: "Homing total"),
                                icon: "house.fill", color: .purple,
                                confirmTitle: lz(en: "Home all axes?", de: "Alle Achsen homen?", fr: "Homing de tous les axes ?", es: "¿Homear todos los ejes?"),
                                confirmMessage: lz(en: "All axes will be homed (G28).", de: "Alle Achsen werden gehomt (G28).", fr: "Tous les axes vont être référencés (G28).", es: "Se iniciará el homing de todos los ejes (G28)."),
                                printer: printer) { printer.homeAxes() }
                            ConfirmableButton(
                                label: lz(en: "XYZ Calibrate", de: "XYZ Kalibrierung", fr: "Calibration XYZ", es: "Calibración XYZ"),
                                icon: "move.3d", color: .green,
                                confirmTitle: lz(en: "XYZ Calibrate?", de: "XYZ Kalibrierung starten?", fr: "Calibrer XYZ ?", es: "¿Calibrar XYZ?"),
                                confirmMessage: lz(
                                    en: "⚠️ Clean the nozzle thoroughly and remove the print plate before starting.",
                                    de: "⚠️ Düse gründlich reinigen und Druckplatte entfernen, bevor du startest.",
                                    fr: "⚠️ Nettoyer soigneusement la buse et retirer le plateau avant de démarrer.",
                                    es: "⚠️ Limpia bien la boquilla y retira la placa de impresión antes de empezar."),
                                printer: printer) { printer.calibrateXYZ() }
                            ConfirmableButton(
                                label: "Input Shaper",
                                icon: "waveform", color: .orange,
                                confirmTitle: lz(en: "Run Input Shaper?", de: "Input Shaper starten?", fr: "Lancer Input Shaper ?", es: "¿Ejecutar Input Shaper?"),
                                confirmMessage: lz(en: "This may take several minutes.", de: "Dies kann mehrere Minuten dauern.", fr: "Cela peut prendre plusieurs minutes.", es: "Esto puede tardar varios minutos."),
                                printer: printer) { printer.calibrateShaper() }
                        }
                    }
                }
            }

        case .stats:
            glassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(lz(en: "Statistics", de: "Statistiken", fr: "Statistiques", es: "Estadísticas"))
                        .font(.caption).fontWeight(.semibold)
                        .foregroundColor(.secondary).textCase(.uppercase).tracking(1)

                    if printer.totalJobs == 0 {
                        HStack {
                            Spacer()
                            VStack(spacing: 6) {
                                Image(systemName: "chart.bar.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(.secondary.opacity(0.4))
                                Text(lz(en: "No data yet", de: "Noch keine Daten", fr: "Pas encore de données", es: "Sin datos aún"))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            .padding(.vertical, 8)
                            Spacer()
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            statCard(
                                icon: "printer.fill",
                                value: "\(printer.totalJobs)",
                                label: lz(en: "Total Prints", de: "Drucke gesamt", fr: "Impressions", es: "Impresiones"),
                                gradient: [Color(hex: "4facfe") ?? .blue, Color(hex: "00f2fe") ?? .cyan]
                            )
                            statCard(
                                icon: "clock.fill",
                                value: {
                                    let h = Int(printer.totalPrintTime) / 3600
                                    let m = (Int(printer.totalPrintTime) % 3600) / 60
                                    return h >= 100 ? "\(h)h" : (h > 0 ? "\(h)h \(m)m" : "\(m)m")
                                }(),
                                label: lz(en: "Print Time", de: "Druckzeit", fr: "Temps d'impression", es: "Tiempo total"),
                                gradient: [Color(hex: "a18cd1") ?? .purple, Color(hex: "fbc2eb") ?? .pink]
                            )
                            statCard(
                                icon: "cylinder.fill",
                                value: {
                                    let m = printer.totalFilamentUsedMm / 1000
                                    return m >= 1000 ? String(format: "%.0fm", m) : String(format: "%.1fm", m)
                                }(),
                                label: lz(en: "Filament", de: "Filament", fr: "Filament", es: "Filamento"),
                                gradient: [Color(hex: "fd7043") ?? .orange, Color(hex: "ff8a65") ?? .orange]
                            )
                            statCard(
                                icon: "trophy.fill",
                                value: {
                                    let h = Int(printer.longestPrintTime) / 3600
                                    let m = (Int(printer.longestPrintTime) % 3600) / 60
                                    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
                                }(),
                                label: lz(en: "Longest Print", de: "Längster Druck", fr: "Plus long", es: "Más largo"),
                                gradient: [Color(hex: "43e97b") ?? .green, Color(hex: "38f9d7") ?? .teal]
                            )
                        }
                    }
                }
            }

        case .bed:
            if printer.printerType == .singleNozzle {
                EmptyView()
            } else {
            glassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(lz(en: "Bed & Chamber", de: "Heizbett & Bauraum", fr: "Plateau & Enceinte", es: "Cama & Cámara")).font(.caption).fontWeight(.semibold)
                        .foregroundColor(.secondary).textCase(.uppercase).tracking(1)
                    GeometryReader { geo in
                        let compact = geo.size.width < 330
                        let tempFont: CGFloat  = compact ? 20 : 28
                        let unitFont: CGFloat  = compact ? 10 : 12
                        let labelFont: CGFloat = compact ? 9  : 11
                        let infoFont: CGFloat  = compact ? 9  : 10
                        let pad: CGFloat       = compact ? 8  : 10
                        let houseSize: CGFloat = compact ? 15 : 18
                        let bulbSize: CGFloat  = compact ? 17 : 22
                        let hSpacing: CGFloat  = compact ? 5  : 8
                        HStack(spacing: 6) {
                            Button(action: { bedTempInput = "\(Int(printer.bedTarget))"; showBedTempInput = true }) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12).fill(.thinMaterial)
                                    RoundedRectangle(cornerRadius: 12).fill(
                                        LinearGradient(
                                            colors: [Color(hue: 0.12, saturation: 0.75, brightness: 0.80).opacity(0.28),
                                                     Color(hue: 0.10, saturation: 0.55, brightness: 0.60).opacity(0.10)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
                                    HStack(alignment: .center, spacing: hSpacing) {
                                        VStack(alignment: .leading, spacing: 0) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "square.fill")
                                                    .font(.system(size: 7)).foregroundColor(.red)
                                                Text(lz(en: "Bed", de: "Bett", fr: "Lit", es: "Cama"))
                                                    .font(.system(size: labelFont, weight: .semibold)).foregroundColor(.secondary)
                                            }
                                            Spacer(minLength: 0)
                                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                                Text("\(Int(printer.bedTemp))")
                                                    .font(.system(size: tempFont, weight: .bold, design: .rounded))
                                                    .foregroundColor(.primary)
                                                    .minimumScaleFactor(0.7)
                                                    .lineLimit(1)
                                                Text("°C")
                                                    .font(.system(size: unitFont, weight: .medium))
                                                    .foregroundColor(.secondary)
                                            }
                                            Spacer(minLength: 2)
                                            HStack {
                                                Text(printer.bedTarget > 0 ? "→ \(Int(printer.bedTarget))°C" : lz(en: "Off", de: "Aus", fr: "Éteint", es: "Apagado"))
                                                    .font(.system(size: infoFont, weight: .medium)).foregroundColor(.secondary)
                                                    .lineLimit(1)
                                                Spacer()
                                                Image(systemName: "pencil")
                                                    .font(.system(size: 8)).foregroundColor(.secondary)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        Button(action: {
                                            haptic()
                                            if printer.isBusy { showHomingBusy = true } else { showHomingDialog = true }
                                        }) {
                                            Image(systemName: "house.fill")
                                                .font(.system(size: houseSize, weight: .semibold))
                                                .foregroundColor(.primary.opacity(0.55))
                                        }
                                        .buttonStyle(.plain)
                                        .confirmationDialog(lz(en: "Homing", de: "Homing", fr: "Homing", es: "Homing"), isPresented: $showHomingDialog, titleVisibility: .visible) {
                                            Button(lz(en: "Yes", de: "Ja", fr: "Oui", es: "Sí")) { printer.homeAxes() }
                                            Button(lz(en: "No", de: "Nein", fr: "Non", es: "No")) {}
                                        }
                                        .alert("Drucker beschäftigt", isPresented: $showHomingBusy) {
                                            Button("OK", role: .cancel) {}
                                        } message: {
                                            Text(printer.printState == "printing"
                                                 ? "Ein Druck läuft. Nach dem Druck wieder verfügbar."
                                                 : "Es läuft gerade ein Befehl. Bitte warte bis er abgeschlossen ist.")
                                        }
                                    }
                                    .padding(pad)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)

                            if printer.hasChamber || printer.printerType == .snapmakerU1 {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(.ultraThinMaterial)
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(LinearGradient(
                                            colors: [Color.purple.opacity(0.22), Color.indigo.opacity(0.12)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
                                    HStack(alignment: .center, spacing: hSpacing) {
                                        VStack(alignment: .leading, spacing: 0) {
                                            HStack(spacing: 3) {
                                                Image(systemName: "thermometer.medium")
                                                    .font(.system(size: 7, weight: .semibold))
                                                    .foregroundColor(.purple)
                                                Text(lz(en: "Chamber", de: "Bauraum", fr: "Enceinte", es: "Cámara"))
                                                    .font(.system(size: labelFont, weight: .semibold))
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                                    .minimumScaleFactor(0.8)
                                            }
                                            Spacer(minLength: 0)
                                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                                Text("\(Int(printer.chamberTemp))")
                                                    .font(.system(size: tempFont, weight: .bold, design: .rounded))
                                                    .foregroundColor(.primary)
                                                    .minimumScaleFactor(0.7)
                                                    .lineLimit(1)
                                                Text("°C")
                                                    .font(.system(size: unitFont, weight: .medium))
                                                    .foregroundColor(.secondary)
                                            }
                                            Spacer(minLength: 2)
                                            HStack(spacing: 4) {
                                                Image(systemName: "fan.fill")
                                                    .font(.system(size: infoFont))
                                                    .foregroundColor(.blue)
                                                Button(action: {
                                                    fanSheetTitle = lz(en: "Cavity Fan", de: "Bauraum-Lüfter", fr: "Ventilateur enceinte", es: "Ventilador cámara")
                                                    fanSheetValue = printer.cavityFanSpeed
                                                    fanSheetSetter = { printer.setCavityFanSpeed($0) }
                                                    showFanSheet = true
                                                }) {
                                                    Text("\(Int(printer.cavityFanSpeed * 100))%")
                                                        .font(.system(size: infoFont, weight: .semibold))
                                                        .foregroundColor(.primary)
                                                }
                                                .buttonStyle(.plain)
                                                if !compact {
                                                    Spacer()
                                                    Image(systemName: "wind")
                                                        .font(.system(size: 10))
                                                        .foregroundColor(printer.purifierDetected ? .mint : .secondary.opacity(0.35))
                                                    Text(printer.purifierDetected
                                                         ? (printer.purifierExhaustSpeed > 0 ? "\(Int(printer.purifierExhaustSpeed * 100))%" : lz(en: "Standby", de: "Standby", fr: "Standby", es: "Standby"))
                                                         : "–")
                                                        .font(.system(size: 10))
                                                        .foregroundColor(printer.purifierDetected ? .mint : .secondary.opacity(0.35))
                                                } else {
                                                    Spacer()
                                                }
                                            }
                                        }
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        Button(action: { printer.toggleChamberLed() }) {
                                            Image(systemName: printer.chamberLedOn ? "lightbulb.fill" : "lightbulb")
                                                .font(.system(size: bulbSize))
                                                .foregroundColor(printer.chamberLedOn ? .yellow : .secondary.opacity(0.5))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(pad)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .frame(height: 110)
                        .frame(maxWidth: .infinity)
                    }
                    .frame(height: 110)
                }
            }
            } // end else singleNozzle (bed tile)

        case .smartPlug:
            SmartPlugTileView(
                plugIP: printer.smartPlugIP,
                deviceID: printer.smartPlugDeviceID,
                localKey: printer.smartPlugLocalKey,
                plugType: printer.smartPlugType,
                isBusy: printer.isBusy
            )

        }
    }

    @ViewBuilder
    func glassCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(.thinMaterial)
            RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06))
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            content().padding(14)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    func actionTileButton(label: String, icon: String, color: Color, fullWidth: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: { haptic(); action() }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if fullWidth { Spacer() }
            }
            .foregroundColor(.white)
            .frame(minWidth: 0, maxWidth: fullWidth ? .infinity : nil)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [color, color.opacity(0.75)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    func filamentButton(label: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: { haptic(); action() }) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(colors: [color, color.opacity(0.65)],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: color.opacity(0.4), radius: 6, x: 0, y: 3)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    func speedFlowControl(label: String, icon: String, value: Double, color: Color,
                          onDecrease: @escaping () -> Void, onIncrease: @escaping () -> Void) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 9)).foregroundColor(color)
                Text(label).font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
            }
            HStack(spacing: 10) {
                Button(action: onDecrease) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 22)).foregroundColor(color)
                }
                .buttonStyle(.plain)
                Text("\(Int(value * 100))%")
                    .font(.system(size: 15, weight: .bold)).frame(minWidth: 44)
                    .contentTransition(.numericText())
                Button(action: onIncrease) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22)).foregroundColor(color)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    func statCard(icon: String, value: String, label: String, gradient: [Color]) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: gradient.map { $0.opacity(0.22) },
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(LinearGradient(colors: gradient.map { $0.opacity(0.5) },
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                    Spacer()
                }
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .padding(10)
        }
    }

    func hardwareInfoItem(label: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 10)).foregroundColor(color)
            Text(value).font(.system(size: 12, weight: .bold))
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    func compactControlButton(label: String, icon: String, color: Color, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                Text(label).font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(active ? .white : color)
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(active ? color : color.opacity(0.08)).cornerRadius(10)
        }
    }
}

// MARK: - Files View
struct FilesView: View {
    @ObservedObject var printer: PrinterService
    var allServices: [PrinterService] = []
    @State private var fileToDelete: PrinterFile? = nil
    @State private var fileToStart: PrinterFile? = nil
    @State private var searchText: String = ""
    @State private var fileToCopy: PrinterFile? = nil
    @State private var showCopyPicker = false
    @State private var isCopying = false
    @State private var copyResultMessage: String? = nil
    @State private var showCopyResult = false
    @State private var showTypeMismatchWarning = false
    @State private var pendingCopyTarget: PrinterService? = nil

    var otherServices: [PrinterService] {
        allServices.filter { $0.baseURL != printer.baseURL }
    }

    func copyFile(_ file: PrinterFile, to target: PrinterService) {
        isCopying = true
        printer.downloadFileData(filename: file.filename) { data in
            guard let data = data else {
                isCopying = false
                copyResultMessage = lz(en: "Download failed.", de: "Download fehlgeschlagen.", fr: "Échec du téléchargement.", es: "Error al descargar.")
                showCopyResult = true
                return
            }
            target.uploadFileData(filename: file.filename, data: data) { success in
                isCopying = false
                copyResultMessage = success
                    ? lz(en: "'\(file.displayName)' copied to \(target.name).", de: "'\(file.displayName)' nach \(target.name) kopiert.", fr: "'\(file.displayName)' copié vers \(target.name).", es: "'\(file.displayName)' copiado a \(target.name).")
                    : lz(en: "Upload to \(target.name) failed.", de: "Upload zu \(target.name) fehlgeschlagen.", fr: "Échec de l'envoi vers \(target.name).", es: "Error al enviar a \(target.name).")
                showCopyResult = true
                if success { target.fetchFiles() }
            }
        }
    }

    func requestCopy(_ file: PrinterFile, to target: PrinterService) {
        if printer.printerType == .singleNozzle || printer.printerType != target.printerType {
            fileToCopy = file
            pendingCopyTarget = target
            showTypeMismatchWarning = true
        } else {
            copyFile(file, to: target)
        }
    }

    var filteredFiles: [PrinterFile] {
        searchText.isEmpty ? printer.files : printer.files.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField(lz(en: "Search files...", de: "Datei suchen...", fr: "Rechercher...", es: "Buscar archivos..."), text: $searchText)
            }
            .padding(10).background(.ultraThinMaterial).cornerRadius(10)
            .padding(.horizontal).padding(.vertical, 8)

            if printer.isLoadingFiles {
                Spacer(); ProgressView(lz(en: "Loading files...", de: "Lade Dateien...", fr: "Chargement...", es: "Cargando archivos...")); Spacer()
            } else if let error = printer.fileError {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(.orange)
                    Text(error).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Button(lz(en: "Retry", de: "Erneut versuchen", fr: "Réessayer", es: "Reintentar")) { printer.fetchFiles() }.buttonStyle(.borderedProminent)
                }
                .padding(); Spacer()
            } else if printer.files.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "doc.badge.plus").font(.largeTitle).foregroundColor(.secondary)
                    Text(lz(en: "No G-Code Files", de: "Keine G-Code Dateien", fr: "Pas de fichiers G-Code", es: "Sin archivos G-Code")).foregroundColor(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(filteredFiles) { file in
                        HStack(spacing: 10) {
                            if let thumbURL = printer.fileThumbnails[file.filename] {
                                AsyncImage(url: thumbURL) { img in
                                    img.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Color.secondary.opacity(0.15)
                                }
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(file.displayName).font(.subheadline).bold().lineLimit(1)
                                HStack {
                                    Label(file.formattedSize, systemImage: "doc").font(.caption).foregroundColor(.secondary)
                                    Spacer()
                                    Text(file.formattedDate).font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.2), lineWidth: 1))
                        .contextMenu {
                            Button { fileToStart = file } label: {
                                Label(lz(en: "Print", de: "Drucken", fr: "Imprimer", es: "Imprimir"), systemImage: "play.fill")
                            }
                            if !otherServices.isEmpty {
                                if otherServices.count == 1 {
                                    Button {
                                        requestCopy(file, to: otherServices[0])
                                    } label: {
                                        Label(lz(en: "Send to \(otherServices[0].name)", de: "Senden an \(otherServices[0].name)", fr: "Envoyer à \(otherServices[0].name)", es: "Enviar a \(otherServices[0].name)"), systemImage: "arrow.right.circle")
                                    }
                                } else {
                                    Button {
                                        fileToCopy = file
                                        showCopyPicker = true
                                    } label: {
                                        Label(lz(en: "Send to printer…", de: "Senden an Drucker…", fr: "Envoyer à imprimante…", es: "Enviar a impresora…"), systemImage: "arrow.right.circle")
                                    }
                                }
                            }
                            Divider()
                            Button(role: .destructive) { fileToDelete = file } label: {
                                Label(lz(en: "Delete", de: "Löschen", fr: "Supprimer", es: "Eliminar"), systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { fileToDelete = file } label: { Label(lz(en: "Delete", de: "Löschen", fr: "Supprimer", es: "Eliminar"), systemImage: "trash") }
                            Button { fileToStart = file } label: { Label(lz(en: "Print", de: "Drucken", fr: "Imprimer", es: "Imprimir"), systemImage: "play.fill") }.tint(.green)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { printer.fetchFiles() }
            }
        }
        .onAppear { printer.fetchFiles() }
        .alert(lz(en: "Delete File?", de: "Datei löschen?", fr: "Supprimer le fichier ?", es: "¿Eliminar archivo?"), isPresented: Binding(get: { fileToDelete != nil }, set: { if !$0 { fileToDelete = nil } })) {
            Button(lz(en: "Delete", de: "Löschen", fr: "Supprimer", es: "Eliminar"), role: .destructive) { if let f = fileToDelete { printer.deleteFile(filename: f.filename) }; fileToDelete = nil }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar"), role: .cancel) { fileToDelete = nil }
        } message: { Text("\(fileToDelete?.displayName ?? "") \(lz(en: "really delete?", de: "wirklich löschen?", fr: "vraiment supprimer ?", es: "¿realmente eliminar?"))") }
        .alert(lz(en: "Start Print?", de: "Druck starten?", fr: "Lancer l'impression ?", es: "¿Iniciar impresión?"), isPresented: Binding(get: { fileToStart != nil }, set: { if !$0 { fileToStart = nil } })) {
            Button(lz(en: "Start", de: "Starten", fr: "Démarrer", es: "Iniciar")) { if let f = fileToStart { printer.startPrint(filename: f.filename) }; fileToStart = nil }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar"), role: .cancel) { fileToStart = nil }
        } message: { Text("\(fileToStart?.displayName ?? "") \(lz(en: "start printing?", de: "drucken?", fr: "lancer ?", es: "¿imprimir?"))") }
        .alert(lz(en: "Result", de: "Ergebnis", fr: "Résultat", es: "Resultado"), isPresented: $showCopyResult) {
            Button("OK", role: .cancel) { copyResultMessage = nil }
        } message: { Text(copyResultMessage ?? "") }
        .alert(lz(en: "Different Printer Type", de: "Anderer Druckertyp", fr: "Type d'imprimante différent", es: "Tipo de impresora diferente"), isPresented: $showTypeMismatchWarning) {
            Button(lz(en: "Send anyway", de: "Trotzdem senden", fr: "Envoyer quand même", es: "Enviar de todos modos")) {
                if let file = fileToCopy, let target = pendingCopyTarget {
                    copyFile(file, to: target)
                }
                pendingCopyTarget = nil
            }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar"), role: .cancel) {
                fileToCopy = nil
                pendingCopyTarget = nil
            }
        } message: {
            Text(lz(
                en: "The G-Code is not modified. The print may not work correctly on a different printer type.",
                de: "Der G-Code wird nicht angepasst. Der Druck funktioniert auf einem anderen Druckertyp möglicherweise nicht korrekt.",
                fr: "Le G-Code n'est pas modifié. L'impression peut ne pas fonctionner correctement sur un type d'imprimante différent.",
                es: "El G-Code no se modifica. La impresión puede no funcionar correctamente en un tipo de impresora diferente."
            ))
        }
        .sheet(isPresented: $showCopyPicker) {
            NavigationView {
                List(otherServices, id: \.baseURL) { target in
                    Button(action: {
                        showCopyPicker = false
                        if let file = fileToCopy {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                requestCopy(file, to: target)
                            }
                        }
                    }) {
                        HStack(spacing: 14) {
                            Image(systemName: "printer.fill").foregroundColor(.blue).frame(width: 28)
                            Text(target.name).font(.subheadline)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
                .navigationTitle(lz(en: "Send to printer", de: "Senden an Drucker", fr: "Envoyer à", es: "Enviar a"))
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarItems(trailing: Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar")) {
                    showCopyPicker = false
                })
            }
            .presentationDetents([.medium])
        }
        .overlay {
            if isCopying {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView().scaleEffect(1.4).tint(.white)
                        Text(lz(en: "Copying…", de: "Kopieren…", fr: "Copie en cours…", es: "Copiando…"))
                            .font(.subheadline).foregroundColor(.white)
                    }
                    .padding(32)
                    .background(Color(.systemGray5).opacity(0.95))
                    .cornerRadius(16)
                }
            }
        }
    }
}

// MARK: - Firmware Config View (Expert Mode)
struct FirmwareConfigView: View {
    let baseURL: String

    var body: some View {
        if let url = URL(string: baseURL + "/firmware-config/") {
            WebView(url: url)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

// MARK: - PrintControlView
struct PrintControlView: View {
    let printerService: PrinterService
    var printerID: String = ""
    var themeColorKey: String = "blue"
    var allServices: [PrinterService] = []
    @State private var selectedTab = 0
    @State private var hideTopPicker = false
    @AppStorage("expert_mode_enabled") private var expertModeEnabled: Bool = false
    @AppStorage("show_timelapse_tab") private var showTimelapseTab: Bool = true
    @AppStorage("show_klipper_tab") private var showKlipperTab: Bool = true

    private var showFirmwareTab: Bool {
        expertModeEnabled && printerService.printerType == .snapmakerU1
    }

    var themeColor: Color {
        if let c = Color(hex: themeColorKey) { return c }
        return appThemes.first { $0.key == themeColorKey }?.color ?? .blue
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if !hideTopPicker {
                    Picker("", selection: $selectedTab) {
                        Text("Dashboard").tag(0)
                        Text(lz(en: "Files", de: "Dateien", fr: "Fichiers", es: "Archivos")).tag(1)
                        if showKlipperTab {
                            Text("Klipper").tag(2)
                        }
                        if showTimelapseTab {
                            Text("Timelapse").tag(3)
                        }
                        if showFirmwareTab {
                            Text(lz(en: "Config", de: "Konfiguration", fr: "Config", es: "Config")).tag(4)
                        }
                    }
                    .pickerStyle(.segmented).padding()
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if selectedTab == 0 { DashboardView(printer: printerService, printerID: printerID) }
                else if selectedTab == 1 { FilesView(printer: printerService, allServices: allServices) }
                else if selectedTab == 2 && showKlipperTab {
                    WebView(url: URL(string: printerService.baseURL)!)
                        .ignoresSafeArea(edges: .bottom)
                } else if selectedTab == 3 && showTimelapseTab {
                    TimelapseView(baseURL: printerService.baseURL, apiKey: printerService.apiKey)
                } else if selectedTab == 4 && showFirmwareTab {
                    FirmwareConfigView(baseURL: printerService.baseURL)
                } else {
                    DashboardView(printer: printerService, printerID: printerID)
                        .onAppear { selectedTab = 0 }
                }
            }
            .onPreferenceChange(HidePickerKey.self) { hide in
                withAnimation(.easeInOut(duration: 0.25)) { hideTopPicker = hide }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                printerService.themeHex = themeColor.hexString
                printerService.writeWidgetData()
                WidgetCenter.shared.reloadAllTimelines()
            }
            .onChange(of: themeColorKey) {
                printerService.themeHex = themeColor.hexString
                printerService.writeWidgetData()
                WidgetCenter.shared.reloadAllTimelines()
            }
            .background(
                ZStack {
                    LinearGradient(
                        colors: [themeColor.opacity(0.45), themeColor.opacity(0.15)],
                        startPoint: .top, endPoint: .bottom
                    )
                    LinearGradient(
                        colors: [Color.white.opacity(0.04), Color.clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
                .ignoresSafeArea()
            )
            .navigationTitle(printerService.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack {
                        Text(printerService.name)
                            .font(.system(size: 20, weight: .bold))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationViewStyle(.stack)
        .tint(themeColor)
    }
}

// MARK: - Printer Pager (home-screen swipe between printers)
struct PrinterPagerView: View {
    let printers: [(PrinterConfig, PrinterService)]
    let allServices: [PrinterService]
    @Binding var currentPage: Int

    var body: some View {
        ZStack {
            TabView(selection: $currentPage) {
                ForEach(Array(printers.enumerated()), id: \.0) { idx, pair in
                    PrintControlView(
                        printerService: pair.1,
                        printerID: pair.0.id.uuidString,
                        themeColorKey: pair.0.themeColor,
                        allServices: allServices
                    )
                    .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            // Page dots — shown only when there are multiple printers
            if printers.count > 1 {
                VStack {
                    Spacer()
                    HStack(spacing: 7) {
                        ForEach(0..<printers.count, id: \.self) { idx in
                            Capsule()
                                .fill(idx == currentPage
                                      ? Color.white
                                      : Color.white.opacity(0.35))
                                .frame(width: idx == currentPage ? 18 : 6, height: 6)
                                .animation(.spring(response: 0.28, dampingFraction: 0.72), value: currentPage)
                        }
                    }
                    .padding(.bottom, 12)
                }
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Settings View
struct PrinterThemePickerRow: View {
    @Binding var selectedTheme: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "paintpalette.fill")
                    .foregroundColor(appThemes.first { $0.key == selectedTheme }?.color ?? .blue)
                    .frame(width: 28)
                Text(lz(en: "Background Color", de: "Hintergrundfarbe", fr: "Couleur de fond", es: "Color de fondo"))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 10) {
                ForEach(appThemes, id: \.key) { theme in
                    Button(action: { selectedTheme = theme.key }) {
                        ZStack {
                            Circle()
                                .fill(theme.color)
                                .frame(width: 38, height: 38)
                                .shadow(color: theme.color.opacity(selectedTheme == theme.key ? 0.5 : 0), radius: 6)
                            if selectedTheme == theme.key {
                                Circle().strokeBorder(.white, lineWidth: 2.5).frame(width: 38, height: 38)
                                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .animation(.spring(response: 0.3), value: selectedTheme)
                }
            }
            .padding(.bottom, 4)
        }
        .padding(.vertical, 4)
    }
}

struct ThemePickerRow: View {
    @AppStorage("app_theme_color") private var selectedTheme: String = "blue"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "paintpalette.fill").foregroundColor(appTintColor()).frame(width: 28)
                Text(lz(en: "App Color", de: "App-Farbe", fr: "Couleur de l'app", es: "Color de la app"))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 10) {
                ForEach(appThemes, id: \.key) { theme in
                    Button(action: { selectedTheme = theme.key }) {
                        ZStack {
                            Circle()
                                .fill(theme.color)
                                .frame(width: 38, height: 38)
                                .shadow(color: theme.color.opacity(selectedTheme == theme.key ? 0.5 : 0), radius: 6)
                            if selectedTheme == theme.key {
                                Circle()
                                    .strokeBorder(.white, lineWidth: 2.5)
                                    .frame(width: 38, height: 38)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .animation(.spring(response: 0.3), value: selectedTheme)
                }
            }
            .padding(.bottom, 4)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Donation Manager (StoreKit 2)
@MainActor
class DonationManager: ObservableObject {
    static let onetimeSmallID = "onetimesupport1.99"
    static let onetimeLargeID = "onetimesupport4.99"
    static let monthlyID = "Support1.99monthly"
    static let annualID = "Support9.99annual"
    static let allIDs = [onetimeSmallID, onetimeLargeID, monthlyID, annualID]

    @Published var onetimeSmallProduct: Product?
    @Published var onetimeLargeProduct: Product?
    @Published var monthlyProduct: Product?
    @Published var annualProduct: Product?
    @Published var isPurchasing = false
    @Published var purchaseSuccess = false
    @Published var isSubscribed = false
    @Published var activeSubscriptionID: String? = nil
    @Published var didFinishLoading = false
    @Published var errorMessage: String?
    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let tx) = result {
                    await tx.finish()
                    if tx.productType == .autoRenewable {
                        // Re-check ground truth rather than assuming the update means active.
                        // Transaction.updates fires for renewals AND expirations/revocations,
                        // so a stale sandbox transaction can set isSubscribed = true incorrectly.
                        await self?.checkSubscriptionStatus()
                    } else {
                        await MainActor.run { self?.purchaseSuccess = true }
                    }
                }
            }
        }
        Task { await load(); await checkSubscriptionStatus() }
    }

    deinit { updatesTask?.cancel() }

    func load() async {
        do {
            let loaded = try await Product.products(for: Self.allIDs)
            for p in loaded {
                switch p.id {
                case Self.onetimeSmallID: onetimeSmallProduct = p
                case Self.onetimeLargeID: onetimeLargeProduct = p
                case Self.monthlyID: monthlyProduct = p
                case Self.annualID: annualProduct = p
                default: break
                }
            }
        } catch {}
        didFinishLoading = true
    }

    var hasProducts: Bool {
        onetimeSmallProduct != nil || onetimeLargeProduct != nil || monthlyProduct != nil || annualProduct != nil
    }

    func checkSubscriptionStatus() async {
        var foundID: String? = nil
        outer: for id in [Self.monthlyID, Self.annualID] {
            for await result in Transaction.currentEntitlements(for: id) {
                if case .verified(let tx) = result,
                   tx.revocationDate == nil,
                   tx.expirationDate.map({ $0 > Date() }) ?? true {
                    foundID = tx.productID
                    break outer
                }
            }
        }
        await MainActor.run {
            isSubscribed = foundID != nil
            activeSubscriptionID = foundID
        }
    }

    func purchase(_ product: Product) async {
        isPurchasing = true
        defer { isPurchasing = false }
        errorMessage = nil
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let tx) = verification {
                    await tx.finish()
                    purchaseSuccess = true
                    if product.type == .autoRenewable {
                        isSubscribed = true
                        activeSubscriptionID = product.id
                    }
                }
            default: break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Command Editor Sheet
private let commandColorPalette: [(hex: String, color: Color)] = [
    ("8B5CF6", .purple), ("6366F1", .indigo), ("3B82F6", .blue), ("0EA5E9", Color(red:0.05,green:0.65,blue:0.91)),
    ("14B8A6", .teal),   ("22C55E", .green),  ("84CC16", Color(red:0.52,green:0.80,blue:0.09)), ("EAB308", Color(red:0.92,green:0.70,blue:0.03)),
    ("F97316", .orange), ("EF4444", .red),    ("EC4899", .pink),  ("A855F7", Color(red:0.66,green:0.33,blue:0.97)),
    ("64748B", Color(red:0.39,green:0.46,blue:0.54)), ("374151", Color(red:0.22,green:0.25,blue:0.32)),
]

private let commandSymbolPalette: [String] = [
    "terminal.fill", "chevron.right.2", "gearshape.fill", "wrench.and.screwdriver.fill",
    "flame.fill", "snowflake", "thermometer.medium", "fan.fill",
    "arrow.trianglehead.2.clockwise", "arrow.up.circle.fill", "arrow.down.circle.fill", "arrow.2.squarepath",
    "paintbrush.fill", "trash.circle.fill", "bolt.fill", "wand.and.stars",
    "pause.circle.fill", "stop.circle.fill", "play.circle.fill", "repeat",
    "doc.text.fill", "hammer.fill", "bandage.fill", "checkmark.circle.fill",
]

struct CommandEditorSheet: View {
    @Binding var command: CustomCommand
    let isNew: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(lz(en: "Command", de: "Befehl", fr: "Commande", es: "Comando"))) {
                    TextField(lz(en: "Name (e.g. Clean Nozzle)", de: "Name (z.B. Düse reinigen)", fr: "Nom", es: "Nombre"),
                              text: $command.name)
                    TextField(lz(en: "GCode / Macro", de: "GCode / Makro", fr: "GCode / Macro", es: "GCode / Macro"), text: $command.gcode)
                        .textInputAutocapitalization(.characters)
                        .font(.system(.body, design: .monospaced))
                }

                Section(header: Text(lz(en: "Color", de: "Farbe", fr: "Couleur", es: "Color"))) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 10) {
                        ForEach(commandColorPalette, id: \.hex) { entry in
                            Button(action: { command.colorHex = entry.hex }) {
                                ZStack {
                                    Circle()
                                        .fill(entry.color)
                                        .frame(width: 36, height: 36)
                                    if command.colorHex.uppercased() == entry.hex.uppercased() {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section(header: Text(lz(en: "Icon", de: "Symbol", fr: "Icône", es: "Ícono"))) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 10) {
                        ForEach(commandSymbolPalette, id: \.self) { symbol in
                            Button(action: { command.sfSymbol = symbol }) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(command.sfSymbol == symbol
                                              ? command.color
                                              : Color.secondary.opacity(0.12))
                                        .frame(width: 44, height: 44)
                                    Image(systemName: symbol)
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(command.sfSymbol == symbol ? .white : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section(header: Text(lz(en: "Preview", de: "Vorschau", fr: "Aperçu", es: "Vista previa"))) {
                    HStack(spacing: 0) {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: command.sfSymbol.isEmpty ? "terminal.fill" : command.sfSymbol)
                                .font(.system(size: 22, weight: .semibold))
                            Text(command.name.isEmpty ? lz(en: "Name", de: "Name", fr: "Nom", es: "Nombre") : command.name)
                                .font(.system(size: 10, weight: .semibold))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                        .foregroundColor(.white)
                        .frame(width: 120)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(LinearGradient(colors: [command.color, command.color.opacity(0.65)],
                                                     startPoint: .top, endPoint: .bottom))
                                .shadow(color: command.color.opacity(0.4), radius: 6, x: 0, y: 3)
                        )
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }

                Section(header: Text(lz(en: "Printer", de: "Drucker", fr: "Imprimante", es: "Impresora"))) {
                    Picker(lz(en: "For which printer?", de: "Für welchen Drucker?", fr: "Pour quelle imprimante?", es: "¿Para qué impresora?"),
                           selection: $command.printerTarget) {
                        ForEach(PrinterTarget.allCases, id: \.self) { target in
                            HStack(spacing: 10) {
                                Image(target.imageName)
                                    .resizable().scaledToFit()
                                    .frame(width: 32, height: 32)
                                Text(target.label)
                            }
                            .tag(target)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section(header: Text(lz(en: "Examples", de: "Beispiele", fr: "Exemples", es: "Ejemplos"))) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(lz(en: "Klipper macro (defined in printer.cfg):", de: "Klipper-Makro (in printer.cfg definiert):", fr: "Macro Klipper (définie dans printer.cfg):", es: "Macro Klipper (definida en printer.cfg):"),
                              systemImage: "info.circle")
                            .font(.caption).foregroundColor(.secondary)
                        Text("MY_MACRO PARAM=value\nBED_MESH_CALIBRATE\nCLEAN_NOZZLE")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.purple)
                            .padding(8).background(Color.purple.opacity(0.07)).cornerRadius(8)
                        Label(lz(en: "Standard GCode / console command:", de: "Standard GCode / Konsolenbefehl:", fr: "GCode standard / commande console:", es: "GCode estándar / comando consola:"),
                              systemImage: "info.circle")
                            .font(.caption).foregroundColor(.secondary)
                        Text("M503\nG28\nM104 S200")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.teal)
                            .padding(8).background(Color.teal.opacity(0.07)).cornerRadius(8)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(isNew
                ? lz(en: "New Command", de: "Neuer Befehl", fr: "Nouvelle commande", es: "Nuevo comando")
                : lz(en: "Edit Command", de: "Befehl bearbeiten", fr: "Modifier la commande", es: "Editar comando"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(lz(en: "Save", de: "Speichern", fr: "Enregistrer", es: "Guardar")) {
                        onSave()
                    }
                    .disabled(command.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              command.gcode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    var onSave: () -> Void
    @EnvironmentObject var printerServices: PrinterServicesManager
    @State private var showAddPrinter = false
    @State private var showNetworkScan = false
    @State private var editingPrinter: PrinterConfig? = nil
    @EnvironmentObject var langStore: LanguageStore
    @State private var showAddCommand = false
    @State private var editingCommandIndex: Int? = nil
    @State private var draftCommand = CustomCommand(name: "", gcode: "")
    @State private var activeGroupID: String = "default"
    @AppStorage("show_nfc_tab") private var showNFCTab: Bool = true
    @AppStorage("show_timelapse_tab") private var showTimelapseTab: Bool = true
    @AppStorage("show_klipper_tab") private var showKlipperTab: Bool = true
    @AppStorage("printers_as_tabs") private var printersAsTabs: Bool = false
    @AppStorage("splitscreen_mode") private var splitscreenMode: Bool = false
    @AppStorage("expert_mode_enabled") private var expertModeEnabled: Bool = false
    @State private var showResetConfirm = false
    @Environment(\.editMode) private var editMode
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var donations = DonationManager()

    private var isIPad: Bool { horizontalSizeClass == .regular }

    var body: some View {
        NavigationStack {
            settingsForm
                .navigationTitle(lz(en: "Settings", de: "Einstellungen", fr: "Paramètres", es: "Ajustes"))
                .toolbar { EditButton() }
                .sheet(isPresented: $showAddPrinter) {
                    PrinterEditView(config: PrinterConfig(name: "", ip: "", type: .snapmakerU1)) { newPrinter in
                        settings.printers.append(newPrinter)
                        onSave()
                    }
                }
                .sheet(item: $editingPrinter) { printer in
                    PrinterEditView(
                        config: printer,
                        onSave: { updated in
                            if let idx = settings.printers.firstIndex(where: { $0.id == updated.id }) {
                                settings.printers[idx] = updated
                                onSave()
                            }
                        },
                        service: printerServices.services.first(where: { $0.name == printer.name })
                    )
                }
                .sheet(isPresented: $showNetworkScan) {
                    NetworkScanView(settings: settings, onSave: onSave)
                }
        }
    }

    @ViewBuilder
    private var ipadSettingsDetail: some View {
        if showAddPrinter {
            PrinterEditView(
                config: PrinterConfig(name: "", ip: "", type: .snapmakerU1),
                onSave: { newPrinter in
                    settings.printers.append(newPrinter)
                    showAddPrinter = false
                    onSave()
                },
                onDismiss: { showAddPrinter = false }
            )
        } else if let printer = editingPrinter {
            PrinterEditView(
                config: printer,
                onSave: { updated in
                    if let idx = settings.printers.firstIndex(where: { $0.id == updated.id }) {
                        settings.printers[idx] = updated
                        onSave()
                    }
                    editingPrinter = nil
                },
                onDismiss: { editingPrinter = nil },
                service: printerServices.services.first(where: { $0.name == printer.name })
            )
        } else if showNetworkScan {
            NetworkScanView(
                settings: settings,
                onSave: { onSave(); showNetworkScan = false },
                onDismiss: { showNetworkScan = false }
            )
        } else {
            VStack(spacing: 16) {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tertiary)
                Text(lz(en: "Select a setting on the left", de: "Links eine Einstellung wählen",
                        fr: "Sélectionner un paramètre à gauche", es: "Seleccionar un ajuste a la izquierda"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var settingsForm: some View {
        Form {
                Section(header: Text(lz(en: "Language", de: "Sprache", fr: "Langue", es: "Idioma"))) {
                    HStack {
                        Image(systemName: "globe").foregroundColor(.blue).frame(width: 28)
                        Picker(lz(en: "Language", de: "Sprache", fr: "Langue", es: "Idioma"), selection: $langStore.current) {
                            Text("🇬🇧 English").tag("en")
                            Text("🇩🇪 Deutsch").tag("de")
                            Text("🇫🇷 Français").tag("fr")
                            Text("🇪🇸 Español").tag("es")
                        }
                        .pickerStyle(.menu)
                    }
                }
                Section(header: Text(lz(en: "Extra Features", de: "Zusatzfunktionen", fr: "Fonctions supplémentaires", es: "Funciones adicionales"))) {
                    HStack {
                        Image(systemName: "rectangle.grid.1x2").foregroundColor(.indigo).frame(width: 28)
                        Toggle(lz(en: "Printers as Tabs", de: "Drucker als einzelne Tabs", fr: "Imprimantes en onglets", es: "Impresoras comme pestañas"), isOn: $printersAsTabs)
                    }
                    if isIPad {
                        HStack {
                            Image(systemName: "rectangle.split.2x1").foregroundColor(.teal).frame(width: 28)
                            Toggle(lz(en: "Split Screen (iPad)", de: "Splitscreen (iPad)", fr: "Écran partagé (iPad)", es: "Pantalla dividida (iPad)"), isOn: $splitscreenMode)
                        }
                    }
                    HStack {
                        Image(systemName: "wave.3.right").foregroundColor(.blue).frame(width: 28)
                        Toggle("NFC", isOn: $showNFCTab)
                    }
                    HStack {
                        Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundColor(.green).frame(width: 28)
                        Toggle("Klipper", isOn: $showKlipperTab)
                    }
                    HStack {
                        Image(systemName: "video.badge.waveform").foregroundColor(.purple).frame(width: 28)
                        Toggle("Timelapse", isOn: $showTimelapseTab)
                    }
                    HStack {
                        Image(systemName: "lock.shield.fill").foregroundColor(.orange).frame(width: 28)
                        Toggle(lz(en: "Firmware Configuration", de: "Firmware Konfiguration", fr: "Configuration Firmware", es: "Configuración Firmware"), isOn: $expertModeEnabled)
                    }
                }
                Section(header: Text(lz(en: "My Printers", de: "Meine Drucker", fr: "Mes imprimantes", es: "Mis impresoras"))) {
                    ForEach(settings.printers) { printer in
                        HStack(spacing: 0) {
                            Button(action: { editingPrinter = printer }) {
                                HStack(spacing: 12) {
                                    Image(printer.type.imageName)
                                        .resizable().scaledToFit()
                                        .frame(width: 28, height: 28)
                                        .opacity(printer.isVisible ? 1.0 : 0.35)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(printer.name).font(.subheadline).bold()
                                            .foregroundColor(printer.isVisible ? .primary : .secondary)
                                        Text(printer.connectionMode == .octoEverywhere ? printer.octoEverywhereURL : printer.ip)
                                            .font(.caption).foregroundColor(.secondary)
                                        HStack(spacing: 4) {
                                            Text(printer.type.rawValue).font(.caption2)
                                                .foregroundColor(printer.isVisible ? .blue : .secondary)
                                                .padding(.horizontal, 6).padding(.vertical, 1)
                                                .background((printer.isVisible ? Color.blue : Color.secondary).opacity(0.1))
                                                .cornerRadius(4)
                                            if printer.connectionMode == .octoEverywhere {
                                                Text("OctoEverywhere").font(.caption2).foregroundColor(.orange)
                                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                                    .background(Color.orange.opacity(0.1)).cornerRadius(4)
                                            }
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)

                            Button(action: {
                                if let idx = settings.printers.firstIndex(where: { $0.id == printer.id }) {
                                    settings.printers[idx].isVisible.toggle()
                                    onSave()
                                }
                            }) {
                                Image(systemName: printer.isVisible ? "eye.fill" : "eye.slash.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(printer.isVisible ? .blue : .secondary)
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onDelete { indices in
                        // Capture push config before removal for Cloudflare cleanup
                        let removed = indices.map { settings.printers[$0] }
                        let removedNames = removed.map { $0.name }
                        settings.printers.remove(atOffsets: indices)
                        if let defaults = UserDefaults(suiteName: "group.paxxmaker.u1"),
                           let data = defaults.data(forKey: "w_all_printers"),
                           var all = try? JSONDecoder().decode([PrinterWidgetEntryData].self, from: data) {
                            all.removeAll { removedNames.contains($0.id) }
                            if let encoded = try? JSONEncoder().encode(all) {
                                defaults.set(encoded, forKey: "w_all_printers")
                            }
                        }
                        // Clean up Cloudflare KV for push-enabled printers
                        for p in removed where p.pushMode == .cloudflare && !p.cloudflareNotifySecret.isEmpty {
                            let pid = p.name; let secret = p.cloudflareNotifySecret
                            Task {
                                await CloudflarePushService.shared.cleanupPrinter(
                                    workerURL: CloudflarePushService.workerURL,
                                    printerID: pid, secret: secret
                                )
                            }
                        }
                        WidgetCenter.shared.reloadAllTimelines()
                        onSave()
                    }
                    .onMove { from, to in
                        settings.printers.move(fromOffsets: from, toOffset: to)
                        onSave()
                    }
                    Button(action: { showAddPrinter = true }) {
                        HStack {
                            Image(systemName: "plus.circle.fill").foregroundColor(.green)
                            Text(lz(en: "Add Printer", de: "Drucker hinzufügen", fr: "Ajouter une imprimante", es: "Agregar impresora")).foregroundColor(.green)
                        }
                    }
                    Button(action: { showNetworkScan = true }) {
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundColor(.blue)
                            Text(lz(en: "Search Network", de: "Im Netzwerk suchen", fr: "Chercher sur le réseau", es: "Buscar en la red")).foregroundColor(.blue)
                        }
                    }
                }
                // MARK: Custom Commands Section — one Section per tile group
                ForEach(settings.customCommandGroups) { group in
                    let groupIdx = settings.customCommandGroups.firstIndex(where: { $0.id == group.id })
                    Section(header: Text(lz(en: "My Commands / Macros", de: "Eigene Befehle / Makros", fr: "Mes commandes / Macros", es: "Mis comandos / Macros"))) {
                        // Tile title — swipe left to delete the whole group
                        HStack(spacing: 8) {
                            Image(systemName: "pencil.line").foregroundColor(.secondary).frame(width: 24)
                            if let gi = groupIdx {
                                TextField(lz(en: "Tile title (optional)", de: "Kachelname (optional)", fr: "Titre de la tuile (optionnel)", es: "Título del mosaico (opcional)"),
                                          text: $settings.customCommandGroups[gi].title)
                                    .font(.body)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                settings.customCommands.removeAll { $0.groupID == group.id }
                                settings.customCommandGroups.removeAll { $0.id == group.id }
                            } label: {
                                Label(lz(en: "Delete", de: "Löschen", fr: "Supprimer", es: "Eliminar"), systemImage: "trash")
                            }
                        }
                        // Commands in this group
                        let enumerated = Array(settings.customCommands.enumerated().filter { $0.element.groupID == group.id })
                        ForEach(enumerated, id: \.element.id) { idx, cmd in
                            Button(action: {
                                draftCommand = cmd
                                editingCommandIndex = idx
                                activeGroupID = group.id
                                showAddCommand = true
                            }) {
                                HStack(spacing: 10) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 7).fill(cmd.color).frame(width: 30, height: 30)
                                        Image(systemName: cmd.sfSymbol.isEmpty ? "terminal.fill" : cmd.sfSymbol)
                                            .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(cmd.name).font(.body).foregroundColor(.primary)
                                        Text(cmd.gcode).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                                        Text(cmd.printerTarget.label).font(.caption2).foregroundColor(.secondary.opacity(0.7))
                                    }
                                    Spacer()
                                    Image(systemName: "pencil").font(.caption).foregroundColor(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            let globalIndices = offsets.map { enumerated[$0].offset }
                            settings.customCommands.remove(atOffsets: IndexSet(globalIndices))
                        }
                        Button(action: {
                            draftCommand = CustomCommand(name: "", gcode: "", printerTarget: .both, groupID: group.id)
                            editingCommandIndex = nil
                            activeGroupID = group.id
                            showAddCommand = true
                        }) {
                            HStack {
                                Image(systemName: "plus.circle.fill").foregroundColor(.purple)
                                Text(lz(en: "Add Command", de: "Befehl hinzufügen", fr: "Ajouter une commande", es: "Agregar comando")).foregroundColor(.purple)
                            }
                        }
                    }
                }
                // Add another tile button
                Section {
                    Button(action: {
                        let newGroup = CustomCommandGroup()
                        settings.customCommandGroups.append(newGroup)
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill").foregroundColor(.purple)
                            Text(lz(en: "Add another Tile", de: "Weitere Kachel hinzufügen", fr: "Ajouter une autre tuile", es: "Agregar otro mosaico")).foregroundColor(.purple)
                        }
                    }
                }
                .sheet(isPresented: $showAddCommand) {
                    CommandEditorSheet(
                        command: $draftCommand,
                        isNew: editingCommandIndex == nil,
                        onSave: {
                            let trimmed = CustomCommand(
                                id: draftCommand.id,
                                name: draftCommand.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                gcode: draftCommand.gcode.trimmingCharacters(in: .whitespacesAndNewlines),
                                printerTarget: draftCommand.printerTarget,
                                colorHex: draftCommand.colorHex,
                                sfSymbol: draftCommand.sfSymbol,
                                groupID: draftCommand.groupID
                            )
                            if let idx = editingCommandIndex {
                                settings.customCommands[idx] = trimmed
                            } else {
                                settings.customCommands.append(trimmed)
                            }
                            showAddCommand = false
                        },
                        onCancel: { showAddCommand = false }
                    )
                }

                // MARK: Donation Section
                Section(
                    header: Label(lz(en: "Support the App", de: "App unterstützen", fr: "Soutenir l'app", es: "Apoyar la app"), systemImage: "heart.fill")
                        .foregroundStyle(.red),
                    footer: Text(lz(
                        en: "PaxxMaker is a hobby project. A small tip helps cover the running costs and keeps development alive. I'm always open to suggestions and feedback — just send me a message!\n\nSubscriptions auto-renew unless cancelled at least 24 hours before the end of the current period. Manage or cancel in your Apple ID settings.",
                        de: "PaxxMaker ist ein Hobbyprojekt. Eine kleine Spende hilft, die Eigenkosten zu decken und die Weiterentwicklung zu ermöglichen. Für Anregungen und Verbesserungsvorschläge bin ich jederzeit offen – schreib mir einfach!\n\nAbonnements verlängern sich automatisch, sofern sie nicht mindestens 24 Stunden vor Ende des aktuellen Zeitraums gekündigt werden. Verwalten oder kündigen in den Apple-ID-Einstellungen.",
                        fr: "PaxxMaker est un projet hobby. Un petit pourboire aide à couvrir les coûts. Je suis toujours ouvert aux suggestions — écrivez-moi !\n\nLes abonnements se renouvellent automatiquement sauf annulation au moins 24 heures avant la fin de la période en cours. Gérez ou annulez dans les réglages de votre identifiant Apple.",
                        es: "PaxxMaker es un proyecto hobby. Una propina ayuda a cubrir los costes. ¡Estoy abierto a sugerencias — escríbeme!\n\nLas suscripciones se renuevan automáticamente a menos que se cancelen al menos 24 horas antes del final del período actual. Gestiona o cancela en los ajustes de tu ID de Apple."
                    ))
                ) {
                    if donations.purchaseSuccess || donations.isSubscribed {
                        Label(lz(en: "Thank you for your support!", de: "Danke für deine Unterstützung!", fr: "Merci pour ton soutien !", es: "¡Gracias por tu apoyo!"),
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    if donations.isSubscribed {
                        Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                            Label(lz(en: "Manage Subscription", de: "Abonnement verwalten", fr: "Gérer l'abonnement", es: "Gestionar suscripción"),
                                  systemImage: "arrow.up.right.square")
                                .font(.subheadline)
                                .foregroundStyle(.blue)
                        }
                    }

                    if !donations.hasProducts && !donations.didFinishLoading {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text(lz(en: "Loading…", de: "Laden…", fr: "Chargement…", es: "Cargando…"))
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                        .onAppear { Task { await donations.load() } }
                    } else if !donations.hasProducts && donations.didFinishLoading {
                        Text(lz(en: "In-App Purchases are currently unavailable.", de: "In-App-Käufe sind derzeit nicht verfügbar.", fr: "Les achats intégrés ne sont pas disponibles.", es: "Las compras no están disponibles."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        if donations.onetimeSmallProduct != nil || donations.onetimeLargeProduct != nil {
                            HStack(spacing: 12) {
                                if let small = donations.onetimeSmallProduct {
                                    Button {
                                        Task { await donations.purchase(small) }
                                    } label: {
                                        VStack(spacing: 4) {
                                            Image(systemName: "heart.fill")
                                                .font(.title3)
                                                .foregroundStyle(.red)
                                            Text(small.displayPrice)
                                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                            Text(lz(en: "Small Support", de: "Kleine Spende", fr: "Petit soutien", es: "Pequeño apoyo"))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                                        .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(donations.isPurchasing)
                                }
                                if let large = donations.onetimeLargeProduct {
                                    Button {
                                        Task { await donations.purchase(large) }
                                    } label: {
                                        VStack(spacing: 4) {
                                            Image(systemName: "heart.circle.fill")
                                                .font(.title3)
                                                .foregroundStyle(.pink)
                                            Text(large.displayPrice)
                                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                            Text(lz(en: "Large Support", de: "Große Spende", fr: "Grand soutien", es: "Gran apoyo"))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(Color.pink.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                                        .foregroundStyle(.pink)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(donations.isPurchasing)
                                }
                            }
                            .padding(.vertical, 2)
                        }

                        if let monthly = donations.monthlyProduct {
                            Button {
                                Task { await donations.purchase(monthly) }
                            } label: {
                                HStack {
                                    Image(systemName: "heart.circle.fill")
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(lz(en: "Monthly Supporter", de: "Monatlicher Unterstützer", fr: "Soutien mensuel", es: "Apoyo mensual"))
                                            .font(.subheadline.weight(.semibold))
                                        Text(lz(en: "\(monthly.displayPrice)/month", de: "\(monthly.displayPrice)/Monat", fr: "\(monthly.displayPrice)/mois", es: "\(monthly.displayPrice)/mes"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if donations.activeSubscriptionID == DonationManager.monthlyID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    } else {
                                        Text(donations.activeSubscriptionID == DonationManager.annualID
                                             ? lz(en: "Switch", de: "Wechseln", fr: "Changer", es: "Cambiar")
                                             : lz(en: "Subscribe", de: "Abonnieren", fr: "S'abonner", es: "Suscribirse"))
                                            .font(.subheadline.weight(.bold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 6)
                                            .background(.orange, in: Capsule())
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(donations.isPurchasing || donations.activeSubscriptionID == DonationManager.monthlyID)
                        }

                        if let annual = donations.annualProduct {
                            Button {
                                Task { await donations.purchase(annual) }
                            } label: {
                                HStack {
                                    Image(systemName: "star.circle.fill")
                                        .foregroundStyle(.yellow)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(lz(en: "Annual Supporter", de: "Jährlicher Unterstützer", fr: "Soutien annuel", es: "Apoyo anual"))
                                            .font(.subheadline.weight(.semibold))
                                        Text(lz(en: "\(annual.displayPrice)/year", de: "\(annual.displayPrice)/Jahr", fr: "\(annual.displayPrice)/an", es: "\(annual.displayPrice)/año"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if donations.activeSubscriptionID == DonationManager.annualID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    } else {
                                        Text(donations.activeSubscriptionID == DonationManager.monthlyID
                                             ? lz(en: "Switch", de: "Wechseln", fr: "Changer", es: "Cambiar")
                                             : lz(en: "Subscribe", de: "Abonnieren", fr: "S'abonner", es: "Suscribirse"))
                                            .font(.subheadline.weight(.bold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 6)
                                            .background(.yellow, in: Capsule())
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(donations.isPurchasing || donations.activeSubscriptionID == DonationManager.annualID)
                        }
                    }
                    if let err = donations.errorMessage {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                    // Feedback row
                    Link(destination: URL(string: "mailto:paxxmaker@gmx.de")!) {
                        Label(lz(en: "Send Feedback / Suggestions", de: "Feedback & Anregungen senden", fr: "Envoyer des suggestions", es: "Enviar sugerencias"),
                              systemImage: "envelope.fill")
                            .foregroundStyle(.blue)
                    }

                    Link(destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!) {
                        Label(lz(en: "Terms of Use (EULA)", de: "Nutzungsbedingungen (EULA)", fr: "Conditions d'utilisation (EULA)", es: "Términos de uso (EULA)"),
                              systemImage: "doc.text")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }

                    Link(destination: URL(string: "https://github.com/DanielR1c/paxxmaker-privacy/blob/main/Privacy%20Policy%20%E2%80%93%20PaxxMaker%20U1.md")!) {
                        Label(lz(en: "Privacy Policy", de: "Datenschutz", fr: "Politique de confidentialité", es: "Política de privacidad"),
                              systemImage: "hand.raised")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                }

                Section(header: Text(lz(en: "Reset", de: "Zurücksetzen", fr: "Réinitialiser", es: "Restablecer"))) {
                    Button(action: { showResetConfirm = true }) {
                        HStack {
                            Image(systemName: "arrow.counterclockwise").foregroundColor(.red)
                            Text(lz(en: "Reset Setup", de: "Einrichtung zurücksetzen", fr: "Réinitialiser la configuration", es: "Restablecer configuración")).foregroundColor(.red)
                        }
                    }
                    .confirmationDialog(
                        lz(en: "Reset Setup?", de: "Einrichtung zurücksetzen?", fr: "Réinitialiser la configuration ?", es: "¿Restablecer configuración?"),
                        isPresented: $showResetConfirm, titleVisibility: .visible
                    ) {
                        Button(lz(en: "Reset", de: "Zurücksetzen", fr: "Réinitialiser", es: "Restablecer"),
                               role: .destructive) {
                            let keysToRemove = [
                                "printers_config", "custom_commands", "custom_command_groups",
                                "custom_tile_title", "dashboard_tile_order", "hidden_tiles",
                                "selected_plate", "app_theme_color", "selected_printer_index",
                                "has_completed_onboarding", "has_shown_firmware_notice",
                                "has_accepted_disclaimer", "has_selected_language", "expert_mode_enabled",
                                "show_nfc_tab", "printers_as_tabs"
                            ]
                            for key in keysToRemove {
                                UserDefaults.standard.removeObject(forKey: key)
                            }
                            if let defaults = UserDefaults(suiteName: "group.paxxmaker.u1") {
                                defaults.removeObject(forKey: "w_all_printers")
                                defaults.removeObject(forKey: "watch_all_printers")
                                defaults.removeObject(forKey: "watch_complication")
                                defaults.removeObject(forKey: "watch_printer_configs")
                            }
                            WidgetCenter.shared.reloadAllTimelines()
                            settings.printers = []
                            settings.customCommands = []
                            settings.customCommandGroups = [CustomCommandGroup(id: "default", title: "")]
                            settings.hasCompletedOnboarding = false
                        }
                        Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar"), role: .cancel) {}
                    } message: {
                        Text(lz(
                            en: "All printers and settings will be permanently deleted. This cannot be undone.",
                            de: "Alle Drucker und Einstellungen werden unwiderruflich gelöscht.",
                            fr: "Toutes les imprimantes et tous les réglages seront définitivement supprimés.",
                            es: "Todas las impresoras y ajustes se eliminarán de forma permanente."
                        ))
                    }
                }
            }
        }
}

// MARK: - OctoEverywhere Guide View
struct OctoEverywhereGuideView: View {
    @Environment(\.dismiss) var dismiss
    var printerType: PrinterConfig.PrinterType = .snapmakerU1

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(spacing: 10) {
                        Image(systemName: "globe")
                            .font(.system(size: 44))
                            .foregroundColor(.orange)
                            .padding(20)
                            .background(Color.orange.opacity(0.1))
                            .clipShape(Circle())
                        Text(lz(en: "Connect with OctoEverywhere", de: "Mit OctoEverywhere verbinden", fr: "Connexion à OctoEverywhere", es: "Conectar con OctoEverywhere"))
                            .font(.title2).bold().multilineTextAlignment(.center)
                        Text(lz(en: "Access your printer from anywhere", de: "Greife von überall auf deinen Drucker zu", fr: "Accède à ton imprimante depuis n'importe où", es: "Accede a tu impresora desde cualquier lugar"))
                            .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                    if printerType == .snapmakerU1 {
                        step(number: 1, icon: "gearshape.fill", color: .blue,
                             title: lz(en: "Enable Firmware Configuration", de: "Firmware-Konfiguration aktivieren", fr: "Activer la configuration firmware", es: "Activar configuración firmware"),
                             text: lz(en: "Open PaxxMaker → Settings → enable \"Firmware Configuration\" under Extra Features.", de: "Öffne PaxxMaker → Einstellungen → aktiviere \"Firmware-Konfiguration\" unter Zusatzfunktionen.", fr: "Ouvre PaxxMaker → Paramètres → active \"Configuration Firmware\" sous Fonctions supplémentaires.", es: "Abre PaxxMaker → Ajustes → activa \"Configuración Firmware\" en Funciones adicionales."))

                        step(number: 2, icon: "printer.fill", color: .blue,
                             title: lz(en: "Open Printer Configuration", de: "Drucker-Konfiguration öffnen", fr: "Ouvrir la configuration imprimante", es: "Abrir configuración impresora"),
                             text: lz(en: "Switch to the Printer tab → tap \"Configuration\" → select \"Cloud Access\".", de: "Wechsle zum Drucker-Tab → tippe auf \"Konfiguration\" → wähle \"Cloud Access\".", fr: "Passe à l'onglet Imprimante → appuie sur \"Configuration\" → sélectionne \"Cloud Access\".", es: "Cambia a la pestaña Impresora → pulsa \"Configuración\" → selecciona \"Cloud Access\"."))

                        step(number: 3, icon: "cloud.fill", color: .orange,
                             title: lz(en: "Activate OctoEverywhere", de: "OctoEverywhere aktivieren", fr: "Activer OctoEverywhere", es: "Activar OctoEverywhere"),
                             text: lz(en: "Enable OctoEverywhere in the cloud access settings. You will receive a connection code.", de: "Aktiviere OctoEverywhere in den Cloud-Access-Einstellungen. Du erhältst einen Verbindungscode.", fr: "Active OctoEverywhere dans les paramètres d'accès cloud. Tu recevras un code de connexion.", es: "Activa OctoEverywhere en los ajustes de acceso cloud. Recibirás un código de connexion."))

                        step(number: 4, icon: "person.crop.circle.badge.checkmark", color: .orange,
                             title: lz(en: "Register at OctoEverywhere", de: "Bei OctoEverywhere registrieren", fr: "S'inscrire sur OctoEverywhere", es: "Registrarse en OctoEverywhere"),
                             text: lz(en: "Go to octoeverywhere.com and sign in. Enter the connection code from step 3 to link your printer.", de: "Gehe zu octoeverywhere.com und melde dich an. Gib den Verbindungscode aus Schritt 3 ein, um deinen Drucker zu verknüpfen.", fr: "Va sur octoeverywhere.com et connecte-toi. Saisis le code de connexion de l'étape 3 pour lier ton imprimante.", es: "Ve a octoeverywhere.com e inicia sesión. Introduce el código de conexión del paso 3 para vincular tu impresora."))
                    }

                    let startStep = printerType == .snapmakerU1 ? 5 : 1
                    step(number: startStep, icon: "iphone", color: .orange,
                         title: lz(en: "Create App Connection", de: "App-Verbindung erstellen", fr: "Créer une connexion App", es: "Crear conexión App"),
                         text: lz(en: "Open your printer in OctoEverywhere → tap \"iOS And Android Apps\" → enter an app name (e.g. \"PaxxMaker\") → select your printer → tap \"Create\".", de: "Öffne deinen Drucker in OctoEverywhere → tippe auf \"iOS And Android Apps\" → gib einen App-Namen ein (z.B. \"PaxxMaker\") → wähle deinen Drucker → tippe auf \"Create\".", fr: "Ouvre ton imprimante dans OctoEverywhere → appuie sur \"iOS And Android Apps\" → entre un nom (ex. \"PaxxMaker\") → sélectionne ton imprimante → appuie sur \"Create\".", es: "Abre tu impresora en OctoEverywhere → pulsa \"iOS And Android Apps\" → introduce un nombre (p.ej. \"PaxxMaker\") → selecciona tu impresora → pulsa \"Create\"."))

                    step(number: startStep + 1, icon: "doc.on.clipboard", color: .orange,
                         title: lz(en: "Copy URL", de: "URL kopieren", fr: "Copier l'URL", es: "Copiar URL"),
                         text: lz(en: "OctoEverywhere generates a unique URL for this app connection. Copy it.", de: "OctoEverywhere generiert eine einzigartige URL für diese App-Verbindung. Kopiere sie.", fr: "OctoEverywhere génère une URL unique pour cette connexion. Copie-la.", es: "OctoEverywhere genera una URL única para esta conexión. Cópiala."))

                    HStack {
                        Spacer()
                        VStack(alignment: .center, spacing: 4) {
                            Text(lz(en: "URL Format", de: "URL-Format", fr: "Format URL", es: "Formato URL")).font(.caption2).foregroundColor(.secondary)
                            Text("https://xxxxx.octoeverywhere.com")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.orange)
                        }
                        .padding(12)
                        .background(Color.orange.opacity(0.08))
                        .cornerRadius(10)
                        Spacer()
                    }

                    step(number: startStep + 2, icon: "checkmark.circle.fill", color: .green,
                         title: lz(en: "Enter in the App", de: "In der App eintragen", fr: "Saisir dans l'App", es: "Introducir en la App"),
                         text: lz(en: "Open PaxxMaker → Settings → your printer → enable OctoEverywhere toggle → paste the URL and save.\n\nOptional: Find the API key in Moonraker under Settings → API Key.", de: "Öffne PaxxMaker → Einstellungen → deinen Drucker → aktiviere den OctoEverywhere-Schalter → füge die URL ein und speichere.\n\nOptional: Den API-Key findest du in Moonraker unter Einstellungen → API-Schlüssel.", fr: "Ouvre PaxxMaker → Paramètres → ton imprimante → active le commutateur OctoEverywhere → colle l'URL et enregistre.\n\nOptionnel : Trouve la clé API dans Moonraker sous Paramètres → Clé API.", es: "Abre PaxxMaker → Ajustes → tu impresora → activa el interruptor OctoEverywhere → pega la URL y guarda.\n\nOpcional: Encuentra la clave API en Moonraker en Ajustes → Clave API."))

                    Spacer(minLength: 20)
                }
                .padding(20)
            }
            .navigationTitle(lz(en: "OctoEverywhere Setup", de: "OctoEverywhere einrichten", fr: "Config. OctoEverywhere", es: "Configurar OctoEverywhere"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button(lz(en: "Done", de: "Fertig", fr: "Terminé", es: "Listo")) { dismiss() })
        }
    }

    @ViewBuilder
    func step(number: Int, icon: String, color: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(color.opacity(0.15)).frame(width: 38, height: 38)
                Text("\(number)").font(.system(size: 15, weight: .bold)).foregroundColor(color)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: icon).foregroundColor(color).font(.subheadline)
                    Text(title).font(.subheadline).bold()
                }
                Text(text).font(.subheadline).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Printer Edit View
struct PrinterEditView: View {
    @State var config: PrinterConfig
    var onSave: (PrinterConfig) -> Void
    var onDismiss: (() -> Void)? = nil
    @Environment(\.dismiss) var dismiss
    @State private var showOctoGuide = false
    @State private var showLocalGuide = false
    @State private var showResetLayoutConfirm = false
    var service: PrinterService? = nil
    @State private var pushStatusMsg: String? = nil
    @State private var pushStatusIsError = false
    @State private var pushIsWorking = false
    @State private var showScriptGuide = false
    @State private var showPushInfo = false

    @State private var showSmartPlugGuide = false


    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(lz(en: "Printer Info", de: "Drucker Info", fr: "Infos imprimante", es: "Info impresora"))) {
                    HStack {
                        Image(systemName: "tag").foregroundColor(.blue)
                        TextField(lz(en: "Name", de: "Name", fr: "Nom", es: "Nombre"), text: $config.name)
                    }
                    HStack {
                        Image(systemName: "network").foregroundColor(.blue)
                        TextField(lz(en: "Local IP e.g. 192.168.178.70", de: "Lokale IP z.B. 192.168.178.70", fr: "IP locale ex. 192.168.178.70", es: "IP local ej. 192.168.178.70"), text: $config.ip)
                            .keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true)
                    }
                }
                Section(header: Text(lz(en: "Printer Type", de: "Drucker Typ", fr: "Type d'imprimante", es: "Tipo de impresora"))) {
                    ForEach(PrinterConfig.PrinterType.allCases, id: \.self) { type in
                        Button(action: { config.type = type }) {
                            HStack(spacing: 14) {
                                Image(type.imageName)
                                    .resizable().scaledToFit()
                                    .frame(width: 38, height: 38)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(type.rawValue).foregroundColor(.primary)
                                    Text("\(type.extruderCount) Extruder").font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                if config.type == type { Image(systemName: "checkmark").foregroundColor(.blue) }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                Section(header: Text(lz(en: "Appearance", de: "Erscheinungsbild", fr: "Apparence", es: "Apariencia"))) {
                    HStack {
                        Image(systemName: "paintpalette.fill")
                            .foregroundColor(Color(hex: config.themeColor) ?? appThemes.first { $0.key == config.themeColor }?.color ?? .blue)
                            .frame(width: 28)
                        Text(lz(en: "Background Color", de: "Hintergrundfarbe", fr: "Couleur de fond", es: "Color de fondo"))
                        Spacer()
                        ColorPicker("", selection: Binding(
                            get: { Color(hex: config.themeColor) ?? appThemes.first { $0.key == config.themeColor }?.color ?? .blue },
                            set: { config.themeColor = $0.hexString }
                        ), supportsOpacity: false)
                        .labelsHidden()
                    }
                }
                Section(header: Text(lz(en: "Connection", de: "Verbindung", fr: "Connexion", es: "Conexión"))) {
                    HStack(spacing: 12) {
                        Image(systemName: "house.fill").foregroundColor(.blue).frame(width: 24)
                        Text("Lokal")
                        Button(action: { showLocalGuide = true }) {
                            Image(systemName: "questionmark.circle")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { config.connectionMode == .octoEverywhere },
                            set: { config.connectionMode = $0 ? .octoEverywhere : .local }
                        )).labelsHidden()
                        Image(systemName: "globe").foregroundColor(.orange).frame(width: 24)
                        Text("OctoEverywhere")
                        Button(action: { showOctoGuide = true }) {
                            Image(systemName: "questionmark.circle")
                                .foregroundColor(.orange)
                        }
                        .buttonStyle(.plain)
                    }
                    if config.connectionMode == .octoEverywhere {
                        HStack {
                            Image(systemName: "link").foregroundColor(.orange).frame(width: 24)
                            TextField("https://xxxx.octoeverywhere.com", text: $config.octoEverywhereURL)
                                .keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true)
                        }
                        HStack {
                            Image(systemName: "key.fill").foregroundColor(.orange).frame(width: 24)
                            SecureField("API-Key (optional)", text: $config.octoEverywhereAPIKey)
                                .autocapitalization(.none).disableAutocorrection(true)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Den API-Key findest du in Moonraker unter")
                                .font(.caption2).foregroundColor(.secondary)
                            Text("Einstellungen → API-Schlüssel")
                                .font(.caption2).foregroundColor(.secondary).bold()
                        }
                        .padding(.vertical, 2)
                    }
                }
                Section {
                    if showResetLayoutConfirm {
                        Button(role: .destructive) {
                            let pid = config.id.uuidString
                            UserDefaults.standard.removeObject(forKey: "dashboard_tile_order_\(pid)")
                            UserDefaults.standard.removeObject(forKey: "hidden_tiles_\(pid)")
                            UserDefaults.standard.removeObject(forKey: "tile_grid_mode_\(pid)")
                            UserDefaults.standard.removeObject(forKey: "tile_half_width_\(pid)")
                            showResetLayoutConfirm = false
                        } label: {
                            HStack {
                                Spacer()
                                Text(lz(en: "Reset", de: "Zurücksetzen", fr: "Réinitialiser", es: "Restablecer"))
                                    .bold()
                                Spacer()
                            }
                        }
                        Button {
                            showResetLayoutConfirm = false
                        } label: {
                            HStack {
                                Spacer()
                                Text(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar"))
                                Spacer()
                            }
                        }
                    }
                }
                // MARK: Smart Plug Section
                Section(header: HStack {
                    Text(lz(en: "Smart Plug", de: "Smart-Steckdose", fr: "Prise intelligente", es: "Enchufe inteligente"))
                    Spacer()
                    if config.smartPlugType == .tuya {
                        Button { showSmartPlugGuide = true } label: {
                            Image(systemName: "questionmark.circle")
                                .foregroundColor(.secondary)
                                .font(.footnote)
                        }
                        .buttonStyle(.plain)
                    }
                }) {
                    Picker(lz(en: "Type", de: "Typ", fr: "Type", es: "Tipo"),
                           selection: $config.smartPlugType) {
                        Text("Tuya / SmartLife").tag(PrinterConfig.SmartPlugType.tuya)
                        Text("Shelly").tag(PrinterConfig.SmartPlugType.shelly)
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Image(systemName: "network").foregroundColor(.orange)
                        TextField(lz(en: "Plug IP e.g. 192.168.178.170", de: "Steckdosen-IP z.B. 192.168.178.170", fr: "IP prise ex. 192.168.178.170", es: "IP enchufe ej. 192.168.178.170"),
                                  text: $config.smartPlugIP)
                            .keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true)
                    }

                    if config.smartPlugType == .tuya {
                        HStack {
                            Image(systemName: "cpu").foregroundColor(.orange)
                            TextField(lz(en: "Device ID (from tinytuya wizard)", de: "Geräte-ID (aus tinytuya wizard)", fr: "ID appareil (tinytuya wizard)", es: "ID dispositivo (tinytuya wizard)"),
                                      text: $config.smartPlugDeviceID)
                                .autocapitalization(.none).disableAutocorrection(true)
                        }
                        HStack {
                            Image(systemName: "key.fill").foregroundColor(.orange)
                            SecureField(lz(en: "Local Key (16 chars, from tinytuya wizard)", de: "Local Key (16 Zeichen, aus tinytuya wizard)", fr: "Clé locale (16 car., tinytuya wizard)", es: "Clave local (16 chars, tinytuya wizard)"),
                                        text: $config.smartPlugLocalKey)
                                .autocapitalization(.none).disableAutocorrection(true)
                        }
                    }
                }

                // MARK: Push Notifications Section
                Section(header: HStack {
                    Text(lz(en: "Push Notifications", de: "Push-Benachrichtigungen", fr: "Notifications push", es: "Notificaciones push"))
                    Spacer()
                    Button { showPushInfo = true } label: {
                        Image(systemName: "questionmark.circle")
                            .foregroundColor(.secondary)
                            .font(.footnote)
                    }
                    .buttonStyle(.plain)
                }) {
                    // Server mode row (coming soon — not yet selectable)
                    Button { } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "cloud.fill")
                                .foregroundColor(.purple)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lz(en: "Server Push (coming soon)", de: "Server-Push (demnächst)", fr: "Push serveur (bientôt)", es: "Push servidor (próximamente)"))
                                    .foregroundColor(.primary)
                                    .font(.body)
                                Text(lz(en: "Works even when the app is closed", de: "Funktioniert auch wenn App geschlossen ist", fr: "Fonctionne même si l'app est fermée", es: "Funciona aunque la app esté cerrada"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .disabled(true)
                    .opacity(0.45)

                    // Local mode row
                    Button {
                        config.pushMode = .off
                        pushStatusMsg = nil
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "iphone")
                                .foregroundColor(.blue)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lz(en: "Local (App Pull)", de: "Lokal (App Pull)", fr: "Local (App Pull)", es: "Local (App Pull)"))
                                    .foregroundColor(.primary)
                                    .font(.body)
                                Text(lz(en: "Works only when the app is active in foreground or background (100% Local)", de: "Funktioniert nur wenn App im Vordergrund oder Hintergrund aktiv ist (100% Lokal)", fr: "Fonctionne uniquement si l'app est active en premier plan ou arrière-plan (100% Local)", es: "Funciona solo cuando la app está activa en primer o segundo plano (100% Local)"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if config.pushMode == .off {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                }

                Section {
                    Button(role: .destructive) {
                        showResetLayoutConfirm = true
                    } label: {
                        HStack {
                            Spacer()
                            Label(lz(en: "Reset Dashboard Layout", de: "Dashboard Layout zurücksetzen", fr: "Réinitialiser la mise en page", es: "Restablecer diseño"),
                                  systemImage: "arrow.counterclockwise")
                            Spacer()
                        }
                    }
                }

                Section {
                    Button(action: {
                        var updated = config
                        updated.ip = config.ip.hasPrefix("http") ? config.ip : "http://\(config.ip)"
                        if !updated.octoEverywhereURL.isEmpty && !updated.octoEverywhereURL.hasPrefix("http") {
                            updated.octoEverywhereURL = "https://\(updated.octoEverywhereURL)"
                        }
                        // Auto-generate secret when push is enabled
                        if updated.pushMode == .cloudflare && updated.cloudflareNotifySecret.isEmpty {
                            updated.cloudflareNotifySecret = CloudflarePushService.generateSecret()
                        }
                        onSave(updated)
                        // Register device token in background
                        if updated.pushMode == .cloudflare,
                           !updated.cloudflareNotifySecret.isEmpty,
                           let token = CloudflarePushService.shared.storedDeviceToken {
                            let secret = updated.cloudflareNotifySecret
                            let pid = updated.name
                            Task {
                                try? await CloudflarePushService.shared.registerDeviceToken(
                                    workerURL: CloudflarePushService.workerURL,
                                    printerID: pid,
                                    deviceToken: token,
                                    secret: secret
                                )
                            }
                        }
                        onDismiss?()
                        dismiss()
                    }) {
                        HStack { Spacer(); Text(lz(en: "Save", de: "Speichern", fr: "Enregistrer", es: "Guardar")).bold(); Spacer() }
                    }
                    .foregroundColor(.white).listRowBackground(Color.blue)
                    .disabled(config.name.isEmpty || config.ip.isEmpty)
                }
            }
            .navigationTitle(config.name.isEmpty ? lz(en: "New Printer", de: "Neuer Drucker", fr: "Nouvelle imprimante", es: "Nueva impresora") : config.name)
            .navigationBarItems(leading: Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar")) { onDismiss?(); dismiss() })
        }
        .sheet(isPresented: $showOctoGuide) {
            OctoEverywhereGuideView(printerType: config.type)
        }
        .sheet(isPresented: $showLocalGuide) {
            LocalConnectionGuideView()
        }
        .sheet(isPresented: $showScriptGuide) {
            PushScriptGuideView(
                printerID: config.name,
                secret: config.cloudflareNotifySecret,
                printerIP: config.ip,
                printerType: config.type
            )
        }
        .sheet(isPresented: $showPushInfo) {
            PushInfoView()
        }

        .sheet(isPresented: $showSmartPlugGuide) {
            SmartPlugGuideView()
        }
    }
}

// MARK: - Push Mode Info Sheet
struct PushInfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // Server Push
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: "cloud.fill")
                                .font(.title2)
                                .foregroundColor(.purple)
                                .frame(width: 36)
                            Text(lz(en: "Server Push (coming soon)", de: "Server-Push (coming soon)", fr: "Push serveur (coming soon)", es: "Push servidor (coming soon)"))
                                .font(.title3.bold())
                        }
                        Text(lz(
                            en: "A small Python script runs continuously on the printer and sends the current progress to a Cloudflare server every 10 seconds. From there, your iPhone is updated directly via push notification.",
                            de: "Ein kleines Python-Script läuft dauerhaft auf dem Drucker und sendet alle 10 Sekunden den aktuellen Fortschritt an einen Cloudflare-Server. Von dort wird dein iPhone direkt per Push-Benachrichtigung aktualisiert.",
                            fr: "Un petit script Python tourne en permanence sur l'imprimante et envoie la progression toutes les 10 secondes à un serveur Cloudflare. De là, votre iPhone est mis à jour directement par notification push.",
                            es: "Un pequeño script Python corre continuamente en la impresora y envía el progreso actual a un servidor Cloudflare cada 10 segundos. Desde allí, tu iPhone se actualiza directamente por notificación push."
                        ))
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            InfoRow(icon: "checkmark.circle.fill", color: .green,
                                    text: lz(en: "Works even when the app is completely closed", de: "Funktioniert auch wenn die App komplett geschlossen ist", fr: "Fonctionne même si l'app est complètement fermée", es: "Funciona aunque la app esté completamente cerrada"))
                            InfoRow(icon: "checkmark.circle.fill", color: .green,
                                    text: lz(en: "Works from anywhere — regardless of your network", de: "Funktioniert von überall — egal ob du zuhause bist oder nicht", fr: "Fonctionne de partout — peu importe votre réseau", es: "Funciona desde cualquier lugar — sin importar tu red"))
                            InfoRow(icon: "checkmark.circle.fill", color: .green,
                                    text: lz(en: "Progress, pause, error and completion in real time", de: "Fortschritt, Pause, Fehler und Abschluss in Echtzeit", fr: "Progression, pause, erreur et fin en temps réel", es: "Progreso, pausa, error y finalización en tiempo real"))
                            InfoRow(icon: "info.circle.fill", color: .orange,
                                    text: lz(en: "One-time SSH setup on the printer required", de: "Einmalige SSH-Einrichtung auf dem Drucker nötig", fr: "Configuration SSH unique sur l'imprimante requise", es: "Configuración SSH única en la impresora necesaria"))
                        }

                        Text(lz(en: "Flow", de: "Ablauf", fr: "Flux", es: "Flujo"))
                            .font(.headline)
                            .padding(.top, 4)
                        HStack(spacing: 0) {
                            VStack(spacing: 0) {
                                FlowStep(icon: "printer.fill",    color: .gray,   label: lz(en: "Printer", de: "Drucker", fr: "Imprimante", es: "Impresora"))
                                connector
                                FlowStep(icon: "cloud.fill",      color: .purple, label: "Cloudflare")
                                connector
                                FlowStep(icon: "applelogo",       color: .primary.opacity(0.7), label: "Apple Server")
                                connector
                                FlowStep(icon: "iphone",          color: .blue,   label: "iPhone")
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(14)

                    // Local
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: "iphone")
                                .font(.title2)
                                .foregroundColor(.blue)
                                .frame(width: 36)
                            Text(lz(en: "Local", de: "Lokal", fr: "Local", es: "Local"))
                                .font(.title3.bold())
                        }
                        Text(lz(
                            en: "The app queries Moonraker directly and updates the Live Activity itself. No script, no server.",
                            de: "Die App fragt Moonraker direkt ab und aktualisiert die Live Activity selbst. Kein Script, kein Server.",
                            fr: "L'app interroge Moonraker directement et met à jour la Live Activity elle-même. Pas de script, pas de serveur.",
                            es: "La app consulta Moonraker directamente y actualiza la Live Activity por sí misma. Sin script, sin servidor."
                        ))
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            InfoRow(icon: "checkmark.circle.fill", color: .green,
                                    text: lz(en: "No setup needed — works immediately", de: "Kein Setup nötig — funktioniert sofort", fr: "Aucune configuration — fonctionne immédiatement", es: "Sin configuración — funciona de inmediato"))
                            InfoRow(icon: "checkmark.circle.fill", color: .green,
                                    text: lz(en: "No script on the printer", de: "Kein Script auf dem Drucker", fr: "Pas de script sur l'imprimante", es: "Sin script en la impresora"))
                            InfoRow(icon: "info.circle.fill", color: .orange,
                                    text: lz(en: "Requires network access to the printer (home network or OctoEverywhere)", de: "Benötigt Netzwerkzugang zum Drucker (Heimnetz oder OctoEverywhere)", fr: "Nécessite un accès réseau à l'imprimante (réseau local ou OctoEverywhere)", es: "Requiere acceso de red a la impresora (red local u OctoEverywhere)"))
                            InfoRow(icon: "info.circle.fill", color: .orange,
                                    text: lz(en: "Updates only while the app is in the foreground or background", de: "Updates nur solange die App im Vordergrund oder Hintergrund läuft", fr: "Mises à jour uniquement si l'app est au premier plan ou en arrière-plan", es: "Actualizaciones solo mientras la app esté en primer plano o en segundo plano"))
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(14)
                }
                .padding()
            }
            .navigationTitle(lz(en: "Push Modes Explained", de: "Push-Modi erklärt", fr: "Modes push expliqués", es: "Modos push explicados"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(lz(en: "Done", de: "Fertig", fr: "OK", es: "Listo")) { dismiss() }
                }
            }
        }
    }

    private var connector: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 2, height: 16)
            .frame(maxWidth: .infinity)
    }
}

private struct InfoRow: View {
    let icon: String; let color: Color; let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundColor(color).font(.callout)
            Text(text).font(.callout).foregroundColor(.secondary)
        }
    }
}

private struct FlowStep: View {
    let icon: String; let color: Color; let label: String
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.body)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Push Script Install Guide
struct PushScriptGuideView: View {
    let printerID: String
    let secret: String
    let printerIP: String
    let printerType: PrinterConfig.PrinterType
    @Environment(\.dismiss) private var dismiss

    private let scriptPath = "/home/lava/printer_data/paxxmaker_bridge.py"

    private var printerHost: String {
        printerIP
            .replacingOccurrences(of: "http://",  with: "")
            .replacingOccurrences(of: "https://", with: "")
            .components(separatedBy: ":").first?
            .trimmingCharacters(in: .whitespaces) ?? printerIP
    }

    private var sshUser: String {
        switch printerType {
        case .snapmakerU1:  return "root"
        case .singleNozzle: return "pi"
        }
    }

    private var sshConnectCommand: String {
        "ssh \(sshUser)@\(printerHost)"
    }

    private var installCommand: String {
        var components = URLComponents(string: CloudflarePushService.workerURL + "/install")!
        components.queryItems = [
            URLQueryItem(name: "id",     value: printerID),
            URLQueryItem(name: "secret", value: secret)
        ]
        let url = components.url?.absoluteString ?? ""
        return "curl -fsSL \"\(url)\" | sh"
    }

    private var removeCommands: String {
        """
        pkill -f paxxmaker_bridge.py 2>/dev/null || true
        rm -f /home/lava/printer_data/config/extended/moonraker/paxxmaker.cfg 2>/dev/null || true
        rm -f /home/lava/printer_data/paxxmaker_start.sh 2>/dev/null || true
        rm -f \(scriptPath) 2>/dev/null || true
        sed -i '/paxxmaker\\.cfg/d' /home/lava/printer_data/config/printer.cfg 2>/dev/null || true
        rm -f /home/lava/printer_data/config/paxxmaker.cfg 2>/dev/null || true
        rm -f /home/lava/klipper/klippy/extras/paxxmaker_autostart.py 2>/dev/null || true
        rm -f /oem/.debug 2>/dev/null || true
        reboot
        """
    }

    @State private var showRemove = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // SSH connect hint
                    VStack(alignment: .leading, spacing: 8) {
                        Label(lz(en: "Step 1 — Connect via SSH", de: "Schritt 1 — SSH verbinden", fr: "Étape 1 — Connexion SSH", es: "Paso 1 — Conectar por SSH"), systemImage: "terminal")
                            .font(.headline)
                        Text(lz(en: "Open Terminal on your Mac and connect to the printer:", de: "Öffne das Terminal auf deinem Mac und verbinde dich mit dem Drucker:", fr: "Ouvrez le Terminal sur votre Mac et connectez-vous à l'imprimante :", es: "Abre Terminal en tu Mac y conéctate a la impresora:"))
                            .font(.callout).foregroundColor(.secondary)
                        HStack {
                            Text(sshConnectCommand)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundColor(.green)
                                .padding(10)
                                .background(Color.black)
                                .cornerRadius(8)
                            Button {
                                UIPasteboard.general.string = sshConnectCommand
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .foregroundColor(.purple)
                            }
                        }
                        Text(printerType == .snapmakerU1
                             ? lz(en: "Password: snapmaker (paxx12 custom firmware default).", de: "Passwort: snapmaker (Standard der paxx12 Custom Firmware).", fr: "Mot de passe : snapmaker (défaut du firmware custom paxx12).", es: "Contraseña: snapmaker (predeterminado del firmware personalizado paxx12).")
                             : lz(en: "Password: default is **raspberry** or blank.", de: "Passwort: standardmäßig **raspberry** oder leer.", fr: "Mot de passe : **raspberry** par défaut ou vide.", es: "Contraseña: por defecto **raspberry** o vacío."))
                            .font(.caption).foregroundColor(.secondary)

                        Divider()

                        // Host key warning hint
                        VStack(alignment: .leading, spacing: 4) {
                            Label(lz(en: "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED?", de: "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED?", fr: "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED ?", es: "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED?"), systemImage: "exclamationmark.triangle")
                                .font(.caption.bold())
                                .foregroundColor(.orange)
                            Text(lz(
                                en: "This happens after a firmware update. Fix it with:",
                                de: "Passiert nach einem Firmware-Update. Beheben mit:",
                                fr: "Cela arrive après une mise à jour du firmware. Correction :",
                                es: "Ocurre tras una actualización de firmware. Corrección:"
                            ))
                            .font(.caption).foregroundColor(.secondary)
                            HStack {
                                Text("ssh-keygen -R \(printerHost)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.green)
                                    .padding(8)
                                    .background(Color.black)
                                    .cornerRadius(6)
                                Button {
                                    UIPasteboard.general.string = "ssh-keygen -R \(printerHost)"
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)

                    // Install command
                    CommandBox(
                        title: lz(en: "Step 2 — Run in Terminal", de: "Schritt 2 — Im Terminal ausführen", fr: "Étape 2 — Exécuter dans Terminal", es: "Paso 2 — Ejecutar en Terminal"),
                        commands: installCommand,
                        accentColor: .purple
                    )

                    Divider()

                    // Remove commands
                    VStack(alignment: .leading, spacing: 8) {
                        Label(lz(en: "Remove script", de: "Script entfernen", fr: "Supprimer le script", es: "Eliminar script"), systemImage: "trash")
                            .font(.headline)
                            .foregroundColor(.red)
                        CommandBox(
                            title: lz(en: "Uninstall (SSH)", de: "Deinstallation (SSH)", fr: "Désinstallation (SSH)", es: "Desinstalación (SSH)"),
                            commands: removeCommands,
                            accentColor: .red
                        )
                    }
                }
                .padding()
            }
            .navigationTitle(lz(en: "Printer Script", de: "Drucker-Script", fr: "Script imprimante", es: "Script impresora"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(lz(en: "Done", de: "Fertig", fr: "OK", es: "Listo")) { dismiss() }
                }
            }
        }
    }
}

private struct BulletLine: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundColor(.secondary)
            Text(text).font(.caption).foregroundColor(.secondary)
        }
    }
}

private struct CommandBox: View {
    let title: String
    let commands: String
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: "terminal")
                    .font(.headline)
                    .foregroundColor(accentColor)
                Spacer()
                Button {
                    UIPasteboard.general.string = commands
                } label: {
                    Label(lz(en: "Copy", de: "Kopieren", fr: "Copier", es: "Copiar"), systemImage: "doc.on.doc")
                        .font(.caption)
                        .foregroundColor(accentColor)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(commands)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.green)
                    .padding(12)
            }
            .background(Color.black)
            .cornerRadius(8)
        }
    }
}

// MARK: - Uninstall Guide View
struct UninstallGuideView: View {
    let printerIP: String
    let printerType: PrinterConfig.PrinterType
    @Environment(\.dismiss) private var dismiss

    private let scriptPath = "/home/lava/printer_data/paxxmaker_bridge.py"

    private var printerHost: String {
        printerIP
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .components(separatedBy: ":").first?
            .trimmingCharacters(in: .whitespaces) ?? printerIP
    }

    private var sshUser: String {
        switch printerType {
        case .snapmakerU1:  return "root"
        case .singleNozzle: return "pi"
        }
    }

    private var sshConnectCommand: String { "ssh \(sshUser)@\(printerHost)" }

    private var removeCommands: String {
        """
        pkill -f paxxmaker_bridge.py 2>/dev/null || true
        rm -f /home/lava/printer_data/config/extended/moonraker/paxxmaker.cfg 2>/dev/null || true
        rm -f /home/lava/printer_data/paxxmaker_start.sh 2>/dev/null || true
        rm -f \(scriptPath) 2>/dev/null || true
        sed -i '/paxxmaker\\.cfg/d' /home/lava/printer_data/config/printer.cfg 2>/dev/null || true
        rm -f /home/lava/printer_data/config/paxxmaker.cfg 2>/dev/null || true
        rm -f /home/lava/klipper/klippy/extras/paxxmaker_autostart.py 2>/dev/null || true
        rm -f /oem/.debug 2>/dev/null || true
        reboot
        """
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(lz(en: "Step 1 — Connect via SSH", de: "Schritt 1 — SSH verbinden", fr: "Étape 1 — Connexion SSH", es: "Paso 1 — Conectar por SSH"),
                              systemImage: "terminal")
                            .font(.headline)
                        HStack {
                            Text(sshConnectCommand)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundColor(.green)
                                .padding(10)
                                .background(Color.black)
                                .cornerRadius(8)
                            Button { UIPasteboard.general.string = sshConnectCommand } label: {
                                Image(systemName: "doc.on.doc").foregroundColor(.purple)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label(lz(en: "Step 2 — Run these commands", de: "Schritt 2 — Diese Befehle ausführen", fr: "Étape 2 — Exécuter ces commandes", es: "Paso 2 — Ejecutar estos comandos"),
                              systemImage: "trash")
                            .font(.headline)
                        HStack(alignment: .top) {
                            Text(removeCommands)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.green)
                                .padding(10)
                                .background(Color.black)
                                .cornerRadius(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button { UIPasteboard.general.string = removeCommands } label: {
                                Image(systemName: "doc.on.doc").foregroundColor(.purple)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(lz(en: "Uninstall Push Script", de: "Push-Script deinstallieren", fr: "Désinstaller le script push", es: "Desinstalar script push"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(lz(en: "Done", de: "Fertig", fr: "OK", es: "Listo")) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Smart Plug Guide
struct SmartPlugGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Intro
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Image(systemName: "powerplug.fill")
                                .font(.title2).foregroundColor(.orange).frame(width: 36)
                            Text(lz(en: "Tuya / SmartLife Smart Plug", de: "Tuya / SmartLife Smart-Steckdose",
                                    fr: "Prise Tuya / SmartLife", es: "Enchufe Tuya / SmartLife"))
                                .font(.title3.bold())
                        }
                        Text(lz(
                            en: "These plugs don't use plain HTTP — they speak Tuya's encrypted LAN protocol v3.5. The app connects directly over your local network. You need three values: IP address, Device ID, and Local Key.",
                            de: "Diese Steckdosen verwenden kein einfaches HTTP, sondern das verschlüsselte Tuya-LAN-Protokoll v3.5. Die App verbindet sich direkt über dein Heimnetz. Du brauchst drei Werte: IP-Adresse, Geräte-ID und Local Key.",
                            fr: "Ces prises n'utilisent pas HTTP simple — elles parlent le protocole LAN Tuya v3.5 chiffré. L'app se connecte directement sur votre réseau local. Vous avez besoin de trois valeurs : IP, ID appareil et clé locale.",
                            es: "Estos enchufes no usan HTTP simple — usan el protocolo LAN Tuya v3.5 cifrado. La app se conecta directamente por tu red local. Necesitas tres valores: IP, ID de dispositivo y clave local."
                        ))
                        .font(.subheadline).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .background(Color(.systemGray6)).cornerRadius(14)

                    // Step 1
                    stepCard(number: 1, icon: "desktopcomputer", color: .blue,
                             title: lz(en: "Install tinytuya on your Mac", de: "tinytuya auf dem Mac installieren",
                                       fr: "Installer tinytuya sur votre Mac", es: "Instalar tinytuya en tu Mac"),
                             body: lz(en: "Open Terminal and run:", de: "Terminal öffnen und ausführen:",
                                      fr: "Ouvrez Terminal et exécutez :", es: "Abre Terminal y ejecuta:"),
                             command: "pip3 install tinytuya")

                    // Step 2
                    stepCard(number: 2, icon: "globe", color: .indigo,
                             title: lz(en: "Set up Tuya developer account", de: "Tuya-Entwicklerkonto einrichten",
                                       fr: "Configurer le compte développeur Tuya", es: "Configurar cuenta desarrolladora Tuya"),
                             body: lz(
                                en: "Go to iot.tuya.com, sign up and create a Cloud Project. Subscribe to the IoT Core API. Under Devices > Link Tuya App Account, link your SmartLife account. Then note down your API Key (Access ID) and API Secret from the project overview — you will need both for the wizard.",
                                de: "Gehe zu iot.tuya.com, registriere dich und erstelle ein Cloud-Projekt. Abonniere die IoT Core API. Unter Geraete > Tuya-App-Konto verknuepfen dein SmartLife-Konto verknuepfen. Notiere dann den API Key (Access ID) und API Secret aus der Projektübersicht — beides brauchst du fuer den Wizard.",
                                fr: "Allez sur iot.tuya.com, inscrivez-vous et créez un projet Cloud. Abonnez-vous à l'API IoT Core. Dans Appareils > Lier un compte Tuya, liez votre compte SmartLife. Notez ensuite l'API Key (Access ID) et l'API Secret depuis la vue d'ensemble du projet — vous en aurez besoin pour l'assistant.",
                                es: "Ve a iot.tuya.com, regístrate y crea un proyecto Cloud. Suscríbete a la API IoT Core. En Dispositivos > Vincular cuenta Tuya, vincula tu cuenta SmartLife. Anota el API Key (Access ID) y el API Secret desde la vista del proyecto — los necesitarás para el asistente."
                             ),
                             command: nil)

                    // Step 3
                    stepCard(number: 3, icon: "wand.and.stars", color: .purple,
                             title: lz(en: "Run the tinytuya wizard", de: "tinytuya-Wizard starten",
                                       fr: "Lancer l'assistant tinytuya", es: "Ejecutar el asistente tinytuya"),
                             body: lz(
                                en: "Run the wizard in Terminal. It will ask for: API Key, API Secret, any Device ID (or type \"scan\"), and your region (eu, us, cn, …). It then downloads all device data and saves it to devices.json.",
                                de: "Den Wizard im Terminal starten. Er fragt nach: API Key, API Secret, einer beliebigen Geraete-ID (oder \"scan\" eingeben) und deiner Region (eu, us, cn, …). Anschliessend laedt er alle Gerätedaten herunter und speichert sie in devices.json.",
                                fr: "Lancez l'assistant dans Terminal. Il demandera : API Key, API Secret, un ID appareil quelconque (ou tapez \"scan\") et votre région (eu, us, cn, …). Il télécharge ensuite toutes les données et les enregistre dans devices.json.",
                                es: "Ejecuta el asistente en Terminal. Pedirá: API Key, API Secret, cualquier ID de dispositivo (o escribe \"scan\") y tu región (eu, us, cn, …). Luego descarga todos los datos y los guarda en devices.json."
                             ),
                             command: "python3 -m tinytuya wizard")

                    // Step 4
                    stepCard(number: 4, icon: "doc.text.magnifyingglass", color: .green,
                             title: lz(en: "Find your device in devices.json", de: "Gerät in devices.json suchen",
                                       fr: "Trouver votre appareil dans devices.json", es: "Buscar tu dispositivo en devices.json"),
                             body: lz(
                                en: "The wizard creates devices.json in the current folder. Find your plug by name. Copy \"id\" (Device ID, ~20 chars) and \"key\" (Local Key, 16 chars) into the app settings. The \"ip\" field contains the IP address if you chose to scan the network.",
                                de: "Der Wizard erstellt devices.json im aktuellen Ordner. Steckdose anhand des Namens finden. \"id\" (Geraete-ID, ca. 20 Zeichen) und \"key\" (Local Key, 16 Zeichen) in die App-Einstellungen eintragen. Das Feld \"ip\" enthaelt die IP-Adresse, wenn du das Netzwerk gescannt hast.",
                                fr: "L'assistant crée devices.json dans le dossier courant. Trouvez votre prise par son nom. Copiez \"id\" (ID appareil, ~20 cars) et \"key\" (clé locale, 16 cars) dans les réglages. Le champ \"ip\" contient l'adresse IP si vous avez scanné le réseau.",
                                es: "El asistente crea devices.json en la carpeta actual. Busca tu enchufe por nombre. Copia \"id\" (ID de dispositivo, ~20 chars) y \"key\" (clave local, 16 chars) en los ajustes. El campo \"ip\" contiene la IP si escaneaste la red."
                             ),
                             command: nil)

                    // Info row
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle.fill").foregroundColor(.orange)
                        Text(lz(
                            en: "The Local Key changes if the device is re-linked or the SmartLife account is re-connected. Re-run the wizard if the connection stops working.",
                            de: "Der Local Key aendert sich, wenn das Gerät erneut verknüpft oder das SmartLife-Konto neu verbunden wird. Den Wizard erneut ausfuehren, wenn die Verbindung nicht mehr funktioniert.",
                            fr: "La clé locale change si l'appareil est ré-associé ou le compte SmartLife reconnecté. Relancez l'assistant si la connexion ne fonctionne plus.",
                            es: "La clave local cambia si el dispositivo se vuelve a vincular o la cuenta SmartLife se reconecta. Vuelve a ejecutar el asistente si la conexión deja de funcionar."
                        ))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.08)).cornerRadius(10)
                }
                .padding()
            }
            .navigationTitle(lz(en: "Smart Plug Setup", de: "Smart-Steckdose einrichten",
                                fr: "Config. prise intelligente", es: "Configurar enchufe"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(lz(en: "Done", de: "Fertig", fr: "OK", es: "Listo")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func stepCard(number: Int, icon: String, color: Color,
                          title: String, body: String, command: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(color.opacity(0.15)).frame(width: 36, height: 36)
                    Text("\(number)").font(.system(size: 15, weight: .bold)).foregroundColor(color)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: icon).foregroundColor(color).font(.subheadline)
                        Text(title).font(.subheadline.bold())
                    }
                    Text(body).font(.subheadline).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let cmd = command {
                HStack {
                    Text(cmd)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundColor(.green)
                        .padding(10)
                        .background(Color.black)
                        .cornerRadius(8)
                    Button {
                        UIPasteboard.general.string = cmd
                    } label: {
                        Image(systemName: "doc.on.doc").foregroundColor(.purple)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Smart Plug Tile
struct SmartPlugTileView: View {
    let plugIP: String
    let deviceID: String
    let localKey: String
    let plugType: PrinterConfig.SmartPlugType
    let isBusy: Bool

    @State private var isOn: Bool? = nil
    @State private var watts: Double? = nil
    @State private var isLoading = false
    @State private var errorMsg: String? = nil
    @State private var showConfirmOff = false
    @State private var showConfirmBusy = false

    private var tuyaConfig: TuyaLocalService.Config? {
        plugType == .tuya ? TuyaLocalService.Config(host: plugIP, deviceID: deviceID, localKey: localKey) : nil
    }

    private var isConfigured: Bool {
        plugType == .shelly ? !plugIP.isEmpty : tuyaConfig != nil
    }

    // MARK: - Toggle geometry (adaptive — fills available width)
    private let trackH: CGFloat = 64
    private let knobD:  CGFloat = 50
    private let pad:    CGFloat = 7
    @State private var trackW: CGFloat = 160

    private var knobOffset: CGFloat {
        let half = trackW / 2 - knobD / 2 - pad
        guard let on = isOn else { return 0 }
        return on ? half : -half
    }

    // MARK: - Body
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(.thinMaterial)
            RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06))
            RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.22), lineWidth: 1)

            VStack(spacing: 14) {
                // ── Header ──
                HStack {
                    Image(systemName: "powerplug.fill")
                        .foregroundColor(isOn == true ? .green : .secondary)
                        .font(.caption)
                        .animation(.easeInOut(duration: 0.3), value: isOn == true)
                    Text(lz(en: "Smart Plug", de: "Smart-Steckdose",
                            fr: "Prise intelligente", es: "Enchufe inteligente"))
                        .font(.caption).fontWeight(.semibold)
                        .foregroundColor(.secondary).textCase(.uppercase).tracking(1)
                    Spacer()
                    if let _ = errorMsg, isOn == nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange).font(.caption)
                    }
                }

                // ── Toggle ──
                ZStack {
                    // Track
                    Capsule()
                        .fill(isOn == true
                            ? LinearGradient(colors: [Color(red: 0.18, green: 0.8, blue: 0.44),
                                                       Color(red: 0.13, green: 0.64, blue: 0.33)],
                                             startPoint: .leading, endPoint: .trailing)
                            : LinearGradient(colors: [Color(.systemGray5), Color(.systemGray4)],
                                             startPoint: .leading, endPoint: .trailing))
                        .overlay(
                            Capsule().strokeBorder(
                                isOn == true ? Color.green.opacity(0.45) : Color.white.opacity(0.08),
                                lineWidth: 1.5
                            )
                        )
                        .shadow(color: isOn == true ? Color.green.opacity(0.45) : .clear,
                                radius: 14, x: 0, y: 0)
                        .animation(.easeInOut(duration: 0.28), value: isOn == true)

                    // Labels that fade based on position
                    HStack {
                        Text(lz(en: "OFF", de: "AUS", fr: "OFF", es: "OFF"))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.75))
                            .padding(.leading, 16)
                            .opacity(isOn == false ? 1 : 0)
                        Spacer()
                        Text(lz(en: "ON", de: "EIN", fr: "ON", es: "ON"))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.trailing, 16)
                            .opacity(isOn == true ? 1 : 0)
                    }
                    .animation(.easeInOut(duration: 0.2), value: isOn)

                    // Knob
                    ZStack {
                        Circle()
                            .fill(.white)
                            .shadow(color: .black.opacity(0.22), radius: 5, x: 0, y: 2)
                        if isLoading {
                            ProgressView().scaleEffect(0.6).tint(Color(.systemGray2))
                        } else {
                            Image(systemName: "power")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(isOn == true ? Color(red: 0.13, green: 0.64, blue: 0.33) : Color(.systemGray3))
                                .animation(.easeInOut(duration: 0.25), value: isOn == true)
                        }
                    }
                    .frame(width: knobD, height: knobD)
                    .offset(x: knobOffset)
                    .animation(.spring(response: 0.38, dampingFraction: 0.72), value: isOn)
                }
                .frame(maxWidth: .infinity, minHeight: trackH, maxHeight: trackH)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { trackW = geo.size.width }
                            .onChange(of: geo.size.width) { _, w in trackW = w }
                    }
                )
                .contentShape(Capsule())
                .onTapGesture {
                    guard !isLoading, isConfigured else { return }
                    if isOn == true { showConfirmOff = true } else { sendPower(true) }
                }
                .disabled(!isConfigured)

                // ── Status text + wattage ──
                VStack(spacing: 2) {
                    Group {
                        if let err = errorMsg, isOn == nil {
                            Text(err)
                                .foregroundColor(.orange)
                        } else {
                            Text(isOn == nil
                                 ? lz(en: "Connecting…", de: "Verbinde…", fr: "Connexion…", es: "Conectando…")
                                 : (isOn! ? lz(en: "On", de: "Eingeschaltet", fr: "Allumée", es: "Encendido")
                                          : lz(en: "Off", de: "Ausgeschaltet", fr: "Éteinte", es: "Apagado")))
                            .foregroundColor(isOn == true ? .green : .secondary)
                        }
                    }
                    .font(.caption2)
                    .animation(.easeInOut(duration: 0.25), value: isOn == true)

                    if let w = watts {
                        Text(String(format: "%.1f W", w))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .transition(.opacity)
                    }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity)
        .confirmationDialog(
            lz(en: "Really cut power?", de: "Strom wirklich ausschalten?",
               fr: "Couper l'alimentation ?", es: "¿Cortar la corriente?"),
            isPresented: $showConfirmOff, titleVisibility: .visible) {
            Button(lz(en: "Yes", de: "Ja", fr: "Oui", es: "Sí"), role: .destructive) {
                if isBusy { showConfirmBusy = true } else { sendPower(false) }
            }
            Button(lz(en: "No", de: "Nein", fr: "Non", es: "No"), role: .cancel) {}
        }
        .confirmationDialog(
            lz(en: "Printer is busy — really cut power?",
               de: "Drucker ist gerade beschäftigt, wirklich ausschalten?",
               fr: "L'imprimante est occupée, couper quand même ?",
               es: "La impresora está ocupada, ¿cortar igual?"),
            isPresented: $showConfirmBusy, titleVisibility: .visible) {
            Button(lz(en: "Yes", de: "Ja", fr: "Oui", es: "Sí"), role: .destructive) {
                sendPower(false)
            }
            Button(lz(en: "No", de: "Nein", fr: "Non", es: "No"), role: .cancel) {}
        }
        .task {
            while !Task.isCancelled {
                await pollStatus()
                try? await Task.sleep(nanoseconds: 4_000_000_000)  // 4 s
            }
        }
    }

    // MARK: - Logic
    private func pollStatus() async {
        guard isConfigured else { return }
        do {
            let status: PlugStatus
            if plugType == .shelly {
                status = try await ShellyLocalService.getStatus(host: plugIP)
            } else {
                guard let cfg = tuyaConfig else { return }
                status = try await TuyaLocalService.getStatus(config: cfg)
            }
            await MainActor.run { isOn = status.power; watts = status.watts; errorMsg = nil }
        } catch {
            await MainActor.run { errorMsg = error.localizedDescription }
        }
    }

    private func sendPower(_ on: Bool) {
        guard isConfigured else { return }
        isLoading = true
        Task {
            do {
                if plugType == .shelly {
                    try await ShellyLocalService.setPower(on, host: plugIP)
                } else {
                    guard let cfg = tuyaConfig else { return }
                    try await TuyaLocalService.setPower(on, config: cfg)
                }
                await MainActor.run { isOn = on; isLoading = false; errorMsg = nil }
            } catch {
                await MainActor.run { isLoading = false; errorMsg = error.localizedDescription }
            }
        }
    }
}

struct LocalConnectionGuideView: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 16) {
                        Image(systemName: "house.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.blue)
                            .padding(16)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(lz(en: "Local Connection", de: "Lokale Verbindung",
                                    fr: "Connexion locale", es: "Conexión local"))
                                .font(.title2.bold())
                            Text(lz(en: "Direct access in your network", de: "Direktzugriff im Netzwerk",
                                    fr: "Accès direct au réseau", es: "Acceso directo a la red"))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 12) {
                        Label(lz(en: "Works at home via Wi-Fi",
                                 de: "Funktioniert zuhause per WLAN",
                                 fr: "Fonctionne à la maison via Wi-Fi",
                                 es: "Funciona en casa por Wi-Fi"),
                              systemImage: "wifi")
                            .font(.body.weight(.medium))

                        Label(lz(en: "Also works from anywhere via VPN",
                                 de: "Auch von unterwegs per VPN nutzbar",
                                 fr: "Fonctionne aussi partout via VPN",
                                 es: "También desde cualquier lugar con VPN"),
                              systemImage: "lock.shield.fill")
                            .font(.body.weight(.medium))
                            .foregroundColor(.blue)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text(lz(en: "VPN Tip", de: "VPN-Tipp",
                                fr: "Conseil VPN", es: "Consejo VPN"))
                            .font(.headline)
                        Text(lz(
                            en: "Set up a VPN server on your router (e.g. WireGuard or OpenVPN). Once connected, the app reaches your printer just like at home – no port forwarding needed.",
                            de: "Richte einen VPN-Server auf deinem Router ein (z.B. WireGuard oder OpenVPN). Wenn du verbunden bist, erreicht die App deinen Drucker wie zuhause – keine Portweiterleitung nötig.",
                            fr: "Configurez un serveur VPN sur votre routeur (ex. WireGuard ou OpenVPN). Une fois connecté, l'app atteint votre imprimante comme à la maison – sans redirection de port.",
                            es: "Configura un servidor VPN en tu router (ej. WireGuard o OpenVPN). Una vez conectado, la app accede a tu impresora como en casa – sin redirección de puertos."
                        ))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding()
                    .background(Color.blue.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
            .navigationTitle(lz(en: "Local", de: "Lokal", fr: "Local", es: "Local"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(lz(en: "Done", de: "Fertig", fr: "OK", es: "Listo")) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Onboarding View
struct OnboardingView: View {
    @ObservedObject var settings: SettingsStore
    var onComplete: () -> Void

    @State private var isSearching = false
    @State private var foundPrinters: [FoundPrinter] = []
    @State private var selectedIDs: Set<UUID> = []
    @State private var printerTypes: [UUID: PrinterConfig.PrinterType] = [:]
    @State private var manualIP = ""
    @State private var printerName = ""
    @State private var manualType: PrinterConfig.PrinterType = .snapmakerU1
    @State private var searchDone = false

    struct FoundPrinter: Identifiable {
        let id = UUID()
        let name: String
        let ip: String
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 12) {
                        Image(systemName: "printer.fill").font(.system(size: 60)).foregroundColor(.blue)
                            .padding(24).background(Color.blue.opacity(0.1)).clipShape(Circle())
                        Text(lz(en: "Welcome", de: "Willkommen", fr: "Bienvenue", es: "Bienvenido")).font(.largeTitle).bold()
                        Text(lz(en: "Let's find your printer", de: "Lass uns deinen Drucker finden", fr: "Trouvons votre imprimante", es: "Busquemos tu impresora")).font(.subheadline).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 40)

                    VStack(spacing: 12) {
                        Button(action: { searchForPrinters() }) {
                            HStack {
                                if isSearching { ProgressView().scaleEffect(0.8).tint(.white) }
                                else { Image(systemName: "magnifyingglass") }
                                Text(lz(en: isSearching ? "Searching..." : "Search Network", de: isSearching ? "Suche läuft..." : "Im Netzwerk suchen", fr: isSearching ? "Recherche..." : "Chercher sur le réseau", es: isSearching ? "Buscando..." : "Buscar en la red")).bold()
                            }
                            .foregroundColor(.white).frame(maxWidth: .infinity).padding()
                            .background(isSearching ? Color.blue.opacity(0.6) : Color.blue).cornerRadius(14)
                        }
                        .disabled(isSearching)

                        if !foundPrinters.isEmpty {
                            VStack(spacing: 8) {
                                ForEach(foundPrinters) { printer in
                                    let isSelected = selectedIDs.contains(printer.id)
                                    let type = printerTypes[printer.id] ?? .snapmakerU1
                                    Button(action: { togglePrinter(printer) }) {
                                        HStack(spacing: 12) {
                                            Image(type.imageName)
                                                .resizable().scaledToFit().frame(width: 32, height: 32)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(printer.name).font(.subheadline).bold()
                                                Text(printer.ip).font(.caption).foregroundColor(.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                                .foregroundColor(isSelected ? .blue : .secondary).font(.title3)
                                        }
                                        .padding()
                                        .background(isSelected ? Color.blue.opacity(0.08) : Color(.secondarySystemBackground))
                                        .cornerRadius(12)
                                        .overlay(RoundedRectangle(cornerRadius: 12)
                                            .stroke(isSelected ? Color.blue.opacity(0.4) : .clear, lineWidth: 1.5))
                                    }
                                    .buttonStyle(.plain)

                                    if isSelected {
                                        Picker("", selection: Binding(
                                            get: { printerTypes[printer.id] ?? .snapmakerU1 },
                                            set: { printerTypes[printer.id] = $0 }
                                        )) {
                                            ForEach(PrinterConfig.PrinterType.allCases, id: \.self) { t in
                                                Label(t.rawValue, image: t.imageName).tag(t)
                                            }
                                        }
                                        .pickerStyle(.segmented)
                                        .padding(.horizontal, 8)
                                    }
                                }
                            }

                            if !selectedIDs.isEmpty {
                                Button(action: { addSelectedPrinters() }) {
                                    HStack {
                                        Image(systemName: "plus.circle.fill")
                                        Text(lz(
                                            en: "Add \(selectedIDs.count) Printer\(selectedIDs.count > 1 ? "s" : "")",
                                            de: "\(selectedIDs.count) Drucker hinzufügen",
                                            fr: "Ajouter \(selectedIDs.count) imprimante\(selectedIDs.count > 1 ? "s" : "")",
                                            es: "Añadir \(selectedIDs.count) impresora\(selectedIDs.count > 1 ? "s" : "")"
                                        )).bold()
                                    }
                                    .foregroundColor(.white).frame(maxWidth: .infinity).padding()
                                    .background(Color.green).cornerRadius(14)
                                }
                                .padding(.top, 4)
                            }
                        } else if searchDone && !isSearching {
                            HStack {
                                Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
                                Text(lz(en: "No printer found", de: "Kein Drucker gefunden", fr: "Aucune imprimante trouvée", es: "Impresora no encontrada")).font(.subheadline).foregroundColor(.secondary)
                            }
                            .padding().background(Color(.secondarySystemBackground)).cornerRadius(12)
                        }
                    }
                    .padding(.horizontal)

                    HStack {
                        Rectangle().fill(Color(.separator)).frame(height: 1)
                        Text(lz(en: "or", de: "oder", fr: "ou", es: "o")).font(.caption).foregroundColor(.secondary).padding(.horizontal, 8)
                        Rectangle().fill(Color(.separator)).frame(height: 1)
                    }
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 12) {
                        Text(lz(en: "Add manually", de: "Manuell eingeben", fr: "Ajouter manuellement", es: "Añadir manualmente")).font(.subheadline).bold().padding(.horizontal)
                        VStack(spacing: 0) {
                            HStack {
                                Image(systemName: "printer.fill").foregroundColor(.blue).frame(width: 24)
                                TextField(lz(en: "Name e.g. Snapmaker U1", de: "Name z.B. Snapmaker U1", fr: "Nom ex. Snapmaker U1", es: "Nombre ej. Snapmaker U1"), text: $printerName)
                            }
                            .padding()
                            Divider().padding(.leading, 44)
                            HStack {
                                Image(systemName: "network").foregroundColor(.blue).frame(width: 24)
                                TextField(lz(en: "IP address e.g. 192.168.178.70", de: "IP-Adresse z.B. 192.168.178.70", fr: "Adresse IP ex. 192.168.178.70", es: "Dirección IP ej. 192.168.178.70"), text: $manualIP)
                                    .keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true)
                            }
                            .padding()
                        }
                        .background(Color(.secondarySystemBackground)).cornerRadius(14).padding(.horizontal)

                        Picker(lz(en: "Printer Type", de: "Druckertyp", fr: "Type d'imprimante", es: "Tipo de impresora"), selection: $manualType) {
                            ForEach(PrinterConfig.PrinterType.allCases, id: \.self) { t in
                                Label(t.rawValue, image: t.imageName).tag(t)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)

                        Button(action: { connectManually() }) {
                            HStack {
                                Image(systemName: "link")
                                Text(lz(en: "Connect", de: "Verbinden", fr: "Connecter", es: "Conectar")).bold()
                            }
                            .foregroundColor(.white).frame(maxWidth: .infinity).padding()
                            .background(manualIP.isEmpty ? Color.gray : Color.blue).cornerRadius(14)
                        }
                        .disabled(manualIP.isEmpty).padding(.horizontal)
                    }

                    HStack {
                        Rectangle().fill(Color(.separator)).frame(height: 1)
                        Text(lz(en: "or", de: "oder", fr: "ou", es: "o")).font(.caption).foregroundColor(.secondary).padding(.horizontal, 8)
                        Rectangle().fill(Color(.separator)).frame(height: 1)
                    }
                    .padding(.horizontal)

                    Button(action: { enterDemoMode() }) {
                        HStack(spacing: 10) {
                            Image(systemName: "play.circle.fill").font(.system(size: 16))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lz(en: "Try Demo Mode", de: "Demo-Modus starten", fr: "Essayer la démo", es: "Probar modo demo"))
                                    .bold()
                                Text(lz(en: "Simulates a Snapmaker U1 – no printer required", de: "Simuliert einen Snapmaker U1 – kein Drucker nötig", fr: "Simule un Snapmaker U1 – aucune imprimante requise", es: "Simula un Snapmaker U1 – sin impresora"))
                                    .font(.caption)
                                    .opacity(0.8)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).opacity(0.6)
                        }
                        .foregroundColor(.purple)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.purple.opacity(0.08))
                        .cornerRadius(14)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.purple.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)

                    Spacer(minLength: 40)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func enterDemoMode() {
        settings.printers = [PrinterConfig(
            name: lz(en: "Demo Printer", de: "Demo-Drucker", fr: "Imprimante démo", es: "Impresora demo"),
            ip: "__demo__",
            type: .snapmakerU1
        )]
        settings.hasCompletedOnboarding = true
        onComplete()
    }

    private func togglePrinter(_ printer: FoundPrinter) {
        if selectedIDs.contains(printer.id) {
            selectedIDs.remove(printer.id)
        } else {
            selectedIDs.insert(printer.id)
            if printerTypes[printer.id] == nil {
                printerTypes[printer.id] = .snapmakerU1
            }
        }
    }

    private func addSelectedPrinters() {
        let selected = foundPrinters.filter { selectedIDs.contains($0.id) }
        var configs: [PrinterConfig] = []
        for printer in selected {
            let type = printerTypes[printer.id] ?? .snapmakerU1
            configs.append(PrinterConfig(name: printer.name, ip: printer.ip, type: type))
        }
        settings.printers = configs
        settings.hasCompletedOnboarding = true
        onComplete()
    }

    func searchForPrinters() {
        isSearching = true; searchDone = false; foundPrinters = []; selectedIDs = []
        let baseIP = getLocalIPBase() ?? "192.168.178"
        var found: [FoundPrinter] = []
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "netscan", attributes: .concurrent)
        let lock = NSLock()
        for i in 1...254 {
            group.enter()
            queue.async {
                let ip = "\(baseIP).\(i)"
                guard let url = URL(string: "http://\(ip)/printer/info") else { group.leave(); return }
                var request = URLRequest(url: url, timeoutInterval: 1.5)
                request.httpMethod = "GET"
                URLSession.shared.dataTask(with: request) { data, _, _ in
                    if let data = data,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let result = json["result"] as? [String: Any] {
                        let hostname = result["hostname"] as? String ?? "Drucker"
                        lock.lock(); found.append(FoundPrinter(name: hostname, ip: "http://\(ip)")); lock.unlock()
                    }
                    group.leave()
                }.resume()
            }
        }
        group.notify(queue: .main) {
            self.foundPrinters = found.sorted { $0.ip < $1.ip }
            self.isSearching = false; self.searchDone = true
        }
    }

    func getLocalIPBase() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        var ptr = ifaddr
        while ptr != nil {
            let interface = ptr!.pointee
            if interface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
               String(cString: interface.ifa_name) == "en0" {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                address = String(cString: hostname)
            }
            ptr = ptr!.pointee.ifa_next
        }
        freeifaddrs(ifaddr)
        guard let ip = address else { return nil }
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }

    func connectManually() {
        guard !manualIP.isEmpty else { return }
        let ip = manualIP.hasPrefix("http") ? manualIP : "http://\(manualIP)"
        let name = printerName.isEmpty ? "Drucker" : printerName
        settings.printers = [PrinterConfig(name: name, ip: ip, type: manualType)]
        settings.hasCompletedOnboarding = true
        onComplete()
    }
}

// MARK: - Network Scan View (add printers from settings)
struct NetworkScanView: View {
    @ObservedObject var settings: SettingsStore
    var onSave: () -> Void
    var onDismiss: (() -> Void)? = nil
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var langStore: LanguageStore

    @State private var isSearching = false
    @State private var foundPrinters: [FoundPrinter] = []
    @State private var selectedIDs: Set<UUID> = []
    @State private var printerTypes: [UUID: PrinterConfig.PrinterType] = [:]
    @State private var searchDone = false

    struct FoundPrinter: Identifiable {
        let id = UUID()
        let name: String
        let ip: String
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button(action: { searchForPrinters() }) {
                        HStack {
                            if isSearching { ProgressView().scaleEffect(0.8) }
                            else { Image(systemName: "magnifyingglass") }
                            Text(lz(en: isSearching ? "Searching..." : "Search Network",
                                    de: isSearching ? "Suche läuft..." : "Im Netzwerk suchen",
                                    fr: isSearching ? "Recherche..." : "Chercher sur le réseau",
                                    es: isSearching ? "Buscando..." : "Buscar en la red"))
                        }
                    }
                    .disabled(isSearching)
                }
                if searchDone && foundPrinters.isEmpty {
                    Section {
                        Text(lz(en: "No printers found on the network.",
                                de: "Keine Drucker im Netzwerk gefunden.",
                                fr: "Aucune imprimante trouvée sur le réseau.",
                                es: "No se encontraron impresoras en la red."))
                            .foregroundColor(.secondary)
                    }
                }
                if !foundPrinters.isEmpty {
                    Section(header: Text(lz(en: "Found Printers", de: "Gefundene Drucker", fr: "Imprimantes trouvées", es: "Impresoras encontradas"))) {
                        ForEach(foundPrinters) { printer in
                            let isSelected = selectedIDs.contains(printer.id)
                            let alreadyAdded = settings.printers.contains { $0.ip == printer.ip }
                            Button(action: {
                                if !alreadyAdded {
                                    if isSelected { selectedIDs.remove(printer.id) }
                                    else { selectedIDs.insert(printer.id) }
                                }
                            }) {
                                HStack(spacing: 12) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(isSelected ? .blue : alreadyAdded ? .secondary : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(printer.name).font(.subheadline).bold()
                                        Text(printer.ip).font(.caption).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if alreadyAdded {
                                        Text(lz(en: "Added", de: "Vorhanden", fr: "Ajouté", es: "Añadido"))
                                            .font(.caption2).foregroundColor(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(alreadyAdded)
                            if isSelected {
                                Picker("", selection: Binding(
                                    get: { printerTypes[printer.id] ?? .snapmakerU1 },
                                    set: { printerTypes[printer.id] = $0 }
                                )) {
                                    ForEach(PrinterConfig.PrinterType.allCases, id: \.self) { t in
                                        Label(t.rawValue, image: t.imageName).tag(t)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                    }
                    if !selectedIDs.isEmpty {
                        Section {
                            Button(action: { addSelected() }) {
                                HStack {
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                    Text(lz(en: "Add \(selectedIDs.count) Printer\(selectedIDs.count > 1 ? "s" : "")",
                                            de: "\(selectedIDs.count) Drucker hinzufügen",
                                            fr: "Ajouter \(selectedIDs.count) imprimante\(selectedIDs.count > 1 ? "s" : "")",
                                            es: "Añadir \(selectedIDs.count) impresora\(selectedIDs.count > 1 ? "s" : "")")).bold()
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(lz(en: "Search Network", de: "Netzwerk suchen", fr: "Chercher réseau", es: "Buscar red"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(lz(en: "Done", de: "Fertig", fr: "OK", es: "Listo")) { onDismiss?(); dismiss() }
                }
            }
            .onAppear { searchForPrinters() }
        }
    }

    func addSelected() {
        for printer in foundPrinters where selectedIDs.contains(printer.id) {
            let type = printerTypes[printer.id] ?? .snapmakerU1
            settings.printers.append(PrinterConfig(name: printer.name, ip: printer.ip, type: type))
        }
        onSave()
        onDismiss?()
        dismiss()
    }

    func searchForPrinters() {
        isSearching = true; searchDone = false; foundPrinters = []; selectedIDs = []
        let baseIP = getLocalIPBase() ?? "192.168.178"
        var found: [FoundPrinter] = []
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "netscan2", attributes: .concurrent)
        let lock = NSLock()
        for i in 1...254 {
            group.enter()
            queue.async {
                let ip = "\(baseIP).\(i)"
                guard let url = URL(string: "http://\(ip)/printer/info") else { group.leave(); return }
                var request = URLRequest(url: url, timeoutInterval: 1.5)
                request.httpMethod = "GET"
                URLSession.shared.dataTask(with: request) { data, _, _ in
                    if let data = data,
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let result = json["result"] as? [String: Any] {
                        let hostname = result["hostname"] as? String ?? "Drucker"
                        lock.lock(); found.append(FoundPrinter(name: hostname, ip: "http://\(ip)")); lock.unlock()
                    }
                    group.leave()
                }.resume()
            }
        }
        group.notify(queue: .main) {
            self.foundPrinters = found.sorted { $0.ip < $1.ip }
            self.isSearching = false; self.searchDone = true
        }
    }

    func getLocalIPBase() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        var ptr = ifaddr
        while ptr != nil {
            let interface = ptr!.pointee
            if interface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
               String(cString: interface.ifa_name) == "en0" {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                address = String(cString: hostname)
            }
            ptr = ptr!.pointee.ifa_next
        }
        freeifaddrs(ifaddr)
        guard let ip = address else { return nil }
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }
}

// MARK: - Printer Services Manager
class PrinterServicesManager: ObservableObject {
    @Published var services: [PrinterService] = []

    func update(from settings: SettingsStore) {
        var updated: [PrinterService] = []
        for config in settings.printers {
            let url = config.effectiveBaseURL
            let key = config.connectionMode == .octoEverywhere ? config.octoEverywhereAPIKey : ""
            if let existing = services.first(where: { $0.name == config.name }) {
                existing.baseURL = url
                existing.extruderCount = config.type.extruderCount
                existing.printerType = config.type
                existing.apiKey = key
                existing.pushMode = config.pushMode
                existing.cloudflareNotifySecret = config.cloudflareNotifySecret
                existing.smartPlugType = config.smartPlugType
                existing.smartPlugIP = config.smartPlugIP
                existing.smartPlugDeviceID = config.smartPlugDeviceID
                existing.smartPlugLocalKey = config.smartPlugLocalKey
                existing.startPolling()
                updated.append(existing)
            } else {
                let svc = PrinterService(baseURL: url, name: config.name,
                                         extruderCount: config.type.extruderCount,
                                         printerType: config.type, apiKey: key)
                svc.pushMode = config.pushMode
                svc.cloudflareNotifySecret = config.cloudflareNotifySecret
                svc.smartPlugType = config.smartPlugType
                svc.smartPlugIP = config.smartPlugIP
                svc.smartPlugDeviceID = config.smartPlugDeviceID
                svc.smartPlugLocalKey = config.smartPlugLocalKey
                updated.append(svc)
            }
        }
        services = updated
    }
}

// MARK: - Scrollable Printer Tab View
struct ScrollablePrinterTabView: View {
    let printers: [(PrinterConfig, PrinterService)]
    let allServices: [PrinterService]
    let showNFCTab: Bool
    let onSettingsSave: () -> Void

    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var printerServices: PrinterServicesManager
    @State private var selectedTab: Int = 0
    @AppStorage("splitscreen_mode") private var splitscreenMode: Bool = false
    @AppStorage("current_splitscreen_count") private var storedSplitscreenCount: Int = 1
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var splitCurrentPage: Int = 0

    var nfcTabIndex: Int { printers.count }
    var settingsTabIndex: Int { printers.count + (showNFCTab ? 1 : 0) }

    private var isSplitscreenInTabMode: Bool {
        splitscreenMode && horizontalSizeClass == .regular && printers.count >= 2
    }

    private var visibleSplitRange: Range<Int> {
        let count = max(storedSplitscreenCount, 1)
        return splitCurrentPage..<min(splitCurrentPage + count, printers.count)
    }

    // Whether the main content shows SplitscreenView (not NFC or Settings)
    private var showingSplitContent: Bool {
        isSplitscreenInTabMode && selectedTab < printers.count
    }

    var body: some View {
        if isSplitscreenInTabMode {
            splitscreenWithTabBar
        } else if printers.count > 4 {
            contentView
                .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
        } else {
            TabView(selection: $selectedTab) {
                ForEach(Array(printers.enumerated()), id: \.0) { idx, pair in
                    PrintControlView(
                        printerService: pair.1,
                        printerID: pair.0.id.uuidString,
                        themeColorKey: pair.0.themeColor,
                        allServices: allServices
                    )
                    .tabItem { Label(pair.0.name, systemImage: pair.0.type.icon) }
                    .tag(idx)
                }
                if showNFCTab {
                    NFCView()
                        .tabItem { Label("NFC", systemImage: "wave.3.right") }
                        .tag(nfcTabIndex)
                }
                SettingsView(settings: settings, onSave: onSettingsSave)
                    .environmentObject(printerServices)
                    .tabItem {
                        Label(lz(en: "Settings", de: "Einstellungen", fr: "Paramètres", es: "Ajustes"),
                              systemImage: "gearshape.fill")
                    }
                    .tag(settingsTabIndex)
            }
        }
    }

    @ViewBuilder
    private var splitscreenWithTabBar: some View {
        if showingSplitContent {
            SplitscreenView(printers: printers, allServices: allServices, currentPage: $splitCurrentPage)
                .safeAreaInset(edge: .bottom, spacing: 0) { splitTabBar }
        } else if showNFCTab && selectedTab == nfcTabIndex {
            NFCView()
                .safeAreaInset(edge: .bottom, spacing: 0) { splitTabBar }
        } else {
            SettingsView(settings: settings, onSave: onSettingsSave)
                .environmentObject(printerServices)
                .safeAreaInset(edge: .bottom, spacing: 0) { splitTabBar }
        }
    }

    private var splitTabBar: some View {
        VStack(spacing: 0) {
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(printers.enumerated()), id: \.0) { idx, pair in
                        Button {
                            selectedTab = idx
                            splitCurrentPage = idx
                        } label: {
                            let isVisible = visibleSplitRange.contains(idx)
                            VStack(spacing: 2) {
                                Image(systemName: pair.0.type.icon)
                                    .font(.system(size: 21))
                                Text(pair.0.name)
                                    .font(.caption2)
                                    .lineLimit(1)
                                Capsule()
                                    .fill(isVisible ? Color.accentColor : Color.clear)
                                    .overlay(Capsule().stroke(Color.secondary.opacity(0.4), lineWidth: 0.5))
                                    .frame(width: 22, height: 4)
                            }
                            .foregroundStyle(isVisible ? Color.accentColor : Color.secondary)
                            .frame(minWidth: 60, maxWidth: 90)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                    if showNFCTab {
                        tabButton(icon: "wave.3.right", label: "NFC", tag: nfcTabIndex)
                    }
                    tabButton(
                        icon: "gearshape.fill",
                        label: lz(en: "Settings", de: "Einstellungen", fr: "Paramètres", es: "Ajustes"),
                        tag: settingsTabIndex
                    )
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 58)
            .background(.bar)
        }
    }

    @ViewBuilder
    var contentView: some View {
        if selectedTab < printers.count {
            let pair = printers[selectedTab]
            PrintControlView(
                printerService: pair.1,
                printerID: pair.0.id.uuidString,
                themeColorKey: pair.0.themeColor,
                allServices: allServices
            )
        } else if showNFCTab && selectedTab == nfcTabIndex {
            NFCView()
        } else {
            SettingsView(settings: settings, onSave: onSettingsSave)
                .environmentObject(printerServices)
        }
    }

    var tabBar: some View {
        VStack(spacing: 0) {
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(printers.enumerated()), id: \.0) { idx, pair in
                        tabButton(icon: pair.0.type.icon, label: pair.0.name, tag: idx)
                    }
                    if showNFCTab {
                        tabButton(icon: "wave.3.right", label: "NFC", tag: nfcTabIndex)
                    }
                    tabButton(
                        icon: "gearshape.fill",
                        label: lz(en: "Settings", de: "Einstellungen", fr: "Paramètres", es: "Ajustes"),
                        tag: settingsTabIndex
                    )
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 49)
            .background(.bar)
        }
    }

    @ViewBuilder
    func tabButton(icon: String, label: String, tag: Int) -> some View {
        Button { selectedTab = tag } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 21))
                Text(label)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(selectedTab == tag ? Color.accentColor : Color.secondary)
            .frame(minWidth: 60, maxWidth: 90)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

}

private struct SplitScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Splitscreen View
struct SplitscreenView: View {
    let printers: [(PrinterConfig, PrinterService)]
    let allServices: [PrinterService]
    @Binding var currentPage: Int
    @AppStorage("current_splitscreen_count") private var storedSplitscreenCount: Int = 1

    var body: some View {
        GeometryReader { geo in
            // Landscape: 3 printers side by side, portrait: 2
            let isLandscape = geo.size.width > geo.size.height
            let maxVisible = isLandscape ? 3 : 2
            let visibleCount = min(printers.count, maxVisible)
            let printerWidth = geo.size.width / CGFloat(visibleCount)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(printers.enumerated()), id: \.0) { idx, pair in
                            PrintControlView(
                                printerService: pair.1,
                                printerID: pair.0.id.uuidString,
                                themeColorKey: pair.0.themeColor,
                                allServices: allServices
                            )
                            .frame(width: printerWidth)
                            .overlay(alignment: .leading) {
                                if idx > 0 {
                                    Rectangle()
                                        .fill(Color(UIColor.separator))
                                        .frame(width: 0.5)
                                }
                            }
                            .id(idx)
                        }
                    }
                    .background(
                        GeometryReader { contentGeo in
                            Color.clear.preference(
                                key: SplitScrollOffsetKey.self,
                                value: printerWidth > 0 ? contentGeo.frame(in: .named("splitHScroll")).minX / printerWidth : 0
                            )
                        }
                    )
                    .scrollTargetLayout()
                    .frame(height: geo.size.height)
                }
                .coordinateSpace(name: "splitHScroll")
                .scrollTargetBehavior(.viewAligned)
                .scrollDisabled(printers.count <= visibleCount)
                .onPreferenceChange(SplitScrollOffsetKey.self) { normalized in
                    let page = max(0, Int(round(-normalized)))
                    if page != currentPage { currentPage = page }
                }
                .onAppear { storedSplitscreenCount = visibleCount }
                .onChange(of: visibleCount) { _, new in storedSplitscreenCount = new }
                .onChange(of: currentPage) { _, target in
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(target, anchor: .leading)
                    }
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }
}

// MARK: - ContentView
struct ContentView: View {
    @StateObject private var settings = SettingsStore()
    @StateObject private var printerServices = PrinterServicesManager()
    @StateObject private var langStore = LanguageStore()
    @AppStorage("show_nfc_tab") private var showNFCTab: Bool = true
    @AppStorage("printers_as_tabs") private var printersAsTabs: Bool = false
    @AppStorage("splitscreen_mode") private var splitscreenMode: Bool = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("has_shown_firmware_notice") private var hasShownFirmwareNotice: Bool = false
    @AppStorage("has_selected_language") private var hasSelectedLanguage: Bool = false
    @AppStorage("has_accepted_disclaimer") private var hasAcceptedDisclaimer: Bool = false
    @State private var showLanguagePicker: Bool = false
    @State private var showFirmwareNotice: Bool = false
    @State private var showDisclaimer: Bool = false
    @State private var currentPrinterPage: Int = 0
    @State private var splitCurrentPage: Int = 0

    private var visiblePrinters: [(PrinterConfig, PrinterService)] {
        Array(zip(settings.printers, printerServices.services)).filter { $0.0.isVisible }
    }

    private var isSplitscreenActive: Bool {
        splitscreenMode && horizontalSizeClass == .regular && visiblePrinters.count >= 2
    }

    var body: some View {
        Group {
            if !settings.hasCompletedOnboarding {
                OnboardingView(settings: settings) {
                    printerServices.update(from: settings)
                }
            } else {
                let currentConfig = visiblePrinters[safe: currentPrinterPage]?.0
                Group {
                    if printersAsTabs {
                        ScrollablePrinterTabView(
                            printers: visiblePrinters,
                            allServices: printerServices.services,
                            showNFCTab: showNFCTab,
                            onSettingsSave: { printerServices.update(from: settings) }
                        )
                    } else {
                        TabView {
                            if isSplitscreenActive {
                                SplitscreenView(
                                    printers: visiblePrinters,
                                    allServices: printerServices.services,
                                    currentPage: $splitCurrentPage
                                )
                                .tabItem {
                                    Label(lz(en: "Split Screen", de: "Splitscreen", fr: "Écran partagé", es: "Pantalla dividida"),
                                          systemImage: "rectangle.split.2x1.fill")
                                }
                            } else {
                                PrinterPagerView(
                                    printers: visiblePrinters,
                                    allServices: printerServices.services,
                                    currentPage: $currentPrinterPage
                                )
                                .tabItem {
                                    Label(currentConfig?.name ?? lz(en: "Printers", de: "Drucker", fr: "Imprimantes", es: "Impresoras"),
                                          systemImage: currentConfig?.type.icon ?? "printer.fill")
                                }
                            }
                            if showNFCTab {
                                NFCView()
                                    .tabItem { Label("NFC", systemImage: "wave.3.right") }
                            }
                            SettingsView(settings: settings) {
                                printerServices.update(from: settings)
                            }
                            .environmentObject(printerServices)
                            .tabItem { Label(lz(en: "Settings", de: "Einstellungen", fr: "Paramètres", es: "Ajustes"), systemImage: "gearshape.fill") }
                        }
                    }
                }
                .onAppear { printerServices.update(from: settings) }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    printerServices.services.forEach { $0.writeWidgetData() }
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
        }
        .environmentObject(langStore)
        .environmentObject(settings)
        .environmentObject(printerServices)
        .onAppear {
            if !hasSelectedLanguage {
                showLanguagePicker = true
            } else if !hasAcceptedDisclaimer {
                showDisclaimer = true
            } else if !hasShownFirmwareNotice {
                showFirmwareNotice = true
            }
        }
        .sheet(isPresented: $showLanguagePicker) {
            LanguagePickerView(langStore: langStore) {
                hasSelectedLanguage = true
                showLanguagePicker = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    if !hasAcceptedDisclaimer {
                        showDisclaimer = true
                    } else if !hasShownFirmwareNotice {
                        showFirmwareNotice = true
                    }
                }
            }
        }
        .sheet(isPresented: $showDisclaimer) {
            DisclaimerView {
                hasAcceptedDisclaimer = true
                showDisclaimer = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    if !hasShownFirmwareNotice {
                        showFirmwareNotice = true
                    }
                }
            }
        }
        .sheet(isPresented: $showFirmwareNotice) {
            FirmwareNoticeView {
                hasShownFirmwareNotice = true
                showFirmwareNotice = false
            }
        }
    }
}

// MARK: - Disclaimer
struct DisclaimerView: View {
    let onAccept: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 5)
                .padding(.top, 12)

            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.12))
                                .frame(width: 80, height: 80)
                            Image(systemName: "shield.lefthalf.filled")
                                .font(.system(size: 36))
                                .foregroundColor(.blue)
                        }
                        .padding(.top, 24)

                        Text(lz(en: "Legal Notice", de: "Rechtlicher Hinweis", fr: "Mentions légales", es: "Aviso legal"))
                            .font(.title2).bold()
                            .multilineTextAlignment(.center)

                        Text(lz(
                            en: "Please read and accept the following before using PaxxMaker.",
                            de: "Bitte lies und akzeptiere folgende Hinweise vor der Nutzung von PaxxMaker.",
                            fr: "Veuillez lire et accepter les mentions suivantes avant d'utiliser PaxxMaker.",
                            es: "Lee y acepta los siguientes avisos antes de usar PaxxMaker."
                        ))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        disclaimerRow(
                            icon: "person.slash.fill", color: .blue,
                            title: lz(en: "Independent App", de: "Unabhängige App", fr: "Application indépendante", es: "Aplicación independiente"),
                            text: lz(
                                en: "PaxxMaker is an independent hobby project and is not affiliated with, endorsed by, or officially connected to Snapmaker in any way.",
                                de: "PaxxMaker ist ein unabhängiges Hobbyprojekt und steht in keiner Verbindung zu Snapmaker. Die App ist weder von Snapmaker autorisiert noch wird sie von Snapmaker unterstützt.",
                                fr: "PaxxMaker est un projet hobby indépendant, non affilié, approuvé ou connecté officiellement à Snapmaker de quelque manière que ce soit.",
                                es: "PaxxMaker es un proyecto hobby independiente y no está afiliado, respaldado ni conectado oficialmente con Snapmaker de ninguna manera."
                            )
                        )

                        disclaimerRow(
                            icon: "building.2.fill", color: .purple,
                            title: lz(en: "Trademark Notice", de: "Markenhinweis", fr: "Avis de marque", es: "Aviso de marca registrada"),
                            text: lz(
                                en: "\"Snapmaker\" and related names are trademarks of Snapmaker Inc. These names are used solely to describe technical compatibility and do not imply any affiliation.",
                                de: "\"Snapmaker\" und damit verbundene Namen sind Marken der Snapmaker Inc. Die Nennung dient ausschließlich der Beschreibung der technischen Kompatibilität und impliziert keinerlei Verbindung.",
                                fr: "« Snapmaker » et les noms associés sont des marques de Snapmaker Inc. Ces noms sont utilisés uniquement pour décrire la compatibilité technique.",
                                es: "\"Snapmaker\" y los nombres relacionados son marcas comerciales de Snapmaker Inc. Estos nombres se usan únicamente para describir la compatibilidad técnica."
                            )
                        )

                        disclaimerRow(
                            icon: "flag.2.crossed.fill", color: .green,
                            title: lz(en: "No Competition", de: "Kein Wettbewerb", fr: "Pas de concurrence", es: "Sin competencia"),
                            text: lz(
                                en: "PaxxMaker does not compete with Snapmaker's official apps or services. It is a community tool built on the open Klipper/Moonraker API.",
                                de: "PaxxMaker steht in keinem Wettbewerb zu offiziellen Snapmaker-Apps oder -Diensten. Die App ist ein Community-Tool auf Basis der offenen Klipper/Moonraker-API.",
                                fr: "PaxxMaker ne concurrence pas les applications ou services officiels de Snapmaker. C'est un outil communautaire basé sur l'API ouverte Klipper/Moonraker.",
                                es: "PaxxMaker no compite con las aplicaciones o servicios oficiales de Snapmaker. Es una herramienta comunitaria basada en la API abierta Klipper/Moonraker."
                            )
                        )

                        disclaimerRow(
                            icon: "exclamationmark.shield.fill", color: .orange,
                            title: lz(en: "No Liability", de: "Haftungsausschluss", fr: "Absence de responsabilité", es: "Sin responsabilidad"),
                            text: lz(
                                en: "Use of this app is at your own risk. The developer assumes no liability for damages, data loss, hardware damage, or any other issues arising from use of this app.",
                                de: "Die Nutzung dieser App erfolgt auf eigene Gefahr. Der Entwickler übernimmt keine Haftung für Schäden, Datenverluste, Hardwareschäden oder sonstige Probleme, die durch die Nutzung entstehen.",
                                fr: "L'utilisation de cette application se fait à vos propres risques. Le développeur décline toute responsabilité pour les dommages, pertes de données ou autres problèmes.",
                                es: "El uso de esta aplicación es bajo tu propio riesgo. El desarrollador no asume responsabilidad por daños, pérdida de datos u otros problemas derivados del uso."
                            )
                        )
                    }
                    .padding(.horizontal, 4)

                    Button(action: onAccept) {
                        Text(lz(en: "Accept & Continue", de: "Akzeptieren & Weiter", fr: "Accepter & Continuer", es: "Aceptar & Continuar"))
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(14)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 32)
                }
                .padding(.horizontal, 24)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(true)
    }

    @ViewBuilder
    func disclaimerRow(icon: String, color: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(color.opacity(0.12)).frame(width: 40, height: 40)
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundColor(color)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline).bold()
                Text(text).font(.subheadline).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
    }
}

// MARK: - Language Picker
struct LanguagePickerView: View {
    @ObservedObject var langStore: LanguageStore
    let onContinue: () -> Void
    @State private var selected: String

    init(langStore: LanguageStore, onContinue: @escaping () -> Void) {
        self.langStore = langStore
        self.onContinue = onContinue
        self._selected = State(initialValue: langStore.current)
    }

    let languages: [(key: String, flag: String, native: String)] = [
        ("de", "🇩🇪", "Deutsch"),
        ("en", "🇬🇧", "English"),
        ("fr", "🇫🇷", "Français"),
        ("es", "🇪🇸", "Español"),
    ]

    var continueLabel: String {
        switch selected {
        case "de": return "Weiter"
        case "fr": return "Continuer"
        case "es": return "Continuar"
        default:   return "Continue"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                Image(systemName: "globe")
                    .font(.system(size: 48))
                    .foregroundColor(.blue)
                    .padding(22)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(Circle())
                    .padding(.top, 52)

                Text("Sprache / Language")
                    .font(.title2).bold()

                Text("Bitte wähle deine Sprache\nPlease select your language")
                    .font(.subheadline).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 36)

            VStack(spacing: 12) {
                ForEach(languages, id: \.key) { lang in
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) { selected = lang.key }
                        langStore.current = lang.key
                    }) {
                        HStack(spacing: 16) {
                            Text(lang.flag).font(.system(size: 34))
                            Text(lang.native).font(.system(size: 17, weight: .semibold))
                            Spacer()
                            if selected == lang.key {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue).font(.title3)
                            }
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(selected == lang.key ? Color.blue.opacity(0.09) : Color(.secondarySystemBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(selected == lang.key ? Color.blue.opacity(0.45) : Color.clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            Button(action: onContinue) {
                Text(continueLabel)
                    .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Color.blue).cornerRadius(14)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .interactiveDismissDisabled(true)
    }
}

// MARK: - Firmware Notice
struct FirmwareNoticeView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 5)
                .padding(.top, 12)

            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color.orange.opacity(0.12))
                                .frame(width: 80, height: 80)
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 36))
                                .foregroundColor(.orange)
                        }
                        .padding(.top, 24)

                        Text(lz(en: "Important Notice", de: "Wichtiger Hinweis", fr: "Avis important", es: "Aviso importante"))
                            .font(.title2).bold()
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        noticeRow(
                            icon: "cpu.fill", color: .orange,
                            title: lz(en: "Custom Firmware required", de: "Custom Firmware erforderlich", fr: "Firmware personnalisé requis", es: "Firmware personalizado requerido"),
                            text: lz(
                                en: "This app is designed exclusively for the Snapmaker U1 with the paxx12 custom firmware. Without this firmware the app will not work correctly or at all.",
                                de: "Diese App ist ausschließlich für den Snapmaker U1 mit der paxx12 Custom Firmware entwickelt. Ohne diese Firmware funktioniert die App nicht korrekt oder gar nicht.",
                                fr: "Cette application est conçue exclusivement pour le Snapmaker U1 avec le firmware personnalisé paxx12. Sans ce firmware, l'application ne fonctionnera pas correctement.",
                                es: "Esta aplicación está diseñada exclusivamente para el Snapmaker U1 con el firmware personalizado paxx12. Sin este firmware, la aplicación no funcionará correctamente."
                            )
                        )

                        noticeRow(
                            icon: "exclamationmark.shield.fill", color: .red,
                            title: lz(en: "Use at your own risk", de: "Nutzung auf eigene Gefahr", fr: "Utilisation à vos risques", es: "Uso bajo su propio riesgo"),
                            text: lz(
                                en: "Custom firmware carries risks. Please inform yourself thoroughly before installation. I assume no liability for any damages or issues.",
                                de: "Custom Firmware birgt Risiken. Bitte informiere dich vor der Installation gründlich. Ich übernehme keine Haftung für Schäden oder Probleme.",
                                fr: "Un firmware personnalisé comporte des risques. Veuillez vous informer avant l'installation. Je décline toute responsabilité pour les dommages.",
                                es: "El firmware personalizado conlleva riesgos. Infórmese antes de la instalación. No asumo responsabilidad por daños o problemas."
                            )
                        )

                        noticeRow(
                            icon: "arrow.triangle.branch", color: .blue,
                            title: lz(en: "Installation", de: "Installation", fr: "Installation", es: "Instalación"),
                            text: lz(
                                en: "Installation instructions and the latest firmware version can be found on GitHub.",
                                de: "Installationsanleitung und die neueste Firmware-Version findest du auf GitHub.",
                                fr: "Les instructions d'installation et la dernière version du firmware se trouvent sur GitHub.",
                                es: "Las instrucciones de instalación y la última versión del firmware se encuentran en GitHub."
                            )
                        )
                    }
                    .padding(.horizontal, 4)

                    VStack(spacing: 12) {
                        Button(action: {
                            if let url = URL(string: "https://github.com/paxx12") {
                                UIApplication.shared.open(url)
                            }
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.right.square")
                                Text("GitHub")
                            }
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(red: 0.1, green: 0.1, blue: 0.1))
                            .cornerRadius(14)
                        }
                        .buttonStyle(.plain)

                        Button(action: onDismiss) {
                            Text(lz(en: "Understood", de: "Verstanden", fr: "Compris", es: "Entendido"))
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.orange)
                                .foregroundColor(.white)
                                .cornerRadius(14)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.bottom, 8)

                    Button(action: {
                        if let url = URL(string: "https://github.com/paxx12") {
                            UIApplication.shared.open(url)
                        }
                    }) {
                        Text(lz(en: "Thanks for the great custom firmware", de: "Danke für die tolle custom firmware", fr: "Merci pour le super firmware personnalisé", es: "Gracias por el gran firmware personalizado"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 24)
                }
                .padding(.horizontal, 24)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(true)
    }

    @ViewBuilder
    func noticeRow(icon: String, color: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(color.opacity(0.12)).frame(width: 40, height: 40)
                Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundColor(color)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline).bold()
                Text(text).font(.subheadline).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
    }
}

// MARK: - OpenSpool NFC

struct OpenSpoolData: Equatable, Sendable {
    var version: String = "1.0"
    var protocol_: String = "openspool"
    var colorHex: String = "888888"
    var type: String = "PLA"
    var subtype: String = ""
    var minTemp: Int = 200
    var maxTemp: Int = 230
    var bedMinTemp: Int = 0
    var bedMaxTemp: Int = 0
    var brand: String = "Generic"
    var diameter: Double = 1.75
    var weight: Int = 0

    enum CodingKeys: String, CodingKey {
        case version, type, subtype, brand, diameter, weight
        case protocol_ = "protocol"
        case colorHex = "color_hex"
        case minTemp = "min_temp"
        case maxTemp = "max_temp"
        case bedMinTemp = "bed_min_temp"
        case bedMaxTemp = "bed_max_temp"
    }

    var normalizedColorHex: String {
        colorHex.replacingOccurrences(of: "#", with: "").uppercased()
    }
}

extension OpenSpoolData: Codable {
    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version    = try c.decodeIfPresent(String.self, forKey: .version)    ?? "1.0"
        protocol_  = try c.decodeIfPresent(String.self, forKey: .protocol_)  ?? "openspool"
        type       = try c.decodeIfPresent(String.self, forKey: .type)       ?? "PLA"
        subtype    = try c.decodeIfPresent(String.self, forKey: .subtype)    ?? ""
        brand      = try c.decodeIfPresent(String.self, forKey: .brand)      ?? "Generic"
        diameter   = try c.decodeIfPresent(Double.self, forKey: .diameter)   ?? 1.75
        weight     = try c.decodeIfPresent(Int.self,    forKey: .weight)     ?? 0

        let rawHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "888888"
        colorHex = rawHex.replacingOccurrences(of: "#", with: "")

        if let v = try? c.decodeIfPresent(Int.self, forKey: .minTemp) {
            minTemp = v
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .minTemp), let v = Int(s) {
            minTemp = v
        } else { minTemp = 200 }

        if let v = try? c.decodeIfPresent(Int.self, forKey: .maxTemp) {
            maxTemp = v
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .maxTemp), let v = Int(s) {
            maxTemp = v
        } else { maxTemp = 230 }

        if let v = try? c.decodeIfPresent(Int.self, forKey: .bedMinTemp) {
            bedMinTemp = v
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .bedMinTemp), let v = Int(s) {
            bedMinTemp = v
        } else { bedMinTemp = 0 }

        if let v = try? c.decodeIfPresent(Int.self, forKey: .bedMaxTemp) {
            bedMaxTemp = v
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .bedMaxTemp), let v = Int(s) {
            bedMaxTemp = v
        } else { bedMaxTemp = 0 }
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version,   forKey: .version)
        try c.encode(protocol_, forKey: .protocol_)
        try c.encode(colorHex,  forKey: .colorHex)
        try c.encode(type,      forKey: .type)
        if !subtype.isEmpty { try c.encode(subtype, forKey: .subtype) }
        try c.encode(brand,     forKey: .brand)
        try c.encode(minTemp,   forKey: .minTemp)
        try c.encode(maxTemp,   forKey: .maxTemp)
        if bedMinTemp > 0 { try c.encode(bedMinTemp, forKey: .bedMinTemp) }
        if bedMaxTemp > 0 { try c.encode(bedMaxTemp, forKey: .bedMaxTemp) }
        try c.encode(diameter,  forKey: .diameter)
        if weight > 0 { try c.encode(weight, forKey: .weight) }
    }
}


@available(iOS 15.0, *)
class OpenSpoolNFCManager: NSObject, ObservableObject, NFCNDEFReaderSessionDelegate {
    @Published var lastRead: OpenSpoolData? = nil
    @Published var isScanning = false
    @Published var statusMessage = ""
    @Published var showError = false

    private var session: NFCNDEFReaderSession?
    var writeData: OpenSpoolData?

    func read() {
        guard NFCNDEFReaderSession.readingAvailable else {
            statusMessage = lz(en: "NFC not available on this device.", de: "NFC auf diesem Gerät nicht verfügbar.", fr: "NFC non disponible sur cet appareil.", es: "NFC no disponible en este dispositivo.")
            showError = true; return
        }
        writeData = nil
        session = NFCNDEFReaderSession(delegate: self, queue: .main, invalidateAfterFirstRead: true)
        session?.alertMessage = lz(en: "Hold iPhone near the filament spool tag.", de: "iPhone an die Filament-Spule halten.", fr: "Approchez l'iPhone du tag de la bobine.", es: "Acerque el iPhone a la etiqueta del carrete.")
        session?.begin()
        isScanning = true
    }

    func write(data: OpenSpoolData) {
        guard NFCNDEFReaderSession.readingAvailable else {
            statusMessage = lz(en: "NFC not available on this device.", de: "NFC auf diesem Gerät nicht verfügbar.", fr: "NFC non disponible sur cet appareil.", es: "NFC no disponible en este dispositivo.")
            showError = true; return
        }
        writeData = data
        session = NFCNDEFReaderSession(delegate: self, queue: .main, invalidateAfterFirstRead: false)
        session?.alertMessage = lz(en: "Hold iPhone near an empty NFC tag to write.", de: "iPhone an ein leeres NFC-Tag halten.", fr: "Approchez l'iPhone d'un tag NFC vide.", es: "Acerque el iPhone a una etiqueta NFC vacía.")
        session?.begin()
        isScanning = true
    }

    func readerSessionDidBecomeActive(_ session: NFCNDEFReaderSession) {}

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        DispatchQueue.main.async { self.isScanning = false }
    }

    private func parseOpenSpool(from payload: Data) -> OpenSpoolData? {
        // MIME record: payload is raw JSON
        if let d = try? JSONDecoder().decode(OpenSpoolData.self, from: payload),
           d.protocol_ == "openspool" { return d }
        // Text record (legacy): skip language prefix byte + lang code
        if payload.count > 3 {
            let langLen = Int(payload[0] & 0x3F)
            let jsonData = payload.dropFirst(1 + langLen)
            if let d = try? JSONDecoder().decode(OpenSpoolData.self, from: jsonData),
               d.protocol_ == "openspool" { return d }
        }
        // Fallback: try entire string
        if let text = String(data: payload, encoding: .utf8),
           let d = try? JSONDecoder().decode(OpenSpoolData.self, from: Data(text.utf8)),
           d.protocol_ == "openspool" { return d }
        return nil
    }

    func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        for message in messages {
            for record in message.records {
                if let d = parseOpenSpool(from: record.payload) {
                    DispatchQueue.main.async { self.lastRead = d; self.isScanning = false }
                    return
                }
            }
        }
        DispatchQueue.main.async { self.isScanning = false }
    }

    func readerSession(_ session: NFCNDEFReaderSession, didDetect tags: [NFCNDEFTag]) {
        guard let tag = tags.first else { session.invalidate(); return }

        // Read mode
        if writeData == nil {
            session.connect(to: tag) { error in
                guard error == nil else { session.invalidate(errorMessage: lz(en: "Connection failed.", de: "Verbindung fehlgeschlagen.", fr: "Connexion échouée.", es: "Conexión fallida.")); return }
                tag.readNDEF { message, error in
                    guard let message = message else {
                        session.invalidate(errorMessage: error?.localizedDescription ?? lz(en: "Read failed.", de: "Lesen fehlgeschlagen.", fr: "Lecture échouée.", es: "Lectura fallida."))
                        return
                    }
                    for record in message.records {
                        if let d = self.parseOpenSpool(from: record.payload) {
                            session.alertMessage = lz(en: "Tag read successfully!", de: "Tag erfolgreich gelesen!", fr: "Tag lu avec succès !", es: "¡Tag leído con éxito!")
                            session.invalidate()
                            DispatchQueue.main.async { self.lastRead = d; self.isScanning = false }
                            return
                        }
                    }
                    session.invalidate(errorMessage: lz(en: "No OpenSpool data found.", de: "Keine OpenSpool-Daten gefunden.", fr: "Aucune donnée OpenSpool trouvée.", es: "No se encontraron datos OpenSpool."))
                    DispatchQueue.main.async { self.isScanning = false }
                }
            }
            return
        }

        // Write mode
        guard let data = writeData else { session.invalidate(); return }
        session.connect(to: tag) { error in
            guard error == nil else { session.invalidate(errorMessage: lz(en: "Connection failed.", de: "Verbindung fehlgeschlagen.", fr: "Connexion échouée.", es: "Conexión fallida.")); return }
            let dataCopy = data
            guard let jsonData = try? JSONEncoder().encode(dataCopy) else {
                session.invalidate(errorMessage: lz(en: "Encoding failed.", de: "Kodierung fehlgeschlagen.", fr: "Encodage échoué.", es: "Codificación fallida.")); return
            }
            // OpenSpool standard: MIME type application/json
            let payload = NFCNDEFPayload(
                format: .media,
                type: "application/json".data(using: .utf8)!,
                identifier: Data(),
                payload: jsonData
            )
            let message = NFCNDEFMessage(records: [payload])
            tag.writeNDEF(message) { error in
                if let error = error {
                    session.invalidate(errorMessage: error.localizedDescription)
                } else {
                    session.alertMessage = lz(en: "Tag written successfully!", de: "Tag erfolgreich beschrieben!", fr: "Tag écrit avec succès !", es: "¡Tag escrito con éxito!")
                    session.invalidate()
                    DispatchQueue.main.async { self.isScanning = false; self.lastRead = data }
                }
            }
        }
    }
}

// MARK: - NFC Spool Graphic
struct SpoolGraphic: View {
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.15))
                .frame(width: 180, height: 180)
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: 3)
                .frame(width: 180, height: 180)
            // Outer ring segments
            ForEach(0..<4, id: \.self) { i in
                SpoolSegment(color: color)
                    .rotationEffect(.degrees(Double(i) * 90))
            }
            // Inner hub
            Circle()
                .fill(color)
                .frame(width: 28, height: 28)
            Circle()
                .stroke(Color.white.opacity(0.3), lineWidth: 2)
                .frame(width: 28, height: 28)
            // Center hole
            Circle()
                .fill(Color(.systemBackground))
                .frame(width: 12, height: 12)
        }
        .frame(width: 200, height: 200)
    }
}

struct SpoolSegment: View {
    let color: Color

    var body: some View {
        ZStack {
            // Main petal shape
            Capsule()
                .fill(color)
                .frame(width: 50, height: 120)
                .offset(y: -15)
            // Inner lines
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(color.opacity(0.6))
                    .frame(width: 36 - CGFloat(i) * 8, height: 6)
                    .offset(y: -55 + CGFloat(i) * 18)
            }
        }
        .mask(
            Circle().frame(width: 160, height: 160)
                .overlay(Circle().fill(Color.black).frame(width: 50, height: 50).blendMode(.destinationOut))
        )
    }
}

// MARK: - NFC Color Names
struct NFCColorOption: Identifiable {
    let id: String
    let nameEN: String
    let nameDE: String
    let nameFR: String
    let nameES: String
    let hex: String
    var color: Color { Color(hex: hex) ?? .gray }
    var name: String { lz(en: nameEN, de: nameDE, fr: nameFR, es: nameES) }

    static let all: [NFCColorOption] = [
        NFCColorOption(id: "red",      nameEN: "Red",      nameDE: "Rot",      nameFR: "Rouge",    nameES: "Rojo",      hex: "FF0000"),
        NFCColorOption(id: "orange",   nameEN: "Orange",   nameDE: "Orange",   nameFR: "Orange",   nameES: "Naranja",   hex: "FF8800"),
        NFCColorOption(id: "yellow",   nameEN: "Yellow",   nameDE: "Gelb",     nameFR: "Jaune",    nameES: "Amarillo",  hex: "FFD700"),
        NFCColorOption(id: "green",    nameEN: "Green",    nameDE: "Grün",     nameFR: "Vert",     nameES: "Verde",     hex: "00AA00"),
        NFCColorOption(id: "cyan",     nameEN: "Cyan",     nameDE: "Cyan",     nameFR: "Cyan",     nameES: "Cian",      hex: "00CCCC"),
        NFCColorOption(id: "blue",     nameEN: "Blue",     nameDE: "Blau",     nameFR: "Bleu",     nameES: "Azul",      hex: "0066FF"),
        NFCColorOption(id: "purple",   nameEN: "Purple",   nameDE: "Lila",     nameFR: "Violet",   nameES: "Púrpura",   hex: "8800CC"),
        NFCColorOption(id: "magenta",  nameEN: "Magenta",  nameDE: "Magenta",  nameFR: "Magenta",  nameES: "Magenta",   hex: "FF00FF"),
        NFCColorOption(id: "pink",     nameEN: "Pink",     nameDE: "Rosa",     nameFR: "Rose",     nameES: "Rosa",      hex: "FF69B4"),
        NFCColorOption(id: "white",    nameEN: "White",    nameDE: "Weiß",     nameFR: "Blanc",    nameES: "Blanco",    hex: "FFFFFF"),
        NFCColorOption(id: "black",    nameEN: "Black",    nameDE: "Schwarz",  nameFR: "Noir",     nameES: "Negro",     hex: "222222"),
        NFCColorOption(id: "gray",     nameEN: "Gray",     nameDE: "Grau",     nameFR: "Gris",     nameES: "Gris",      hex: "888888"),
        NFCColorOption(id: "brown",    nameEN: "Brown",    nameDE: "Braun",    nameFR: "Marron",   nameES: "Marrón",    hex: "8B4513"),
        NFCColorOption(id: "gold",     nameEN: "Gold",     nameDE: "Gold",     nameFR: "Or",       nameES: "Dorado",    hex: "DAA520"),
        NFCColorOption(id: "silver",   nameEN: "Silver",   nameDE: "Silber",   nameFR: "Argent",   nameES: "Plata",     hex: "C0C0C0"),
    ]
}

// MARK: - NFC View
@available(iOS 15.0, *)
struct NFCView: View {
    @StateObject private var nfc = OpenSpoolNFCManager()
    @State private var spoolData = OpenSpoolData()
    @State private var selectedColorID = "gray"
    @State private var showCustomColor = false
    @State private var customColor = Color.gray
    @State private var showColorSheet = false

    let materials = ["PLA", "PLA+", "PETG", "ABS", "ASA", "TPU", "PA", "PC", "PVA", "HIPS"]
    let subtypes = ["", "Basic", "Matte", "Silk", "HF", "Support", "SnapSpeed", "95A", "95A HF"]
    let brandSuggestions = ["Generic", "Snapmaker", "Bambu", "Prusa", "eSun", "Overture", "PolyTerra", "PolyLite", "Sunlu", "Eryone"]
    let tempRange = Array(stride(from: 150, through: 350, by: 5))
    let bedTempRange = Array(stride(from: 30, through: 120, by: 5))

    private var spoolColor: Color {
        if showCustomColor {
            return customColor
        }
        return NFCColorOption.all.first { $0.id == selectedColorID }?.color ?? .gray
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        NavigationStack {
            Group {
                if horizontalSizeClass == .regular {
                    // iPad: two-column layout
                    HStack(spacing: 0) {
                        // Left: spool graphic + read/write buttons
                        VStack(spacing: 28) {
                            Spacer()
                            SpoolGraphic(color: spoolColor)
                                .frame(maxWidth: 260)
                                .padding(.horizontal, 24)
                                .animation(.easeInOut(duration: 0.3), value: selectedColorID)
                                .animation(.easeInOut(duration: 0.3), value: customColor)
                            if !nfc.statusMessage.isEmpty {
                                Text(nfc.statusMessage)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                            }
                            VStack(spacing: 10) {
                                Button(action: { nfc.read() }) {
                                    HStack(spacing: 8) {
                                        if nfc.isScanning && nfc.writeData == nil { ProgressView().tint(.primary) }
                                        else { Image(systemName: "wave.3.left") }
                                        Text(lz(en: "Read Tag", de: "Tag lesen", fr: "Lire tag", es: "Leer tag")).fontWeight(.semibold)
                                    }
                                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                                    .background(Color(.secondarySystemBackground))
                                    .foregroundColor(.primary).cornerRadius(12)
                                }
                                .disabled(nfc.isScanning)
                                Button(action: { nfc.write(data: spoolData) }) {
                                    HStack(spacing: 8) {
                                        if nfc.isScanning && nfc.writeData != nil { ProgressView().tint(.primary) }
                                        else { Image(systemName: "wave.3.right") }
                                        Text(lz(en: "Write Tag", de: "Tag schreiben", fr: "Écrire tag", es: "Escribir tag")).fontWeight(.semibold)
                                    }
                                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                                    .background(Color.accentColor)
                                    .foregroundColor(.white).cornerRadius(12)
                                }
                                .disabled(nfc.isScanning)
                            }
                            .padding(.horizontal, 24)
                            Spacer()
                        }
                        .frame(width: 300)
                        .background(Color(.secondarySystemGroupedBackground))

                        Divider()

                        // Right: form fields
                        ScrollView {
                            VStack(spacing: 20) {
                                nfcFormFields
                                // Info
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "info.circle").foregroundColor(.secondary)
                                    Text(lz(
                                        en: "Compatible tags: NTAG215, NTAG216. Hold your device near the spool tag to read or write.",
                                        de: "Kompatible Tags: NTAG215, NTAG216. Gerät an das Spulen-Tag halten.",
                                        fr: "Tags compatibles : NTAG215, NTAG216. Approchez l'appareil du tag.",
                                        es: "Tags compatibles: NTAG215, NTAG216. Acerque el dispositivo al tag."
                                    ))
                                    .font(.caption).foregroundColor(.secondary)
                                }
                                .padding(12)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
                                Spacer(minLength: 20)
                            }
                            .padding(24)
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    // iPhone: original vertical layout
                    ScrollView {
                        VStack(spacing: 24) {
                            SpoolGraphic(color: spoolColor)
                                .padding(.top, 16)
                                .animation(.easeInOut(duration: 0.3), value: selectedColorID)
                                .animation(.easeInOut(duration: 0.3), value: customColor)
                            VStack(spacing: 20) {
                        // Color
                        VStack(alignment: .leading, spacing: 6) {
                            Text(lz(en: "Color", de: "Farbe", fr: "Couleur", es: "Color"))
                                .font(.caption).foregroundColor(.secondary)
                            Button(action: { showColorSheet = true }) {
                                HStack {
                                    Circle().fill(spoolColor).frame(width: 20, height: 20)
                                        .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                                    Text(showCustomColor ? "#\(spoolData.colorHex.uppercased())" :
                                            (NFCColorOption.all.first { $0.id == selectedColorID }?.name ?? ""))
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.down").foregroundColor(.secondary).font(.caption)
                                }
                                .padding(12)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(10)
                            }
                            .buttonStyle(.plain)
                            if showCustomColor {
                                ColorPicker(lz(en: "Pick color", de: "Farbe wählen", fr: "Choisir couleur", es: "Elegir color"), selection: $customColor, supportsOpacity: false)
                                    .onChange(of: customColor) { spoolData.colorHex = customColor.hexString }
                                    .padding(.top, 4)
                            }
                        }

                        // Brand
                        VStack(alignment: .leading, spacing: 6) {
                            Text(lz(en: "Brand", de: "Marke", fr: "Marque", es: "Marca"))
                                .font(.caption).foregroundColor(.secondary)
                            HStack {
                                TextField("Generic", text: $spoolData.brand)
                                    .foregroundColor(.primary)
                                Spacer()
                                Menu {
                                    ForEach(brandSuggestions, id: \.self) { b in
                                        Button(b) { spoolData.brand = b }
                                    }
                                } label: {
                                    Image(systemName: "list.bullet").foregroundColor(.secondary)
                                }
                            }
                            .padding(12)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(10)
                        }

                        // Type
                        VStack(alignment: .leading, spacing: 6) {
                            Text(lz(en: "Type", de: "Typ", fr: "Type", es: "Tipo"))
                                .font(.caption).foregroundColor(.secondary)
                            Menu {
                                ForEach(materials, id: \.self) { mat in
                                    Button(action: { spoolData.type = mat }) {
                                        Label(mat, systemImage: spoolData.type == mat ? "checkmark" : "")
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(spoolData.type).foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.down").foregroundColor(.secondary).font(.caption)
                                }
                                .padding(12)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(10)
                            }
                        }

                        // Subtype
                        VStack(alignment: .leading, spacing: 6) {
                            Text(lz(en: "Variant", de: "Variante", fr: "Variante", es: "Variante"))
                                .font(.caption).foregroundColor(.secondary)
                            Menu {
                                Button(action: { spoolData.subtype = "" }) {
                                    Label(lz(en: "None", de: "Keine", fr: "Aucune", es: "Ninguna"),
                                          systemImage: spoolData.subtype.isEmpty ? "checkmark" : "")
                                }
                                Divider()
                                ForEach(subtypes.filter { !$0.isEmpty }, id: \.self) { sub in
                                    Button(action: { spoolData.subtype = sub }) {
                                        Label(sub, systemImage: spoolData.subtype == sub ? "checkmark" : "")
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(spoolData.subtype.isEmpty
                                         ? lz(en: "None", de: "Keine", fr: "Aucune", es: "Ninguna")
                                         : spoolData.subtype)
                                        .foregroundColor(spoolData.subtype.isEmpty ? .secondary : .primary)
                                    Spacer()
                                    Image(systemName: "chevron.down").foregroundColor(.secondary).font(.caption)
                                }
                                .padding(12)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(10)
                            }
                        }

                        // Nozzle temperatures
                        Text(lz(en: "Nozzle Temperature", de: "Düsentemperatur", fr: "Température buse", es: "Temperatura boquilla"))
                            .font(.caption).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Min")
                                    .font(.caption2).foregroundColor(.secondary)
                                Menu {
                                    ForEach(tempRange, id: \.self) { t in
                                        Button("\(t)°C") { spoolData.minTemp = t }
                                    }
                                } label: {
                                    HStack {
                                        Text("\(spoolData.minTemp)°C").foregroundColor(.primary)
                                        Spacer()
                                        Image(systemName: "chevron.down").foregroundColor(.secondary).font(.caption)
                                    }
                                    .padding(12)
                                    .background(Color(.secondarySystemBackground))
                                    .cornerRadius(10)
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Max")
                                    .font(.caption2).foregroundColor(.secondary)
                                Menu {
                                    ForEach(tempRange, id: \.self) { t in
                                        Button("\(t)°C") { spoolData.maxTemp = t }
                                    }
                                } label: {
                                    HStack {
                                        Text("\(spoolData.maxTemp)°C").foregroundColor(.primary)
                                        Spacer()
                                        Image(systemName: "chevron.down").foregroundColor(.secondary).font(.caption)
                                    }
                                    .padding(12)
                                    .background(Color(.secondarySystemBackground))
                                    .cornerRadius(10)
                                }
                            }
                        }

                        // Bed temperatures
                        Text(lz(en: "Bed Temperature", de: "Betttemperatur", fr: "Température du lit", es: "Temperatura cama"))
                            .font(.caption).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Min")
                                    .font(.caption2).foregroundColor(.secondary)
                                Menu {
                                    Button(lz(en: "Not set", de: "Nicht gesetzt", fr: "Non défini", es: "No definido")) { spoolData.bedMinTemp = 0 }
                                    Divider()
                                    ForEach(bedTempRange, id: \.self) { t in
                                        Button("\(t)°C") { spoolData.bedMinTemp = t }
                                    }
                                } label: {
                                    HStack {
                                        Text(spoolData.bedMinTemp > 0 ? "\(spoolData.bedMinTemp)°C" : "–").foregroundColor(.primary)
                                        Spacer()
                                        Image(systemName: "chevron.down").foregroundColor(.secondary).font(.caption)
                                    }
                                    .padding(12)
                                    .background(Color(.secondarySystemBackground))
                                    .cornerRadius(10)
                                }
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Max")
                                    .font(.caption2).foregroundColor(.secondary)
                                Menu {
                                    Button(lz(en: "Not set", de: "Nicht gesetzt", fr: "Non défini", es: "No definido")) { spoolData.bedMaxTemp = 0 }
                                    Divider()
                                    ForEach(bedTempRange, id: \.self) { t in
                                        Button("\(t)°C") { spoolData.bedMaxTemp = t }
                                    }
                                } label: {
                                    HStack {
                                        Text(spoolData.bedMaxTemp > 0 ? "\(spoolData.bedMaxTemp)°C" : "–").foregroundColor(.primary)
                                        Spacer()
                                        Image(systemName: "chevron.down").foregroundColor(.secondary).font(.caption)
                                    }
                                    .padding(12)
                                    .background(Color(.secondarySystemBackground))
                                    .cornerRadius(10)
                                }
                            }
                        }

                        // Read / Write buttons
                        HStack(spacing: 12) {
                            Button(action: { nfc.read() }) {
                                HStack(spacing: 8) {
                                    if nfc.isScanning && nfc.writeData == nil {
                                        ProgressView().tint(.primary)
                                    } else {
                                        Image(systemName: "wave.3.left")
                                    }
                                    Text(lz(en: "Read Tag", de: "Tag lesen", fr: "Lire tag", es: "Leer tag"))
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color(.secondarySystemBackground))
                                .foregroundColor(.primary)
                                .cornerRadius(12)
                            }
                            .disabled(nfc.isScanning)

                            Button(action: { nfc.write(data: spoolData) }) {
                                HStack(spacing: 8) {
                                    if nfc.isScanning && nfc.writeData != nil {
                                        ProgressView().tint(.primary)
                                    } else {
                                        Image(systemName: "wave.3.right")
                                    }
                                    Text(lz(en: "Write Tag", de: "Tag schreiben", fr: "Écrire tag", es: "Escribir tag"))
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color(.secondarySystemBackground))
                                .foregroundColor(.primary)
                                .cornerRadius(12)
                            }
                            .disabled(nfc.isScanning)
                        }
                    }
                    .padding(.horizontal, 20)

                    // Info
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle").foregroundColor(.secondary)
                        Text(lz(
                            en: "Compatible tags: NTAG215, NTAG216. Hold your iPhone near the spool tag to read or write.",
                            de: "Kompatible Tags: NTAG215, NTAG216. Halte dein iPhone an das Spulen-Tag zum Lesen oder Schreiben.",
                            fr: "Tags compatibles : NTAG215, NTAG216. Approchez votre iPhone du tag pour lire ou écrire.",
                            es: "Tags compatibles: NTAG215, NTAG216. Acerque el iPhone al tag para leer o escribir."
                        ))
                        .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
                    .padding(.horizontal, 20)

                    Spacer(minLength: 20)
                }
            }
                } // else (iPhone)
            } // Group
            .navigationTitle("NFC")
            .navigationBarTitleDisplayMode(.inline)
            .alert(lz(en: "Error", de: "Fehler", fr: "Erreur", es: "Error"), isPresented: $nfc.showError) {
                Button("OK", role: .cancel) {}
            } message: { Text(nfc.statusMessage) }
            .onChange(of: nfc.lastRead) {
                guard let data = nfc.lastRead else { return }
                spoolData = data
                if let match = NFCColorOption.all.first(where: { $0.hex.lowercased() == data.colorHex.lowercased() }) {
                    selectedColorID = match.id
                    showCustomColor = false
                } else {
                    showCustomColor = true
                    customColor = Color(hex: data.colorHex) ?? .gray
                }
                nfc.statusMessage = lz(en: "Tag read successfully", de: "Tag erfolgreich gelesen", fr: "Tag lu avec succès", es: "Tag leído con éxito")
            }
            .sheet(isPresented: $showColorSheet) {
                NFCColorPickerSheet(
                    selectedColorID: $selectedColorID,
                    showCustomColor: $showCustomColor,
                    customColor: $customColor,
                    colorHex: $spoolData.colorHex,
                    isPresented: $showColorSheet
                )
                .presentationDetents([.medium])
            }
        }
    }

    // Form fields used by the iPad right panel (Color → Bed Temp)
    @ViewBuilder
    private var nfcFormFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(lz(en: "Color", de: "Farbe", fr: "Couleur", es: "Color"))
                .font(.caption).foregroundColor(.secondary)
            Button(action: { showColorSheet = true }) {
                HStack {
                    Circle().fill(spoolColor).frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                    Text(showCustomColor ? "#\(spoolData.colorHex.uppercased())" :
                            (NFCColorOption.all.first { $0.id == selectedColorID }?.name ?? ""))
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.down").foregroundColor(.secondary).font(.caption)
                }
                .padding(12).background(Color(.secondarySystemBackground)).cornerRadius(10)
            }
            .buttonStyle(.plain)
            if showCustomColor {
                ColorPicker(lz(en: "Pick color", de: "Farbe wählen", fr: "Choisir couleur", es: "Elegir color"), selection: $customColor, supportsOpacity: false)
                    .onChange(of: customColor) { spoolData.colorHex = customColor.hexString }
                    .padding(.top, 4)
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text(lz(en: "Brand", de: "Marke", fr: "Marque", es: "Marca"))
                .font(.caption).foregroundColor(.secondary)
            HStack {
                TextField("Generic", text: $spoolData.brand).foregroundColor(.primary)
                Spacer()
                Menu {
                    ForEach(brandSuggestions, id: \.self) { b in Button(b) { spoolData.brand = b } }
                } label: { Image(systemName: "list.bullet").foregroundColor(.secondary) }
            }
            .padding(12).background(Color(.secondarySystemBackground)).cornerRadius(10)
        }
        VStack(alignment: .leading, spacing: 6) {
            Text(lz(en: "Type", de: "Typ", fr: "Type", es: "Tipo"))
                .font(.caption).foregroundColor(.secondary)
            Menu {
                ForEach(materials, id: \.self) { mat in
                    Button(action: { spoolData.type = mat }) {
                        Label(mat, systemImage: spoolData.type == mat ? "checkmark" : "")
                    }
                }
            } label: {
                HStack {
                    Text(spoolData.type).foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.down").foregroundColor(.secondary).font(.caption)
                }
                .padding(12).background(Color(.secondarySystemBackground)).cornerRadius(10)
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text(lz(en: "Variant", de: "Variante", fr: "Variante", es: "Variante"))
                .font(.caption).foregroundColor(.secondary)
            Menu {
                Button(action: { spoolData.subtype = "" }) {
                    Label(lz(en: "None", de: "Keine", fr: "Aucune", es: "Ninguna"),
                          systemImage: spoolData.subtype.isEmpty ? "checkmark" : "")
                }
                Divider()
                ForEach(subtypes.filter { !$0.isEmpty }, id: \.self) { sub in
                    Button(action: { spoolData.subtype = sub }) {
                        Label(sub, systemImage: spoolData.subtype == sub ? "checkmark" : "")
                    }
                }
            } label: {
                HStack {
                    Text(spoolData.subtype.isEmpty ? lz(en: "None", de: "Keine", fr: "Aucune", es: "Ninguna") : spoolData.subtype)
                        .foregroundColor(spoolData.subtype.isEmpty ? .secondary : .primary)
                    Spacer()
                    Image(systemName: "chevron.down").foregroundColor(.secondary).font(.caption)
                }
                .padding(12).background(Color(.secondarySystemBackground)).cornerRadius(10)
            }
        }
        Text(lz(en: "Nozzle Temperature", de: "Düsentemperatur", fr: "Température buse", es: "Temperatura boquilla"))
            .font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 12) {
            ForEach([("Min", $spoolData.minTemp, spoolData.minTemp), ("Max", $spoolData.maxTemp, spoolData.maxTemp)], id: \.0) { label, binding, current in
                VStack(alignment: .leading, spacing: 6) {
                    Text(label).font(.caption2).foregroundColor(.secondary)
                    Menu {
                        ForEach(tempRange, id: \.self) { t in Button("\(t)°C") { binding.wrappedValue = t } }
                    } label: {
                        HStack {
                            Text("\(current)°C").foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.down").foregroundColor(.secondary).font(.caption)
                        }
                        .padding(12).background(Color(.secondarySystemBackground)).cornerRadius(10)
                    }
                }
            }
        }
        Text(lz(en: "Bed Temperature", de: "Betttemperatur", fr: "Température du lit", es: "Temperatura cama"))
            .font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Min").font(.caption2).foregroundColor(.secondary)
                Menu {
                    Button(lz(en: "Not set", de: "Nicht gesetzt", fr: "Non défini", es: "No definido")) { spoolData.bedMinTemp = 0 }
                    Divider()
                    ForEach(bedTempRange, id: \.self) { t in Button("\(t)°C") { spoolData.bedMinTemp = t } }
                } label: {
                    HStack {
                        Text(spoolData.bedMinTemp > 0 ? "\(spoolData.bedMinTemp)°C" : "–").foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "chevron.down").foregroundColor(.secondary).font(.caption)
                    }
                    .padding(12).background(Color(.secondarySystemBackground)).cornerRadius(10)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Max").font(.caption2).foregroundColor(.secondary)
                Menu {
                    Button(lz(en: "Not set", de: "Nicht gesetzt", fr: "Non défini", es: "No definido")) { spoolData.bedMaxTemp = 0 }
                    Divider()
                    ForEach(bedTempRange, id: \.self) { t in Button("\(t)°C") { spoolData.bedMaxTemp = t } }
                } label: {
                    HStack {
                        Text(spoolData.bedMaxTemp > 0 ? "\(spoolData.bedMaxTemp)°C" : "–").foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "chevron.down").foregroundColor(.secondary).font(.caption)
                    }
                    .padding(12).background(Color(.secondarySystemBackground)).cornerRadius(10)
                }
            }
        }
    }
}

struct NFCColorPickerSheet: View {
    @Binding var selectedColorID: String
    @Binding var showCustomColor: Bool
    @Binding var customColor: Color
    @Binding var colorHex: String
    @Binding var isPresented: Bool

    var body: some View {
        NavigationView {
            List {
                ForEach(NFCColorOption.all) { opt in
                    Button(action: {
                        selectedColorID = opt.id
                        colorHex = opt.hex
                        showCustomColor = false
                        isPresented = false
                    }) {
                        HStack(spacing: 14) {
                            Circle().fill(opt.color).frame(width: 28, height: 28)
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                            Text(opt.name).foregroundColor(.primary)
                            Spacer()
                            if selectedColorID == opt.id && !showCustomColor {
                                Image(systemName: "checkmark").foregroundColor(.blue).fontWeight(.semibold)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: {
                    showCustomColor = true
                    isPresented = false
                }) {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                                .frame(width: 28, height: 28)
                        }
                        Text(lz(en: "Custom...", de: "Eigene...", fr: "Personnalisé...", es: "Personalizado..."))
                            .foregroundColor(.primary)
                        Spacer()
                        if showCustomColor {
                            Image(systemName: "checkmark").foregroundColor(.blue).fontWeight(.semibold)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(lz(en: "Color", de: "Farbe", fr: "Couleur", es: "Color"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lz(en: "Done", de: "Fertig", fr: "Terminé", es: "Listo")) { isPresented = false }
                }
            }
        }
    }
}

// MARK: - Timelapse

private struct TLFile: Identifiable {
    var id: String { path }
    var path: String
    var modified: Double
    var size: Int64
    var baseURL: String

    var filename: String { path.components(separatedBy: "/").last ?? path }
    var displayName: String {
        filename
            .replacingOccurrences(of: ".mp4", with: "")
            .replacingOccurrences(of: ".mkv", with: "")
            .replacingOccurrences(of: ".mov", with: "")
    }
    var formattedDate: String {
        DateFormatter.localizedString(from: Date(timeIntervalSince1970: modified),
                                      dateStyle: .medium, timeStyle: .short)
    }
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
    var downloadURL: URL? {
        let enc = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        return URL(string: "\(baseURL)/server/files/timelapse/\(enc)")
    }
}

struct TimelapseView: View {
    let baseURL: String
    let apiKey: String

    @State private var files: [TLFile] = []
    @State private var isLoading = true
    @State private var loadError: String? = nil
    @State private var playingFile: TLFile? = nil
    @State private var exportingPath: String? = nil
    @State private var exportURL: URL? = nil
    @State private var showShare = false

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                    Text(lz(en: "Loading timelapse videos…",
                            de: "Lade Timelapse-Videos…",
                            fr: "Chargement des timelapse…",
                            es: "Cargando timelapse…"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = loadError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40)).foregroundStyle(.orange)
                    Text(err).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button(lz(en: "Retry", de: "Erneut laden", fr: "Réessayer", es: "Reintentar")) {
                        Task { await loadFiles() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(lz(en: "No timelapse videos found.\nStart a print to create one.",
                            de: "Keine Timelapse-Videos vorhanden.\nStarte einen Druck, um eines zu erstellen.",
                            fr: "Aucune vidéo timelapse trouvée.",
                            es: "No se encontraron videos timelapse."))
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button(lz(en: "Refresh", de: "Aktualisieren", fr: "Actualiser", es: "Actualizar")) {
                        Task { await loadFiles() }
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(files) { file in
                        TLRow(
                            file: file,
                            apiKey: apiKey,
                            isExporting: exportingPath == file.path,
                            onPlay: { playingFile = file },
                            onExport: { Task { await exportFile(file) } }
                        )
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await loadFiles() }
            }
        }
        .task { await loadFiles() }
        .sheet(item: $playingFile) { file in
            if let url = file.downloadURL {
                TLPlayerSheet(url: url, apiKey: apiKey, title: file.displayName)
            }
        }
        .sheet(isPresented: $showShare, onDismiss: {
            if let url = exportURL { try? FileManager.default.removeItem(at: url) }
            exportURL = nil
        }) {
            if let url = exportURL {
                TLShareSheet(items: [url]).ignoresSafeArea()
            }
        }
    }

    private func loadFiles() async {
        await MainActor.run { isLoading = true; loadError = nil }
        guard let url = URL(string: "\(baseURL)/server/files/list?root=timelapse") else {
            await MainActor.run { isLoading = false; loadError = "Ungültige URL" }
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [[String: Any]] else {
                await MainActor.run { isLoading = false; loadError = lz(en: "No response from server", de: "Keine Serverantwort", fr: "Pas de réponse du serveur", es: "Sin respuesta del servidor") }
                return
            }
            let loaded = result.compactMap { d -> TLFile? in
                guard let path = d["path"] as? String else { return nil }
                let ext = (path as NSString).pathExtension.lowercased()
                guard ext == "mp4" || ext == "mkv" || ext == "mov" else { return nil }
                return TLFile(path: path,
                              modified: d["modified"] as? Double ?? 0,
                              size: d["size"] as? Int64 ?? Int64(d["size"] as? Int ?? 0),
                              baseURL: baseURL)
            }.sorted { $0.modified > $1.modified }
            await MainActor.run { files = loaded; isLoading = false }
        } catch {
            await MainActor.run { isLoading = false; loadError = error.localizedDescription }
        }
    }

    private func exportFile(_ file: TLFile) async {
        guard let url = file.downloadURL else { return }
        await MainActor.run { exportingPath = file.path }
        var req = URLRequest(url: url, timeoutInterval: 300)
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(file.filename)
            try data.write(to: tmp)
            await MainActor.run { exportingPath = nil; exportURL = tmp; showShare = true }
        } catch {
            await MainActor.run { exportingPath = nil }
        }
    }
}

private struct TLRow: View {
    let file: TLFile
    let apiKey: String
    let isExporting: Bool
    let onPlay: () -> Void
    let onExport: () -> Void

    @State private var thumbnail: CGImage? = nil
    @State private var thumbLoading = true

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12))
                if let thumb = thumbnail {
                    Image(thumb, scale: 1.0, label: Text(""))
                        .resizable().scaledToFill()
                        .clipped()
                } else if thumbLoading {
                    ProgressView().scaleEffect(0.65)
                } else {
                    Image(systemName: "video.fill").font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .task(id: file.path) { await loadThumbnail() }

            VStack(alignment: .leading, spacing: 3) {
                Text(file.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(file.formattedDate)
                    Text("·")
                    Text(file.formattedSize)
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                Button(action: onPlay) {
                    Image(systemName: "play.circle.fill")
                        .font(.title).foregroundStyle(.blue)
                }
                .buttonStyle(.plain)

                Button(action: onExport) {
                    if isExporting {
                        ProgressView().frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title2).foregroundStyle(.blue)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isExporting)
            }
        }
        .padding(.vertical, 6)
    }

    private func loadThumbnail() async {
        guard let url = file.downloadURL else {
            await MainActor.run { thumbLoading = false }
            return
        }
        var options: [String: Any] = ["AVURLAssetPreferPreciseDurationAndTimingKey": false]
        if !apiKey.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = ["X-Api-Key": apiKey]
        }
        let asset = AVURLAsset(url: url, options: options)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 128, height: 90)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 5, preferredTimescale: 600)
        if let img = try? await gen.image(at: .zero).image {
            await MainActor.run { thumbnail = img; thumbLoading = false }
        } else {
            await MainActor.run { thumbLoading = false }
        }
    }
}

struct TLPlayerSheet: View {
    let url: URL
    let apiKey: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4)
                    .padding(20)
            }
        }
        .onAppear {
            if apiKey.isEmpty {
                player = AVPlayer(url: url)
            } else {
                let asset = AVURLAsset(url: url,
                    options: ["AVURLAssetHTTPHeaderFieldsKey": ["X-Api-Key": apiKey]])
                player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            }
            player?.play()
        }
        .onDisappear { player?.pause(); player = nil }
    }
}

struct TLShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView()
}
