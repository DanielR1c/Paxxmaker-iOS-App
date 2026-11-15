import SwiftUI
import CryptoKit

// What PaxxMaker-Connect 1.5 adds with OrcaSlicer 2.5: the plate's statistics,
// a model check with Orca's repair, colour mixing of two heads, and filament
// matching by OrcaSlicer's filament ids.

// MARK: statistics

/// OrcaSlicer's plate statistics as PaxxMaker-Connect hands them on.
struct SliceStats: Decodable {
    struct Head: Decodable, Identifiable {
        var head: Int
        var length_m: Double?
        var weight_g: Double?
        var cost: Double?
        var model_g: Double?
        var tower_g: Double?
        var flush_g: Double?
        var support_g: Double?
        var id: Int { head }
    }
    struct Feature: Decodable, Identifiable {
        var name: String
        var time_s: Int?
        var weight_g: Double?
        var id: String { name }
    }
    var time_s: Int?
    var prepare_s: Int?
    var travel_s: Int?
    var layers: Int?
    var weight_g: Double?
    var cost: Double?
    var changes: Int?
    var heads: [Head]?
    var features: [Feature]?
    var mix_slot: Int?

    /// Orca's feature names in the app's language.
    static func featureName(_ n: String) -> String {
        switch n {
        case "Outer wall": return lz(en: "Outer wall", de: "Außenwand", fr: "Paroi externe", es: "Pared exterior", pt: "Parede externa", it: "Parete esterna", zh: "外墙")
        case "Inner wall": return lz(en: "Inner wall", de: "Innenwand", fr: "Paroi interne", es: "Pared interior", pt: "Parede interna", it: "Parete interna", zh: "内墙")
        case "Overhang wall": return lz(en: "Overhang wall", de: "Überhangwand", fr: "Paroi en surplomb", es: "Pared en voladizo", pt: "Parede em balanço", it: "Parete a sbalzo", zh: "悬垂墙")
        case "Sparse infill": return lz(en: "Infill", de: "Füllung", fr: "Remplissage", es: "Relleno", pt: "Preenchimento", it: "Riempimento", zh: "稀疏填充")
        case "Internal solid infill": return lz(en: "Solid infill", de: "Massive Füllung", fr: "Remplissage plein", es: "Relleno sólido", pt: "Preenchimento sólido", it: "Riempimento pieno", zh: "内部实心填充")
        case "Top surface": return lz(en: "Top surface", de: "Oberseite", fr: "Surface supérieure", es: "Superficie superior", pt: "Superfície superior", it: "Superficie superiore", zh: "顶面")
        case "Bottom surface": return lz(en: "Bottom surface", de: "Unterseite", fr: "Surface inférieure", es: "Superficie inferior", pt: "Superfície inferior", it: "Superficie inferiore", zh: "底面")
        case "Bridge", "Internal Bridge": return lz(en: "Bridge", de: "Brücke", fr: "Pont", es: "Puente", pt: "Ponte", it: "Ponte", zh: "桥接")
        case "Gap infill": return lz(en: "Gap infill", de: "Lückenfüllung", fr: "Remplissage d'espace", es: "Relleno de huecos", pt: "Preenchimento de vãos", it: "Riempimento spazi", zh: "间隙填充")
        case "Prime tower": return lz(en: "Prime tower", de: "Reinigungsturm", fr: "Tour de purge", es: "Torre de purga", pt: "Torre de purga", it: "Torre di spurgo", zh: "擦拭塔")
        case "Support", "Support transition": return lz(en: "Support", de: "Stütze", fr: "Support", es: "Soporte", pt: "Suporte", it: "Supporto", zh: "支撑")
        case "Support interface": return lz(en: "Support interface", de: "Stützkontakt", fr: "Interface de support", es: "Interfaz de soporte", pt: "Interface de suporte", it: "Interfaccia supporto", zh: "支撑接触面")
        case "Skirt", "Brim": return lz(en: "Skirt / brim", de: "Skirt / Rand", fr: "Jupe / bordure", es: "Falda / borde", pt: "Saia / borda", it: "Skirt / brim", zh: "裙边 / Brim")
        case "Ironing": return lz(en: "Ironing", de: "Glätten", fr: "Lissage", es: "Planchado", pt: "Passar a ferro", it: "Stiratura", zh: "熨烫")
        default: return n
        }
    }
}

