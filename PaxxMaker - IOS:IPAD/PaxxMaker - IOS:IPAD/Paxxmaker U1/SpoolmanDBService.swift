import Foundation

// MARK: - SpoolmanDB (community filament database)
// The same open database Spoolman itself uses (https://donkie.github.io/SpoolmanDB).
// ~7000 products, each with the correct empty-spool weight for that specific
// product — so a manufacturer's different spool types (cardboard, plastic,
// refill) all carry their own weight, instead of one unreliable per-brand guess.

struct DBFilament: Decodable, Identifiable, Hashable {
    var manufacturer: String
    var name: String?
    var material: String?
    var density: Double?
    var weight: Double?
    var spool_weight: Double?
    var spool_type: String?
    var diameter: Double?
    var color_hex: String?
    var extruder_temp: Int?
    var bed_temp: Int?

    // Stable identity for lists (not provided uniformly by the DB).
    var id: String { "\(manufacturer)|\(name ?? "")|\(material ?? "")|\(color_hex ?? "")" }

    var display: String {
        var s = manufacturer
        if let m = material { s += " · \(m)" }
        if let n = name, !n.isEmpty { s += " · \(n)" }
        return s
    }
}

actor SpoolmanDB {
    static let shared = SpoolmanDB()
    private var cache: [DBFilament] = []
    private let url = URL(string: "https://donkie.github.io/SpoolmanDB/filaments.json")!
    private var cacheFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("spoolmandb_filaments.json")
    }

    /// Return all products, loading from local cache or the network on demand.
    /// Cache is refreshed if older than 7 days.
    func all() async -> [DBFilament] {
        if !cache.isEmpty { return cache }
        // Try the on-disk cache first (fast, offline-capable).
        if let data = try? Data(contentsOf: cacheFile),
           let list = try? JSONDecoder().decode([DBFilament].self, from: data),
           !list.isEmpty,
           let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
           let mod = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(mod) < 7 * 24 * 3600 {
            cache = list
            return cache
        }
        // Fetch fresh.
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let list = try JSONDecoder().decode([DBFilament].self, from: data)
            cache = list
            try? data.write(to: cacheFile)
            return list
        } catch {
            // Network failed — fall back to any stale disk cache.
            if let data = try? Data(contentsOf: cacheFile),
               let list = try? JSONDecoder().decode([DBFilament].self, from: data) {
                cache = list
                return list
            }
            return []
        }
    }

    /// Full-text-ish search over manufacturer / name / material.
    func search(_ query: String, limit: Int = 60) async -> [DBFilament] {
        let all = await all()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let terms = q.split(separator: " ").map(String.init)
        let matches = all.filter { f in
            let hay = "\(f.manufacturer) \(f.material ?? "") \(f.name ?? "")".lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
        return Array(matches.prefix(limit))
    }

    /// If every product of this manufacturer shares one empty-spool weight,
    /// return it (safe to auto-fill). Nil if the brand uses several spool types.
    func unambiguousSpoolWeight(manufacturer: String) async -> Double? {
        let all = await all()
        let m = manufacturer.trimmingCharacters(in: .whitespaces).lowercased()
        guard !m.isEmpty else { return nil }
        let weights = Set(all.filter { $0.manufacturer.lowercased() == m }
                             .compactMap { $0.spool_weight })
        return weights.count == 1 ? weights.first : nil
    }

    /// Distinct manufacturer names (for suggestions).
    func manufacturers() async -> [String] {
        let all = await all()
        return Array(Set(all.map { $0.manufacturer })).sorted()
    }
}
