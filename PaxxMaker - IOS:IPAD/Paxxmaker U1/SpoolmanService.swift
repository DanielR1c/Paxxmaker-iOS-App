import Foundation

// MARK: - Spoolman API client
// Talks to a self-hosted Spoolman instance (https://github.com/Donkie/Spoolman)
// over its REST API (base `/api/v1`, default port 7912). Covers the full CRUD
// surface for spools, filaments and vendors plus the "use filament" endpoint.

enum SpoolmanError: LocalizedError {
    case notConfigured
    case badURL
    case http(Int, String)
    case transport(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:      return lz(en: "Spoolman URL not set", de: "Spoolman-Adresse nicht gesetzt", fr: "Adresse Spoolman non définie", es: "Dirección de Spoolman no configurada", pt: "Endereço do Spoolman não definido", it: "Indirizzo Spoolman non impostato", zh: "未设置 Spoolman 地址")
        case .badURL:             return lz(en: "Invalid Spoolman URL", de: "Ungültige Spoolman-Adresse", fr: "Adresse Spoolman invalide", es: "Dirección de Spoolman no válida", pt: "Endereço do Spoolman inválido", it: "Indirizzo Spoolman non valido", zh: "Spoolman 地址无效")
        case .http(let c, let m): return "HTTP \(c)\(m.isEmpty ? "" : ": \(m)")"
        case .transport(let m):   return m
        case .decoding(let m):    return m
        }
    }
}

// MARK: - Models

struct SpoolmanVendor: Codable, Identifiable, Hashable {
    var id: Int
    var name: String
    var comment: String?
    var empty_spool_weight: Double?
}

struct SpoolmanFilament: Codable, Identifiable, Hashable {
    var id: Int
    var name: String?
    var vendor: SpoolmanVendor?
    var material: String?
    var price: Double?
    var density: Double
    var diameter: Double
    var weight: Double?          // full-spool net weight (g)
    var spool_weight: Double?    // empty spool (g)
    var article_number: String?
    var comment: String?
    var settings_extruder_temp: Int?
    var settings_bed_temp: Int?
    var color_hex: String?
    var multi_color_hexes: String?

    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        let mat = material ?? "?"
        if let v = vendor?.name, !v.isEmpty { return "\(v) \(mat)" }
        return mat
    }

    // Row display in "name → material → vendor" order. rowTitle is the first
    // available of those; rowSubtitle lists the remaining ones (so a filament
    // with a name shows "material · vendor" beneath it).
    var rowTitle: String {
        if let n = name, !n.isEmpty { return n }
        if let m = material, !m.isEmpty { return m }
        return vendor?.name ?? "—"
    }
    var rowSubtitle: String {
        var parts: [String] = []
        if !(name ?? "").isEmpty, let m = material, !m.isEmpty { parts.append(m) }
        if let v = vendor?.name, !v.isEmpty { parts.append(v) }
        return parts.joined(separator: " · ")
    }
}

struct SpoolmanSpool: Codable, Identifiable, Hashable {
    var id: Int
    var filament: SpoolmanFilament
    var price: Double?
    var remaining_weight: Double?
    var initial_weight: Double?
    var spool_weight: Double?
    var used_weight: Double
    var remaining_length: Double?
    var used_length: Double
    var location: String?
    // Spoolman custom fields. spoollink stores the RFID card UID(s) of the
    // physical spool in "card_uids" — that is what makes an assignment follow
    // the spool when it is moved to another nozzle.
    var extra: [String: String]?
    var lot_nr: String?
    var comment: String?
    var archived: Bool
    var first_used: String?
    var last_used: String?

    // 0…1 remaining fraction, if we can compute it.
    var remainingFraction: Double? {
        guard let rem = remaining_weight else { return nil }
        let total = (initial_weight ?? filament.weight) ?? (rem + used_weight)
        guard total > 0 else { return nil }
        return max(0, min(1, rem / total))
    }
}

