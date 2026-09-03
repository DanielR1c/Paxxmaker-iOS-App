import SwiftUI
import Combine
import WatchConnectivity
import WidgetKit
import CoreGraphics
import ImageIO

private func lz(en: String, de: String, fr: String, es: String, pt: String = "", it: String = "", zh: String = "") -> String {
    // Language chosen in the iPhone app (synced over WatchConnectivity) wins;
    // only fall back to the system language before the first sync.
    let code = UserDefaults.standard.string(forKey: "app_language")
        ?? UserDefaults(suiteName: "group.paxxmaker.u1")?.string(forKey: "app_language")
        ?? Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
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

// URLError.localizedDescription follows the SYSTEM language, which disagrees
// with the app's own language setting — translate the common cases ourselves.
private func lzTransport(_ error: Error) -> String {
    if let e = error as? URLError {
        switch e.code {
        case .timedOut:
            return lz(en: "Connection timed out.", de: "Zeitüberschreitung der Verbindung.", fr: "Délai de connexion dépassé.", es: "Tiempo de conexión agotado.", pt: "Tempo de conexão esgotado.", it: "Timeout della connessione.", zh: "连接超时。")
        case .notConnectedToInternet:
            return lz(en: "No internet connection.", de: "Keine Internetverbindung.", fr: "Aucune connexion internet.", es: "Sin conexión a internet.", pt: "Sem conexão com a internet.", it: "Nessuna connessione internet.", zh: "无网络连接。")
        default: break
        }
    }
    return lz(en: "Could not connect to the server.", de: "Verbindung zum Server konnte nicht hergestellt werden.", fr: "Impossible de se connecter au serveur.", es: "No se pudo conectar al servidor.", pt: "Não foi possível conectar ao servidor.", it: "Impossibile connettersi al server.", zh: "无法连接到服务器。")
}

// MARK: - Printer Data Model
struct WatchPrinterData: Identifiable, Codable {
    var id: String
    var name: String
    var printState: String
    var filename: String
    var progress: Double
    var extruderTemp: Double
    var bedTemp: Double
    var timeElapsed: Int
    var themeHex: String

    var stateColor: Color {
        switch printState {
        case "printing": return .green
        case "paused":   return .orange
        case "error":    return .red
        case "complete": return .blue
        default:         return Color(white: 0.55)
        }
    }

    var stateLabel: String {
        switch printState {
        case "printing": return lz(en: "Printing",   de: "Druckt",     fr: "Impression",  es: "Imprimiendo", pt: "Imprimindo", it: "Stampa in corso", zh: "打印中")
        case "paused":   return lz(en: "Paused",     de: "Pause",      fr: "Pause",       es: "Pausado", pt: "Pausado", it: "In pausa", zh: "已暂停")
        case "error":    return lz(en: "Error",      de: "Fehler",     fr: "Erreur",      es: "Error", pt: "Erro", it: "Errore", zh: "错误")
        case "complete": return lz(en: "Done",       de: "Fertig",     fr: "Terminé",     es: "Listo", pt: "Concluído", it: "Fatto", zh: "完成")
        case "standby":  return lz(en: "Ready",      de: "Bereit",     fr: "Prêt",        es: "Listo", pt: "Pronto", it: "Pronto", zh: "就绪")
        default:         return "–"
        }
    }

    var themeColor: Color {
        guard themeHex.count == 6, let val = UInt64(themeHex, radix: 16) else { return .blue }
        return Color(red: Double((val >> 16) & 0xFF) / 255,
                     green: Double((val >> 8)  & 0xFF) / 255,
                     blue:  Double( val        & 0xFF) / 255)
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

    var isActive: Bool { printState == "printing" || printState == "paused" }
}

// MARK: - Config Model (written by iPhone into App Group)
fileprivate struct WatchPrinterDirectConfig: Codable {
    var id: String; var name: String; var baseURL: String; var apiKey: String; var themeHex: String
    // Kept for forward-compat with the iPhone payload. The Watch never contacts
    // the Cloudflare Worker itself — it gets data from the iPhone (WatchConnectivity),
    // the local printer LAN when home, and the iPhone's Live Activity which
    // watchOS mirrors onto the watch. Non-cellular watches always have the phone.
    var cfSecret: String?
    var pushMode: String?
}

// MARK: - File Model
struct WatchFileItem: Identifiable {
    var id = UUID()
    var path: String
    var modified: Double

    var displayName: String {
        (path.components(separatedBy: "/").last ?? path)
            .replacingOccurrences(of: ".gcode", with: "")
            .replacingOccurrences(of: ".gco",   with: "")
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: Date(timeIntervalSince1970: modified))
    }
}

// MARK: - Watch Connectivity Manager
class WatchConnectivityManager: NSObject, ObservableObject, WCSessionDelegate {
    // Singleton, damit App und Background-Refresh-Task dieselbe Instanz (und
    // damit denselben WCSession-Delegate) verwenden.
    static let shared = WatchConnectivityManager()

    @Published var printers: [WatchPrinterData] = []
    @Published var isLoading = true
    fileprivate private(set) var configs: [WatchPrinterDirectConfig] = []

    private var directPollTimer: Timer?
    private var lastWCUpdate: Date?
    private var phoneFallbackTask: Task<Void, Never>?
    // The recursive 30 s direct-poll chain — MUST be single-instance. Every
    // wrist-raise / app-activation used to start a brand new never-cancelled
    // chain on top of any already running ones (each self-rescheduling
    // forever), so a day of intermittent use could stack up many concurrent
    // pollers — multiplying Cloudflare Worker requests whenever the LAN fetch
    // fell back to the remote status endpoint.
    private var directPollChain: Task<Void, Never>?

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        startDirectPolling()
        // Track the initial poll chain too, so a later startDirectPollChain()
        // cancels it instead of leaving a second chain running forever.
        directPollChain = Task {
            await fetchDirect()
            await MainActor.run { isLoading = false }
        }
    }

    deinit { directPollTimer?.invalidate(); directPollChain?.cancel() }

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        guard activationState == .activated else { return }
        // Apply the last cached context immediately (stale but instant)
        let ctx = session.receivedApplicationContext
        if !ctx.isEmpty { parse(ctx) }
        // Then request fresh data from the iPhone
        requestStatusFromPhone()
    }

    func session(_ session: WCSession,
                 didReceiveApplicationContext applicationContext: [String: Any]) { parse(applicationContext) }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) { parse(userInfo) }

    private func parse(_ dict: [String: Any]) {
        // Keep the Watch's language in step with the iPhone app's setting.
        if let lang = dict["lang"] as? String, !lang.isEmpty,
           UserDefaults.standard.string(forKey: "app_language") != lang {
            UserDefaults.standard.set(lang, forKey: "app_language")
            // The watch complications run in their own process — they can only
            // read the shared app group.
            UserDefaults(suiteName: "group.paxxmaker.u1")?.set(lang, forKey: "app_language")
            WidgetCenter.shared.reloadAllTimelines()
        }
        // Store connection configs shipped by the iPhone in OUR app group —
        // iPhone and Watch app groups are separate containers, so this is the
        // only way the Watch ever gets them (needed for direct printer polling
        // while the iOS app isn't running).
        if let cfgData = dict["configs"] as? Data,
           let loaded = try? JSONDecoder().decode([WatchPrinterDirectConfig].self, from: cfgData) {
            configs = loaded
            UserDefaults(suiteName: "group.paxxmaker.u1")?
                .set(cfgData, forKey: "watch_printer_configs")
        }
        guard let raw = dict["printers"] as? Data,
              let decoded = try? JSONDecoder().decode([WatchPrinterData].self, from: raw)
        else { return }
        // Load configs from app group whenever they're missing (older iOS builds
        // don't ship them in the payload)
        if configs.isEmpty,
           let defaults = UserDefaults(suiteName: "group.paxxmaker.u1"),
           let data = defaults.data(forKey: "watch_printer_configs"),
           let loaded = try? JSONDecoder().decode([WatchPrinterDirectConfig].self, from: data) {
            configs = loaded
        }
        // Stale cache (e.g. the iPhone app was woken in background and replied
        // with old data) must NOT count as a fresh update — otherwise direct
        // polling stays suppressed and the Watch freezes on old values.
        let sentAt = dict["at"] as? Double
        let isFresh = sentAt.map { Date().timeIntervalSince1970 - $0 < 90 } ?? false
        DispatchQueue.main.async {
            if isFresh { self.lastWCUpdate = Date() }
            self.printers = decoded
            self.writeComplicationData(decoded)
        }
        // Route through the single-instance chain — spawning a bare
        // Task { fetchDirect() } here would leak a new eternal 30 s poller on
        // every stale WC update, stacking into a Cloudflare request storm.
        if !isFresh { DispatchQueue.main.async { self.startDirectPollChain() } }
    }

    // MARK: - Direct API polling

    private func startDirectPolling() {
        directPollTimer?.invalidate()
        directPollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.fetchDirectIfNeeded() }
        }
    }

    func refresh() {
        // Ask the iPhone first. It replies from its cache (with an age stamp);
        // requestStatusFromPhone() itself falls back to a direct printer/Worker
        // poll only if the phone is unreachable or doesn't answer in time.
        // (Previously this ALSO kicked off a direct poll unconditionally, so the
        // Worker got hit even when the phone had fresh data right there.)
        requestStatusFromPhone()
    }

    // Cancels any previous recursive poll chain before starting a new one —
    // there must only ever be ONE running at a time.
    private func startDirectPollChain() {
        directPollChain?.cancel()
        directPollChain = Task { await fetchDirect() }
    }

    private func requestStatusFromPhone() {
        // Cancel any previous pending fallback
        phoneFallbackTask?.cancel()

        guard WCSession.default.activationState == .activated else {
            startDirectPollChain()
            return
        }
        guard WCSession.default.isReachable else {
            // iPhone definitively unreachable — go straight to printer
            startDirectPollChain()
            return
        }

        // Give the iPhone 10 s to reply; if it doesn't, poll the printer directly
        let fallback = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.startDirectPollChain()
        }
        phoneFallbackTask = fallback

        WCSession.default.sendMessage(["requestStatus": true, "printerIndex": 0]) { [weak self] reply in
            fallback.cancel()
            self?.parse(reply)
            DispatchQueue.main.async { self?.isLoading = false }
        } errorHandler: { [weak self] _ in
            fallback.cancel()
            self?.startDirectPollChain()
        }
    }

    // True if any known printer is mid-print — the only time auto-polling runs.
    private var anyPrinterActive: Bool {
        printers.contains { $0.printState == "printing" || $0.printState == "paused" }
    }

    private func fetchDirectIfNeeded() async {
        guard !Task.isCancelled else { return }
        if let last = lastWCUpdate, -last.timeIntervalSinceNow < 90 { return }
        // Maximally sparse: don't auto-poll while nothing is printing. A print
        // that starts while idle is picked up the next time the Watch app is
        // opened (refresh() always does one check regardless of this gate).
        guard await MainActor.run(body: { anyPrinterActive }) else { return }
        await fetchDirect()
    }

    private func fetchDirect() async {
        guard !Task.isCancelled else { return }
        await fetchDirectOnce()
        // Continue the 30 s loop only while a print is active; otherwise stop and
        // wait for the next manual refresh (opening the app). Zero idle load.
        guard await MainActor.run(body: { anyPrinterActive }) else { return }
        try? await Task.sleep(for: .seconds(30))
        guard !Task.isCancelled else { return }
        await fetchDirectIfNeeded()
    }

    // Background complication refresh entry point. Only reaches out to the
    // Worker while a print is active (per the last persisted complication
    // state) — idle needs ZERO requests. A print that starts while idle is
    // picked up when the Watch app is next opened (which calls refresh()).
    func fetchDirectOnceIfActive() async {
        struct StatePeek: Decodable { let printState: String }
        guard let defaults = UserDefaults(suiteName: "group.paxxmaker.u1"),
              let data = defaults.data(forKey: "watch_all_printers"),
              let peek = try? JSONDecoder().decode([StatePeek].self, from: data),
              peek.contains(where: { $0.printState == "printing" || $0.printState == "paused" })
        else { return }
        await fetchDirectOnce()
    }

    // Single-shot direct poll — also used by the background refresh task (which
    // must not start the endless polling loop above).
    func fetchDirectOnce() async {
        guard let defaults = UserDefaults(suiteName: "group.paxxmaker.u1"),
              let data = defaults.data(forKey: "watch_printer_configs"),
              let loadedConfigs = try? JSONDecoder().decode([WatchPrinterDirectConfig].self, from: data),
              !loadedConfigs.isEmpty
        else { return }

        self.configs = loadedConfigs

        // Keyed by config id so a printer that's currently unreachable (away
        // from its WiFi, no push configured) keeps showing its last known
        // status instead of vanishing from the list entirely.
        let fresh: [String: WatchPrinterData] = await withTaskGroup(of: (String, WatchPrinterData?).self) { group in
            for config in loadedConfigs {
                group.addTask { (config.id, await self.fetchPrinterStatus(config)) }
            }
            var results: [String: WatchPrinterData] = [:]
            for await (id, data) in group { if let data { results[id] = data } }
            return results
        }

        let stale = await MainActor.run { Dictionary(uniqueKeysWithValues: printers.map { ($0.id, $0) }) }
        var updated: [WatchPrinterData] = loadedConfigs.compactMap { fresh[$0.id] ?? stale[$0.id] }

        // Only update if we actually got results — don't overwrite WC data with an empty list
        guard !updated.isEmpty else { return }

        updated.sort { a, b in
            let ai = loadedConfigs.firstIndex(where: { $0.id == a.id }) ?? 0
            let bi = loadedConfigs.firstIndex(where: { $0.id == b.id }) ?? 0
            return ai < bi
        }

        await MainActor.run {
            self.printers = updated
            self.writeComplicationData(updated)
        }
    }

    private func fetchPrinterStatus(_ config: WatchPrinterDirectConfig) async -> WatchPrinterData? {
        let query = "print_stats&display_status&extruder&heater_bed"
        guard let url = URL(string: "\(config.baseURL)/printer/objects/query?\(query)") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 4)
        if !config.apiKey.isEmpty { request.setValue(config.apiKey, forHTTPHeaderField: "X-Api-Key") }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = (json["result"] as? [String: Any])?["status"] as? [String: Any]
            else { return nil }
            let ps  = status["print_stats"]    as? [String: Any] ?? [:]
            let ds  = status["display_status"] as? [String: Any] ?? [:]
            let ext = status["extruder"]       as? [String: Any] ?? [:]
            let bed = status["heater_bed"]     as? [String: Any] ?? [:]
            return WatchPrinterData(
                id: config.id, name: config.name,
                printState:   ps["state"]           as? String ?? "standby",
                filename:     ps["filename"]         as? String ?? "",
                progress:     ds["progress"]         as? Double ?? 0,
                extruderTemp: ext["temperature"]     as? Double ?? 0,
                bedTemp:      bed["temperature"]     as? Double ?? 0,
                timeElapsed:  Int(ps["print_duration"] as? Double ?? 0),
                themeHex:     config.themeHex
            )
        } catch {
            // Printer's LAN IP is unreachable — typical when away from home
            // WiFi. If Server Push is on, the Cloudflare Worker has a recent
            // status snapshot reachable from anywhere (cellular included).
            return nil
        }
    }

    private var lastWidgetHash: Int = 0

    private func writeComplicationData(_ printers: [WatchPrinterData]) {
        guard let defaults = UserDefaults(suiteName: "group.paxxmaker.u1") else { return }
        struct Payload: Codable {
            var id: String; var printerName: String; var progress: Double
            var printState: String; var themeHex: String; var timeElapsed: Int
        }
        let allPayloads = printers.map {
            Payload(id: $0.id, printerName: $0.name, progress: $0.progress,
                    printState: $0.printState, themeHex: $0.themeHex, timeElapsed: $0.timeElapsed)
        }
        guard let encoded = try? JSONEncoder().encode(allPayloads) else { return }
        let newHash = encoded.hashValue
        guard newHash != lastWidgetHash else { return }
        lastWidgetHash = newHash
        defaults.set(encoded, forKey: "watch_all_printers")
        if let first = printers.first {
            let single = Payload(id: first.id, printerName: first.name, progress: first.progress,
                                 printState: first.printState, themeHex: first.themeHex,
                                 timeElapsed: first.timeElapsed)
            if let singleEncoded = try? JSONEncoder().encode(single) {
                defaults.set(singleEncoded, forKey: "watch_complication")
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - Root View
private enum DragDir { case none, vertical, horizontal }

struct ContentView: View {
    @EnvironmentObject var wc: WatchConnectivityManager
    @State private var selectedIndex = 0
    @State private var showFiles = false
    @State private var verticalDrag: CGFloat = 0
    @State private var horizontalDrag: CGFloat = 0
    @State private var crownValue: Double = 0
    @State private var dragDir: DragDir = .none

    var body: some View {
        if wc.isLoading && wc.printers.isEmpty {
            VStack(spacing: 8) {
                ProgressView()
                Text(lz(en: "Connecting…", de: "Verbinde…", fr: "Connexion…", es: "Conectando…", pt: "Conectando…", it: "Connessione…", zh: "连接中…"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } else if wc.printers.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "printer.slash")
                    .font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                Text(lz(en: "No printer\nreachable", de: "Kein Drucker\nerreichbar",
                        fr: "Imprimante\nindisponible", es: "Sin impresora",
                        pt: "Impressora\ninacessível", it: "Stampante\nnon raggiungibile", zh: "无法连接\n打印机"))
                    .multilineTextAlignment(.center)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }
        } else {
            let count = wc.printers.count
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                HStack(spacing: 0) {
                    // Left: vertical printer pager
                    GeometryReader { g in
                        VStack(spacing: 0) {
                            ForEach(Array(wc.printers.enumerated()), id: \.element.id) { i, printer in
                                PrinterWatchCard(data: printer, index: i, total: count)
                                    .frame(width: g.size.width, height: g.size.height)
                            }
                        }
                        .offset(y: -CGFloat(selectedIndex) * g.size.height + verticalDrag)
                    }
                    .clipped()
                    .frame(width: w, height: h)
                    .focusable(!showFiles)
                    .digitalCrownRotation(
                        $crownValue,
                        from: 0, through: Double(max(0, count - 1)),
                        by: 1.0, sensitivity: .low,
                        isContinuous: false, isHapticFeedbackEnabled: true
                    )
                    .onChange(of: crownValue) { _, newVal in
                        guard !showFiles else { return }
                        let i = max(0, min(Int(newVal.rounded()), count - 1))
                        guard i != selectedIndex else { return }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { selectedIndex = i }
                    }

                    // Right: files for the selected printer
                    FilesView(
                        printerIndex: selectedIndex,
                        shouldLoad: showFiles,
                        onBack: {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { showFiles = false }
                        }
                    )
                    .frame(width: w, height: h)
                    // Forces a fresh FilesView (and fresh @State) whenever the printer changes
                    .id(selectedIndex)
                }
                .offset(x: showFiles ? -(w - horizontalDrag) : horizontalDrag)
                // Single unified gesture with direction lock — prevents getting stuck halfway
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .local)
                        .onChanged { v in
                            if dragDir == .none {
                                if abs(v.translation.height) > abs(v.translation.width) * 1.3 {
                                    dragDir = .vertical
                                } else if abs(v.translation.width) > abs(v.translation.height) * 1.3 {
                                    dragDir = .horizontal
                                }
                            }
                            switch dragDir {
                            case .vertical:
                                guard !showFiles else { break }
                                let raw = v.translation.height
                                let atTop    = selectedIndex == 0 && raw > 0
                                let atBottom = selectedIndex == count - 1 && raw < 0
                                verticalDrag = (atTop || atBottom) ? raw * 0.25 : raw
                            case .horizontal:
                                horizontalDrag = showFiles
                                    ? max(0, v.translation.width)
                                    : min(0, v.translation.width)
                            case .none:
                                break
                            }
                        }
                        .onEnded { v in
                            defer {
                                // Always reset — this is what prevents the "stuck halfway" bug
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                                    verticalDrag = 0
                                    horizontalDrag = 0
                                }
                                dragDir = .none
                            }
                            switch dragDir {
                            case .vertical:
                                guard !showFiles else { break }
                                let predicted = v.predictedEndTranslation.height
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                                    if v.translation.height < -35 || predicted < -70 {
                                        selectedIndex = min(selectedIndex + 1, count - 1)
                                    } else if v.translation.height > 35 || predicted > 70 {
                                        selectedIndex = max(selectedIndex - 1, 0)
                                    }
                                }
                                crownValue = Double(selectedIndex)
                            case .horizontal:
                                let predicted = v.predictedEndTranslation.width
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                    if showFiles {
                                        if horizontalDrag > 45 || predicted > 90 { showFiles = false }
                                    } else {
                                        if horizontalDrag < -45 || predicted < -90 { showFiles = true }
                                    }
                                }
                            case .none:
                                break
                            }
                        }
                )
            }
            // Fill the entire watch display including under the status bar
            .ignoresSafeArea()
        }
    }
}