/// The statistics rows under "Result": per head, tool changes, time by part.
struct SliceStatsRows: View {
    let stats: SliceStats
    let currency: String
    let isU1: Bool

    private func g(_ v: Double?) -> String { String(format: "%.1f g", v ?? 0) }

    var body: some View {
        if let heads = stats.heads, !heads.isEmpty {
            ForEach(heads) { h in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(isU1 ? lz(en: "Head \(h.head)", de: "Kopf \(h.head)", fr: "Tête \(h.head)", es: "Cabezal \(h.head)", pt: "Cabeça \(h.head)", it: "Testa \(h.head)", zh: "喷头 \(h.head)")
                                  : lz(en: "Filament", de: "Filament", fr: "Filament", es: "Filamento", pt: "Filamento", it: "Filamento", zh: "耗材"))
                        Spacer()
                        Text("\(g(h.weight_g)) · \(String(format: "%.2f m", h.length_m ?? 0))" + (h.cost.map { $0 > 0 ? " · " + EnergyLog.money($0, currency) : "" } ?? ""))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    let parts = breakdown(h)
                    if !parts.isEmpty {
                        Text(parts).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        if let c = stats.changes, c > 0 {
            HStack {
                Text(lz(en: "Head changes", de: "Kopfwechsel", fr: "Changements de tête", es: "Cambios de cabezal", pt: "Trocas de cabeça", it: "Cambi testa", zh: "换头次数"))
                Spacer()
                Text("\(c)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
        if let f = stats.features, !f.isEmpty {
            DisclosureGroup(lz(en: "Time by part", de: "Zeit nach Bereich", fr: "Temps par zone", es: "Tiempo por zona", pt: "Tempo por área", it: "Tempo per zona", zh: "按部位的时间")) {
                ForEach(f.filter { ($0.time_s ?? 0) > 0 }) { e in
                    HStack {
                        Text(SliceStats.featureName(e.name))
                        Spacer()
                        Text(EnergyLog.duration(e.time_s ?? 0) + " · " + g(e.weight_g))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.footnote)
                }
                if let t = stats.travel_s, t > 0 {
                    HStack {
                        Text(lz(en: "Travel moves", de: "Leerfahrten", fr: "Déplacements", es: "Desplazamientos", pt: "Deslocamentos", it: "Spostamenti", zh: "空驶"))
                        Spacer()
                        Text(EnergyLog.duration(t)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.footnote)
                }
            }
        }
    }

    /// "Model 1.8 g · Tower 2.4 g" — only the parts that use filament.
    private func breakdown(_ h: SliceStats.Head) -> String {
        var out: [String] = []
        let total = h.weight_g ?? 0
        let model = h.model_g ?? 0
        guard total > 0, abs(total - model) > 0.05 else { return "" }
        out.append(lz(en: "Model", de: "Modell", fr: "Modèle", es: "Modelo", pt: "Modelo", it: "Modello", zh: "模型") + " " + g(model))
        if let t = h.tower_g, t > 0.05 { out.append(lz(en: "Tower", de: "Turm", fr: "Tour", es: "Torre", pt: "Torre", it: "Torre", zh: "塔") + " " + g(t)) }
        if let f = h.flush_g, f > 0.05 { out.append(lz(en: "Flush", de: "Spülen", fr: "Purge", es: "Purga", pt: "Purga", it: "Spurgo", zh: "冲刷") + " " + g(f)) }
        if let s = h.support_g, s > 0.05 { out.append(lz(en: "Support", de: "Stütze", fr: "Support", es: "Soporte", pt: "Suporte", it: "Supporto", zh: "支撑") + " " + g(s)) }
        return out.joined(separator: " · ")
    }
}

// MARK: model check

enum MeshCheck {
    /// Edges that belong to one triangle only — holes and cracks. Vertices
    /// are joined by their exact position (an STL repeats them per triangle).
    nonisolated static func openEdges(_ mesh: TriMesh) -> Int {
        struct P: Hashable { let x: UInt32, y: UInt32, z: UInt32 }
        let v = mesh.vertices
        guard v.count >= 3 else { return 0 }
        var ids: [P: UInt32] = [:]
        ids.reserveCapacity(v.count / 2)
        var index = [UInt32](repeating: 0, count: v.count)
        for i in v.indices {
            let p = P(x: v[i].x.bitPattern, y: v[i].y.bitPattern, z: v[i].z.bitPattern)
            if let id = ids[p] { index[i] = id } else { let id = UInt32(ids.count); ids[p] = id; index[i] = id }
        }
        var edges: [UInt64: Int32] = [:]
        edges.reserveCapacity(v.count)
        for t in 0..<(v.count / 3) {
            for k in 0..<3 {
                let a = index[t * 3 + k], b = index[t * 3 + (k + 1) % 3]
                if a == b { continue }
                let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
                edges[key, default: 0] += 1
            }
        }
        return edges.values.reduce(0) { $0 + ($1 == 1 ? 1 : 0) }
    }
}

// MARK: colour mixing

/// Two heads printing one colour by taking turns (OrcaSlicer 2.5 "mixed
/// filament"): layer by layer or in finer sub-layers, at a fixed share or as
/// a gradient from bottom to top.
struct MixSettings: Codable, Equatable {
    var on = false
    var headA = 1
    var headB = 2
    /// Share of head A in percent (fixed blend), or at the bottom (gradient).
    var shareA = 50.0
    /// Share of head A at the top (gradient only).
    var shareATop = 10.0
    var gradient = false
    var sublayer = false
    /// Objects that print in the blend; empty = all.
    var objects: Set<UUID> = []

    func applies(to id: UUID) -> Bool { objects.isEmpty || objects.contains(id) }

    /// The colour the blend gives, roughly: the two colours mixed by share.
    static func blend(_ a: String, _ b: String, shareA: Double) -> String {
        func rgb(_ h: String) -> (Double, Double, Double)? {
            let s = h.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            guard s.count >= 6, let v = Int(s.prefix(6), radix: 16) else { return nil }
            return (Double((v >> 16) & 255), Double((v >> 8) & 255), Double(v & 255))
        }
        guard let ca = rgb(a), let cb = rgb(b) else { return "" }
        let t = max(0, min(1, shareA / 100))
        // Mixed in linear light, closer to how stacked layers look than sRGB.
        func lin(_ c: Double) -> Double { pow(c / 255, 2.2) }
        func back(_ c: Double) -> Int { Int((pow(c, 1 / 2.2) * 255).rounded()) }
        let r = back(lin(ca.0) * t + lin(cb.0) * (1 - t))
        let g = back(lin(ca.1) * t + lin(cb.1) * (1 - t))
        let bl = back(lin(ca.2) * t + lin(cb.2) * (1 - t))
        return String(format: "%02X%02X%02X", r, g, bl)
    }
}

// MARK: filament ids

/// OrcaSlicer's filament_id: "OF" + 6 base62 digits of
/// uuid5(namespace, "filament_product/<vendor>/<type>/<name>") — one id per
/// spool product, shared by all its printer variants (docs/HLSD/filament_id.md).
enum OrcaFilamentID {
    private static let namespace: [UInt8] = [0xc4, 0xd3, 0xff, 0x49, 0x4c, 0x32, 0x55, 0x34,
                                             0xa3, 0xe3, 0x00, 0x89, 0x41, 0x57, 0xab, 0x97]
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    static func mint(vendor: String, type: String, name: String) -> String {
        var h = Insecure.SHA1()
        h.update(data: namespace)
        h.update(data: Data("filament_product/\(vendor)/\(type)/\(name)".utf8))
        var b = Array(h.finalize().prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        let m: UInt64 = 56_800_235_584          // 62^6
        var r: UInt64 = 0
        for x in b { r = (r * 256 + UInt64(x)) % m }
        var s = ""
        for _ in 0..<6 { s = String(alphabet[Int(r % 62)]) + s; r /= 62 }
        return "OF" + s
    }

    /// The ids the spool in a head may carry, from what the printer reports
    /// (maker, material, sub-type) — in the spellings the profiles use.
    static func candidates(vendor: String, type: String, subtype: String, vendorSpellings: [String]) -> Set<String> {
        var out = Set<String>()
        let t = type.trimmingCharacters(in: .whitespaces)
        let sub = subtype.trimmingCharacters(in: .whitespaces)
        var baseType = t.uppercased()
        while baseType.hasSuffix("+") { baseType.removeLast() }
        for v in Set([vendor] + vendorSpellings) where !v.isEmpty {
            for ty in Set([t, baseType]) where !ty.isEmpty {
                var names = ["\(v) \(t)", "\(v) \(baseType)"]
                if !sub.isEmpty { names += ["\(v) \(t) \(sub)", "\(v) \(baseType) \(sub)", "\(v) \(t)\(sub)"] }
                for n in names { out.insert(mint(vendor: v, type: ty, name: n)) }
            }
        }
        return out
    }

    /// "GEEETECH" ≈ "Geeetech" ≈ "Geeetec": letters and digits, lower case.
    static func normalisedVendor(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }
    static func sameVendor(_ a: String, _ b: String) -> Bool {
        let x = normalisedVendor(a), y = normalisedVendor(b)
        guard x.count >= 3, y.count >= 3, x != "none", y != "none" else { return false }
        return x.hasPrefix(y) || y.hasPrefix(x)
    }
}

// MARK: colour mixing per object (set in the plate's "Head" tool)

/// An object printed by its own head and a second one taking turns
/// (OrcaSlicer 2.5 "mixed filament"). `share` is the own head's part in
/// percent — at the bottom when it is a gradient, `shareTop` at the top.
nonisolated struct ObjectMix: Codable, Equatable, Hashable {
    var head: Int
    var share = 50.0
    var shareTop = 50.0
    var gradient = false
    var sublayer = false

    /// What the blend looks like, roughly: the two colours mixed in linear
    /// light (stacked thin layers read like that from a distance).
    static func blend(_ a: SIMD4<Float>, _ b: SIMD4<Float>, share: Double) -> SIMD4<Float> {
        let t = Float(max(0, min(1, share / 100)))
        func lin(_ c: Float) -> Float { pow(max(c, 0), 2.2) }
        func back(_ c: Float) -> Float { pow(max(c, 0), 1 / 2.2) }
        return SIMD4(back(lin(a.x) * t + lin(b.x) * (1 - t)),
                     back(lin(a.y) * t + lin(b.y) * (1 - t)),
                     back(lin(a.z) * t + lin(b.z) * (1 - t)), 1)
    }
    static func blend(_ a: UIColor, _ b: UIColor, share: Double) -> UIColor {
        func v(_ c: UIColor) -> SIMD4<Float> {
            var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, al: CGFloat = 0
            c.getRed(&r, green: &g, blue: &bl, alpha: &al)
            return SIMD4(Float(r), Float(g), Float(bl), 1)
        }
        let m = blend(v(a), v(b), share: share)
        return UIColor(red: CGFloat(m.x), green: CGFloat(m.y), blue: CGFloat(m.z), alpha: 1)
    }
}