// MARK: - Service

struct SpoolmanService {
    let baseURL: URL

    /// Build from a user-entered host/IP. Accepts "192.168.1.5",
    /// "192.168.1.5:7912", "http://host", "https://host/spoolman". Falls back to
    /// port 7912 and appends the /api/v1 path when missing.
    init?(rawHost: String) {
        var s = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        guard var comps = URLComponents(string: s) else { return nil }
        if comps.port == nil, (comps.host?.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil) {
            comps.port = 7912   // only default the port for bare IPs
        }
        // Normalize the path so it ends at /api/v1 exactly once.
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/api/v1") { path += "/api/v1" }
        comps.path = path
        guard let url = comps.url else { return nil }
        self.baseURL = url
    }

    // System/URLSession error strings follow the DEVICE language, not the app's
    // in-app language override — so surfacing error.localizedDescription would
    // show e.g. German text in a Spanish UI. Map to our own lz() messages.
    static func localizedTransport(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .timedOut:
                return lz(en: "Connection timed out.", de: "Zeitüberschreitung der Verbindung.", fr: "Délai de connexion dépassé.", es: "Tiempo de conexión agotado.", pt: "Tempo de conexão esgotado.", it: "Timeout della connessione.", zh: "连接超时。")
            case .notConnectedToInternet:
                return lz(en: "No internet connection.", de: "Keine Internetverbindung.", fr: "Aucune connexion internet.", es: "Sin conexión a internet.", pt: "Sem conexão com a internet.", it: "Nessuna connessione internet.", zh: "无网络连接。")
            default:
                break
            }
        }
        return lz(en: "Could not connect to the server.", de: "Verbindung zum Server konnte nicht hergestellt werden.", fr: "Impossible de se connecter au serveur.", es: "No se pudo conectar al servidor.", pt: "Não foi possível conectar ao servidor.", it: "Impossibile connettersi al server.", zh: "无法连接到服务器。")
    }

    static var noHTTPMessage: String {
        lz(en: "No response from server.", de: "Keine Antwort vom Server.", fr: "Aucune réponse du serveur.", es: "Sin respuesta del servidor.", pt: "Sem resposta do servidor.", it: "Nessuna risposta dal server.", zh: "服务器无响应。")
    }

    static var decodeMessage: String {
        lz(en: "Unexpected server response.", de: "Unerwartete Server-Antwort.", fr: "Réponse du serveur inattendue.", es: "Respuesta inesperada del servidor.", pt: "Resposta inesperada do servidor.", it: "Risposta del server inattesa.", zh: "服务器响应异常。")
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        // NB: do NOT use URL.appendingPathComponent here — it percent-encodes the
        // whole string, turning a "?" query separator into "%3F" and making
        // "spool?allow_archived=false" a literal path segment → 404. Concatenate
        // the raw string instead so the query string stays intact.
        let url = URL(string: baseURL.absoluteString + "/" + path) ?? baseURL
        // 15 s: Spoolman often runs on a weak SBC (e.g. the printer host) whose
        // uvicorn can be slow on the first request after idle. The tab loads
        // lazily, so a generous timeout doesn't affect app launch.
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func run<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw SpoolmanError.transport(Self.localizedTransport(error)) }
        guard let http = resp as? HTTPURLResponse else { throw SpoolmanError.transport(Self.noHTTPMessage) }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw SpoolmanError.http(http.statusCode, String(msg))
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw SpoolmanError.decoding(Self.decodeMessage) }
    }

    private func runVoid(_ req: URLRequest) async throws {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw SpoolmanError.transport(Self.localizedTransport(error)) }
        guard let http = resp as? HTTPURLResponse else { throw SpoolmanError.transport(Self.noHTTPMessage) }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw SpoolmanError.http(http.statusCode, String(msg))
        }
    }

    // Reachability / version probe.
    func ping() async throws {
        // /info lives at /api/v1/info
        try await runVoid(request("info"))
    }

    // ── Spools ───────────────────────────────────────────────────────────────
    func spools(includeArchived: Bool = false) async throws -> [SpoolmanSpool] {
        try await run(request("spool?allow_archived=\(includeArchived ? "true" : "false")"), as: [SpoolmanSpool].self)
    }
    func createSpool(_ body: [String: Any]) async throws -> SpoolmanSpool {
        try await run(request("spool", method: "POST", body: try JSONSerialization.data(withJSONObject: body)), as: SpoolmanSpool.self)
    }
    func updateSpool(_ id: Int, _ body: [String: Any]) async throws -> SpoolmanSpool {
        try await run(request("spool/\(id)", method: "PATCH", body: try JSONSerialization.data(withJSONObject: body)), as: SpoolmanSpool.self)
    }
    func deleteSpool(_ id: Int) async throws {
        try await runVoid(request("spool/\(id)", method: "DELETE"))
    }
    /// Reduce a spool's remaining filament by weight (g) or length (mm).
    func useSpool(_ id: Int, useWeight: Double? = nil, useLength: Double? = nil) async throws -> SpoolmanSpool {
        var body: [String: Any] = [:]
        if let w = useWeight { body["use_weight"] = w }
        if let l = useLength { body["use_length"] = l }
        return try await run(request("spool/\(id)/use", method: "PUT", body: try JSONSerialization.data(withJSONObject: body)), as: SpoolmanSpool.self)
    }

    // ── Filaments ──────────────────────────────────────────────────────────────
    func filaments() async throws -> [SpoolmanFilament] {
        try await run(request("filament"), as: [SpoolmanFilament].self)
    }
    func createFilament(_ body: [String: Any]) async throws -> SpoolmanFilament {
        try await run(request("filament", method: "POST", body: try JSONSerialization.data(withJSONObject: body)), as: SpoolmanFilament.self)
    }
    func updateFilament(_ id: Int, _ body: [String: Any]) async throws -> SpoolmanFilament {
        try await run(request("filament/\(id)", method: "PATCH", body: try JSONSerialization.data(withJSONObject: body)), as: SpoolmanFilament.self)
    }
    func deleteFilament(_ id: Int) async throws {
        try await runVoid(request("filament/\(id)", method: "DELETE"))
    }

    // ── Vendors ────────────────────────────────────────────────────────────────
    func vendors() async throws -> [SpoolmanVendor] {
        try await run(request("vendor"), as: [SpoolmanVendor].self)
    }
    func createVendor(_ body: [String: Any]) async throws -> SpoolmanVendor {
        try await run(request("vendor", method: "POST", body: try JSONSerialization.data(withJSONObject: body)), as: SpoolmanVendor.self)
    }
    func updateVendor(_ id: Int, _ body: [String: Any]) async throws -> SpoolmanVendor {
        try await run(request("vendor/\(id)", method: "PATCH", body: try JSONSerialization.data(withJSONObject: body)), as: SpoolmanVendor.self)
    }
    func deleteVendor(_ id: Int) async throws {
        try await runVoid(request("vendor/\(id)", method: "DELETE"))
    }
}

// MARK: - Shared config (read from anywhere)
extension SpoolmanSpool {
    /// Card UIDs linked to this spool, upper-cased. Spoolman stores custom-field
    /// values JSON-encoded (e.g. "\"04A1…\""), and several UIDs may be listed.
    var cardUIDs: [String] {
        guard let raw = extra?["card_uids"], !raw.isEmpty else { return [] }
        var v = raw.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
        return v.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
    }
}

enum SpoolmanConfig {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "spoolman_enabled") }
    static var host: String { UserDefaults.standard.string(forKey: "spoolman_url") ?? "" }
    static var service: SpoolmanService? {
        guard isEnabled else { return nil }
        return SpoolmanService(rawHost: host)
    }
}