// MARK: - Files View
struct FilesView: View {
    let printerIndex: Int
    let shouldLoad: Bool
    let onBack: () -> Void

    @State private var files: [WatchFileItem] = []
    @State private var isLoading = false
    @State private var loadError: String? = nil
    @State private var confirmFile: WatchFileItem? = nil
    @State private var showConfirm = false
    @State private var selectedFileIndex = 0
    @State private var fileCrownValue: Double = 0
    @State private var fileVerticalDrag: CGFloat = 0

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(lz(en: "Loading…", de: "Lade…", fr: "Chargement…", es: "Cargando…", pt: "Carregando…", it: "Caricamento…", zh: "加载中…"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if let err = loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24, weight: .light)).foregroundStyle(.orange)
                    Text(err)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(lz(en: "Retry", de: "Erneut", fr: "Réessayer", es: "Reintentar", pt: "Repetir", it: "Riprova", zh: "重试")) {
                        Task { loadError = nil; isLoading = true; await fetchFiles() }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.blue)
                }
                .padding(8)
            } else if files.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                    Text(lz(en: "No G-Code files", de: "Keine G-Code Dateien", fr: "Pas de fichiers G-Code", es: "Sin archivos G-Code", pt: "Nenhum arquivo G-Code", it: "Nessun file G-Code", zh: "没有 G-Code 文件"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(lz(en: "Refresh", de: "Aktualisieren", fr: "Actualiser", es: "Actualizar", pt: "Atualizar", it: "Aggiorna", zh: "刷新")) {
                        Task { isLoading = true; await fetchFiles() }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.blue)
                }
            } else {
                let count = files.count
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    VStack(spacing: 0) {
                        ForEach(Array(files.enumerated()), id: \.element.id) { i, file in
                            FileCardView(
                                file: file, index: i, total: count,
                                printerIndex: printerIndex,
                                onPlay: { confirmFile = file; showConfirm = true }
                            )
                            .frame(width: w, height: h)
                        }
                    }
                    .offset(y: -CGFloat(selectedFileIndex) * h + fileVerticalDrag)
                    .focusable(shouldLoad)
                    .digitalCrownRotation(
                        $fileCrownValue,
                        from: 0, through: Double(max(0, count - 1)),
                        by: 1.0, sensitivity: .low,
                        isContinuous: false, isHapticFeedbackEnabled: true
                    )
                    .onChange(of: fileCrownValue) { _, newVal in
                        // Require 75 % rotation past a detent before switching — feels less jumpy
                        let base = Double(selectedFileIndex)
                        let next: Int
                        if newVal >= base + 0.75 { next = min(selectedFileIndex + 1, count - 1) }
                        else if newVal <= base - 0.75 { next = max(selectedFileIndex - 1, 0) }
                        else { return }
                        guard next != selectedFileIndex else { return }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { selectedFileIndex = next }
                        fileCrownValue = Double(next)
                    }
                    .gesture(
                        DragGesture(minimumDistance: 8, coordinateSpace: .local)
                            .onChanged { v in
                                guard abs(v.translation.height) > abs(v.translation.width) * 1.3 else { return }
                                let raw = v.translation.height
                                let atTop = selectedFileIndex == 0 && raw > 0
                                let atBottom = selectedFileIndex == count - 1 && raw < 0
                                fileVerticalDrag = (atTop || atBottom) ? raw * 0.25 : raw
                            }
                            .onEnded { v in
                                defer {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { fileVerticalDrag = 0 }
                                }
                                guard abs(v.translation.height) > abs(v.translation.width) * 1.3 else { return }
                                let predicted = v.predictedEndTranslation.height
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                                    if v.translation.height < -35 || predicted < -70 {
                                        selectedFileIndex = min(selectedFileIndex + 1, count - 1)
                                    } else if v.translation.height > 35 || predicted > 70 {
                                        selectedFileIndex = max(selectedFileIndex - 1, 0)
                                    }
                                }
                                fileCrownValue = Double(selectedFileIndex)
                            }
                    )
                }
                .clipped()
            }
        }
        // Track both shouldLoad AND printerIndex so files reload when switching printers
        .task(id: "\(shouldLoad)-\(printerIndex)") {
            guard shouldLoad else { return }
            files = []; loadError = nil; isLoading = true
            selectedFileIndex = 0; fileCrownValue = 0
            await fetchFiles()
        }
        .alert(confirmFile.map { $0.displayName } ?? "", isPresented: $showConfirm) {
            Button(lz(en: "Yes", de: "Ja", fr: "Oui", es: "Sí", pt: "Sim", it: "Sì", zh: "是")) {
                if let f = confirmFile { startPrint(f) }
            }
            Button(lz(en: "No", de: "Nein", fr: "Non", es: "No", pt: "Não", it: "No", zh: "否"), role: .cancel) {}
        } message: {
            Text(lz(en: "Start print?", de: "Druck starten?", fr: "Lancer l'impression?", es: "¿Iniciar impresión?", pt: "Iniciar impressão?", it: "Avviare la stampa?", zh: "开始打印？"))
        }
    }

    private func resolvedConfig() -> WatchPrinterDirectConfig? {
        guard let defaults = UserDefaults(suiteName: "group.paxxmaker.u1"),
              let data = defaults.data(forKey: "watch_printer_configs"),
              let configs = try? JSONDecoder().decode([WatchPrinterDirectConfig].self, from: data)
        else { return nil }
        return configs.indices.contains(printerIndex) ? configs[printerIndex] : configs.first
    }

    // Simple Codable model for WCSession file transfer
    private struct FItem: Codable { var path: String; var modified: Double }

    private func fetchFiles() async {
        // Try via iPhone first — bypasses ATS and direct network restrictions on Watch
        if WCSession.default.isReachable, await fetchFilesViaPhone() { return }
        await fetchFilesDirectly()
    }

    private func fetchFilesViaPhone() async -> Bool {
        await withCheckedContinuation { cont in
            WCSession.default.sendMessage(
                ["requestFiles": true, "printerIndex": printerIndex],
                replyHandler: { reply in
                    guard let encoded = reply["files"] as? Data,
                          let items = try? JSONDecoder().decode([FItem].self, from: encoded) else {
                        cont.resume(returning: false); return
                    }
                    let watchFiles = items.map { WatchFileItem(path: $0.path, modified: $0.modified) }
                    Task { @MainActor in self.files = watchFiles; self.isLoading = false }
                    cont.resume(returning: true)
                },
                errorHandler: { _ in cont.resume(returning: false) }
            )
        }
    }

    private func fetchFilesDirectly() async {
        guard let cfg = resolvedConfig(), !cfg.baseURL.isEmpty, cfg.baseURL != "__demo__" else {
            await MainActor.run {
                isLoading = false
                loadError = lz(en: "No printer configured.\nOpen the iPhone app first.",
                               de: "Kein Drucker konfiguriert.\nBitte erst iPhone App öffnen.",
                               fr: "Aucune imprimante configurée.",
                               es: "Sin impresora configurada.",
                               pt: "Nenhuma impressora configurada.\nAbra primeiro o app do iPhone.",
                               it: "Nessuna stampante configurata.\nApri prima l'app iPhone.",
                               zh: "未配置打印机。\n请先打开 iPhone 应用。")
            }
            return
        }
        guard let url = URL(string: "\(cfg.baseURL)/server/files/list") else {
            await MainActor.run { isLoading = false }; return
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        if !cfg.apiKey.isEmpty { req.setValue(cfg.apiKey, forHTTPHeaderField: "X-Api-Key") }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["result"] as? [[String: Any]] else {
                await MainActor.run {
                    isLoading = false
                    loadError = lz(en: "Invalid server response", de: "Ungültige Serverantwort",
                                   fr: "Réponse invalide", es: "Respuesta inválida",
                                   pt: "Resposta inválida do servidor", it: "Risposta del server non valida", zh: "服务器响应无效")
                }
                return
            }
            let items = results.compactMap { d -> WatchFileItem? in
                guard let path = (d["path"] as? String) ?? (d["filename"] as? String) else { return nil }
                let ext = (path as NSString).pathExtension.lowercased()
                guard ext == "gcode" || ext == "gco" || ext == "g" else { return nil }
                return WatchFileItem(path: path, modified: d["modified"] as? Double ?? 0)
            }.sorted { $0.modified > $1.modified }
            await MainActor.run { files = Array(items.prefix(50)); isLoading = false }
        } catch {
            await MainActor.run { isLoading = false; loadError = lzTransport(error) }
        }
    }

    private func startPrint(_ file: WatchFileItem) {
        let filename = file.path.components(separatedBy: "/").last ?? file.path
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(
                ["startPrint": filename, "printerIndex": printerIndex],
                replyHandler: { _ in },
                errorHandler: { [self] _ in startPrintDirectly(filename: filename) }
            )
        } else {
            startPrintDirectly(filename: filename)
        }
    }

    private func startPrintDirectly(filename: String) {
        guard let cfg = resolvedConfig(),
              let url = URL(string: "\(cfg.baseURL)/printer/print/start") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !cfg.apiKey.isEmpty { req.setValue(cfg.apiKey, forHTTPHeaderField: "X-Api-Key") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["filename": filename])
        URLSession.shared.dataTask(with: req).resume()
    }
}

