import SwiftUI

// MARK: - Energy tracking (power cost per print)
// The measuring happens on the printer, inside the same daemon that handles
// Auto-Shutdown: a Tuya plug accepts only ONE connection at a time, so a second
// poller would lock the first one out. Each print's consumption is appended to
// a small JSON file that Moonraker serves, and the app reads it from there.

struct EnergyRecord: Identifiable, Decodable {
    var file: String
    var started: Int
    var ended: Int
    var seconds: Int
    var wh: Double
    var pricePerKWh: Double
    var currency: String
    var result: String
    /// Successful / failed wattage reads. 0 samples means the plug was never
    /// readable — the row then shows a warning instead of a silent 0.00.
    var samples: Int
    var failed: Int
    /// Filament, as measured by Klipper and weighed by the slicer's numbers.
    var filamentMm: Double
    var filamentG: Double
    var filamentType: String
    /// Slicer profile name(s) from the G-code ("Sunlu PLA+ Black"), one per
    /// tool separated by ";" — the fallback label when Spoolman knows nothing.
    var filamentName: String
    var filamentToolsG: [Double]?
    var filamentToolsMm: [Double]?
    /// Tool index → Spoolman spool id seen feeding it during the print.
    var spools: [Int: Int]
    /// U1: what was loaded per channel when the print started.
    var channels: [FilamentChannel]
    /// U1: sliced tool index → channel really used (remapped at print start).
    var extruderMap: [Int]
    /// Priced once by the app and written back — so a later switch of the
    /// price source or a changed spool price never rewrites history.
    var filamentCost: Double?
    var filamentToolCosts: [Double?]?
    var priceSource: String?
    /// Per tool: where the price came from ("spoolman"/"slicer") and the
    /// price per kg that was applied — so the details can always say so.
    var toolSources: [String?]
    var toolPricesKg: [Double?]
    /// What the slicer profile said the filament costs per kg (Orca/Prusa
    /// write `; filament_cost = …` per tool into the file), 0 = not set.
    var slicerPricesKg: [Double]

    var id: Int { started }
    var noReadings: Bool { samples == 0 }
    var kwh: Double { wh / 1000 }
    /// Cost at the price that applied WHEN it was printed — recomputing old
    /// prints with today's price would quietly rewrite history.
    var cost: Double { kwh * pricePerKWh }

    enum CodingKeys: String, CodingKey {
        case file, started, ended, seconds, wh, result, samples, failed, spools
        case pricePerKWh = "price_per_kwh"
        case filamentMm = "filament_mm"
        case filamentG = "filament_g"
        case filamentType = "filament_type"
        case filamentName = "filament_name"
        case filamentToolsG = "filament_tools_g"
        case filamentToolsMm = "filament_tools_mm"
        case channels = "filament_channels"
        case extruderMap = "extruder_map"
        case filamentCost = "filament_cost"
        case filamentToolCosts = "filament_tool_costs"
        case priceSource = "price_source"
        case toolSources = "filament_tool_sources"
        case toolPricesKg = "filament_tool_price_kg"
        case slicerPricesKg = "filament_slicer_price_kg"
        case currency
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decodeIfPresent(String.self, forKey: .file) ?? ""
        started = try c.decodeIfPresent(Int.self, forKey: .started) ?? 0
        ended = try c.decodeIfPresent(Int.self, forKey: .ended) ?? 0
        seconds = try c.decodeIfPresent(Int.self, forKey: .seconds) ?? 0
        wh = try c.decodeIfPresent(Double.self, forKey: .wh) ?? 0
        pricePerKWh = try c.decodeIfPresent(Double.self, forKey: .pricePerKWh) ?? 0
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "EUR"
        result = try c.decodeIfPresent(String.self, forKey: .result) ?? ""
        // Records from the first script version carry no counters; treat them
        // as "measured" so they don't all light up as faulty after an update.
        samples = try c.decodeIfPresent(Int.self, forKey: .samples) ?? 1
        failed = try c.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        filamentMm = try c.decodeIfPresent(Double.self, forKey: .filamentMm) ?? 0
        filamentG = try c.decodeIfPresent(Double.self, forKey: .filamentG) ?? 0
        filamentType = try c.decodeIfPresent(String.self, forKey: .filamentType) ?? ""
        filamentName = try c.decodeIfPresent(String.self, forKey: .filamentName) ?? ""
        filamentToolsG = try c.decodeIfPresent([Double].self, forKey: .filamentToolsG)
        filamentToolsMm = try c.decodeIfPresent([Double].self, forKey: .filamentToolsMm)
        let sp = try c.decodeIfPresent([String: Int].self, forKey: .spools) ?? [:]
        spools = Dictionary(uniqueKeysWithValues: sp.compactMap { k, v in Int(k).map { ($0, v) } })
        channels = try c.decodeIfPresent([FilamentChannel].self, forKey: .channels) ?? []
        extruderMap = try c.decodeIfPresent([Int].self, forKey: .extruderMap) ?? []
        filamentCost = try c.decodeIfPresent(Double.self, forKey: .filamentCost)
        filamentToolCosts = try c.decodeIfPresent([Double?].self, forKey: .filamentToolCosts)
        priceSource = try c.decodeIfPresent(String.self, forKey: .priceSource)
        toolSources = try c.decodeIfPresent([String?].self, forKey: .toolSources) ?? []
        toolPricesKg = try c.decodeIfPresent([Double?].self, forKey: .toolPricesKg) ?? []
        slicerPricesKg = try c.decodeIfPresent([Double].self, forKey: .slicerPricesKg) ?? []
    }

    /// Grams per tool; a single-tool print is just its total.
    var gramsPerTool: [Double] {
        if let t = filamentToolsG, !t.isEmpty { return t }
        return filamentG > 0 ? [filamentG] : []
    }
    /// Metres per tool: from the slicer footer, otherwise the total split by
    /// each tool's share of the grams.
    func metres(forTool i: Int) -> Double {
        if let mm = filamentToolsMm, i < mm.count { return mm[i] / 1000 }
        let g = gramsPerTool
        guard i < g.count, filamentG > 0 else { return filamentMm / 1000 }
        return filamentMm / 1000 * g[i] / filamentG
    }
    /// The channel that really printed sliced tool `i`.
    func channel(forTool i: Int) -> Int { extruderMap[safe: i] ?? i }
}

