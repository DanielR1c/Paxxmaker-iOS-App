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
import Security
#if canImport(CSSH)
import CSSH
#endif

// MARK: - SSH password storage (Keychain)
// The SSH password entered for a printer's auto-setup is needed again later
// (e.g. removing the bridge via SSH when switching to Local push) — store it
// in the Keychain, not UserDefaults, since it's a real credential.
enum SSHCredentialStore {
    private static let service = "com.paxxmaker.u1.sshpw"

    private static func query(for printerID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: printerID]
    }

    static func save(_ password: String, for printerID: String) {
        var q = query(for: printerID)
        SecItemDelete(q as CFDictionary)
        guard !password.isEmpty, let data = password.data(using: .utf8) else { return }
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load(for printerID: String) -> String? {
        var q = query(for: printerID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for printerID: String) {
        SecItemDelete(query(for: printerID) as CFDictionary)
    }
}

// The SSH username isn't secret, but it needs to be remembered alongside the
// password — standard Klipper hosts have a per-install username (auto-detected
// via Moonraker during setup, e.g. "Ender3S1"), not the fixed "pi" fallback.
// Without this, later SSH actions (like removing the bridge when switching to
// Local push) would authenticate as the wrong user even with the right password.
enum SSHUsernameStore {
    private static func key(_ printerID: String) -> String { "sshuser_\(printerID)" }
    static func save(_ user: String, for printerID: String) {
        if user.isEmpty { UserDefaults.standard.removeObject(forKey: key(printerID)) }
        else { UserDefaults.standard.set(user, forKey: key(printerID)) }
    }
    static func load(for printerID: String) -> String? {
        UserDefaults.standard.string(forKey: key(printerID))
    }
    static func delete(for printerID: String) {
        UserDefaults.standard.removeObject(forKey: key(printerID))
    }
}

// MARK: - SSH one-tap installer
// Connects to the printer over SSH (libssh2 via the CSSH prebuilt package) and
// runs the push-bridge installer / uninstaller — so the user doesn't have to
// open Terminal and paste commands.
//
// Why libssh2 and NOT swift-nio-ssh/Citadel: the Snapmaker U1 runs Dropbear,
// which only offers aes-ctr / chacha20-poly1305 ciphers. swift-nio-ssh only
// implements AES-GCM → no common cipher → connection always fails. libssh2
// speaks aes-ctr, so it connects (verified against the real printer).
//
// The feature is guarded by `#if canImport(CSSH)` so the project still builds
// WITHOUT the library. Package: https://github.com/migueldeicaza/Libssh2Prebuild.git
enum SSHInstallError: LocalizedError {
    case libraryMissing
    case connection(String)
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .libraryMissing:
            return "SSH library not installed. In Xcode: File → Add Package Dependencies → https://github.com/migueldeicaza/Libssh2Prebuild.git"
        case .connection(let m): return m
        case .failed(let m):     return m
        }
    }
}

enum SSHInstaller {
    // Let the printer fetch + run the installer itself via curl. We do NOT pipe
    // the script over SSH: Dropbear rejects long exec requests (the base64'd
    // installer is ~21 KB → "request denied"). A short `curl <url> | sh` command
    // stays well under the limit, and curl (unlike busybox wget) speaks HTTPS.
    // `curl` isn't in the non-interactive PATH on the U1, so we fall back to its
    // known absolute path.
    // `useSudo` is for standard Klipper hosts (MainsailOS/Debian etc.) where the
    // login user isn't root but needs root to write a systemd unit. The Snapmaker
    // U1 already logs in as root, so it keeps the plain (non-sudo) path.
    static func install(host: String, user: String, password: String,
                        workerURL: String, printerID: String, secret: String,
                        useSudo: Bool = false) async throws -> String {
        var comp = URLComponents(string: workerURL + "/install")
        comp?.queryItems = [
            URLQueryItem(name: "id", value: printerID),
            URLQueryItem(name: "secret", value: secret)
        ]
        guard let url = comp?.url?.absoluteString else { throw SSHInstallError.failed("Invalid worker URL") }
        let cmd = useSudo ? sudoRun(url, password: password) : curlPipe(url)
        return try await exec(host: host, user: user, password: password, command: cmd)
    }

    // Uninstall: the printer fetches + runs the /uninstall script the same way.
    static func uninstall(host: String, user: String, password: String,
                          workerURL: String, secret: String,
                          useSudo: Bool = false) async throws -> String {
        var comp = URLComponents(string: workerURL + "/uninstall")
        comp?.queryItems = [URLQueryItem(name: "secret", value: secret)]
        guard let url = comp?.url?.absoluteString else { throw SSHInstallError.failed("Invalid worker URL") }
        let cmd = useSudo ? sudoRun(url, password: password) : curlPipe(url)
        return try await exec(host: host, user: user, password: password, command: cmd)
    }

    private static func curlPipe(_ url: String) -> String {
        "C=$(command -v curl || echo /usr/local/bin/curl); \"$C\" -fsSL \"\(url)\" | sh"
    }

    // Download the installer to a temp file, then run it with `sudo -S`. We can't
    // pipe both the password (into sudo's stdin) and the script through the same
    // stream, so the script goes to a file and the password to stdin.
    private static func sudoRun(_ url: String, password: String) -> String {
        let pw = password.replacingOccurrences(of: "'", with: "'\\''")
        return "C=$(command -v curl || echo /usr/local/bin/curl); "
             + "\"$C\" -fsSL \"\(url)\" -o /tmp/pm_setup.sh && "
             + "printf '%s\\n' '\(pw)' | sudo -S sh /tmp/pm_setup.sh 2>&1; "
             + "rm -f /tmp/pm_setup.sh"
    }

    // Auto-detect the Linux login user from Moonraker (paths look like
    // /home/<user>/klipper). Saves the user from typing it for standard Klipper
    // printers whose username varies (pi, biqu, mks, the hostname, …).
    static func detectUsername(host: String) async -> String? {
        guard let url = URL(string: "http://\(host):7125/printer/info") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = obj["result"] as? [String: Any] else { return nil }
            for key in ["klipper_path", "python_path", "config_file", "log_file"] {
                if let p = result[key] as? String {
                    let comps = p.split(separator: "/")
                    if comps.count >= 2, comps[0] == "home" { return String(comps[1]) }
                }
            }
        } catch { }
        return nil
    }

    // Reads the push secret already installed on the printer (from the bridge
    // script). Lets a second device (iPad) adopt the same secret the printer
    // already reports with, so BOTH devices receive the push. Returns nil if the
    // printer isn't set up yet.
    static func readExistingSecret(host: String, user: String, password: String) async throws -> String? {
        // /home/*/printer_data deckt auch umbenannte/abweichende OS-User ab (nicht
        // nur das feste "lava" der U1) sowie Standard-Klipper-Hosts.
        let cmd = "for d in /home/lava/printer_data \"$HOME/printer_data\" /home/*/printer_data \"$HOME\"; do f=\"$d/paxxmaker_bridge.py\"; [ -f \"$f\" ] && { grep -m1 PAXX_SECRET \"$f\" | sed -n 's/.*\"PAXX_SECRET\"[^\"]*\"\\([^\"]*\\)\".*/\\1/p'; break; }; done"
        let out = try await exec(host: host, user: user, password: password, command: cmd)
        let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ignore the un-substituted template placeholder from the reference copy.
        return (s.isEmpty || s == "REPLACED-BY-INSTALLER") ? nil : s
    }

    // U1-only pre-check: without OctoEverywhere there is NO persistent autostart
    // hook on the paxx12 firmware (the rootfs is wiped every boot except /oem
    // and printer_data) — the bridge would only run until the next reboot.
    // Require OctoEverywhere before letting the installer run at all, instead
    // of quietly shipping a setup that silently stops working after a restart.
    static func checkOctoEverywhereInstalled(host: String, user: String, password: String) async throws -> Bool {
        let cmd = "[ -d /oem/apps/octoeverywhere ] && echo YES || echo NO"
        let out = try await exec(host: host, user: user, password: password, command: cmd)
        return out.trimmingCharacters(in: .whitespacesAndNewlines) == "YES"
    }

    // Self-heal: relaunch an already-installed bridge if it isn't running (e.g.
    // after a printer reboot on firmware without a persistent autostart hook).
    // Only touches an EXISTING install — never creates one. The bridge's flock
    // makes a redundant relaunch harmless. Returns "RUNNING"/"RELAUNCHED"/
    // "NOT_INSTALLED".
    @discardableResult
    static func ensureBridgeRunning(host: String, user: String, password: String) async throws -> String {
        let cmd = "P=$(command -v python3 || echo /usr/bin/python3); "
            + "for d in /home/lava/printer_data \"$HOME/printer_data\" /home/*/printer_data \"$HOME\"; do "
            + "f=\"$d/paxxmaker_bridge.py\"; [ -f \"$f\" ] || continue; "
            + "if pgrep -f paxxmaker_bridge.py >/dev/null 2>&1; then echo RUNNING; "
            + "else ( \"$P\" \"$f\" </dev/null >/dev/null 2>&1 & ); echo RELAUNCHED; fi; exit 0; done; "
            + "echo NOT_INSTALLED"
        let out = try await exec(host: host, user: user, password: password, command: cmd)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // libssh2 calls are blocking, so run them off the cooperative pool.
    private static func exec(host: String, user: String, password: String, command: String) async throws -> String {
        #if canImport(CSSH)
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do    { cont.resume(returning: try blockingExec(host: host, user: user, password: password, command: command)) }
                catch { cont.resume(throwing: error) }
            }
        }
        #else
        throw SSHInstallError.libraryMissing
        #endif
    }

    #if canImport(CSSH)
    private static let WIN_DEFAULT: UInt32 = 2 * 1024 * 1024
    private static let PKT_DEFAULT: UInt32 = 32768

    private static func tcpConnect(_ host: String, _ port: Int32) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else {
            throw SSHInstallError.connection("Printer not reachable (\(host)). Check Wi-Fi/VPN and the IP address.")
        }
        defer { freeaddrinfo(res) }
        var sock: Int32 = -1
        var p: UnsafeMutablePointer<addrinfo>? = info
        while let cur = p {
            sock = socket(cur.pointee.ai_family, cur.pointee.ai_socktype, cur.pointee.ai_protocol)
            if sock >= 0 {
                if connect(sock, cur.pointee.ai_addr, cur.pointee.ai_addrlen) == 0 { break }
                close(sock); sock = -1
            }
            p = cur.pointee.ai_next
        }
        guard sock >= 0 else {
            throw SSHInstallError.connection("Could not open a connection to the printer (\(host):\(port)).")
        }
        return sock
    }

    private static func blockingExec(host: String, user: String, password: String, command: String) throws -> String {
        guard libssh2_init(0) == 0 else { throw SSHInstallError.failed("libssh2 init failed") }
        defer { libssh2_exit() }

        let sock = try tcpConnect(host, 22)
        defer { close(sock) }

        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            throw SSHInstallError.failed("SSH session init failed")
        }
        libssh2_session_set_blocking(session, 1)
        defer {
            libssh2_session_disconnect_ex(session, 11 /* BY_APPLICATION */, "bye", "")
            libssh2_session_free(session)
        }

        guard libssh2_session_handshake(session, sock) == 0 else {
            // The host key rotates every boot, so we don't pin it (trusted LAN/VPN).
            throw SSHInstallError.connection("SSH handshake failed. Is the printer reachable and SSH enabled?")
        }
        guard libssh2_userauth_password_ex(session, user, UInt32(user.utf8.count),
                                           password, UInt32(password.utf8.count), nil) == 0 else {
            // Deliberately .failed, not .connection: the printer IS reachable,
            // only the credentials are wrong — callers use .connection to show
            // "printer not reachable", which would be misleading here.
            throw SSHInstallError.failed("SSH login failed — check the password (default for the U1 is \"snapmaker\").")
        }
        guard let channel = libssh2_channel_open_ex(session, "session", 7, WIN_DEFAULT, PKT_DEFAULT, nil, 0) else {
            throw SSHInstallError.failed("Could not open an SSH channel.")
        }
        defer { libssh2_channel_free(channel) }

        guard libssh2_channel_process_startup(channel, "exec", 4, command, UInt32(command.utf8.count)) == 0 else {
            throw SSHInstallError.failed("Could not start the command on the printer.")
        }

        var output = Data()
        var buf = [Int8](repeating: 0, count: 8192)
        for stream: Int32 in [0, 1] {   // 0 = stdout, 1 = stderr
            while true {
                let n = libssh2_channel_read_ex(channel, stream, &buf, buf.count)
                if n > 0 { buf.withUnsafeBytes { output.append($0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: Int(n)) } }
                else { break }
            }
        }
        libssh2_channel_close(channel)
        return String(decoding: output, as: UTF8.self)
    }
    #endif
}

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
        case .both:         return lz(en: "Both", de: "Beide", fr: "Les deux", es: "Ambos", pt: "Ambos", it: "Entrambi", zh: "两者")
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
        didSet { LanguageStore.publish(current) }
    }
    init() {
        current = UserDefaults.standard.string(forKey: "app_language") ?? "en"
        LanguageStore.publish(current, reloadWidgets: false)
    }

    // Widgets live in a separate process and can only see the shared app group,
    // so mirror the chosen language there (they'd otherwise fall back to the
    // system language and disagree with the app).
    static func publish(_ code: String, reloadWidgets: Bool = true) {
        UserDefaults.standard.set(code, forKey: "app_language")
        UserDefaults(suiteName: "group.paxxmaker.u1")?.set(code, forKey: "app_language")
        if reloadWidgets { WidgetCenter.shared.reloadAllTimelines() }
    }
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

func lz(en: String, de: String, fr: String, es: String, pt: String? = nil, it: String? = nil, zh: String? = nil) -> String {
    switch UserDefaults.standard.string(forKey: "app_language") ?? "en" {
    case "de": return de
    case "fr": return fr
    case "es": return es
    case "pt": return pt ?? en
    case "it": return it ?? en
    case "zh": return zh ?? en
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
        return t.isEmpty ? lz(en: "My Commands", de: "Eigene Befehle", fr: "Mes commandes", es: "Mis comandos", pt: "Meus Comandos", it: "I miei comandi", zh: "我的命令") : t
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
                name: lz(en: "Example: Klipper Macro", de: "Beispiel: Klipper Makro", fr: "Exemple: Macro Klipper", es: "Ejemplo: Macro Klipper", pt: "Exemplo: Macro Klipper", it: "Esempio: Macro Klipper", zh: "示例：Klipper 宏"),
                gcode: "MY_MACRO PARAM=value",
                printerTarget: .both, colorHex: "8B5CF6", sfSymbol: "terminal.fill"),
            CustomCommand(
                name: lz(en: "Example: Console Command", de: "Beispiel: Konsolenbefehl", fr: "Exemple: Commande console", es: "Ejemplo: Comando consola", pt: "Exemplo: Comando de console", it: "Esempio: Comando console", zh: "示例：控制台命令"),
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
    // Rotates ONLY the <video> element inside the page (not buttons/controls) —
    // used for the manual camera rotation of WebRTC streams.
    var videoRotation: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func applyVideoRotation(_ webView: WKWebView, degrees: Int) {
        let deg = ((degrees % 360) + 360) % 360
        let odd = deg % 180 != 0
        // 16:9 tile: a 90°/270° video must shrink to fit its swapped axes
        let scale = odd ? " scale(0.5625)" : ""
        // The visible player UI ("Liveübertragung", AirPlay, pause …) are
        // WebKit's NATIVE video controls — they are glued to the <video>
        // element and would rotate along with it. So while a rotation is
        // active we hide the controls and keep the stream playing; without
        // rotation everything stays stock.
        let css = deg == 0 ? "" :
            "video{transform:rotate(\(deg)deg)\(scale) !important;}" +
            "video::-webkit-media-controls{display:none !important;}"
        let js = """
        (function(){
            var st = document.getElementById('pm-video-rot');
            if (!st) { st = document.createElement('style'); st.id = 'pm-video-rot'; document.head.appendChild(st); }
            st.textContent = '\(css)';
            window.__pmApplyRot = function(){
                document.querySelectorAll('video').forEach(function(v){
                    if (\(deg) === 0) { v.controls = true; }
                    else {
                        v.controls = false;
                        v.muted = true;
                        v.setAttribute('playsinline','');
                    }
                });
            };
            // Rotated video: the native controls are hidden (they'd rotate along
            // with the video), so provide an upright replacement — tapping the
            // video toggles play/pause, a centered play icon shows while paused.
            var ctl = document.getElementById('pm-ctl');
            if (\(deg) === 0) {
                if (ctl) { ctl.remove(); }
            } else if (!ctl) {
                ctl = document.createElement('div');
                ctl.id = 'pm-ctl';
                ctl.style.cssText = 'position:fixed;top:0;left:0;right:0;bottom:0;display:flex;align-items:center;justify-content:center;z-index:2147483647;cursor:pointer;background:transparent';
                ctl.innerHTML = '<div id="pm-ctl-ico" style="width:64px;height:64px;border-radius:50%;background:rgba(0,0,0,.55);display:none;align-items:center;justify-content:center;pointer-events:none"><svg width="28" height="28" viewBox="0 0 24 24" fill="white"><path d="M8 5v14l11-7z"/></svg></div>';
                document.body.appendChild(ctl);
                var upd = function(){
                    var v = document.querySelector('video');
                    var ico = document.getElementById('pm-ctl-ico');
                    if (!v || !ico) return;
                    ico.style.display = v.paused ? 'flex' : 'none';
                };
                ctl.addEventListener('click', function(){
                    var v = document.querySelector('video');
                    if (!v) return;
                    if (v.paused) { v.play().catch(function(){}); } else { v.pause(); }
                    setTimeout(upd, 60);
                });
                document.addEventListener('play', upd, true);
                document.addEventListener('pause', upd, true);
                setInterval(upd, 1000);
            }
            // WebRTC players attach their <video> after page load — re-apply
            // whenever the DOM changes.
            if (!window.__pmRotObs) {
                window.__pmRotObs = new MutationObserver(function(){ window.__pmApplyRot(); });
                window.__pmRotObs.observe(document.documentElement, {childList: true, subtree: true});
            }
            window.__pmApplyRot();
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

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
        context.coordinator.videoRotation = videoRotation
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only reload if the URL actually changed to avoid interrupting WebRTC streams
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            webView.load(URLRequest(url: url))
        }
        if context.coordinator.videoRotation != videoRotation {
            context.coordinator.videoRotation = videoRotation
            WebView.applyVideoRotation(webView, degrees: videoRotation)
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?
        var videoRotation: Int = 0

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Re-apply the video-only rotation after every page load
            if videoRotation != 0 {
                WebView.applyVideoRotation(webView, degrees: videoRotation)
            }
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
struct PrinterWidgetEntryData: Codable {
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

// Codable snapshot of a slot for the per-printer offline cache (Color itself
// isn't Codable — colorHex is enough to rebuild it).
struct SlotCache: Codable {
    let id: Int
    let colorHex: String
    let material: String
    let detected: Bool
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
    } {
        // Cache the slots so the "Spools" tile keeps its last content offline /
        // at launch (fetches never reset on failure, only on real responses).
        didSet {
            let cache = filamentSlots.map { SlotCache(id: $0.id, colorHex: $0.colorHex, material: $0.material, detected: $0.detected) }
            if let data = try? JSONEncoder().encode(cache) { UserDefaults.standard.set(data, forKey: "slots_\(name)") }
        }
    }
    @Published var nozzleDiameters: [Double] = [0.4, 0.4, 0.4, 0.4]
    @Published var nozzleDiametersLoaded: [Bool] = [false, false, false, false]
    @Published var switchCounts: [Int] = [0, 0, 0, 0]
    @Published var activeExtruderIndex: Int = -1
    // Temperature of the nozzle currently in use. Falls back to the first nozzle
    // (or the hottest, if none is flagged active) so widget/Live Activity never
    // show a cold idle nozzle while another one is doing the printing.
    var activeExtruderTemp: Double {
        if activeExtruderIndex >= 0, let t = extruderTemps[safe: activeExtruderIndex] { return t }
        return extruderTemps.max() ?? extruderTemps.first ?? 0
    }
    @Published var isOnline: Bool = false
    // True when the shown status comes from the Live Activity push (printer LAN
    // unreachable), not a live LAN connection — used to hide the "LIVE" badge.
    @Published var isViaLiveActivity: Bool = false
    // Spoolman (via Moonraker) — set when the printer's Moonraker has the
    // [spoolman] component connected; activeSpoolId is the spool it deducts from.
    // Cached per printer: once Spoolman has been seen, the tile keeps showing
    // (even offline / at launch). It only hides again when a live connection
    // reports no Spoolman (a 404), never on a mere network failure.
    // paxx12 >= 1.5.x owns the spool assignment itself (Moonraker component
    // "spoollink"): it exposes print_task_config.filament_spool_id per slot and
    // deliberately clears Moonraker's single active spool right after it is set.
    // Detected by FEATURE, not version, so it also holds for future builds.
    @Published var fwSpoolLink: Bool = false {
        didSet { UserDefaults.standard.set(fwSpoolLink, forKey: "fw_spoollink_\(name)") }
    }
    @Published var fwSlotSpoolIds: [Int] = [0, 0, 0, 0]   // 0 = unassigned
    // paxx12's own "Filament Manager" page (/filament/). Its presence is what
    // unlocks the Spoollink screen in the app.
    @Published var spoollinkAvailable: Bool = false {
        didSet {
            UserDefaults.standard.set(spoollinkAvailable, forKey: "spoollink_avail_\(name)")
        }
    }
    // False only when the printer's command list was read and SET_SPOOL_ID is
    // missing (filament tag detection switched off in the firmware config).
    @Published var spoollinkCommandsReady: Bool = true
    @Published var slotCardUIDs: [String] = ["", "", "", ""]   // RFID card UID per channel
    @Published var slotMaterials: [String] = ["", "", "", ""]
    @Published var slotVendors: [String] = ["", "", "", ""]
    @Published var slotColorHexes: [String] = ["", "", "", ""]   // RRGGBB per channel
    @Published var slotSubtypes: [String] = ["", "", "", ""]
    // What the RFID tag itself reports (may differ from the loaded config).
    @Published var tagVendors: [String] = ["", "", "", ""]
    @Published var tagTypes: [String] = ["", "", "", ""]
    @Published var tagSubtypes: [String] = ["", "", "", ""]
    @Published var tagColorHexes: [String] = ["", "", "", ""]
    @Published var tagTempMin: [Int] = [0, 0, 0, 0]
    @Published var tagTempMax: [Int] = [0, 0, 0, 0]
    // card UID -> Spoolman spool id. The UID travels with the physical spool, so
    // this is what lets an assignment follow when spools/tags are swapped. Kept
    // in the service (not a view) so tracking stays correct with the UI closed.
    private var spoolCardIndex: [String: Int] = [:]

    func refreshSpoolCardIndex() {
        let host = UserDefaults.standard.string(forKey: "spoolman_url") ?? ""
        guard !host.isEmpty, let svc = SpoolmanService(rawHost: host) else { return }
        Task { [weak self] in
            guard let list = try? await svc.spools(includeArchived: false) else { return }
            var map: [String: Int] = [:]
            for sp in list { for uid in sp.cardUIDs { map[uid] = sp.id } }
            await MainActor.run {
                guard let self else { return }
                self.spoolCardIndex = map
                self.resolveSlotAssignments()
            }
        }
    }

    /// A choice the USER made — from the nozzle list or from Spoollink. Besides
    /// the mapping it moves the nozzle's RFID tag onto the chosen spool, so the
    /// tag can't point at the old one and silently revert the change on the next
    /// resolve. That makes both screens overwrite each other symmetrically.
    func assignSpoolManually(channel ch: Int, spoolId: Int?) {
        assignSpool(channel: ch, spoolId: spoolId)
        let uid = (slotCardUIDs[safe: ch] ?? "").uppercased()
        guard !uid.isEmpty else { return }
        relinkCardUID(uid, to: spoolId, channel: ch)
    }

    /// spoollink keeps a copy of the resolved spool per card UID in
    /// extended/spoollink/<UID>.json and reads THAT instead of asking Spoolman
    /// again. Without rewriting it, a re-assignment stays invisible to the
    /// printer — which is why a tag could only be pointed at one spool.
    func syncSpoollinkCache(uid: String, spoolId: Int?) async {
        let name = uid.uppercased() + ".json"
        guard let spoolId else {
            _ = await deleteConfigFile(path: "extended/spoollink", filename: name)
            return
        }
        var host = UserDefaults.standard.string(forKey: "spoolman_url") ?? ""
        guard !host.isEmpty else { return }
        if !host.hasPrefix("http") { host = "http://" + host }
        guard let url = URL(string: "\(host)/api/v1/spool/\(spoolId)"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
        _ = await uploadConfigFile(path: "extended/spoollink", filename: name, data: data)
    }

    private func uploadConfigFile(path: String, filename: String, data: Data) async -> Bool {
        guard let url = URL(string: "\(baseURL)/server/files/upload") else { return false }
        let boundary = "----paxx\(UUID().uuidString)"
        var req = URLRequest(url: url, timeoutInterval: 25); req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        var body = Data()
        func field(_ n: String, _ v: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(n)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(v)\r\n".data(using: .utf8)!)
        }
        field("root", "config")
        field("path", path)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return code == 200 || code == 201
    }

    private func deleteConfigFile(path: String, filename: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/server/files/config/\(path)/\(filename)") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 12); req.httpMethod = "DELETE"
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return code == 200 || code == 204
    }

    /// Make `uid` belong to exactly one spool: remove it everywhere else, add it
    /// to the target. Keeps other UIDs on those spools intact.
    private func relinkCardUID(_ uid: String, to spoolId: Int?, channel: Int? = nil) {
        let host = UserDefaults.standard.string(forKey: "spoolman_url") ?? ""
        guard !host.isEmpty, let svc = SpoolmanService(rawHost: host) else { return }
        Task { [weak self] in
            guard let list = try? await svc.spools(includeArchived: false) else { return }
            func store(_ id: Int, _ uids: [String]) async {
                _ = try? await svc.updateSpool(id, ["extra": ["card_uids": "\"\(uids.joined(separator: ","))\""]])
            }
            for sp in list where sp.cardUIDs.contains(uid) && sp.id != spoolId {
                await store(sp.id, sp.cardUIDs.filter { $0 != uid })
            }
            if let target = spoolId, let sp = list.first(where: { $0.id == target }),
               !sp.cardUIDs.contains(uid) {
                await store(target, sp.cardUIDs + [uid])
            }
            // Rewrite the printer's own cache for this UID, otherwise it keeps
            // resolving the tag to the previous spool.
            await self?.syncSpoollinkCache(uid: uid, spoolId: spoolId)
            await MainActor.run {
                self?.refreshSpoolCardIndex()
                // Rewriting the tag link and the cache is not enough on its own:
                // SpoolLink only writes Klipper's filament_spool_id when it
                // resolves a tag, so ask it to read that channel's tag again.
                // Otherwise Klipper keeps reporting "no spool" while the app
                // already shows the new one. Skipped mid-print — re-reading the
                // tags is not something to do while the printer is running.
                if let self, let ch = channel, self.printState != "printing" {
                    self.spoollinkReadTags(channel: ch)
                }
            }
        }
    }

    /// Single source of truth for "which spool sits on which nozzle":
    ///  1. the spool its RFID tag belongs to — the tag travels with the spool,
    ///  2. otherwise the firmware's own assignment,
    ///  3. otherwise whatever was set by hand.
    /// The result is written to BOTH our hook mapping and the firmware, so the
    /// two can't drift apart and end up deducting from the wrong spool.
    func resolveSlotAssignments() {
        for ch in 0..<4 {
            let uid = (slotCardUIDs[safe: ch] ?? "").uppercased()
            var want: Int? = nil
            if !uid.isEmpty, let byTag = spoolCardIndex[uid] {
                want = byTag
            } else if let fw = fwSlotSpoolIds[safe: ch], fw > 0 {
                want = fw
            }
            guard let want else { continue }
            if (mcSlotSpools[safe: ch] ?? -1) != want { setSlotSpool(ch, want) }
            if spoollinkCommandsReady, (fwSlotSpoolIds[safe: ch] ?? 0) != want {
                spoollinkAssign(channel: ch, spoolId: want)
            }
        }
    }

    /// True when a tag was read for that channel and it disagrees with what the
    /// printer currently has loaded (vendor / type / subtype / colour).
    func tagMismatch(_ i: Int) -> Bool {
        guard let t = tagTypes[safe: i], let v = tagVendors[safe: i],
              !(t.isEmpty && v.isEmpty) else { return false }
        func differs(_ a: String?, _ b: String?) -> Bool {
            guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
            return a.caseInsensitiveCompare(b) != .orderedSame
        }
        return differs(v, slotVendors[safe: i])
            || differs(t, slotMaterials[safe: i])
            || differs(tagSubtypes[safe: i], slotSubtypes[safe: i])
            || differs(tagColorHexes[safe: i], slotColorHexes[safe: i])
    }

    /// Remembers which tag state was already pushed per channel, so a tag the
    /// printer refuses to take over is applied ONCE and not on every poll.
    private var autoAppliedTagSig = ["", "", "", ""]

    /// A tag that disagrees with the printer's loaded filament is applied by
    /// itself — the same thing the "Apply tag to printer" button does. Skipped
    /// while printing: rewriting the loaded filament config mid-job is not safe.
    private func autoApplyTagMismatches() {
        guard fwSpoolLink, printState != "printing" else { return }
        for ch in 0..<4 {
            let sig = [tagVendors[safe: ch] ?? "", tagTypes[safe: ch] ?? "",
                       tagSubtypes[safe: ch] ?? "", tagColorHexes[safe: ch] ?? ""]
                        .joined(separator: "|")
            guard tagMismatch(ch) else {
                // In sync again — forget it, so a later mismatch is applied too.
                autoAppliedTagSig[ch] = ""
                continue
            }
            guard autoAppliedTagSig[ch] != sig else { continue }
            autoAppliedTagSig[ch] = sig
            applyTagToPrinter(channel: ch)
        }
    }

    /// Push the tag's own values into the printer's loaded configuration —
    /// the app-side equivalent of the web UI's "Apply RFID to Printer".
    func applyTagToPrinter(channel i: Int) {
        guard (0..<4).contains(i) else { return }
        let vendor = (tagVendors[safe: i] ?? "").isEmpty ? "Generic" : tagVendors[i]
        let type = tagTypes[safe: i] ?? ""
        guard !type.isEmpty else { return }
        let sub = tagSubtypes[safe: i] ?? ""
        let color = tagColorHexes[safe: i] ?? ""
        var parts = ["SET_PRINT_FILAMENT_CONFIG",
                     "CONFIG_EXTRUDER=\(i)",
                     "VENDOR=\"\(vendor)\"",
                     "FILAMENT_TYPE=\(type)",
                     "FILAMENT_SUBTYPE=\"\(sub)\""]
        parts.append("COLOR_NUMS=\(color.isEmpty ? 0 : 1)")
        parts.append("COLORS=\(color)")
        parts.append(contentsOf: ["MULTI_MODE=0", "ALPHA=255", "FORCE=1"])
        sendGCode(parts.joined(separator: " "))
        scheduleSpoollinkRefresh()
    }

    // What the "Active Spool" tile should show.
    // Old firmware: Moonraker's active spool. New firmware: the spool of the
    // currently active nozzle — the firmware's own assignment if it has one
    // (RFID-tagged spools), otherwise our per-nozzle mapping.
    // The one place that decides which spool sits on a nozzle. Every view has to
    // go through this — a second, differently ordered lookup elsewhere is what
    // made the colours flip back and forth between polls.
    // resolveSlotAssignments() already weighed tag > firmware > manual and wrote
    // the answer into mcSlotSpools, so that is the truth; the firmware value is
    // only a fallback, otherwise its stale entry resurfaces after a re-link.
    func resolvedSpoolId(forChannel ch: Int) -> Int? {
        if let own = mcSlotSpools[safe: ch], own > 0 { return own }
        if let fw = fwSlotSpoolIds[safe: ch], fw > 0 { return fw }
        return nil
    }

    var effectiveActiveSpoolId: Int? {
        guard fwSpoolLink else { return activeSpoolId }
        return resolvedSpoolId(forChannel: max(0, activeExtruderIndex))
    }

    @Published var spoolmanConnected: Bool = false {
        didSet { UserDefaults.standard.set(spoolmanConnected, forKey: "spoolman_connected_\(name)") }
    }
    @Published var activeSpoolId: Int? = nil
    // 4-color Spoolman auto-tracking hook (U1 / multi-nozzle only). The hook is
    // a Klipper delayed_gcode watcher (extended/klipper/spoolman_multicolor.cfg)
    // that switches the active Spoolman spool to match the active nozzle.
    @Published var mcHookInstalled: Bool = false   // _SPOOLMAN_MAP macro present
    @Published var mcAutoTracking: Bool = false    // watcher enabled flag
    @Published var mcSlotSpools: [Int] = [-1, -1, -1, -1]  // spool id per nozzle
    @Published var mcBusy: Bool = false            // install/remove in progress
    @Published var mcStatusMsg: String? = nil      // last install/remove message
    @Published var lastSeenDate: Date? = nil
    @Published var printTimeRemaining: Int = 0
    @Published var extruderTempHistories: [[Double]] = Array(repeating: [], count: 4)
    @Published var bedTempHistory: [Double] = []
    var apiKey: String = ""
    var themeHex: String = "0A84FF"
    var printerType: PrinterConfig.PrinterType = .snapmakerU1
    @Published var singleNozzleFilamentColorHex: String = "FF8800"
    // Persisted like spoolmanConnected: the tile keeps its last known visibility
    // while the printer is unreachable, and only a live answer changes it.
    @Published var webcamConfigured: Bool = true {
        didSet { UserDefaults.standard.set(webcamConfigured, forKey: "tilevis_cam_\(name)") }
    }
    @Published var webcamStreamURL: URL?
    @Published var webcamRotation: Int = 0
    @Published var webcamMirrorH: Bool = false
    @Published var webcamMirrorV: Bool = false
    @Published var webcam2StreamURL: URL? {
        didSet {
            let k = "tilevis_cam2_\(name)"
            if let u = webcam2StreamURL { UserDefaults.standard.set(u.absoluteString, forKey: k) }
            else { UserDefaults.standard.removeObject(forKey: k) }
        }
    }
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

    // Manual camera rotation: preferably stored ON THE PRINTER via Moonraker's
    // webcam API (then Fluidd/Mainsail show it the same way). Webcams sourced
    // from a config file (e.g. the U1's) are read-only there — those fall back
    // to a local per-app rotation. Both are applied on top of each other.
    @Published var webcamUserRotation: Int = 0
    @Published var webcam2UserRotation: Int = 0
    var webcamName = ""
    var webcam2Name = ""

    func loadUserCamRotations() {
        // Manual rotation is a single-nozzle feature — clear any leftover
        // value on the U1 so its stream always shows unrotated.
        guard printerType == .singleNozzle else {
            webcamUserRotation = 0; webcam2UserRotation = 0
            UserDefaults.standard.removeObject(forKey: "camUserRot1_\(name)")
            UserDefaults.standard.removeObject(forKey: "camUserRot2_\(name)")
            return
        }
        webcamUserRotation  = UserDefaults.standard.integer(forKey: "camUserRot1_\(name)")
        webcam2UserRotation = UserDefaults.standard.integer(forKey: "camUserRot2_\(name)")
    }

    func rotateCamera(_ cam: Int) {
        let camName = cam == 2 ? webcam2Name : webcamName
        let mrRot   = cam == 2 ? webcam2Rotation : webcamRotation
        let usrRot  = cam == 2 ? webcam2UserRotation : webcamUserRotation
        let newRot  = (mrRot + usrRot + 90) % 360

        // Local fallback: for read-only (config-sourced) webcams that reject
        // writes. Adds 90° on top of whatever the printer reports, per printer.
        func fallbackLocal() {
            DispatchQueue.main.async {
                if cam == 2 {
                    self.webcam2UserRotation = (self.webcam2UserRotation + 90) % 360
                    UserDefaults.standard.set(self.webcam2UserRotation, forKey: "camUserRot2_\(self.name)")
                } else {
                    self.webcamUserRotation = (self.webcamUserRotation + 90) % 360
                    UserDefaults.standard.set(self.webcamUserRotation, forKey: "camUserRot1_\(self.name)")
                }
            }
        }

        // Adopt an authoritative server value and clear the local offset, so the
        // two can never stack into a wrong (e.g. upside-down) angle.
        func adoptServer(_ rot: Int) {
            DispatchQueue.main.async {
                if cam == 2 {
                    self.webcam2Rotation = rot
                    self.webcam2UserRotation = 0
                    UserDefaults.standard.set(0, forKey: "camUserRot2_\(self.name)")
                } else {
                    self.webcamRotation = rot
                    self.webcamUserRotation = 0
                    UserDefaults.standard.set(0, forKey: "camUserRot1_\(self.name)")
                }
            }
        }

        // Ambiguous result (timeout / no HTTP / 5xx): the printer may or may not
        // have applied the write. Re-read the list and trust the printer — adopt
        // its value if it took the change, else a single local step. This is what
        // prevents the double-apply that flipped the image upside down.
        func reconcile() {
            guard let listURL = URL(string: "\(baseURL)/server/webcams/list") else { fallbackLocal(); return }
            var greq = URLRequest(url: listURL, timeoutInterval: 8)
            if !apiKey.isEmpty { greq.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
            URLSession.shared.dataTask(with: greq) { [weak self] data, _, _ in
                guard let self else { return }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = json["result"] as? [String: Any],
                      let cams = result["webcams"] as? [[String: Any]],
                      let entry = cams.first(where: { ($0["name"] as? String) == camName }),
                      let serverRot = entry["rotation"] as? Int else {
                    fallbackLocal(); return
                }
                if serverRot == newRot { adoptServer(serverRot) } else { fallbackLocal() }
            }.resume()
        }

        guard !isDemoMode, !camName.isEmpty,
              let url = URL(string: "\(baseURL)/server/webcams/item") else { fallbackLocal(); return }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": camName, "rotation": newRot])
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, err in
            guard let self else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode
            if err == nil, code == 200 {
                adoptServer(newRot)                       // stored on the printer
            } else if let code, (400..<500).contains(code) {
                fallbackLocal()                           // definitively rejected → read-only cam
            } else {
                reconcile()                               // timeout / 5xx / no HTTP → verify, don't double
            }
        }.resume()
    }

    private var timer: Timer?
    // Independent from the adaptive status `timer` (which gets replaced whenever
    // the poll interval changes) so a Spoolman spool change made externally
    // (Fluidd/Klipper) always auto-refreshes at a steady ~3 s.
    private var spoolTimer: Timer?
    private var laObserverTask: Task<Void, Never>?
    private var laObserverActivityID: String?
    private var filamentPollTick: Int = 0
    private var spoolmanRecheckTick: Int = 0
    private var mcHookPollTick: Int = 0
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
        // Restore last known Spoolman availability so the tile survives offline
        // starts; a live 404 will clear it again.
        self.spoolmanConnected = UserDefaults.standard.bool(forKey: "spoolman_connected_\(name)")
        self.fwSpoolLink = UserDefaults.standard.bool(forKey: "fw_spoollink_\(name)")
        self.spoollinkAvailable = UserDefaults.standard.bool(forKey: "spoollink_avail_\(name)")
        // Same for the other conditionally-visible tiles, so the dashboard keeps
        // its shape until the printer answers again.
        if let camVis = UserDefaults.standard.object(forKey: "tilevis_cam_\(name)") as? Bool {
            self.webcamConfigured = camVis
        }
        if let cam2 = UserDefaults.standard.string(forKey: "tilevis_cam2_\(name)") {
            self.webcam2StreamURL = URL(string: cam2)
        }
        // Restore cached statistics + filament slots so those tiles show the last
        // known values offline / at launch instead of "no data" / empty slots.
        let ud = UserDefaults.standard
        self.totalJobs = ud.integer(forKey: "stats_jobs_\(name)")
        self.totalPrintTime = ud.double(forKey: "stats_time_\(name)")
        self.totalFilamentUsedMm = ud.double(forKey: "stats_fil_\(name)")
        self.longestPrintTime = ud.double(forKey: "stats_longest_\(name)")
        if let data = ud.data(forKey: "slots_\(name)"),
           let cache = try? JSONDecoder().decode([SlotCache].self, from: data), cache.count == 4 {
            self.filamentSlots = cache.map {
                FilamentSlot(id: $0.id, color: Color(hex: $0.colorHex) ?? .gray,
                             colorHex: $0.colorHex, material: $0.material, detected: $0.detected)
            }
        }
        loadUserCamRotations()
        startPolling()
    }
    deinit { timer?.invalidate(); spoolTimer?.invalidate(); laObserverTask?.cancel() }

    var offlineSinceLabel: String {
        guard let date = lastSeenDate else {
            return lz(en: "Offline", de: "Offline", fr: "Hors ligne", es: "Sin conexión", pt: "Offline", it: "Offline", zh: "离线")
        }
        let s = Int(-date.timeIntervalSinceNow)
        if s < 10 { return lz(en: "just now", de: "gerade eben", fr: "à l'instant", es: "ahora", pt: "agora mesmo", it: "proprio ora", zh: "刚刚") }
        if s < 60 { return "\(s)s" }
        let m = s / 60
        return m < 60 ? "\(m)m" : "\(m/60)h \(m%60)m"
    }

    var isDemoMode: Bool { baseURL == "__demo__" }

    /// True when the printer is busy and shouldn't receive new commands.
    var isBusy: Bool { printState == "printing" || isGCodeRunning }

    func startPolling() {
        timer?.invalidate()
        spoolTimer?.invalidate()
        registerInWidgetList()
        if isDemoMode {
            loadDemoData()
            return
        }
        fetchStatus()
        fetchHistoryTotals()
        fetchSpoolmanStatus()
        if printerType == .snapmakerU1 { fetchSpoollinkAvailability() }
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
            self.filamentPollTick += 1
            if self.printerType == .snapmakerU1 {
                self.fetchU1ExtendedStatus()
                if self.filamentPollTick % 10 == 0 { self.fetchFilamentSlots() }
            }
        }
        // Dedicated, steady Spoolman poll. Kept separate from `timer` because
        // fetchStatus() swaps `timer` out whenever the poll interval changes
        // (1 s printing / 8 s idle); a spool change made externally in
        // Fluidd/Klipper must still show up within ~3 s regardless.
        spoolTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.spoolmanConnected { self.fetchSpoolmanStatus() }
            else { self.spoolmanRecheckTick += 1
                   if self.spoolmanRecheckTick % 20 == 0 { self.fetchSpoolmanStatus() } }
            // 4-color hook status (U1) — infrequent; reflects external changes
            // and re-applies the saved mapping after a Klipper restart.
            if self.printerType == .snapmakerU1 {
                self.mcHookPollTick += 1
                if self.spoolmanConnected && self.mcHookPollTick % 10 == 1 { self.fetchMultiColorHook() }
                // /filament/ presence + per-channel state, checked rarely.
                if self.mcHookPollTick % 20 == 1 {
                    self.fetchSpoollinkAvailability()
                    if self.spoollinkAvailable {
                        self.fetchSpoollinkState()
                        self.refreshSpoolCardIndex()
                    }
                }
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

    // Poll Moonraker's Spoolman component: is it connected, and which spool is
    // active. 404 = [spoolman] not configured on this printer → hide the tile.
    func fetchSpoolmanStatus() {
        guard !isDemoMode, let url = URL(string: "\(baseURL)/server/spoolman/status") else { return }
        var req = URLRequest(url: url, timeoutInterval: 6)
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            // A 404 means Moonraker has no [spoolman] component — but proxies
            // (e.g. OctoEverywhere) also answer 404 while the printer is offline.
            // Only trust it when the normal status poll says we're connected.
            if (resp as? HTTPURLResponse)?.statusCode == 404 {
                DispatchQueue.main.async {
                    if self.isOnline { self.updateIfChanged(\.spoolmanConnected, false) }
                }
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any] else { return }
            let connected = result["spoolman_connected"] as? Bool ?? false
            let spoolId = result["spool_id"] as? Int
            DispatchQueue.main.async {
                self.updateIfChanged(\.spoolmanConnected, connected)
                self.updateIfChanged(\.activeSpoolId, spoolId)
            }
        }.resume()
    }

    // Set (or clear, with nil) the active Spoolman spool in Moonraker.
    // On paxx12 >= 1.5 the "spoollink" component wipes Moonraker's active spool
    // right after it is set, so the choice would not stick — there we also write
    // it into our own per-nozzle mapping, which is what the tile then shows.
    func setActiveSpool(_ id: Int?) {
        if fwSpoolLink {
            // Same symmetric path as the nozzle list: also moves the tag of the
            // active nozzle onto the chosen spool. Without that the tag would
            // still point at the old one and revert this on the next resolve.
            assignSpoolManually(channel: max(0, activeExtruderIndex), spoolId: id)
        }
        guard let url = URL(string: "\(baseURL)/server/spoolman/spool_id") else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        // Moonraker unsets the active spool on an EMPTY body ({}); sending
        // spool_id: null makes it try int(null) and 400. So omit the key for nil.
        let payload: [String: Any] = id.map { ["spool_id": $0] } ?? [:]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        DispatchQueue.main.async { self.updateIfChanged(\.activeSpoolId, id) }
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.async { self?.fetchSpoolmanStatus() }
        }.resume()
    }

    // MARK: - Spoollink (paxx12 >= 1.5 "Filament Manager")

    // The firmware serves its own page at /filament/. A 200 there means the
    // feature is installed; cached so the screen stays available offline.
    func fetchSpoollinkAvailability() {
        guard printerType == .snapmakerU1, !isDemoMode,
              let url = URL(string: "\(baseURL)/filament/") else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, _ in
            guard let self, let code = (resp as? HTTPURLResponse)?.statusCode else { return }
            // Reachable page = feature shown. No printer-side configuration is
            // required from the user; whether the gcodes exist is a separate
            // question answered by verifySpoollinkCommands() and only used to
            // warn inside the screen.
            DispatchQueue.main.async {
                if code == 200 {
                    self.updateIfChanged(\.spoollinkAvailable, true)
                    self.verifySpoollinkCommands()
                } else if code == 404 {
                    self.updateIfChanged(\.spoollinkAvailable, false)
                }
            }
        }.resume()
    }

    // Are the SET_SPOOL_ID / FILAMENT_DT_* gcodes actually registered? Optimistic
    // by default: only a successfully read command list that lacks them flips it
    // to false, so a flaky link never blocks the controls.
    private func verifySpoollinkCommands() {
        guard let url = URL(string: "\(baseURL)/printer/gcode/help") else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let help = json["result"] as? [String: Any] else { return }
            let ok = help.keys.contains { $0.uppercased() == "SET_SPOOL_ID" }
            DispatchQueue.main.async { self.updateIfChanged(\.spoollinkCommandsReady, ok) }
        }.resume()
    }

    // Per-channel state: assigned spool, RFID card UID, material, vendor.
    func fetchSpoollinkState() {
        guard printerType == .snapmakerU1, !isDemoMode,
              let url = URL(string: "\(baseURL)/printer/objects/query?print_task_config&filament_detect") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let st = (json["result"] as? [String: Any])?["status"] as? [String: Any] else { return }
            var ids = [0, 0, 0, 0], uids = ["", "", "", ""], mats = ["", "", "", ""], vends = ["", "", "", ""]
            var cols = ["", "", "", ""], subs = ["", "", "", ""]
            if let ptc = st["print_task_config"] as? [String: Any] {
                if let a = ptc["filament_spool_id"] as? [Int] { for i in 0..<4 { ids[i] = a[safe: i] ?? 0 } }
                if let a = ptc["filament_type"] as? [String] { for i in 0..<4 { mats[i] = a[safe: i] ?? "" } }
                if let a = ptc["filament_vendor"] as? [String] { for i in 0..<4 { vends[i] = a[safe: i] ?? "" } }
                if let a = ptc["filament_sub_type"] as? [String] {
                    for i in 0..<4 { let v = a[safe: i] ?? ""; subs[i] = v == "NONE" ? "" : v }
                }
                // "RRGGBBAA" — keep the RGB part.
                if let a = ptc["filament_color_rgba"] as? [String] {
                    for i in 0..<4 {
                        let v = a[safe: i] ?? ""
                        cols[i] = v.count >= 6 ? String(v.prefix(6)) : ""
                    }
                }
            }
            var tVend = ["", "", "", ""], tType = ["", "", "", ""], tSub = ["", "", "", ""]
            var tCol = ["", "", "", ""], tMin = [0, 0, 0, 0], tMax = [0, 0, 0, 0]
            if let fd = st["filament_detect"] as? [String: Any],
               let info = fd["info"] as? [[String: Any]] {
                func clean(_ v: Any?) -> String {
                    let s = (v as? String) ?? ""
                    return s == "NONE" ? "" : s
                }
                for i in 0..<4 {
                    guard let e = info[safe: i] else { continue }
                    tVend[i] = clean(e["VENDOR"])
                    tType[i] = clean(e["MAIN_TYPE"])
                    tSub[i]  = clean(e["SUB_TYPE"])
                    // ARGB_COLOR is 0xAARRGGBB — keep the RGB part.
                    if let argb = (e["ARGB_COLOR"] as? NSNumber)?.int64Value, argb != 0 {
                        tCol[i] = String(format: "%06X", argb & 0xFFFFFF)
                    }
                    tMin[i] = (e["HOTEND_MIN_TEMP"] as? NSNumber)?.intValue ?? 0
                    tMax[i] = (e["HOTEND_MAX_TEMP"] as? NSNumber)?.intValue ?? 0
                    // A tag without filament data only carries a trustworthy UID.
                    if tType[i].isEmpty && tVend[i].isEmpty { tCol[i] = "" }
                }
                for i in 0..<4 {
                    // CARD_UID comes back as a BYTE ARRAY (e.g. [4,115,100,…]),
                    // not a number — the web UI renders it as hex.
                    let raw = info[safe: i]?["CARD_UID"]
                    if let bytes = raw as? [NSNumber], bytes.contains(where: { $0.intValue != 0 }) {
                        uids[i] = bytes.map { String(format: "%02X", $0.intValue) }.joined()
                    } else if let n = (raw as? NSNumber)?.int64Value, n > 0 {
                        uids[i] = String(n, radix: 16).uppercased()
                    } else {
                        uids[i] = ""
                    }
                }
            }
            DispatchQueue.main.async {
                if self.fwSlotSpoolIds != ids { self.fwSlotSpoolIds = ids }
                if self.slotCardUIDs != uids { self.slotCardUIDs = uids }
                if self.slotMaterials != mats { self.slotMaterials = mats }
                if self.slotVendors != vends { self.slotVendors = vends }
                if self.slotColorHexes != cols { self.slotColorHexes = cols }
                if self.slotSubtypes != subs { self.slotSubtypes = subs }
                if self.tagVendors != tVend { self.tagVendors = tVend }
                if self.tagTypes != tType { self.tagTypes = tType }
                if self.tagSubtypes != tSub { self.tagSubtypes = tSub }
                if self.tagColorHexes != tCol { self.tagColorHexes = tCol }
                if self.tagTempMin != tMin { self.tagTempMin = tMin }
                if self.tagTempMax != tMax { self.tagTempMax = tMax }
                if !self.fwSpoolLink { self.fwSpoolLink = true }
                // A spool the printer recognised from its RFID tag is the truth:
                // pull it into our own per-nozzle mapping so the 4-colour tracking
                // and the nozzle list (and therefore the colours) follow along.
                self.resolveSlotAssignments()
                self.autoApplyTagMismatches()
            }
        }.resume()
    }

    /// Assign a spool to a nozzle from the Spoollink screen.
    /// Always records it in our own per-nozzle mapping (that one works on every
    /// firmware and drives the display + 4-colour tracking) and additionally
    /// pushes it to the firmware when this build has the SET_SPOOL_ID command.
    func assignSpool(channel: Int, spoolId: Int?) {
        setSlotSpool(channel, spoolId)
        if spoollinkCommandsReady { spoollinkAssign(channel: channel, spoolId: spoolId) }
    }

    /// Assign a Spoolman spool to a channel (0-based). `nil` clears it.
    func spoollinkAssign(channel: Int, spoolId: Int?) {
        guard (0..<4).contains(channel) else { return }
        sendGCode("SET_SPOOL_ID LANE=E\(channel) SPOOL_ID=\(spoolId ?? 0)")
        scheduleSpoollinkRefresh()
    }

    /// Re-read the RFID tags — one channel, or all four when `channel` is nil.
    func spoollinkReadTags(channel: Int? = nil) {
        let range = channel.map { [$0] } ?? Array(0..<4)
        let script = range.map { "FILAMENT_DT_CLEAR CHANNEL=\($0)" }.joined(separator: "\n")
            + "\n" + range.map { "FILAMENT_DT_UPDATE CHANNEL=\($0)" }.joined(separator: "\n")
        sendGCode(script)
        scheduleSpoollinkRefresh()
    }

    private func scheduleSpoollinkRefresh() {
        for d in [1.0, 3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.fetchSpoollinkState() }
        }
    }

    // MARK: - 4-color Spoolman hook (U1 only)

    // Klipper config uploaded to config/extended/klipper/ (auto-included by the
    // paxx12 firmware). A delayed_gcode watcher maps the active nozzle to the
    // assigned Spoolman spool — no change to the tool-change path, so it cannot
    // abort a print.
    static let multiColorHookCfg = """
    # PaxxMaker — 4-Farben-Spoolman-Tracking (U1 / Multi-Nozzle)
    # Auto-installiert/entfernt durch die App. Nicht manuell bearbeiten.
    # delayed_gcode-Watcher: beobachtet nur toolhead.extruder -> setzt Spule.

    [gcode_macro _SPOOLMAN_MAP]
    variable_spool0: -1
    variable_spool1: -1
    variable_spool2: -1
    variable_spool3: -1
    variable_enabled: 1
    variable_last: -999
    gcode:
        # (leer — reiner Variablen-Container)

    [gcode_macro SET_ACTIVE_SPOOL]
    gcode:
        {% if params.ID %}
            {action_call_remote_method("spoolman_set_active_spool", spool_id=params.ID|int)}
        {% endif %}

    [gcode_macro CLEAR_ACTIVE_SPOOL]
    gcode:
        {action_call_remote_method("spoolman_set_active_spool", spool_id=None)}

    [delayed_gcode _spoolman_tool_watch]
    initial_duration: 3
    gcode:
        {% set m = printer['gcode_macro _SPOOLMAN_MAP'] %}
        {% if m.enabled|int == 1 %}
            {% set active = printer.toolhead.extruder %}
            {% set idx = {'extruder':0,'extruder1':1,'extruder2':2,'extruder3':3}.get(active, -1) %}
            {% set want = {0:m.spool0,1:m.spool1,2:m.spool2,3:m.spool3}.get(idx, -1)|int %}
            {% if want != m.last|int %}
                {% if want >= 0 %}
                    SET_ACTIVE_SPOOL ID={want}
                {% else %}
                    CLEAR_ACTIVE_SPOOL
                {% endif %}
                SET_GCODE_VARIABLE MACRO=_SPOOLMAN_MAP VARIABLE=last VALUE={want}
            {% endif %}
        {% endif %}
        UPDATE_DELAYED_GCODE ID=_spoolman_tool_watch DURATION=2
    """

    var mcIsIdle: Bool { printState != "printing" && printState != "paused" }
    private var mcMapKey: String { "mc_map_\(name)" }
    private func mcStoredMapping() -> [Int] {
        let a = UserDefaults.standard.array(forKey: mcMapKey) as? [Int]
        return (a?.count == 4) ? a! : [-1, -1, -1, -1]
    }
    private func mcStoreMapping(_ s: [Int]) { UserDefaults.standard.set(s, forKey: mcMapKey) }

    // Poll whether the hook is installed and read its live mapping/enabled state.
    func fetchMultiColorHook() {
        guard printerType == .snapmakerU1, !isDemoMode,
              let url = URL(string: "\(baseURL)/printer/objects/query?gcode_macro%20_SPOOLMAN_MAP") else { return }
        var req = URLRequest(url: url, timeoutInterval: 6)
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let status = result["status"] as? [String: Any] else { return }
            let macro = status["gcode_macro _SPOOLMAN_MAP"] as? [String: Any]
            // A removed macro still shows up as an EMPTY {} for a while, so key
            // on a real field ('enabled') rather than mere presence.
            let installed = macro?["enabled"] != nil
            var slots = [-1, -1, -1, -1]
            var enabled = false
            if let m = macro {
                for i in 0..<4 { slots[i] = (m["spool\(i)"] as? Int) ?? -1 }
                enabled = ((m["enabled"] as? Int) ?? 0) == 1
            }
            DispatchQueue.main.async {
                self.updateIfChanged(\.mcHookInstalled, installed)
                self.updateIfChanged(\.mcAutoTracking, enabled)
                guard installed else { return }
                // Macro vars reset to -1 on a Klipper restart. If we have a saved
                // mapping and the printer lost it, push ours back; otherwise adopt
                // the printer's live values as source of truth.
                let stored = self.mcStoredMapping()
                if slots.allSatisfy({ $0 < 0 }) && stored.contains(where: { $0 >= 0 }) {
                    self.mcSlotSpools = stored
                    self.mcApplyMapping(stored)
                } else {
                    if self.mcSlotSpools != slots { self.mcSlotSpools = slots }
                    self.mcStoreMapping(slots)
                }
            }
        }.resume()
    }

    // Assign (or clear with nil) the Spoolman spool for a nozzle slot. Live, no
    // restart — persisted so it survives a Klipper restart.
    func setSlotSpool(_ slot: Int, _ id: Int?) {
        guard slot >= 0, slot < 4 else { return }
        let v = id ?? -1
        if mcSlotSpools.count == 4 { mcSlotSpools[slot] = v }
        mcStoreMapping(mcSlotSpools)
        Task { await self.mcGcode("SET_GCODE_VARIABLE MACRO=_SPOOLMAN_MAP VARIABLE=spool\(slot) VALUE=\(v)") }
    }

    func setAutoTracking(_ on: Bool) {
        mcAutoTracking = on
        Task { await self.mcGcode("SET_GCODE_VARIABLE MACRO=_SPOOLMAN_MAP VARIABLE=enabled VALUE=\(on ? 1 : 0)") }
    }

    func installMultiColorHook() {
        guard printerType == .snapmakerU1, !isDemoMode, !mcBusy else { return }
        guard mcIsIdle else {
            mcStatusMsg = lz(en: "Only possible while the printer is idle.", de: "Nur im Leerlauf möglich.", fr: "Possible uniquement à l'arrêt.", es: "Solo posible en reposo.", pt: "Só é possível quando ociosa.", it: "Possibile solo da ferma.", zh: "仅在空闲时可用。")
            return
        }
        mcBusy = true
        mcStatusMsg = lz(en: "Setting up… printer restarts briefly.", de: "Wird eingerichtet… Drucker startet kurz neu.", fr: "Configuration… l'imprimante redémarre.", es: "Configurando… la impresora se reinicia.", pt: "Configurando… a impressora reinicia.", it: "Configurazione… la stampante si riavvia.", zh: "正在设置…打印机将短暂重启。")
        Task { await self.mcPerformInstall() }
    }

    func removeMultiColorHook() {
        guard printerType == .snapmakerU1, !isDemoMode, !mcBusy else { return }
        guard mcIsIdle else {
            mcStatusMsg = lz(en: "Only possible while the printer is idle.", de: "Nur im Leerlauf möglich.", fr: "Possible uniquement à l'arrêt.", es: "Solo posible en reposo.", pt: "Só é possível quando ociosa.", it: "Possibile solo da ferma.", zh: "仅在空闲时可用。")
            return
        }
        mcBusy = true
        mcStatusMsg = lz(en: "Removing… printer restarts briefly.", de: "Wird entfernt… Drucker startet kurz neu.", fr: "Suppression… l'imprimante redémarre.", es: "Eliminando… la impresora se reinicia.", pt: "Removendo… a impressora reinicia.", it: "Rimozione… la stampante si riavvia.", zh: "正在移除…打印机将短暂重启。")
        Task { await self.mcPerformRemove() }
    }

    private func mcPerformInstall() async {
        let uploaded = await mcUploadCfg()
        guard uploaded else {
            await MainActor.run { self.mcBusy = false
                self.mcStatusMsg = lz(en: "Upload failed.", de: "Upload fehlgeschlagen.", fr: "Échec de l'envoi.", es: "Error al subir.", pt: "Falha no envio.", it: "Caricamento non riuscito.", zh: "上传失败。") }
            return
        }
        await mcFirmwareRestart()
        let ready = await mcWaitReady(seconds: 45)
        await MainActor.run {
            self.mcBusy = false
            if ready {
                self.mcStatusMsg = nil
                let stored = self.mcStoredMapping()
                self.mcApplyMapping(stored)
                self.setAutoTracking(true)
                self.fetchMultiColorHook()
            } else {
                self.mcStatusMsg = lz(en: "Printer didn't come back — please check it.", de: "Drucker kam nicht zurück — bitte prüfen.", fr: "L'imprimante n'est pas revenue — vérifiez.", es: "La impresora no volvió — revísala.", pt: "A impressora não voltou — verifique.", it: "La stampante non è tornata — controlla.", zh: "打印机未恢复——请检查。")
            }
        }
    }

    private func mcPerformRemove() async {
        await mcGcode("SET_GCODE_VARIABLE MACRO=_SPOOLMAN_MAP VARIABLE=enabled VALUE=0")
        _ = await mcDeleteCfg()
        await mcFirmwareRestart()
        let ready = await mcWaitReady(seconds: 45)
        await MainActor.run {
            self.mcBusy = false
            UserDefaults.standard.removeObject(forKey: self.mcMapKey)
            self.mcSlotSpools = [-1, -1, -1, -1]
            if ready {
                self.mcStatusMsg = nil
                self.fetchMultiColorHook()
            } else {
                self.mcStatusMsg = lz(en: "Printer didn't come back — please check it.", de: "Drucker kam nicht zurück — bitte prüfen.", fr: "L'imprimante n'est pas revenue — vérifiez.", es: "La impresora no volvió — revísala.", pt: "A impressora não voltou — verifique.", it: "La stampante non è tornata — controlla.", zh: "打印机未恢复——请检查。")
            }
        }
    }

    private func mcApplyMapping(_ s: [Int]) {
        guard s.count == 4 else { return }
        Task { for i in 0..<4 { await self.mcGcode("SET_GCODE_VARIABLE MACRO=_SPOOLMAN_MAP VARIABLE=spool\(i) VALUE=\(s[i])") } }
    }

    private func mcGcode(_ script: String) async {
        guard let enc = script.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/printer/gcode/script?script=\(enc)") else { return }
        var req = URLRequest(url: url, timeoutInterval: 12); req.httpMethod = "POST"
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        _ = try? await URLSession.shared.data(for: req)
    }

    private func mcFirmwareRestart() async {
        guard let url = URL(string: "\(baseURL)/printer/firmware_restart") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10); req.httpMethod = "POST"
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        _ = try? await URLSession.shared.data(for: req)
    }

    private func mcWaitReady(seconds: Int) async -> Bool {
        for _ in 0..<(seconds / 3) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let url = URL(string: "\(baseURL)/printer/info") else { continue }
            var req = URLRequest(url: url, timeoutInterval: 6)
            if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["result"] as? [String: Any],
               (result["state"] as? String) == "ready" {
                return true
            }
        }
        return false
    }

    private func mcUploadCfg() async -> Bool {
        guard let url = URL(string: "\(baseURL)/server/files/upload") else { return false }
        let boundary = "----paxx\(UUID().uuidString)"
        var req = URLRequest(url: url, timeoutInterval: 25); req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("root", "config")
        field("path", "extended/klipper")
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"spoolman_multicolor.cfg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(Self.multiColorHookCfg.data(using: .utf8)!)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return code == 200 || code == 201
    }

    private func mcDeleteCfg() async -> Bool {
        guard let url = URL(string: "\(baseURL)/server/files/config/extended/klipper/spoolman_multicolor.cfg") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 12); req.httpMethod = "DELETE"
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return code == 200 || code == 204
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
                self?.webcamName = cam["name"] as? String ?? ""
                self?.webcam2Name = cam2Entry?["name"] as? String ?? ""
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
                guard let self else { return }
                self.totalJobs = jobs
                self.totalPrintTime = printTime
                self.totalFilamentUsedMm = filament
                self.longestPrintTime = longest
                let ud = UserDefaults.standard
                ud.set(jobs, forKey: "stats_jobs_\(self.name)")
                ud.set(printTime, forKey: "stats_time_\(self.name)")
                ud.set(filament, forKey: "stats_fil_\(self.name)")
                ud.set(longest, forKey: "stats_longest_\(self.name)")
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

    // When the printer's LAN is unreachable (away from home) but a print is
    // running, fall back to the live-pushed status from our OWN Live Activity —
    // the app CAN read `activity.content.state` (unlike the widget). This stops
    // the app (and, via writeWidgetData, the widget + Watch) from showing a
    // wrong "offline / 0%" while the Live Activity itself shows the real value.
    // Must run on the main thread. Returns true if LA data was applied.
    @discardableResult
    private func applyLiveActivityFallback() -> Bool {
        guard #available(iOS 16.2, *) else { return false }
        guard let activity = Activity<PaxxMakerWidgetAttributes>.activities
                .first(where: { $0.attributes.printerName == name }) else { return false }
        let s = activity.content.state
        // Only trust it while it reflects an active print (a stale ended LA
        // could otherwise keep showing old data).
        guard s.printState == "printing" || s.printState == "paused" else { return false }
        // Subscribe for instant push-driven updates (not just this 3 s poll).
        ensureLiveActivityObserver(activity)
        updateIfChanged(\.printState, s.printState)
        updateIfChanged(\.progress, s.progress)
        updateIfChanged(\.bedTemp, s.bedTemp)
        updateIfChanged(\.printTimeElapsed, s.timeElapsed)
        if extruderTemps.indices.contains(0), extruderTemps[0] != s.extruderTemp {
            extruderTemps[0] = s.extruderTemp
        }
        updateIfChanged(\.activeExtruderIndex, 0)
        if !activity.attributes.filename.isEmpty {
            updateIfChanged(\.filename, activity.attributes.filename)
        }
        // Data is fresh via push — don't show the "offline" state for this, but
        // flag it so the UI hides "LIVE" (we're not live-connected to the LAN).
        updateIfChanged(\.isOnline, true)
        updateIfChanged(\.isViaLiveActivity, true)
        lastSeenDate = Date()
        return true
    }

    // Subscribe to the Live Activity's push-driven content updates so the app
    // reflects them INSTANTLY (not only on the 3 s poll) while relying on the LA
    // away from home. Zero network cost — the LA receives these pushes anyway.
    @available(iOS 16.2, *)
    private func ensureLiveActivityObserver(_ activity: Activity<PaxxMakerWidgetAttributes>) {
        if laObserverActivityID == activity.id { return }   // already observing this one
        laObserverTask?.cancel()
        laObserverActivityID = activity.id
        laObserverTask = Task { [weak self] in
            for await content in activity.contentUpdates {
                guard let self else { return }
                let s = content.state
                await MainActor.run {
                    // Only while we're relying on the LA (LAN still unreachable).
                    guard self.isViaLiveActivity || !self.isOnline else { return }
                    guard s.printState == "printing" || s.printState == "paused" else { return }
                    self.updateIfChanged(\.printState, s.printState)
                    self.updateIfChanged(\.progress, s.progress)
                    self.updateIfChanged(\.bedTemp, s.bedTemp)
                    self.updateIfChanged(\.printTimeElapsed, s.timeElapsed)
                    if self.extruderTemps.indices.contains(0), self.extruderTemps[0] != s.extruderTemp {
                        self.extruderTemps[0] = s.extruderTemp
                    }
                    self.updateIfChanged(\.isOnline, true)
                    self.updateIfChanged(\.isViaLiveActivity, true)
                    self.lastSeenDate = Date()
                }
            }
            await MainActor.run { self?.laObserverActivityID = nil }
        }
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
                DispatchQueue.main.async {
                    // LAN unreachable — use the Live Activity's pushed status if a
                    // print is running, otherwise mark offline.
                    if !self.applyLiveActivityFallback() {
                        self.updateIfChanged(\.isOnline, false)
                    }
                }
                return
            }
            DispatchQueue.main.async {
                self.updateIfChanged(\.isOnline, true)
                self.updateIfChanged(\.isViaLiveActivity, false)
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
                        material: detected ? lz(en: "Inserted", de: "Eingelegt", fr: "Inséré", es: "Insertado", pt: "Inserido", it: "Inserito", zh: "已插入") : "–",
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
                        // Skip the app's own local notification when Server Push
                        // is on — the Cloudflare Worker already sends the alert,
                        // otherwise the user gets the same "done" twice.
                        if self.pushMode != .cloudflare {
                            self.sendLocalNotification(
                                title: lz(en: "Print done!", de: "Druck fertig!", fr: "Impression terminée!", es: "¡Impresión lista!", pt: "Impressão concluída!", it: "Stampa completata!", zh: "打印完成！"),
                                body: self.filename.isEmpty ? self.name : "\(self.filename) · \(self.name)",
                                identifier: "print-done-\(self.name)"
                            )
                        }
                        hapticNotification(.success)
                    }
                } else if prevState == "printing" && self.printState == "error" {
                    let bgDefaults = UserDefaults(suiteName: "group.paxxmaker.u1")
                    let bgHandled = (bgDefaults?.dictionary(forKey: "bg_prev_print_states") as? [String: String])?[self.name] == "error"
                    if !bgHandled {
                        if self.pushMode != .cloudflare {
                            self.sendLocalNotification(
                                title: lz(en: "Print error", de: "Druckfehler", fr: "Erreur d'impression", es: "Error de impresión", pt: "Erro de impressão", it: "Errore di stampa", zh: "打印错误"),
                                body: "\(self.name)" + (self.filename.isEmpty ? "" : ": \(self.filename)"),
                                identifier: "print-err-\(self.name)"
                            )
                        }
                        hapticNotification(.error)
                    }
                } else if (prevState == "printing" || prevState == "paused") && self.printState == "cancelled" {
                    let bgDefaults = UserDefaults(suiteName: "group.paxxmaker.u1")
                    let bgHandled = (bgDefaults?.dictionary(forKey: "bg_prev_print_states") as? [String: String])?[self.name] == "cancelled"
                    if !bgHandled {
                        if self.pushMode != .cloudflare {
                            self.sendLocalNotification(
                                title: lz(en: "Print cancelled", de: "Druck abgebrochen", fr: "Impression annulée", es: "Impresión cancelada", pt: "Impressão cancelada", it: "Stampa annullata", zh: "打印已取消"),
                                body: "\(self.name)" + (self.filename.isEmpty ? "" : ": \(self.filename)"),
                                identifier: "print-cancelled-\(self.name)"
                            )
                        }
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
                            title: lz(en: "Filament runout!", de: "Filament leer!", fr: "Plus de filament !", es: "¡Filamento agotado!", pt: "Filamento esgotado!", it: "Filamento esaurito!", zh: "耗材用尽！"),
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
            progress: progress, extruderTemp: activeExtruderTemp, bedTemp: bedTemp,
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
            defaults.set(Date().timeIntervalSince1970, forKey: "w_all_printers_at")
            // Forward latest state to paired Apple Watch. Also ship the
            // connection configs: app groups are NOT shared between iPhone and
            // Watch, so without this the Watch can never poll printers directly
            // (= frozen values whenever the iOS app isn't running). "at" lets
            // the Watch tell fresh data from stale cache.
            if WCSession.isSupported(),
               WCSession.default.activationState == .activated,
               WCSession.default.isPaired {
                var ctx: [String: Any] = ["printers": encoded,
                                          "at": Date().timeIntervalSince1970]
                if let cfgData = defaults.data(forKey: "watch_printer_configs") {
                    ctx["configs"] = cfgData
                }
                try? WCSession.default.updateApplicationContext(ctx)
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
            extruderTemp: activeExtruderTemp, bedTemp: bedTemp, timeElapsed: printTimeElapsed
        )
        if prevState != "printing" && printState == "printing" {
            let usePush = pushMode == .cloudflare && !cloudflareNotifySecret.isEmpty
            // Self-heal: a print just started — make sure the printer-side bridge
            // (live-progress) is actually running. On firmware without a boot
            // autostart (e.g. a U1 without OctoEverywhere) it may be down after a
            // reboot; the end-event notifier stays reboot-safe regardless.
            if usePush { selfHealBridgeIfNeeded() }
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

    private var lastSelfHealAt: Date?

    // Relaunch the printer-side bridge over SSH if it isn't running. U1 only:
    // its SSH login (root) and default password ("snapmaker") are known, so this
    // needs no stored credentials. If the user changed the password it fails
    // silently — end-event pushes keep working via the reboot-safe notifier.
    private func selfHealBridgeIfNeeded() {
        guard printerType == .snapmakerU1 else { return }
        // Throttle: at most once every 2 min (a redundant relaunch is harmless
        // but there's no point hammering SSH).
        if let t = lastSelfHealAt, Date().timeIntervalSince(t) < 120 { return }
        lastSelfHealAt = Date()
        let host = baseURL
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .components(separatedBy: ":").first?
            .trimmingCharacters(in: .whitespaces) ?? baseURL
        guard !host.isEmpty else { return }
        Task.detached {
            _ = try? await SSHInstaller.ensureBridgeRunning(host: host, user: "root", password: "snapmaker")
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
        // New paxx12: per-slot Spoolman ids live here. Its presence identifies
        // the firmware generation that manages spools itself.
        if let ids = json["filament_spool_id"] as? [Int] {
            let padded = (0..<4).map { ids[safe: $0] ?? 0 }
            if fwSlotSpoolIds != padded { fwSlotSpoolIds = padded }
            if !fwSpoolLink { fwSpoolLink = true }
        }
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
                if let error = error { self.fileError = SpoolmanService.localizedTransport(error); return }
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
                            Text(lz(en: "No Filament", de: "Kein Filament", fr: "Pas de filament", es: "Sin filamento", pt: "Sem filamento", it: "Nessun filamento", zh: "无耗材")).font(.caption2).foregroundColor(.secondary)
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
                            Text(lz(en: "Active", de: "Aktiv", fr: "Actif", es: "Activo", pt: "Ativo", it: "Attivo", zh: "使用中"))
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
                                Text(lz(en: "Attach", de: "Greifen", fr: "Attacher", es: "Enganchar", pt: "Prender", it: "Aggancia", zh: "夹取"))
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
            TextField(lz(en: "Target temp (°C)", de: "Zieltemperatur (°C)", fr: "Température cible (°C)", es: "Temperatura objetivo (°C)", pt: "Temperatura alvo (°C)", it: "Temperatura obiettivo (°C)", zh: "目标温度 (°C)"), text: $tempInput).keyboardType(.numberPad)
            Button(lz(en: "Set", de: "Setzen", fr: "Définir", es: "Establecer", pt: "Definir", it: "Imposta", zh: "设置")) { if let t = Double(tempInput) { onSetTemp(t) } }
            Button(lz(en: "Off", de: "Aus", fr: "Éteindre", es: "Apagar", pt: "Desligar", it: "Spegni", zh: "关闭")) { onSetTemp(0) }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {}
        } message: { Text("\(slot.material) · \(lz(en: "Current", de: "Aktuell", fr: "Actuel", es: "Actual", pt: "Atual", it: "Attuale", zh: "当前")): \(Int(temp))°C") }
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
        // For 90°/270° the image's width/height swap — constrain against the
        // opposite viewport axis so the rotated frame still fits the tile.
        let odd = (((rotation % 360) + 360) % 360) % 180 != 0
        let fit = odd ? "max-width:100vh;max-height:100vw" : "max-width:100%;max-height:100%"
        let html = """
        <!DOCTYPE html><html><head>
        <style>html,body{margin:0;padding:0;background:#000;width:100%;height:100vh;display:flex;align-items:center;justify-content:center;overflow:hidden}img{\(fit);object-fit:contain;transform:\(transform)}</style>
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
    @State private var showFilamentColorPicker = false
    @State private var filamentPickerColor: Color = .orange
    // Spoolman: when it is set up, the filament chip mirrors the "Active Spool"
    // tile instead of the manually picked colour, and tapping it opens the very
    // same spool picker — so both tiles can never disagree.
    @AppStorage("spoolman_url") private var spoolmanURL: String = ""
    @State private var spoolmanSpools: [SpoolmanSpool] = []
    @State private var showSpoolPicker = false

    var usesSpoolman: Bool { printer.spoolmanConnected }
    var activeSpool: SpoolmanSpool? {
        guard let id = printer.effectiveActiveSpoolId else { return nil }
        return spoolmanSpools.first { $0.id == id }
    }

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
        // Header + temperature use exactly the same metrics as the Heizbett tile
        // so both headers and both temperatures sit on the same lines.
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { extruderTempInput = "\(Int(extruderTarget))"; showExtruderTempInput = true }) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "flame.fill").font(.system(size: 12)).foregroundColor(.orange)
                        Text("Extruder")
                            .font(.caption2).fontWeight(.semibold).foregroundColor(.secondary)
                            .textCase(.uppercase).tracking(1).lineLimit(1)
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                            .shadow(color: statusColor.opacity(0.6), radius: 3)
                        Spacer(minLength: 0)
                        Image(systemName: "pencil").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(Int(extruderTemp))").font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundColor(.primary).minimumScaleFactor(0.5).lineLimit(1)
                        Text("°C").font(.system(size: 14, weight: .medium)).foregroundColor(.secondary)
                        Spacer(minLength: 0)
                    }
                    Text(extruderTarget > 0 ? "→ \(Int(extruderTarget))°C" : lz(en: "Off", de: "Aus", fr: "Éteint", es: "Apagado", pt: "Desligado", it: "Spento", zh: "关闭"))
                        .font(.system(size: 12, weight: .medium)).foregroundColor(.secondary).lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Filament chip + nozzle diameter.
            HStack(spacing: 8) {
                if usesSpoolman {
                    // Chip follows the active Spoolman spool; tap = spool picker.
                    Button(action: { showSpoolPicker = true }) {
                        HStack(spacing: 4) {
                            if let a = activeSpool {
                                ColorDot(hex: a.filament.color_hex, size: 9)
                                Text(a.filament.material ?? a.filament.rowTitle)
                                    .font(.caption2).fontWeight(.medium).foregroundColor(.primary)
                                    .lineLimit(1)
                            } else {
                                Image(systemName: "smallcircle.filled.circle")
                                    .font(.system(size: 9)).foregroundColor(.secondary)
                                Text(lz(en: "No spool", de: "Keine Spule", fr: "Aucune bobine", es: "Sin bobina", pt: "Sem bobina", it: "Nessuna bobina", zh: "无料盘"))
                                    .font(.caption2).fontWeight(.medium).foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                } else if slot.detected {
                    Button(action: { filamentPickerColor = slot.color; showFilamentColorPicker = true }) {
                        HStack(spacing: 4) {
                            Circle().fill(slot.color).frame(width: 9, height: 9)
                            Text(slot.material).font(.caption2).fontWeight(.medium).foregroundColor(.primary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(lz(en: "No Filament", de: "Kein Filament", fr: "Pas de fil.", es: "Sin filamento", pt: "Sem filamento", it: "Nessun filamento", zh: "无耗材"))
                        .font(.caption2).foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
                let nozzle = printer.nozzleDiameters[safe: 0] ?? 0.4
                let loaded = printer.nozzleDiametersLoaded[safe: 0] ?? false
                Text(loaded ? String(format: "Ø %.1f mm", nozzle) : "Ø – mm")
                    .font(.caption2).foregroundColor(.secondary)
            }
            // (M600 lives in the Heizbett tile so both tiles carry equal weight.)
        }
        .alert("Extruder", isPresented: $showExtruderTempInput) {
            TextField(lz(en: "Target temp (°C)", de: "Zieltemperatur (°C)", fr: "Température cible (°C)", es: "Temperatura objetivo (°C)", pt: "Temperatura alvo (°C)", it: "Temperatura obiettivo (°C)", zh: "目标温度 (°C)"), text: $extruderTempInput).keyboardType(.numberPad)
            Button(lz(en: "Set", de: "Setzen", fr: "Définir", es: "Establecer", pt: "Definir", it: "Imposta", zh: "设置")) { if let t = Double(extruderTempInput) { printer.setExtruderTemp(extruder: 0, target: t) } }
            Button(lz(en: "Off", de: "Aus", fr: "Éteindre", es: "Apagar", pt: "Desligar", it: "Spegni", zh: "关闭")) { printer.setExtruderTemp(extruder: 0, target: 0) }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {}
        }
        .sheet(isPresented: $showFilamentColorPicker) {
            VStack(spacing: 24) {
                Text(lz(en: "Filament Color", de: "Filamentfarbe", fr: "Couleur filament", es: "Color filamento", pt: "Cor do Filamento", it: "Colore Filamento", zh: "耗材颜色"))
                    .font(.headline)
                ColorPicker(lz(en: "Color", de: "Farbe", fr: "Couleur", es: "Color", pt: "Cor", it: "Colore", zh: "颜色"),
                            selection: $filamentPickerColor, supportsOpacity: false)
                    .padding(.horizontal)
                Button(lz(en: "Done", de: "Fertig", fr: "OK", es: "OK", pt: "Concluído", it: "Fatto", zh: "完成")) {
                    showFilamentColorPicker = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(32)
            .presentationDetents([.height(220)])
            .onChange(of: filamentPickerColor) { printer.setSNFilamentColor(filamentPickerColor.hexString) }
        }
        .sheet(isPresented: $showSpoolPicker) {
            ActiveSpoolPicker(spools: spoolmanSpools, activeId: printer.effectiveActiveSpoolId) { id in
                printer.setActiveSpool(id)
                showSpoolPicker = false
            }
        }
        .task { await loadSpoolmanSpools() }
        .onChange(of: printer.spoolmanConnected) { Task { await loadSpoolmanSpools() } }
        .onChange(of: printer.effectiveActiveSpoolId) { Task { await loadSpoolmanSpools() } }
    }

    private func loadSpoolmanSpools() async {
        guard usesSpoolman, let svc = SpoolmanService(rawHost: spoolmanURL) else { return }
        if let list = try? await svc.spools(includeArchived: false) {
            await MainActor.run { self.spoolmanSpools = list }
        }
    }
}

// MARK: - Preheat presets (single-nozzle)
struct PreheatPreset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var nozzle: Int
    var bed: Int
    // Optional so presets saved before colours existed still decode.
    var colorHex: String? = nil
}

private struct PreheatIdxBox: Identifiable { let id: Int }

// A tile of tappable preheat presets. Tap = apply (nozzle + bed). Long-press a
// preset → context menu → edit its material name and temperatures. Presets are
// stored per printer.
struct PreheatTileView: View {
    @ObservedObject var printer: PrinterService
    @State private var presets: [PreheatPreset] = PreheatTileView.defaults
    @State private var editing: PreheatIdxBox? = nil

    static let defaults: [PreheatPreset] = [
        PreheatPreset(name: "PLA",  nozzle: 210, bed: 60,  colorHex: "fd7043"),
        PreheatPreset(name: "PETG", nozzle: 240, bed: 70,  colorHex: "26a69a"),
        PreheatPreset(name: "ABS",  nozzle: 250, bed: 100, colorHex: "ab47bc"),
    ]
    private var storeKey: String { "preheat_presets_\(printer.name)" }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let arr = try? JSONDecoder().decode([PreheatPreset].self, from: data), !arr.isEmpty {
            presets = arr
        }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: storeKey) }
    }
    private func apply(_ p: PreheatPreset) {
        printer.setExtruderTemp(extruder: 0, target: Double(p.nozzle))
        printer.setBedTemp(target: Double(p.bed))
    }

    // Same visual weight & metrics as the Statistics tile's statCard.
    @ViewBuilder
    private func presetCard(icon: String, value: String, label: String, gradient: [Color]) -> some View {
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
                    .minimumScaleFactor(0.6).lineLimit(1)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(10)
        }
    }

    // Colour of a preset — falls back per index for presets saved before
    // colours existed.
    static let fallbackHexes = ["fd7043", "26a69a", "ab47bc"]
    private func presetHex(_ i: Int) -> String {
        presets[safe: i]?.colorHex ?? PreheatTileView.fallbackHexes[i % PreheatTileView.fallbackHexes.count]
    }

    @ViewBuilder private func presetPill(_ i: Int) -> some View {
        let c = Color(hex: presetHex(i)) ?? .orange
        Button(action: { haptic(); apply(presets[i]) }) {
            presetCard(icon: "flame.fill",
                       value: presets[i].name,
                       label: "\(presets[i].nozzle)° · \(presets[i].bed)°",
                       gradient: [c, c.opacity(0.55)])
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { editing = PreheatIdxBox(id: i) } label: {
                Label(lz(en: "Edit", de: "Bearbeiten", fr: "Modifier", es: "Editar", pt: "Editar", it: "Modifica", zh: "编辑"), systemImage: "pencil")
            }
        }
    }

    @ViewBuilder private var coolPill: some View {
        Button(action: { haptic(); printer.setExtruderTemp(extruder: 0, target: 0); printer.setBedTemp(target: 0) }) {
            presetCard(icon: "snowflake",
                       value: lz(en: "Off", de: "Aus", fr: "Arrêt", es: "Apagar", pt: "Desligar", it: "Spegni", zh: "关闭"),
                       label: lz(en: "Heaters off", de: "Heizung aus", fr: "Chauffe arrêtée", es: "Sin calor", pt: "Sem aquecer", it: "Riscald. off", zh: "关闭加热"),
                       gradient: [Color(hex: "4facfe") ?? .blue, Color(hex: "00f2fe") ?? .cyan])
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        DashboardView_glassCardShell {
            VStack(alignment: .leading, spacing: 12) {
                Text(lz(en: "Preheat", de: "Vorheizen", fr: "Préchauffage", es: "Precalentar", pt: "Pré-aquecer", it: "Preriscalda", zh: "预热"))
                    .font(.caption).fontWeight(.semibold)
                    .foregroundColor(.secondary).textCase(.uppercase).tracking(1)
                // Fixed HStack rows (not a LazyVGrid, which reserves extra height
                // and left an uneven gap at the bottom).
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        if presets.indices.contains(0) { presetPill(0) }
                        if presets.indices.contains(1) { presetPill(1) }
                    }
                    HStack(spacing: 10) {
                        if presets.indices.contains(2) { presetPill(2) }
                        coolPill
                    }
                }
            }
        }
        .onAppear { load() }
        .sheet(item: $editing) { box in
            PreheatEditSheet(preset: presets[box.id], fallbackHex: presetHex(box.id)) { updated in
                presets[box.id] = updated
                save()
                editing = nil
            }
        }
    }
}

// Edit one preset: free material name + nozzle/bed temperatures.
struct PreheatEditSheet: View {
    @State var preset: PreheatPreset
    var fallbackHex: String = "fd7043"
    var onSave: (PreheatPreset) -> Void
    @Environment(\.dismiss) private var dismiss

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: preset.colorHex ?? fallbackHex) ?? .orange },
            set: { preset.colorHex = $0.hexString }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(lz(en: "Material", de: "Material", fr: "Matériau", es: "Material", pt: "Material", it: "Materiale", zh: "材料"))) {
                    TextField(lz(en: "Name", de: "Name", fr: "Nom", es: "Nombre", pt: "Nome", it: "Nome", zh: "名称"), text: $preset.name)
                    ColorPicker(selection: colorBinding, supportsOpacity: false) {
                        HStack {
                            Image(systemName: "paintpalette.fill").foregroundColor(.pink)
                            Text(lz(en: "Colour", de: "Farbe", fr: "Couleur", es: "Color", pt: "Cor", it: "Colore", zh: "颜色"))
                        }
                    }
                }
                Section(header: Text(lz(en: "Temperatures", de: "Temperaturen", fr: "Températures", es: "Temperaturas", pt: "Temperaturas", it: "Temperature", zh: "温度"))) {
                    Stepper(value: $preset.nozzle, in: 0...350, step: 5) {
                        HStack { Image(systemName: "flame.fill").foregroundColor(.orange)
                            Text(lz(en: "Nozzle", de: "Düse", fr: "Buse", es: "Boquilla", pt: "Bico", it: "Ugello", zh: "喷嘴"))
                            Spacer(); Text("\(preset.nozzle) °C").foregroundColor(.secondary) }
                    }
                    Stepper(value: $preset.bed, in: 0...150, step: 5) {
                        HStack { Image(systemName: "square.stack.3d.up.fill").foregroundColor(.red)
                            Text(lz(en: "Bed", de: "Bett", fr: "Plateau", es: "Cama", pt: "Mesa", it: "Piano", zh: "热床"))
                            Spacer(); Text("\(preset.bed) °C").foregroundColor(.secondary) }
                    }
                }
            }
            .navigationTitle(lz(en: "Edit Preset", de: "Preset bearbeiten", fr: "Modifier le préréglage", es: "Editar preajuste", pt: "Editar predefinição", it: "Modifica preset", zh: "编辑预设"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(lz(en: "Save", de: "Speichern", fr: "Enregistrer", es: "Guardar", pt: "Salvar", it: "Salva", zh: "保存")) { onSave(preset); dismiss() }
                }
            }
        }
    }
}

// Same chrome as the dashboard's glassCard, usable from standalone tile views.
struct DashboardView_glassCardShell<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16).fill(.thinMaterial)
            RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06))
            RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            content().padding(14)
        }
        .frame(maxWidth: .infinity)
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
    case webcam, webcam2, status, screen, extruder, bed, chamber, preheat, filament, spools, cleaning, calibration, stats, smartPlug, activeSpool
    var id: String { rawValue }
    var label: String {
        switch self {
        case .webcam: return "Webcam"
        case .webcam2: return "Webcam 2"
        case .status: return lz(en: "Status & Control", de: "Status & Steuerung", fr: "Statut & Contrôle", es: "Estado & Control", pt: "Status e Controle", it: "Stato e Controllo", zh: "状态与控制")
        case .screen: return lz(en: "Printer Screen", de: "Druckerbildschirm", fr: "Écran Imprimante", es: "Pantalla Impresora", pt: "Tela da Impressora", it: "Schermo della stampante", zh: "打印机屏幕")
        case .extruder: return "Extruder"
        case .bed: return lz(en: "Heated Bed", de: "Heizbett", fr: "Plateau chauffant", es: "Cama caliente", pt: "Mesa aquecida", it: "Piano riscaldato", zh: "热床")
        case .chamber: return lz(en: "Chamber", de: "Bauraum", fr: "Enceinte", es: "Cámara", pt: "Câmara", it: "Camera", zh: "腔体")
        case .preheat: return lz(en: "Preheat", de: "Vorheizen", fr: "Préchauffage", es: "Precalentar", pt: "Pré-aquecer", it: "Preriscalda", zh: "预热")
        case .filament: return lz(en: "Filament", de: "Filament", fr: "Filament", es: "Filamento", pt: "Filamento", it: "Filamento", zh: "耗材")
        case .spools: return lz(en: "Spools", de: "Spulen", fr: "Bobines", es: "Bobinas", pt: "Bobinas", it: "Bobine", zh: "料盘")
        case .cleaning: return lz(en: "Nozzle Cleaning", de: "Düsen Reinigung", fr: "Nettoyage Buse", es: "Limpieza Boquilla", pt: "Limpeza do Bico", it: "Pulizia Ugello", zh: "喷嘴清洁")
        case .calibration: return lz(en: "Calibration", de: "Kalibrierung", fr: "Calibration", es: "Calibración", pt: "Calibração", it: "Calibrazione", zh: "校准")
        case .stats: return lz(en: "Statistics", de: "Statistiken", fr: "Statistiques", es: "Estadísticas", pt: "Estatísticas", it: "Statistiche", zh: "统计")
        case .smartPlug: return lz(en: "Smart Plug", de: "Smart-Steckdose", fr: "Prise intelligente", es: "Enchufe inteligente", pt: "Tomada Inteligente", it: "Presa Intelligente", zh: "智能插座")
        case .activeSpool: return lz(en: "Active Spool", de: "Aktive Spule", fr: "Bobine active", es: "Bobina activa", pt: "Bobina ativa", it: "Bobina attiva", zh: "当前料盘")
        }
    }
    var icon: String {
        switch self {
        case .webcam: return "video.fill"
        case .webcam2: return "web.camera.fill"
        case .status: return "play.circle.fill"
        case .screen: return "display"
        case .extruder: return "thermometer"
        case .bed: return "square.stack.3d.up.fill"
        case .chamber: return "cube.transparent.fill"
        case .preheat: return "thermometer.sun.fill"
        case .filament: return "arrow.2.squarepath"
        case .spools: return "cylinder.split.1x2.fill"
        case .cleaning: return "paintbrush.fill"
        case .calibration: return "slider.horizontal.3"
        case .stats: return "chart.bar.fill"
        case .smartPlug: return "powerplug.fill"
        case .activeSpool: return "smallcircle.filled.circle"
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
            return title.isEmpty ? lz(en: "My Commands", de: "Eigene Befehle", fr: "Mes commandes", es: "Mis comandos", pt: "Meus Comandos", it: "I miei comandi", zh: "我的命令") : title
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
            .navigationTitle(lz(en: "Customize Tiles", de: "Kacheln anpassen", fr: "Personnaliser", es: "Personalizar", pt: "Personalizar Blocos", it: "Personalizza Riquadri", zh: "自定义卡片"))
            .navigationBarItems(trailing: Button(lz(en: "Done", de: "Fertig", fr: "Terminé", es: "Listo", pt: "Concluído", it: "Fatto", zh: "完成")) { dismiss() })
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
                    Text(lz(en: "Off", de: "Aus", fr: "Éteindre", es: "Apagar", pt: "Desligar", it: "Spegni", zh: "关闭"))
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
                    Text(lz(en: "Set", de: "Setzen", fr: "Définir", es: "Establecer", pt: "Definir", it: "Imposta", zh: "设置"))
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
            Button(lz(en: "Start", de: "Starten", fr: "Lancer", es: "Iniciar", pt: "Iniciar", it: "Avvia", zh: "开始")) { action() }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .alert(lz(en: "Printer busy", de: "Drucker beschäftigt", fr: "Imprimante occupée", es: "Impresora ocupada", pt: "Impressora ocupada", it: "Stampante occupata", zh: "打印机忙碌中"),
               isPresented: $showBusy) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(printer.printState == "printing"
                 ? lz(en: "A print is running. Available once the print is done.", de: "Ein Druck läuft. Nach dem Druck wieder verfügbar.", fr: "Une impression est en cours.", es: "Hay una impresión en curso.", pt: "Uma impressão está em andamento. Disponível assim que a impressão terminar.", it: "È in corso una stampa. Disponibile al termine della stampa.", zh: "打印正在进行中，打印完成后可用。")
                 : lz(en: "A command is currently running. Please wait.", de: "Es läuft gerade ein Befehl. Bitte warte bis er abgeschlossen ist.", fr: "Une commande est en cours. Patientez.", es: "Un comando está en curso. Espere.", pt: "Um comando está em execução. Aguarde.", it: "È in esecuzione un comando. Attendere.", zh: "命令正在执行，请稍候。"))
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
            confirmMessage: lz(en: "Run this command?", de: "Befehl ausführen?", fr: "Exécuter cette commande\u{00A0}?", es: "¿Ejecutar este comando?", pt: "Executar este comando?", it: "Eseguire questo comando?", zh: "执行此命令？"),
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

    private static let defaultTileOrder     = "webcam,status,screen,extruder,bed,chamber,preheat,spools,filament,calibration,cleaning,stats"
    private static let defaultHalfWidth     = "filament,calibration"
    // iPad default: spools next to extruder, calibration+cleaning side-by-side
    private static let defaultTileOrderIPad = "webcam,status,screen,extruder,spools,bed,chamber,preheat,filament,calibration,cleaning,stats"
    private static let defaultHalfWidthIPad = "extruder,spools,calibration,cleaning"
    // Single-nozzle default: Extruder|Heizbett, Vorheizen|Statistiken,
    // Kalibrierung|Aktive Spule — all half-width pairs.
    private static let defaultTileOrderSN   = "webcam,status,extruder,bed,preheat,stats,calibration,activeSpool"
    private static let defaultHalfWidthSN   = "extruder,bed,preheat,stats,calibration,activeSpool"
    @State private var showEmergencyConfirm = false
    @State private var showPauseConfirm = false
    @State private var showResumeConfirm = false
    @State private var showCancelConfirm = false
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
    @State private var showSpoollinkSheet = false
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
                if t == .webcam     { return printer.webcamConfigured }
                if t == .webcam2    { return printer.webcam2StreamURL != nil }
                if t == .smartPlug  { return !printer.smartPlugIP.isEmpty }
                if t == .activeSpool { return printer.spoolmanConnected }
                return true
            }
    }

    var allTileItems: [DashboardItem] {
        let snExcluded: Set<DashboardTile> = [.screen, .filament, .spools, .cleaning, .chamber]
        func isApplicable(_ t: DashboardTile) -> Bool {
            if t == .webcam     { return printer.webcamConfigured }
            if t == .webcam2    { return printer.webcam2StreamURL != nil }
            if t == .smartPlug  { return !printer.smartPlugIP.isEmpty }
            if t == .activeSpool { return printer.spoolmanConnected }
            if t == .preheat { return printer.printerType == .singleNozzle }
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

    // Drop a tile onto another one: the dragged tile takes that spot and the
    // target — plus everything after it — slides along; no tiles are swapped and
    // no gap is left behind. Dragging upwards inserts before the target (it
    // slides down), dragging downwards inserts after it.
    func insertTile(withID id: String, at targetID: String) {
        var items = allTileItems
        guard id != targetID,
              let fromIdx = items.firstIndex(where: { $0.rawID == id }),
              let toIdx   = items.firstIndex(where: { $0.rawID == targetID }) else { return }
        let movingDown = fromIdx < toIdx
        let tile = items.remove(at: fromIdx)
        guard let t = items.firstIndex(where: { $0.rawID == targetID }) else { return }
        items.insert(tile, at: movingDown ? t + 1 : t)
        applyTileOrder(items)
    }

    func reorderItem(withID id: String, after targetID: String) {
        moveTile(id: id, targetID: targetID, placeBefore: false)
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
            // iPhone: status always locked full; extruder only for the U1
            // (multi-nozzle card is wide) — single-nozzle extruder is compact
            // and may go half. Bed/chamber are their own half-capable tiles.
            var locked: Set<String> = [DashboardTile.status.rawValue]
            if printer.printerType == .snapmakerU1 { locked.insert(DashboardTile.extruder.rawValue) }
            return locked.contains(item.rawID) ? 0 : 1
        }
        let primaryTiles: Set<String> = [DashboardTile.webcam.rawValue, DashboardTile.status.rawValue, DashboardTile.screen.rawValue]
        let heavyTiles:   Set<String> = [DashboardTile.extruder.rawValue]
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
        let sn = printer.printerType == .singleNozzle
        tileOrderString = ud.string(forKey: lKey("dashboard_tile_order"))
            ?? (sn ? DashboardView.defaultTileOrderSN : (iPad ? DashboardView.defaultTileOrderIPad : DashboardView.defaultTileOrder))
        hiddenTilesString = ud.string(forKey: lKey("hidden_tiles")) ?? ""
        tileGridModeString = ud.string(forKey: lKey("tile_grid_mode")) ?? ""
        halfWidthString = ud.string(forKey: lKey("tile_half_width"))
            ?? (sn ? DashboardView.defaultHalfWidthSN : (iPad ? DashboardView.defaultHalfWidthIPad : DashboardView.defaultHalfWidth))
        thirdWidthString = ud.string(forKey: lKey("tile_third_width")) ?? ""
        // Restore the status tile's saved height (0=full … 2=compact). Stored per
        // printer like the widths; without this it reset to full on every launch.
        if ud.object(forKey: lKey("status_tile_size")) != nil {
            statusTileSize = ud.integer(forKey: lKey("status_tile_size"))
        }
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
        case "printing": return lz(en: "Printing", de: "Druckt", fr: "En cours", es: "Imprimiendo", pt: "Imprimindo", it: "Stampa in corso", zh: "打印中")
        case "paused":   return lz(en: "Paused", de: "Pausiert", fr: "En pause", es: "Pausado", pt: "Pausado", it: "In pausa", zh: "已暂停")
        case "error":    return lz(en: "Error", de: "Fehler", fr: "Erreur", es: "Error", pt: "Erro", it: "Errore", zh: "错误")
        case "complete": return lz(en: "Done", de: "Fertig", fr: "Terminé", es: "Listo", pt: "Concluído", it: "Fatto", zh: "完成")
        case "standby":  return lz(en: "Ready", de: "Bereit", fr: "Prêt", es: "Listo", pt: "Pronto", it: "Pronto", zh: "就绪")
        default:         return lz(en: "Unknown", de: "Unbekannt", fr: "Inconnu", es: "Desconocido", pt: "Desconhecido", it: "Sconosciuto", zh: "未知")
        }
    }

    // Column span (in a 6-unit grid) for a tile width state.
    private func gridSpan(_ ews: Int) -> Int { ews == 2 ? 2 : (ews == 1 ? 3 : 6) }

    // One tile as it appears in the grid: editable in edit mode, otherwise the
    // normal tile with a long-press to enter edit mode.
    @ViewBuilder
    private func tileCell(for tile: DashboardItem) -> some View {
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

    // One dashboard row — mixed widths use a 6-unit Grid, uniform widths a LazyVGrid.
    @ViewBuilder
    private func dashboardRow(_ row: [DashboardItem], rowIndex: Int) -> some View {
        let eWSes = row.map { effectiveWidthState(for: $0) }
        let isMixedRow = eWSes.count > 1 && !eWSes.dropFirst().allSatisfy { $0 == eWSes[0] }
        if isMixedRow {
            mixedRow(row, eWSes: eWSes, rowIndex: rowIndex)
        } else {
            uniformRow(row, eWSes: eWSes, rowIndex: rowIndex)
        }
    }

    @ViewBuilder
    private func mixedRow(_ row: [DashboardItem], eWSes: [Int], rowIndex: Int) -> some View {
        let totalUnits = eWSes.reduce(0) { $0 + gridSpan($1) }
        let remainingUnits = 6 - totalUnits
        Grid(horizontalSpacing: 12, verticalSpacing: 0) {
            GridRow {
                ForEach(row) { tile in
                    tileCell(for: tile)
                        .gridCellColumns(gridSpan(effectiveWidthState(for: tile)))
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
    }

    @ViewBuilder
    private func uniformRow(_ row: [DashboardItem], eWSes: [Int], rowIndex: Int) -> some View {
        let ews0 = eWSes.first ?? 0
        let colCount = ews0 == 2 ? 3 : (ews0 == 1 ? 2 : 1)
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: colCount),
            spacing: 0
        ) {
            ForEach(row) { tile in
                tileCell(for: tile)
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

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 12) {
                    // Demo mode banner
                    if printer.isDemoMode {
                        HStack(spacing: 8) {
                            Image(systemName: "play.circle.fill").font(.system(size: 13, weight: .semibold))
                            Text(lz(en: "Demo Mode – No real printer connected", de: "Demo-Modus – Kein echter Drucker verbunden", fr: "Mode démo – Aucune imprimante connectée", es: "Modo demo – Sin impresora real", pt: "Modo Demo – Nenhuma impressora real conectada", it: "Modalità Demo – Nessuna stampante reale collegata", zh: "演示模式 – 未连接真实打印机"))
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
                            Text(lz(en: "Not connected", de: "Keine Verbindung", fr: "Non connecté", es: "Sin conexión", pt: "Não conectado", it: "Non connesso", zh: "未连接"))
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Button {
                                haptic(.light)
                                printer.fetchStatus()
                            } label: {
                                Text(lz(en: "Retry", de: "Erneut", fr: "Réessayer", es: "Reintentar", pt: "Repetir", it: "Riprova", zh: "重试"))
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
                        dashboardRow(rows[rowIndex], rowIndex: rowIndex)
                    }
                    Spacer(minLength: 20)
                }
                // Away from home (status via Live Activity, LAN unreachable) the
                // commands can't reach the printer — disable all tile controls so
                // they don't pretend to work. `.disabled` greys out the actual
                // controls (buttons/toggles/steppers) but leaves the info
                // displays (progress, temperatures) fully readable.
                .disabled(printer.isViaLiveActivity && !isEditMode)
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
                printer.fetchSpoolmanStatus()
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
            // Hide the emergency stop away from home (status via Live Activity,
            // LAN unreachable) — the command couldn't reach the printer anyway.
            if (printer.printState == "printing" || printer.printState == "paused") && !printer.isViaLiveActivity {
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
                    Button(lz(en: "Done", de: "Fertig", fr: "Terminé", es: "Listo", pt: "Concluído", it: "Fatto", zh: "完成")) {
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
        .alert(lz(en: "Emergency Stop?", de: "Notfall Stop?", fr: "Arrêt d'urgence ?", es: "¿Parada de emergencia?", pt: "Parada de Emergência?", it: "Arresto di emergenza?", zh: "紧急停止？"), isPresented: $showEmergencyConfirm) {
            Button(lz(en: "Stop", de: "Stoppen", fr: "Arrêter", es: "Detener", pt: "Parar", it: "Ferma", zh: "停止"), role: .destructive) { printer.emergencyStop() }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {}
        } message: { Text(lz(en: "The printer will stop immediately.", de: "Der Drucker wird sofort gestoppt.", fr: "L'imprimante s'arrête immédiatement.", es: "La impresora se detendrá inmediatamente.", pt: "A impressora irá parar imediatamente.", it: "La stampante si fermerà immediatamente.", zh: "打印机将立即停止。")) }
        .alert(lz(en: "Pause Print?", de: "Druck pausieren?", fr: "Mettre en pause ?", es: "¿Pausar impresión?", pt: "Pausar impressão?", it: "Mettere in pausa la stampa?", zh: "暂停打印？"), isPresented: $showPauseConfirm) {
            Button(lz(en: "Pause", de: "Pausieren", fr: "Pause", es: "Pausar", pt: "Pausar", it: "Pausa", zh: "暂停"), role: .destructive) { printer.sendCommand("pause") }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {}
        } message: { Text(lz(en: "The print will be paused.", de: "Der Druck wird unterbrochen.", fr: "L'impression sera mise en pause.", es: "La impresión se pausará.", pt: "A impressão será pausada.", it: "La stampa verrà messa in pausa.", zh: "打印将被暂停。")) }
        .alert(lz(en: "Resume Print?", de: "Druck fortsetzen?", fr: "Reprendre ?", es: "¿Reanudar impresión?", pt: "Retomar impressão?", it: "Riprendere la stampa?", zh: "继续打印？"), isPresented: $showResumeConfirm) {
            Button(lz(en: "Resume", de: "Fortsetzen", fr: "Reprendre", es: "Reanudar", pt: "Retomar", it: "Riprendi", zh: "继续")) { printer.sendCommand("resume") }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {}
        } message: { Text(lz(en: "The print will be resumed.", de: "Der Druck wird fortgesetzt.", fr: "L'impression reprendra.", es: "La impresión se reanudará.", pt: "A impressão será retomada.", it: "La stampa verrà ripresa.", zh: "打印将继续。")) }
        .alert(lz(en: "Stop Print?", de: "Druck abbrechen?", fr: "Arrêter l'impression ?", es: "¿Detener impresión?", pt: "Cancelar impressão?", it: "Interrompere la stampa?", zh: "停止打印？"), isPresented: $showCancelConfirm) {
            Button(lz(en: "Stop", de: "Abbrechen", fr: "Arrêter", es: "Detener", pt: "Parar", it: "Ferma", zh: "停止"), role: .destructive) { printer.sendCommand("cancel") }
            Button(lz(en: "Cancel", de: "Zurück", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {}
        } message: { Text(lz(en: "The current print will be cancelled.", de: "Der aktuelle Druck wird abgebrochen.", fr: "L'impression en cours sera annulée.", es: "La impresión actual será cancelada.", pt: "A impressão atual será cancelada.", it: "La stampa corrente verrà annullata.", zh: "当前打印将被取消。")) }
        .alert(lz(en: "Bed Temperature", de: "Bett Temperatur", fr: "Température du plateau", es: "Temperatura de la cama", pt: "Temperatura da Mesa", it: "Temperatura del Piano", zh: "热床温度"), isPresented: $showBedTempInput) {
            TextField(lz(en: "Target temp (°C)", de: "Zieltemperatur (°C)", fr: "Température cible (°C)", es: "Temperatura objetivo (°C)", pt: "Temperatura alvo (°C)", it: "Temperatura obiettivo (°C)", zh: "目标温度 (°C)"), text: $bedTempInput).keyboardType(.numberPad)
            Button(lz(en: "Set", de: "Setzen", fr: "Définir", es: "Establecer", pt: "Definir", it: "Imposta", zh: "设置")) { if let t = Double(bedTempInput) { printer.setBedTemp(target: t) } }
            Button(lz(en: "Off", de: "Aus", fr: "Éteindre", es: "Apagar", pt: "Desligar", it: "Spegni", zh: "关闭")) { printer.setBedTemp(target: 0) }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {}
        } message: { Text(lz(en: "Current: \(Int(printer.bedTemp))°C", de: "Aktuell: \(Int(printer.bedTemp))°C", fr: "Actuel : \(Int(printer.bedTemp))°C", es: "Actual: \(Int(printer.bedTemp))°C", pt: "Atual: \(Int(printer.bedTemp))°C", it: "Attuale: \(Int(printer.bedTemp))°C", zh: "当前：\(Int(printer.bedTemp))°C")) }
        .sheet(isPresented: $showSpoollinkSheet) { SpoollinkSheet(printer: printer) }
        .sheet(isPresented: $showFanSheet) {
            FanSliderSheet(title: fanSheetTitle, currentValue: fanSheetValue) { v in
                fanSheetSetter?(v)
            }
        }
        .alert(lz(en: "GCode Error", de: "GCode Fehler", fr: "Erreur GCode", es: "Error GCode", pt: "Erro de GCode", it: "Errore GCode", zh: "G代码错误"), isPresented: Binding(
            get: { printer.lastGCodeError != nil },
            set: { if !$0 { printer.lastGCodeError = nil } }
        )) {
            Button(lz(en: "OK", de: "OK", fr: "OK", es: "OK", pt: "OK", it: "OK", zh: "好"), role: .cancel) { printer.lastGCodeError = nil }
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

    // Small, size-stable chip shown under the finger while dragging. Using the
    // live tile here let flexible-height tiles (maxHeight: .infinity) blow up
    // mid-drag and made the layout look like it was jumping.
    @ViewBuilder
    private func dragPreview(for item: DashboardItem) -> some View {
        let tile = item.asStaticTile
        HStack(spacing: 8) {
            Image(systemName: tile?.icon ?? "square.grid.2x2.fill")
                .font(.system(size: 15, weight: .semibold))
            Text(tile?.label ?? settings.displayTitle(for: item.customGroupID ?? ""))
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.thinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
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
                            }
                            UserDefaults.standard.set(statusTileSize, forKey: lKey("status_tile_size"))
                        }
                    Spacer()
                }
            }
            } // end height button

            // Rotate button (bottom-left) — camera tiles on single-nozzle
            // printers only (the U1's WebRTC player with its native controls
            // doesn't rotate cleanly): turns the image in 90° steps, stored on
            // the printer via Moonraker (app-local fallback).
            if printer.printerType == .singleNozzle,
               item.rawID == DashboardTile.webcam.rawValue || item.rawID == DashboardTile.webcam2.rawValue {
            VStack(spacing: 0) {
                Spacer()
                HStack(spacing: 0) {
                    Image(systemName: "rotate.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color.purple.opacity(0.8)))
                        .contentShape(Rectangle())
                        .padding(6)
                        .onTapGesture {
                            haptic(.light)
                            withAnimation(.easeInOut(duration: 0.2)) {
                                printer.rotateCamera(item.rawID == DashboardTile.webcam2.rawValue ? 2 : 1)
                            }
                        }
                    Spacer()
                }
            }
            } // end rotate button
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
        // Compact, fixed-size drag preview — rendering the live tile made
        // flexible-height tiles balloon while being dragged.
        .draggable(item.rawID) { dragPreview(for: item) }
        // Insert (don't swap): the dropped tile takes this tile's place and this
        // tile — plus everything after it — slides down.
        .dropDestination(for: String.self) { droppedIDs, _ in
            guard let droppedID = droppedIDs.first, droppedID != item.rawID else { return false }
            dropTargetID = nil
            insertTile(withID: droppedID, at: item.rawID)
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

    // Status tile, split into small typed pieces so the type-checker stays fast.
    @ViewBuilder
    private func statusTile() -> some View {
        glassCard {
            VStack(spacing: 10) {
                statusHeaderRow
                if !printer.filename.isEmpty {
                    HStack {
                        Image(systemName: "doc.fill").font(.caption2).foregroundColor(.secondary)
                        Text(printer.filename).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        Spacer()
                    }
                }
                statusProgressBlock
                if printer.extruderTempHistories[0].count >= 4 {
                    TempSparklineView(
                        extruderHistories: printer.extruderTempHistories,
                        bedHistory: printer.bedTempHistory,
                        extruderColors: printer.filamentSlots.map { $0.color == .gray ? .orange : $0.color }
                    )
                    .frame(height: 26)
                    .padding(.vertical, 2)
                }
                if printer.printTimeElapsed > 0 { statusTimeRow }
                statusControlButtons
                // Speed & Flow — hidden in Stufe 3
                if statusTileSize < 2 { statusSpeedFlow }
                // Motor/MCU temps & current — hidden in Stufe 2 + 3
                if statusTileSize == 0 { statusHardwareInfo }
            }
        }
    }

    @ViewBuilder private var statusHeaderRow: some View {
        HStack {
            HStack(spacing: 6) {
                Circle().fill(stateColor).frame(width: 10, height: 10)
                    .shadow(color: stateColor.opacity(0.8), radius: 4)
                Text(stateLabel).font(.subheadline).bold().foregroundColor(stateColor)
            }
            Spacer()
            if printer.isOnline && !printer.isViaLiveActivity {
                Text("LIVE").font(.system(size: 10, weight: .bold)).foregroundColor(.green)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.green.opacity(0.15)).cornerRadius(5)
            } else if !printer.isOnline {
                HStack(spacing: 3) {
                    Image(systemName: "wifi.slash").font(.system(size: 9))
                    Text(printer.offlineSinceLabel).font(.system(size: 10, weight: .bold))
                }
                .foregroundColor(.red)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.red.opacity(0.12)).cornerRadius(5)
            }
        }
    }

    @ViewBuilder private var statusProgressBlock: some View {
        VStack(spacing: 4) {
            HStack {
                Text(lz(en: "Progress", de: "Fortschritt", fr: "Progression", es: "Progreso", pt: "Progresso", it: "Avanzamento", zh: "进度")).font(.caption2).foregroundColor(.secondary)
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
    }

    @ViewBuilder private var statusTimeRow: some View {
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

    @ViewBuilder private var statusControlButtons: some View {
        // Away from home the status comes from the Live Activity push (LAN
        // unreachable) — commands can't reach the printer, so grey the buttons
        // out instead of pretending they work.
        let canControl = !printer.isViaLiveActivity
        HStack(spacing: 8) {
            compactControlButton(label: lz(en: "Pause", de: "Pause", fr: "Pause", es: "Pausa", pt: "Pausar", it: "Pausa", zh: "暂停"), icon: "pause.fill",
                color: (canControl && printer.printState == "printing") ? .orange : Color.orange.opacity(0.25),
                active: canControl && printer.printState == "printing") {
                if canControl && printer.printState == "printing" { showPauseConfirm = true }
            }
            .disabled(!canControl)
            compactControlButton(label: lz(en: "Resume", de: "Weiter", fr: "Reprendre", es: "Reanudar", pt: "Retomar", it: "Riprendi", zh: "继续"), icon: "play.fill",
                color: (canControl && printer.printState == "paused") ? .green : Color.green.opacity(0.25),
                active: canControl && printer.printState == "paused") {
                if canControl && printer.printState == "paused" { showResumeConfirm = true }
            }
            .disabled(!canControl)
            compactControlButton(label: lz(en: "Stop", de: "Stopp", fr: "Arrêter", es: "Detener", pt: "Parar", it: "Ferma", zh: "停止"), icon: "stop.fill",
                color: (canControl && (printer.printState == "printing" || printer.printState == "paused")) ? .red : Color.red.opacity(0.25),
                active: canControl && (printer.printState == "printing" || printer.printState == "paused")) {
                if canControl && (printer.printState == "printing" || printer.printState == "paused") { showCancelConfirm = true }
            }
            .disabled(!canControl)
        }
    }

    @ViewBuilder private var statusSpeedFlow: some View {
        HStack(spacing: 0) {
            speedFlowControl(
                label: lz(en: "Speed", de: "Tempo", fr: "Vitesse", es: "Velocidad", pt: "Velocidade", it: "Velocità", zh: "速度"),
                icon: "speedometer", value: printer.speedFactor, color: .blue,
                onDecrease: { printer.setSpeedFactor(printer.speedFactor - 0.05) },
                onIncrease: { printer.setSpeedFactor(printer.speedFactor + 0.05) }
            )
            Divider().frame(height: 36)
            speedFlowControl(
                label: lz(en: "Flow", de: "Flow", fr: "Débit", es: "Flujo", pt: "Fluxo", it: "Flusso", zh: "流量"),
                icon: "drop.fill", value: printer.extrudeFactor, color: .teal,
                onDecrease: { printer.setExtrudeFactor(printer.extrudeFactor - 0.05) },
                onIncrease: { printer.setExtrudeFactor(printer.extrudeFactor + 0.05) }
            )
        }
        .background(Color.secondary.opacity(0.07)).cornerRadius(10)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    @ViewBuilder private var statusHardwareInfo: some View {
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
                hardwareInfoItem(label: lz(en: "Current", de: "Strom", fr: "Courant", es: "Corriente", pt: "Atual", it: "Attuale", zh: "当前"),
                                 value: String(format: "%.1fA", printer.currentDraw), icon: "bolt.fill", color: .yellow)
            }
        }
        .background(Color.secondary.opacity(0.07)).cornerRadius(10)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
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
                                rotation: printer.webcamRotation + printer.webcamUserRotation,
                                mirrorH: printer.webcamMirrorH,
                                mirrorV: printer.webcamMirrorV)
                    .aspectRatio(16/9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            } else if let webrtcURL = URL(string: "\(printer.baseURL)/webcam/webrtc") {
                WebView(url: webrtcURL,
                        videoRotation: printer.webcamRotation + printer.webcamUserRotation)
                    .aspectRatio(16/9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            }

        case .webcam2:
            if let streamURL = printer.webcam2StreamURL {
                if streamURL.absoluteString.contains("webrtc") {
                    WebView(url: streamURL,
                            videoRotation: printer.webcam2Rotation + printer.webcam2UserRotation)
                        .aspectRatio(16/9, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                } else {
                    MJPEGStreamView(streamURL: streamURL,
                                    rotation: printer.webcam2Rotation + printer.webcam2UserRotation,
                                    mirrorH: printer.webcam2MirrorH,
                                    mirrorV: printer.webcam2MirrorV)
                        .aspectRatio(16/9, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                }
            }

        case .status:
            statusTile()

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
                    } else if let screenURL = URL(string: "\(printer.baseURL)/screen/") {
                        WebView(url: screenURL, fitWidth: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .aspectRatio(5/3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            }

        case .extruder:
            if printer.printerType == .singleNozzle {
                // Brings its own header (matching the Heizbett tile's metrics).
                glassCard { SingleNozzleCombinedCard(printer: printer) }
            } else {
            glassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Extruder").font(.caption).fontWeight(.semibold)
                        .foregroundColor(.secondary).textCase(.uppercase).tracking(1)

                    if printer.extruderCount == 1 {
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
            } // end else (non single-nozzle extruder tile)

        case .filament:
            if printer.printerType == .singleNozzle {
                EmptyView()
            } else {
                glassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(lz(en: "Filament", de: "Filament", fr: "Filament", es: "Filamento", pt: "Filamento", it: "Filamento", zh: "耗材"))
                            .font(.caption).fontWeight(.semibold)
                            .foregroundColor(.secondary).textCase(.uppercase).tracking(1)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ConfirmableButton(
                                label: lz(en: "Eject", de: "Auswerfen", fr: "Éjecter", es: "Expulsar", pt: "Ejetar", it: "Espelli", zh: "退出"),
                                icon: "arrow.up.circle.fill", color: .orange,
                                confirmTitle: lz(en: "Eject Filament?", de: "Filament auswerfen?", fr: "Éjecter le filament ?", es: "¿Expulsar filamento?", pt: "Ejetar filamento?", it: "Espellere il filamento?", zh: "退出耗材？"),
                                confirmMessage: lz(en: "The filament will be unloaded.", de: "Das Filament wird ausgeworfen.", fr: "Le filament va être éjecté.", es: "El filamento será expulsado.", pt: "O filamento será removido.", it: "Il filamento verrà scaricato.", zh: "耗材将被卸载。"),
                                printer: printer) { printer.unloadFilament() }
                            ConfirmableButton(
                                label: lz(en: "Flush", de: "Spülen", fr: "Purger", es: "Purgar", pt: "Purgar", it: "Spurga", zh: "冲洗"),
                                icon: "arrow.down.circle.fill", color: .teal,
                                confirmTitle: lz(en: "Flush Filament?", de: "Filament spülen?", fr: "Purger le filament ?", es: "¿Purgar filamento?", pt: "Purgar filamento?", it: "Spurgare il filamento?", zh: "冲洗耗材？"),
                                confirmMessage: lz(en: "A flush sequence will run.", de: "Eine Spülsequenz wird ausgeführt.", fr: "Une séquence de purge va démarrer.", es: "Se ejecutará una secuencia de purga.", pt: "Uma sequência de purga será executada.", it: "Verrà eseguita una sequenza di spurgo.", zh: "将执行冲洗序列。"),
                                printer: printer) { printer.sendGCode("INNER_FLUSH_FILAMENT") }
                            ConfirmableButton(
                                label: lz(en: "Clean", de: "Reinigen", fr: "Nettoyer", es: "Limpiar", pt: "Limpar", it: "Pulisci", zh: "清洁"),
                                icon: "paintbrush.fill", color: .orange,
                                confirmTitle: lz(en: "Clean Nozzle?", de: "Düse reinigen?", fr: "Nettoyer la buse ?", es: "¿Limpiar boquilla?", pt: "Limpar bico?", it: "Pulire l'ugello?", zh: "清洁喷嘴？"),
                                confirmMessage: lz(en: "A nozzle cleaning sequence will run.", de: "Eine Düsenreinigung wird gestartet.", fr: "Une séquence de nettoyage de buse va démarrer.", es: "Se iniciará una secuencia de limpieza de boquilla.", pt: "Uma sequência de limpeza do bico será executada.", it: "Verrà eseguita una sequenza di pulizia dell'ugello.", zh: "将执行喷嘴清洁序列。"),
                                printer: printer) { printer.cleanNozzleRough() }
                            ConfirmableButton(
                                label: lz(en: "Clean + Purge", de: "Reinigen + Poop entsorgen", fr: "Nettoyer + Évacuer", es: "Limpiar + Desechar", pt: "Limpar + Purgar", it: "Pulisci + Spurga", zh: "清洁+冲洗"),
                                icon: "trash.circle.fill", color: .red,
                                confirmTitle: lz(en: "Clean + Purge?", de: "Reinigen + Poop entsorgen?", fr: "Nettoyer + Évacuer ?", es: "¿Limpiar + Desechar?", pt: "Limpar + Purgar?", it: "Pulire + Spurgare?", zh: "清洁+冲洗？"),
                                confirmMessage: lz(en: "Cleaning and purge discard will run.", de: "Reinigen und Poop entsorgen wird gestartet.", fr: "Le nettoyage et l'évacuation vont démarrer.", es: "Se iniciará la limpieza y descarte.", pt: "A limpeza e o descarte de purga serão executados.", it: "Verranno eseguiti la pulizia e lo scarico di spurgo.", zh: "将执行清洁和废料排出。"),
                                printer: printer) { printer.cleanNozzleRoughDiscard() }
                        }
                    }
                }
            }

        case .spools:
            if printer.printerType == .singleNozzle {
                EmptyView()
            } else {
            // With paxx12's Filament Manager present this tile becomes the
            // SpoolLink tile: same layout, but it opens the SpoolLink screen.
            // Without it (e.g. firmware 1.4.1) the tile stays exactly as before:
            // no chevron, no tap, no SpoolLink polling.
            // No opt-in switch: detecting paxx12's Filament Manager is enough.
            let spoollinkOn = printer.spoollinkAvailable
            glassCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 5) {
                        Text(spoollinkOn
                             ? "SpoolLink"
                             : lz(en: "Spools", de: "Spulen", fr: "Bobines", es: "Bobinas", pt: "Bobinas", it: "Bobine", zh: "料盘"))
                            .font(.caption).fontWeight(.semibold)
                            .foregroundColor(.secondary).textCase(.uppercase).tracking(1)
                        if spoollinkOn {
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                        }
                    }
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
                .contentShape(Rectangle())
                .onTapGesture { if spoollinkOn { showSpoollinkSheet = true } }
            }
            .onAppear { if spoollinkOn { printer.fetchSpoollinkState() } }
            } // end else singleNozzle

        case .cleaning:
            EmptyView()

        case .activeSpool:
            ActiveSpoolTileView(printer: printer)

        case .calibration:
            glassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(lz(en: "Calibration", de: "Kalibrierung", fr: "Calibration", es: "Calibración", pt: "Calibração", it: "Calibrazione", zh: "校准"))
                        .font(.caption).fontWeight(.semibold)
                        .foregroundColor(.secondary).textCase(.uppercase).tracking(1)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        if printer.printerType == .singleNozzle {
                            ConfirmableButton(
                                label: lz(en: "Bed Mesh", de: "Bett-Mesh", fr: "Maillage lit", es: "Malla cama", pt: "Malha da Mesa", it: "Mesh del Piano", zh: "热床网格"),
                                icon: "grid", color: .blue,
                                confirmTitle: lz(en: "Bed Mesh Calibrate?", de: "Bett-Mesh kalibrieren?", fr: "Calibrer le maillage ?", es: "¿Calibrar malla cama?", pt: "Calibrar malha da mesa?", it: "Calibrare la mesh del piano?", zh: "校准热床网格？"),
                                confirmMessage: lz(en: "This may take several minutes.", de: "Dies kann mehrere Minuten dauern.", fr: "Cela peut prendre plusieurs minutes.", es: "Esto puede tardar varios minutos.", pt: "Isso pode levar vários minutos.", it: "Potrebbe richiedere diversi minuti.", zh: "这可能需要几分钟。"),
                                printer: printer) { printer.calibrateBedMeshKlipper() }
                            ConfirmableButton(
                                label: lz(en: "Screw Tilt", de: "Schrauben", fr: "Réglage vis", es: "Inclinación", pt: "Inclinação dos Parafusos", it: "Inclinazione Viti", zh: "螺丝校平"),
                                icon: "arrow.up.and.down.and.arrow.left.and.right", color: .teal,
                                confirmTitle: lz(en: "Run Screw Tilt Adjust?", de: "Schrauben Abtasten starten?", fr: "Lancer réglage vis ?", es: "¿Ajustar inclinación?", pt: "Executar ajuste de inclinação dos parafusos?", it: "Eseguire la regolazione dell'inclinazione delle viti?", zh: "执行螺丝校平调整？"),
                                confirmMessage: lz(en: "This may take several minutes.", de: "Dies kann mehrere Minuten dauern.", fr: "Cela peut prendre plusieurs minutes.", es: "Esto puede tardar varios minutos.", pt: "Isso pode levar vários minutos.", it: "Potrebbe richiedere diversi minuti.", zh: "这可能需要几分钟。"),
                                printer: printer) { printer.calibrateScrewTilt() }
                            ConfirmableButton(
                                label: "Input Shaper X",
                                icon: "waveform.path", color: .orange,
                                confirmTitle: lz(en: "Run Input Shaper X?", de: "Input Shaper X starten?", fr: "Lancer Input Shaper X ?", es: "¿Ejecutar Input Shaper X?", pt: "Executar Input Shaper X?", it: "Eseguire Input Shaper X?", zh: "执行 X 轴输入整形？"),
                                confirmMessage: lz(en: "This may take several minutes.", de: "Dies kann mehrere Minuten dauern.", fr: "Cela peut prendre plusieurs minutes.", es: "Esto puede tardar varios minutos.", pt: "Isso pode levar vários minutos.", it: "Potrebbe richiedere diversi minuti.", zh: "这可能需要几分钟。"),
                                printer: printer) { printer.calibrateShaperX() }
                            ConfirmableButton(
                                label: "Input Shaper Y",
                                icon: "waveform", color: .purple,
                                confirmTitle: lz(en: "Run Input Shaper Y?", de: "Input Shaper Y starten?", fr: "Lancer Input Shaper Y ?", es: "¿Ejecutar Input Shaper Y?", pt: "Executar Input Shaper Y?", it: "Eseguire Input Shaper Y?", zh: "执行 Y 轴输入整形？"),
                                confirmMessage: lz(en: "This may take several minutes.", de: "Dies kann mehrere Minuten dauern.", fr: "Cela peut prendre plusieurs minutes.", es: "Esto puede tardar varios minutos.", pt: "Isso pode levar vários minutos.", it: "Potrebbe richiedere diversi minuti.", zh: "这可能需要几分钟。"),
                                printer: printer) { printer.calibrateShaperY() }
                        } else {
                            ConfirmableButton(
                                label: lz(en: "Bed Mesh", de: "Bett-Mesh", fr: "Maillage lit", es: "Malla cama", pt: "Malha da Mesa", it: "Mesh del Piano", zh: "热床网格"),
                                icon: "grid", color: .blue,
                                confirmTitle: lz(en: "Bed Mesh Calibrate?", de: "Bett-Mesh kalibrieren?", fr: "Calibrer le maillage ?", es: "¿Calibrar malla cama?", pt: "Calibrar malha da mesa?", it: "Calibrare la mesh del piano?", zh: "校准热床网格？"),
                                confirmMessage: lz(en: "This may take several minutes.", de: "Dies kann mehrere Minuten dauern.", fr: "Cela peut prendre plusieurs minutes.", es: "Esto puede tardar varios minutos.", pt: "Isso pode levar vários minutos.", it: "Potrebbe richiedere diversi minuti.", zh: "这可能需要几分钟。"),
                                printer: printer) { printer.calibrateBedMesh() }
                            ConfirmableButton(
                                label: lz(en: "Home All", de: "Alle homen", fr: "Homing complet", es: "Homing total", pt: "Home Geral", it: "Home Generale", zh: "全部回零"),
                                icon: "house.fill", color: .purple,
                                confirmTitle: lz(en: "Home all axes?", de: "Alle Achsen homen?", fr: "Homing de tous les axes ?", es: "¿Homear todos los ejes?", pt: "Fazer home de todos os eixos?", it: "Eseguire l'home di tutti gli assi?", zh: "所有轴回零？"),
                                confirmMessage: lz(en: "All axes will be homed (G28).", de: "Alle Achsen werden gehomt (G28).", fr: "Tous les axes vont être référencés (G28).", es: "Se iniciará el homing de todos los ejes (G28).", pt: "Todos os eixos serão referenciados (G28).", it: "Tutti gli assi verranno azzerati (G28).", zh: "所有轴将执行回零 (G28)。"),
                                printer: printer) { printer.homeAxes() }
                            ConfirmableButton(
                                label: lz(en: "XYZ Calibrate", de: "XYZ Kalibrierung", fr: "Calibration XYZ", es: "Calibración XYZ", pt: "Calibrar XYZ", it: "Calibra XYZ", zh: "XYZ 校准"),
                                icon: "move.3d", color: .green,
                                confirmTitle: lz(en: "XYZ Calibrate?", de: "XYZ Kalibrierung starten?", fr: "Calibrer XYZ ?", es: "¿Calibrar XYZ?", pt: "Calibrar XYZ?", it: "Calibrare XYZ?", zh: "执行 XYZ 校准？"),
                                confirmMessage: lz(en: "⚠️ Clean the nozzle thoroughly and remove the print plate before starting.", de: "⚠️ Düse gründlich reinigen und Druckplatte entfernen, bevor du startest.", fr: "⚠️ Nettoyer soigneusement la buse et retirer le plateau avant de démarrer.", es: "⚠️ Limpia bien la boquilla y retira la placa de impresión antes de empezar.", pt: "⚠️ Limpe bem o bico e remova a placa de impressão antes de iniciar.", it: "⚠️ Pulisci accuratamente l'ugello e rimuovi il piatto di stampa prima di iniziare.", zh: "⚠️ 开始前请彻底清洁喷嘴并取下打印板。"),
                                printer: printer) { printer.calibrateXYZ() }
                            ConfirmableButton(
                                label: "Input Shaper",
                                icon: "waveform", color: .orange,
                                confirmTitle: lz(en: "Run Input Shaper?", de: "Input Shaper starten?", fr: "Lancer Input Shaper ?", es: "¿Ejecutar Input Shaper?", pt: "Executar Input Shaper?", it: "Eseguire Input Shaper?", zh: "执行输入整形？"),
                                confirmMessage: lz(en: "This may take several minutes.", de: "Dies kann mehrere Minuten dauern.", fr: "Cela peut prendre plusieurs minutes.", es: "Esto puede tardar varios minutos.", pt: "Isso pode levar vários minutos.", it: "Potrebbe richiedere diversi minuti.", zh: "这可能需要几分钟。"),
                                printer: printer) { printer.calibrateShaper() }
                        }
                    }
                }
            }

        case .stats:
            glassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(lz(en: "Statistics", de: "Statistiken", fr: "Statistiques", es: "Estadísticas", pt: "Estatísticas", it: "Statistiche", zh: "统计"))
                        .font(.caption).fontWeight(.semibold)
                        .foregroundColor(.secondary).textCase(.uppercase).tracking(1)

                    if printer.totalJobs == 0 {
                        HStack {
                            Spacer()
                            VStack(spacing: 6) {
                                Image(systemName: "chart.bar.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(.secondary.opacity(0.4))
                                Text(lz(en: "No data yet", de: "Noch keine Daten", fr: "Pas encore de données", es: "Sin datos aún", pt: "Ainda sem dados", it: "Nessun dato ancora", zh: "暂无数据"))
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
                                label: lz(en: "Total Prints", de: "Drucke gesamt", fr: "Impressions", es: "Impresiones", pt: "Total de Impressões", it: "Stampe Totali", zh: "总打印次数"),
                                gradient: [Color(hex: "4facfe") ?? .blue, Color(hex: "00f2fe") ?? .cyan]
                            )
                            statCard(
                                icon: "clock.fill",
                                value: {
                                    let h = Int(printer.totalPrintTime) / 3600
                                    let m = (Int(printer.totalPrintTime) % 3600) / 60
                                    return h >= 100 ? "\(h)h" : (h > 0 ? "\(h)h \(m)m" : "\(m)m")
                                }(),
                                label: lz(en: "Print Time", de: "Druckzeit", fr: "Temps d'impression", es: "Tiempo total", pt: "Tempo de Impressão", it: "Tempo di Stampa", zh: "打印时间"),
                                gradient: [Color(hex: "a18cd1") ?? .purple, Color(hex: "fbc2eb") ?? .pink]
                            )
                            statCard(
                                icon: "cylinder.fill",
                                value: {
                                    let m = printer.totalFilamentUsedMm / 1000
                                    return m >= 1000 ? String(format: "%.0fm", m) : String(format: "%.1fm", m)
                                }(),
                                label: lz(en: "Filament", de: "Filament", fr: "Filament", es: "Filamento", pt: "Filamento", it: "Filamento", zh: "耗材"),
                                gradient: [Color(hex: "fd7043") ?? .orange, Color(hex: "ff8a65") ?? .orange]
                            )
                            statCard(
                                icon: "trophy.fill",
                                value: {
                                    let h = Int(printer.longestPrintTime) / 3600
                                    let m = (Int(printer.longestPrintTime) % 3600) / 60
                                    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
                                }(),
                                label: lz(en: "Longest Print", de: "Längster Druck", fr: "Plus long", es: "Más largo", pt: "Impressão Mais Longa", it: "Stampa Più Lunga", zh: "最长打印"),
                                gradient: [Color(hex: "43e97b") ?? .green, Color(hex: "38f9d7") ?? .teal]
                            )
                        }
                    }
                }
            }

        case .bed:
            glassCard {
                VStack(alignment: .leading, spacing: 6) {
                    // Header + temperature mirror the Extruder tile exactly, so
                    // both headers and both temperatures line up.
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: "square.stack.3d.up.fill").font(.system(size: 12)).foregroundColor(.orange)
                            Text(lz(en: "Heated Bed", de: "Heizbett", fr: "Plateau", es: "Cama", pt: "Mesa", it: "Piano", zh: "热床"))
                                .font(.caption2).fontWeight(.semibold).foregroundColor(.secondary).textCase(.uppercase).tracking(1).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "pencil").font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("\(Int(printer.bedTemp))").font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundColor(.primary).minimumScaleFactor(0.5).lineLimit(1)
                            Text("°C").font(.system(size: 14, weight: .medium)).foregroundColor(.secondary)
                            Spacer(minLength: 0)
                        }
                        Text(printer.bedTarget > 0
                             ? "→ \(Int(printer.bedTarget))°C"
                             : lz(en: "Off", de: "Aus", fr: "Éteint", es: "Apagado", pt: "Desligado", it: "Spento", zh: "关闭"))
                            .font(.system(size: 12, weight: .medium)).foregroundColor(.secondary).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { bedTempInput = "\(Int(printer.bedTarget))"; showBedTempInput = true }

                    // M600 lives here (not in the Extruder tile) so the two tiles
                    // in the row carry a similar amount of content.
                    if printer.printerType == .singleNozzle {
                        Button(action: { haptic(); printer.changeFilament() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.2.squarepath").font(.system(size: 12, weight: .semibold))
                                Text(lz(en: "Change (M600)", de: "Wechseln (M600)", fr: "Changer (M600)", es: "Cambiar (M600)", pt: "Trocar (M600)", it: "Cambia (M600)", zh: "更换 (M600)"))
                                    .font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(LinearGradient(colors: [.green, .green.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                }
            }

        case .chamber:
            if printer.printerType == .singleNozzle || !(printer.hasChamber || printer.printerType == .snapmakerU1) {
                EmptyView()
            } else {
                glassCard {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: "cube.transparent.fill").font(.system(size: 12)).foregroundColor(.purple)
                            Text(lz(en: "Chamber", de: "Bauraum", fr: "Enceinte", es: "Cámara", pt: "Câmara", it: "Camera", zh: "腔体"))
                                .font(.caption2).fontWeight(.semibold).foregroundColor(.secondary).textCase(.uppercase).tracking(1).lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                            Button(action: { printer.toggleChamberLed() }) {
                                Image(systemName: printer.chamberLedOn ? "lightbulb.fill" : "lightbulb")
                                    .font(.system(size: 14)).foregroundColor(printer.chamberLedOn ? .yellow : .secondary.opacity(0.5))
                            }.buttonStyle(.plain)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("\(Int(printer.chamberTemp))").font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundColor(.primary).minimumScaleFactor(0.5).lineLimit(1)
                            Text("°C").font(.system(size: 14, weight: .medium)).foregroundColor(.secondary)
                            Spacer(minLength: 0)
                        }
                        Button(action: {
                            fanSheetTitle = lz(en: "Cavity Fan", de: "Bauraum-Lüfter", fr: "Ventilateur enceinte", es: "Ventilador cámara", pt: "Ventoinha da Câmara", it: "Ventola della Camera", zh: "腔体风扇")
                            fanSheetValue = printer.cavityFanSpeed
                            fanSheetSetter = { printer.setCavityFanSpeed($0) }
                            showFanSheet = true
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: "fan.fill").font(.system(size: 11)).foregroundColor(.blue)
                                Text("\(Int(printer.cavityFanSpeed * 100))%").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                                if printer.purifierDetected {
                                    Image(systemName: "wind").font(.system(size: 10)).foregroundColor(.mint)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }

        case .preheat:
            if printer.printerType == .singleNozzle {
                PreheatTileView(printer: printer)
            } else {
                EmptyView()
            }

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
        // Top-aligned: in a row the shorter card stretches to its neighbour's
        // height, and centred content would drop its header below the taller
        // card's header. Top alignment keeps all tile headers on one line.
        ZStack(alignment: .top) {
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
                copyResultMessage = lz(en: "Download failed.", de: "Download fehlgeschlagen.", fr: "Échec du téléchargement.", es: "Error al descargar.", pt: "Falha no download.", it: "Download non riuscito.", zh: "下载失败。")
                showCopyResult = true
                return
            }
            target.uploadFileData(filename: file.filename, data: data) { success in
                isCopying = false
                copyResultMessage = success
                    ? lz(en: "'\(file.displayName)' copied to \(target.name).", de: "'\(file.displayName)' nach \(target.name) kopiert.", fr: "'\(file.displayName)' copié vers \(target.name).", es: "'\(file.displayName)' copiado a \(target.name).", pt: "'\(file.displayName)' copiado para \(target.name).", it: "'\(file.displayName)' copiato su \(target.name).", zh: "「\(file.displayName)」已复制到 \(target.name)。")
                    : lz(en: "Upload to \(target.name) failed.", de: "Upload zu \(target.name) fehlgeschlagen.", fr: "Échec de l'envoi vers \(target.name).", es: "Error al enviar a \(target.name).", pt: "Falha ao enviar para \(target.name).", it: "Caricamento su \(target.name) non riuscito.", zh: "上传到 \(target.name) 失败。")
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
                TextField(lz(en: "Search files...", de: "Datei suchen...", fr: "Rechercher...", es: "Buscar archivos...", pt: "Buscar arquivos...", it: "Cerca file...", zh: "搜索文件..."), text: $searchText)
            }
            .padding(10).background(.ultraThinMaterial).cornerRadius(10)
            .padding(.horizontal).padding(.vertical, 8)

            if printer.isLoadingFiles {
                Spacer(); ProgressView(lz(en: "Loading files...", de: "Lade Dateien...", fr: "Chargement...", es: "Cargando archivos...", pt: "Carregando arquivos...", it: "Caricamento file...", zh: "正在加载文件...")); Spacer()
            } else if let error = printer.fileError {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(.orange)
                    Text(error).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Button(lz(en: "Retry", de: "Erneut versuchen", fr: "Réessayer", es: "Reintentar", pt: "Repetir", it: "Riprova", zh: "重试")) { printer.fetchFiles() }.buttonStyle(.borderedProminent)
                }
                .padding(); Spacer()
            } else if printer.files.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "doc.badge.plus").font(.largeTitle).foregroundColor(.secondary)
                    Text(lz(en: "No G-Code Files", de: "Keine G-Code Dateien", fr: "Pas de fichiers G-Code", es: "Sin archivos G-Code", pt: "Nenhum arquivo G-Code", it: "Nessun file G-Code", zh: "没有 G-Code 文件")).foregroundColor(.secondary)
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
                                Label(lz(en: "Print", de: "Drucken", fr: "Imprimer", es: "Imprimir", pt: "Imprimir", it: "Stampa", zh: "打印"), systemImage: "play.fill")
                            }
                            if !otherServices.isEmpty {
                                if otherServices.count == 1 {
                                    Button {
                                        requestCopy(file, to: otherServices[0])
                                    } label: {
                                        Label(lz(en: "Send to \(otherServices[0].name)", de: "Senden an \(otherServices[0].name)", fr: "Envoyer à \(otherServices[0].name)", es: "Enviar a \(otherServices[0].name)", pt: "Enviar para \(otherServices[0].name)", it: "Invia a \(otherServices[0].name)", zh: "发送到 \(otherServices[0].name)"), systemImage: "arrow.right.circle")
                                    }
                                } else {
                                    Button {
                                        fileToCopy = file
                                        showCopyPicker = true
                                    } label: {
                                        Label(lz(en: "Send to printer…", de: "Senden an Drucker…", fr: "Envoyer à imprimante…", es: "Enviar a impresora…", pt: "Enviar para a impressora…", it: "Invia alla stampante…", zh: "发送到打印机…"), systemImage: "arrow.right.circle")
                                    }
                                }
                            }
                            Divider()
                            Button(role: .destructive) { fileToDelete = file } label: {
                                Label(lz(en: "Delete", de: "Löschen", fr: "Supprimer", es: "Eliminar", pt: "Excluir", it: "Elimina", zh: "删除"), systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { fileToDelete = file } label: { Label(lz(en: "Delete", de: "Löschen", fr: "Supprimer", es: "Eliminar", pt: "Excluir", it: "Elimina", zh: "删除"), systemImage: "trash") }
                            Button { fileToStart = file } label: { Label(lz(en: "Print", de: "Drucken", fr: "Imprimer", es: "Imprimir", pt: "Imprimir", it: "Stampa", zh: "打印"), systemImage: "play.fill") }.tint(.green)
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
        .alert(lz(en: "Delete File?", de: "Datei löschen?", fr: "Supprimer le fichier ?", es: "¿Eliminar archivo?", pt: "Excluir arquivo?", it: "Eliminare il file?", zh: "删除文件？"), isPresented: Binding(get: { fileToDelete != nil }, set: { if !$0 { fileToDelete = nil } })) {
            Button(lz(en: "Delete", de: "Löschen", fr: "Supprimer", es: "Eliminar", pt: "Excluir", it: "Elimina", zh: "删除"), role: .destructive) { if let f = fileToDelete { printer.deleteFile(filename: f.filename) }; fileToDelete = nil }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) { fileToDelete = nil }
        } message: { Text("\(fileToDelete?.displayName ?? "") \(lz(en: "really delete?", de: "wirklich löschen?", fr: "vraiment supprimer ?", es: "¿realmente eliminar?", pt: "excluir mesmo?", it: "eliminare davvero?", zh: "确定删除？"))") }
        .alert(lz(en: "Start Print?", de: "Druck starten?", fr: "Lancer l'impression ?", es: "¿Iniciar impresión?", pt: "Iniciar impressão?", it: "Avviare la stampa?", zh: "开始打印？"), isPresented: Binding(get: { fileToStart != nil }, set: { if !$0 { fileToStart = nil } })) {
            Button(lz(en: "Start", de: "Starten", fr: "Démarrer", es: "Iniciar", pt: "Iniciar", it: "Avvia", zh: "开始")) { if let f = fileToStart { printer.startPrint(filename: f.filename) }; fileToStart = nil }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) { fileToStart = nil }
        } message: { Text("\(fileToStart?.displayName ?? "") \(lz(en: "start printing?", de: "drucken?", fr: "lancer ?", es: "¿imprimir?", pt: "iniciar impressão?", it: "avviare la stampa?", zh: "开始打印？"))") }
        .alert(lz(en: "Result", de: "Ergebnis", fr: "Résultat", es: "Resultado", pt: "Resultado", it: "Risultato", zh: "结果"), isPresented: $showCopyResult) {
            Button("OK", role: .cancel) { copyResultMessage = nil }
        } message: { Text(copyResultMessage ?? "") }
        .alert(lz(en: "Different Printer Type", de: "Anderer Druckertyp", fr: "Type d'imprimante différent", es: "Tipo de impresora diferente", pt: "Tipo de impressora diferente", it: "Tipo di stampante diverso", zh: "不同的打印机类型"), isPresented: $showTypeMismatchWarning) {
            Button(lz(en: "Send anyway", de: "Trotzdem senden", fr: "Envoyer quand même", es: "Enviar de todos modos", pt: "Enviar mesmo assim", it: "Invia comunque", zh: "仍然发送")) {
                if let file = fileToCopy, let target = pendingCopyTarget {
                    copyFile(file, to: target)
                }
                pendingCopyTarget = nil
            }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {
                fileToCopy = nil
                pendingCopyTarget = nil
            }
        } message: {
            Text(lz(en: "The G-Code is not modified. The print may not work correctly on a different printer type.", de: "Der G-Code wird nicht angepasst. Der Druck funktioniert auf einem anderen Druckertyp möglicherweise nicht korrekt.", fr: "Le G-Code n'est pas modifié. L'impression peut ne pas fonctionner correctement sur un type d'imprimante différent.", es: "El G-Code no se modifica. La impresión puede no funcionar correctamente en un tipo de impresora diferente.", pt: "O G-Code não é modificado. A impressão pode não funcionar corretamente em um tipo de impressora diferente.", it: "Il G-Code non viene modificato. La stampa potrebbe non funzionare correttamente su un tipo di stampante diverso.", zh: "G-Code 不会被修改。在不同类型的打印机上可能无法正常打印。"))
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
                .navigationTitle(lz(en: "Send to printer", de: "Senden an Drucker", fr: "Envoyer à", es: "Enviar a", pt: "Enviar para a impressora", it: "Invia alla stampante", zh: "发送到打印机"))
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarItems(trailing: Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消")) {
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
                        Text(lz(en: "Copying…", de: "Kopieren…", fr: "Copie en cours…", es: "Copiando…", pt: "Copiando…", it: "Copia in corso…", zh: "正在复制…"))
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
                        Text(lz(en: "Files", de: "Dateien", fr: "Fichiers", es: "Archivos", pt: "Arquivos", it: "File", zh: "文件")).tag(1)
                        if showKlipperTab {
                            Text("Klipper").tag(2)
                        }
                        if showTimelapseTab {
                            Text("Timelapse").tag(3)
                        }
                        if showFirmwareTab {
                            Text(lz(en: "Config", de: "Konfiguration", fr: "Config", es: "Config", pt: "Configuração", it: "Configurazione", zh: "配置")).tag(4)
                        }
                    }
                    .pickerStyle(.segmented).padding()
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if selectedTab == 0 { DashboardView(printer: printerService, printerID: printerID) }
                else if selectedTab == 1 { FilesView(printer: printerService, allServices: allServices) }
                else if selectedTab == 2 && showKlipperTab {
                    if let klipperURL = URL(string: printerService.baseURL) {
                        WebView(url: klipperURL)
                            .ignoresSafeArea(edges: .bottom)
                    }
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
            // Don't build the paged TabView until printers are loaded. During
            // the brief launch window the list is empty, and an empty paged
            // TabView writes its selection back to 0 — which would overwrite
            // the restored "last printer page".
            if printers.isEmpty {
                Color.clear
            } else {
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
            }

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
                Text(lz(en: "Background Color", de: "Hintergrundfarbe", fr: "Couleur de fond", es: "Color de fondo", pt: "Cor de Fundo", it: "Colore di Sfondo", zh: "背景颜色"))
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
                Text(lz(en: "App Color", de: "App-Farbe", fr: "Couleur de l'app", es: "Color de la app", pt: "Cor do App", it: "Colore App", zh: "应用颜色"))
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
                Section(header: Text(lz(en: "Command", de: "Befehl", fr: "Commande", es: "Comando", pt: "Comando", it: "Comando", zh: "命令"))) {
                    TextField(lz(en: "Name (e.g. Clean Nozzle)", de: "Name (z.B. Düse reinigen)", fr: "Nom", es: "Nombre", pt: "Nome (ex.: Limpar Bico)", it: "Nome (es. Pulisci Ugello)", zh: "名称（例如：清洁喷嘴）"),
                              text: $command.name)
                    TextField(lz(en: "GCode / Macro", de: "GCode / Makro", fr: "GCode / Macro", es: "GCode / Macro", pt: "GCode / Macro", it: "GCode / Macro", zh: "GCode / 宏"), text: $command.gcode)
                        .textInputAutocapitalization(.characters)
                        .font(.system(.body, design: .monospaced))
                }

                Section(header: Text(lz(en: "Color", de: "Farbe", fr: "Couleur", es: "Color", pt: "Cor", it: "Colore", zh: "颜色"))) {
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

                Section(header: Text(lz(en: "Icon", de: "Symbol", fr: "Icône", es: "Ícono", pt: "Ícone", it: "Icona", zh: "图标"))) {
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

                Section(header: Text(lz(en: "Preview", de: "Vorschau", fr: "Aperçu", es: "Vista previa", pt: "Pré-visualização", it: "Anteprima", zh: "预览"))) {
                    HStack(spacing: 0) {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: command.sfSymbol.isEmpty ? "terminal.fill" : command.sfSymbol)
                                .font(.system(size: 22, weight: .semibold))
                            Text(command.name.isEmpty ? lz(en: "Name", de: "Name", fr: "Nom", es: "Nombre", pt: "Nome", it: "Nome", zh: "名称") : command.name)
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

                Section(header: Text(lz(en: "Printer", de: "Drucker", fr: "Imprimante", es: "Impresora", pt: "Impressora", it: "Stampante", zh: "打印机"))) {
                    Picker(lz(en: "For which printer?", de: "Für welchen Drucker?", fr: "Pour quelle imprimante?", es: "¿Para qué impresora?", pt: "Para qual impressora?", it: "Per quale stampante?", zh: "适用于哪台打印机？"),
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

                Section(header: Text(lz(en: "Examples", de: "Beispiele", fr: "Exemples", es: "Ejemplos", pt: "Exemplos", it: "Esempi", zh: "示例"))) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(lz(en: "Klipper macro (defined in printer.cfg):", de: "Klipper-Makro (in printer.cfg definiert):", fr: "Macro Klipper (définie dans printer.cfg):", es: "Macro Klipper (definida en printer.cfg):", pt: "Macro Klipper (definida em printer.cfg):", it: "Macro Klipper (definita in printer.cfg):", zh: "Klipper 宏（在 printer.cfg 中定义）："),
                              systemImage: "info.circle")
                            .font(.caption).foregroundColor(.secondary)
                        Text("MY_MACRO PARAM=value\nBED_MESH_CALIBRATE\nCLEAN_NOZZLE")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.purple)
                            .padding(8).background(Color.purple.opacity(0.07)).cornerRadius(8)
                        Label(lz(en: "Standard GCode / console command:", de: "Standard GCode / Konsolenbefehl:", fr: "GCode standard / commande console:", es: "GCode estándar / comando consola:", pt: "GCode padrão / comando de console:", it: "GCode standard / comando console:", zh: "标准 GCode / 控制台命令："),
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
                ? lz(en: "New Command", de: "Neuer Befehl", fr: "Nouvelle commande", es: "Nuevo comando", pt: "Novo Comando", it: "Nuovo Comando", zh: "新建命令")
                : lz(en: "Edit Command", de: "Befehl bearbeiten", fr: "Modifier la commande", es: "Editar comando", pt: "Editar Comando", it: "Modifica Comando", zh: "编辑命令"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(lz(en: "Save", de: "Speichern", fr: "Enregistrer", es: "Guardar", pt: "Salvar", it: "Salva", zh: "保存")) {
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
    @AppStorage("spoolman_enabled") private var spoolmanEnabled: Bool = false
    @AppStorage("spoolman_url") private var spoolmanURL: String = ""
    @State private var showResetConfirm = false
    @Environment(\.editMode) private var editMode
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var donations = DonationManager()
    @EnvironmentObject var tour: TourGuide

    private var isIPad: Bool { horizontalSizeClass == .regular }

    var body: some View {
        NavigationStack {
            ScrollViewReader { tourProxy in
            settingsForm
                .collectTourFrames(tour)
                .overlay { tourSettingsOverlay }
                .onChange(of: tour.step) { _, s in
                    tourScroll(s, proxy: tourProxy)
                    // The tour drives the last step: open the top printer's sheet
                    // so the Server-Push coach mark can point inside it.
                    if s == .serverPush, editingPrinter == nil {
                        editingPrinter = settings.printers.first
                    }
                }
                .onAppear {
                    // The step is usually already .spoolman when this tab appears.
                    if tour.isActive { tourScroll(tour.step, proxy: tourProxy) }
                }
                .navigationTitle(lz(en: "Settings", de: "Einstellungen", fr: "Paramètres", es: "Ajustes", pt: "Configurações", it: "Impostazioni", zh: "设置"))
                .toolbar { EditButton() }
                .sheet(isPresented: $showAddPrinter) {
                    PrinterEditView(config: PrinterConfig(name: "", ip: "", type: .snapmakerU1)) { newPrinter in
                        settings.printers.append(newPrinter)
                        onSave()
                    }
                    .environmentObject(tour)
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
                    .environmentObject(tour)
                }
                .sheet(isPresented: $showNetworkScan) {
                    NetworkScanView(settings: settings, onSave: onSave)
                }
            }
        }
    }

    // Scroll the Settings list so the highlighted row sits centred in view.
    private func tourScroll(_ step: TourStep, proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation {
                switch step {
                case .spoolman: proxy.scrollTo("tourSpoolmanRow", anchor: .center)
                case .printer:  proxy.scrollTo(settings.printers.first?.id, anchor: .center)
                default: break
                }
            }
        }
    }

    // Coach-mark overlay for the steps that live inside the Settings list.
    @ViewBuilder
    private var tourSettingsOverlay: some View {
        switch tour.step {
        case .spoolman:
            ZStack {
                TourSpotlight(hole: tour.spoolmanFrame, interactive: false)
                VStack {
                    Spacer()
                    TourCallout(
                        title: "Spoolman",
                        text: lz(en: "Here you'll find Spoolman — your filament manager.",
                                 de: "Hier findest du Spoolman – deine Filamentverwaltung.",
                                 fr: "Ici tu trouves Spoolman – ton gestionnaire de filament.",
                                 es: "Aquí encuentras Spoolman, tu gestor de filamento.",
                                 pt: "Aqui você encontra o Spoolman, seu gerenciador de filamento.",
                                 it: "Qui trovi Spoolman, il tuo gestore di filamento.",
                                 zh: "在这里可以找到 Spoolman（耗材管理）。"),
                        okTitle: "OK",
                        onOK: { withAnimation { tour.confirmSpoolman() } }
                    )
                    .padding(.bottom, 24)
                }
            }
        case .printer:
            ZStack {
                TourSpotlight(hole: tour.printerFrame, interactive: false)
                VStack {
                    Spacer()
                    TourCallout(
                        title: lz(en: "Your printer", de: "Dein Drucker", fr: "Ton imprimante", es: "Tu impresora", pt: "Sua impressora", it: "La tua stampante", zh: "你的打印机"),
                        text: lz(en: "This is your printer. Its push settings are inside.",
                                 de: "Das ist dein Drucker. Seine Push-Einstellungen sind hier drin.",
                                 fr: "Voici ton imprimante. Ses réglages push sont à l'intérieur.",
                                 es: "Esta es tu impresora. Sus ajustes de push están dentro.",
                                 pt: "Esta é a sua impressora. As configurações de push ficam aqui dentro.",
                                 it: "Questa è la tua stampante. Le impostazioni push sono qui dentro.",
                                 zh: "这是你的打印机。推送设置就在里面。"),
                        okTitle: lz(en: "Next", de: "Weiter", fr: "Suivant", es: "Siguiente", pt: "Próximo", it: "Avanti", zh: "下一步"),
                        onOK: { withAnimation { tour.confirmPrinter() } }
                    )
                    .padding(.bottom, 24)
                }
            }
        default:
            EmptyView()
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
                Text(lz(en: "Select a setting on the left", de: "Links eine Einstellung wählen", fr: "Sélectionner un paramètre à gauche", es: "Seleccionar un ajuste a la izquierda", pt: "Selecione uma configuração à esquerda", it: "Seleziona un'impostazione a sinistra", zh: "请在左侧选择一项设置"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var settingsForm: some View {
        Form {
                Section(header: Text(lz(en: "Language", de: "Sprache", fr: "Langue", es: "Idioma", pt: "Idioma", it: "Lingua", zh: "语言"))) {
                    HStack {
                        Image(systemName: "globe").foregroundColor(.blue).frame(width: 28)
                        Picker(lz(en: "Language", de: "Sprache", fr: "Langue", es: "Idioma", pt: "Idioma", it: "Lingua", zh: "语言"), selection: $langStore.current) {
                            Text("🇬🇧 English").tag("en")
                            Text("🇩🇪 Deutsch").tag("de")
                            Text("🇫🇷 Français").tag("fr")
                            Text("🇪🇸 Español").tag("es")
                            Text("🇵🇹 Português").tag("pt")
                            Text("🇮🇹 Italiano").tag("it")
                            Text("🇨🇳 中文").tag("zh")
                        }
                        .pickerStyle(.menu)
                    }
                }
                Section(header: Text(lz(en: "Extra Features", de: "Zusatzfunktionen", fr: "Fonctions supplémentaires", es: "Funciones adicionales", pt: "Recursos Extras", it: "Funzioni Extra", zh: "附加功能"))) {
                    HStack {
                        Image(systemName: "rectangle.grid.1x2").foregroundColor(.indigo).frame(width: 28)
                        Toggle(lz(en: "Printers as Tabs", de: "Drucker als einzelne Tabs", fr: "Imprimantes en onglets", es: "Impresoras comme pestañas", pt: "Impressoras como Abas", it: "Stampanti come Schede", zh: "打印机以标签页显示"), isOn: $printersAsTabs)
                    }
                    if isIPad {
                        HStack {
                            Image(systemName: "rectangle.split.2x1").foregroundColor(.teal).frame(width: 28)
                            Toggle(lz(en: "Split Screen (iPad)", de: "Splitscreen (iPad)", fr: "Écran partagé (iPad)", es: "Pantalla dividida (iPad)", pt: "Tela Dividida (iPad)", it: "Schermo Diviso (iPad)", zh: "分屏（iPad）"), isOn: $splitscreenMode)
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
                        Toggle(lz(en: "Firmware Configuration", de: "Firmware Konfiguration", fr: "Configuration Firmware", es: "Configuración Firmware", pt: "Configuração de Firmware", it: "Configurazione Firmware", zh: "固件配置"), isOn: $expertModeEnabled)
                    }
                    HStack {
                        Image(systemName: "record.circle.fill").foregroundColor(.pink).frame(width: 28)
                        Toggle("Spoolman", isOn: $spoolmanEnabled)
                    }
                    .id("tourSpoolmanRow")
                    .tourTarget(.spoolman)
                    if spoolmanEnabled {
                        HStack {
                            Image(systemName: "network").foregroundColor(.pink).frame(width: 28)
                            TextField(lz(en: "Spoolman address e.g. 192.168.178.50:7912", de: "Spoolman-Adresse z.B. 192.168.178.50:7912", fr: "Adresse Spoolman p.ex. 192.168.178.50:7912", es: "Dirección Spoolman p.ej. 192.168.178.50:7912", pt: "Endereço Spoolman ex.: 192.168.178.50:7912", it: "Indirizzo Spoolman es. 192.168.178.50:7912", zh: "Spoolman 地址，例如 192.168.178.50:7912"), text: $spoolmanURL)
                                .keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true)
                        }
                    }
                }
                Section(header: Text(lz(en: "My Printers", de: "Meine Drucker", fr: "Mes imprimantes", es: "Mis impresoras", pt: "Minhas Impressoras", it: "Le mie Stampanti", zh: "我的打印机"))) {
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
                                // Make the WHOLE row tappable (Spacer gaps
                                // included), not just the rendered content.
                                .contentShape(Rectangle())
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
                        .tourTarget(printer.id == settings.printers.first?.id ? .printer : .inactive)
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
                        for p in removed {
                            SSHCredentialStore.delete(for: p.name)
                            SSHUsernameStore.delete(for: p.name)
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
                            Text(lz(en: "Add Printer", de: "Drucker hinzufügen", fr: "Ajouter une imprimante", es: "Agregar impresora", pt: "Adicionar Impressora", it: "Aggiungi Stampante", zh: "添加打印机")).foregroundColor(.green)
                        }
                    }
                    Button(action: { showNetworkScan = true }) {
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundColor(.blue)
                            Text(lz(en: "Search Network", de: "Im Netzwerk suchen", fr: "Chercher sur le réseau", es: "Buscar en la red", pt: "Buscar na Rede", it: "Cerca in Rete", zh: "搜索网络")).foregroundColor(.blue)
                        }
                    }
                }
                // MARK: Custom Commands Section — one Section per tile group
                ForEach(settings.customCommandGroups) { group in
                    let groupIdx = settings.customCommandGroups.firstIndex(where: { $0.id == group.id })
                    Section(header: Text(lz(en: "My Commands / Macros", de: "Eigene Befehle / Makros", fr: "Mes commandes / Macros", es: "Mis comandos / Macros", pt: "Meus Comandos / Macros", it: "I miei Comandi / Macro", zh: "我的命令 / 宏"))) {
                        // Tile title — swipe left to delete the whole group
                        HStack(spacing: 8) {
                            Image(systemName: "pencil.line").foregroundColor(.secondary).frame(width: 24)
                            if let gi = groupIdx {
                                TextField(lz(en: "Tile title (optional)", de: "Kachelname (optional)", fr: "Titre de la tuile (optionnel)", es: "Título del mosaico (opcional)", pt: "Título do bloco (opcional)", it: "Titolo riquadro (opzionale)", zh: "卡片标题（可选）"),
                                          text: $settings.customCommandGroups[gi].title)
                                    .font(.body)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                settings.customCommands.removeAll { $0.groupID == group.id }
                                settings.customCommandGroups.removeAll { $0.id == group.id }
                            } label: {
                                Label(lz(en: "Delete", de: "Löschen", fr: "Supprimer", es: "Eliminar", pt: "Excluir", it: "Elimina", zh: "删除"), systemImage: "trash")
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
                                Text(lz(en: "Add Command", de: "Befehl hinzufügen", fr: "Ajouter une commande", es: "Agregar comando", pt: "Adicionar Comando", it: "Aggiungi Comando", zh: "添加命令")).foregroundColor(.purple)
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
                            Text(lz(en: "Add another Tile", de: "Weitere Kachel hinzufügen", fr: "Ajouter une autre tuile", es: "Agregar otro mosaico", pt: "Adicionar outro bloco", it: "Aggiungi un altro riquadro", zh: "添加另一个卡片")).foregroundColor(.purple)
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
                    header: Label(lz(en: "Support the App", de: "App unterstützen", fr: "Soutenir l'app", es: "Apoyar la app", pt: "Apoiar o App", it: "Supporta l'App", zh: "支持本应用"), systemImage: "heart.fill")
                        .foregroundStyle(.red),
                    footer: Text(lz(en: "PaxxMaker is a hobby project. A small tip helps cover the running costs and keeps development alive. I'm always open to suggestions and feedback — just send me a message!\n\nSubscriptions auto-renew unless cancelled at least 24 hours before the end of the current period. Manage or cancel in your Apple ID settings.", de: "PaxxMaker ist ein Hobbyprojekt. Eine kleine Spende hilft, die Eigenkosten zu decken und die Weiterentwicklung zu ermöglichen. Für Anregungen und Verbesserungsvorschläge bin ich jederzeit offen – schreib mir einfach!\n\nAbonnements verlängern sich automatisch, sofern sie nicht mindestens 24 Stunden vor Ende des aktuellen Zeitraums gekündigt werden. Verwalten oder kündigen in den Apple-ID-Einstellungen.", fr: "PaxxMaker est un projet hobby. Un petit pourboire aide à couvrir les coûts. Je suis toujours ouvert aux suggestions — écrivez-moi !\n\nLes abonnements se renouvellent automatiquement sauf annulation au moins 24 heures avant la fin de la période en cours. Gérez ou annulez dans les réglages de votre identifiant Apple.", es: "PaxxMaker es un proyecto hobby. Una propina ayuda a cubrir los costes. ¡Estoy abierto a sugerencias — escríbeme!\n\nLas suscripciones se renuevan automáticamente a menos que se cancelen al menos 24 horas antes del final del período actual. Gestiona o cancela en los ajustes de tu ID de Apple.", pt: "PaxxMaker é um projeto de hobby. Uma pequena contribuição ajuda a cobrir os custos operacionais e mantém o desenvolvimento vivo. Estou sempre aberto a sugestões e feedback — é só me enviar uma mensagem!\n\nAs assinaturas são renovadas automaticamente, a menos que sejam canceladas pelo menos 24 horas antes do fim do período atual. Gerencie ou cancele nas configurações da sua Apple ID.", it: "PaxxMaker è un progetto hobbistico. Un piccolo contributo aiuta a coprire i costi di gestione e mantiene vivo lo sviluppo. Sono sempre aperto a suggerimenti e feedback — scrivimi pure un messaggio!\n\nGli abbonamenti si rinnovano automaticamente a meno che non vengano annullati almeno 24 ore prima della fine del periodo corrente. Gestisci o annulla nelle impostazioni del tuo ID Apple.", zh: "PaxxMaker 是一个业余爱好项目。一点小小的赞助有助于支付运行成本，让开发得以持续。我随时欢迎建议和反馈——请随时给我留言！\n\n订阅会自动续订，除非在当前订阅周期结束前至少 24 小时取消。您可以在 Apple ID 设置中管理或取消订阅。"))
                ) {
                    if donations.purchaseSuccess || donations.isSubscribed {
                        Label(lz(en: "Thank you for your support!", de: "Danke für deine Unterstützung!", fr: "Merci pour ton soutien !", es: "¡Gracias por tu apoyo!", pt: "Obrigado pelo seu apoio!", it: "Grazie per il tuo supporto!", zh: "感谢您的支持！"),
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    if donations.isSubscribed {
                        Link(destination: URL(string: "https://apps.apple.com/account/subscriptions")!) {
                            Label(lz(en: "Manage Subscription", de: "Abonnement verwalten", fr: "Gérer l'abonnement", es: "Gestionar suscripción", pt: "Gerenciar Assinatura", it: "Gestisci Abbonamento", zh: "管理订阅"),
                                  systemImage: "arrow.up.right.square")
                                .font(.subheadline)
                                .foregroundStyle(.blue)
                        }
                    }

                    if !donations.hasProducts && !donations.didFinishLoading {
                        HStack {
                            ProgressView().scaleEffect(0.8)
                            Text(lz(en: "Loading…", de: "Laden…", fr: "Chargement…", es: "Cargando…", pt: "Carregando…", it: "Caricamento…", zh: "加载中…"))
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                        .onAppear { Task { await donations.load() } }
                    } else if !donations.hasProducts && donations.didFinishLoading {
                        Text(lz(en: "In-App Purchases are currently unavailable.", de: "In-App-Käufe sind derzeit nicht verfügbar.", fr: "Les achats intégrés ne sont pas disponibles.", es: "Las compras no están disponibles.", pt: "As compras no app estão indisponíveis no momento.", it: "Gli acquisti in-app non sono al momento disponibili.", zh: "应用内购买当前不可用。"))
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
                                            Text(lz(en: "Small Support", de: "Kleine Spende", fr: "Petit soutien", es: "Pequeño apoyo", pt: "Apoio Pequeno", it: "Supporto Piccolo", zh: "小额支持"))
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
                                            Text(lz(en: "Large Support", de: "Große Spende", fr: "Grand soutien", es: "Gran apoyo", pt: "Apoio Grande", it: "Supporto Grande", zh: "大额支持"))
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
                                        Text(lz(en: "Monthly Supporter", de: "Monatlicher Unterstützer", fr: "Soutien mensuel", es: "Apoyo mensual", pt: "Apoiador Mensal", it: "Sostenitore Mensile", zh: "月度支持者"))
                                            .font(.subheadline.weight(.semibold))
                                        Text(lz(en: "\(monthly.displayPrice)/month", de: "\(monthly.displayPrice)/Monat", fr: "\(monthly.displayPrice)/mois", es: "\(monthly.displayPrice)/mes", pt: "\(monthly.displayPrice)/mês", it: "\(monthly.displayPrice)/mese", zh: "\(monthly.displayPrice)/月"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if donations.activeSubscriptionID == DonationManager.monthlyID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    } else {
                                        Text(donations.activeSubscriptionID == DonationManager.annualID
                                             ? lz(en: "Switch", de: "Wechseln", fr: "Changer", es: "Cambiar", pt: "Trocar", it: "Cambia", zh: "切换")
                                             : lz(en: "Subscribe", de: "Abonnieren", fr: "S'abonner", es: "Suscribirse", pt: "Assinar", it: "Abbonati", zh: "订阅"))
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
                                        Text(lz(en: "Annual Supporter", de: "Jährlicher Unterstützer", fr: "Soutien annuel", es: "Apoyo anual", pt: "Apoiador Anual", it: "Sostenitore Annuale", zh: "年度支持者"))
                                            .font(.subheadline.weight(.semibold))
                                        Text(lz(en: "\(annual.displayPrice)/year", de: "\(annual.displayPrice)/Jahr", fr: "\(annual.displayPrice)/an", es: "\(annual.displayPrice)/año", pt: "\(annual.displayPrice)/ano", it: "\(annual.displayPrice)/anno", zh: "\(annual.displayPrice)/年"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if donations.activeSubscriptionID == DonationManager.annualID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    } else {
                                        Text(donations.activeSubscriptionID == DonationManager.monthlyID
                                             ? lz(en: "Switch", de: "Wechseln", fr: "Changer", es: "Cambiar", pt: "Trocar", it: "Cambia", zh: "切换")
                                             : lz(en: "Subscribe", de: "Abonnieren", fr: "S'abonner", es: "Suscribirse", pt: "Assinar", it: "Abbonati", zh: "订阅"))
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
                        Label(lz(en: "Send Feedback / Suggestions", de: "Feedback & Anregungen senden", fr: "Envoyer des suggestions", es: "Enviar sugerencias", pt: "Enviar Feedback / Sugestões", it: "Invia Feedback / Suggerimenti", zh: "发送反馈/建议"),
                              systemImage: "envelope.fill")
                            .foregroundStyle(.blue)
                    }

                    Link(destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!) {
                        Label(lz(en: "Terms of Use (EULA)", de: "Nutzungsbedingungen (EULA)", fr: "Conditions d'utilisation (EULA)", es: "Términos de uso (EULA)", pt: "Termos de Uso (EULA)", it: "Termini di Utilizzo (EULA)", zh: "使用条款（EULA）"),
                              systemImage: "doc.text")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }

                    Link(destination: URL(string: "https://github.com/DanielR1c/paxxmaker-privacy/blob/main/Privacy%20Policy%20%E2%80%93%20PaxxMaker%20U1.md")!) {
                        Label(lz(en: "Privacy Policy", de: "Datenschutz", fr: "Politique de confidentialité", es: "Política de privacidad", pt: "Política de Privacidade", it: "Informativa sulla Privacy", zh: "隐私政策"),
                              systemImage: "hand.raised")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                }

                Section(header: Text(lz(en: "Reset", de: "Zurücksetzen", fr: "Réinitialiser", es: "Restablecer", pt: "Redefinir", it: "Ripristina", zh: "重置"))) {
                    Button(action: { showResetConfirm = true }) {
                        HStack {
                            Image(systemName: "arrow.counterclockwise").foregroundColor(.red)
                            Text(lz(en: "Reset Setup", de: "Einrichtung zurücksetzen", fr: "Réinitialiser la configuration", es: "Restablecer configuración", pt: "Redefinir Configuração", it: "Ripristina Configurazione", zh: "重置设置")).foregroundColor(.red)
                        }
                    }
                    .confirmationDialog(
                        lz(en: "Reset Setup?", de: "Einrichtung zurücksetzen?", fr: "Réinitialiser la configuration ?", es: "¿Restablecer configuración?", pt: "Redefinir configuração?", it: "Ripristinare la configurazione?", zh: "重置设置？"),
                        isPresented: $showResetConfirm, titleVisibility: .visible
                    ) {
                        Button(lz(en: "Reset", de: "Zurücksetzen", fr: "Réinitialiser", es: "Restablecer", pt: "Redefinir", it: "Ripristina", zh: "重置"),
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
                        Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {}
                    } message: {
                        Text(lz(en: "All printers and settings will be permanently deleted. This cannot be undone.", de: "Alle Drucker und Einstellungen werden unwiderruflich gelöscht.", fr: "Toutes les imprimantes et tous les réglages seront définitivement supprimés.", es: "Todas las impresoras y ajustes se eliminarán de forma permanente.", pt: "Todas as impressoras e configurações serão excluídas permanentemente. Isso não pode ser desfeito.", it: "Tutte le stampanti e le impostazioni verranno eliminate permanentemente. Questa azione non può essere annullata.", zh: "所有打印机和设置将被永久删除，且无法撤销。"))
                    }
                }

                Section(header: Text(lz(en: "Legal", de: "Rechtliches", fr: "Mentions légales", es: "Legal", pt: "Jurídico", it: "Note legali", zh: "法律"))) {
                    NavigationLink {
                        OpenSourceLicensesView()
                    } label: {
                        HStack {
                            Image(systemName: "doc.text").foregroundColor(.secondary).frame(width: 28)
                            Text(lz(en: "Open Source Licenses", de: "Open-Source-Lizenzen", fr: "Licences open source", es: "Licencias de código abierto", pt: "Licenças de código aberto", it: "Licenze open source", zh: "开源许可"))
                        }
                    }
                    if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                        HStack {
                            Text(lz(en: "Version", de: "Version", fr: "Version", es: "Versión", pt: "Versão", it: "Versione", zh: "版本")).foregroundColor(.secondary)
                            Spacer()
                            Text(v).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
}

// MARK: - Open Source Licenses
struct OpenSourceLicensesView: View {
    private let libssh2License = """
    Copyright (C) 2004-2007 Sara Golemon <sarag@libssh2.org>
    Copyright (C) 2005-2006 Mikhail Gusarov <dottedmag@dottedmag.net>
    Copyright (C) 2006-2007 The Written Word, Inc.
    Copyright (C) 2007 Eli Fant <elifantu@mail.ru>
    Copyright (C) 2009-2023 Daniel Stenberg
    Copyright (C) 2008, 2009 Simon Josefsson
    Copyright (C) 2000 Markus Friedl
    Copyright (C) 2015 Microsoft Corp.
    All rights reserved.

    Redistribution and use in source and binary forms, with or without \
    modification, are permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright notice, \
       this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright notice, \
       this list of conditions and the following disclaimer in the documentation \
       and/or other materials provided with the distribution.

    3. Neither the name of the copyright holder nor the names of its contributors \
       may be used to endorse or promote products derived from this software \
       without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" \
    AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE \
    IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE \
    ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE \
    LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR \
    CONSEQUENTIAL DAMAGES HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER \
    IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) \
    ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE \
    POSSIBILITY OF SUCH DAMAGE.
    """

    // Standard GPL-3.0 notice as published by the FSF.
    private let gplNotice = """
    This program is free software: you can redistribute it and/or modify it \
    under the terms of the GNU General Public License as published by the Free \
    Software Foundation, either version 3 of the License, or (at your option) \
    any later version.

    This program is distributed in the hope that it will be useful, but \
    WITHOUT ANY WARRANTY; without even the implied warranty of \
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General \
    Public License for more details.

    You should have received a copy of the GNU General Public License along \
    with this program. If not, see <https://www.gnu.org/licenses/>.
    """

    var body: some View {
        List {
            Section {
                DisclosureGroup("GNU GPL v3.0") {
                    Text(gplNotice)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }
                Link(destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!) {
                    Label(lz(en: "Full licence text", de: "Vollständiger Lizenztext", fr: "Texte complet de la licence", es: "Texto completo de la licencia", pt: "Texto completo da licença", it: "Testo completo della licenza", zh: "许可证全文"),
                          systemImage: "arrow.up.right.square")
                }
                Link(destination: URL(string: "https://github.com/Klipper3d/klipper")!) {
                    Label("Klipper — GPL-3.0", systemImage: "arrow.up.right.square")
                }
                Link(destination: URL(string: "https://github.com/Arksine/moonraker")!) {
                    Label("Moonraker — GPL-3.0", systemImage: "arrow.up.right.square")
                }
                Link(destination: URL(string: "https://github.com/paxx12-snapmaker-u1/SnapmakerU1-Extended-Firmware")!) {
                    Label("paxx12 (Snapmaker U1 Extended Firmware) — GPL-3.0", systemImage: "arrow.up.right.square")
                }
            } header: {
                Text(lz(en: "GNU General Public License v3.0", de: "GNU General Public License v3.0", fr: "Licence publique générale GNU v3.0", es: "Licencia Pública General GNU v3.0", pt: "Licença Pública Geral GNU v3.0", it: "Licenza Pubblica Generica GNU v3.0", zh: "GNU 通用公共许可证 v3.0"))
            } footer: {
                Text(lz(
                    en: "Klipper, Moonraker and the paxx12 Extended Firmware are licensed under the GPL-3.0. PaxxMaker talks to them over their network APIs and does not include or modify their source code.",
                    de: "Klipper, Moonraker und die paxx12 Extended Firmware stehen unter der GPL-3.0. PaxxMaker spricht über deren Netzwerk-Schnittstellen mit ihnen und enthält oder verändert deren Quellcode nicht.",
                    fr: "Klipper, Moonraker et le firmware étendu paxx12 sont sous licence GPL-3.0. PaxxMaker communique via leurs API réseau et n'inclut ni ne modifie leur code source.",
                    es: "Klipper, Moonraker y el firmware extendido paxx12 se licencian bajo GPL-3.0. PaxxMaker se comunica mediante sus API de red y no incluye ni modifica su código fuente.",
                    pt: "Klipper, Moonraker e o firmware estendido paxx12 são licenciados sob a GPL-3.0. O PaxxMaker se comunica por suas APIs de rede e não inclui nem modifica seu código-fonte.",
                    it: "Klipper, Moonraker e il firmware esteso paxx12 sono rilasciati con licenza GPL-3.0. PaxxMaker comunica tramite le loro API di rete e non include né modifica il loro codice sorgente.",
                    zh: "Klipper、Moonraker 与 paxx12 扩展固件均采用 GPL-3.0 许可。PaxxMaker 通过其网络 API 通信，不包含也不修改其源代码。"))
            }
            Section {
                Link(destination: URL(string: "https://github.com/Donkie/Spoolman")!) {
                    Label("Spoolman — MIT", systemImage: "arrow.up.right.square")
                }
                Link(destination: URL(string: "https://github.com/QuinnDamerell/OctoPrint-OctoEverywhere")!) {
                    Label("OctoEverywhere — AGPL-3.0", systemImage: "arrow.up.right.square")
                }
            } header: {
                Text(lz(en: "Other projects", de: "Weitere Projekte", fr: "Autres projets", es: "Otros proyectos", pt: "Outros projetos", it: "Altri progetti", zh: "其他项目"))
            } footer: {
                Text(lz(
                    en: "Spoolman is MIT-licensed, OctoEverywhere is under the AGPL-3.0. PaxxMaker only uses their network APIs.",
                    de: "Spoolman steht unter der MIT-Lizenz, OctoEverywhere unter der AGPL-3.0. PaxxMaker nutzt ausschließlich deren Netzwerk-Schnittstellen.",
                    fr: "Spoolman est sous licence MIT, OctoEverywhere sous AGPL-3.0. PaxxMaker n'utilise que leurs API réseau.",
                    es: "Spoolman tiene licencia MIT y OctoEverywhere AGPL-3.0. PaxxMaker solo usa sus API de red.",
                    pt: "O Spoolman é licenciado sob MIT e o OctoEverywhere sob AGPL-3.0. O PaxxMaker usa apenas suas APIs de rede.",
                    it: "Spoolman è rilasciato con licenza MIT, OctoEverywhere con AGPL-3.0. PaxxMaker ne usa solo le API di rete.",
                    zh: "Spoolman 采用 MIT 许可，OctoEverywhere 采用 AGPL-3.0。PaxxMaker 仅使用它们的网络 API。"))
            }
            Section {
                DisclosureGroup("libssh2") {
                    Text(libssh2License)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                }
            } header: {
                Text(lz(en: "Bundled libraries", de: "Enthaltene Bibliotheken", fr: "Bibliothèques incluses", es: "Bibliotecas incluidas", pt: "Bibliotecas incluídas", it: "Librerie incluse", zh: "内置库"))
            } footer: {
                Text(lz(
                    en: "PaxxMaker communicates with Spoolman, OctoEverywhere and Moonraker/Klipper over their network APIs. Those run as separate software on your own devices and their code is not included in this app.",
                    de: "PaxxMaker kommuniziert mit Spoolman, OctoEverywhere und Moonraker/Klipper über deren Netzwerk-Schnittstellen. Diese laufen als eigenständige Software auf deinen eigenen Geräten; ihr Code ist nicht Teil dieser App.",
                    fr: "PaxxMaker communique avec Spoolman, OctoEverywhere et Moonraker/Klipper via leurs API réseau. Ces logiciels s'exécutent séparément sur vos propres appareils ; leur code n'est pas inclus dans cette app.",
                    es: "PaxxMaker se comunica con Spoolman, OctoEverywhere y Moonraker/Klipper a través de sus API de red. Se ejecutan como software independiente en tus propios dispositivos y su código no se incluye en esta app.",
                    pt: "O PaxxMaker se comunica com Spoolman, OctoEverywhere e Moonraker/Klipper por suas APIs de rede. Eles rodam como software separado nos seus próprios dispositivos e o código não está incluído neste app.",
                    it: "PaxxMaker comunica con Spoolman, OctoEverywhere e Moonraker/Klipper tramite le loro API di rete. Questi girano come software separato sui tuoi dispositivi e il loro codice non è incluso in questa app.",
                    zh: "PaxxMaker 通过网络 API 与 Spoolman、OctoEverywhere 和 Moonraker/Klipper 通信。它们作为独立软件运行在你自己的设备上，其代码不包含在本应用中。"))
            }
        }
        .navigationTitle(lz(en: "Licenses", de: "Lizenzen", fr: "Licences", es: "Licencias", pt: "Licenças", it: "Licenze", zh: "许可"))
        .navigationBarTitleDisplayMode(.inline)
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
                        Text(lz(en: "Connect with OctoEverywhere", de: "Mit OctoEverywhere verbinden", fr: "Connexion à OctoEverywhere", es: "Conectar con OctoEverywhere", pt: "Conectar com OctoEverywhere", it: "Connetti con OctoEverywhere", zh: "通过 OctoEverywhere 连接"))
                            .font(.title2).bold().multilineTextAlignment(.center)
                        Text(lz(en: "Access your printer from anywhere", de: "Greife von überall auf deinen Drucker zu", fr: "Accède à ton imprimante depuis n'importe où", es: "Accede a tu impresora desde cualquier lugar", pt: "Acesse sua impressora de qualquer lugar", it: "Accedi alla tua stampante da qualsiasi luogo", zh: "随时随地访问您的打印机"))
                            .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                    if printerType == .snapmakerU1 {
                        step(number: 1, icon: "gearshape.fill", color: .blue,
                             title: lz(en: "Enable Firmware Configuration", de: "Firmware-Konfiguration aktivieren", fr: "Activer la configuration firmware", es: "Activar configuración firmware", pt: "Ativar Configuração de Firmware", it: "Abilita Configurazione Firmware", zh: "启用固件配置"),
                             text: lz(en: "Open PaxxMaker → Settings → enable \"Firmware Configuration\" under Extra Features.", de: "Öffne PaxxMaker → Einstellungen → aktiviere \"Firmware-Konfiguration\" unter Zusatzfunktionen.", fr: "Ouvre PaxxMaker → Paramètres → active \"Configuration Firmware\" sous Fonctions supplémentaires.", es: "Abre PaxxMaker → Ajustes → activa \"Configuración Firmware\" en Funciones adicionales.", pt: "Abra o PaxxMaker → Configurações → ative \"Configuração de Firmware\" em Recursos Extras.", it: "Apri PaxxMaker → Impostazioni → abilita \"Configurazione Firmware\" in Funzioni Extra.", zh: "打开 PaxxMaker → 设置 → 在附加功能中启用\"固件配置\"。"))

                        step(number: 2, icon: "printer.fill", color: .blue,
                             title: lz(en: "Open Printer Configuration", de: "Drucker-Konfiguration öffnen", fr: "Ouvrir la configuration imprimante", es: "Abrir configuración impresora", pt: "Abrir Configuração da Impressora", it: "Apri Configurazione Stampante", zh: "打开打印机配置"),
                             text: lz(en: "Switch to the Printer tab → tap \"Configuration\" → select \"Cloud Access\".", de: "Wechsle zum Drucker-Tab → tippe auf \"Konfiguration\" → wähle \"Cloud Access\".", fr: "Passe à l'onglet Imprimante → appuie sur \"Configuration\" → sélectionne \"Cloud Access\".", es: "Cambia a la pestaña Impresora → pulsa \"Configuración\" → selecciona \"Cloud Access\".", pt: "Vá para a aba Impressora → toque em \"Configuração\" → selecione \"Cloud Access\".", it: "Vai alla scheda Stampante → tocca \"Configurazione\" → seleziona \"Cloud Access\".", zh: "切换到打印机标签页 → 点击\"配置\" → 选择\"云访问\"。"))

                        step(number: 3, icon: "cloud.fill", color: .orange,
                             title: lz(en: "Activate OctoEverywhere", de: "OctoEverywhere aktivieren", fr: "Activer OctoEverywhere", es: "Activar OctoEverywhere", pt: "Ativar OctoEverywhere", it: "Attiva OctoEverywhere", zh: "激活 OctoEverywhere"),
                             text: lz(en: "Enable OctoEverywhere in the cloud access settings. You will receive a connection code.", de: "Aktiviere OctoEverywhere in den Cloud-Access-Einstellungen. Du erhältst einen Verbindungscode.", fr: "Active OctoEverywhere dans les paramètres d'accès cloud. Tu recevras un code de connexion.", es: "Activa OctoEverywhere en los ajustes de acceso cloud. Recibirás un código de connexion.", pt: "Ative o OctoEverywhere nas configurações de acesso à nuvem. Você receberá um código de conexão.", it: "Abilita OctoEverywhere nelle impostazioni di accesso cloud. Riceverai un codice di connessione.", zh: "在云访问设置中启用 OctoEverywhere。您将收到一个连接码。"))

                        step(number: 4, icon: "person.crop.circle.badge.checkmark", color: .orange,
                             title: lz(en: "Register at OctoEverywhere", de: "Bei OctoEverywhere registrieren", fr: "S'inscrire sur OctoEverywhere", es: "Registrarse en OctoEverywhere", pt: "Registrar-se no OctoEverywhere", it: "Registrati su OctoEverywhere", zh: "在 OctoEverywhere 注册"),
                             text: lz(en: "Go to octoeverywhere.com and sign in. Enter the connection code from step 3 to link your printer.", de: "Gehe zu octoeverywhere.com und melde dich an. Gib den Verbindungscode aus Schritt 3 ein, um deinen Drucker zu verknüpfen.", fr: "Va sur octoeverywhere.com et connecte-toi. Saisis le code de connexion de l'étape 3 pour lier ton imprimante.", es: "Ve a octoeverywhere.com e inicia sesión. Introduce el código de conexión del paso 3 para vincular tu impresora.", pt: "Acesse octoeverywhere.com e faça login. Insira o código de conexão da etapa 3 para vincular sua impressora.", it: "Vai su octoeverywhere.com e accedi. Inserisci il codice di connessione del passaggio 3 per collegare la tua stampante.", zh: "前往 octoeverywhere.com 并登录。输入第 3 步中的连接码以关联您的打印机。"))
                    }

                    let startStep = printerType == .snapmakerU1 ? 5 : 1
                    step(number: startStep, icon: "iphone", color: .orange,
                         title: lz(en: "Create App Connection", de: "App-Verbindung erstellen", fr: "Créer une connexion App", es: "Crear conexión App", pt: "Criar Conexão do App", it: "Crea Connessione App", zh: "创建应用连接"),
                         text: lz(en: "Open your printer in OctoEverywhere → tap \"iOS And Android Apps\" → enter an app name (e.g. \"PaxxMaker\") → select your printer → tap \"Create\".", de: "Öffne deinen Drucker in OctoEverywhere → tippe auf \"iOS And Android Apps\" → gib einen App-Namen ein (z.B. \"PaxxMaker\") → wähle deinen Drucker → tippe auf \"Create\".", fr: "Ouvre ton imprimante dans OctoEverywhere → appuie sur \"iOS And Android Apps\" → entre un nom (ex. \"PaxxMaker\") → sélectionne ton imprimante → appuie sur \"Create\".", es: "Abre tu impresora en OctoEverywhere → pulsa \"iOS And Android Apps\" → introduce un nombre (p.ej. \"PaxxMaker\") → selecciona tu impresora → pulsa \"Create\".", pt: "Abra sua impressora no OctoEverywhere → toque em \"iOS And Android Apps\" → digite um nome de app (ex.: \"PaxxMaker\") → selecione sua impressora → toque em \"Create\".", it: "Apri la tua stampante in OctoEverywhere → tocca \"iOS And Android Apps\" → inserisci un nome app (es. \"PaxxMaker\") → seleziona la tua stampante → tocca \"Create\".", zh: "在 OctoEverywhere 中打开您的打印机 → 点击 \"iOS And Android Apps\" → 输入应用名称（例如 \"PaxxMaker\"）→ 选择您的打印机 → 点击 \"Create\"。"))

                    step(number: startStep + 1, icon: "doc.on.clipboard", color: .orange,
                         title: lz(en: "Copy URL", de: "URL kopieren", fr: "Copier l'URL", es: "Copiar URL", pt: "Copiar URL", it: "Copia URL", zh: "复制网址"),
                         text: lz(en: "OctoEverywhere generates a unique URL for this app connection. Copy it.", de: "OctoEverywhere generiert eine einzigartige URL für diese App-Verbindung. Kopiere sie.", fr: "OctoEverywhere génère une URL unique pour cette connexion. Copie-la.", es: "OctoEverywhere genera una URL única para esta conexión. Cópiala.", pt: "O OctoEverywhere gera uma URL exclusiva para esta conexão do app. Copie-a.", it: "OctoEverywhere genera un URL univoco per questa connessione app. Copialo.", zh: "OctoEverywhere 会为此应用连接生成一个唯一的网址。请复制它。"))

                    HStack {
                        Spacer()
                        VStack(alignment: .center, spacing: 4) {
                            Text(lz(en: "URL Format", de: "URL-Format", fr: "Format URL", es: "Formato URL", pt: "Formato da URL", it: "Formato URL", zh: "网址格式")).font(.caption2).foregroundColor(.secondary)
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
                         title: lz(en: "Enter in the App", de: "In der App eintragen", fr: "Saisir dans l'App", es: "Introducir en la App", pt: "Inserir no App", it: "Inserisci nell'App", zh: "在应用中输入"),
                         text: lz(en: "Open PaxxMaker → Settings → your printer → enable OctoEverywhere toggle → paste the URL and save.\n\nOptional: Find the API key in Moonraker under Settings → API Key.", de: "Öffne PaxxMaker → Einstellungen → deinen Drucker → aktiviere den OctoEverywhere-Schalter → füge die URL ein und speichere.\n\nOptional: Den API-Key findest du in Moonraker unter Einstellungen → API-Schlüssel.", fr: "Ouvre PaxxMaker → Paramètres → ton imprimante → active le commutateur OctoEverywhere → colle l'URL et enregistre.\n\nOptionnel : Trouve la clé API dans Moonraker sous Paramètres → Clé API.", es: "Abre PaxxMaker → Ajustes → tu impresora → activa el interruptor OctoEverywhere → pega la URL y guarda.\n\nOpcional: Encuentra la clave API en Moonraker en Ajustes → Clave API.", pt: "Abra o PaxxMaker → Configurações → sua impressora → ative a opção OctoEverywhere → cole a URL e salve.\n\nOpcional: Encontre a chave da API no Moonraker em Configurações → API Key.", it: "Apri PaxxMaker → Impostazioni → la tua stampante → attiva l'interruttore OctoEverywhere → incolla l'URL e salva.\n\nOpzionale: trova la chiave API in Moonraker in Impostazioni → API Key.", zh: "打开 PaxxMaker → 设置 → 您的打印机 → 启用 OctoEverywhere 开关 → 粘贴网址并保存。\n\n可选：在 Moonraker 的「设置 → API Key」中找到 API 密钥。"))

                    Spacer(minLength: 20)
                }
                .padding(20)
            }
            .navigationTitle(lz(en: "OctoEverywhere Setup", de: "OctoEverywhere einrichten", fr: "Config. OctoEverywhere", es: "Configurar OctoEverywhere", pt: "Configuração do OctoEverywhere", it: "Configurazione OctoEverywhere", zh: "OctoEverywhere 设置"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button(lz(en: "Done", de: "Fertig", fr: "Terminé", es: "Listo", pt: "Concluído", it: "Fatto", zh: "完成")) { dismiss() })
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
    @State private var showPushInfo = false
    @State private var showLocalSwitchConfirm = false
    @EnvironmentObject var tour: TourGuide
    // Shared with PushAutoSetupView (via @Binding) so switching to Local reuses
    // the exact same SSH credentials as that card's own "Remove from printer"
    // button, instead of an independent lookup that could drift out of sync.
    @State private var sshUsername = ""
    @State private var sshPassword = ""

    // Derived SSH connection details for the printer (used when switching to Local)
    private var pushHost: String {
        config.ip
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .components(separatedBy: ":").first?
            .trimmingCharacters(in: .whitespaces) ?? config.ip
    }
    // Standard Klipper hosts have a per-install username detected during setup
    // (e.g. "Ender3S1", not always "pi") — use the saved one if we have it.
    private var pushUser: String {
        if config.type == .snapmakerU1 { return "root" }
        return SSHUsernameStore.load(for: config.name) ?? "pi"
    }
    private var pushDefaultPassword: String { config.type == .snapmakerU1 ? "snapmaker" : "" }

    // Switch to Local push. Always unregisters this device (which triggers the
    // bridge's self-shutdown on its next event), and optionally removes the
    // script from the printer right away over SSH.
    private func switchToLocal(removeViaSSH: Bool) {
        let secret = config.cloudflareNotifySecret
        let pid = config.name
        if !secret.isEmpty, let token = CloudflarePushService.shared.storedDeviceToken {
            Task { await CloudflarePushService.shared.unregisterDeviceToken(
                workerURL: CloudflarePushService.workerURL, printerID: pid, secret: secret, deviceToken: token) }
        }
        config.pushMode = .off
        pushStatusMsg = nil
        guard removeViaSSH, !secret.isEmpty else { return }
        // Reuse the SAME credentials as this printer's own "Remove from
        // printer" button (hoisted @State, shared via @Binding with
        // PushAutoSetupView) — falls back to Keychain/UserDefaults only if
        // that card was somehow never shown this session.
        let host = pushHost
        let user = sshUsername.isEmpty ? pushUser : sshUsername
        let storedPW = sshPassword.isEmpty ? SSHCredentialStore.load(for: pid) : sshPassword
        // No known password (e.g. push was set up before this device stored
        // credentials) — an SSH attempt would fail with a scary red error for
        // no useful reason. Just say calmly what already happens automatically.
        guard let pw = storedPW ?? (pushDefaultPassword.isEmpty ? nil : pushDefaultPassword) else {
            pushStatusIsError = false
            pushStatusMsg = lz(en: "No saved SSH password — the script will remove itself automatically on the next print.", de: "Kein gespeichertes SSH-Passwort — das Script entfernt sich beim nächsten Druck automatisch selbst.", fr: "Aucun mot de passe SSH enregistré — le script se supprime automatiquement à la prochaine impression.", es: "Sin contraseña SSH guardada — el script se eliminará automáticamente en la próxima impresión.", pt: "Nenhuma senha SSH salva — o script se remove automaticamente na próxima impressão.", it: "Nessuna password SSH salvata — lo script si rimuoverà automaticamente alla prossima stampa.", zh: "没有已保存的 SSH 密码——脚本将在下次打印时自动移除自己。")
            return
        }
        pushIsWorking = true
        pushStatusIsError = false
        pushStatusMsg = lz(en: "Removing from printer…", de: "Entferne vom Drucker…", fr: "Suppression de l'imprimante…", es: "Eliminando de la impresora…", pt: "Removendo da impressora…", it: "Rimozione dalla stampante…", zh: "正在从打印机移除…")
        Task {
            do {
                _ = try await SSHInstaller.uninstall(host: host, user: user, password: pw,
                                                     workerURL: CloudflarePushService.workerURL, secret: secret,
                                                     useSudo: config.type == .singleNozzle)
                await MainActor.run {
                    pushIsWorking = false; pushStatusIsError = false
                    pushStatusMsg = lz(en: "Removed from printer ✓", de: "Vom Drucker entfernt ✓", fr: "Retiré de l'imprimante ✓", es: "Eliminado de la impresora ✓", pt: "Removido da impressora ✓", it: "Rimosso dalla stampante ✓", zh: "已从打印机移除 ✓")
                    SSHCredentialStore.delete(for: pid)
                    SSHUsernameStore.delete(for: pid)
                }
            } catch {
                await MainActor.run {
                    pushIsWorking = false; pushStatusIsError = true
                    pushStatusMsg = lz(en: "Couldn't remove via SSH — the script stops itself on the next print.", de: "Konnte nicht per SSH entfernt werden — das Script stoppt sich beim nächsten Druck selbst.", fr: "Impossible de retirer via SSH — le script s'arrête au prochain impression.", es: "No se pudo eliminar por SSH — el script se detiene en la próxima impresión.", pt: "Não foi possível remover via SSH — o script para sozinho na próxima impressão.", it: "Impossibile rimuovere via SSH — lo script si ferma alla prossima stampa.", zh: "无法通过 SSH 移除——脚本会在下次打印时自行停止。")
                }
            }
        }
    }

    @State private var showSmartPlugGuide = false


    // Normalise fields, persist, register push, then close the sheet.
    private func performSave() {
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
    }

    // Coach-mark shown inside this sheet, pointing at the Server-Push row.
    @ViewBuilder
    private var tourServerPushOverlay: some View {
        if tour.step == .serverPush {
            ZStack {
                TourSpotlight(hole: tour.serverPushFrame, interactive: false)
                VStack {
                    Spacer()
                    TourCallout(
                        title: lz(en: "Server Push", de: "Server-Push", fr: "Push serveur", es: "Push servidor", pt: "Push do Servidor", it: "Push dal Server", zh: "服务器推送"),
                        text: lz(en: "Here you'll find Server Push.",
                                 de: "Hier findest du Server-Push.",
                                 fr: "Ici tu trouves le push serveur.",
                                 es: "Aquí encuentras el Push del servidor.",
                                 pt: "Aqui você encontra o Push do Servidor.",
                                 it: "Qui trovi il Push dal Server.",
                                 zh: "在这里可以找到服务器推送。"),
                        okTitle: lz(en: "Got it", de: "Verstanden", fr: "Compris", es: "Entendido", pt: "Entendi", it: "Capito", zh: "明白了"),
                        onOK: {
                            withAnimation { tour.confirmServerPush() }
                            onDismiss?(); dismiss()
                        }
                    )
                    .padding(.bottom, 24)
                }
            }
        }
    }

    var body: some View {
        NavigationView {
            ScrollViewReader { tourProxy in
            Form {
                Section(header: Text(lz(en: "Printer Info", de: "Drucker Info", fr: "Infos imprimante", es: "Info impresora", pt: "Informações da Impressora", it: "Informazioni Stampante", zh: "打印机信息"))) {
                    HStack {
                        Image(systemName: "tag").foregroundColor(.blue)
                        TextField(lz(en: "Name", de: "Name", fr: "Nom", es: "Nombre", pt: "Nome", it: "Nome", zh: "名称"), text: $config.name)
                    }
                    HStack {
                        Image(systemName: "network").foregroundColor(.blue)
                        TextField(lz(en: "Local IP e.g. 192.168.178.70", de: "Lokale IP z.B. 192.168.178.70", fr: "IP locale ex. 192.168.178.70", es: "IP local ej. 192.168.178.70", pt: "IP local ex.: 192.168.178.70", it: "IP locale es. 192.168.178.70", zh: "本地 IP，例如 192.168.178.70"), text: $config.ip)
                            .keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true)
                    }
                }
                Section(header: Text(lz(en: "Printer Type", de: "Drucker Typ", fr: "Type d'imprimante", es: "Tipo de impresora", pt: "Tipo de Impressora", it: "Tipo di Stampante", zh: "打印机类型"))) {
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
                Section(header: Text(lz(en: "Appearance", de: "Erscheinungsbild", fr: "Apparence", es: "Apariencia", pt: "Aparência", it: "Aspetto", zh: "外观"))) {
                    HStack {
                        Image(systemName: "paintpalette.fill")
                            .foregroundColor(Color(hex: config.themeColor) ?? appThemes.first { $0.key == config.themeColor }?.color ?? .blue)
                            .frame(width: 28)
                        Text(lz(en: "Background Color", de: "Hintergrundfarbe", fr: "Couleur de fond", es: "Color de fondo", pt: "Cor de Fundo", it: "Colore di Sfondo", zh: "背景颜色"))
                        Spacer()
                        ColorPicker("", selection: Binding(
                            get: { Color(hex: config.themeColor) ?? appThemes.first { $0.key == config.themeColor }?.color ?? .blue },
                            set: { config.themeColor = $0.hexString }
                        ), supportsOpacity: false)
                        .labelsHidden()
                    }
                }
                Section(header: Text(lz(en: "Connection", de: "Verbindung", fr: "Connexion", es: "Conexión", pt: "Conexão", it: "Connessione", zh: "连接"))) {
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
                                Text(lz(en: "Reset", de: "Zurücksetzen", fr: "Réinitialiser", es: "Restablecer", pt: "Redefinir", it: "Ripristina", zh: "重置"))
                                    .bold()
                                Spacer()
                            }
                        }
                        Button {
                            showResetLayoutConfirm = false
                        } label: {
                            HStack {
                                Spacer()
                                Text(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"))
                                Spacer()
                            }
                        }
                    }
                }
                // MARK: Smart Plug Section
                Section(header: HStack {
                    Text(lz(en: "Smart Plug", de: "Smart-Steckdose", fr: "Prise intelligente", es: "Enchufe inteligente", pt: "Tomada Inteligente", it: "Presa Intelligente", zh: "智能插座"))
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
                    Picker(lz(en: "Type", de: "Typ", fr: "Type", es: "Tipo", pt: "Tipo", it: "Tipo", zh: "类型"),
                           selection: $config.smartPlugType) {
                        Text("Tuya / SmartLife").tag(PrinterConfig.SmartPlugType.tuya)
                        Text("Shelly").tag(PrinterConfig.SmartPlugType.shelly)
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Image(systemName: "network").foregroundColor(.orange)
                        TextField(lz(en: "Plug IP e.g. 192.168.178.170", de: "Steckdosen-IP z.B. 192.168.178.170", fr: "IP prise ex. 192.168.178.170", es: "IP enchufe ej. 192.168.178.170", pt: "IP da tomada ex.: 192.168.178.170", it: "IP presa es. 192.168.178.170", zh: "插座 IP，例如 192.168.178.170"),
                                  text: $config.smartPlugIP)
                            .keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true)
                    }

                    if config.smartPlugType == .tuya {
                        HStack {
                            Image(systemName: "cpu").foregroundColor(.orange)
                            TextField(lz(en: "Device ID (from tinytuya wizard)", de: "Geräte-ID (aus tinytuya wizard)", fr: "ID appareil (tinytuya wizard)", es: "ID dispositivo (tinytuya wizard)", pt: "ID do dispositivo (do assistente tinytuya)", it: "ID dispositivo (dalla procedura tinytuya)", zh: "设备 ID（来自 tinytuya 向导）"),
                                      text: $config.smartPlugDeviceID)
                                .autocapitalization(.none).disableAutocorrection(true)
                        }
                        HStack {
                            Image(systemName: "key.fill").foregroundColor(.orange)
                            SecureField(lz(en: "Local Key (16 chars, from tinytuya wizard)", de: "Local Key (16 Zeichen, aus tinytuya wizard)", fr: "Clé locale (16 car., tinytuya wizard)", es: "Clave local (16 chars, tinytuya wizard)", pt: "Local Key (16 caracteres, do assistente tinytuya)", it: "Local Key (16 caratteri, dalla procedura tinytuya)", zh: "Local Key（16 位字符，来自 tinytuya 向导）"),
                                        text: $config.smartPlugLocalKey)
                                .autocapitalization(.none).disableAutocorrection(true)
                        }
                    }
                }

                // MARK: Push Notifications Section
                Section(header: HStack {
                    Text(lz(en: "Push Notifications", de: "Push-Benachrichtigungen", fr: "Notifications push", es: "Notificaciones push", pt: "Notificações Push", it: "Notifiche Push", zh: "推送通知"))
                    Spacer()
                    Button { showPushInfo = true } label: {
                        Image(systemName: "questionmark.circle")
                            .foregroundColor(.secondary)
                            .font(.footnote)
                    }
                    .buttonStyle(.plain)
                }) {
                    // Server mode row
                    Button {
                        config.pushMode = .cloudflare
                        if config.cloudflareNotifySecret.isEmpty {
                            config.cloudflareNotifySecret = CloudflarePushService.generateSecret()
                        }
                        pushStatusMsg = nil
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "cloud.fill")
                                .foregroundColor(.gray)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(lz(en: "Server Push", de: "Server-Push", fr: "Push serveur", es: "Push servidor", pt: "Push do Servidor", it: "Push dal Server", zh: "服务器推送"))
                                        .foregroundColor(.primary)
                                        .font(.body)
                                }
                                Text(lz(en: "Works even when the app is closed", de: "Funktioniert auch wenn App geschlossen ist", fr: "Fonctionne même si l'app est fermée", es: "Funciona aunque la app esté cerrada", pt: "Funciona mesmo com o app fechado", it: "Funziona anche ad app chiusa", zh: "即使应用关闭也能运行"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if config.pushMode == .cloudflare {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .id("tourServerPush")
                    .tourTarget(.serverPush)

                    // Inline auto-setup card (only when server push is selected)
                    if config.pushMode == .cloudflare {
                        PushAutoSetupView(
                            printerID: config.name,
                            secret: config.cloudflareNotifySecret,
                            printerIP: config.ip,
                            printerType: config.type,
                            sshUsername: $sshUsername,
                            sshPassword: $sshPassword,
                            onSecretAdopted: { adopted in config.cloudflareNotifySecret = adopted }
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        .listRowBackground(Color.clear)
                    }

                    // Local mode row
                    Button {
                        if config.pushMode == .cloudflare && !config.cloudflareNotifySecret.isEmpty {
                            showLocalSwitchConfirm = true   // ask about removing the printer script
                        } else {
                            config.pushMode = .off
                            pushStatusMsg = nil
                        }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "iphone")
                                .foregroundColor(.blue)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lz(en: "Local (App Pull)", de: "Lokal (App Pull)", fr: "Local (App Pull)", es: "Local (App Pull)", pt: "Local (App Pull)", it: "Locale (App Pull)", zh: "本地（应用拉取）"))
                                    .foregroundColor(.primary)
                                    .font(.body)
                                Text(lz(en: "Works only when the app is active in foreground or background (100% Local)", de: "Funktioniert nur wenn App im Vordergrund oder Hintergrund aktiv ist (100% Lokal)", fr: "Fonctionne uniquement si l'app est active en premier plan ou arrière-plan (100% Local)", es: "Funciona solo cuando la app está activa en primer o segundo plano (100% Local)", pt: "Funciona apenas quando o app está ativo em primeiro ou segundo plano (100% Local)", it: "Funziona solo quando l'app è attiva in primo piano o in background (100% Locale)", zh: "仅当应用在前台或后台活跃时有效（100% 本地）"))
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

                    if let msg = pushStatusMsg {
                        HStack(spacing: 8) {
                            if pushIsWorking { ProgressView().scaleEffect(0.8) }
                            Text(msg)
                                .font(.caption)
                                .foregroundColor(pushStatusIsError ? .red : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                // 4-color Spoolman hook removal — U1 only, appears only when
                // the hook is actually installed (the subview self-hides).
                if config.type == .snapmakerU1, let svc = service {
                    MultiColorHookRemoveSection(service: svc)
                }

                Section {
                    Button(role: .destructive) {
                        showResetLayoutConfirm = true
                    } label: {
                        HStack {
                            Spacer()
                            Label(lz(en: "Reset Dashboard Layout", de: "Dashboard Layout zurücksetzen", fr: "Réinitialiser la mise en page", es: "Restablecer diseño", pt: "Redefinir Layout do Painel", it: "Ripristina Layout Dashboard", zh: "重置仪表盘布局"),
                                  systemImage: "arrow.counterclockwise")
                            Spacer()
                        }
                    }
                }

            }
            .onAppear { if config.type == .snapmakerU1 { service?.fetchMultiColorHook() } }
            .navigationTitle(config.name.isEmpty ? lz(en: "New Printer", de: "Neuer Drucker", fr: "Nouvelle imprimante", es: "Nueva impresora", pt: "Nova Impressora", it: "Nuova Stampante", zh: "新建打印机") : config.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消")) { onDismiss?(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: { performSave() }) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(config.name.isEmpty || config.ip.isEmpty ? .gray : .blue)
                    }
                    .disabled(config.name.isEmpty || config.ip.isEmpty)
                    .accessibilityLabel(lz(en: "Save", de: "Speichern", fr: "Enregistrer", es: "Guardar", pt: "Salvar", it: "Salva", zh: "保存"))
                }
            }
            .onChange(of: tour.step) { _, s in
                if s == .serverPush {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        withAnimation { tourProxy.scrollTo("tourServerPush", anchor: .center) }
                    }
                }
            }
            .onAppear {
                // The step is usually already .serverPush before this sheet
                // appears (set when the printer row was tapped), so onChange
                // won't fire — scroll here too.
                if tour.step == .serverPush {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        withAnimation { tourProxy.scrollTo("tourServerPush", anchor: .center) }
                    }
                }
            }
            }
            .collectTourFrames(tour)
            .overlay { tourServerPushOverlay }
        }
        .sheet(isPresented: $showOctoGuide) {
            OctoEverywhereGuideView(printerType: config.type)
        }
        .sheet(isPresented: $showLocalGuide) {
            LocalConnectionGuideView()
        }
        .sheet(isPresented: $showPushInfo) {
            PushInfoView()
        }

        .sheet(isPresented: $showSmartPlugGuide) {
            SmartPlugGuideView()
        }
        .confirmationDialog(lz(en: "Push is still installed on the printer. Remove it now?", de: "Auf dem Drucker läuft noch das Push-Script. Jetzt entfernen?", fr: "Le push est encore installé sur l'imprimante. Le retirer maintenant ?", es: "El push sigue instalado en la impresora. ¿Quitarlo ahora?", pt: "O push ainda está instalado na impressora. Remover agora?", it: "Il push è ancora installato sulla stampante. Rimuoverlo ora?", zh: "打印机上仍装有推送脚本。现在移除吗？"),
                           isPresented: $showLocalSwitchConfirm, titleVisibility: .visible) {
            Button(lz(en: "Remove from printer", de: "Vom Drucker entfernen", fr: "Retirer de l'imprimante", es: "Quitar de la impresora", pt: "Remover da impressora", it: "Rimuovi dalla stampante", zh: "从打印机移除"), role: .destructive) {
                switchToLocal(removeViaSSH: true)
            }
            Button(lz(en: "Just switch to Local", de: "Nur auf Lokal umschalten", fr: "Passer en Local seulement", es: "Solo cambiar a Local", pt: "Só mudar para Local", it: "Passa solo a Locale", zh: "仅切换到本地"), role: nil) {
                switchToLocal(removeViaSSH: false)
            }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {}
        } message: {
            Text(lz(en: "If you keep it, the script stops itself automatically once no device wants push anymore.", de: "Wenn du es behältst, stoppt sich das Script automatisch, sobald kein Gerät mehr Push möchte.", fr: "Si vous le gardez, le script s'arrête automatiquement dès qu'aucun appareil ne veut de push.", es: "Si lo mantienes, el script se detiene automáticamente cuando ningún dispositivo quiere push.", pt: "Se mantiver, o script para sozinho quando nenhum dispositivo quiser push.", it: "Se lo mantieni, lo script si ferma da solo quando nessun dispositivo vuole più il push.", zh: "如果保留，一旦没有设备需要推送，脚本会自动停止。"))
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
                                .foregroundColor(.gray)
                                .frame(width: 36)
                            Text(lz(en: "Server Push", de: "Server-Push", fr: "Push serveur", es: "Push servidor", pt: "Push do Servidor", it: "Push dal Server", zh: "服务器推送"))
                                .font(.title3.bold())
                        }
                        Text(lz(en: "A small Python script runs continuously on the printer and notifies a Cloudflare server whenever the status changes or progress moves by 1% or more. From there, your iPhone is updated directly via push notification.", de: "Ein kleines Python-Script läuft dauerhaft auf dem Drucker und benachrichtigt einen Cloudflare-Server bei jeder Statusänderung oder wenn sich der Fortschritt um mindestens 1 % ändert. Von dort wird dein iPhone direkt per Push-Benachrichtigung aktualisiert.", fr: "Un petit script Python tourne en permanence sur l'imprimante et informe un serveur Cloudflare à chaque changement d'état ou dès que la progression change d'au moins 1 %. De là, votre iPhone est mis à jour directement par notification push.", es: "Un pequeño script Python corre continuamente en la impresora y notifica a un servidor Cloudflare cada vez que cambia el estado o el progreso varía al menos un 1 %. Desde allí, tu iPhone se actualiza directamente por notificación push.", pt: "Um pequeno script Python roda continuamente na impressora e notifica um servidor Cloudflare sempre que o status muda ou o progresso varia pelo menos 1%. A partir daí, seu iPhone é atualizado diretamente via notificação push.", it: "Un piccolo script Python viene eseguito continuamente sulla stampante e notifica un server Cloudflare ogni volta che lo stato cambia o l'avanzamento varia di almeno l'1%. Da lì, il tuo iPhone viene aggiornato direttamente tramite notifica push.", zh: "一个小型 Python 脚本会持续在打印机上运行，每当状态发生变化或进度变化达到 1% 以上时就会通知 Cloudflare 服务器。之后，您的 iPhone 会通过推送通知直接更新。"))
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            InfoRow(icon: "checkmark.circle.fill", color: .green,
                                    text: lz(en: "Works even when the app is completely closed", de: "Funktioniert auch wenn die App komplett geschlossen ist", fr: "Fonctionne même si l'app est complètement fermée", es: "Funciona aunque la app esté completamente cerrada", pt: "Funciona mesmo com o app totalmente fechado", it: "Funziona anche ad app completamente chiusa", zh: "即使应用完全关闭也能运行"))
                            InfoRow(icon: "checkmark.circle.fill", color: .green,
                                    text: lz(en: "Works from anywhere — regardless of your network", de: "Funktioniert von überall — egal ob du zuhause bist oder nicht", fr: "Fonctionne de partout — peu importe votre réseau", es: "Funciona desde cualquier lugar — sin importar tu red", pt: "Funciona de qualquer lugar — independente da sua rede", it: "Funziona ovunque — indipendentemente dalla tua rete", zh: "无论您在哪个网络，随时随地可用"))
                            InfoRow(icon: "checkmark.circle.fill", color: .green,
                                    text: lz(en: "Progress, pause, error and completion in real time", de: "Fortschritt, Pause, Fehler und Abschluss in Echtzeit", fr: "Progression, pause, erreur et fin en temps réel", es: "Progreso, pausa, error y finalización en tiempo real", pt: "Progresso, pausa, erro e conclusão em tempo real", it: "Avanzamento, pausa, errore e completamento in tempo reale", zh: "实时显示进度、暂停、错误和完成状态"))
                            InfoRow(icon: "info.circle.fill", color: .orange,
                                    text: lz(en: "One-time setup on the printer required", de: "Einmalige Einrichtung auf dem Drucker nötig", fr: "Configuration unique sur l'imprimante requise", es: "Configuración única en la impresora necesaria", pt: "Configuração única na impressora é necessária", it: "È richiesta una configurazione una tantum sulla stampante", zh: "需要在打印机上进行一次性设置"))
                        }

                        Text(lz(en: "Flow", de: "Ablauf", fr: "Flux", es: "Flujo", pt: "Fluxo", it: "Flusso", zh: "流量"))
                            .font(.headline)
                            .padding(.top, 4)
                        HStack(spacing: 0) {
                            VStack(spacing: 0) {
                                FlowStep(icon: "printer.fill",    color: .gray,   label: lz(en: "Printer", de: "Drucker", fr: "Imprimante", es: "Impresora", pt: "Impressora", it: "Stampante", zh: "打印机"))
                                connector
                                FlowStep(icon: "cloud.fill",      color: .gray, label: "Cloudflare")
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
                            Text(lz(en: "Local", de: "Lokal", fr: "Local", es: "Local", pt: "Local", it: "Locale", zh: "本地"))
                                .font(.title3.bold())
                        }
                        Text(lz(en: "The app queries Moonraker directly and updates the Live Activity itself. No script, no server.", de: "Die App fragt Moonraker direkt ab und aktualisiert die Live Activity selbst. Kein Script, kein Server.", fr: "L'app interroge Moonraker directement et met à jour la Live Activity elle-même. Pas de script, pas de serveur.", es: "La app consulta Moonraker directamente y actualiza la Live Activity por sí misma. Sin script, sin servidor.", pt: "O app consulta o Moonraker diretamente e atualiza a Live Activity sozinho. Sem script, sem servidor.", it: "L'app interroga direttamente Moonraker e aggiorna essa stessa la Live Activity. Nessuno script, nessun server.", zh: "应用直接查询 Moonraker 并自行更新灵动岛实时活动。无需脚本，无需服务器。"))
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            InfoRow(icon: "checkmark.circle.fill", color: .green,
                                    text: lz(en: "No setup needed — works immediately", de: "Kein Setup nötig — funktioniert sofort", fr: "Aucune configuration — fonctionne immédiatement", es: "Sin configuración — funciona de inmediato", pt: "Sem necessidade de configuração — funciona imediatamente", it: "Nessuna configurazione necessaria — funziona immediatamente", zh: "无需设置——立即可用"))
                            InfoRow(icon: "checkmark.circle.fill", color: .green,
                                    text: lz(en: "No script on the printer", de: "Kein Script auf dem Drucker", fr: "Pas de script sur l'imprimante", es: "Sin script en la impresora", pt: "Sem script na impressora", it: "Nessuno script sulla stampante", zh: "打印机上无需脚本"))
                            InfoRow(icon: "info.circle.fill", color: .orange,
                                    text: lz(en: "Requires network access to the printer (home network or OctoEverywhere)", de: "Benötigt Netzwerkzugang zum Drucker (Heimnetz oder OctoEverywhere)", fr: "Nécessite un accès réseau à l'imprimante (réseau local ou OctoEverywhere)", es: "Requiere acceso de red a la impresora (red local u OctoEverywhere)", pt: "Requer acesso à rede da impressora (rede doméstica ou OctoEverywhere)", it: "Richiede accesso di rete alla stampante (rete domestica o OctoEverywhere)", zh: "需要网络访问打印机（家庭网络或 OctoEverywhere）"))
                            InfoRow(icon: "info.circle.fill", color: .orange,
                                    text: lz(en: "Updates only while the app is in the foreground or background", de: "Updates nur solange die App im Vordergrund oder Hintergrund läuft", fr: "Mises à jour uniquement si l'app est au premier plan ou en arrière-plan", es: "Actualizaciones solo mientras la app esté en primer plano o en segundo plano", pt: "Atualiza apenas enquanto o app está em primeiro ou segundo plano", it: "Si aggiorna solo mentre l'app è in primo piano o in background", zh: "仅在应用处于前台或后台时更新"))
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(14)
                }
                .padding()
            }
            .navigationTitle(lz(en: "Push Modes Explained", de: "Push-Modi erklärt", fr: "Modes push expliqués", es: "Modos push explicados", pt: "Modos de Push Explicados", it: "Modalità Push Spiegate", zh: "推送模式说明"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(lz(en: "Done", de: "Fertig", fr: "OK", es: "Listo", pt: "Concluído", it: "Fatto", zh: "完成")) { dismiss() }
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

// MARK: - Push Auto-Setup (inline card)
struct PushAutoSetupView: View {
    let printerID: String
    let secret: String
    let printerIP: String
    let printerType: PrinterConfig.PrinterType
    // Hoisted into PrinterEditView so the Local-switch removal (switchToLocal)
    // reuses the EXACT same values as this card's own "Remove from printer"
    // button — two independently-recomputed credential lookups had drifted
    // out of sync (wrong username / stale password) even after both should
    // have pointed at the same Keychain entry.
    @Binding var sshUsername: String
    @Binding var sshPassword: String
    var onSecretAdopted: (String) -> Void = { _ in }

    private var printerHost: String {
        printerIP
            .replacingOccurrences(of: "http://",  with: "")
            .replacingOccurrences(of: "https://", with: "")
            .components(separatedBy: ":").first?
            .trimmingCharacters(in: .whitespaces) ?? printerIP
    }

    // Fallback login user when auto-detection / manual entry is empty.
    private var defaultUser: String {
        switch printerType {
        case .snapmakerU1:  return "root"
        case .singleNozzle: return "pi"
        }
    }
    // Standard Klipper hosts need sudo to install a systemd service; the U1 is
    // already root.
    private var useSudo: Bool { printerType == .singleNozzle }

    @State private var sshRunning = false
    @State private var sshSuccess: Bool? = nil
    @State private var sshResultText: String? = nil
    @State private var sshErrorDetail: String? = nil
    // Note: the install/remove confirmations live in their own child views
    // (PushInstallButton / PushRemoveButton) — dialogs sharing one view or
    // one state in this Form hierarchy got mixed up by SwiftUI.

    private func runSSH(uninstall: Bool) {
        guard !sshPassword.isEmpty else {
            sshSuccess = false
            sshResultText = lz(en: "Please enter the SSH password first.", de: "Bitte zuerst das SSH-Passwort eingeben.", fr: "Veuillez d'abord saisir le mot de passe SSH.", es: "Introduce primero la contraseña SSH.", pt: "Insira primeiro a senha SSH.", it: "Inserisci prima la password SSH.", zh: "请先输入 SSH 密码。")
            sshErrorDetail = nil
            return
        }
        haptic()
        sshRunning = true; sshSuccess = nil; sshResultText = nil; sshErrorDetail = nil
        let host = printerHost
        let user = sshUsername.trimmingCharacters(in: .whitespaces).isEmpty ? defaultUser : sshUsername.trimmingCharacters(in: .whitespaces)
        let pw = sshPassword
        let sudo = useSudo
        let pid = printerID, sec = secret
        let type = printerType
        Task {
            do {
                if uninstall {
                    _ = try await SSHInstaller.uninstall(host: host, user: user, password: pw,
                                                         workerURL: CloudflarePushService.workerURL, secret: sec,
                                                         useSudo: sudo)
                } else {
                    // The U1's firmware wipes everything except /oem and printer_data
                    // on every boot — OctoEverywhere is the only available autostart
                    // hook. Without it the bridge would silently stop working after
                    // the next printer restart, so block setup until it's there.
                    if type == .snapmakerU1 {
                        // Distinguish "printer unreachable" from "OctoEverywhere
                        // missing": a connection failure must NOT show the
                        // misleading OE hint (that's what `try? ... ?? false` did).
                        let hasOcto: Bool
                        do {
                            hasOcto = try await SSHInstaller.checkOctoEverywhereInstalled(host: host, user: user, password: pw)
                        } catch {
                            await MainActor.run {
                                sshRunning = false
                                sshSuccess = false
                                if case SSHInstallError.connection = error {
                                    sshResultText = lz(en: "Printer not reachable", de: "Drucker nicht erreichbar", fr: "Imprimante injoignable", es: "Impresora no accesible", pt: "Impressora inacessível", it: "Stampante non raggiungibile", zh: "无法连接打印机")
                                    sshErrorDetail = lz(en: "Check that the printer is powered on and connected to the same network, then try again.", de: "Prüfe, ob der Drucker eingeschaltet und im selben Netzwerk ist, dann erneut versuchen.", fr: "Vérifiez que l'imprimante est allumée et connectée au même réseau, puis réessayez.", es: "Comprueba que la impresora esté encendida y en la misma red, luego inténtalo de nuevo.", pt: "Verifique se a impressora está ligada e na mesma rede, depois tente novamente.", it: "Verifica che la stampante sia accesa e connessa alla stessa rete, poi riprova.", zh: "请确认打印机已开机并连接到同一网络，然后重试。")
                                } else {
                                    sshResultText = lz(en: "Setup failed", de: "Einrichtung fehlgeschlagen", fr: "Échec de la configuration", es: "Error de configuración", pt: "Falha na configuração", it: "Configurazione non riuscita", zh: "设置失败")
                                    sshErrorDetail = error.localizedDescription
                                }
                            }
                            return
                        }
                        guard hasOcto else {
                            await MainActor.run {
                                sshRunning = false
                                sshSuccess = false
                                sshResultText = lz(en: "OctoEverywhere required", de: "OctoEverywhere erforderlich", fr: "OctoEverywhere requis", es: "OctoEverywhere requerido", pt: "OctoEverywhere necessário", it: "OctoEverywhere richiesto", zh: "需要 OctoEverywhere")
                                sshErrorDetail = lz(en: "The printer's firmware resets almost everything on every restart — OctoEverywhere is the only thing that keeps running afterwards, and Server Push needs it to restart itself with it. Enable it first: in this printer's Konfiguration tab under Cloud Access → OctoEverywhere, then try Setup again.", de: "Die Firmware des Druckers setzt bei jedem Neustart fast alles zurück — nur OctoEverywhere läuft danach noch, und Server-Push braucht es, um sich mit ihm neu zu starten. Aktiviere es zuerst: im Konfiguration-Reiter dieses Druckers unter Cloud Access → OctoEverywhere, dann Einrichtung erneut versuchen.", fr: "Le firmware de l'imprimante réinitialise presque tout à chaque redémarrage — seul OctoEverywhere continue de fonctionner après, et Server Push en a besoin pour redémarrer avec lui. Activez-le d'abord : dans l'onglet Konfiguration de cette imprimante sous Cloud Access → OctoEverywhere, puis réessayez la configuration.", es: "El firmware de la impresora reinicia casi todo en cada reinicio — solo OctoEverywhere sigue funcionando después, y Server Push lo necesita para reiniciarse con él. Actívalo primero: en la pestaña Konfiguration de esta impresora, en Cloud Access → OctoEverywhere, luego intenta la configuración de nuevo.", pt: "O firmware da impressora reinicia quase tudo a cada reinício — apenas o OctoEverywhere continua rodando depois, e o Server Push precisa dele para reiniciar junto. Ative-o primeiro: na aba Konfiguration desta impressora, em Cloud Access → OctoEverywhere, depois tente a configuração novamente.", it: "Il firmware della stampante reimposta quasi tutto a ogni riavvio — solo OctoEverywhere continua a funzionare dopo, e Server Push ne ha bisogno per riavviarsi con esso. Attivalo prima: nella scheda Konfiguration di questa stampante, in Cloud Access → OctoEverywhere, poi riprova la configurazione.", zh: "打印机固件几乎每次重启都会重置所有内容——只有 OctoEverywhere 之后仍会运行，服务器推送需要依靠它一起重启。请先启用：在此打印机的“Konfiguration”标签页中，进入 Cloud Access → OctoEverywhere，然后重新尝试设置。")
                            }
                            return
                        }
                    }
                    // Weg 1 (Multi-Device): Falls der Drucker schon eingerichtet ist,
                    // dessen Schluessel uebernehmen — dann bekommen iPhone UND iPad
                    // die Push, statt dass sich beide gegenseitig "ueberschreiben".
                    var effectiveSecret = sec
                    if let existing = try? await SSHInstaller.readExistingSecret(host: host, user: user, password: pw),
                       !existing.isEmpty, existing != sec {
                        effectiveSecret = existing
                        await MainActor.run { onSecretAdopted(existing) }
                    }
                    // Token VOR der Installation registrieren: die Bridge prueft
                    // direkt nach dem Start, ob ueberhaupt ein Geraet Push will,
                    // und wuerde sich sonst sofort wieder selbst deinstallieren
                    // (die Registrierung beim "Speichern" kaeme zu spaet).
                    if let token = CloudflarePushService.shared.storedDeviceToken {
                        try? await CloudflarePushService.shared.registerDeviceToken(
                            workerURL: CloudflarePushService.workerURL, printerID: pid,
                            deviceToken: token, secret: effectiveSecret)
                    }
                    _ = try await SSHInstaller.install(host: host, user: user, password: pw,
                                                       workerURL: CloudflarePushService.workerURL,
                                                       printerID: pid, secret: effectiveSecret,
                                                       useSudo: sudo)
                }
                await MainActor.run {
                    sshSuccess = true
                    sshResultText = uninstall
                        ? lz(en: "Successfully removed", de: "Löschen erfolgreich", fr: "Suppression réussie", es: "Eliminado correctamente", pt: "Removido com sucesso", it: "Rimozione riuscita", zh: "移除成功")
                        : lz(en: "Setup successful", de: "Einrichtung erfolgreich", fr: "Configuration réussie", es: "Configuración correcta", pt: "Configuração concluída", it: "Configurazione riuscita", zh: "设置成功")
                    sshRunning = false
                    // Save the working password so later actions (e.g. removing
                    // the bridge via SSH when switching to Local push) don't
                    // fail with an empty/wrong password.
                    if uninstall {
                        SSHCredentialStore.delete(for: pid)
                        SSHUsernameStore.delete(for: pid)
                    } else {
                        SSHCredentialStore.save(pw, for: pid)
                        SSHUsernameStore.save(user, for: pid)
                    }
                }
            } catch {
                await MainActor.run {
                    sshSuccess = false
                    sshResultText = uninstall
                        ? lz(en: "Removal failed", de: "Löschen fehlgeschlagen", fr: "Échec de la suppression", es: "Error al eliminar", pt: "Falha ao remover", it: "Rimozione non riuscita", zh: "移除失败")
                        : lz(en: "Setup failed", de: "Einrichtung fehlgeschlagen", fr: "Échec de la configuration", es: "Error de configuración", pt: "Falha na configuração", it: "Configurazione non riuscita", zh: "设置失败")
                    sshErrorDetail = error.localizedDescription
                    sshRunning = false
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(lz(en: "Setup", de: "Einrichtung", fr: "Configuration", es: "Configuración", pt: "Configuração", it: "Configurazione", zh: "设置"))
                .font(.subheadline.bold()).foregroundColor(.gray)
            Text(lz(en: "The app connects to the printer via SSH and installs everything.", de: "Die App verbindet sich per SSH mit dem Drucker und installiert alles.", fr: "L'app se connecte à l'imprimante en SSH et installe tout.", es: "La app se conecta a la impresora por SSH e instala todo.", pt: "O app conecta-se à impressora via SSH e instala tudo.", it: "L'app si connette alla stampante via SSH e installa tutto.", zh: "应用通过 SSH 连接打印机并自动安装。"))
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Standard Klipper printers have varying usernames — show a field
            // (auto-filled from Moonraker). The U1 is always root, so no field.
            if printerType == .singleNozzle {
                HStack(spacing: 8) {
                    Image(systemName: "person.fill").foregroundColor(.secondary).frame(width: 20)
                    TextField(lz(en: "SSH username", de: "SSH-Benutzername", fr: "Nom d'utilisateur SSH", es: "Usuario SSH", pt: "Usuário SSH", it: "Nome utente SSH", zh: "SSH 用户名"), text: $sshUsername)
                        .textInputAutocapitalization(.never).disableAutocorrection(true)
                }
                .padding(10)
                .background(Color(.systemBackground))
                .cornerRadius(9)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))
            }

            HStack(spacing: 8) {
                Image(systemName: "key.fill").foregroundColor(.secondary).frame(width: 20)
                SecureField(lz(en: "SSH password", de: "SSH-Passwort", fr: "Mot de passe SSH", es: "Contraseña SSH", pt: "Senha SSH", it: "Password SSH", zh: "SSH 密码"), text: $sshPassword)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
            }
            .padding(10)
            .background(Color(.systemBackground))
            .cornerRadius(9)
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))

            PushInstallButton(running: sshRunning) { runSSH(uninstall: false) }

            if let ok = sshSuccess, let msg = sshResultText {
                VStack(alignment: .leading, spacing: 4) {
                    Label(msg, systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.subheadline.bold())
                        .foregroundColor(ok ? .green : .red)
                    if !ok, let detail = sshErrorDetail {
                        Text(detail).font(.caption2).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider().padding(.vertical, 2)

            PushRemoveButton(running: sshRunning) { runSSH(uninstall: true) }
        }
        .padding(14)
        .background(Color.gray.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.gray.opacity(0.22), lineWidth: 1))
        .cornerRadius(14)
        .onAppear {
            if sshPassword.isEmpty, let saved = SSHCredentialStore.load(for: printerID) {
                sshPassword = saved
            } else if sshPassword.isEmpty && printerType == .snapmakerU1 {
                sshPassword = "snapmaker"
            }
            // Auto-fill the SSH username for standard Klipper printers from Moonraker.
            if printerType == .singleNozzle && sshUsername.isEmpty {
                let host = printerHost
                Task {
                    if let u = await SSHInstaller.detectUsername(host: host) {
                        await MainActor.run { if sshUsername.isEmpty { sshUsername = u } }
                    }
                }
            }
        }
        // Single-nozzle printers have individual passwords — never prefill.
        // (Without this, switching the type from U1 to single-nozzle while the
        // sheet is open would leave the "snapmaker" prefill in place.)
        .onChange(of: printerType) { _, newType in
            if newType == .snapmakerU1 {
                if sshPassword.isEmpty { sshPassword = "snapmaker" }
            } else if sshPassword == "snapmaker" {
                sshPassword = ""
            }
        }
    }
}

// Self-contained install button: owns its own confirmation state + dialog so
// nothing can get crossed with other dialogs in the surrounding Form.
private struct PushInstallButton: View {
    let running: Bool
    let action: () -> Void
    @State private var confirm = false

    var body: some View {
        Button { confirm = true } label: {
            HStack(spacing: 6) {
                if running { ProgressView().tint(.white) }
                Text(running ? lz(en: "Working…", de: "Wird ausgeführt…", fr: "En cours…", es: "En curso…", pt: "Em andamento…", it: "In corso…", zh: "处理中…")
                             : lz(en: "Set up now", de: "Jetzt einrichten", fr: "Configurer", es: "Configurar", pt: "Configurar", it: "Configura", zh: "立即设置"))
            }
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(Color.gray).foregroundColor(.white).cornerRadius(12)
        }
        // Inside a Form/List row a tap would otherwise trigger EVERY button in
        // the row — borderless makes each button handle only its own taps.
        .buttonStyle(.borderless)
        .disabled(running)
        .confirmationDialog(lz(en: "Set up push on the printer?", de: "Push auf dem Drucker einrichten?", fr: "Configurer le push sur l'imprimante ?", es: "¿Configurar push en la impresora?", pt: "Configurar push na impressora?", it: "Configurare il push sulla stampante?", zh: "在打印机上设置推送？"),
                            isPresented: $confirm, titleVisibility: .visible) {
            Button(lz(en: "Set up now", de: "Jetzt einrichten", fr: "Configurer", es: "Configurar", pt: "Configurar", it: "Configura", zh: "立即设置")) { action() }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {}
        }
    }
}

// Self-contained remove button, same isolation as PushInstallButton.
private struct PushRemoveButton: View {
    let running: Bool
    let action: () -> Void
    @State private var confirm = false

    var body: some View {
        Button(role: .destructive) { confirm = true } label: {
            Label(lz(en: "Remove from printer", de: "Vom Drucker entfernen", fr: "Retirer de l'imprimante", es: "Quitar de la impresora", pt: "Remover da impressora", it: "Rimuovi dalla stampante", zh: "从打印机移除"), systemImage: "trash")
                .font(.caption)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderless)   // see PushInstallButton
        .disabled(running)
        .confirmationDialog(lz(en: "Really remove push from the printer?", de: "Push wirklich vom Drucker entfernen?", fr: "Vraiment retirer le push de l'imprimante ?", es: "¿Quitar realmente el push de la impresora?", pt: "Remover mesmo o push da impressora?", it: "Rimuovere davvero il push dalla stampante?", zh: "确定从打印机移除推送？"),
                            isPresented: $confirm, titleVisibility: .visible) {
            Button(lz(en: "Remove", de: "Entfernen", fr: "Supprimer", es: "Eliminar", pt: "Remover", it: "Rimuovi", zh: "移除"), role: .destructive) { action() }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {}
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
        systemctl disable --now paxxmaker-bridge 2>/dev/null || true
        rm -f /etc/systemd/system/paxxmaker-bridge.service 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        rm -f /etc/init.d/S99paxxmaker 2>/dev/null || true
        rm -f /oem/apps/octoeverywhere/venv/lib/python3*/site-packages/sitecustomize.py 2>/dev/null || true
        crontab -l 2>/dev/null | grep -v paxxmaker_bridge | crontab - 2>/dev/null || true
        sed -i '/paxxmaker_bridge/d' /etc/rc.local 2>/dev/null || true
        rm -f \(scriptPath) 2>/dev/null || true
        rm -f /home/lava/printer_data/config/extended/moonraker/paxxmaker.cfg 2>/dev/null || true
        rm -f /home/lava/printer_data/paxxmaker_start.sh 2>/dev/null || true
        rm -f /home/lava/printer_data/config/paxxmaker.cfg 2>/dev/null || true
        sed -i '/paxxmaker\\.cfg/d' /home/lava/printer_data/config/printer.cfg 2>/dev/null || true
        rm -f /home/lava/klipper/klippy/extras/paxxmaker_autostart.py 2>/dev/null || true
        rm -f /oem/.debug 2>/dev/null || true
        rm -f /tmp/paxxmaker.log /tmp/paxxmaker_bridge.log /tmp/paxxmaker_bridge.lock 2>/dev/null || true
        reboot
        """
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(lz(en: "Step 1 — Connect via SSH", de: "Schritt 1 — SSH verbinden", fr: "Étape 1 — Connexion SSH", es: "Paso 1 — Conectar por SSH", pt: "Passo 1 — Conectar via SSH", it: "Passo 1 — Connettersi via SSH", zh: "第 1 步 — 通过 SSH 连接"),
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
                        Label(lz(en: "Step 2 — Run these commands", de: "Schritt 2 — Diese Befehle ausführen", fr: "Étape 2 — Exécuter ces commandes", es: "Paso 2 — Ejecutar estos comandos", pt: "Passo 2 — Execute estes comandos", it: "Passo 2 — Esegui questi comandi", zh: "第 2 步 — 执行以下命令"),
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
            .navigationTitle(lz(en: "Uninstall Push Script", de: "Push-Script deinstallieren", fr: "Désinstaller le script push", es: "Desinstalar script push", pt: "Desinstalar Script de Push", it: "Disinstalla Script Push", zh: "卸载推送脚本"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(lz(en: "Done", de: "Fertig", fr: "OK", es: "Listo", pt: "Concluído", it: "Fatto", zh: "完成")) { dismiss() }
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
                            Text(lz(en: "Tuya / SmartLife Smart Plug", de: "Tuya / SmartLife Smart-Steckdose", fr: "Prise Tuya / SmartLife", es: "Enchufe Tuya / SmartLife", pt: "Tomada Inteligente Tuya / SmartLife", it: "Presa Intelligente Tuya / SmartLife", zh: "Tuya / SmartLife 智能插座"))
                                .font(.title3.bold())
                        }
                        Text(lz(en: "These plugs don't use plain HTTP — they speak Tuya's encrypted LAN protocol v3.5. The app connects directly over your local network. You need three values: IP address, Device ID, and Local Key.", de: "Diese Steckdosen verwenden kein einfaches HTTP, sondern das verschlüsselte Tuya-LAN-Protokoll v3.5. Die App verbindet sich direkt über dein Heimnetz. Du brauchst drei Werte: IP-Adresse, Geräte-ID und Local Key.", fr: "Ces prises n'utilisent pas HTTP simple — elles parlent le protocole LAN Tuya v3.5 chiffré. L'app se connecte directement sur votre réseau local. Vous avez besoin de trois valeurs : IP, ID appareil et clé locale.", es: "Estos enchufes no usan HTTP simple — usan el protocolo LAN Tuya v3.5 cifrado. La app se conecta directamente por tu red local. Necesitas tres valores: IP, ID de dispositivo y clave local.", pt: "Essas tomadas não usam HTTP simples — elas falam o protocolo LAN criptografado v3.5 da Tuya. O app se conecta diretamente pela sua rede local. Você precisa de três valores: endereço IP, Device ID e Local Key.", it: "Queste prese non usano HTTP semplice — parlano il protocollo LAN crittografato v3.5 di Tuya. L'app si connette direttamente tramite la tua rete locale. Servono tre valori: indirizzo IP, Device ID e Local Key.", zh: "这些插座不使用普通 HTTP，而是使用 Tuya 加密的局域网协议 v3.5。应用会通过您的本地网络直接连接。您需要三个值：IP 地址、设备 ID 和 Local Key。"))
                        .font(.subheadline).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .background(Color(.systemGray6)).cornerRadius(14)

                    // Step 1
                    stepCard(number: 1, icon: "desktopcomputer", color: .blue,
                             title: lz(en: "Install tinytuya on your Mac", de: "tinytuya auf dem Mac installieren", fr: "Installer tinytuya sur votre Mac", es: "Instalar tinytuya en tu Mac", pt: "Instalar tinytuya no seu Mac", it: "Installa tinytuya sul tuo Mac", zh: "在 Mac 上安装 tinytuya"),
                             body: lz(en: "Open Terminal and run:", de: "Terminal öffnen und ausführen:", fr: "Ouvrez Terminal et exécutez :", es: "Abre Terminal y ejecuta:", pt: "Abra o Terminal e execute:", it: "Apri il Terminale ed esegui:", zh: "打开终端并执行："),
                             command: "pip3 install tinytuya")

                    // Step 2
                    stepCard(number: 2, icon: "globe", color: .indigo,
                             title: lz(en: "Set up Tuya developer account", de: "Tuya-Entwicklerkonto einrichten", fr: "Configurer le compte développeur Tuya", es: "Configurar cuenta desarrolladora Tuya", pt: "Configurar conta de desenvolvedor Tuya", it: "Configura account sviluppatore Tuya", zh: "设置 Tuya 开发者账户"),
                             body: lz(en: "Go to iot.tuya.com, sign up and create a Cloud Project. Subscribe to the IoT Core API. Under Devices > Link Tuya App Account, link your SmartLife account. Then note down your API Key (Access ID) and API Secret from the project overview — you will need both for the wizard.", de: "Gehe zu iot.tuya.com, registriere dich und erstelle ein Cloud-Projekt. Abonniere die IoT Core API. Unter Geraete > Tuya-App-Konto verknuepfen dein SmartLife-Konto verknuepfen. Notiere dann den API Key (Access ID) und API Secret aus der Projektübersicht — beides brauchst du fuer den Wizard.", fr: "Allez sur iot.tuya.com, inscrivez-vous et créez un projet Cloud. Abonnez-vous à l'API IoT Core. Dans Appareils > Lier un compte Tuya, liez votre compte SmartLife. Notez ensuite l'API Key (Access ID) et l'API Secret depuis la vue d'ensemble du projet — vous en aurez besoin pour l'assistant.", es: "Ve a iot.tuya.com, regístrate y crea un proyecto Cloud. Suscríbete a la API IoT Core. En Dispositivos > Vincular cuenta Tuya, vincula tu cuenta SmartLife. Anota el API Key (Access ID) y el API Secret desde la vista del proyecto — los necesitarás para el asistente.", pt: "Acesse iot.tuya.com, cadastre-se e crie um Cloud Project. Assine a IoT Core API. Em Devices > Link Tuya App Account, vincule sua conta SmartLife. Depois anote sua API Key (Access ID) e API Secret na visão geral do projeto — você precisará de ambos para o assistente.", it: "Vai su iot.tuya.com, registrati e crea un Cloud Project. Sottoscrivi la IoT Core API. In Devices > Link Tuya App Account, collega il tuo account SmartLife. Poi annota API Key (Access ID) e API Secret dalla panoramica del progetto — ti serviranno entrambi per la procedura guidata.", zh: "前往 iot.tuya.com 注册并创建一个 Cloud Project，订阅 IoT Core API。在 Devices > Link Tuya App Account 中关联您的 SmartLife 账户。然后在项目概览中记下 API Key（Access ID）和 API Secret——向导需要用到这两项。"),
                             command: nil)

                    // Step 3
                    stepCard(number: 3, icon: "wand.and.stars", color: .purple,
                             title: lz(en: "Run the tinytuya wizard", de: "tinytuya-Wizard starten", fr: "Lancer l'assistant tinytuya", es: "Ejecutar el asistente tinytuya", pt: "Executar o assistente tinytuya", it: "Esegui la procedura guidata tinytuya", zh: "运行 tinytuya 向导"),
                             body: lz(en: "Run the wizard in Terminal. It will ask for: API Key, API Secret, any Device ID (or type \"scan\"), and your region (eu, us, cn, …). It then downloads all device data and saves it to devices.json.", de: "Den Wizard im Terminal starten. Er fragt nach: API Key, API Secret, einer beliebigen Geraete-ID (oder \"scan\" eingeben) und deiner Region (eu, us, cn, …). Anschliessend laedt er alle Gerätedaten herunter und speichert sie in devices.json.", fr: "Lancez l'assistant dans Terminal. Il demandera : API Key, API Secret, un ID appareil quelconque (ou tapez \"scan\") et votre région (eu, us, cn, …). Il télécharge ensuite toutes les données et les enregistre dans devices.json.", es: "Ejecuta el asistente en Terminal. Pedirá: API Key, API Secret, cualquier ID de dispositivo (o escribe \"scan\") y tu región (eu, us, cn, …). Luego descarga todos los datos y los guarda en devices.json.", pt: "Execute o assistente no Terminal. Ele pedirá: API Key, API Secret, qualquer Device ID (ou digite \"scan\") e sua região (eu, us, cn, …). Em seguida, ele baixa todos os dados do dispositivo e os salva em devices.json.", it: "Esegui la procedura guidata nel Terminale. Chiederà: API Key, API Secret, un Device ID qualsiasi (o digita \"scan\") e la tua regione (eu, us, cn, …). Poi scarica tutti i dati del dispositivo e li salva in devices.json.", zh: "在终端中运行向导。它会要求输入：API Key、API Secret、任意设备 ID（或输入 \"scan\"）以及您的地区（eu、us、cn 等）。随后它会下载所有设备数据并保存到 devices.json。"),
                             command: "python3 -m tinytuya wizard")

                    // Step 4
                    stepCard(number: 4, icon: "doc.text.magnifyingglass", color: .green,
                             title: lz(en: "Find your device in devices.json", de: "Gerät in devices.json suchen", fr: "Trouver votre appareil dans devices.json", es: "Buscar tu dispositivo en devices.json", pt: "Encontre seu dispositivo em devices.json", it: "Trova il tuo dispositivo in devices.json", zh: "在 devices.json 中查找您的设备"),
                             body: lz(en: "The wizard creates devices.json in the current folder. Find your plug by name. Copy \"id\" (Device ID, ~20 chars) and \"key\" (Local Key, 16 chars) into the app settings. The \"ip\" field contains the IP address if you chose to scan the network.", de: "Der Wizard erstellt devices.json im aktuellen Ordner. Steckdose anhand des Namens finden. \"id\" (Geraete-ID, ca. 20 Zeichen) und \"key\" (Local Key, 16 Zeichen) in die App-Einstellungen eintragen. Das Feld \"ip\" enthaelt die IP-Adresse, wenn du das Netzwerk gescannt hast.", fr: "L'assistant crée devices.json dans le dossier courant. Trouvez votre prise par son nom. Copiez \"id\" (ID appareil, ~20 cars) et \"key\" (clé locale, 16 cars) dans les réglages. Le champ \"ip\" contient l'adresse IP si vous avez scanné le réseau.", es: "El asistente crea devices.json en la carpeta actual. Busca tu enchufe por nombre. Copia \"id\" (ID de dispositivo, ~20 chars) y \"key\" (clave local, 16 chars) en los ajustes. El campo \"ip\" contiene la IP si escaneaste la red.", pt: "O assistente cria devices.json na pasta atual. Encontre sua tomada pelo nome. Copie \"id\" (Device ID, ~20 caracteres) e \"key\" (Local Key, 16 caracteres) nas configurações do app. O campo \"ip\" contém o endereço IP se você optou por escanear a rede.", it: "La procedura guidata crea devices.json nella cartella corrente. Trova la tua presa per nome. Copia \"id\" (Device ID, ~20 caratteri) e \"key\" (Local Key, 16 caratteri) nelle impostazioni dell'app. Il campo \"ip\" contiene l'indirizzo IP se hai scelto di scansionare la rete.", zh: "向导会在当前文件夹中生成 devices.json。请按名称找到您的插座，将 \"id\"（设备 ID，约 20 位字符）和 \"key\"（Local Key，16 位字符）复制到应用设置中。如果您选择了扫描网络，\"ip\" 字段中会包含 IP 地址。"),
                             command: nil)

                    // Info row
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle.fill").foregroundColor(.orange)
                        Text(lz(en: "The Local Key changes if the device is re-linked or the SmartLife account is re-connected. Re-run the wizard if the connection stops working.", de: "Der Local Key aendert sich, wenn das Gerät erneut verknüpft oder das SmartLife-Konto neu verbunden wird. Den Wizard erneut ausfuehren, wenn die Verbindung nicht mehr funktioniert.", fr: "La clé locale change si l'appareil est ré-associé ou le compte SmartLife reconnecté. Relancez l'assistant si la connexion ne fonctionne plus.", es: "La clave local cambia si el dispositivo se vuelve a vincular o la cuenta SmartLife se reconecta. Vuelve a ejecutar el asistente si la conexión deja de funcionar.", pt: "O Local Key muda se o dispositivo for vinculado novamente ou a conta SmartLife for reconectada. Execute o assistente novamente se a conexão parar de funcionar.", it: "Il Local Key cambia se il dispositivo viene ricollegato o l'account SmartLife viene riconnesso. Riesegui la procedura guidata se la connessione smette di funzionare.", zh: "如果设备重新关联或 SmartLife 账户重新连接，Local Key 将会改变。如果连接失效，请重新运行向导。"))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.08)).cornerRadius(10)
                }
                .padding()
            }
            .navigationTitle(lz(en: "Smart Plug Setup", de: "Smart-Steckdose einrichten", fr: "Config. prise intelligente", es: "Configurar enchufe", pt: "Configuração da Tomada Inteligente", it: "Configurazione Presa Intelligente", zh: "智能插座设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(lz(en: "Done", de: "Fertig", fr: "OK", es: "Listo", pt: "Concluído", it: "Fatto", zh: "完成")) { dismiss() }
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
// App-wide smart-plug status monitor.
//
// The polling loop lives here, in a long-lived singleton, NOT in the tile's
// `.task`. The dashboard re-lays-out its tiles every few seconds (printer
// status timer + LazyVGrid), which tears the tile down and would cancel any
// view-bound task mid-request — that's the "CancellationError" you saw. By
// owning the loop in a singleton that never gets torn down, the status is
// fetched and refreshed reliably regardless of what the UI does.
@MainActor
final class SmartPlugMonitor: ObservableObject {
    static let shared = SmartPlugMonitor()

    struct PlugState { var isOn: Bool? = nil; var watts: Double? = nil; var errorMsg: String? = nil }

    @Published private(set) var states: [String: PlugState] = [:]
    private var loops: [String: Task<Void, Never>] = [:]
    // A poll is in flight for this key — prevents the loop and an immediate
    // refresh() from opening two overlapping connections (Tuya plugs accept
    // only one at a time; overlaps cause connection-refused retry storms).
    private var inFlight: Set<String> = []

    private func key(_ ip: String, _ id: String) -> String { "\(ip)|\(id)" }

    func state(ip: String, deviceID: String) -> PlugState {
        states[key(ip, deviceID)] ?? PlugState()
    }

    // Starts the per-plug polling loop once. Idempotent and runs synchronously
    // up to the first `await`, so the loop is registered even if the caller's
    // own task is cancelled immediately afterwards.
    func ensurePolling(ip: String, deviceID: String, localKey: String,
                       type: PrinterConfig.SmartPlugType) {
        let k = key(ip, deviceID)
        guard loops[k] == nil else { return }
        guard isConfigured(ip: ip, deviceID: deviceID, localKey: localKey, type: type) else { return }
        loops[k] = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce(k: k, ip: ip, deviceID: deviceID, localKey: localKey, type: type)
                try? await Task.sleep(nanoseconds: 4_000_000_000)  // 4 s
            }
        }
    }

    // Immediate one-off refresh (e.g. when the app returns to the foreground).
    func refresh(ip: String, deviceID: String, localKey: String,
                 type: PrinterConfig.SmartPlugType) {
        let k = key(ip, deviceID)
        Task { [weak self] in
            await self?.pollOnce(k: k, ip: ip, deviceID: deviceID, localKey: localKey, type: type)
        }
    }

    private func isConfigured(ip: String, deviceID: String, localKey: String,
                              type: PrinterConfig.SmartPlugType) -> Bool {
        type == .shelly ? !ip.isEmpty
                        : TuyaLocalService.Config(host: ip, deviceID: deviceID, localKey: localKey) != nil
    }

    private func pollOnce(k: String, ip: String, deviceID: String, localKey: String,
                          type: PrinterConfig.SmartPlugType) async {
        // Skip if another poll for this plug is already running — no overlapping
        // connections to a single-connection Tuya plug.
        guard !inFlight.contains(k) else { return }
        inFlight.insert(k)
        defer { inFlight.remove(k) }

        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            do {
                let status: PlugStatus
                if type == .shelly {
                    status = try await ShellyLocalService.getStatus(host: ip)
                } else {
                    guard let cfg = TuyaLocalService.Config(host: ip, deviceID: deviceID, localKey: localKey) else { return }
                    status = try await TuyaLocalService.getStatus(config: cfg)
                }
                var s = states[k] ?? PlugState()
                s.isOn = status.power; s.watts = status.watts; s.errorMsg = nil
                states[k] = s
                return
            } catch is CancellationError {
                return  // never surface a cancellation as a user-facing error
            } catch {
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: 700_000_000)  // 0.7 s, then retry
                } else {
                    var s = states[k] ?? PlugState()
                    // error.localizedDescription follows the SYSTEM language, so it
                    // showed German text in an English app — use our own wording.
                    if s.isOn == nil { s.errorMsg = SpoolmanService.localizedTransport(error) }  // keep last good state otherwise
                    states[k] = s
                }
            }
        }
    }

    func setPower(_ on: Bool, ip: String, deviceID: String, localKey: String,
                  type: PrinterConfig.SmartPlugType) async throws {
        if type == .shelly {
            try await ShellyLocalService.setPower(on, host: ip)
        } else {
            guard let cfg = TuyaLocalService.Config(host: ip, deviceID: deviceID, localKey: localKey) else { throw TuyaError.noKey }
            try await TuyaLocalService.setPower(on, config: cfg)
        }
        let k = key(ip, deviceID)
        var s = states[k] ?? PlugState()
        s.isOn = on; s.errorMsg = nil
        states[k] = s
    }
}

struct SmartPlugTileView: View {
    let plugIP: String
    let deviceID: String
    let localKey: String
    let plugType: PrinterConfig.SmartPlugType
    let isBusy: Bool

    @ObservedObject private var monitor = SmartPlugMonitor.shared
    @State private var isLoading = false
    @State private var showConfirmOff = false
    @State private var showConfirmBusy = false
    @Environment(\.scenePhase) private var scenePhase

    // Status comes from the shared monitor, not from per-view @State.
    private var isOn: Bool?     { monitor.state(ip: plugIP, deviceID: deviceID).isOn }
    private var watts: Double?  { monitor.state(ip: plugIP, deviceID: deviceID).watts }
    private var errorMsg: String? { monitor.state(ip: plugIP, deviceID: deviceID).errorMsg }

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
                    Text(lz(en: "Smart Plug", de: "Smart-Steckdose", fr: "Prise intelligente", es: "Enchufe inteligente", pt: "Tomada Inteligente", it: "Presa Intelligente", zh: "智能插座"))
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
                        Text(lz(en: "OFF", de: "AUS", fr: "OFF", es: "OFF", pt: "DESLIGAR", it: "SPENTO", zh: "关"))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.75))
                            .padding(.leading, 16)
                            .opacity(isOn == false ? 1 : 0)
                        Spacer()
                        Text(lz(en: "ON", de: "EIN", fr: "ON", es: "ON", pt: "LIGAR", it: "ACCESO", zh: "开"))
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
                                 ? lz(en: "Connecting…", de: "Verbinde…", fr: "Connexion…", es: "Conectando…", pt: "Conectando…", it: "Connessione…", zh: "连接中…")
                                 : (isOn! ? lz(en: "On", de: "Eingeschaltet", fr: "Allumée", es: "Encendido", pt: "Ligado", it: "Acceso", zh: "已开启")
                                          : lz(en: "Off", de: "Ausgeschaltet", fr: "Éteinte", es: "Apagado", pt: "Desligar", it: "Spegni", zh: "关闭")))
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
            lz(en: "Really cut power?", de: "Strom wirklich ausschalten?", fr: "Couper l'alimentation ?", es: "¿Cortar la corriente?", pt: "Cortar energia mesmo?", it: "Interrompere davvero l'alimentazione?", zh: "确定要断电吗？"),
            isPresented: $showConfirmOff, titleVisibility: .visible) {
            Button(lz(en: "Yes", de: "Ja", fr: "Oui", es: "Sí", pt: "Sim", it: "Sì", zh: "是"), role: .destructive) {
                if isBusy { showConfirmBusy = true } else { sendPower(false) }
            }
            Button(lz(en: "No", de: "Nein", fr: "Non", es: "No", pt: "Não", it: "No", zh: "否"), role: .cancel) {}
        }
        .confirmationDialog(
            lz(en: "Printer is busy — really cut power?", de: "Drucker ist gerade beschäftigt, wirklich ausschalten?", fr: "L'imprimante est occupée, couper quand même ?", es: "La impresora está ocupada, ¿cortar igual?", pt: "A impressora está ocupada — cortar energia mesmo assim?", it: "La stampante è occupata — interrompere comunque l'alimentazione?", zh: "打印机正忙——仍要断电吗？"),
            isPresented: $showConfirmBusy, titleVisibility: .visible) {
            Button(lz(en: "Yes", de: "Ja", fr: "Oui", es: "Sí", pt: "Sim", it: "Sì", zh: "是"), role: .destructive) {
                sendPower(false)
            }
            Button(lz(en: "No", de: "Nein", fr: "Non", es: "No", pt: "Não", it: "No", zh: "否"), role: .cancel) {}
        }
        // Kick off the shared monitor's polling loop. This runs synchronously
        // up to its first await, so the loop survives even if this view (and
        // its task) is torn down a moment later by a dashboard re-layout.
        .onAppear {
            monitor.ensurePolling(ip: plugIP, deviceID: deviceID, localKey: localKey, type: plugType)
        }
        // Refresh immediately when the app returns to the foreground.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                monitor.ensurePolling(ip: plugIP, deviceID: deviceID, localKey: localKey, type: plugType)
                monitor.refresh(ip: plugIP, deviceID: deviceID, localKey: localKey, type: plugType)
            }
        }
    }

    // MARK: - Logic
    private func sendPower(_ on: Bool) {
        guard isConfigured else { return }
        isLoading = true
        Task {
            do {
                try await monitor.setPower(on, ip: plugIP, deviceID: deviceID, localKey: localKey, type: plugType)
                await MainActor.run { isLoading = false }
            } catch {
                await MainActor.run { isLoading = false }
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
                            Text(lz(en: "Local Connection", de: "Lokale Verbindung", fr: "Connexion locale", es: "Conexión local", pt: "Conexão Local", it: "Connessione Locale", zh: "本地连接"))
                                .font(.title2.bold())
                            Text(lz(en: "Direct access in your network", de: "Direktzugriff im Netzwerk", fr: "Accès direct au réseau", es: "Acceso directo a la red", pt: "Acesso direto na sua rede", it: "Accesso diretto nella tua rete", zh: "在您的网络中直接访问"))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 12) {
                        Label(lz(en: "Works at home via Wi-Fi", de: "Funktioniert zuhause per WLAN", fr: "Fonctionne à la maison via Wi-Fi", es: "Funciona en casa por Wi-Fi", pt: "Funciona em casa via Wi-Fi", it: "Funziona a casa via Wi-Fi", zh: "在家中通过 Wi-Fi 使用"),
                              systemImage: "wifi")
                            .font(.body.weight(.medium))

                        Label(lz(en: "Also works from anywhere via VPN", de: "Auch von unterwegs per VPN nutzbar", fr: "Fonctionne aussi partout via VPN", es: "También desde cualquier lugar con VPN", pt: "Também funciona de qualquer lugar via VPN", it: "Funziona anche ovunque tramite VPN", zh: "也可通过 VPN 随时随地使用"),
                              systemImage: "lock.shield.fill")
                            .font(.body.weight(.medium))
                            .foregroundColor(.blue)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text(lz(en: "VPN Tip", de: "VPN-Tipp", fr: "Conseil VPN", es: "Consejo VPN", pt: "Dica de VPN", it: "Suggerimento VPN", zh: "VPN 提示"))
                            .font(.headline)
                        Text(lz(en: "Set up a VPN server on your router (e.g. WireGuard or OpenVPN). Once connected, the app reaches your printer just like at home – no port forwarding needed.", de: "Richte einen VPN-Server auf deinem Router ein (z.B. WireGuard oder OpenVPN). Wenn du verbunden bist, erreicht die App deinen Drucker wie zuhause – keine Portweiterleitung nötig.", fr: "Configurez un serveur VPN sur votre routeur (ex. WireGuard ou OpenVPN). Une fois connecté, l'app atteint votre imprimante comme à la maison – sans redirection de port.", es: "Configura un servidor VPN en tu router (ej. WireGuard o OpenVPN). Una vez conectado, la app accede a tu impresora como en casa – sin redirección de puertos.", pt: "Configure um servidor VPN no seu roteador (ex.: WireGuard ou OpenVPN). Uma vez conectado, o app acessa sua impressora como se estivesse em casa – sem necessidade de redirecionamento de portas.", it: "Configura un server VPN sul tuo router (es. WireGuard o OpenVPN). Una volta connesso, l'app raggiunge la tua stampante come se fossi a casa – nessun port forwarding necessario.", zh: "在路由器上设置一个 VPN 服务器（例如 WireGuard 或 OpenVPN）。连接后，应用就能像在家中一样访问您的打印机——无需端口转发。"))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding()
                    .background(Color.blue.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
            .navigationTitle(lz(en: "Local", de: "Lokal", fr: "Local", es: "Local", pt: "Local", it: "Locale", zh: "本地"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(lz(en: "Done", de: "Fertig", fr: "OK", es: "Listo", pt: "Concluído", it: "Fatto", zh: "完成")) { dismiss() }
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
                        Text(lz(en: "Welcome", de: "Willkommen", fr: "Bienvenue", es: "Bienvenido", pt: "Bem-vindo", it: "Benvenuto", zh: "欢迎")).font(.largeTitle).bold()
                        Text(lz(en: "Let's find your printer", de: "Lass uns deinen Drucker finden", fr: "Trouvons votre imprimante", es: "Busquemos tu impresora", pt: "Vamos encontrar sua impressora", it: "Troviamo la tua stampante", zh: "让我们找到您的打印机")).font(.subheadline).foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 40)

                    VStack(spacing: 12) {
                        Button(action: { searchForPrinters() }) {
                            HStack {
                                if isSearching { ProgressView().scaleEffect(0.8).tint(.white) }
                                else { Image(systemName: "magnifyingglass") }
                                Text(lz(en: isSearching ? "Searching..." : "Search Network", de: isSearching ? "Suche läuft..." : "Im Netzwerk suchen", fr: isSearching ? "Recherche..." : "Chercher sur le réseau", es: isSearching ? "Buscando..." : "Buscar en la red", pt: isSearching ? "Buscando..." : "Buscar na Rede", it: isSearching ? "Ricerca in corso..." : "Cerca in Rete", zh: isSearching ? "搜索中..." : "搜索网络")).bold()
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
                                            es: "Añadir \(selectedIDs.count) impresora\(selectedIDs.count > 1 ? "s" : "")",
                                            pt: "Adicionar \(selectedIDs.count) impressora\(selectedIDs.count > 1 ? "s" : "")",
                                            it: "Aggiungi \(selectedIDs.count) \(selectedIDs.count > 1 ? "stampanti" : "stampante")",
                                            zh: "添加 \(selectedIDs.count) 台打印机"
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
                                Text(lz(en: "No printer found", de: "Kein Drucker gefunden", fr: "Aucune imprimante trouvée", es: "Impresora no encontrada", pt: "Nenhuma impressora encontrada", it: "Nessuna stampante trovata", zh: "未找到打印机")).font(.subheadline).foregroundColor(.secondary)
                            }
                            .padding().background(Color(.secondarySystemBackground)).cornerRadius(12)
                        }
                    }
                    .padding(.horizontal)

                    HStack {
                        Rectangle().fill(Color(.separator)).frame(height: 1)
                        Text(lz(en: "or", de: "oder", fr: "ou", es: "o", pt: "ou", it: "o", zh: "或")).font(.caption).foregroundColor(.secondary).padding(.horizontal, 8)
                        Rectangle().fill(Color(.separator)).frame(height: 1)
                    }
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 12) {
                        Text(lz(en: "Add manually", de: "Manuell eingeben", fr: "Ajouter manuellement", es: "Añadir manualmente", pt: "Adicionar manualmente", it: "Aggiungi manualmente", zh: "手动添加")).font(.subheadline).bold().padding(.horizontal)
                        VStack(spacing: 0) {
                            HStack {
                                Image(systemName: "printer.fill").foregroundColor(.blue).frame(width: 24)
                                TextField(lz(en: "Name e.g. Snapmaker U1", de: "Name z.B. Snapmaker U1", fr: "Nom ex. Snapmaker U1", es: "Nombre ej. Snapmaker U1", pt: "Nome ex.: Snapmaker U1", it: "Nome es. Snapmaker U1", zh: "名称，例如 Snapmaker U1"), text: $printerName)
                            }
                            .padding()
                            Divider().padding(.leading, 44)
                            HStack {
                                Image(systemName: "network").foregroundColor(.blue).frame(width: 24)
                                TextField(lz(en: "IP address e.g. 192.168.178.70", de: "IP-Adresse z.B. 192.168.178.70", fr: "Adresse IP ex. 192.168.178.70", es: "Dirección IP ej. 192.168.178.70", pt: "Endereço IP ex.: 192.168.178.70", it: "Indirizzo IP es. 192.168.178.70", zh: "IP 地址，例如 192.168.178.70"), text: $manualIP)
                                    .keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true)
                            }
                            .padding()
                        }
                        .background(Color(.secondarySystemBackground)).cornerRadius(14).padding(.horizontal)

                        Picker(lz(en: "Printer Type", de: "Druckertyp", fr: "Type d'imprimante", es: "Tipo de impresora", pt: "Tipo de Impressora", it: "Tipo di Stampante", zh: "打印机类型"), selection: $manualType) {
                            ForEach(PrinterConfig.PrinterType.allCases, id: \.self) { t in
                                Label(t.rawValue, image: t.imageName).tag(t)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)

                        Button(action: { connectManually() }) {
                            HStack {
                                Image(systemName: "link")
                                Text(lz(en: "Connect", de: "Verbinden", fr: "Connecter", es: "Conectar", pt: "Conectar", it: "Connetti", zh: "连接")).bold()
                            }
                            .foregroundColor(.white).frame(maxWidth: .infinity).padding()
                            .background(manualIP.isEmpty ? Color.gray : Color.blue).cornerRadius(14)
                        }
                        .disabled(manualIP.isEmpty).padding(.horizontal)
                    }

                    HStack {
                        Rectangle().fill(Color(.separator)).frame(height: 1)
                        Text(lz(en: "or", de: "oder", fr: "ou", es: "o", pt: "ou", it: "o", zh: "或")).font(.caption).foregroundColor(.secondary).padding(.horizontal, 8)
                        Rectangle().fill(Color(.separator)).frame(height: 1)
                    }
                    .padding(.horizontal)

                    Button(action: { enterDemoMode() }) {
                        HStack(spacing: 10) {
                            Image(systemName: "play.circle.fill").font(.system(size: 16))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lz(en: "Try Demo Mode", de: "Demo-Modus starten", fr: "Essayer la démo", es: "Probar modo demo", pt: "Experimentar Modo Demo", it: "Prova la Modalità Demo", zh: "试用演示模式"))
                                    .bold()
                                Text(lz(en: "Simulates a Snapmaker U1 – no printer required", de: "Simuliert einen Snapmaker U1 – kein Drucker nötig", fr: "Simule un Snapmaker U1 – aucune imprimante requise", es: "Simula un Snapmaker U1 – sin impresora", pt: "Simula um Snapmaker U1 – nenhuma impressora necessária", it: "Simula uno Snapmaker U1 – nessuna stampante richiesta", zh: "模拟 Snapmaker U1——无需实际打印机"))
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
            name: lz(en: "Demo Printer", de: "Demo-Drucker", fr: "Imprimante démo", es: "Impresora demo", pt: "Impressora Demo", it: "Stampante Demo", zh: "演示打印机"),
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
                                    es: isSearching ? "Buscando..." : "Buscar en la red",
                                    pt: isSearching ? "Buscando..." : "Buscar na Rede",
                                    it: isSearching ? "Ricerca in corso..." : "Cerca in Rete",
                                    zh: isSearching ? "搜索中..." : "搜索网络"))
                        }
                    }
                    .disabled(isSearching)
                }
                if searchDone && foundPrinters.isEmpty {
                    Section {
                        Text(lz(en: "No printers found on the network.", de: "Keine Drucker im Netzwerk gefunden.", fr: "Aucune imprimante trouvée sur le réseau.", es: "No se encontraron impresoras en la red.", pt: "Nenhuma impressora encontrada na rede.", it: "Nessuna stampante trovata sulla rete.", zh: "在网络中未找到打印机。"))
                            .foregroundColor(.secondary)
                    }
                }
                if !foundPrinters.isEmpty {
                    Section(header: Text(lz(en: "Found Printers", de: "Gefundene Drucker", fr: "Imprimantes trouvées", es: "Impresoras encontradas", pt: "Impressoras Encontradas", it: "Stampanti Trovate", zh: "找到的打印机"))) {
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
                                        Text(lz(en: "Added", de: "Vorhanden", fr: "Ajouté", es: "Añadido", pt: "Adicionada", it: "Aggiunta", zh: "已添加"))
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
                                            es: "Añadir \(selectedIDs.count) impresora\(selectedIDs.count > 1 ? "s" : "")",
                                            pt: "Adicionar \(selectedIDs.count) impressora\(selectedIDs.count > 1 ? "s" : "")",
                                            it: "Aggiungi \(selectedIDs.count) \(selectedIDs.count > 1 ? "stampanti" : "stampante")",
                                            zh: "添加 \(selectedIDs.count) 台打印机")).bold()
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(lz(en: "Search Network", de: "Netzwerk suchen", fr: "Chercher réseau", es: "Buscar red", pt: "Buscar na Rede", it: "Cerca in Rete", zh: "搜索网络"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(lz(en: "Done", de: "Fertig", fr: "OK", es: "Listo", pt: "Concluído", it: "Fatto", zh: "完成")) { onDismiss?(); dismiss() }
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
                // Previously only set by the Dashboard view's onAppear, so a
                // printer never actually opened this session (e.g. right after
                // launch, before the user swiped to it) kept PrinterService's
                // "0A84FF" default (Apple system blue) — synced to the Watch
                // as soon as a print started polling, showing the wrong theme
                // color until the user happened to open that printer's tab.
                if let hex = Self.resolveThemeHex(config.themeColor) { existing.themeHex = hex }
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
                if let hex = Self.resolveThemeHex(config.themeColor) { svc.themeHex = hex }
                updated.append(svc)
            }
        }
        services = updated
        pruneSharedCaches(printers: settings.printers)
    }

    // PrinterConfig.themeColor is a theme KEY ("green", "blue", …) or — for
    // custom colors — a raw hex string. themeHex consumers (widget, Watch)
    // need a hex; resolve exactly like the Dashboard's `themeColor` does.
    static func resolveThemeHex(_ keyOrHex: String) -> String? {
        guard !keyOrHex.isEmpty else { return nil }
        if Color(hex: keyOrHex) != nil { return keyOrHex }
        return appThemes.first { $0.key == keyOrHex }?.color.hexString
    }

    // Remove stale printers (renamed or deleted ones) from the app-group caches
    // that feed the widgets and the Apple Watch. Entries are merged by name and
    // were never cleaned up on rename — over time the Watch showed "ghost"
    // printers that no longer exist in the app.
    private func pruneSharedCaches(printers: [PrinterConfig]) {
        let validNames = Set(printers.map { $0.name })
        guard let defaults = UserDefaults(suiteName: "group.paxxmaker.u1") else { return }
        var didChange = false

        func pruneJSONArray(key: String) {
            guard let data = defaults.data(forKey: key),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            let kept = arr.filter { validNames.contains(($0["id"] as? String) ?? "") }
            if kept.count != arr.count,
               let encoded = try? JSONSerialization.data(withJSONObject: kept) {
                defaults.set(encoded, forKey: key)
                didChange = true
            }
        }
        pruneJSONArray(key: "w_all_printers")
        pruneJSONArray(key: "watch_printer_configs")

        // Also sync each entry's push fields with the CURRENT config. The
        // entry is normally refreshed by the printer's own polling — but a
        // printer that is offline never polls successfully, so switching it to
        // Local left its old cfSecret/pushMode in the shared configs and the
        // widget/Watch kept hitting the Worker /status endpoint for a printer
        // that no longer has push at all.
        if let data = defaults.data(forKey: "watch_printer_configs"),
           var arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var changed = false
            for i in arr.indices {
                guard let id = arr[i]["id"] as? String,
                      let cfg = printers.first(where: { $0.name == id }) else { continue }
                let pushOn = cfg.pushMode == .cloudflare && !cfg.cloudflareNotifySecret.isEmpty
                let wantSecret: String? = pushOn ? cfg.cloudflareNotifySecret : nil
                let wantMode: String? = pushOn ? "cloudflare" : nil
                if (arr[i]["cfSecret"] as? String) != wantSecret || (arr[i]["pushMode"] as? String) != wantMode {
                    arr[i]["cfSecret"] = wantSecret as Any?
                    arr[i]["pushMode"] = wantMode as Any?
                    changed = true
                }
            }
            if changed, let encoded = try? JSONSerialization.data(withJSONObject: arr) {
                defaults.set(encoded, forKey: "watch_printer_configs")
                didChange = true
            }
        }

        if var bgStates = defaults.dictionary(forKey: "bg_prev_print_states") as? [String: String] {
            let before = bgStates.count
            bgStates = bgStates.filter { validNames.contains($0.key) }
            if bgStates.count != before { defaults.set(bgStates, forKey: "bg_prev_print_states"); didChange = true }
        }

        // Only act when something was actually pruned. This method runs on
        // EVERY printer-list sync (app open, tab switches, settings saves) —
        // unconditionally reloading all widget timelines here made every such
        // sync refetch every widget instance, each of which may hit the
        // Cloudflare /status endpoint (that's where the mysterious request
        // bursts came from). Ghost cleanup is a rare event; reload only then.
        guard didChange else { return }

        // Push the cleaned list to the Watch right away so its own cache gets
        // replaced instead of keeping the ghosts until the next status update.
        if WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isPaired {
            var ctx: [String: Any] = ["at": Date().timeIntervalSince1970]
            if let printers = defaults.data(forKey: "w_all_printers") { ctx["printers"] = printers }
            if let cfgs = defaults.data(forKey: "watch_printer_configs") { ctx["configs"] = cfgs }
            if ctx.count > 1 { try? WCSession.default.updateApplicationContext(ctx) }
        }
        WidgetCenter.shared.reloadAllTimelines()
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
    // Persisted so relaunching the app returns to the tab that was last open.
    @AppStorage("last_printertab_index") private var selectedTab: Int = 0
    @AppStorage("splitscreen_mode") private var splitscreenMode: Bool = false
    @AppStorage("current_splitscreen_count") private var storedSplitscreenCount: Int = 1
    @AppStorage("spoolman_enabled") private var spoolmanEnabled: Bool = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var splitCurrentPage: Int = 0

    var nfcTabIndex: Int { printers.count }
    var spoolmanTabIndex: Int { printers.count + (showNFCTab ? 1 : 0) }
    var settingsTabIndex: Int { printers.count + (showNFCTab ? 1 : 0) + (spoolmanEnabled ? 1 : 0) }

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
        mainContent
            .onAppear {
                // A restored tab index can be out of range (a printer was
                // removed, or NFC/Spoolman turned off since last launch) —
                // clamp it so we don't land on a blank/wrong tab.
                if selectedTab < 0 || selectedTab > settingsTabIndex { selectedTab = 0 }
            }
    }

    @ViewBuilder
    private var mainContent: some View {
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
                if spoolmanEnabled {
                    SpoolmanView()
                        .tabItem { Label("Spoolman", systemImage: "record.circle.fill") }
                        .tag(spoolmanTabIndex)
                }
                SettingsView(settings: settings, onSave: onSettingsSave)
                    .environmentObject(printerServices)
                    .tabItem {
                        Label(lz(en: "Settings", de: "Einstellungen", fr: "Paramètres", es: "Ajustes", pt: "Configurações", it: "Impostazioni", zh: "设置"),
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
        } else if spoolmanEnabled && selectedTab == spoolmanTabIndex {
            SpoolmanView()
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
                    if spoolmanEnabled {
                        tabButton(icon: "record.circle.fill", label: "Spoolman", tag: spoolmanTabIndex)
                    }
                    tabButton(
                        icon: "gearshape.fill",
                        label: lz(en: "Settings", de: "Einstellungen", fr: "Paramètres", es: "Ajustes", pt: "Configurações", it: "Impostazioni", zh: "设置"),
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
        } else if spoolmanEnabled && selectedTab == spoolmanTabIndex {
            SpoolmanView()
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
                    if spoolmanEnabled {
                        tabButton(icon: "record.circle.fill", label: "Spoolman", tag: spoolmanTabIndex)
                    }
                    tabButton(
                        icon: "gearshape.fill",
                        label: lz(en: "Settings", de: "Einstellungen", fr: "Paramètres", es: "Ajustes", pt: "Configurações", it: "Impostazioni", zh: "设置"),
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
    @AppStorage("spoolman_enabled") private var spoolmanEnabled: Bool = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("has_shown_firmware_notice") private var hasShownFirmwareNotice: Bool = false
    @AppStorage("has_selected_language") private var hasSelectedLanguage: Bool = false
    @AppStorage("has_accepted_disclaimer") private var hasAcceptedDisclaimer: Bool = false
    // Versioned so the one-time feature tour also fires for existing users after
    // they update to this version. Bump the suffix to re-show it in a future update.
    @AppStorage("has_seen_feature_tour_1") private var hasSeenFeatureTour: Bool = false
    // "What's new" popup for the U1 per-nozzle Spoolman update (one-time, own key
    // so existing users who already saw the old tour still get this one).
    @AppStorage("has_seen_whatsnew_spoollink_1") private var hasSeenWhatsNewSL: Bool = false
    @State private var showWhatsNewSL = false
    // Release behaviour: the walkthrough fires exactly once (gated by
    // has_seen_feature_tour_1) and then marks itself as seen. Flip to true only
    // for repeated testing.
    private let alwaysShowTourForTesting = false
    @State private var showLanguagePicker: Bool = false
    @State private var showFirmwareNotice: Bool = false
    @State private var showDisclaimer: Bool = false
    @StateObject private var tour = TourGuide()
    // Persisted so relaunching the app returns to the tab that was last open.
    @AppStorage("last_root_tab") private var rootTabSel: String = "main"
    // Persisted so relaunching returns to the printer that was last swiped to.
    @AppStorage("last_printer_page") private var currentPrinterPage: Int = 0
    @State private var splitCurrentPage: Int = 0

    private var visiblePrinters: [(PrinterConfig, PrinterService)] {
        Array(zip(settings.printers, printerServices.services)).filter { $0.0.isVisible }
    }

    private var isSplitscreenActive: Bool {
        splitscreenMode && horizontalSizeClass == .regular && visiblePrinters.count >= 2
    }

    // Start the guided walkthrough from the printer tab so "tap Settings" makes sense.
    private func startTour() {
        rootTabSel = "main"
        tour.start()
    }

    // Show the one-time "what's new" popup. Unlike the previous one this is not
    // gated on owning a U1: the Spoollink half is U1-only, but the thank-you for
    // the feedback is addressed to everyone.
    private func maybeShowWhatsNew() {
        guard settings.hasCompletedOnboarding, !hasSeenWhatsNewSL else { return }
        showWhatsNewSL = true
    }

    // Root-level coach marks: the intro card and the "tap Settings" step.
    // (The Spoolman/printer steps live in SettingsView, Server-Push in the sheet.)
    @ViewBuilder
    private var tourRootOverlay: some View {
        switch tour.step {
        case .intro:
            ZStack {
                Color.black.opacity(0.62).ignoresSafeArea()
                VStack(spacing: 16) {
                    Image(systemName: "sparkles").font(.system(size: 38)).foregroundColor(.yellow)
                    Text(lz(en: "What's new", de: "Das ist neu", fr: "Nouveautés", es: "Novedades", pt: "Novidades", it: "Novità", zh: "新功能"))
                        .font(.title2).bold()
                    Text(lz(en: "A quick tour shows you where to find the two new features: Spoolman and Server Push.",
                            de: "Eine kurze Führung zeigt dir, wo du die zwei neuen Funktionen findest: Spoolman und Server-Push.",
                            fr: "Une visite rapide te montre où trouver les deux nouveautés : Spoolman et le push serveur.",
                            es: "Un recorrido rápido te muestra dónde están las dos novedades: Spoolman y Push del servidor.",
                            pt: "Um tour rápido mostra onde encontrar os dois novos recursos: Spoolman e Push do Servidor.",
                            it: "Un breve tour ti mostra dove trovare le due novità: Spoolman e Push dal Server.",
                            zh: "快速导览将向你展示两项新功能的位置：Spoolman 和服务器推送。"))
                        .font(.subheadline).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        rootTabSel = "settings"   // drive to Settings for the next step
                        withAnimation { tour.advanceFromIntro() }
                    } label: {
                        Text(lz(en: "Start", de: "Los geht's", fr: "C'est parti", es: "Empezar", pt: "Começar", it: "Iniziamo", zh: "开始"))
                            .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Color.accentColor).foregroundColor(.white).cornerRadius(12)
                    }
                    .padding(.top, 2)
                    Button { withAnimation { tour.finish() } } label: {
                        Text(lz(en: "Skip", de: "Überspringen", fr: "Passer", es: "Omitir", pt: "Pular", it: "Salta", zh: "跳过"))
                            .font(.footnote).foregroundColor(.secondary)
                    }
                }
                .padding(24)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 14)
                .padding(.horizontal, 30)
            }
        default:
            EmptyView()
        }
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
                        TabView(selection: $rootTabSel) {
                            if isSplitscreenActive {
                                SplitscreenView(
                                    printers: visiblePrinters,
                                    allServices: printerServices.services,
                                    currentPage: $splitCurrentPage
                                )
                                .tabItem {
                                    Label(lz(en: "Split Screen", de: "Splitscreen", fr: "Écran partagé", es: "Pantalla dividida", pt: "Tela Dividida", it: "Schermo Diviso", zh: "分屏"),
                                          systemImage: "rectangle.split.2x1.fill")
                                }
                                .tag("main")
                            } else {
                                PrinterPagerView(
                                    printers: visiblePrinters,
                                    allServices: printerServices.services,
                                    currentPage: $currentPrinterPage
                                )
                                .tabItem {
                                    Label(currentConfig?.name ?? lz(en: "Printers", de: "Drucker", fr: "Imprimantes", es: "Impresoras", pt: "Impressoras", it: "Stampanti", zh: "打印机"),
                                          systemImage: currentConfig?.type.icon ?? "printer.fill")
                                }
                                .tag("main")
                            }
                            if showNFCTab {
                                NFCView()
                                    .tabItem { Label("NFC", systemImage: "wave.3.right") }
                                    .tag("nfc")
                            }
                            if spoolmanEnabled {
                                SpoolmanView()
                                    .tabItem { Label("Spoolman", systemImage: "record.circle.fill") }
                                    .tag("spoolman")
                            }
                            SettingsView(settings: settings) {
                                printerServices.update(from: settings)
                            }
                            .environmentObject(printerServices)
                            .tabItem { Label(lz(en: "Settings", de: "Einstellungen", fr: "Paramètres", es: "Ajustes", pt: "Configurações", it: "Impostazioni", zh: "设置"), systemImage: "gearshape.fill") }
                            .tag("settings")
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
        .environmentObject(tour)
        .onAppear {
            // Restored tab may no longer exist (its feature was turned off) —
            // fall back to the printer tab so the TabView isn't left blank.
            if (rootTabSel == "nfc" && !showNFCTab) || (rootTabSel == "spoolman" && !spoolmanEnabled) {
                rootTabSel = "main"
            }
            // Clamp the restored printer page if a printer was removed/hidden.
            // Only when printers are actually loaded — during the brief launch
            // window `visiblePrinters` is empty, and clamping then would wipe
            // the restored page back to 0.
            if !visiblePrinters.isEmpty && (currentPrinterPage < 0 || currentPrinterPage >= visiblePrinters.count) {
                currentPrinterPage = 0
            }
            if !hasSelectedLanguage {
                showLanguagePicker = true
            } else if !hasAcceptedDisclaimer {
                showDisclaimer = true
            } else if !hasShownFirmwareNotice {
                showFirmwareNotice = true
            } else if settings.hasCompletedOnboarding {
                maybeShowWhatsNew()
            }
        }
        // New users reach the popup right after finishing onboarding.
        .onChange(of: settings.hasCompletedOnboarding) { _, done in
            if done && hasShownFirmwareNotice {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { maybeShowWhatsNew() }
            }
        }
        // When the walkthrough finishes, remember it so it never repeats.
        .onChange(of: tour.step) { _, s in
            if s == .finished {
                if !alwaysShowTourForTesting { hasSeenFeatureTour = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation { tour.step = .inactive }
                }
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    if settings.hasCompletedOnboarding {
                        maybeShowWhatsNew()
                    }
                }
            }
        }
        .sheet(isPresented: $showWhatsNewSL) {
            WhatsNewSpoollinkView { hasSeenWhatsNewSL = true; showWhatsNewSL = false }
        }
        .overlay { tourRootOverlay }
        .animation(.easeInOut(duration: 0.25), value: tour.step)
    }
}

// MARK: - What's New popup (Spoollink + feedback note)
struct WhatsNewSpoollinkView: View {
    var onDismiss: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            // Scrollable so large Dynamic Type can't push the button off-screen.
            ScrollView {
            VStack(spacing: 18) {
            Image(systemName: "link.circle.fill")
                .font(.system(size: 46)).foregroundColor(.orange).padding(.top, 10)
            Text(lz(en: "New: SpoolLink", de: "Neu: SpoolLink", fr: "Nouveau : SpoolLink", es: "Nuevo: SpoolLink", pt: "Novo: SpoolLink", it: "Novità: SpoolLink", zh: "新功能：SpoolLink"))
                .font(.title2).bold().multilineTextAlignment(.center)
            Text(lz(
                en: "The app now supports SpoolLink. If you run firmware v1.5.2-paxx12-21 with SpoolLink on your U1, it is picked up automatically — there is nothing to switch on. The “Spools” tile then turns into a SpoolLink tile.\n\nThank you so much for your feedback, I was really happy to read it! I haven’t got round to everything yet, but I’ll be tackling the rest step by step.",
                de: "Die App unterstützt jetzt SpoolLink. Wer auf dem U1 die Firmware v1.5.2-paxx12-21 mit SpoolLink nutzt, bei dem wird das automatisch erkannt — es muss nichts eingeschaltet werden. Die Kachel „Spulen“ wird dann zur SpoolLink-Kachel.\n\nVielen Dank für euer Feedback, ich habe mich sehr darüber gefreut! Ich bin noch nicht zu allem gekommen, nehme den Rest aber nach und nach in Angriff.",
                fr: "L’app prend désormais en charge SpoolLink. Si tu utilises le firmware v1.5.2-paxx12-21 avec SpoolLink sur ta U1, il est détecté automatiquement — rien à activer. La tuile « Bobines » devient alors une tuile SpoolLink.\n\nMerci beaucoup pour vos retours, ils m’ont fait très plaisir ! Je n’ai pas encore eu le temps de tout traiter, mais je m’y attelle petit à petit.",
                es: "La app ya es compatible con SpoolLink. Si usas el firmware v1.5.2-paxx12-21 con SpoolLink en tu U1, se detecta automáticamente: no hay nada que activar. La tarjeta «Bobinas» se convierte entonces en una tarjeta de SpoolLink.\n\n¡Muchas gracias por vuestros comentarios, me han hecho mucha ilusión! Todavía no he podido con todo, pero iré abordando el resto poco a poco.",
                pt: "O app agora é compatível com o SpoolLink. Se você usa o firmware v1.5.2-paxx12-21 com SpoolLink na sua U1, ele é detectado automaticamente — não há nada para ativar. O bloco “Bobinas” passa então a ser um bloco SpoolLink.\n\nMuito obrigado pelo feedback, fiquei muito feliz com ele! Ainda não consegui fazer tudo, mas vou tratar do resto aos poucos.",
                it: "L’app ora supporta SpoolLink. Se usi il firmware v1.5.2-paxx12-21 con SpoolLink sulla tua U1, viene rilevato automaticamente: non c’è nulla da attivare. Il riquadro «Bobine» diventa allora un riquadro SpoolLink.\n\nGrazie mille per i vostri riscontri, mi hanno fatto molto piacere! Non sono ancora riuscito a fare tutto, ma affronterò il resto poco a poco.",
                zh: "应用现已支持 SpoolLink。如果你的 U1 使用带 SpoolLink 的固件 v1.5.2-paxx12-21，应用会自动识别，无需手动开启。“料盘”卡片随之会变成 SpoolLink 卡片。\n\n非常感谢大家的反馈，我看得很开心！有些内容我还没来得及处理，但会逐步完成。"))
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 20)
            }   // ScrollView

            Button(action: onDismiss) {
                Text(lz(en: "Got it", de: "Verstanden", fr: "Compris", es: "Entendido", pt: "Entendi", it: "Ho capito", zh: "知道了"))
                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Color.accentColor).foregroundColor(.white).cornerRadius(12)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            .background(Color(.systemBackground))
        }
        .presentationDetents([.medium, .large])
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

                        Text(lz(en: "Legal Notice", de: "Rechtlicher Hinweis", fr: "Mentions légales", es: "Aviso legal", pt: "Aviso Legal", it: "Nota Legale", zh: "法律声明"))
                            .font(.title2).bold()
                            .multilineTextAlignment(.center)

                        Text(lz(en: "Please read and accept the following before using PaxxMaker.", de: "Bitte lies und akzeptiere folgende Hinweise vor der Nutzung von PaxxMaker.", fr: "Veuillez lire et accepter les mentions suivantes avant d'utiliser PaxxMaker.", es: "Lee y acepta los siguientes avisos antes de usar PaxxMaker.", pt: "Leia e aceite o seguinte antes de usar o PaxxMaker.", it: "Leggi e accetta quanto segue prima di usare PaxxMaker.", zh: "使用 PaxxMaker 前，请阅读并接受以下内容。"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        disclaimerRow(
                            icon: "person.slash.fill", color: .blue,
                            title: lz(en: "Independent App", de: "Unabhängige App", fr: "Application indépendante", es: "Aplicación independiente", pt: "App Independente", it: "App Indipendente", zh: "独立应用"),
                            text: lz(en: "PaxxMaker is an independent hobby project and is not affiliated with, endorsed by, or officially connected to Snapmaker in any way.", de: "PaxxMaker ist ein unabhängiges Hobbyprojekt und steht in keiner Verbindung zu Snapmaker. Die App ist weder von Snapmaker autorisiert noch wird sie von Snapmaker unterstützt.", fr: "PaxxMaker est un projet hobby indépendant, non affilié, approuvé ou connecté officiellement à Snapmaker de quelque manière que ce soit.", es: "PaxxMaker es un proyecto hobby independiente y no está afiliado, respaldado ni conectado oficialmente con Snapmaker de ninguna manera.", pt: "PaxxMaker é um projeto de hobby independente e não é afiliado, endossado ou oficialmente conectado à Snapmaker de forma alguma.", it: "PaxxMaker è un progetto hobbistico indipendente e non è affiliato, sponsorizzato o ufficialmente collegato a Snapmaker in alcun modo.", zh: "PaxxMaker 是一个独立的业余爱好项目，与 Snapmaker 没有任何隶属、认可或官方关联。")
                        )

                        disclaimerRow(
                            icon: "building.2.fill", color: .purple,
                            title: lz(en: "Trademark Notice", de: "Markenhinweis", fr: "Avis de marque", es: "Aviso de marca registrada", pt: "Aviso de Marca Registrada", it: "Nota sul Marchio", zh: "商标声明"),
                            text: lz(en: "\"Snapmaker\" and related names are trademarks of Snapmaker Inc. These names are used solely to describe technical compatibility and do not imply any affiliation.", de: "\"Snapmaker\" und damit verbundene Namen sind Marken der Snapmaker Inc. Die Nennung dient ausschließlich der Beschreibung der technischen Kompatibilität und impliziert keinerlei Verbindung.", fr: "« Snapmaker » et les noms associés sont des marques de Snapmaker Inc. Ces noms sont utilisés uniquement pour décrire la compatibilité technique.", es: "\"Snapmaker\" y los nombres relacionados son marcas comerciales de Snapmaker Inc. Estos nombres se usan únicamente para describir la compatibilidad técnica.", pt: "\"Snapmaker\" e nomes relacionados são marcas registradas da Snapmaker Inc. Esses nomes são usados apenas para descrever a compatibilidade técnica e não implicam qualquer afiliação.", it: "\"Snapmaker\" e i nomi correlati sono marchi di Snapmaker Inc. Questi nomi sono utilizzati esclusivamente per descrivere la compatibilità tecnica e non implicano alcuna affiliazione.", zh: "\"Snapmaker\" 及相关名称是 Snapmaker Inc. 的商标。这些名称仅用于说明技术兼容性，并不意味着任何关联关系。")
                        )

                        disclaimerRow(
                            icon: "flag.2.crossed.fill", color: .green,
                            title: lz(en: "No Competition", de: "Kein Wettbewerb", fr: "Pas de concurrence", es: "Sin competencia", pt: "Sem Concorrência", it: "Nessuna Concorrenza", zh: "非竞争关系"),
                            text: lz(en: "PaxxMaker does not compete with Snapmaker's official apps or services. It is a community tool built on the open Klipper/Moonraker API.", de: "PaxxMaker steht in keinem Wettbewerb zu offiziellen Snapmaker-Apps oder -Diensten. Die App ist ein Community-Tool auf Basis der offenen Klipper/Moonraker-API.", fr: "PaxxMaker ne concurrence pas les applications ou services officiels de Snapmaker. C'est un outil communautaire basé sur l'API ouverte Klipper/Moonraker.", es: "PaxxMaker no compite con las aplicaciones o servicios oficiales de Snapmaker. Es una herramienta comunitaria basada en la API abierta Klipper/Moonraker.", pt: "PaxxMaker não compete com os apps ou serviços oficiais da Snapmaker. É uma ferramenta da comunidade construída sobre a API aberta Klipper/Moonraker.", it: "PaxxMaker non compete con le app o i servizi ufficiali di Snapmaker. È uno strumento della community basato sull'API aperta Klipper/Moonraker.", zh: "PaxxMaker 不与 Snapmaker 的官方应用或服务竞争，它是基于开放的 Klipper/Moonraker API 构建的社区工具。")
                        )

                        disclaimerRow(
                            icon: "exclamationmark.shield.fill", color: .orange,
                            title: lz(en: "No Liability", de: "Haftungsausschluss", fr: "Absence de responsabilité", es: "Sin responsabilidad", pt: "Isenção de Responsabilidade", it: "Nessuna Responsabilità", zh: "免责声明"),
                            text: lz(en: "Use of this app is at your own risk. The developer assumes no liability for damages, data loss, hardware damage, or any other issues arising from use of this app.", de: "Die Nutzung dieser App erfolgt auf eigene Gefahr. Der Entwickler übernimmt keine Haftung für Schäden, Datenverluste, Hardwareschäden oder sonstige Probleme, die durch die Nutzung entstehen.", fr: "L'utilisation de cette application se fait à vos propres risques. Le développeur décline toute responsabilité pour les dommages, pertes de données ou autres problèmes.", es: "El uso de esta aplicación es bajo tu propio riesgo. El desarrollador no asume responsabilidad por daños, pérdida de datos u otros problemas derivados del uso.", pt: "O uso deste app é por sua conta e risco. O desenvolvedor não assume nenhuma responsabilidade por danos, perda de dados, danos ao hardware ou quaisquer outros problemas decorrentes do uso deste app.", it: "L'uso di questa app è a proprio rischio. Lo sviluppatore non si assume alcuna responsabilità per danni, perdita di dati, danni hardware o qualsiasi altro problema derivante dall'uso di questa app.", zh: "使用本应用需自行承担风险。开发者对因使用本应用而产生的损坏、数据丢失、硬件损坏或任何其他问题概不负责。")
                        )
                    }
                    .padding(.horizontal, 4)

                    Button(action: onAccept) {
                        Text(lz(en: "Accept & Continue", de: "Akzeptieren & Weiter", fr: "Accepter & Continuer", es: "Aceptar & Continuar", pt: "Aceitar e Continuar", it: "Accetta e Continua", zh: "接受并继续"))
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
        ("pt", "🇵🇹", "Português"),
        ("it", "🇮🇹", "Italiano"),
        ("zh", "🇨🇳", "中文"),
    ]

    var continueLabel: String {
        switch selected {
        case "de": return "Weiter"
        case "fr": return "Continuer"
        case "es": return "Continuar"
        case "pt": return "Continuar"
        case "it": return "Continua"
        case "zh": return "继续"
        default:   return "Continue"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Scrollable so the whole list stays reachable at large Dynamic Type
            // sizes; the continue button is pinned below and never scrolls away.
            ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "globe")
                    .font(.system(size: 48))
                    .foregroundColor(.blue)
                    .padding(22)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(Circle())
                    .padding(.top, 32)

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
            .padding(.bottom, 24)
            }   // ScrollView

            Button(action: onContinue) {
                Text(continueLabel)
                    .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Color.blue).cornerRadius(14)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .background(Color(.systemBackground))
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

                        Text(lz(en: "Important Notice", de: "Wichtiger Hinweis", fr: "Avis important", es: "Aviso importante", pt: "Aviso Importante", it: "Avviso Importante", zh: "重要提示"))
                            .font(.title2).bold()
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        noticeRow(
                            icon: "cpu.fill", color: .orange,
                            title: lz(en: "Custom Firmware required", de: "Custom Firmware erforderlich", fr: "Firmware personnalisé requis", es: "Firmware personalizado requerido", pt: "Firmware personalizado necessário", it: "È richiesto un firmware personalizzato", zh: "需要自定义固件"),
                            text: lz(en: "This app is designed exclusively for the Snapmaker U1 with the paxx12 custom firmware. Without this firmware the app will not work correctly or at all.", de: "Diese App ist ausschließlich für den Snapmaker U1 mit der paxx12 Custom Firmware entwickelt. Ohne diese Firmware funktioniert die App nicht korrekt oder gar nicht.", fr: "Cette application est conçue exclusivement pour le Snapmaker U1 avec le firmware personnalisé paxx12. Sans ce firmware, l'application ne fonctionnera pas correctement.", es: "Esta aplicación está diseñada exclusivamente para el Snapmaker U1 con el firmware personalizado paxx12. Sin este firmware, la aplicación no funcionará correctamente.", pt: "Este app foi projetado exclusivamente para o Snapmaker U1 com o firmware personalizado paxx12. Sem esse firmware, o app não funcionará corretamente ou não funcionará de forma alguma.", it: "Questa app è progettata esclusivamente per lo Snapmaker U1 con il firmware personalizzato paxx12. Senza questo firmware, l'app non funzionerà correttamente o non funzionerà affatto.", zh: "本应用专为搭载 paxx12 自定义固件的 Snapmaker U1 设计。没有该固件，应用将无法正常工作，甚至完全无法使用。")
                        )

                        noticeRow(
                            icon: "exclamationmark.shield.fill", color: .red,
                            title: lz(en: "Use at your own risk", de: "Nutzung auf eigene Gefahr", fr: "Utilisation à vos risques", es: "Uso bajo su propio riesgo", pt: "Use por sua conta e risco", it: "Usa a tuo rischio", zh: "使用风险自负"),
                            text: lz(en: "Custom firmware carries risks. Please inform yourself thoroughly before installation. I assume no liability for any damages or issues.", de: "Custom Firmware birgt Risiken. Bitte informiere dich vor der Installation gründlich. Ich übernehme keine Haftung für Schäden oder Probleme.", fr: "Un firmware personnalisé comporte des risques. Veuillez vous informer avant l'installation. Je décline toute responsabilité pour les dommages.", es: "El firmware personalizado conlleva riesgos. Infórmese antes de la instalación. No asumo responsabilidad por daños o problemas.", pt: "Firmware personalizado envolve riscos. Informe-se cuidadosamente antes da instalação. Não assumo nenhuma responsabilidade por quaisquer danos ou problemas.", it: "Il firmware personalizzato comporta dei rischi. Informati accuratamente prima dell'installazione. Non mi assumo alcuna responsabilità per eventuali danni o problemi.", zh: "自定义固件存在风险。安装前请仔细了解相关信息。对于由此产生的任何损坏或问题，本人概不负责。")
                        )

                        noticeRow(
                            icon: "arrow.triangle.branch", color: .blue,
                            title: lz(en: "Installation", de: "Installation", fr: "Installation", es: "Instalación", pt: "Instalação", it: "Installazione", zh: "安装"),
                            text: lz(en: "Installation instructions and the latest firmware version can be found on GitHub.", de: "Installationsanleitung und die neueste Firmware-Version findest du auf GitHub.", fr: "Les instructions d'installation et la dernière version du firmware se trouvent sur GitHub.", es: "Las instrucciones de instalación y la última versión del firmware se encuentran en GitHub.", pt: "As instruções de instalação e a versão mais recente do firmware podem ser encontradas no GitHub.", it: "Le istruzioni di installazione e l'ultima versione del firmware sono disponibili su GitHub.", zh: "安装说明和最新固件版本可在 GitHub 上找到。")
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
                            Text(lz(en: "Understood", de: "Verstanden", fr: "Compris", es: "Entendido", pt: "Entendi", it: "Capito", zh: "知道了"))
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
                        Text(lz(en: "Thanks for the great custom firmware", de: "Danke für die tolle custom firmware", fr: "Merci pour le super firmware personnalisé", es: "Gracias por el gran firmware personalizado", pt: "Obrigado pelo ótimo firmware personalizado", it: "Grazie per l'ottimo firmware personalizzato", zh: "感谢出色的自定义固件"))
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
    // Extra fields (Spoolman round-trip): written and read back so a scanned tag
    // fully re-creates the filament, including its price.
    var name: String = ""
    var price: Double = 0
    var spoolWeight: Int = 0   // empty spool weight (g)
    var density: Double = 0
    var articleNumber: String = ""
    var comment: String = ""

    enum CodingKeys: String, CodingKey {
        case version, type, subtype, brand, diameter, weight, name, price, density, comment
        case protocol_ = "protocol"
        case colorHex = "color_hex"
        case minTemp = "min_temp"
        case maxTemp = "max_temp"
        case bedMinTemp = "bed_min_temp"
        case bedMaxTemp = "bed_max_temp"
        case spoolWeight = "spool_weight"
        case articleNumber = "article_number"
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
        name       = try c.decodeIfPresent(String.self, forKey: .name)       ?? ""
        price      = try c.decodeIfPresent(Double.self, forKey: .price)      ?? 0
        spoolWeight = try c.decodeIfPresent(Int.self,   forKey: .spoolWeight) ?? 0
        density    = try c.decodeIfPresent(Double.self, forKey: .density)    ?? 0
        articleNumber = try c.decodeIfPresent(String.self, forKey: .articleNumber) ?? ""
        comment    = try c.decodeIfPresent(String.self, forKey: .comment)    ?? ""

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
        if !name.isEmpty { try c.encode(name, forKey: .name) }
        if price > 0 { try c.encode(price, forKey: .price) }
        if spoolWeight > 0 { try c.encode(spoolWeight, forKey: .spoolWeight) }
        if density > 0 { try c.encode(density, forKey: .density) }
        if !articleNumber.isEmpty { try c.encode(articleNumber, forKey: .articleNumber) }
        if !comment.isEmpty { try c.encode(comment, forKey: .comment) }
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
            statusMessage = lz(en: "NFC not available on this device.", de: "NFC auf diesem Gerät nicht verfügbar.", fr: "NFC non disponible sur cet appareil.", es: "NFC no disponible en este dispositivo.", pt: "NFC não disponível neste dispositivo.", it: "NFC non disponibile su questo dispositivo.", zh: "此设备不支持 NFC。")
            showError = true; return
        }
        writeData = nil
        session = NFCNDEFReaderSession(delegate: self, queue: .main, invalidateAfterFirstRead: true)
        session?.alertMessage = lz(en: "Hold iPhone near the filament spool tag.", de: "iPhone an die Filament-Spule halten.", fr: "Approchez l'iPhone du tag de la bobine.", es: "Acerque el iPhone a la etiqueta del carrete.", pt: "Aproxime o iPhone da etiqueta da bobina de filamento.", it: "Avvicina l'iPhone al tag della bobina di filamento.", zh: "将 iPhone 靠近耗材料盘标签。")
        session?.begin()
        isScanning = true
    }

    func write(data: OpenSpoolData) {
        guard NFCNDEFReaderSession.readingAvailable else {
            statusMessage = lz(en: "NFC not available on this device.", de: "NFC auf diesem Gerät nicht verfügbar.", fr: "NFC non disponible sur cet appareil.", es: "NFC no disponible en este dispositivo.", pt: "NFC não disponível neste dispositivo.", it: "NFC non disponibile su questo dispositivo.", zh: "此设备不支持 NFC。")
            showError = true; return
        }
        writeData = data
        session = NFCNDEFReaderSession(delegate: self, queue: .main, invalidateAfterFirstRead: false)
        session?.alertMessage = lz(en: "Hold iPhone near an empty NFC tag to write.", de: "iPhone an ein leeres NFC-Tag halten.", fr: "Approchez l'iPhone d'un tag NFC vide.", es: "Acerque el iPhone a una etiqueta NFC vacía.", pt: "Aproxime o iPhone de uma etiqueta NFC vazia para gravar.", it: "Avvicina l'iPhone a un tag NFC vuoto per scrivere.", zh: "将 iPhone 靠近空白 NFC 标签以写入。")
        session?.begin()
        isScanning = true
    }

    func readerSessionDidBecomeActive(_ session: NFCNDEFReaderSession) {}

    func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        DispatchQueue.main.async { self.isScanning = false }
    }

    // Parse any supported record. Prefers OpenSpool JSON, then OpenPrintTag CBOR.
    private func parseRecord(_ record: NFCNDEFPayload) -> OpenSpoolData? {
        // OpenPrintTag: MIME "application/vnd.openprinttag" with CBOR payload.
        if let mime = String(data: record.type, encoding: .utf8),
           mime == OpenPrintTag.mimeType,
           let d = OpenPrintTag.parse(record.payload) {
            return d
        }
        return parseOpenSpool(from: record.payload)
    }

    private func parseOpenSpool(from payload: Data) -> OpenSpoolData? {
        // MIME record: payload is raw JSON
        if let d = try? JSONDecoder().decode(OpenSpoolData.self, from: payload),
           d.protocol_ == "openspool" { return d }
        // Some tags store OpenPrintTag CBOR in a generic record — try it too.
        if let d = OpenPrintTag.parse(payload) { return d }
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
                if let d = parseRecord(record) {
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
                guard error == nil else { session.invalidate(errorMessage: lz(en: "Connection failed.", de: "Verbindung fehlgeschlagen.", fr: "Connexion échouée.", es: "Conexión fallida.", pt: "Falha na conexão.", it: "Connessione non riuscita.", zh: "连接失败。")); return }
                tag.readNDEF { message, error in
                    guard let message = message else {
                        session.invalidate(errorMessage: error?.localizedDescription ?? lz(en: "Read failed.", de: "Lesen fehlgeschlagen.", fr: "Lecture échouée.", es: "Lectura fallida.", pt: "Falha na leitura.", it: "Lettura non riuscita.", zh: "读取失败。"))
                        return
                    }
                    for record in message.records {
                        if let d = self.parseRecord(record) {
                            session.alertMessage = lz(en: "Tag read successfully!", de: "Tag erfolgreich gelesen!", fr: "Tag lu avec succès !", es: "¡Tag leído con éxito!", pt: "Etiqueta lida com sucesso!", it: "Tag letto con successo!", zh: "标签读取成功！")
                            session.invalidate()
                            DispatchQueue.main.async { self.lastRead = d; self.isScanning = false }
                            return
                        }
                    }
                    session.invalidate(errorMessage: lz(en: "No OpenSpool data found.", de: "Keine OpenSpool-Daten gefunden.", fr: "Aucune donnée OpenSpool trouvée.", es: "No se encontraron datos OpenSpool.", pt: "Nenhum dado OpenSpool encontrado.", it: "Nessun dato OpenSpool trovato.", zh: "未找到 OpenSpool 数据。"))
                    DispatchQueue.main.async { self.isScanning = false }
                }
            }
            return
        }

        // Write mode
        guard let data = writeData else { session.invalidate(); return }
        session.connect(to: tag) { error in
            guard error == nil else { session.invalidate(errorMessage: lz(en: "Connection failed.", de: "Verbindung fehlgeschlagen.", fr: "Connexion échouée.", es: "Conexión fallida.", pt: "Falha na conexão.", it: "Connessione non riuscita.", zh: "连接失败。")); return }
            let dataCopy = data
            guard let jsonData = try? JSONEncoder().encode(dataCopy) else {
                session.invalidate(errorMessage: lz(en: "Encoding failed.", de: "Kodierung fehlgeschlagen.", fr: "Encodage échoué.", es: "Codificación fallida.", pt: "Falha na codificação.", it: "Codifica non riuscita.", zh: "编码失败。")); return
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
                    session.alertMessage = lz(en: "Tag written successfully!", de: "Tag erfolgreich beschrieben!", fr: "Tag écrit avec succès !", es: "¡Tag escrito con éxito!", pt: "Etiqueta gravada com sucesso!", it: "Tag scritto con successo!", zh: "标签写入成功！")
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
    let namePT: String
    let nameIT: String
    let nameZH: String
    let hex: String
    var color: Color { Color(hex: hex) ?? .gray }
    var name: String { lz(en: nameEN, de: nameDE, fr: nameFR, es: nameES, pt: namePT, it: nameIT, zh: nameZH) }

    static let all: [NFCColorOption] = [
        NFCColorOption(id: "red",      nameEN: "Red",      nameDE: "Rot",      nameFR: "Rouge",    nameES: "Rojo",      namePT: "Vermelho", nameIT: "Rosso",   nameZH: "红色", hex: "FF0000"),
        NFCColorOption(id: "orange",   nameEN: "Orange",   nameDE: "Orange",   nameFR: "Orange",   nameES: "Naranja",   namePT: "Laranja",  nameIT: "Arancione", nameZH: "橙色", hex: "FF8800"),
        NFCColorOption(id: "yellow",   nameEN: "Yellow",   nameDE: "Gelb",     nameFR: "Jaune",    nameES: "Amarillo",  namePT: "Amarelo",  nameIT: "Giallo",  nameZH: "黄色", hex: "FFD700"),
        NFCColorOption(id: "green",    nameEN: "Green",    nameDE: "Grün",     nameFR: "Vert",     nameES: "Verde",     namePT: "Verde",    nameIT: "Verde",   nameZH: "绿色", hex: "00AA00"),
        NFCColorOption(id: "cyan",     nameEN: "Cyan",     nameDE: "Cyan",     nameFR: "Cyan",     nameES: "Cian",      namePT: "Ciano",    nameIT: "Ciano",   nameZH: "青色", hex: "00CCCC"),
        NFCColorOption(id: "blue",     nameEN: "Blue",     nameDE: "Blau",     nameFR: "Bleu",     nameES: "Azul",      namePT: "Azul",     nameIT: "Blu",     nameZH: "蓝色", hex: "0066FF"),
        NFCColorOption(id: "purple",   nameEN: "Purple",   nameDE: "Lila",     nameFR: "Violet",   nameES: "Púrpura",   namePT: "Roxo",     nameIT: "Viola",   nameZH: "紫色", hex: "8800CC"),
        NFCColorOption(id: "magenta",  nameEN: "Magenta",  nameDE: "Magenta",  nameFR: "Magenta",  nameES: "Magenta",   namePT: "Magenta",  nameIT: "Magenta", nameZH: "品红", hex: "FF00FF"),
        NFCColorOption(id: "pink",     nameEN: "Pink",     nameDE: "Rosa",     nameFR: "Rose",     nameES: "Rosa",      namePT: "Rosa",     nameIT: "Rosa",    nameZH: "粉色", hex: "FF69B4"),
        NFCColorOption(id: "white",    nameEN: "White",    nameDE: "Weiß",     nameFR: "Blanc",    nameES: "Blanco",    namePT: "Branco",   nameIT: "Bianco",  nameZH: "白色", hex: "FFFFFF"),
        NFCColorOption(id: "black",    nameEN: "Black",    nameDE: "Schwarz",  nameFR: "Noir",     nameES: "Negro",     namePT: "Preto",    nameIT: "Nero",    nameZH: "黑色", hex: "222222"),
        NFCColorOption(id: "gray",     nameEN: "Gray",     nameDE: "Grau",     nameFR: "Gris",     nameES: "Gris",      namePT: "Cinza",    nameIT: "Grigio",  nameZH: "灰色", hex: "888888"),
        NFCColorOption(id: "brown",    nameEN: "Brown",    nameDE: "Braun",    nameFR: "Marron",   nameES: "Marrón",    namePT: "Marrom",   nameIT: "Marrone", nameZH: "棕色", hex: "8B4513"),
        NFCColorOption(id: "gold",     nameEN: "Gold",     nameDE: "Gold",     nameFR: "Or",       nameES: "Dorado",    namePT: "Dourado",  nameIT: "Oro",     nameZH: "金色", hex: "DAA520"),
        NFCColorOption(id: "silver",   nameEN: "Silver",   nameDE: "Silber",   nameFR: "Argent",   nameES: "Plata",     namePT: "Prata",    nameIT: "Argento", nameZH: "银色", hex: "C0C0C0"),
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
                                        Text(lz(en: "Read Tag", de: "Tag lesen", fr: "Lire tag", es: "Leer tag", pt: "Ler Etiqueta", it: "Leggi Tag", zh: "读取标签")).fontWeight(.semibold)
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
                                        Text(lz(en: "Write Tag", de: "Tag schreiben", fr: "Écrire tag", es: "Escribir tag", pt: "Gravar Etiqueta", it: "Scrivi Tag", zh: "写入标签")).fontWeight(.semibold)
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
                                    Text(lz(en: "Compatible tags: NTAG215, NTAG216. Hold your device near the spool tag to read or write.", de: "Kompatible Tags: NTAG215, NTAG216. Gerät an das Spulen-Tag halten.", fr: "Tags compatibles : NTAG215, NTAG216. Approchez l'appareil du tag.", es: "Tags compatibles: NTAG215, NTAG216. Acerque el dispositivo al tag.", pt: "Etiquetas compatíveis: NTAG215, NTAG216. Aproxime seu dispositivo da etiqueta da bobina para ler ou gravar.", it: "Tag compatibili: NTAG215, NTAG216. Avvicina il dispositivo al tag della bobina per leggere o scrivere.", zh: "兼容标签：NTAG215、NTAG216。将设备靠近料盘标签即可读取或写入。"))
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
                            Text(lz(en: "Color", de: "Farbe", fr: "Couleur", es: "Color", pt: "Cor", it: "Colore", zh: "颜色"))
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
                                ColorPicker(lz(en: "Pick color", de: "Farbe wählen", fr: "Choisir couleur", es: "Elegir color", pt: "Escolher cor", it: "Scegli colore", zh: "选择颜色"), selection: $customColor, supportsOpacity: false)
                                    .onChange(of: customColor) { spoolData.colorHex = customColor.hexString }
                                    .padding(.top, 4)
                            }
                        }

                        // Brand
                        VStack(alignment: .leading, spacing: 6) {
                            Text(lz(en: "Brand", de: "Marke", fr: "Marque", es: "Marca", pt: "Marca", it: "Marca", zh: "品牌"))
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
                            Text(lz(en: "Type", de: "Typ", fr: "Type", es: "Tipo", pt: "Tipo", it: "Tipo", zh: "类型"))
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
                            Text(lz(en: "Variant", de: "Variante", fr: "Variante", es: "Variante", pt: "Variante", it: "Variante", zh: "变体"))
                                .font(.caption).foregroundColor(.secondary)
                            Menu {
                                Button(action: { spoolData.subtype = "" }) {
                                    Label(lz(en: "None", de: "Keine", fr: "Aucune", es: "Ninguna", pt: "Nenhum", it: "Nessuno", zh: "无"),
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
                                         ? lz(en: "None", de: "Keine", fr: "Aucune", es: "Ninguna", pt: "Nenhum", it: "Nessuno", zh: "无")
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
                        Text(lz(en: "Nozzle Temperature", de: "Düsentemperatur", fr: "Température buse", es: "Temperatura boquilla", pt: "Temperatura do Bico", it: "Temperatura Ugello", zh: "喷嘴温度"))
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
                        Text(lz(en: "Bed Temperature", de: "Betttemperatur", fr: "Température du lit", es: "Temperatura cama", pt: "Temperatura da Mesa", it: "Temperatura del Piano", zh: "热床温度"))
                            .font(.caption).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Min")
                                    .font(.caption2).foregroundColor(.secondary)
                                Menu {
                                    Button(lz(en: "Not set", de: "Nicht gesetzt", fr: "Non défini", es: "No definido", pt: "Não definido", it: "Non impostato", zh: "未设置")) { spoolData.bedMinTemp = 0 }
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
                                    Button(lz(en: "Not set", de: "Nicht gesetzt", fr: "Non défini", es: "No definido", pt: "Não definido", it: "Non impostato", zh: "未设置")) { spoolData.bedMaxTemp = 0 }
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
                                    Text(lz(en: "Read Tag", de: "Tag lesen", fr: "Lire tag", es: "Leer tag", pt: "Ler Etiqueta", it: "Leggi Tag", zh: "读取标签"))
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
                                    Text(lz(en: "Write Tag", de: "Tag schreiben", fr: "Écrire tag", es: "Escribir tag", pt: "Gravar Etiqueta", it: "Scrivi Tag", zh: "写入标签"))
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
                        Text(lz(en: "Compatible tags: NTAG215, NTAG216. Hold your iPhone near the spool tag to read or write.", de: "Kompatible Tags: NTAG215, NTAG216. Halte dein iPhone an das Spulen-Tag zum Lesen oder Schreiben.", fr: "Tags compatibles : NTAG215, NTAG216. Approchez votre iPhone du tag pour lire ou écrire.", es: "Tags compatibles: NTAG215, NTAG216. Acerque el iPhone al tag para leer o escribir.", pt: "Etiquetas compatíveis: NTAG215, NTAG216. Aproxime o iPhone da etiqueta da bobina para ler ou gravar.", it: "Tag compatibili: NTAG215, NTAG216. Avvicina il tuo iPhone al tag della bobina per leggere o scrivere.", zh: "兼容标签：NTAG215、NTAG216。将 iPhone 靠近料盘标签即可读取或写入。"))
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
            .alert(lz(en: "Error", de: "Fehler", fr: "Erreur", es: "Error", pt: "Erro", it: "Errore", zh: "错误"), isPresented: $nfc.showError) {
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
                nfc.statusMessage = lz(en: "Tag read successfully", de: "Tag erfolgreich gelesen", fr: "Tag lu avec succès", es: "Tag leído con éxito", pt: "Etiqueta lida com sucesso", it: "Tag letto con successo", zh: "标签读取成功")
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
            Text(lz(en: "Color", de: "Farbe", fr: "Couleur", es: "Color", pt: "Cor", it: "Colore", zh: "颜色"))
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
                ColorPicker(lz(en: "Pick color", de: "Farbe wählen", fr: "Choisir couleur", es: "Elegir color", pt: "Escolher cor", it: "Scegli colore", zh: "选择颜色"), selection: $customColor, supportsOpacity: false)
                    .onChange(of: customColor) { spoolData.colorHex = customColor.hexString }
                    .padding(.top, 4)
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text(lz(en: "Brand", de: "Marke", fr: "Marque", es: "Marca", pt: "Marca", it: "Marca", zh: "品牌"))
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
            Text(lz(en: "Type", de: "Typ", fr: "Type", es: "Tipo", pt: "Tipo", it: "Tipo", zh: "类型"))
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
            Text(lz(en: "Variant", de: "Variante", fr: "Variante", es: "Variante", pt: "Variante", it: "Variante", zh: "变体"))
                .font(.caption).foregroundColor(.secondary)
            Menu {
                Button(action: { spoolData.subtype = "" }) {
                    Label(lz(en: "None", de: "Keine", fr: "Aucune", es: "Ninguna", pt: "Nenhum", it: "Nessuno", zh: "无"),
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
                    Text(spoolData.subtype.isEmpty ? lz(en: "None", de: "Keine", fr: "Aucune", es: "Ninguna", pt: "Nenhum", it: "Nessuno", zh: "无") : spoolData.subtype)
                        .foregroundColor(spoolData.subtype.isEmpty ? .secondary : .primary)
                    Spacer()
                    Image(systemName: "chevron.down").foregroundColor(.secondary).font(.caption)
                }
                .padding(12).background(Color(.secondarySystemBackground)).cornerRadius(10)
            }
        }
        Text(lz(en: "Nozzle Temperature", de: "Düsentemperatur", fr: "Température buse", es: "Temperatura boquilla", pt: "Temperatura do Bico", it: "Temperatura Ugello", zh: "喷嘴温度"))
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
        Text(lz(en: "Bed Temperature", de: "Betttemperatur", fr: "Température du lit", es: "Temperatura cama", pt: "Temperatura da Mesa", it: "Temperatura del Piano", zh: "热床温度"))
            .font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Min").font(.caption2).foregroundColor(.secondary)
                Menu {
                    Button(lz(en: "Not set", de: "Nicht gesetzt", fr: "Non défini", es: "No definido", pt: "Não definido", it: "Non impostato", zh: "未设置")) { spoolData.bedMinTemp = 0 }
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
                    Button(lz(en: "Not set", de: "Nicht gesetzt", fr: "Non défini", es: "No definido", pt: "Não definido", it: "Non impostato", zh: "未设置")) { spoolData.bedMaxTemp = 0 }
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
                        Text(lz(en: "Custom...", de: "Eigene...", fr: "Personnalisé...", es: "Personalizado...", pt: "Personalizado...", it: "Personalizzato...", zh: "自定义..."))
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
            .navigationTitle(lz(en: "Color", de: "Farbe", fr: "Couleur", es: "Color", pt: "Cor", it: "Colore", zh: "颜色"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lz(en: "Done", de: "Fertig", fr: "Terminé", es: "Listo", pt: "Concluído", it: "Fatto", zh: "完成")) { isPresented = false }
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
                    Text(lz(en: "Loading timelapse videos…", de: "Lade Timelapse-Videos…", fr: "Chargement des timelapse…", es: "Cargando timelapse…", pt: "Carregando vídeos timelapse…", it: "Caricamento video timelapse…", zh: "正在加载延时摄影视频…"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = loadError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40)).foregroundStyle(.orange)
                    Text(err).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button(lz(en: "Retry", de: "Erneut laden", fr: "Réessayer", es: "Reintentar", pt: "Repetir", it: "Riprova", zh: "重试")) {
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
                    Text(lz(en: "No timelapse videos found.\nStart a print to create one.", de: "Keine Timelapse-Videos vorhanden.\nStarte einen Druck, um eines zu erstellen.", fr: "Aucune vidéo timelapse trouvée.", es: "No se encontraron videos timelapse.", pt: "Nenhum vídeo timelapse encontrado.\nInicie uma impressão para criar um.", it: "Nessun video timelapse trovato.\nAvvia una stampa per crearne uno.", zh: "未找到延时摄影视频。\n开始一次打印即可创建。"))
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button(lz(en: "Refresh", de: "Aktualisieren", fr: "Actualiser", es: "Actualizar", pt: "Atualizar", it: "Aggiorna", zh: "刷新")) {
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
                await MainActor.run { isLoading = false; loadError = lz(en: "No response from server", de: "Keine Serverantwort", fr: "Pas de réponse du serveur", es: "Sin respuesta del servidor", pt: "Sem resposta do servidor", it: "Nessuna risposta dal server", zh: "服务器无响应") }
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
            await MainActor.run { isLoading = false; loadError = SpoolmanService.localizedTransport(error) }
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