// MARK: - File Card (fullscreen single-file pager card)
struct FileCardView: View {
    let file: WatchFileItem
    let index: Int
    let total: Int
    let printerIndex: Int
    let onPlay: () -> Void

    @State private var thumbnail: CGImage? = nil
    @State private var estimatedTime: Int? = nil
    @State private var thumbLoading = true

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.13))
                    if let thumb = thumbnail {
                        Image(thumb, scale: 1.0, label: Text(""))
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if thumbLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 8)
                .padding(.top, 28)

                Spacer(minLength: 4)

                Text(file.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                HStack(spacing: 4) {
                    Text("\(index + 1)/\(total)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                    if let t = estimatedTime, t > 0 {
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.3))
                        Text(formatDuration(t))
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .padding(.top, 3)

                Spacer(minLength: 6)

                Button(action: onPlay) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(lz(en: "Start", de: "Starten", fr: "Démarrer", es: "Iniciar", pt: "Iniciar", it: "Avvia", zh: "开始"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(Color.green, in: RoundedRectangle(cornerRadius: 15))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18)
                .padding(.bottom, 6)
            }
        }
        .task(id: file.path) { await fetchMetadata() }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private func resolvedConfig() -> WatchPrinterDirectConfig? {
        guard let defaults = UserDefaults(suiteName: "group.paxxmaker.u1"),
              let data = defaults.data(forKey: "watch_printer_configs"),
              let configs = try? JSONDecoder().decode([WatchPrinterDirectConfig].self, from: data)
        else { return nil }
        return configs.indices.contains(printerIndex) ? configs[printerIndex] : configs.first
    }

    private func fetchMetadata() async {
        await MainActor.run { thumbLoading = true }
        defer { Task { @MainActor in thumbLoading = false } }
        // Prefer iPhone proxy — it's always on the same LAN as the printer
        if WCSession.default.isReachable, await fetchMetadataViaPhone() { return }
        await fetchMetadataDirect()
    }

    private func fetchMetadataViaPhone() async -> Bool {
        await withCheckedContinuation { cont in
            WCSession.default.sendMessage(
                ["requestThumbnail": file.path, "printerIndex": printerIndex],
                replyHandler: { reply in
                    var gotSomething = false
                    if let et = reply["estimatedTime"] as? Double, et > 0 {
                        Task { @MainActor in self.estimatedTime = Int(et) }
                        gotSomething = true
                    }
                    if let imgData = reply["thumbnailData"] as? Data,
                       let src = CGImageSourceCreateWithData(imgData as CFData, nil),
                       let cgImg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                        Task { @MainActor in self.thumbnail = cgImg }
                        gotSomething = true
                    }
                    cont.resume(returning: gotSomething)
                },
                errorHandler: { _ in cont.resume(returning: false) }
            )
        }
    }

    private func fetchMetadataDirect() async {
        guard let cfg = resolvedConfig(), !cfg.baseURL.isEmpty, cfg.baseURL != "__demo__" else { return }
        let encoded = file.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? file.path
        guard let metaURL = URL(string: "\(cfg.baseURL)/server/files/metadata?filename=\(encoded)") else { return }
        var metaReq = URLRequest(url: metaURL, timeoutInterval: 5)
        if !cfg.apiKey.isEmpty { metaReq.setValue(cfg.apiKey, forHTTPHeaderField: "X-Api-Key") }
        guard let (metaData, _) = try? await URLSession.shared.data(for: metaReq),
              let json = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
              let result = json["result"] as? [String: Any] else { return }

        if let et = result["estimated_time"] as? Double, et > 0 {
            await MainActor.run { estimatedTime = Int(et) }
        }

        guard let thumbs = result["thumbnails"] as? [[String: Any]],
              let largest = thumbs.max(by: { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) }),
              let relPath = largest["relative_path"] as? String else { return }

        let gcodeDir = (file.path as NSString).deletingLastPathComponent
        let fullPath = gcodeDir.isEmpty || gcodeDir == "." ? relPath : "\(gcodeDir)/\(relPath)"
        let pathEncoded = fullPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fullPath
        guard let imgURL = URL(string: "\(cfg.baseURL)/server/files/gcodes/\(pathEncoded)") else { return }
        var imgReq = URLRequest(url: imgURL, timeoutInterval: 5)
        if !cfg.apiKey.isEmpty { imgReq.setValue(cfg.apiKey, forHTTPHeaderField: "X-Api-Key") }
        guard let (imgData, _) = try? await URLSession.shared.data(for: imgReq),
              let src = CGImageSourceCreateWithData(imgData as CFData, nil),
              let cgImg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        await MainActor.run { thumbnail = cgImg }
    }
}