struct FilamentChannel: Decodable, Hashable {
    var type: String
    var vendor: String
    var color: String   // RRGGBB or ""
    /// Filled by the daemon from Spoolman when the channel had a spool:
    /// the filament's name, the spool id and source = "spoolman".
    var name: String = ""
    var spoolId: Int? = nil
    var source: String = ""
    var fromSpoolman: Bool { source == "spoolman" }
    /// "Sunlu PETG Schwarz" from Spoolman, else "Sunlu PETG" from the printer.
    var label: String {
        let parts = fromSpoolman && !name.isEmpty ? [vendor, name] : [vendor, type]
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }
    enum CodingKeys: String, CodingKey { case type, vendor, color, name, source, spoolId = "spool_id" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        vendor = try c.decodeIfPresent(String.self, forKey: .vendor) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        spoolId = try c.decodeIfPresent(Int.self, forKey: .spoolId)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
    }
    init(type: String, vendor: String, color: String) { self.type = type; self.vendor = vendor; self.color = color }
    /// The same channel described by a Spoolman spool (for records written
    /// before the daemon asked Spoolman itself).
    init(spool: SpoolmanSpool) {
        type = spool.filament.material ?? ""
        vendor = spool.filament.vendor?.name ?? ""
        color = String((spool.filament.color_hex ?? "").replacingOccurrences(of: "#", with: "").prefix(6))
        name = spool.filament.name ?? ""
        spoolId = spool.id
        source = "spoolman"
    }
    var swiftUIColor: Color? {
        guard color.count == 6, let v = UInt32(color, radix: 16) else { return nil }
        return Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

/// Puts a price on the grams. Spoolman knows what a spool cost; without it
/// (or for spools without a price) the app's own per-kg prices apply.
enum FilamentPricing {
    private static var spoolCache: [Int: SpoolmanSpool?] = [:]

    static func pricePerGram(spool: SpoolmanSpool) -> Double? {
        let price = spool.price ?? spool.filament.price
        let weight = spool.initial_weight ?? spool.filament.weight
        guard let price, let weight, weight > 0 else { return nil }
        return price / weight
    }

    static func spool(_ id: Int) async -> SpoolmanSpool? {
        if let cached = spoolCache[id] { return cached }
        let s = try? await SpoolmanConfig.service?.spool(id)
        spoolCache[id] = s
        return s
    }

    /// Which real source the user wants (settings → power costs). Global like
    /// the Spoolman connection itself; "spoolman" only makes sense with it on.
    static let sourceKey = "filament_price_source"
    static var useSpoolman: Bool {
        let v = UserDefaults.standard.string(forKey: sourceKey)
        return v == nil ? SpoolmanConfig.isEnabled : v == "spoolman"
    }

    /// One tool's pricing: nil cost = no real price found anywhere.
    struct ToolPrice {
        var cost: Double?
        var source: String?      // "spoolman" / "slicer"
        var pricePerKg: Double?
    }

    /// Real data only. Spoolman first when chosen, and if THAT spool has no
    /// price the slicer profile's figure from the file steps in for this
    /// head. Nothing is guessed — nil means "unknown".
    static func priceFor(tool: Int, spoolID: Int?, slicer: [Double]) async -> ToolPrice {
        if useSpoolman, let sid = spoolID, let s = await spool(sid), let p = pricePerGram(spool: s) {
            return ToolPrice(cost: nil, source: "spoolman", pricePerKg: p * 1000)
        }
        if tool < slicer.count, slicer[tool] > 0 {
            return ToolPrice(cost: nil, source: "slicer", pricePerKg: slicer[tool])
        }
        return ToolPrice()
    }

    /// Cost per sliced tool; the spool is looked up by the channel that
    /// really printed the tool.
    static func costPerTool(grams: [Double], spools: [Int: Int], map: [Int], slicerPrices: [Double]) async -> [ToolPrice] {
        var out: [ToolPrice] = []
        for (tool, g) in grams.enumerated() {
            guard g > 0 else { out.append(ToolPrice(cost: 0)); continue }
            var tp = await priceFor(tool: tool, spoolID: spools[map[safe: tool] ?? tool], slicer: slicerPrices)
            tp.cost = tp.pricePerKg.map { g * $0 / 1000 }
            out.append(tp)
        }
        return out
    }

    /// Sum over all tools — nil as soon as one tool has no price, so a
    /// half-priced print never shows up as a total.
    static func total(of parts: [Double?], grams: [Double]) -> Double? {
        guard grams.contains(where: { $0 > 0 }), !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0, +)
    }

    /// Stored result if the print was priced before, otherwise price it now
    /// and — when every tool got a price — write it into the record on the
    /// printer, so it stays what it was measured as.
    static func price(_ r: EnergyRecord, source: EnergySource) async -> (total: Double?, tools: [ToolPrice]) {
        if let c = r.filamentCost {
            let costs = r.filamentToolCosts ?? [c]
            return (c, costs.indices.map { ToolPrice(cost: costs[$0], source: r.toolSources[safe: $0] ?? nil,
                                                     pricePerKg: r.toolPricesKg[safe: $0] ?? nil) })
        }
        var spools = r.spools
        // A record from the daemon version that only sampled the active spool
        // knows one channel at best. Before falling back to the slicer price,
        // ask the printer's own channel → spool table (the app's 4-colour
        // hook keeps it in the _SPOOLMAN_MAP macro) for the missing heads.
        if useSpoolman {
            let missing = r.gramsPerTool.indices.filter { r.gramsPerTool[$0] > 0 && spools[r.channel(forTool: $0)] == nil }
            if !missing.isEmpty {
                for (ch, sid) in await EnergyLog.spoolmanChannelMap(baseURL: source.baseURL, apiKey: source.apiKey)
                where spools[ch] == nil { spools[ch] = sid }
            }
        }
        let parts = await costPerTool(grams: r.gramsPerTool, spools: spools, map: r.extruderMap, slicerPrices: r.slicerPricesKg)
        let sum = total(of: parts.map(\.cost), grams: r.gramsPerTool)
        if let sum {
            await EnergyLog.storePrice(started: r.started, total: sum, tools: parts,
                                       baseURL: source.baseURL, apiKey: source.apiKey, dir: source.dir)
        }
        return (sum, parts)
    }
}

enum EnergyLog {
    static let fileName = "paxxmaker_energy.json"

