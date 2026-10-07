import SwiftUI
import AuthenticationServices
import Security
import Combine
import WebKit

// MARK: - Model libraries (Thingiverse, MyMiniFactory)
//
// Search a model site and put an STL straight onto the plate. Every user signs
// in with their own account: both sites support OAuth's implicit grant, where
// the app never holds a secret — only the public client id below — and the
// user types their password on the site's own login page, never into the app.
// The token lands in the iOS keychain.
//
// Downloaded files stay for a while under "Recently loaded" (Caches, so iOS
// may clear them when space is short; the app itself drops them after 30
// days) and open again without another download.
//
// The only part of PaxxMaker that talks to the internet — and only while
// this screen is used.

enum LibrarySource: String, CaseIterable, Identifiable, Codable {
    case thingiverse, myminifactory
    var id: String { rawValue }

    var title: String {
        switch self {
        case .thingiverse: return "Thingiverse"
        case .myminifactory: return "MyMiniFactory"
        }
    }

    /// Public client id of the app registered on the site — not a secret.
    /// Empty = the source is not set up and not offered.
    var clientID: String {
        switch self {
        case .thingiverse: return LibraryConfig.thingiverseClientID
        case .myminifactory: return LibraryConfig.myMiniFactoryClientID
        }
    }

    var isConfigured: Bool { !clientID.isEmpty }

    /// Where the site sends the user back after signing in. Has to be
    /// registered exactly like this in the app settings on the site.
    var redirectURI: String { "paxxmaker://oauth/\(rawValue)" }

    var signUpURL: URL {
        switch self {
        case .thingiverse: return URL(string: "https://www.thingiverse.com/register")!
        case .myminifactory: return URL(string: "https://www.myminifactory.com/signup")!
        }
    }

    func authorizeURL(state: String) -> URL {
        var c: URLComponents
        switch self {
        case .thingiverse: c = URLComponents(string: "https://www.thingiverse.com/login/oauth/authorize")!
        case .myminifactory: c = URLComponents(string: "https://auth.myminifactory.com/web/authorize")!
        }
        c.queryItems = [URLQueryItem(name: "client_id", value: clientID),
                        URLQueryItem(name: "redirect_uri", value: redirectURI),
                        URLQueryItem(name: "response_type", value: "token"),
                        URLQueryItem(name: "state", value: state)]
        return c.url!
    }
}

/// The ids from the developer pages of the two sites. Fill in after
/// registering the app there (redirect URIs: see `LibrarySource.redirectURI`).
enum LibraryConfig {
    static let thingiverseClientID = "fe00e18ce8755e2e21fe"
    static let myMiniFactoryClientID = ""
    /// MyMiniFactory's "mobile login" turns the 10-minute token of a phone
    /// sign-in into a 2-hour one that can be refreshed; it asks for the
    /// client key of the registered app. Empty = sign in again when it runs out.
    static let myMiniFactoryClientKey = ""

    static var sources: [LibrarySource] { LibrarySource.allCases.filter(\.isConfigured) }

    /// Shown in the app when a source is set up — and always in a debug build,
    /// so the screens can be looked at before the ids exist.
    static var entryVisible: Bool {
        #if DEBUG
        return true
        #else
        return !sources.isEmpty
        #endif
    }
}

// MARK: - Sign-in and tokens

struct LibraryToken: Codable {
    var accessToken: String
    var expires: Date?
    var isExpired: Bool { expires.map { $0 < Date().addingTimeInterval(60) } ?? false }
}

enum Keychain {
    private static let service = "PaxxMaker.Library"

    static func save(_ data: Data, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// Where the sign-in sheet appears: the app's key window.
final class AuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first.map { UIWindow(windowScene: $0) } ?? UIWindow()
        }
    }
}

@MainActor
final class LibraryAccounts: ObservableObject {
    static let shared = LibraryAccounts()
    @Published private(set) var tokens: [LibrarySource: LibraryToken] = [:]

    private init() {
        for s in LibrarySource.allCases {
            if let d = Keychain.load(account: s.rawValue), let t = try? JSONDecoder().decode(LibraryToken.self, from: d) { tokens[s] = t }
        }
    }

    func isSignedIn(_ s: LibrarySource) -> Bool { tokens[s] != nil }

    func signOut(_ s: LibrarySource) {
        tokens[s] = nil
        Keychain.delete(account: s.rawValue)
    }

    private func store(_ t: LibraryToken, for s: LibrarySource) {
        tokens[s] = t
        if let d = try? JSONEncoder().encode(t) { Keychain.save(d, account: s.rawValue) }
    }

    /// The site's own login page in the system sheet; the token comes back in
    /// the fragment of the redirect (implicit grant — no secret in the app).
    /// Thingiverse does not use this — see `WebSignInView`.
    func signIn(_ s: LibrarySource) async throws {
        let state = UUID().uuidString
        defer { authSession = nil }
        let callback = try await runAuth(s.authorizeURL(state: state))
        try await accept(s, callback: callback, state: state)
    }

    /// Takes the token out of the redirect back to `paxxmaker://oauth/…`.
    func accept(_ s: LibrarySource, callback: URL, state: String) async throws {
        let fields = Self.fragment(callback)
        if let e = fields["error"] { throw LibraryError.signIn(e) }
        guard fields["state"] == state else { throw LibraryError.signIn("state") }
        guard let token = fields["access_token"], !token.isEmpty else { throw LibraryError.signIn("no token") }
        var t = LibraryToken(accessToken: token,
                             expires: fields["expires_in"].flatMap(Double.init).map { Date().addingTimeInterval($0) })
        if s == .myminifactory, let longer = await Self.mmfMobileLogin(token) { t = longer }
        store(t, for: s)
    }

    private var authSession: ASWebAuthenticationSession?
    private let presenter = AuthPresenter()