// MARK: - Printer Card
struct PrinterWatchCard: View {
    let data: WatchPrinterData
    let index: Int
    let total: Int

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [data.themeColor, data.themeColor.opacity(0.45)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            VStack(spacing: 4) {
                HStack(alignment: .center, spacing: 4) {
                    Text(data.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                    Spacer()
                    if total > 1 {
                        Text("\(index + 1)/\(total)")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.top, 10)
                    }
                    Circle()
                        .fill(data.stateColor)
                        .frame(width: 7, height: 7)
                        .shadow(color: data.stateColor.opacity(0.9), radius: data.isActive ? 4 : 0)
                        .padding(.top, 10)
                }

                Text(data.stateLabel)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 2)

                ZStack {
                    Circle().stroke(Color.white.opacity(0.2), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: CGFloat(data.progress))
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: .white.opacity(0.35), radius: 4)
                    VStack(spacing: 0) {
                        Text("\(Int(data.progress * 100))")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("%")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(width: 78, height: 78)

                Spacer(minLength: 2)

                if data.isActive && !data.shortFilename.isEmpty {
                    Text(data.shortFilename)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 0) {
                    Image(systemName: "flame.fill").font(.system(size: 9, weight: .semibold))
                    Text(" \(Int(data.extruderTemp))°").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Image(systemName: "square.fill").font(.system(size: 9, weight: .semibold))
                    Text(" \(Int(data.bedTemp))°").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))

                HStack {
                    if data.isActive && data.timeElapsed > 0 {
                        Text(data.formattedTime)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.leading, 10)
                    }
                    Spacer()
                    // Hint: swipe right to open files
                    HStack(spacing: 2) {
                        Image(systemName: "folder")
                            .font(.system(size: 8))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.28))
                    .padding(.trailing, 8)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 26)   // pushes content below the system clock
            .padding(.bottom, 7)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(WatchConnectivityManager())
}
