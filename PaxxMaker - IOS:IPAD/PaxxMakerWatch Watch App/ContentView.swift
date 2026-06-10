import SwiftUI
import Combine
import WatchConnectivity
import WidgetKit
import CoreGraphics
import ImageIO

private func lz(en: String, de: String, fr: String, es: String) -> String {
    let code = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
    switch code { case "de": return de; case "fr": return fr; case "es": return es; default: return en }
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
        case "printing": return lz(en: "Printing",   de: "Druckt",     fr: "Impression",  es: "Imprimiendo")
        case "paused":   return lz(en: "Paused",     de: "Pause",      fr: "Pause",       es: "Pausado")
        case "error":    return lz(en: "Error",      de: "Fehler",     fr: "Erreur",      es: "Error")
        case "complete": return lz(en: "Done",       de: "Fertig",     fr: "Terminé",     es: "Listo")
        case "standby":  return lz(en: "Ready",      de: "Bereit",     fr: "Prêt",        es: "Listo")
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
    @Published var printers: [WatchPrinterData] = []
    @Published var isLoading = true
    fileprivate private(set) var configs: [WatchPrinterDirectConfig] = []

    private var directPollTimer: Timer?
    private var lastWCUpdate: Date?
    private var phoneFallbackTask: Task<Void, Never>?

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        startDirectPolling()
        Task {
            await fetchDirect()
            await MainActor.run { isLoading = false }
        }
    }

    deinit { directPollTimer?.invalidate() }

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
        guard let raw = dict["printers"] as? Data,
              let decoded = try? JSONDecoder().decode([WatchPrinterData].self, from: raw)
        else { return }
        // Load configs from app group whenever they're missing (WCSession path doesn't set them)
        if configs.isEmpty,
           let defaults = UserDefaults(suiteName: "group.paxxmaker.u1"),
           let data = defaults.data(forKey: "watch_printer_configs"),
           let loaded = try? JSONDecoder().decode([WatchPrinterDirectConfig].self, from: data) {
            configs = loaded
        }
        DispatchQueue.main.async {
            self.lastWCUpdate = Date()
            self.printers = decoded
            self.writeComplicationData(decoded)
        }
    }

    // MARK: - Direct API polling

    private func startDirectPolling() {
        directPollTimer?.invalidate()
        directPollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.fetchDirectIfNeeded() }
        }
    }

    func refresh() {
        requestStatusFromPhone()
        Task { await fetchDirect() }
    }

    private func requestStatusFromPhone() {
        // Cancel any previous pending fallback
        phoneFallbackTask?.cancel()

        guard WCSession.default.activationState == .activated else {
            Task { await fetchDirect() }
            return
        }
        guard WCSession.default.isReachable else {
            // iPhone definitively unreachable — go straight to printer
            Task { await fetchDirect() }
            return
        }

        // Give the iPhone 10 s to reply; if it doesn't, poll the printer directly
        let fallback = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await self?.fetchDirect()
        }
        phoneFallbackTask = fallback

        WCSession.default.sendMessage(["requestStatus": true, "printerIndex": 0]) { [weak self] reply in
            fallback.cancel()
            self?.parse(reply)
            DispatchQueue.main.async { self?.isLoading = false }
        } errorHandler: { [weak self] _ in
            fallback.cancel()
            Task { await self?.fetchDirect() }
        }
    }

    private func fetchDirectIfNeeded() async {
        if let last = lastWCUpdate, -last.timeIntervalSinceNow < 90 { return }
        await fetchDirect()
    }

    private func fetchDirect() async {
        guard let defaults = UserDefaults(suiteName: "group.paxxmaker.u1"),
              let data = defaults.data(forKey: "watch_printer_configs"),
              let loadedConfigs = try? JSONDecoder().decode([WatchPrinterDirectConfig].self, from: data),
              !loadedConfigs.isEmpty
        else { return }

        self.configs = loadedConfigs

        var updated: [WatchPrinterData] = await withTaskGroup(of: WatchPrinterData?.self) { group in
            for config in loadedConfigs {
                group.addTask { await self.fetchPrinterStatus(config) }
            }
            var results: [WatchPrinterData] = []
            for await result in group { if let r = result { results.append(r) } }
            return results
        }

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

        // Keep polling every 30 s as long as no WC update arrived
        try? await Task.sleep(for: .seconds(30))
        await fetchDirectIfNeeded()
    }

    private func fetchPrinterStatus(_ config: WatchPrinterDirectConfig) async -> WatchPrinterData? {
        let query = "print_stats&display_status&extruder&heater_bed"
        guard let url = URL(string: "\(config.baseURL)/printer/objects/query?\(query)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 7)
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
        } catch { return nil }
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
                Text(lz(en: "Connecting…", de: "Verbinde…", fr: "Connexion…", es: "Conectando…"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } else if wc.printers.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "printer.slash")
                    .font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                Text(lz(en: "No printer\nreachable", de: "Kein Drucker\nerreichbar",
                        fr: "Imprimante\nindisponible", es: "Sin impresora"))
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
                    Text(lz(en: "Loading…", de: "Lade…", fr: "Chargement…", es: "Cargando…"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if let err = loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24, weight: .light)).foregroundStyle(.orange)
                    Text(err)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(lz(en: "Retry", de: "Erneut", fr: "Réessayer", es: "Reintentar")) {
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
                    Text(lz(en: "No G-Code files", de: "Keine G-Code Dateien", fr: "Pas de fichiers G-Code", es: "Sin archivos G-Code"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(lz(en: "Refresh", de: "Aktualisieren", fr: "Actualiser", es: "Actualizar")) {
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
            Button(lz(en: "Yes", de: "Ja", fr: "Oui", es: "Sí")) {
                if let f = confirmFile { startPrint(f) }
            }
            Button(lz(en: "No", de: "Nein", fr: "Non", es: "No"), role: .cancel) {}
        } message: {
            Text(lz(en: "Start print?", de: "Druck starten?", fr: "Lancer l'impression?", es: "¿Iniciar impresión?"))
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
                               es: "Sin impresora configurada.")
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
                                   fr: "Réponse invalide", es: "Respuesta inválida")
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
            await MainActor.run { isLoading = false; loadError = error.localizedDescription }
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
                        Text(lz(en: "Start", de: "Starten", fr: "Démarrer", es: "Iniciar"))
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