    private func runAuth(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "paxxmaker") { url, error in
                if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: error ?? ASWebAuthenticationSessionError(.canceledLogin)) }
            }
            session.presentationContextProvider = presenter
            session.prefersEphemeralWebBrowserSession = false
            authSession = session
            if !session.start() {
                authSession = nil
                cont.resume(throwing: LibraryError.signIn("start"))
            }
        }
    }

    /// The user gave up waiting: close the sheet (if any) and stop.
    func cancelSignIn() {
        authSession?.cancel()
    }

    /// A valid token, refreshed where the site allows it; nil = sign in again.
    func token(for s: LibrarySource) async -> String? {
        guard let t = tokens[s] else { return nil }
        if !t.isExpired { return t.accessToken }
        if s == .myminifactory, let fresh = await Self.mmfRefresh(t.accessToken) { store(fresh, for: s); return fresh.accessToken }
        signOut(s)
        return nil
    }

    /// The site said the token is no good (401): forget it.
    func invalidate(_ s: LibrarySource) { signOut(s) }

    private static func fragment(_ url: URL) -> [String: String] {
        let raw = url.fragment ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.query ?? ""
        var out: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
        }
        return out
    }

    private static var deviceInfo: String {
        let d = UIDevice.current
        let info: [String: String] = ["device_id": d.identifierForVendor?.uuidString ?? "unknown",
                                      "manufacturer": "Apple", "device_model": d.model,
                                      "locale": Locale.current.identifier, "user_agent": "PaxxMaker"]
        return (try? JSONSerialization.data(withJSONObject: info)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func mmfPost(_ path: String, _ fields: [String: String]) async -> LibraryToken? {
        guard !LibraryConfig.myMiniFactoryClientKey.isEmpty,
              let url = URL(string: "https://auth.myminifactory.com" + path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents(); c.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = c.percentEncodedQuery?.data(using: .utf8)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tok = j["access_token"] as? String else { return nil }
        let exp = (j["expires_in"] as? NSNumber)?.doubleValue
        return LibraryToken(accessToken: tok, expires: exp.map { Date().addingTimeInterval($0) })
    }

    private static func mmfMobileLogin(_ token: String) async -> LibraryToken? {
        await mmfPost("/v1/oauth/mobile/login", ["client_key": LibraryConfig.myMiniFactoryClientKey,
                                                 "access_token": token, "device_info": deviceInfo])
    }

    private static func mmfRefresh(_ token: String) async -> LibraryToken? {
        await mmfPost("/v1/oauth/mobile/refresh", ["client_key": LibraryConfig.myMiniFactoryClientKey,
                                                   "access_token": token,
                                                   "device_id": UIDevice.current.identifierForVendor?.uuidString ?? "unknown"])
    }
}

enum LibraryError: LocalizedError {
    case signIn(String), signedOut, http(Int), noFiles, tooBig

    var errorDescription: String? {
        switch self {
        case .signIn: return lz(en: "Signing in did not work. Please try again.", de: "Die Anmeldung hat nicht geklappt. Bitte noch einmal versuchen.", fr: "La connexion a échoué. Réessaie.", es: "No se pudo iniciar sesión. Inténtalo de nuevo.", pt: "O login não funcionou. Tente novamente.", it: "Accesso non riuscito. Riprova.", zh: "登录失败，请重试。")
        case .signedOut: return lz(en: "The sign-in has expired — please sign in again.", de: "Die Anmeldung ist abgelaufen — bitte neu anmelden.", fr: "La connexion a expiré — reconnecte-toi.", es: "La sesión ha caducado: vuelve a iniciar sesión.", pt: "O login expirou — entre novamente.", it: "L'accesso è scaduto — accedi di nuovo.", zh: "登录已过期——请重新登录。")
        case .http(let c): return lz(en: "The site did not answer as expected (HTTP \(c)).", de: "Die Seite hat nicht wie erwartet geantwortet (HTTP \(c)).", fr: "Le site n'a pas répondu comme prévu (HTTP \(c)).", es: "El sitio no respondió como se esperaba (HTTP \(c)).", pt: "O site não respondeu como esperado (HTTP \(c)).", it: "Il sito non ha risposto come previsto (HTTP \(c)).", zh: "网站未按预期响应（HTTP \(c)）。")
        case .noFiles: return lz(en: "This model has no STL file to print.", de: "Dieses Modell hat keine STL-Datei zum Drucken.", fr: "Ce modèle n'a pas de fichier STL.", es: "Este modelo no tiene archivo STL.", pt: "Este modelo não tem arquivo STL.", it: "Questo modello non ha file STL.", zh: "此模型没有可打印的 STL 文件。")
        case .tooBig: return lz(en: "The file is too large for the phone (over 200 MB).", de: "Die Datei ist zu groß für das iPhone (über 200 MB).", fr: "Le fichier est trop volumineux (plus de 200 Mo).", es: "El archivo es demasiado grande (más de 200 MB).", pt: "O arquivo é grande demais (mais de 200 MB).", it: "Il file è troppo grande (oltre 200 MB).", zh: "文件过大（超过 200 MB）。")
        }
    }
}

// MARK: - What the sites return, in one shape

struct LibraryItem: Identifiable, Hashable {
    let source: LibrarySource
    let remoteID: Int
    let name: String
    let creator: String
    let thumbnail: URL?
    let likes: Int
    let page: URL?
    var id: String { "\(source.rawValue)-\(remoteID)" }
}

struct LibraryDetail {
    var images: [URL]
    var license: String
    var description: String
}

struct LibraryFile: Identifiable, Hashable {
    let id: Int
    let name: String
    let bytes: Int
    let download: URL?
    let thumbnail: URL?
    var isSTL: Bool { name.lowercased().hasSuffix(".stl") }
}

// MARK: - Thingiverse sorting, time range, categories
//
// Values as the API takes them (checked against api.thingiverse.com):
// sort = relevant | popular | likes | downloads | makes | newest,
// posted_after = now-7d …, category_id = the site's own category ids.

enum ThingSort: String, CaseIterable, Identifiable {
    case relevant, popular, likes, downloads, makes, newest
    var id: String { rawValue }
    var usesPeriod: Bool { self != .relevant && self != .newest }
    var title: String {
        switch self {
        case .relevant: return lz(en: "Best match", de: "Relevanz", fr: "Pertinence", es: "Relevancia", pt: "Relevância", it: "Pertinenza", zh: "相关度")
        case .popular: return lz(en: "Popular", de: "Beliebt", fr: "Populaires", es: "Populares", pt: "Populares", it: "Popolari", zh: "热门")
        case .likes: return lz(en: "Most likes", de: "Meiste Likes", fr: "Plus aimés", es: "Más me gusta", pt: "Mais curtidos", it: "Più apprezzati", zh: "最多点赞")
        case .downloads: return lz(en: "Most downloads", de: "Meiste Downloads", fr: "Plus téléchargés", es: "Más descargas", pt: "Mais downloads", it: "Più scaricati", zh: "最多下载")
        case .makes: return lz(en: "Most makes", de: "Meiste Makes", fr: "Plus imprimés", es: "Más impresos", pt: "Mais impressos", it: "Più stampati", zh: "最多打印")
        case .newest: return lz(en: "Newest", de: "Neueste", fr: "Plus récents", es: "Más recientes", pt: "Mais recentes", it: "Più recenti", zh: "最新")
        }
    }
    var icon: String {
        switch self {
        case .relevant: return "text.magnifyingglass"
        case .popular: return "flame"
        case .likes: return "heart"
        case .downloads: return "arrow.down.circle"
        case .makes: return "printer"
        case .newest: return "clock"
        }
    }
}

enum ThingPeriod: String, CaseIterable, Identifiable {
    case all, week, month, year
    var id: String { rawValue }
    var postedAfter: String? {
        switch self {
        case .all: return nil
        case .week: return "now-7d"
        case .month: return "now-30d"
        case .year: return "now-365d"
        }
    }
    var title: String {
        switch self {
        case .all: return lz(en: "All time", de: "Gesamter Zeitraum", fr: "Depuis toujours", es: "Siempre", pt: "Todo o período", it: "Sempre", zh: "全部时间")
        case .week: return lz(en: "Last 7 days", de: "Letzte 7 Tage", fr: "7 derniers jours", es: "Últimos 7 días", pt: "Últimos 7 dias", it: "Ultimi 7 giorni", zh: "最近 7 天")
        case .month: return lz(en: "Last 30 days", de: "Letzte 30 Tage", fr: "30 derniers jours", es: "Últimos 30 días", pt: "Últimos 30 dias", it: "Ultimi 30 giorni", zh: "最近 30 天")
        case .year: return lz(en: "Last year", de: "Letztes Jahr", fr: "Dernière année", es: "Último año", pt: "Último ano", it: "Ultimo anno", zh: "最近一年")
        }
    }
}

nonisolated struct ThingFilter: Equatable {
    var sort: ThingSort = .relevant
    var period: ThingPeriod = .all
    var category: Int = 0          // 0 = all categories
    /// "Best match" needs a search term; without one it lists what is popular.
    func effectiveSort(query: String) -> ThingSort {
        sort == .relevant && query.trimmingCharacters(in: .whitespaces).isEmpty ? .popular : sort
    }
}

/// Thingiverse's categories with the site's ids. Sub-categories keep the
/// site's English names; the main groups are translated.
enum ThingCategories {
    struct Group: Identifiable { let id: Int; let title: String; let icon: String; let subs: [(id: Int, name: String)] }

    static var groups: [Group] { [
        Group(id: 73, title: lz(en: "3D Printing", de: "3D-Druck", fr: "Impression 3D", es: "Impresión 3D", pt: "Impressão 3D", it: "Stampa 3D", zh: "3D 打印"), icon: "cube",
              subs: [(127, "3D Printer Accessories"), (152, "3D Printer Extruders"), (128, "3D Printer Parts"), (126, "3D Printers"), (129, "3D Printing Tests")]),
        Group(id: 63, title: lz(en: "Art", de: "Kunst", fr: "Art", es: "Arte", pt: "Arte", it: "Arte", zh: "艺术"), icon: "paintbrush",
              subs: [(144, "2D Art"), (75, "Art Tools"), (143, "Coins & Badges"), (78, "Interactive Art"), (79, "Math Art"), (145, "Scans & Replicas"), (80, "Sculptures"), (76, "Signs & Logos")]),
        Group(id: 64, title: lz(en: "Fashion", de: "Mode", fr: "Mode", es: "Moda", pt: "Moda", it: "Moda", zh: "时尚"), icon: "eyeglasses",
              subs: [(81, "Accessories"), (82, "Bracelets"), (142, "Costume"), (139, "Earrings"), (83, "Glasses"), (84, "Jewelry"), (130, "Keychains"), (85, "Rings")]),
        Group(id: 65, title: lz(en: "Gadgets", de: "Gadgets", fr: "Gadgets", es: "Gadgets", pt: "Gadgets", it: "Gadget", zh: "小工具"), icon: "iphone",
              subs: [(141, "Audio"), (86, "Camera"), (87, "Computer"), (88, "Mobile Phone"), (90, "Tablet"), (91, "Video Games")]),
        Group(id: 66, title: lz(en: "Hobby", de: "Hobby", fr: "Loisirs", es: "Hobby", pt: "Hobby", it: "Hobby", zh: "爱好"), icon: "guitars",
              subs: [(155, "Automotive"), (93, "DIY"), (92, "Electronics"), (94, "Music"), (95, "R/C Vehicles"), (96, "Robotics"), (140, "Sport & Outdoors")]),
        Group(id: 67, title: lz(en: "Household", de: "Haushalt", fr: "Maison", es: "Hogar", pt: "Casa", it: "Casa", zh: "家居"), icon: "house",
              subs: [(147, "Bathroom"), (146, "Containers"), (97, "Decor"), (99, "Household Supplies"), (100, "Kitchen & Dining"), (101, "Office"), (102, "Organization"), (98, "Outdoor & Garden"), (103, "Pets"), (153, "Replacement Parts")]),
        Group(id: 69, title: lz(en: "Learning", de: "Lernen", fr: "Apprentissage", es: "Aprendizaje", pt: "Aprendizado", it: "Apprendimento", zh: "学习"), icon: "graduationcap",
              subs: [(106, "Biology"), (104, "Engineering"), (105, "Math"), (148, "Physics & Astronomy")]),
        Group(id: 70, title: lz(en: "Models", de: "Modelle", fr: "Modèles", es: "Modelos", pt: "Modelos", it: "Modelli", zh: "模型"), icon: "figure.stand",
              subs: [(107, "Animals"), (108, "Buildings & Structures"), (109, "Creatures"), (110, "Food & Drink"), (111, "Model Furniture"), (115, "Model Robots"), (112, "People"), (114, "Props"), (116, "Vehicles")]),
        Group(id: 71, title: lz(en: "Tools", de: "Werkzeuge", fr: "Outils", es: "Herramientas", pt: "Ferramentas", it: "Utensili", zh: "工具"), icon: "wrench.and.screwdriver",
              subs: [(118, "Hand Tools"), (117, "Machine Tools"), (120, "Tool Holders & Boxes"), (119, "Parts")]),
        Group(id: 72, title: lz(en: "Toys & Games", de: "Spielzeug & Spiele", fr: "Jouets & jeux", es: "Juguetes y juegos", pt: "Brinquedos e jogos", it: "Giochi", zh: "玩具与游戏"), icon: "puzzlepiece",
              subs: [(151, "Chess"), (121, "Construction Toys"), (122, "Dice"), (123, "Games"), (124, "Mechanical Toys"), (113, "Playsets"), (125, "Puzzles"), (149, "Toy & Game Accessories")]),
    ] }

    static var allTitle: String { lz(en: "All categories", de: "Alle Kategorien", fr: "Toutes les catégories", es: "Todas las categorías", pt: "Todas as categorias", it: "Tutte le categorie", zh: "全部分类") }

    static func name(_ id: Int) -> String {
        if id <= 0 { return allTitle }
        for g in groups {
            if g.id == id { return g.title }
            if let s = g.subs.first(where: { $0.id == id }) { return s.name }
        }
        return allTitle
    }
}

@MainActor
enum LibraryAPI {
    private static func get(_ s: LibrarySource, _ url: URL) async throws -> Any {
        guard let token = await LibraryAccounts.shared.token(for: s) else { throw LibraryError.signedOut }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { LibraryAccounts.shared.invalidate(s); throw LibraryError.signedOut }
        guard (200..<300).contains(code) else { throw LibraryError.http(code) }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func str(_ v: Any?) -> String { (v as? String) ?? ((v as? NSNumber)?.stringValue ?? "") }
    private static func int(_ v: Any?) -> Int { (v as? Int) ?? Int(str(v)) ?? 0 }
    private static func url(_ v: Any?) -> URL? { (v as? String).flatMap(URL.init(string:)) }

    /// Empty query = browse (by default what is popular), so there is
    /// something to see. `filter` is Thingiverse only.
    static func search(_ s: LibrarySource, query: String, page: Int, filter: ThingFilter = ThingFilter()) async throws -> (items: [LibraryItem], more: Bool) {
        let q = query.trimmingCharacters(in: .whitespaces)
        switch s {
        case .thingiverse:
            // An empty term works too (tested): /search/?sort=… lists everything.
            let term = q.isEmpty ? "" : (q.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? q) + "/"
            var c = URLComponents(string: "https://api.thingiverse.com/search/" + term)!
            let sort = filter.effectiveSort(query: q)
            c.queryItems = [URLQueryItem(name: "type", value: "things"), URLQueryItem(name: "sort", value: sort.rawValue),
                            URLQueryItem(name: "page", value: "\(page)"), URLQueryItem(name: "per_page", value: "30")]
            if sort.usesPeriod, let after = filter.period.postedAfter { c.queryItems!.append(URLQueryItem(name: "posted_after", value: after)) }
            if filter.category > 0 { c.queryItems!.append(URLQueryItem(name: "category_id", value: "\(filter.category)")) }
            let j = try await get(s, c.url!)
            // Newer answers: { total, hits: [...] }; older ones a plain list.
            let hits = ((j as? [String: Any])?["hits"] as? [[String: Any]]) ?? (j as? [[String: Any]]) ?? []
            let total = int((j as? [String: Any])?["total"])
            let items = hits.map { h in
                LibraryItem(source: s, remoteID: int(h["id"]), name: str(h["name"]),
                            creator: str((h["creator"] as? [String: Any])?["name"]),
                            thumbnail: url(h["thumbnail"]) ?? url(h["preview_image"]),
                            likes: int(h["like_count"]), page: url(h["public_url"]))
            }
            return (items, total > 0 ? page * 30 < total : hits.count == 30)
        case .myminifactory:
            var c = URLComponents(string: "https://www.myminifactory.com/api/v2/search")!
            c.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "page", value: "\(page)"),
                            URLQueryItem(name: "per_page", value: "30"),
                            URLQueryItem(name: "sort", value: q.isEmpty ? "popularity" : "visits")]
            let j = try await get(s, c.url!) as? [String: Any] ?? [:]
            let list = j["items"] as? [[String: Any]] ?? []
            let items = list.map { o -> LibraryItem in
                let imgs = o["images"] as? [[String: Any]] ?? []
                let img = imgs.first { ($0["is_primary"] as? Bool) == true } ?? imgs.first
                let thumb = url((img?["thumbnail"] as? [String: Any])?["url"]) ?? url((img?["standard"] as? [String: Any])?["url"])
                let d = o["designer"] as? [String: Any]
                return LibraryItem(source: s, remoteID: int(o["id"]), name: str(o["name"]),
                                   creator: str(d?["name"]).isEmpty ? str(d?["username"]) : str(d?["name"]),
                                   thumbnail: thumb, likes: int(o["likes"]), page: url(o["url"]))
            }
            return (items, page * 30 < int(j["total_count"]))
        }
    }

    static func detail(_ item: LibraryItem) async throws -> LibraryDetail {
        switch item.source {
        case .thingiverse:
            let j = try await get(item.source, URL(string: "https://api.thingiverse.com/things/\(item.remoteID)")!) as? [String: Any] ?? [:]
            var images: [URL] = []
            if let d = j["default_image"] as? [String: Any], let sizes = d["sizes"] as? [[String: Any]] {
                let large = sizes.first { str($0["type"]) == "display" && str($0["size"]) == "large" } ?? sizes.last
                if let u = url(large?["url"]) { images.append(u) }
            }
            if images.isEmpty, let u = item.thumbnail { images.append(u) }
            return LibraryDetail(images: images, license: str(j["license"]), description: str(j["description"]))
        case .myminifactory:
            let j = try await get(item.source, URL(string: "https://www.myminifactory.com/api/v2/objects/\(item.remoteID)")!) as? [String: Any] ?? [:]
            let imgs = (j["images"] as? [[String: Any]] ?? []).compactMap { url(($0["standard"] as? [String: Any])?["url"]) }
            return LibraryDetail(images: imgs.isEmpty ? [item.thumbnail].compactMap { $0 } : imgs,
                                 license: str(j["license"]), description: str(j["description"]))
        }
    }

    static func files(_ item: LibraryItem) async throws -> [LibraryFile] {
        switch item.source {
        case .thingiverse:
            let j = try await get(item.source, URL(string: "https://api.thingiverse.com/things/\(item.remoteID)/files")!)
            let list = (j as? [[String: Any]]) ?? ((j as? [String: Any])?["files"] as? [[String: Any]]) ?? []
            return list.map { f in
                LibraryFile(id: int(f["id"]), name: str(f["name"]), bytes: int(f["size"]),
                            download: url(f["download_url"]) ?? URL(string: "https://api.thingiverse.com/files/\(int(f["id"]))/download"),
                            thumbnail: url(f["thumbnail"]))
            }.filter(\.isSTL)
        case .myminifactory:
            let j = try await get(item.source, URL(string: "https://www.myminifactory.com/api/v2/objects/\(item.remoteID)/files")!) as? [String: Any] ?? [:]
            return (j["items"] as? [[String: Any]] ?? []).map { f in
                LibraryFile(id: int(f["id"]), name: str(f["filename"]), bytes: int(f["size"]),
                            download: url(f["download_url"]), thumbnail: url(f["thumbnail_url"]))
            }.filter(\.isSTL)
        }
    }

    /// Fetches the file into the cache (or takes it from there) and returns
    /// the local copy.
    static func download(_ file: LibraryFile, of item: LibraryItem) async throws -> URL {
        if let cached = LibraryCache.shared.fileURL(item: item, file: file) { return cached }
        guard file.bytes < 200_000_000 else { throw LibraryError.tooBig }
        guard let src = file.download else { throw LibraryError.noFiles }
        guard let token = await LibraryAccounts.shared.token(for: item.source) else { throw LibraryError.signedOut }
        var req = URLRequest(url: src, timeoutInterval: 120)
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { LibraryAccounts.shared.invalidate(item.source); throw LibraryError.signedOut }
        guard (200..<300).contains(code) else { throw LibraryError.http(code) }
        return try LibraryCache.shared.store(tmp, item: item, file: file)
    }
}

// MARK: - Recently loaded (temporary)

struct CachedModel: Codable, Identifiable {
    var id: String            // source-fileid
    var source: LibrarySource
    var itemID: Int
    var fileID: Int
    var name: String          // file name
    var title: String         // model title on the site
    var creator: String
    var page: URL?
    var thumbnail: URL?
    var loaded: Date
    var path: String          // relative to the cache folder
}

@MainActor
final class LibraryCache: ObservableObject {
    static let shared = LibraryCache()
    @Published private(set) var entries: [CachedModel] = []

    private let root: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PaxxMakerLibrary", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    private var indexURL: URL { root.appendingPathComponent("index.json") }

    private init() {
        if let d = try? Data(contentsOf: indexURL), let e = try? JSONDecoder().decode([CachedModel].self, from: d) { entries = e }
        prune()
    }

    private func save() { try? JSONEncoder().encode(entries).write(to: indexURL, options: .atomic) }

    /// Older than 30 days, or the file is gone (iOS cleared the cache).
    func prune() {
        let limit = Date().addingTimeInterval(-30 * 86_400)
        for e in entries where e.loaded < limit { try? FileManager.default.removeItem(at: root.appendingPathComponent(e.path).deletingLastPathComponent()) }
        entries = entries.filter { $0.loaded >= limit && FileManager.default.fileExists(atPath: root.appendingPathComponent($0.path).path) }
            .sorted { $0.loaded > $1.loaded }
        save()
    }

    func url(of e: CachedModel) -> URL { root.appendingPathComponent(e.path) }

    func fileURL(item: LibraryItem, file: LibraryFile) -> URL? {
        guard let e = entries.first(where: { $0.id == "\(item.source.rawValue)-\(file.id)" }) else { return nil }
        let u = url(of: e)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func store(_ tmp: URL, item: LibraryItem, file: LibraryFile) throws -> URL {
        let key = "\(item.source.rawValue)-\(file.id)"
        let folder = root.appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Its own file name, so the model on the plate is called what the
        // designer called it.
        let safe = file.name.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "_")
        let dest = folder.appendingPathComponent(safe.isEmpty ? "model.stl" : safe)
        try FileManager.default.moveItem(at: tmp, to: dest)
        entries.removeAll { $0.id == key }
        entries.insert(CachedModel(id: key, source: item.source, itemID: item.remoteID, fileID: file.id, name: file.name,
                                   title: item.name, creator: item.creator, page: item.page, thumbnail: item.thumbnail,
                                   loaded: Date(), path: key + "/" + dest.lastPathComponent), at: 0)
        if entries.count > 60 { for e in entries.suffix(from: 60) { remove(e) } }
        save()
        return dest
    }

    func remove(_ e: CachedModel) {
        try? FileManager.default.removeItem(at: url(of: e).deletingLastPathComponent())
        entries.removeAll { $0.id == e.id }
        save()
    }
}

// MARK: - Screens

/// Search, sign-in and "recently loaded" in one place. `onPlate` gets the
/// local STL once the user picks a file.
struct LibraryView: View {
    var onPlate: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("app_language") private var appLanguage: String = "en"
    @AppStorage("library_source") private var sourceRaw: String = LibrarySource.thingiverse.rawValue
    @ObservedObject private var accounts = LibraryAccounts.shared
    @ObservedObject private var cache = LibraryCache.shared

    @State private var query = ""
    @State private var items: [LibraryItem] = []
    @State private var page = 1
    @State private var more = false
    @State private var loading = false
    @State private var error: String? = nil
    @State private var signingIn = false
    @State private var webSignIn: WebSignIn? = nil
    @AppStorage("tv_sort") private var sortRaw: String = ThingSort.relevant.rawValue
    @AppStorage("tv_period") private var periodRaw: String = ThingPeriod.all.rawValue
    @AppStorage("tv_category") private var category: Int = 0
    @State private var searchTask: Task<Void, Never>? = nil

    private var sources: [LibrarySource] {
        let s = LibraryConfig.sources
        return s.isEmpty ? LibrarySource.allCases : s
    }
    private var source: LibrarySource { LibrarySource(rawValue: sourceRaw).flatMap { sources.contains($0) ? $0 : nil } ?? sources[0] }

    var body: some View {
        NavigationStack {
            Group {
                if !accounts.isSignedIn(source) { signInCard } else { browser }
            }
            .navigationTitle(lz(en: "Find models", de: "Modelle suchen", fr: "Trouver des modèles", es: "Buscar modelos", pt: "Procurar modelos", it: "Cerca modelli", zh: "查找模型"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lz(en: "Close", de: "Schließen", fr: "Fermer", es: "Cerrar", pt: "Fechar", it: "Chiudi", zh: "关闭")) { dismiss() }
                }
                if accounts.isSignedIn(source) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(role: .destructive) {
                                accounts.signOut(source); items = []
                            } label: {
                                Label(lz(en: "Sign out of \(source.title)", de: "Von \(source.title) abmelden", fr: "Se déconnecter de \(source.title)", es: "Cerrar sesión en \(source.title)", pt: "Sair do \(source.title)", it: "Esci da \(source.title)", zh: "退出 \(source.title)"), systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        } label: { Image(systemName: "person.crop.circle") }
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                if sources.count > 1 {
                    Picker("", selection: $sourceRaw) {
                        ForEach(sources) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal).padding(.vertical, 6)
                    .background(.bar)
                }
            }
            .onChange(of: sourceRaw) { _, _ in items = []; page = 1; runSearch() }
            .sheet(item: $webSignIn) { w in
                WebSignInView(sign: w) { callback in
                    webSignIn = nil
                    signingIn = true
                    Task {
                        defer { signingIn = false }
                        do {
                            try await accounts.accept(w.source, callback: callback, state: w.state)
                            runSearch()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
            }
            .alert(lz(en: "Model library", de: "Modellbibliothek", fr: "Bibliothèque", es: "Biblioteca", pt: "Biblioteca", it: "Libreria", zh: "模型库"),
                   isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    // MARK: sign-in

    private var signInCard: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "shippingbox.and.arrow.backward").font(.system(size: 46)).foregroundColor(.accentColor).padding(.top, 30)
                Text(lz(en: "Sign in to \(source.title)", de: "Bei \(source.title) anmelden", fr: "Connexion à \(source.title)", es: "Iniciar sesión en \(source.title)", pt: "Entrar no \(source.title)", it: "Accedi a \(source.title)", zh: "登录 \(source.title)"))
                    .font(.title3.bold())
                Text(lz(en: "Search models and put them straight onto the plate. Sign-in required.",
                        de: "Modelle suchen und direkt auf die Druckplatte legen. Anmeldung erforderlich.",
                        fr: "Cherche des modèles et pose-les directement sur le plateau. Connexion requise.",
                        es: "Busca modelos y ponlos directamente en la placa. Inicio de sesión necesario.",
                        pt: "Procure modelos e coloque-os direto na mesa. Login necessário.",
                        it: "Cerca modelli e mettili direttamente sul piano. Accesso richiesto.",
                        zh: "搜索模型并直接放到打印板上。需要登录。"))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 26)
                Button {
                    signIn()
                } label: {
                    HStack {
                        if signingIn { ProgressView().tint(.white) }
                        Text(lz(en: "Sign in", de: "Anmelden", fr: "Se connecter", es: "Iniciar sesión", pt: "Entrar", it: "Accedi", zh: "登录"))
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: 280).padding(.vertical, 13)
                }
                .buttonStyle(.borderedProminent)
                .disabled(signingIn || !source.isConfigured)
                if signingIn {
                    Button(lz(en: "Cancel sign-in", de: "Anmeldung abbrechen", fr: "Annuler la connexion", es: "Cancelar inicio de sesión", pt: "Cancelar login", it: "Annulla accesso", zh: "取消登录")) {
                        accounts.cancelSignIn()
                        signingIn = false
                    }
                    .font(.footnote)
                }
                if !source.isConfigured {
                    Text("Client-ID fehlt: LibraryConfig in ModelLibrary.swift (nur im Debug-Build sichtbar)")
                        .font(.caption2).foregroundColor(.orange).multilineTextAlignment(.center).padding(.horizontal)
                }
                Link(lz(en: "No account yet? Create one for free", de: "Noch kein Konto? Kostenlos erstellen", fr: "Pas encore de compte ? Crée-en un gratuitement", es: "¿Sin cuenta? Créala gratis", pt: "Sem conta? Crie uma grátis", it: "Nessun account? Creane uno gratis", zh: "还没有账号？免费注册"),
                     destination: source.signUpURL)
                    .font(.footnote)
                if !cache.entries.isEmpty {
                    recentList.padding(.top, 10)
                }
            }
            .padding(.bottom, 30)
        }
    }

    private func signIn() {
        if source == .thingiverse {
            let state = UUID().uuidString
            webSignIn = WebSignIn(source: source, state: state, url: source.authorizeURL(state: state))
            return
        }
        signingIn = true
        Task {
            defer { signingIn = false }
            do {
                try await accounts.signIn(source)
                runSearch()
            } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
                // Closed by the user — nothing to report.
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: browsing

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    private var filter: ThingFilter {
        ThingFilter(sort: ThingSort(rawValue: sortRaw) ?? .relevant,
                    period: ThingPeriod(rawValue: periodRaw) ?? .all,
                    category: category)
    }

    private var browser: some View {
        ScrollView {
            if source == .thingiverse { filterBar }
            if query.isEmpty && !cache.entries.isEmpty && filter == ThingFilter() { recentList }
            HStack {
                Text(source == .thingiverse
                     ? filter.effectiveSort(query: query).title + (category > 0 ? " · " + ThingCategories.name(category) : "")
                     : (query.isEmpty
                        ? lz(en: "Popular", de: "Beliebt", fr: "Populaires", es: "Populares", pt: "Populares", it: "Popolari", zh: "热门")
                        : lz(en: "Results", de: "Ergebnisse", fr: "Résultats", es: "Resultados", pt: "Resultados", it: "Risultati", zh: "结果")))
                    .font(.headline).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal).padding(.top, 8)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(items) { item in
                    NavigationLink {
                        LibraryItemView(item: item, onPlate: { url in onPlate(url); dismiss() })
                    } label: {
                        LibraryCard(item: item)
                    }
                    .buttonStyle(.plain)
                    .onAppear { if item.id == items.last?.id, more, !loading { loadPage(page + 1) } }
                }
            }
            .padding(.horizontal)
            if loading { ProgressView().padding() }
            if !loading && items.isEmpty && !query.isEmpty {
                Text(lz(en: "Nothing found.", de: "Nichts gefunden.", fr: "Aucun résultat.", es: "Sin resultados.", pt: "Nada encontrado.", it: "Nessun risultato.", zh: "未找到。"))
                    .foregroundStyle(.secondary).padding(.top, 40)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: lz(en: "Search \(source.title)", de: "\(source.title) durchsuchen", fr: "Chercher sur \(source.title)", es: "Buscar en \(source.title)", pt: "Buscar no \(source.title)", it: "Cerca su \(source.title)", zh: "搜索 \(source.title)"))
        .onChange(of: query) { _, _ in runSearch(debounce: true) }
        .onChange(of: sortRaw) { _, _ in runSearch() }
        .onChange(of: periodRaw) { _, _ in runSearch() }
        .onChange(of: category) { _, _ in runSearch() }
        .task { if items.isEmpty { runSearch() } }
        .scrollDismissesKeyboard(.interactively)
    }

    /// Typing waits a moment before asking — one request per pause, not
    /// per letter.
    private func runSearch(debounce: Bool = false) {
        searchTask?.cancel()
        searchTask = Task {
            if debounce { try? await Task.sleep(nanoseconds: 450_000_000) }
            guard !Task.isCancelled else { return }
            items = []; page = 1
            loadPage(1)
        }
    }

    private func loadPage(_ p: Int) {
        guard accounts.isSignedIn(source) else { return }
        loading = true
        let s = source, q = query, f = filter
        Task {
            defer { loading = false }
            do {
                let r = try await LibraryAPI.search(s, query: q, page: p, filter: f)
                guard s == source, q == query, f == filter else { return }       // answer to an old question
                let known = Set(items.map(\.id))
                items += r.items.filter { !known.contains($0.id) }
                page = p; more = r.more
            } catch {
                if s == source { self.error = error.localizedDescription }
            }
        }
    }

    // MARK: sort / time range / category (Thingiverse)

    private var filterBar: some View {
        let f = filter
        let sort = f.effectiveSort(query: query)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("", selection: $sortRaw) {
                        ForEach(ThingSort.allCases.filter { $0 != .relevant || !query.isEmpty }) { s in
                            Label(s.title, systemImage: s.icon).tag(s.rawValue)
                        }
                    }
                } label: {
                    FilterChip(title: sort.title, icon: sort.icon, active: sort != (query.isEmpty ? .popular : .relevant))
                }
                if sort.usesPeriod {
                    Menu {
                        Picker("", selection: $periodRaw) {
                            ForEach(ThingPeriod.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                    } label: {
                        FilterChip(title: f.period.title, icon: "calendar", active: f.period != .all)
                    }
                }
                Menu {
                    Button { category = 0 } label: {
                        if category == 0 { Label(ThingCategories.allTitle, systemImage: "checkmark") } else { Text(ThingCategories.allTitle) }
                    }
                    ForEach(ThingCategories.groups) { g in
                        Menu {
                            categoryButton(g.id, lz(en: "All of \(g.title)", de: "Alles aus \(g.title)", fr: "Tout : \(g.title)", es: "Todo: \(g.title)", pt: "Tudo: \(g.title)", it: "Tutto: \(g.title)", zh: "全部\(g.title)"))
                            Divider()
                            ForEach(g.subs, id: \.id) { sub in categoryButton(sub.id, sub.name) }
                        } label: {
                            Label(g.title, systemImage: g.icon)
                        }
                    }
                } label: {
                    FilterChip(title: ThingCategories.name(category), icon: "square.grid.2x2", active: category > 0)
                }
                if f != ThingFilter() {
                    Button {
                        sortRaw = ThingSort.relevant.rawValue; periodRaw = ThingPeriod.all.rawValue; category = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(lz(en: "Reset filters", de: "Filter zurücksetzen", fr: "Réinitialiser les filtres", es: "Restablecer filtros", pt: "Redefinir filtros", it: "Reimposta filtri", zh: "重置筛选"))
                }
            }
            .padding(.horizontal).padding(.vertical, 6)
        }
    }

    @ViewBuilder private func categoryButton(_ id: Int, _ title: String) -> some View {
        Button { category = id } label: {
            if category == id { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    // MARK: recently loaded

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(lz(en: "Recently loaded", de: "Zuletzt geladen", fr: "Récemment chargés", es: "Cargados recientemente", pt: "Carregados recentemente", it: "Caricati di recente", zh: "最近下载"))
                .font(.headline).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(cache.entries) { e in
                        Button { onPlate(cache.url(of: e)); dismiss() } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                thumb(e.thumbnail).frame(width: 110, height: 110).clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(e.name).font(.caption2.weight(.semibold)).lineLimit(1)
                                Text(e.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 110)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if let page = e.page { Link(destination: page) { Label(lz(en: "Open website", de: "Webseite öffnen", fr: "Ouvrir le site", es: "Abrir sitio", pt: "Abrir site", it: "Apri sito", zh: "打开网页"), systemImage: "safari") } }
                            Button(role: .destructive) { cache.remove(e) } label: {
                                Label(lz(en: "Remove", de: "Entfernen", fr: "Retirer", es: "Quitar", pt: "Remover", it: "Rimuovi", zh: "移除"), systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
            Text(lz(en: "Kept on the phone for 30 days — opens again without downloading. Long-press to remove.",
                    de: "Bleibt 30 Tage auf dem iPhone — öffnet ohne erneuten Download. Lange drücken zum Entfernen.",
                    fr: "Conservé 30 jours sur le téléphone — s'ouvre sans nouveau téléchargement. Appui long pour retirer.",
                    es: "Se guarda 30 días en el teléfono: se abre sin volver a descargar. Mantén pulsado para quitar.",
                    pt: "Fica 30 dias no telefone — abre sem novo download. Pressione e segure para remover.",
                    it: "Resta 30 giorni sul telefono — si apre senza riscaricare. Tieni premuto per rimuovere.",
                    zh: "在手机上保留 30 天——无需重新下载即可打开。长按可移除。"))
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal)
        }
    }
}

@ViewBuilder
private func thumb(_ url: URL?) -> some View {
    AsyncImage(url: url) { phase in
        switch phase {
        case .success(let img): img.resizable().scaledToFill()
        default: ZStack { Color.secondary.opacity(0.15); Image(systemName: "cube").foregroundStyle(.secondary) }
        }
    }
}

private struct FilterChip: View {
    let title: String
    let icon: String
    let active: Bool
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.footnote)
            Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .foregroundStyle(active ? Color.white : Color.primary)
        .background(Capsule().fill(active ? Color.accentColor : Color(.secondarySystemFill)))
    }
}

private struct LibraryCard: View {
    let item: LibraryItem
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A fixed square the picture fills — a filled picture on its own
            // takes its natural width and pushes the grid column apart.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { thumb(item.thumbnail) }
                .clipShape(RoundedRectangle(cornerRadius: 14))
            Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
            HStack(spacing: 4) {
                Text(item.creator).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "heart.fill").font(.caption2)
                Text("\(item.likes)").monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// One model: pictures, licence, the STL files; a tap loads a file onto the plate.
struct LibraryItemView: View {
    let item: LibraryItem
    var onPlate: (URL) -> Void
    @AppStorage("app_language") private var appLanguage: String = "en"
    @ObservedObject private var cache = LibraryCache.shared
    @State private var detail: LibraryDetail? = nil
    @State private var files: [LibraryFile]? = nil
    @State private var busy: Int? = nil
    @State private var error: String? = nil

    var body: some View {
        List {
            Section {
                TabView {
                    ForEach((detail?.images ?? [item.thumbnail].compactMap { $0 }), id: \.self) { u in
                        Color.clear.overlay { thumb(u) }.clipped()
                    }
                }
                .tabViewStyle(.page)
                .frame(height: 260)
                .listRowInsets(EdgeInsets())
            }
            Section {
                Text(item.name).font(.headline)
                LabeledContent(lz(en: "By", de: "Von", fr: "Par", es: "De", pt: "Por", it: "Di", zh: "作者"), value: item.creator)
                if let l = detail?.license, !l.isEmpty {
                    LabeledContent(lz(en: "License", de: "Lizenz", fr: "Licence", es: "Licencia", pt: "Licença", it: "Licenza", zh: "许可"), value: l)
                }
                if let page = item.page {
                    Link(destination: page) {
                        Label(lz(en: "View on \(item.source.title)", de: "Auf \(item.source.title) ansehen", fr: "Voir sur \(item.source.title)", es: "Ver en \(item.source.title)", pt: "Ver no \(item.source.title)", it: "Vedi su \(item.source.title)", zh: "在 \(item.source.title) 上查看"), systemImage: "safari")
                    }
                }
            } footer: {
                Text(lz(en: "Respect the designer's licence — for Creative Commons models, credit them when you share a print.",
                        de: "Bitte die Lizenz des Erstellers beachten — bei Creative-Commons-Modellen ihn nennen, wenn du einen Druck teilst.",
                        fr: "Respecte la licence du créateur — pour les modèles Creative Commons, cite-le quand tu partages une impression.",
                        es: "Respeta la licencia del autor: con modelos Creative Commons, cítalo al compartir una impresión.",
                        pt: "Respeite a licença do criador — em modelos Creative Commons, dê o crédito ao compartilhar uma impressão.",
                        it: "Rispetta la licenza dell'autore — per i modelli Creative Commons, citalo quando condividi una stampa.",
                        zh: "请遵守作者的许可——对于知识共享（CC）模型，分享打印作品时请注明作者。"))
            }
            Section {
                if let files {
                    if files.isEmpty {
                        Text(LibraryError.noFiles.localizedDescription).foregroundStyle(.secondary)
                    }
                    ForEach(files) { f in
                        Button { load(f) } label: {
                            HStack(spacing: 12) {
                                thumb(f.thumbnail).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(f.name).lineLimit(2).foregroundStyle(Color.primary)
                                    if f.bytes > 0 {
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(f.bytes), countStyle: .file))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if busy == f.id { ProgressView() }
                                else if cache.fileURL(item: item, file: f) != nil {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                } else {
                                    Image(systemName: "arrow.down.to.line.circle").foregroundColor(.accentColor)
                                }
                            }
                        }
                        .disabled(busy != nil)
                    }
                } else {
                    HStack { ProgressView(); Text(lz(en: "Loading files…", de: "Dateien werden geladen…", fr: "Chargement des fichiers…", es: "Cargando archivos…", pt: "Carregando arquivos…", it: "Caricamento file…", zh: "正在加载文件…")).foregroundStyle(.secondary) }
                }
            } header: {
                Text(lz(en: "STL files", de: "STL-Dateien", fr: "Fichiers STL", es: "Archivos STL", pt: "Arquivos STL", it: "File STL", zh: "STL 文件"))
            } footer: {
                Text(lz(en: "Tap a file to download it and place it on the print plate.", de: "Tippe auf eine Datei, um sie zu laden und auf die Druckplatte zu legen.", fr: "Touche un fichier pour le télécharger et le poser sur le plateau.", es: "Toca un archivo para descargarlo y colocarlo en la placa.", pt: "Toque num arquivo para baixá-lo e colocá-lo na mesa.", it: "Tocca un file per scaricarlo e metterlo sul piano.", zh: "点击文件即可下载并放到打印板上。"))
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            async let d = try? LibraryAPI.detail(item)
            do { files = try await LibraryAPI.files(item) } catch { files = []; self.error = error.localizedDescription }
            detail = await d
        }
        .alert(item.source.title, isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func load(_ f: LibraryFile) {
        busy = f.id
        Task {
            defer { busy = nil }
            do { onPlate(try await LibraryAPI.download(f, of: item)) }
            catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Sign-in inside the app (Thingiverse)
//
// Thingiverse signs in with a link sent by mail. In the system sign-in sheet
// that cannot work: the link opens in Safari and the login made there never
// reaches the sheet. So the site runs in a web view inside the app, and the
// user pastes the link from the mail into that same web view. The login page
// still is Thingiverse's own; the app only watches for the redirect back to
// paxxmaker://oauth/… and takes the token from it. Nothing is stored beyond
// the sheet (non-persistent website data).

struct WebSignIn: Identifiable {
    let id = UUID()
    let source: LibrarySource
    let state: String
    let url: URL
}

@MainActor
final class WebSignInModel: NSObject, ObservableObject, WKNavigationDelegate {
    let view: WKWebView
    @Published var loading = false
    /// A mail link was pasted: offer "Continue" by hand as well.
    @Published var pastedLink = false
    /// On the "Authorize PaxxMaker" page — the paste bar is not needed there.
    @Published var onAuthorizePage = false
    /// A sign-in link was asked for (or the user went to the mail app and
    /// came back): only now is the paste bar shown.
    @Published var linkRequested = false
    private var start: URL?
    private var urlWatch: NSKeyValueObservation?
    private var onCallback: ((URL) -> Void)?
    private var afterMailLink = false
    private var done = false

    override init() {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .nonPersistent()
        let hero = UIImage(named: "AuthorizeHero")?.jpegData(compressionQuality: 0.85)
            .map { "data:image/jpeg;base64," + $0.base64EncodedString() } ?? ""
        c.userContentController.addUserScript(WKUserScript(source: Self.authorizePageStyle.replacingOccurrences(of: "__PXM_HERO__", with: hero),
                                                           injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        c.userContentController.addUserScript(WKUserScript(source: Self.linkRequestWatch, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let relay = ScriptRelay()
        c.userContentController.add(relay, name: "pxmLink")
        view = WKWebView(frame: .zero, configuration: c)
        super.init()
        relay.onMessage = { [weak self] in self?.linkRequested = true }
        view.navigationDelegate = self
        // The site is a single-page app: after the mail link it checks the
        // link in the page itself and then moves on without a new page load,
        // so watch the address instead of waiting for didFinish.
        urlWatch = view.observe(\.url, options: [.new]) { [weak self] v, _ in
            let url = v.url
            Task { @MainActor [weak self] in self?.urlChanged(url) }
        }
    }

    func begin(_ url: URL, onCallback: @escaping (URL) -> Void) {
        guard start == nil else { return }
        start = url
        self.onCallback = onCallback
        view.load(URLRequest(url: url))
    }

    /// The link from the mail, opened here so the login lands in this view.
    func openMailLink(_ url: URL) {
        afterMailLink = true
        pastedLink = true
        view.load(URLRequest(url: url))
    }

    /// Back to the "Authorize PaxxMaker" page.
    func goAuthorize() {
        afterMailLink = false
        if let start { view.load(URLRequest(url: start)) }
    }

    /// Signed in by the mail link once the site lands on one of its normal
    /// pages — then back to "Authorize".
    private func urlChanged(_ url: URL?) {
        onAuthorizePage = url?.path.lowercased().contains("oauth/authorize") == true
        guard afterMailLink, let url, url.host?.lowercased().hasSuffix("thingiverse.com") == true else { return }
        let path = url.path.lowercased()
        if path.contains("oauth") { afterMailLink = false; return }
        let landed = path.isEmpty || path == "/" || ["/dashboard", "/explore", "/for-you", "/home"].contains { path.hasPrefix($0) }
        guard landed else { return }
        afterMailLink = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            self.goAuthorize()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        if url.scheme == "paxxmaker" {
            decisionHandler(.cancel)
            if !done { done = true; onCallback?(url) }
            return
        }
        // Links meant for a new window stay in this one.
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request); decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loading = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loading = false }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }

    /// Notices that a sign-in link was requested without knowing the page:
    /// whatever the button is called or wherever it sits, the user sends the
    /// form while a field holds an e-mail address — a submit, a click on
    /// anything button-like, or Return in that field.
    private static let linkRequestWatch = #"""
    (function () {
      function hasMail() {
        var f = document.querySelectorAll('input');
        for (var i = 0; i < f.length; i++) {
          var e = f[i], v = (e.value || '').trim();
          var mailish = e.type === 'email' || /mail/i.test((e.name || '') + (e.id || '') + (e.autocomplete || '') + (e.placeholder || ''));
          if (mailish && /.+@.+\..+/.test(v)) return true;
        }
        return false;
      }
      function tell() { if (hasMail()) try { window.webkit.messageHandlers.pxmLink.postMessage('link'); } catch (e) {} }
      document.addEventListener('submit', tell, true);
      document.addEventListener('click', function (ev) {
        var t = ev.target && ev.target.closest ? ev.target.closest('button,[role=button],input[type=submit],a') : null;
        if (t) tell();
      }, true);
      document.addEventListener('keydown', function (ev) { if (ev.key === 'Enter') tell(); }, true);
    })();
    """#

    /// Thingiverse's "Authorize" page is an old desktop page without mobile
    /// styling (tiny serif text, a big empty picture box). Only on that page:
    /// system font, readable sizes, a proper button, light/dark like the app.
    private static let authorizePageStyle = #"""
    (function () {
      if (!/oauth\/authorize/i.test(location.pathname) || document.getElementById('pxm-style')) return;
      var vp = document.querySelector('meta[name=viewport]');
      if (!vp) { vp = document.createElement('meta'); vp.name = 'viewport'; document.head.appendChild(vp); }
      vp.content = 'width=device-width, initial-scale=1, maximum-scale=1';
      var st = document.createElement('style');
      st.id = 'pxm-style';
      st.textContent = [
        ':root{color-scheme:light dark}',
        'html,body{background:#fff!important;color:#1c1c1e!important}',
        'body{font-family:-apple-system,system-ui,sans-serif!important;font-size:17px!important;line-height:1.45!important;margin:0 auto!important;padding:28px 22px 40px!important;max-width:560px!important;-webkit-text-size-adjust:100%}',
        'body *{font-family:inherit!important;max-width:100%!important}',
        'h1,h2,h3{font-size:26px!important;font-weight:700!important;line-height:1.2!important;margin:0 0 18px!important}',
        'p,li,div,span{font-size:17px!important}',
        'b,strong{font-weight:600!important}',
        'ul{padding-left:22px!important;margin:8px 0 18px!important}',
        'li{margin:6px 0!important}',
        'a{color:#007aff!important}',
        '.pxm-primary{display:block!important;width:100%!important;box-sizing:border-box!important;background:#007aff!important;color:#fff!important;border:0!important;border-radius:14px!important;padding:16px!important;font-size:18px!important;font-weight:600!important;text-align:center!important;margin:26px 0 8px!important;text-decoration:none!important;-webkit-appearance:none!important;box-shadow:none!important}',
        '.pxm-secondary{display:block!important;width:100%!important;text-align:center!important;font-size:17px!important;padding:12px!important;margin:0 0 18px!important;text-decoration:none!important;background:none!important;border:0!important}',
        '.pxm-hero{display:block!important;width:180px!important;height:180px!important;object-fit:cover!important;border-radius:42px!important;margin:6px auto 26px!important;box-shadow:0 8px 24px rgba(0,0,0,.18)!important}',
        '.pxm-small,.pxm-small *{font-size:13px!important;text-align:center!important;display:block!important;opacity:.7}',
        '@media (prefers-color-scheme:dark){html,body{background:#000!important;color:#f2f2f7!important}a{color:#0a84ff!important}.pxm-primary{background:#0a84ff!important}}'
      ].join('\n');
      document.head.appendChild(st);
      var all = Array.prototype.slice.call(document.body.querySelectorAll('*'));
      all.forEach(function (e) {
        var t = (e.innerText || e.value || '').trim();
        // Empty picture boxes (the app has no cover image on the site).
        if (!t && !e.querySelector('input,button,a') && e.getBoundingClientRect().height > 80) e.style.display = 'none';
        if (/^agree\s*&\s*authorize/i.test(t) && /^(A|BUTTON|INPUT)$/.test(e.tagName)) e.classList.add('pxm-primary');
        else if (/^cancel$/i.test(t) && /^(A|BUTTON|INPUT)$/.test(e.tagName)) e.classList.add('pxm-secondary');
        else if (/^(update privacy preferences|terms of content use)$/i.test(t) && e.tagName === 'A') e.classList.add('pxm-small');
      });
      document.querySelectorAll('img').forEach(function (i) { if (!i.closest('.pxm-primary')) i.style.display = 'none'; });
      // The PaxxMaker picture in place of the site's empty box.
      var hero = '__PXM_HERO__';
      var h = Array.prototype.slice.call(document.querySelectorAll('h1,h2,h3')).filter(function (e) { return /authorize/i.test(e.textContent); })[0];
      if (hero && h) {
        var im = document.createElement('img');
        im.src = hero; im.alt = 'PaxxMaker'; im.className = 'pxm-hero';
        h.parentNode.insertBefore(im, h);
      }
    })();
    """#
}

/// Script messages without the content controller holding the model forever.
private final class ScriptRelay: NSObject, WKScriptMessageHandler {
    var onMessage: () -> Void = {}
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        DispatchQueue.main.async { self.onMessage() }
    }
}

private struct WebSignInWebView: UIViewRepresentable {
    let model: WebSignInModel
    func makeUIView(context: Context) -> WKWebView { model.view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct WebSignInView: View {
    let sign: WebSignIn
    var onCallback: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var web = WebSignInModel()
    @State private var noLink = false
    @State private var keyboardUp = false
    @State private var leftApp = false

    var body: some View {
        NavigationStack {
            WebSignInWebView(model: web)
                // Only once a link is on its way, and not over the keyboard.
                .safeAreaInset(edge: .bottom) {
                    if !web.onAuthorizePage && !keyboardUp {
                        if web.linkRequested { pasteBar } else { howToBar }
                    }
                }
                .navigationTitle(sign.source.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消")) { dismiss() }
                    }
                    if web.loading {
                        ToolbarItem(placement: .topBarTrailing) { ProgressView() }
                    }
                }
                .alert(lz(en: "No link copied", de: "Kein Link kopiert", fr: "Aucun lien copié", es: "No hay enlace copiado", pt: "Nenhum link copiado", it: "Nessun link copiato", zh: "未复制链接"),
                       isPresented: $noLink) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(lz(en: "In the mail from Thingiverse, press and hold the sign-in link and choose “Copy Link”, then come back here.",
                            de: "Halte in der Mail von Thingiverse den Anmeldelink gedrückt, wähle „Link kopieren“ und komm dann hierher zurück.",
                            fr: "Dans l'e-mail de Thingiverse, maintiens le lien de connexion appuyé, choisis « Copier le lien », puis reviens ici.",
                            es: "En el correo de Thingiverse, mantén pulsado el enlace de acceso, elige «Copiar enlace» y vuelve aquí.",
                            pt: "No e-mail do Thingiverse, mantenha o link de login pressionado, escolha “Copiar link” e volte aqui.",
                            it: "Nell'e-mail di Thingiverse tieni premuto il link di accesso, scegli “Copia link” e torna qui.",
                            zh: "在 Thingiverse 的邮件中长按登录链接，选择“拷贝链接”，然后回到这里。"))
                }
        }
        .onAppear { web.begin(sign.url, onCallback: onCallback) }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        // Went to the mail app and came back: the link is probably copied.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in leftApp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if leftApp { web.linkRequested = true }
        }
    }

    /// For first-timers, before a link was asked for: the whole way in one
    /// glance — without naming the site's buttons, which may change.
    private var howToBar: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "envelope.badge").font(.title3).foregroundColor(.accentColor)
            Text(lz(en: "Enter your e-mail and request the sign-in link. In the mail, press and hold the link → “Copy Link”, then come back here and paste it.",
                    de: "E-Mail eingeben und Anmeldelink anfordern. In der Mail den Link gedrückt halten → „Link kopieren“, zurück in die App und einfügen.",
                    fr: "Saisis ton e-mail et demande le lien de connexion. Dans l'e-mail, maintiens le lien → « Copier le lien », reviens ici et colle-le.",
                    es: "Introduce tu correo y pide el enlace de acceso. En el correo, mantén pulsado el enlace → «Copiar enlace», vuelve aquí y pégalo.",
                    pt: "Digite seu e-mail e peça o link de login. No e-mail, mantenha o link pressionado → “Copiar link”, volte aqui e cole.",
                    it: "Inserisci l'e-mail e richiedi il link di accesso. Nell'e-mail tieni premuto il link → “Copia link”, torna qui e incollalo.",
                    zh: "输入邮箱并获取登录链接。在邮件中长按链接 →“拷贝链接”，回到这里粘贴。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var pasteBar: some View {
        VStack(spacing: 6) {
            Button {
                if let url = Self.copiedLink() { web.openMailLink(url) } else { noLink = true }
            } label: {
                Label(lz(en: "Paste link from mail", de: "Link aus der Mail einfügen", fr: "Coller le lien de l'e-mail", es: "Pegar enlace del correo", pt: "Colar link do e-mail", it: "Incolla il link dell'e-mail", zh: "粘贴邮件中的链接"),
                      systemImage: "doc.on.clipboard")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: 320)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            Text(web.pastedLink
                 ? lz(en: "Nothing happening?", de: "Geht es nicht weiter?", fr: "Rien ne se passe ?", es: "¿No avanza?", pt: "Nada acontece?", it: "Non succede nulla?", zh: "没有反应？")
                 : lz(en: "In the mail: press and hold the link → “Copy Link”", de: "In der Mail: Link gedrückt halten → „Link kopieren“", fr: "Dans l'e-mail : maintiens le lien → « Copier le lien »", es: "En el correo: mantén pulsado el enlace → «Copiar enlace»", pt: "No e-mail: mantenha o link pressionado → “Copiar link”", it: "Nell'e-mail: tieni premuto il link → “Copia link”", zh: "在邮件中：长按链接 →“拷贝链接”"))
                .font(.caption2).foregroundStyle(.secondary)
            if web.pastedLink {
                Button(lz(en: "Continue to “Authorize”", de: "Weiter zu „Authorize“", fr: "Continuer vers « Authorize »", es: "Continuar a «Authorize»", pt: "Continuar para “Authorize”", it: "Continua su “Authorize”", zh: "继续到“Authorize”")) {
                    web.goAuthorize()
                }
                .font(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private static func copiedLink() -> URL? {
        let pb = UIPasteboard.general
        if let u = pb.url, ["http", "https"].contains(u.scheme?.lowercased() ?? "") { return u }
        guard let text = pb.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              let u = URL(string: text), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return nil }
        return u
    }
}