    private static func get(_ path: String, baseURL: String, apiKey: String) async -> Data? {
        guard let url = URL(string: "\(baseURL)\(path)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// The file as the printer wrote it — kept raw so a delete round-trips
    /// fields this app version doesn't know about.
    private static func loadRaw(baseURL: String, apiKey: String, dir: String) async -> [[String: Any]]? {
        guard let data = await get("/server/files/config/\(AutoShutdownInstaller.path(dir, fileName))",
                                   baseURL: baseURL, apiKey: apiKey),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["prints"] as? [[String: Any]] ?? []
    }

    /// Newest first, as written by the printer.
    static func load(baseURL: String, apiKey: String, dir: String) async -> [EnergyRecord] {
        guard let raw = await loadRaw(baseURL: baseURL, apiKey: apiKey, dir: dir),
              let arr = try? JSONSerialization.data(withJSONObject: raw),
              let list = try? JSONDecoder().decode([EnergyRecord].self, from: arr)
        else { return [] }
        return list
    }

    /// Remove one print from the printer's file. The daemon only touches the
    /// file when a print ends, so a plain read-modify-upload is safe here.
    static func delete(started: Int, baseURL: String, apiKey: String, dir: String) async -> Bool {
        guard let raw = await loadRaw(baseURL: baseURL, apiKey: apiKey, dir: dir) else { return false }
        let kept = raw.filter { ($0["started"] as? Int) != started }
        guard kept.count != raw.count,
              let data = try? JSONSerialization.data(withJSONObject: ["prints": kept],
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return false }
        return await AutoShutdownInstaller.upload(baseURL: baseURL, apiKey: apiKey, dir: dir,
                                                  filename: fileName, data: data)
    }

    /// Live view of the running print, refreshed by the daemon every ~30 s.
    struct LiveStatus {
        var printing: Bool; var at: Int; var watts: Double?; var wh: Double
        var samples: Int; var failed: Int; var file: String
        var pricePerKWh: Double; var currency: String
        var filamentG: Double; var filamentToolsG: [Double]?; var filamentType: String; var spools: [Int: Int]
        var slicerPricesKg: [Double]; var extruderMap: [Int]
        /// The newest finished print, written by the daemon at print end —
        /// the tile shows it without downloading the whole history.
        var last: EnergyRecord?
        var cost: Double { wh / 1000 * pricePerKWh }
        var gramsPerTool: [Double] {
            if let t = filamentToolsG, !t.isEmpty { return t }
            return filamentG > 0 ? [filamentG] : []
        }
    }

    static func liveStatus(baseURL: String, apiKey: String, dir: String) async -> LiveStatus? {
        guard let data = await get("/server/files/config/\(AutoShutdownInstaller.path(dir, "paxxmaker_energy_status.json"))",
                                   baseURL: baseURL, apiKey: apiKey),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return LiveStatus(printing: o["printing"] as? Bool ?? false,
                          at: o["at"] as? Int ?? 0,
                          watts: o["watts"] as? Double,
                          wh: o["wh"] as? Double ?? 0,
                          samples: o["samples"] as? Int ?? 0,
                          failed: o["failed"] as? Int ?? 0,
                          file: o["file"] as? String ?? "",
                          pricePerKWh: o["price_per_kwh"] as? Double ?? 0,
                          currency: o["currency"] as? String ?? "EUR",
                          filamentG: o["filament_g"] as? Double ?? 0,
                          filamentToolsG: o["filament_tools_g"] as? [Double],
                          filamentType: o["filament_type"] as? String ?? "",
                          spools: Dictionary(uniqueKeysWithValues: (o["spools"] as? [String: Int] ?? [:])
                                    .compactMap { k, v in Int(k).map { ($0, v) } }),
                          slicerPricesKg: o["filament_slicer_price_kg"] as? [Double] ?? [],
                          extruderMap: o["extruder_map"] as? [Int] ?? [],
                          last: (o["last"] as? [String: Any]).flatMap { d in
                              (try? JSONSerialization.data(withJSONObject: d)).flatMap { try? JSONDecoder().decode(EnergyRecord.self, from: $0) }
                          })
    }

    /// Write the app's pricing into one record (see FilamentPricing.price).
    static func storePrice(started: Int, total: Double, tools: [FilamentPricing.ToolPrice],
                           baseURL: String, apiKey: String, dir: String) async {
        guard var raw = await loadRaw(baseURL: baseURL, apiKey: apiKey, dir: dir),
              let i = raw.firstIndex(where: { ($0["started"] as? Int) == started }),
              raw[i]["filament_cost"] == nil else { return }
        raw[i]["filament_cost"] = (total * 10000).rounded() / 10000
        raw[i]["filament_tool_costs"] = tools.map { t -> Any in t.cost.map { ($0 * 10000).rounded() / 10000 } ?? NSNull() }
        raw[i]["filament_tool_sources"] = tools.map { t -> Any in t.source ?? NSNull() }
        raw[i]["filament_tool_price_kg"] = tools.map { t -> Any in t.pricePerKg.map { ($0 * 100).rounded() / 100 } ?? NSNull() }
        raw[i]["price_source"] = FilamentPricing.useSpoolman ? "spoolman" : "slicer"
        guard let data = try? JSONSerialization.data(withJSONObject: ["prints": raw],
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        _ = await AutoShutdownInstaller.upload(baseURL: baseURL, apiKey: apiKey, dir: dir, filename: fileName, data: data)
    }

    /// Apply a new limit right away. The daemon only trims when it writes the
    /// next record, so without this a lowered limit would show no effect
    /// until the next print.
    static func trim(keep: Int, baseURL: String, apiKey: String, dir: String) async {
        guard keep > 0, let raw = await loadRaw(baseURL: baseURL, apiKey: apiKey, dir: dir),
              raw.count > keep else { return }
        let kept = raw.sorted { ($0["started"] as? Int ?? 0) > ($1["started"] as? Int ?? 0) }.prefix(keep)
        guard let data = try? JSONSerialization.data(withJSONObject: ["prints": Array(kept)],
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        _ = await AutoShutdownInstaller.upload(baseURL: baseURL, apiKey: apiKey, dir: dir, filename: fileName, data: data)
    }

    /// U1: channel → Spoolman spool id from the _SPOOLMAN_MAP macro.
    static func spoolmanChannelMap(baseURL: String, apiKey: String) async -> [Int: Int] {
        guard let data = await get("/printer/objects/query?gcode_macro%20_SPOOLMAN_MAP", baseURL: baseURL, apiKey: apiKey),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let m = ((o["result"] as? [String: Any])?["status"] as? [String: Any])?["gcode_macro _SPOOLMAN_MAP"] as? [String: Any]
        else { return [:] }
        var out: [Int: Int] = [:]
        for i in 0..<4 {
            if let v = m["spool\(i)"] as? Int, v > 0 { out[i] = v }
            else if let v = m["spool\(i)"] as? Double, v > 0 { out[i] = Int(v) }
        }
        return out
    }

    /// U1: material / vendor / colour per channel from the firmware.
    static func channelInfo(baseURL: String, apiKey: String) async -> [FilamentChannel] {
        guard let data = await get("/printer/objects/query?print_task_config", baseURL: baseURL, apiKey: apiKey),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ptc = ((o["result"] as? [String: Any])?["status"] as? [String: Any])?["print_task_config"] as? [String: Any],
              let types = ptc["filament_type"] as? [String]
        else { return [] }
        let vendors = ptc["filament_vendor"] as? [String] ?? []
        let colors = ptc["filament_color_rgba"] as? [String] ?? []
        return types.indices.map { i in
            FilamentChannel(type: types[i], vendor: vendors[safe: i] ?? "",
                            color: String((colors[safe: i] ?? "").prefix(6)))
        }
    }

    /// Wipe the whole history on the printer (asked for when deactivating).
    static func deleteAll(baseURL: String, apiKey: String, dir: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/server/files/config/\(AutoShutdownInstaller.path(dir, fileName))")
        else { return false }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "DELETE"
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return code == 200 || code == 404          // already gone counts as done
    }

    // MARK: Thumbnails — Moonraker keeps the slicer's preview next to the G-code
    private static var thumbCache: [String: UIImage] = [:]
    private static var thumbMisses: Set<String> = []

    static func thumbnail(file: String, baseURL: String, apiKey: String) async -> UIImage? {
        let key = "\(baseURL)|\(file)"
        if let img = thumbCache[key] { return img }
        if thumbMisses.contains(key) || file.isEmpty { return nil }
        var q = CharacterSet.urlQueryAllowed; q.remove(charactersIn: "&+")
        guard let enc = file.addingPercentEncoding(withAllowedCharacters: q),
              let data = await get("/server/files/metadata?filename=\(enc)", baseURL: baseURL, apiKey: apiKey),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let res = obj["result"] as? [String: Any],
              let thumbs = res["thumbnails"] as? [[String: Any]]
        else { thumbMisses.insert(key); return nil }
        let sizes = thumbs.compactMap { t -> (w: Int, path: String)? in
            guard let w = t["width"] as? Int, let p = t["relative_path"] as? String else { return nil }
            return (w, p)
        }.sorted { $0.w < $1.w }
        // Smallest one that is still crisp in a list row (~64 pt at 3x),
        // otherwise the biggest there is.
        guard let pick = sizes.first(where: { $0.w >= 150 }) ?? sizes.last
        else { thumbMisses.insert(key); return nil }
        // relative_path is relative to the G-code's own directory.
        let dir = (file as NSString).deletingLastPathComponent
        let rel = dir.isEmpty ? pick.path : "\(dir)/\(pick.path)"
        guard let path = rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let img = await get("/server/files/gcodes/\(path)", baseURL: baseURL, apiKey: apiKey),
              let ui = UIImage(data: img)
        else { thumbMisses.insert(key); return nil }
        thumbCache[key] = ui
        return ui
    }

    static func symbol(_ code: String) -> String {
        switch code.uppercased() {
        case "EUR": return "€"
        case "USD": return "$"
        case "GBP": return "£"
        case "CHF": return "CHF"
        default:    return code
        }
    }

    static func money(_ value: Double, _ code: String) -> String {
        String(format: "%.2f %@", value, symbol(code))
    }

    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }
}

// MARK: - Setup sheet
struct EnergyTrackingSheet: View {
    @Binding var config: PrinterConfig
    let sshUser: String
    let sshPassword: String
    var persist: (PrinterConfig) -> Void
    @AppStorage("app_language") private var appLanguage: String = "en"
    @Environment(\.dismiss) private var dismiss

    @State private var busy = false
    @State private var sending = false
    @State private var message: String? = nil
    @State private var failed = false
    @State private var priceText = ""
    @State private var original: PrinterConfig? = nil
    @State private var askDeleteHistory = false
    @AppStorage(FilamentPricing.sourceKey) private var priceSource: String = ""
    private var effectiveSource: String {
        priceSource.isEmpty ? (SpoolmanConfig.isEnabled ? "spoolman" : "slicer") : priceSource
    }

    private var host: String {
        config.ip.replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .components(separatedBy: ":").first?
            .trimmingCharacters(in: .whitespaces) ?? config.ip
    }
    private var baseURL: String { config.ip.hasPrefix("http") ? config.ip : "http://\(config.ip)" }
    private var user: String {
        let u = sshUser.trimmingCharacters(in: .whitespaces)
        if !u.isEmpty { return u }
        return config.type == .snapmakerU1 ? "root" : "pi"
    }
    private var effectivePassword: String {
        if !sshPassword.isEmpty { return sshPassword }
        if let saved = SSHCredentialStore.load(for: config.name), !saved.isEmpty { return saved }
        return config.type == .snapmakerU1 ? "snapmaker" : ""
    }
    /// The daemon stays when Auto-Shutdown still uses it.
    private func stillNeeded() -> Bool { config.autoShutdownEnabled }

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text(lz(
                    en: "Your price per kilowatt hour. It is stored with each print, so an later price change does not rewrite past costs.",
                    de: "Dein Preis je Kilowattstunde. Er wird bei jedem Druck mitgespeichert — eine spätere Preisänderung schreibt vergangene Kosten nicht um.",
                    fr: "Ton prix du kilowattheure. Il est enregistré avec chaque impression, donc un changement ultérieur ne réécrit pas les coûts passés.",
                    es: "Tu precio por kilovatio hora. Se guarda con cada impresión, así que un cambio posterior no reescribe los costes pasados.",
                    pt: "Seu preço por quilowatt-hora. Ele é salvo junto com cada impressão, então uma alteração posterior não reescreve custos passados.",
                    it: "Il tuo prezzo al chilowattora. Viene salvato con ogni stampa, quindi una modifica successiva non riscrive i costi passati.",
                    zh: "你的每千瓦时电价。每次打印都会一并保存，因此之后改价不会改写以往的费用。"))) {
                    HStack {
                        Image(systemName: "eurosign.circle").foregroundColor(.orange).frame(width: 28)
                        Text(lz(en: "Price per kWh", de: "Preis pro kWh", fr: "Prix par kWh", es: "Precio por kWh", pt: "Preço por kWh", it: "Prezzo per kWh", zh: "每千瓦时价格"))
                        Spacer()
                        TextField("0.30", text: $priceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        Text(EnergyLog.symbol(config.energyCurrency)).foregroundStyle(.secondary)
                    }
                    Picker(lz(en: "Currency", de: "Währung", fr: "Devise", es: "Moneda", pt: "Moeda", it: "Valuta", zh: "货币"),
                           selection: $config.energyCurrency) {
                        Text("€ EUR").tag("EUR")
                        Text("$ USD").tag("USD")
                        Text("£ GBP").tag("GBP")
                        Text("CHF").tag("CHF")
                    }
                }

                Section(footer: Text(effectiveSource == "spoolman"
                    ? lz(en: "The price of the spool loaded in the head. Spoolman not reachable → falls back to the slicer.",
                         de: "Der Preis der im Kopf eingelegten Spule. Spoolman nicht erreichbar → Rückfall auf Slicer.",
                         fr: "Le prix de la bobine chargée dans la tête. Spoolman injoignable → repli sur le slicer.",
                         es: "El precio de la bobina cargada en el cabezal. Spoolman no accesible → se usa el slicer.",
                         pt: "O preço da bobina carregada na cabeça. Spoolman inacessível → usa o fatiador.",
                         it: "Il prezzo della bobina caricata nella testa. Spoolman non raggiungibile → si usa lo slicer.",
                         zh: "喷头所装料盘的价格。Spoolman 无法连接 → 回退到切片软件。")
                    : lz(en: "The price per kg from the filament profile — what you entered in the slicer.",
                         de: "Der Preis pro kg aus dem Filamentprofil — die im Slicer hinterlegten Preise.",
                         fr: "Le prix au kg du profil filament — les prix saisis dans le slicer.",
                         es: "El precio por kg del perfil de filamento: los precios guardados en el slicer.",
                         pt: "O preço por kg do perfil de filamento — os preços definidos no fatiador.",
                         it: "Il prezzo al kg del profilo filamento — i prezzi impostati nello slicer.",
                         zh: "耗材配置中的每公斤价格——即你在切片软件中填写的价格。"))) {
                    Picker(selection: Binding(
                        get: { effectiveSource },
                        set: { priceSource = $0 })) {
                        Text("Slicer").tag("slicer")
                        Text("Spoolman").tag("spoolman")
                    } label: {
                        HStack {
                            Image(systemName: "circle.hexagongrid.fill").foregroundColor(.purple).frame(width: 28)
                            Text(lz(en: "Filament price from", de: "Filamentpreis aus", fr: "Prix du filament depuis", es: "Precio del filamento de", pt: "Preço do filamento de", it: "Prezzo filamento da", zh: "耗材价格来源"))
                        }
                    }
                }

                Section(footer: config.energyKeepCount == 0 ? Text("") : Text(lz(
                    en: "Older prints are dropped from the list on the printer once the limit is reached.",
                    de: "Ist die Grenze erreicht, fallen die ältesten Drucke aus der Liste auf dem Drucker.",
                    fr: "Une fois la limite atteinte, les impressions les plus anciennes disparaissent de la liste sur l'imprimante.",
                    es: "Al alcanzar el límite, las impresiones más antiguas desaparecen de la lista en la impresora.",
                    pt: "Ao atingir o limite, as impressões mais antigas saem da lista na impressora.",
                    it: "Raggiunto il limite, le stampe più vecchie escono dall'elenco sulla stampante.",
                    zh: "达到上限后，最早的打印会从打印机上的列表中移除。"))) {
                    Toggle(isOn: Binding(
                        get: { config.energyKeepCount == 0 },
                        set: { config.energyKeepCount = $0 ? 0 : 100 })) {
                        HStack {
                            Image(systemName: "infinity").foregroundColor(.blue).frame(width: 28)
                            Text(lz(en: "Keep all prints", de: "Alle Drucke behalten", fr: "Garder toutes les impressions", es: "Conservar todas las impresiones", pt: "Manter todas as impressões", it: "Conserva tutte le stampe", zh: "保留所有打印"))
                        }
                    }
                    if config.energyKeepCount > 0 {
                        Stepper(value: $config.energyKeepCount, in: 1...9999, step: config.energyKeepCount >= 100 ? 50 : (config.energyKeepCount >= 20 ? 5 : 1)) {
                            HStack {
                                Image(systemName: "list.number").foregroundColor(.secondary).frame(width: 28)
                                Text(lz(en: "Prints kept", de: "Gespeicherte Drucke", fr: "Impressions conservées", es: "Impresiones guardadas", pt: "Impressões guardadas", it: "Stampe conservate", zh: "保留的打印数"))
                                Spacer()
                                Text("\(config.energyKeepCount)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    if effectivePassword.isEmpty {
                        Label(lz(en: "Enter the SSH password under \"SSH Access\" first.", de: "Bitte zuerst oben unter \"SSH-Zugriff\" das SSH-Passwort eintragen.", fr: "Saisis d'abord le mot de passe SSH sous « Accès SSH ».", es: "Introduce primero la contraseña SSH en «Acceso SSH».", pt: "Insira primeiro a senha SSH em \"Acesso SSH\".", it: "Inserisci prima la password SSH in «Accesso SSH».", zh: "请先在\"SSH 访问\"中输入 SSH 密码。"),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundColor(.orange)
                    }
                    Button {
                        config.energyTrackingEnabled ? (askDeleteHistory = true) : activate()
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView().padding(.trailing, 6) }
                            Text(config.energyTrackingEnabled
                                 ? lz(en: "Deactivate", de: "Deaktivieren", fr: "Désactiver", es: "Desactivar", pt: "Desativar", it: "Disattiva", zh: "停用")
                                 : lz(en: "Install", de: "Installieren", fr: "Installer", es: "Instalar", pt: "Instalar", it: "Installa", zh: "安装"))
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(busy || sending || effectivePassword.isEmpty)
                    .foregroundColor(config.energyTrackingEnabled ? .red : .accentColor)
                    .confirmationDialog(
                        lz(en: "Delete the cost history too?", de: "Kostenverlauf auch löschen?", fr: "Supprimer aussi l'historique des coûts ?", es: "¿Eliminar también el historial de costes?", pt: "Excluir também o histórico de custos?", it: "Eliminare anche la cronologia dei costi?", zh: "同时删除费用记录？"),
                        isPresented: $askDeleteHistory, titleVisibility: .visible) {
                        Button(lz(en: "Delete history", de: "Verlauf löschen", fr: "Supprimer l'historique", es: "Eliminar historial", pt: "Excluir histórico", it: "Elimina cronologia", zh: "删除记录"), role: .destructive) {
                            deactivate(deleteHistory: true)
                        }
                        Button(lz(en: "Keep history", de: "Verlauf behalten", fr: "Garder l'historique", es: "Conservar historial", pt: "Manter histórico", it: "Mantieni cronologia", zh: "保留记录")) {
                            deactivate(deleteHistory: false)
                        }
                        Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {}
                    } message: {
                        Text(lz(en: "The list of recorded prints stays on the printer unless you delete it now.", de: "Die Liste der erfassten Drucke bleibt auf dem Drucker, wenn du sie jetzt nicht löschst.", fr: "La liste des impressions enregistrées reste sur l'imprimante si tu ne la supprimes pas maintenant.", es: "La lista de impresiones registradas permanece en la impresora si no la eliminas ahora.", pt: "A lista de impressões registradas permanece na impressora se você não a excluir agora.", it: "L'elenco delle stampe registrate resta sulla stampante se non lo elimini ora.", zh: "如果现在不删除，已记录的打印列表会保留在打印机上。"))
                    }

                    if sending {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(lz(en: "Sending change to the printer…", de: "Änderung wird an den Drucker geschickt…", fr: "Envoi de la modification à l'imprimante…", es: "Enviando el cambio a la impresora…", pt: "Enviando a alteração para a impressora…", it: "Invio della modifica alla stampante…", zh: "正在将更改发送到打印机…"))
                                .font(.footnote)
                        }
                        .foregroundColor(.blue)
                    }
                    if let message {
                        Label(message, systemImage: failed ? "xmark.octagon.fill" : "checkmark.circle.fill")
                            .font(.footnote).foregroundColor(failed ? .red : .green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section {
                    Text(lz(
                        en: "The printer reads the plug's wattage every few seconds while printing and adds it up. Note that the plug measures everything connected to it, not just the printer.",
                        de: "Der Drucker liest während des Drucks alle paar Sekunden die Wattzahl der Steckdose und summiert sie auf. Beachte: Die Steckdose misst alles, was an ihr hängt — nicht nur den Drucker.",
                        fr: "Pendant l'impression, l'imprimante lit la puissance de la prise toutes les quelques secondes et la cumule. Attention : la prise mesure tout ce qui y est branché, pas seulement l'imprimante.",
                        es: "Durante la impresión, la impresora lee los vatios del enchufe cada pocos segundos y los suma. Ojo: el enchufe mide todo lo conectado a él, no solo la impresora.",
                        pt: "Durante a impressão, a impressora lê a potência da tomada a cada poucos segundos e soma. Atenção: a tomada mede tudo que estiver ligado nela, não apenas a impressora.",
                        it: "Durante la stampa la stampante legge i watt della presa ogni pochi secondi e li somma. Attenzione: la presa misura tutto ciò che vi è collegato, non solo la stampante.",
                        zh: "打印期间，打印机每隔几秒读取插座功率并累加。注意：插座测量的是接在它上面的全部设备，而不只是打印机。"))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .onAppear {
                if original == nil { original = config }

                if priceText.isEmpty {
                    priceText = String(format: "%.2f", config.energyPricePerKWh)
                }
            }
            .navigationTitle(lz(en: "Power costs", de: "Stromkosten", fr: "Coûts d'électricité", es: "Costes de electricidad", pt: "Custos de energia", it: "Costi di energia", zh: "电费"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消")) {
                        if let o = original {
                            config.energyPricePerKWh = o.energyPricePerKWh
                            config.energyCurrency = o.energyCurrency
                            config.energyKeepCount = o.energyKeepCount
                        }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: confirm) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(busy || sending ? .gray : .blue)
                    }
                    .disabled(busy || sending)
                }
            }
        }
    }

    private func parsedPrice() -> Double {
        Double(priceText.replacingOccurrences(of: ",", with: ".")) ?? config.energyPricePerKWh
    }

    private func settings() -> AutoShutdownInstaller.Settings {
        AutoShutdownInstaller.Settings(
            shutdownEnabled: config.autoShutdownEnabled,
            trackEnergy: config.energyTrackingEnabled,
            pricePerKWh: parsedPrice(),
            currency: config.energyCurrency,
            keepCount: config.energyKeepCount,
            delayMinutes: config.autoShutdownDelayMin,
            onComplete: config.autoShutdownOnComplete,
            onCancelled: config.autoShutdownOnCancelled,
            plugType: config.smartPlugType,
            plugHost: config.smartPlugIP
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "https://", with: ""),
            deviceID: config.smartPlugDeviceID,
            localKey: config.smartPlugLocalKey,
            proto: UserDefaults.standard.string(
                forKey: "tuyaProto." + config.smartPlugIP
                    .replacingOccurrences(of: "http://", with: "")
                    .replacingOccurrences(of: "https://", with: "")) ?? "auto")
    }

    private func confirm() {
        config.energyPricePerKWh = parsedPrice()
        guard config.energyTrackingEnabled else { persist(config); dismiss(); return }
        sending = true
        Task {
            do {
                var st = settings(); st.trackEnergy = true
                try await AutoShutdownInstaller.updateSettings(baseURL: baseURL, apiKey: "", dir: AutoShutdownInstaller.dir(for: config.type), settings: st)
                await EnergyLog.trim(keep: st.keepCount, baseURL: baseURL, apiKey: "", dir: AutoShutdownInstaller.dir(for: config.type))
                await MainActor.run { persist(config); sending = false; dismiss() }
            } catch {
                await MainActor.run { sending = false; failed = true; message = error.localizedDescription }
            }
        }
    }

    private func activate() {
        busy = true; message = nil; failed = false
        config.energyPricePerKWh = parsedPrice()
        let b = baseURL, h = host, u = user, pw = effectivePassword
        var st = settings(); st.trackEnergy = true
        let settingsToSend = st
        Task {
            do {
                if config.type == .snapmakerU1 {
                    var ok = true
                    if let enabled = await AutoShutdownInstaller.octoEverywhereEnabled(baseURL: b, apiKey: "") {
                        ok = enabled
                    } else {
                        ok = try await SSHInstaller.checkOctoEverywhereInstalled(host: h, user: u, password: pw)
                    }
                    if !ok {
                        await MainActor.run {
                            busy = false; failed = true
                            message = lz(en: "OctoEverywhere required — the measuring service starts together with it.", de: "OctoEverywhere erforderlich — der Messdienst startet gemeinsam mit ihm.", fr: "OctoEverywhere requis — le service de mesure démarre avec lui.", es: "Se requiere OctoEverywhere: el servicio de medición arranca junto con él.", pt: "OctoEverywhere é necessário — o serviço de medição inicia junto com ele.", it: "OctoEverywhere richiesto — il servizio di misura parte insieme a esso.", zh: "需要 OctoEverywhere——测量服务会随它一起启动。")
                        }
                        return
                    }
                }
                let out = try await AutoShutdownInstaller.install(baseURL: b, apiKey: "", dir: AutoShutdownInstaller.dir(for: config.type), host: h,
                                                                  user: u, password: pw,
                                                                  settings: settingsToSend)
                let placed = !out.contains("NOMOVE")
                await MainActor.run {
                    config.energyTrackingEnabled = placed
                    if placed { persist(config) }
                    busy = false; failed = !placed
                    message = placed
                        ? lz(en: "Installed and running on the printer.", de: "Auf dem Drucker eingerichtet und aktiv.", fr: "Installé et actif sur l'imprimante.", es: "Instalado y activo en la impresora.", pt: "Instalado e ativo na impressora.", it: "Installato e attivo sulla stampante.", zh: "已在打印机上安装并运行。")
                        : lz(en: "The script could not be placed on the printer.", de: "Das Skript konnte auf dem Drucker nicht abgelegt werden.", fr: "Le script n'a pas pu être placé sur l'imprimante.", es: "No se pudo colocar el script en la impresora.", pt: "Não foi possível colocar o script na impressora.", it: "Non è stato possibile collocare lo script sulla stampante.", zh: "无法在打印机上放置脚本。")
                }
            } catch {
                await MainActor.run { busy = false; failed = true; message = error.localizedDescription }
            }
        }
    }

    private func deactivate(deleteHistory: Bool) {
        busy = true; message = nil; failed = false
        let b = baseURL, h = host, u = user, pw = effectivePassword
        let keep = stillNeeded()
        var st = settings(); st.trackEnergy = false
        let settingsToSend = st
        Task {
            do {
                if deleteHistory, !(await EnergyLog.deleteAll(baseURL: b, apiKey: "", dir: AutoShutdownInstaller.dir(for: config.type))) {
                    throw AutoShutdownInstaller.Failure.upload(lz(en: "Printer not reachable — nothing was changed.", de: "Drucker nicht erreichbar — es wurde nichts geändert.", fr: "Imprimante injoignable — rien n'a été modifié.", es: "Impresora no accesible: no se cambió nada.", pt: "Impressora inacessível — nada foi alterado.", it: "Stampante non raggiungibile — non è stato modificato nulla.", zh: "无法连接打印机——未做任何更改。"))
                }
                if keep {
                    // Auto-Shutdown still needs the daemon: only switch the
                    // feature off instead of removing everything.
                    try await AutoShutdownInstaller.updateSettings(baseURL: b, apiKey: "", dir: AutoShutdownInstaller.dir(for: config.type), settings: settingsToSend)
                } else {
                    _ = try await AutoShutdownInstaller.remove(baseURL: b, apiKey: "", dir: AutoShutdownInstaller.dir(for: config.type), host: h, user: u, password: pw)
                }
                await MainActor.run {
                    config.energyTrackingEnabled = false
                    persist(config)
                    busy = false
                    message = lz(en: "Tracking switched off.", de: "Zählung abgeschaltet.", fr: "Suivi désactivé.", es: "Seguimiento desactivado.", pt: "Contagem desativada.", it: "Conteggio disattivato.", zh: "统计已关闭。")
                }
            } catch {
                await MainActor.run { busy = false; failed = true; message = error.localizedDescription }
            }
        }
    }
}

// MARK: - History window
/// One printer's log endpoint. The tile knows only these two values, the
/// settings entry derives them from every configured printer.
struct EnergySource: Hashable {
    let baseURL: String
    let apiKey: String
    /// Where the printer keeps the log (see AutoShutdownInstaller.dir).
    let dir: String
}

struct EnergyHistoryView: View {
    let sources: [EnergySource]

    init(sources: [EnergySource]) { self.sources = sources }

    init(printers: [PrinterConfig]) {
        self.sources = printers.filter { $0.energyTrackingEnabled }.map {
            EnergySource(baseURL: $0.effectiveBaseURL,
                         apiKey: $0.connectionMode == .octoEverywhere ? $0.octoEverywhereAPIKey : "",
                         dir: AutoShutdownInstaller.dir(for: $0.type))
        }
    }

    /// A record together with the printer it came from — needed to delete it
    /// and to fetch its preview image.
    struct Row: Identifiable {
        let record: EnergyRecord
        let source: EnergySource
        /// Priced after loading (Spoolman lookups are async).
        var priced = false
        /// nil once priced = no real price available for this print.
        var filamentCost: Double? = nil
        var id: String { "\(source.baseURL)|\(record.started)" }
        var total: Double { record.cost + (filamentCost ?? 0) }
        var priceMissing: Bool { priced && filamentCost == nil && record.filamentG > 0 }
    }

    @Environment(\.dismiss) private var dismiss
    // Read so the view re-renders the moment the app language is switched.
    @AppStorage("app_language") private var appLanguage: String = "en"
    @State private var rows: [Row] = []
    @State private var loading = true
    @State private var deleteFailed = false
    /// The tapped row — carried in the item so the sheet never reads stale state.
    @State private var selected: Row? = nil

    private var total: Double { rows.reduce(0) { $0 + $1.total } }
    private var totalEnergy: Double { rows.reduce(0) { $0 + $1.record.cost } }
    private var totalFilament: Double { rows.reduce(0) { $0 + ($1.filamentCost ?? 0) } }
    private var totalKWh: Double { rows.reduce(0) { $0 + $1.record.kwh } }
    private var totalGrams: Double { rows.reduce(0) { $0 + $1.record.filamentG } }
    private var currency: String { rows.first?.record.currency ?? "EUR" }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rows.isEmpty {
                    ContentUnavailableView(
                        lz(en: "No prints recorded yet", de: "Noch keine Drucke erfasst", fr: "Aucune impression enregistrée", es: "Aún no hay impresiones registradas", pt: "Nenhuma impressão registrada", it: "Nessuna stampa registrata", zh: "尚未记录打印"),
                        systemImage: "bolt.slash",
                        description: Text(lz(
                            en: "Consumption is recorded once a print finishes.",
                            de: "Der Verbrauch wird erfasst, sobald ein Druck beendet ist.",
                            fr: "La consommation est enregistrée dès qu'une impression se termine.",
                            es: "El consumo se registra cuando termina una impresión.",
                            pt: "O consumo é registrado assim que uma impressão termina.",
                            it: "Il consumo viene registrato quando una stampa termina.",
                            zh: "打印结束后才会记录用电量。")))
                } else {
                    List {
                        Section {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(lz(en: "Total", de: "Gesamt", fr: "Total", es: "Total", pt: "Total", it: "Totale", zh: "合计"))
                                        .fontWeight(.semibold)
                                    Spacer()
                                    Text(EnergyLog.money(total, currency)).fontWeight(.semibold)
                                }
                                HStack(spacing: 10) {
                                    Label("\(String(format: "%.2f", totalKWh)) kWh · \(EnergyLog.money(totalEnergy, currency))", systemImage: "bolt.fill")
                                    Label("\(String(format: "%.0f", totalGrams)) g · \(EnergyLog.money(totalFilament, currency))", systemImage: "circle.hexagongrid.fill")
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Section {
                            ForEach(rows) { row in
                                rowView(row)
                            }
                            .onDelete(perform: delete)
                        }
                    }
                }
            }
            .navigationTitle(lz(en: "Power costs", de: "Stromkosten", fr: "Coûts d'électricité", es: "Costes de electricidad", pt: "Custos de energia", it: "Costi di energia", zh: "电费"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(lz(en: "Done", de: "Fertig", fr: "OK", es: "Listo", pt: "Concluído", it: "Fine", zh: "完成")) { dismiss() }
                }
            }
            .alert(lz(en: "Could not delete", de: "Löschen fehlgeschlagen", fr: "Suppression impossible", es: "No se pudo eliminar", pt: "Não foi possível excluir", it: "Impossibile eliminare", zh: "无法删除"),
                   isPresented: $deleteFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(lz(en: "The printer is not reachable — the entry stays.", de: "Der Drucker ist nicht erreichbar — der Eintrag bleibt.", fr: "L'imprimante est injoignable — l'entrée reste.", es: "La impresora no está accesible: la entrada se mantiene.", pt: "A impressora não está acessível — a entrada permanece.", it: "La stampante non è raggiungibile — la voce resta.", zh: "打印机无法连接——条目保留。"))
            }
            .refreshable { await load() }
            .task { await load() }
            .sheet(item: $selected) { row in
                EnergyDetailView(row: row)
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        let r = row.record
        Button { selected = row } label: {
            HStack(spacing: 12) {
                EnergyThumb(file: r.file, source: row.source)
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.file.replacingOccurrences(of: ".gcode", with: ""))
                        .font(.subheadline).fontWeight(.medium).lineLimit(1)
                        .foregroundColor(.primary)
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill").foregroundColor(.yellow)
                        Text(EnergyLog.money(r.cost, r.currency))
                        Text("+")
                        Image(systemName: "circle.hexagongrid.fill").foregroundColor(.purple)
                        Text(row.priced ? (row.filamentCost.map { EnergyLog.money($0, r.currency) } ?? "?") : "…")
                        Text("=")
                        Text(row.priceMissing ? "?" : EnergyLog.money(row.total, r.currency)).fontWeight(.semibold)
                        if r.noReadings {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func delete(at offsets: IndexSet) {
        let doomed = offsets.map { rows[$0] }
        // Optimistic: drop the row now, put it back if the printer refuses.
        rows.remove(atOffsets: offsets)
        Task {
            for row in doomed {
                let ok = await EnergyLog.delete(started: row.record.started,
                                                baseURL: row.source.baseURL, apiKey: row.source.apiKey, dir: row.source.dir)
                if !ok {
                    await MainActor.run {
                        rows.append(row)
                        rows.sort { $0.record.started > $1.record.started }
                        deleteFailed = true
                    }
                }
            }
        }
    }

    private func load() async {
        // Several printers can each keep their own log; merge and sort.
        var all: [Row] = []
        for src in sources {
            all += await EnergyLog.load(baseURL: src.baseURL, apiKey: src.apiKey, dir: src.dir)
                .map { Row(record: $0, source: src) }
        }
        let sorted = all.sorted { $0.record.started > $1.record.started }
        await MainActor.run { rows = sorted; loading = false }
        // Price the filament afterwards — Spoolman lookups must not hold up
        // the list, and the rows show "…" until their number is in.
        for row in sorted {
            let r = row.record
            let c = await FilamentPricing.price(r, source: row.source).total
            await MainActor.run {
                if let i = rows.firstIndex(where: { $0.id == row.id }) { rows[i].filamentCost = c; rows[i].priced = true }
            }
        }
    }
}

/// Everything recorded for one print.
struct EnergyDetailView: View {
    let row: EnergyHistoryView.Row
    @Environment(\.dismiss) private var dismiss
    @AppStorage("app_language") private var appLanguage: String = "en"

    private var r: EnergyRecord { row.record }
    @State private var tools: [FilamentPricing.ToolPrice] = []
    private var toolCosts: [Double?] { tools.map(\.cost) }
    @State private var priced = false
    /// Channel → Spoolman description, fetched for older records whose
    /// daemon only stored the printer's display entry.
    @State private var spoolChannels: [Int: FilamentChannel] = [:]

    private func channel(tool: Int) -> FilamentChannel? {
        let ch = r.channel(forTool: tool)
        if let c = r.channels[safe: ch], c.fromSpoolman { return c }
        if let c = spoolChannels[ch] { return c }
        return r.channels[safe: ch]
    }

    /// Priced HERE, not taken from the list row: the row is a snapshot from
    /// the moment it was tapped and may not have been priced yet.
    private var filamentTotal: Double? {
        priced ? FilamentPricing.total(of: toolCosts, grams: r.gramsPerTool) : row.filamentCost
    }
    private var grandTotal: Double { r.cost + (filamentTotal ?? 0) }
    private var totalMissing: Bool { priced && filamentTotal == nil && r.filamentG > 0 }

    /// Material per sliced tool, from the channel that REALLY printed it
    /// (the user may have remapped at print start); else the slicer's list.
    private func material(tool: Int) -> String {
        if let ch = channel(tool: tool), !ch.type.isEmpty { return ch.type }
        let types = r.filamentType.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        return types[safe: tool] ?? types.first ?? ""
    }
    private func color(tool: Int) -> Color? { channel(tool: tool)?.swiftUIColor }
    /// "Sunlu ASA" — what was really loaded in the head that printed this tool.
    private func loaded(tool: Int) -> String {
        // Spoolman's name first, then the slicer's profile name from the
        // G-code, then the printer's own channel entry, then the bare material.
        if let ch = channel(tool: tool), ch.fromSpoolman, !ch.label.isEmpty { return ch.label }
        let names = r.filamentName.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        if let n = names[safe: tool] ?? (names.count == 1 ? names.first : nil), !n.isEmpty { return n }
        if let ch = channel(tool: tool), !ch.label.isEmpty { return ch.label }
        return material(tool: tool)
    }
    private func head(_ tool: Int) -> String {
        lz(en: "Head", de: "Kopf", fr: "Tête", es: "Cabezal", pt: "Cabeça", it: "Testa", zh: "喷头") + " \(r.channel(forTool: tool) + 1)"
    }
    private var usedTools: [Int] { r.gramsPerTool.indices.filter { r.gramsPerTool[$0] > 0 } }
    private var priceMissing: String {
        lz(en: "Price per kg could not be determined", de: "Preis/kg konnte nicht ermittelt werden", fr: "Prix au kg indéterminable", es: "No se pudo determinar el precio por kg", pt: "Não foi possível determinar o preço por kg", it: "Prezzo al kg non determinabile", zh: "无法确定每公斤价格")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        EnergyThumb(file: r.file, source: row.source, size: 72)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.file.replacingOccurrences(of: ".gcode", with: ""))
                                .font(.headline).lineLimit(2)
                            Text(Date(timeIntervalSince1970: TimeInterval(r.started)),
                                 format: .dateTime.day().month().year().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                            Label(r.result == "complete"
                                  ? lz(en: "Completed", de: "Fertig", fr: "Terminé", es: "Completado", pt: "Concluído", it: "Completata", zh: "完成")
                                  : lz(en: "Cancelled", de: "Abgebrochen", fr: "Annulé", es: "Cancelado", pt: "Cancelado", it: "Annullata", zh: "已取消"),
                                  systemImage: r.result == "complete" ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.caption).foregroundColor(r.result == "complete" ? .green : .orange)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section(lz(en: "Costs", de: "Kosten", fr: "Coûts", es: "Costes", pt: "Custos", it: "Costi", zh: "费用")) {
                    line(lz(en: "Power", de: "Strom", fr: "Électricité", es: "Electricidad", pt: "Energia", it: "Elettricità", zh: "电费"), EnergyLog.money(r.cost, r.currency), "bolt.fill", .yellow)
                    // Single material: its real colour and name. Several: one line per head below.
                    if usedTools.count <= 1 {
                        let t = usedTools.first ?? 0
                        line(loaded(tool: t).isEmpty ? lz(en: "Filament", de: "Filament", fr: "Filament", es: "Filamento", pt: "Filamento", it: "Filamento", zh: "耗材") : loaded(tool: t),
                             priced ? (filamentTotal.map { EnergyLog.money($0, r.currency) } ?? priceMissing) : "…",
                             "circle.hexagongrid.fill", color(tool: t) ?? .secondary)
                    } else {
                        ForEach(usedTools, id: \.self) { i in
                            line(loaded(tool: i).isEmpty ? head(i) : "\(head(i)) · \(loaded(tool: i))",
                                 priced ? (toolCosts[safe: i].flatMap { $0 }.map { EnergyLog.money($0, r.currency) } ?? priceMissing) : "…",
                                 "circle.hexagongrid.fill", color(tool: i) ?? .secondary)
                        }
                    }
                    HStack {
                        Text(lz(en: "Total", de: "Gesamt", fr: "Total", es: "Total", pt: "Total", it: "Totale", zh: "合计")).fontWeight(.semibold)
                        Spacer()
                        Text(totalMissing ? "?" : EnergyLog.money(grandTotal, r.currency)).fontWeight(.semibold)
                    }
                }

                Section(lz(en: "Power", de: "Strom", fr: "Électricité", es: "Electricidad", pt: "Energia", it: "Elettricità", zh: "电力")) {
                    line(lz(en: "Consumption", de: "Verbrauch", fr: "Consommation", es: "Consumo", pt: "Consumo", it: "Consumo", zh: "用电量"), String(format: "%.3f kWh", r.kwh))
                    line(lz(en: "Duration", de: "Dauer", fr: "Durée", es: "Duración", pt: "Duração", it: "Durata", zh: "时长"), EnergyLog.duration(r.seconds))
                    if r.seconds > 0 {
                        line(lz(en: "Average", de: "Durchschnitt", fr: "Moyenne", es: "Promedio", pt: "Média", it: "Media", zh: "平均"), String(format: "%.0f W", r.wh / (Double(r.seconds) / 3600)))
                    }
                    line(lz(en: "Price per kWh", de: "Preis pro kWh", fr: "Prix par kWh", es: "Precio por kWh", pt: "Preço por kWh", it: "Prezzo per kWh", zh: "每千瓦时价格"), EnergyLog.money(r.pricePerKWh, r.currency))
                    if r.noReadings {
                        Label(lz(en: "Plug not readable during this print", de: "Steckdose war während des Drucks nicht lesbar", fr: "Prise illisible pendant l'impression", es: "Enchufe ilegible durante la impresión", pt: "Tomada ilegível durante a impressão", it: "Presa non leggibile durante la stampa", zh: "打印期间无法读取插座"), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundColor(.orange)
                    }
                }

                Section(lz(en: "Filament", de: "Filament", fr: "Filament", es: "Filamento", pt: "Filamento", it: "Filamento", zh: "耗材")) {
                    if r.filamentG > 0 {
                        line(lz(en: "Used", de: "Verbraucht", fr: "Utilisé", es: "Usado", pt: "Usado", it: "Usato", zh: "用量"), String(format: "%.1f g · %.1f m", r.filamentG, r.filamentMm / 1000))
                        let multi = usedTools.count > 1
                        // One row per head that extruded (single nozzle: just the
                        // filament): what it was, what it used, where the price came from.
                        let tools = r.gramsPerTool
                        ForEach(usedTools, id: \.self) { i in
                                HStack(spacing: 8) {
                                    Circle().fill(color(tool: i) ?? Color.secondary.opacity(0.3))
                                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                                        .frame(width: 12, height: 12)
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 6) {
                                            if multi { Text(head(i)) }
                                            if !loaded(tool: i).isEmpty {
                                                Text(loaded(tool: i)).foregroundStyle(multi ? .secondary : .primary).lineLimit(1)
                                            }
                                        }
                                        Text(priced ? priceSource(tool: i) : "…").font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 1) {
                                        Text(String(format: "%.1f g", tools[i]))
                                        Text(String(format: "%.2f m", r.metres(forTool: i))).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                        }
                    } else {
                        Text(lz(en: "No filament data for this print.", de: "Für diesen Druck liegen keine Filamentdaten vor.", fr: "Pas de données filament pour cette impression.", es: "No hay datos de filamento para esta impresión.", pt: "Sem dados de filamento para esta impressão.", it: "Nessun dato filamento per questa stampa.", zh: "此次打印没有耗材数据。"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

            }
            .navigationTitle(lz(en: "Details", de: "Details", fr: "Détails", es: "Detalles", pt: "Detalhes", it: "Dettagli", zh: "详情"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(lz(en: "Done", de: "Fertig", fr: "OK", es: "Listo", pt: "Concluído", it: "Fine", zh: "完成")) { dismiss() }
                }
            }
        }
        .presentationDetents([.large, .medium])
        .task {
            tools = await FilamentPricing.price(r, source: row.source).tools
            priced = true
            // Spoolman's own name and colour for channels the daemon only
            // described from the printer display.
            if FilamentPricing.useSpoolman {
                for (ch, sid) in r.spools where !(r.channels[safe: ch]?.fromSpoolman ?? false) {
                    if let sp = await FilamentPricing.spool(sid) { spoolChannels[ch] = FilamentChannel(spool: sp) }
                }
            }
        }
    }

    /// Where the per-kg price for this tool came from, with the figure.
    private func priceSource(tool: Int) -> String {
        guard let tp = tools[safe: tool], let src = tp.source, let p = tp.pricePerKg else { return priceMissing }
        return "\(src == "spoolman" ? "Spoolman" : "Slicer") · \(EnergyLog.money(p, r.currency))/kg"
    }

    @ViewBuilder
    private func line(_ label: String, _ value: String, _ icon: String? = nil, _ color: Color = .secondary) -> some View {
        HStack {
            if let icon { Image(systemName: icon).foregroundColor(color).frame(width: 24) }
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

/// The slicer's preview image from Moonraker, or a neutral placeholder when
/// the G-code (and with it the thumbnail) is gone.
struct EnergyThumb: View {
    let file: String
    let source: EnergySource
    var size: CGFloat = 48
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "cube").foregroundColor(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 6))
        .task(id: file) {
            image = await EnergyLog.thumbnail(file: file, baseURL: source.baseURL, apiKey: source.apiKey)
        }
    }
}

// MARK: - Dashboard tile
struct EnergyCostTileView: View {
    let baseURL: String
    let apiKey: String
    let printerType: PrinterConfig.PrinterType
    private var dir: String { AutoShutdownInstaller.dir(for: printerType) }
    /// From the printer's own status — the live view goes away the moment the
    /// print ends instead of waiting for the daemon's next status write.
    var isPrinting: Bool = false

    @State private var last: EnergyRecord?
    @State private var lastFilamentCost: Double? = nil
    @State private var live: EnergyLog.LiveStatus?
    @State private var liveFilamentCost: Double? = nil
    @State private var loaded = false
    @State private var showHistory = false
    // The tile's inputs never change, so SwiftUI would keep its old body on a
    // language switch; reading the key makes it re-render at once.
    @AppStorage("app_language") private var appLanguage: String = "en"

    var body: some View {
        Button { showHistory = true } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(.thinMaterial)
                RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06))
                RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.22), lineWidth: 1)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "bolt.fill").foregroundColor(.yellow).font(.caption)
                        Text(lz(en: "Last Print Cost", de: "Kosten letzter Druck", fr: "Coût dernière impression", es: "Coste última impresión", pt: "Custo da última impressão", it: "Costo ultima stampa", zh: "上次打印费用"))
                            .font(.caption).fontWeight(.semibold)
                            .foregroundColor(.secondary).textCase(.uppercase).tracking(1)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                    }

                    if isPrinting, let l = live, l.printing, Date().timeIntervalSince1970 - Double(l.at) < 180 {
                        // Running print: the cost so far, straight from the daemon.
                        Text(EnergyLog.money(l.cost + (liveFilamentCost ?? 0), l.currency))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                            .minimumScaleFactor(0.5).lineLimit(1)
                        HStack(spacing: 8) {
                            if let w = l.watts { Text(String(format: "%.0f W", w)) } else {
                                Label(lz(en: "Plug not readable", de: "Steckdose nicht lesbar", fr: "Prise illisible", es: "Enchufe ilegible", pt: "Tomada ilegível", it: "Presa non leggibile", zh: "无法读取插座"), systemImage: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                            }
                            Text("·")
                            Text(String(format: "%.3f kWh", l.wh / 1000))
                            if l.filamentG > 0 { Text("·"); Text(String(format: "%.0f g", l.filamentG)) }
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        Text(lz(en: "Running print", de: "Laufender Druck", fr: "Impression en cours", es: "Impresión en curso", pt: "Impressão em andamento", it: "Stampa in corso", zh: "打印进行中"))
                            .font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    } else if let r = last {
                        Text(EnergyLog.money(r.cost + (lastFilamentCost ?? 0), r.currency))
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                            .minimumScaleFactor(0.5).lineLimit(1)
                        HStack(spacing: 8) {
                            Label(EnergyLog.money(r.cost, r.currency), systemImage: "bolt.fill")
                            if r.filamentG > 0 {
                                Label("\(String(format: "%.0f g", r.filamentG)) \(lastFilamentCost.map { EnergyLog.money($0, r.currency) } ?? "?")", systemImage: "circle.hexagongrid.fill")
                            }
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        Text(r.file.replacingOccurrences(of: ".gcode", with: ""))
                            .font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    } else {
                        Text(loaded
                             ? lz(en: "No data yet", de: "Noch keine Daten", fr: "Pas encore de données", es: "Aún sin datos", pt: "Ainda sem dados", it: "Ancora nessun dato", zh: "暂无数据")
                             : "…")
                            .font(.system(size: 15, weight: .medium)).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showHistory, onDismiss: { Task { await load() } }) {
            EnergyHistoryView(sources: [EnergySource(baseURL: baseURL, apiKey: apiKey, dir: dir)])
        }
        .task(id: "\(baseURL)|\(isPrinting)") {
            // Both files are tiny, so polling every few seconds while the tile
            // is on screen is cheap — and the finished print shows up right away.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func load() async {
        // Status file first: tiny, and since the daemon mirrors the newest
        // print into it the (possibly multi-MB) history is only fetched when
        // an older daemon left no such entry.
        let status = await EnergyLog.liveStatus(baseURL: baseURL, apiKey: apiKey, dir: dir)
        var newest = status?.last
        if newest == nil {
            newest = await EnergyLog.load(baseURL: baseURL, apiKey: apiKey, dir: dir)
                .max { $0.started < $1.started }
        }
        var lastCost: Double? = nil, liveCost: Double? = nil
        if let r = newest {
            lastCost = await FilamentPricing.price(r, source: EnergySource(baseURL: baseURL, apiKey: apiKey, dir: dir)).total
        }
        if let l = status, l.printing {
            let parts = await FilamentPricing.costPerTool(grams: l.gramsPerTool, spools: l.spools, map: l.extruderMap, slicerPrices: l.slicerPricesKg)
            liveCost = FilamentPricing.total(of: parts.map(\.cost), grams: l.gramsPerTool)
        }
        await MainActor.run {
            last = newest; live = status; loaded = true
            lastFilamentCost = lastCost; liveFilamentCost = liveCost
        }
    }
}
