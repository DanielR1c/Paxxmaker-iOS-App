import SwiftUI

// MARK: - Build volumes of common printers, and telling which one Klipper runs on.
// Klipper itself has no notion of a printer model, but three things usually
// name it: the header comment of printer.cfg ("# This file contains pin
// mappings for the Creality Ender-3 S1 …"), the machine's hostname and the
// name the user gave the printer in PaxxMaker. The list below is matched
// against those; the axis travel Klipper reports settles size variants
// (Voron 250/300/350). The user can always pick from the list or type the
// values.

enum PrinterVolumes {
    struct Known: Identifiable, Hashable {
        let vendor: String
        let model: String
        let x: Float, y: Float, z: Float
        /// Lower-case, letters and digits only; longest match wins.
        let aliases: [String]
        var id: String { vendor + " " + model }
        var label: String { vendor + " " + model }
        var bed: BedSize { BedSize(x: x, y: y, z: z) }
        var sizeText: String { String(format: "%.0f × %.0f × %.0f mm", x, y, z) }

        init(_ vendor: String, _ model: String, _ x: Float, _ y: Float, _ z: Float, _ aliases: [String]) {
            self.vendor = vendor; self.model = model; self.x = x; self.y = y; self.z = z
            self.aliases = aliases.map(PrinterVolumes.normalize)
        }
    }

    static let all: [Known] = [
        // Voron (Z as in the stock configs)
        Known("Voron", "0 (V0.1 / V0.2)", 120, 120, 120, ["voron0", "v0.1", "v0.2", "v01", "v02"]),
        Known("Voron", "Trident 250", 250, 250, 250, ["trident250", "trident"]),
        Known("Voron", "Trident 300", 300, 300, 250, ["trident300", "trident"]),
        Known("Voron", "Trident 350", 350, 350, 250, ["trident350", "trident"]),
        Known("Voron", "2.4 250", 250, 250, 230, ["voron24250", "v24250", "voron250", "voron24", "voron2", "v24"]),
        Known("Voron", "2.4 300", 300, 300, 280, ["voron24300", "v24300", "voron300", "voron24", "voron2", "v24"]),
        Known("Voron", "2.4 350", 350, 350, 330, ["voron24350", "v24350", "voron350", "voron24", "voron2", "v24"]),
        Known("Voron", "Switchwire", 250, 210, 210, ["switchwire", "vsw"]),
        // Prusa
        Known("Prusa", "MINI / MINI+", 180, 180, 180, ["prusamini", "minip"]),
        Known("Prusa", "MK3S / MK3S+", 250, 210, 210, ["mk3s", "mk3", "i3mk3"]),
        Known("Prusa", "MK4 / MK4S", 250, 210, 220, ["mk4s", "mk4"]),
        Known("Prusa", "Core One", 250, 220, 270, ["coreone", "core1"]),
        Known("Prusa", "XL", 360, 360, 360, ["prusaxl"]),
        // Creality
        Known("Creality", "Ender-3 / Pro / V2 / Neo", 220, 220, 250, ["ender3", "ender3pro", "ender3v2", "ender3neo", "ender3v2neo"]),
        Known("Creality", "Ender-3 V3 SE", 220, 220, 250, ["ender3v3se"]),
        Known("Creality", "Ender-3 V3 KE", 220, 220, 240, ["ender3v3ke"]),
        Known("Creality", "Ender-3 V3", 220, 220, 250, ["ender3v3"]),
        Known("Creality", "Ender-3 V3 Plus", 300, 300, 330, ["ender3v3plus"]),
        Known("Creality", "Ender-3 S1 / S1 Pro", 220, 220, 270, ["ender3s1", "ender3s1pro"]),
        Known("Creality", "Ender-3 S1 Plus", 300, 300, 300, ["ender3s1plus"]),
        Known("Creality", "Ender-3 Max", 300, 300, 340, ["ender3max"]),
        Known("Creality", "Ender-3 Max Neo", 300, 300, 320, ["ender3maxneo"]),
        Known("Creality", "Ender-5 / Pro", 220, 220, 300, ["ender5", "ender5pro"]),
        Known("Creality", "Ender-5 Plus", 350, 350, 400, ["ender5plus"]),
        Known("Creality", "Ender-5 S1", 220, 220, 280, ["ender5s1"]),
        Known("Creality", "Ender-6", 250, 250, 400, ["ender6"]),
        Known("Creality", "Ender-7", 250, 250, 300, ["ender7"]),
        Known("Creality", "CR-10 / V2 / V3 / S", 300, 300, 400, ["cr10", "cr10v2", "cr10v3", "cr10s"]),
        Known("Creality", "CR-10S Pro / V2", 300, 300, 400, ["cr10spro"]),
        Known("Creality", "CR-10 Smart / Smart Pro", 300, 300, 400, ["cr10smart"]),
        Known("Creality", "CR-10 SE", 220, 220, 265, ["cr10se"]),
        Known("Creality", "CR-10 Max", 450, 450, 470, ["cr10max"]),
        Known("Creality", "CR-6 SE", 235, 235, 250, ["cr6se", "cr6"]),
        Known("Creality", "CR-6 Max", 400, 400, 400, ["cr6max"]),
        Known("Creality", "CR-20 / Pro", 220, 220, 250, ["cr20"]),
        Known("Creality", "CR-M4", 450, 450, 470, ["crm4"]),
        Known("Creality", "K1 / K1C / K1 SE", 220, 220, 250, ["k1", "k1c", "k1se", "crealityk1"]),
        Known("Creality", "K1 Max", 300, 300, 300, ["k1max"]),
        Known("Creality", "K2 Plus", 350, 350, 350, ["k2plus"]),
        Known("Creality", "Hi", 260, 260, 300, ["crealityhi"]),
        Known("Creality", "Sermoon V1 / V1 Pro", 175, 175, 165, ["sermoonv1", "sermoon"]),
        // Sovol
        Known("Sovol", "SV01 / SV01 Pro", 280, 240, 300, ["sv01"]),
        Known("Sovol", "SV02", 240, 220, 300, ["sv02"]),
        Known("Sovol", "SV03", 350, 350, 400, ["sv03"]),
        Known("Sovol", "SV04", 300, 300, 400, ["sv04"]),
        Known("Sovol", "SV05", 220, 220, 300, ["sv05"]),
        Known("Sovol", "SV06 / SV06 Ace", 220, 220, 250, ["sv06", "sv06ace"]),
        Known("Sovol", "SV06 Plus", 300, 300, 340, ["sv06plus"]),
        Known("Sovol", "SV07", 220, 220, 250, ["sv07"]),
        Known("Sovol", "SV07 Plus", 300, 300, 350, ["sv07plus"]),
        Known("Sovol", "SV08", 350, 350, 345, ["sv08"]),
        Known("Sovol", "Zero", 152, 153, 170, ["sovolzero"]),
        // Snapmaker
        Known("Snapmaker", "U1", 270, 270, 270, ["snapmakeru1", "u1"]),
        Known("Snapmaker", "J1 / J1s", 300, 200, 200, ["snapmakerj1", "j1s", "j1"]),
        Known("Snapmaker", "Artisan", 400, 400, 400, ["artisan"]),
        Known("Snapmaker", "2.0 A150", 160, 160, 145, ["a150"]),
        Known("Snapmaker", "2.0 A250 / A250T", 230, 250, 235, ["a250"]),
        Known("Snapmaker", "2.0 A350 / A350T", 320, 350, 330, ["a350"]),
        // Anycubic
        Known("Anycubic", "Kobra / Kobra Go / Neo", 220, 220, 250, ["kobra", "kobrago", "kobraneo"]),
        Known("Anycubic", "Kobra 2 / Neo / Pro", 220, 220, 250, ["kobra2", "kobra2neo", "kobra2pro"]),
        Known("Anycubic", "Kobra 2 Plus", 320, 320, 400, ["kobra2plus"]),
        Known("Anycubic", "Kobra 2 Max", 420, 420, 500, ["kobra2max"]),
        Known("Anycubic", "Kobra 3 / Combo", 250, 250, 260, ["kobra3", "kobra3combo"]),
        Known("Anycubic", "Kobra 3 Max", 420, 420, 500, ["kobra3max"]),
        Known("Anycubic", "Kobra S1", 250, 250, 250, ["kobras1"]),
        Known("Anycubic", "Kobra Plus", 300, 300, 350, ["kobraplus"]),
        Known("Anycubic", "Kobra Max", 400, 400, 450, ["kobramax"]),
        Known("Anycubic", "Vyper", 245, 245, 260, ["vyper"]),
        Known("Anycubic", "i3 Mega / Mega S / Mega Pro", 210, 210, 205, ["i3mega", "megas", "megapro", "anycubicmega"]),
        Known("Anycubic", "Mega X", 300, 300, 305, ["megax"]),
        Known("Anycubic", "Chiron", 400, 400, 450, ["chiron"]),
        Known("Anycubic", "4Max Pro / 2.0", 270, 210, 190, ["4maxpro", "4max"]),
        // Bambu Lab
        Known("Bambu Lab", "A1 mini", 180, 180, 180, ["a1mini"]),
        Known("Bambu Lab", "A1", 256, 256, 256, ["bambua1", "bambulaba1"]),
        Known("Bambu Lab", "P1P / P1S", 256, 256, 256, ["p1p", "p1s"]),
        Known("Bambu Lab", "X1 / X1C / X1E", 256, 256, 256, ["x1c", "x1e", "x1carbon", "bambux1"]),
        Known("Bambu Lab", "H2D", 350, 320, 325, ["h2d"]),
        // Elegoo
        Known("Elegoo", "Neptune 2 / 2S / 2D", 220, 220, 250, ["neptune2"]),
        Known("Elegoo", "Neptune 3", 220, 220, 280, ["neptune3"]),
        Known("Elegoo", "Neptune 3 Pro", 225, 225, 280, ["neptune3pro"]),
        Known("Elegoo", "Neptune 3 Plus", 320, 320, 400, ["neptune3plus"]),
        Known("Elegoo", "Neptune 3 Max", 420, 420, 500, ["neptune3max"]),
        Known("Elegoo", "Neptune 4 / 4 Pro", 225, 225, 265, ["neptune4", "neptune4pro"]),
        Known("Elegoo", "Neptune 4 Plus", 320, 320, 385, ["neptune4plus"]),
        Known("Elegoo", "Neptune 4 Max", 420, 420, 480, ["neptune4max"]),
        Known("Elegoo", "Centauri / Centauri Carbon", 256, 256, 256, ["centauri", "centauricarbon"]),
        Known("Elegoo", "OrangeStorm Giga", 800, 800, 1000, ["orangestorm", "giga"]),
        // QIDI
        Known("QIDI", "X-Smart 3", 175, 180, 170, ["xsmart3"]),
        Known("QIDI", "X-Plus 3", 280, 280, 270, ["xplus3"]),
        Known("QIDI", "X-Max 3", 325, 325, 315, ["xmax3"]),
        Known("QIDI", "Q1 Pro", 245, 245, 240, ["q1pro"]),
        Known("QIDI", "Plus 4", 305, 305, 280, ["qidiplus4", "plus4"]),
        Known("QIDI", "X-Plus / X-Plus 2", 270, 200, 200, ["xplus"]),
        Known("QIDI", "X-Max / X-CF Pro", 300, 250, 300, ["xmax", "xcfpro"]),
        // Flashforge
        Known("Flashforge", "Adventurer 3", 150, 150, 150, ["adventurer3"]),
        Known("Flashforge", "Adventurer 4", 220, 200, 250, ["adventurer4"]),
        Known("Flashforge", "Adventurer 5M / 5M Pro / AD5X", 220, 220, 220, ["adventurer5m", "ad5m", "ad5x"]),
        Known("Flashforge", "Creator Pro 2", 200, 148, 150, ["creatorpro2"]),
        Known("Flashforge", "Guider 2s", 280, 250, 300, ["guider2"]),
        // Artillery
        Known("Artillery", "Sidewinder X1 / X2", 300, 300, 400, ["sidewinderx1", "sidewinderx2", "sidewinder"]),
        Known("Artillery", "Sidewinder X3 Pro", 240, 240, 260, ["sidewinderx3pro", "x3pro"]),
        Known("Artillery", "Sidewinder X3 Plus", 300, 300, 400, ["sidewinderx3plus", "x3plus"]),
        Known("Artillery", "Genius / Genius Pro", 220, 220, 250, ["genius"]),
        Known("Artillery", "Hornet", 220, 220, 250, ["hornet"]),
        // Rat Rig
        Known("Rat Rig", "V-Minion", 180, 180, 180, ["vminion", "minion"]),
        Known("Rat Rig", "V-Core 3 / 4 300", 300, 300, 300, ["vcore3300", "vcore4300", "vcore300", "vcore3", "vcore4", "vcore"]),
        Known("Rat Rig", "V-Core 3 / 4 400", 400, 400, 400, ["vcore3400", "vcore4400", "vcore400", "vcore3", "vcore4", "vcore"]),
        Known("Rat Rig", "V-Core 3 / 4 500", 500, 500, 500, ["vcore3500", "vcore4500", "vcore500", "vcore3", "vcore4", "vcore"]),
        // Others
        Known("Kingroon", "KP3S", 180, 180, 180, ["kp3s"]),
        Known("Kingroon", "KP3S Pro", 200, 200, 200, ["kp3spro"]),
        Known("Kingroon", "KP5L", 300, 300, 330, ["kp5l"]),
        Known("Two Trees", "Sapphire Pro / Plus", 235, 235, 235, ["sapphirepro", "sapphire"]),
        Known("Two Trees", "SK1", 256, 256, 256, ["twotreessk1", "sk1"]),
        Known("Two Trees", "SP-5", 300, 300, 330, ["sp5"]),
        Known("Tronxy", "X5SA", 330, 330, 400, ["x5sa"]),
        Known("Tronxy", "X5SA-400", 400, 400, 400, ["x5sa400"]),
        Known("Tronxy", "X5SA-500", 500, 500, 600, ["x5sa500"]),
        Known("FLSUN", "Q5 (Delta)", 200, 200, 200, ["flsunq5", "q5"]),
        Known("FLSUN", "QQ-S Pro (Delta)", 255, 255, 360, ["qqspro", "qqs"]),
        Known("FLSUN", "Super Racer (Delta)", 260, 260, 330, ["superracer", "flsunsr"]),
        Known("FLSUN", "V400 (Delta)", 300, 300, 410, ["v400"]),
        Known("FLSUN", "T1 (Delta)", 260, 260, 330, ["flsunt1"]),
        Known("BIQU", "B1", 235, 235, 270, ["biqub1"]),
        Known("BIQU", "Hurakan", 235, 235, 270, ["hurakan"]),
        Known("Sunlu", "S9 Plus", 310, 310, 400, ["s9plus"]),
        Known("Sunlu", "T3", 220, 220, 250, ["sunlut3"]),
        Known("Geeetech", "A10 / A10M", 220, 220, 260, ["geeetecha10", "a10m"]),
        Known("Geeetech", "A20 / A20M", 255, 255, 255, ["geeetecha20", "a20m"]),
        Known("Geeetech", "A30", 320, 320, 420, ["geeetecha30"]),
        Known("Longer", "LK4 / LK4 Pro", 220, 220, 250, ["lk4"]),
        Known("Longer", "LK5 Pro", 300, 300, 400, ["lk5"]),
        Known("Wanhao", "D12 230", 230, 230, 250, ["d12230", "wanhaod12"]),
        Known("Mingda", "Magician X", 230, 230, 260, ["magicianx"]),
        Known("Kywoo", "Tycoon", 240, 240, 230, ["tycoon"]),
    ]

    static var vendors: [String] {
        var seen = Set<String>(), out: [String] = []
        for k in all where seen.insert(k.vendor).inserted { out.append(k.vendor) }
        return out
    }

    nonisolated static func normalize(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }

    /// The best-named printer in `text`: the longest alias that occurs wins;
    /// among equals (size variants of one family) the one whose X travel is
    /// closest to what Klipper reports.
    static func match(_ text: String, travel: BedSize?) -> Known? {
        let hay = normalize(text)
        guard !hay.isEmpty else { return nil }
        var best: [Known] = [], bestLen = 0
        for k in all {
            for a in k.aliases where a.count >= 2 && hay.contains(a) {
                if a.count > bestLen { bestLen = a.count; best = [k] }
                else if a.count == bestLen, !best.contains(k) { best.append(k) }
            }
        }
        guard !best.isEmpty else { return nil }
        if best.count > 1, let t = travel {
            return best.min { abs($0.x - t.x) < abs($1.x - t.x) }
        }
        return best.first
    }

    /// Asks the printer what it is: the header of printer.cfg, then the
    /// hostname, then the name in the app. nil when nothing is recognised.
    static func detect(config: PrinterConfig) async -> Known? {
        let travel = BedSize.travel(for: config)
        let base = config.effectiveBaseURL
        let key = config.connectionMode == .octoEverywhere ? config.octoEverywhereAPIKey : ""
        func get(_ path: String, timeout: TimeInterval = 6) async -> Data? {
            guard let url = URL(string: base + path) else { return nil }
            var req = URLRequest(url: url, timeoutInterval: timeout)
            if !key.isEmpty { req.setValue(key, forHTTPHeaderField: "X-Api-Key") }
            return try? await URLSession.shared.data(for: req).0
        }
        if let d = await get("/server/files/config/printer.cfg", timeout: 8), let text = String(data: d, encoding: .utf8) {
            // Klipper's example configs name the printer in the first comment lines.
            let head = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(40).filter { $0.hasPrefix("#") }.joined(separator: " ")
            if let k = match(head, travel: travel) { return k }
        }
        if let d = await get("/printer/info"), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let host = (o["result"] as? [String: Any])?["hostname"] as? String, let k = match(host, travel: travel) {
            return k
        }
        return match(config.name, travel: travel)
    }

    // MARK: stored per printer

    static func modelLabel(for config: PrinterConfig) -> String? {
        UserDefaults.standard.string(forKey: "bed_model_\(config.name)")
    }
    static func setModelLabel(_ label: String?, for config: PrinterConfig) {
        if let label { UserDefaults.standard.set(label, forKey: "bed_model_\(config.name)") }
        else { UserDefaults.standard.removeObject(forKey: "bed_model_\(config.name)") }
    }
    static func hasStoredBed(for config: PrinterConfig) -> Bool {
        UserDefaults.standard.array(forKey: "bed_size_\(config.name)") != nil
    }
}

// MARK: - Picker: the list, automatic detection, or typed values

struct BedSizePicker: View {
    let printer: PrinterConfig
    /// Called with the new size and the model label (nil = typed by hand).
    var onChange: (BedSize, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("app_language") private var appLanguage: String = "en"
    @State private var search = ""
    @State private var x = ""
    @State private var y = ""
    @State private var z = ""
    @State private var detecting = false
    @State private var detected: PrinterVolumes.Known? = nil
    @State private var detectFailed = false

    private var filtered: [PrinterVolumes.Known] {
        let q = PrinterVolumes.normalize(search)
        return q.isEmpty ? PrinterVolumes.all : PrinterVolumes.all.filter { PrinterVolumes.normalize($0.label).contains(q) }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("X", text: $x).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 56)
                    Text("×").foregroundStyle(.secondary)
                    TextField("Y", text: $y).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 56)
                    Text("×").foregroundStyle(.secondary)
                    TextField("Z", text: $z).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 56)
                    Text("mm").foregroundStyle(.secondary)
                    Spacer()
                    Button(lz(en: "Apply", de: "Übernehmen", fr: "Appliquer", es: "Aplicar", pt: "Aplicar", it: "Applica", zh: "应用")) {
                        if let bx = Float(x), let by = Float(y), let bz = Float(z), bx > 10, by > 10, bz > 10 {
                            onChange(BedSize(x: bx, y: by, z: bz), nil); dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
                Button {
                    detecting = true; detectFailed = false; detected = nil
                    Task {
                        let k = await PrinterVolumes.detect(config: printer)
                        detecting = false
                        if let k { detected = k } else { detectFailed = true }
                    }
                } label: {
                    HStack {
                        Label(lz(en: "Detect from printer", de: "Vom Drucker erkennen", fr: "Détecter depuis l'imprimante", es: "Detectar desde la impresora", pt: "Detectar pela impressora", it: "Rileva dalla stampante", zh: "从打印机识别"), systemImage: "wand.and.stars")
                        Spacer()
                        if detecting { ProgressView() }
                    }
                }
                .disabled(detecting)
                if let k = detected {
                    Button {
                        onChange(k.bed, k.label); dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(k.label).foregroundColor(.primary)
                                Text(k.sizeText).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(lz(en: "Use", de: "Übernehmen", fr: "Utiliser", es: "Usar", pt: "Usar", it: "Usa", zh: "使用")).foregroundColor(.accentColor)
                        }
                    }
                }
                if detectFailed {
                    Text(lz(en: "Klipper did not name a known printer — choose it below.", de: "Klipper nennt keinen bekannten Drucker — unten auswählen.", fr: "Klipper ne nomme aucune imprimante connue — choisis-la ci-dessous.", es: "Klipper no nombra ninguna impresora conocida — elígela abajo.", pt: "O Klipper não nomeia nenhuma impressora conhecida — escolha abaixo.", it: "Klipper non indica una stampante nota — scegline una sotto.", zh: "Klipper 未给出已知打印机——请在下方选择。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text(lz(en: "Manual", de: "Manuell", fr: "Manuel", es: "Manual", pt: "Manual", it: "Manuale", zh: "手动"))
            }
            ForEach(PrinterVolumes.vendors, id: \.self) { vendor in
                let items = filtered.filter { $0.vendor == vendor }
                if !items.isEmpty {
                    Section(vendor) {
                        ForEach(items) { k in
                            Button {
                                onChange(k.bed, k.label); dismiss()
                            } label: {
                                HStack {
                                    Text(k.model).foregroundColor(.primary)
                                    Spacer()
                                    Text(k.sizeText).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: lz(en: "Search printer", de: "Drucker suchen", fr: "Chercher une imprimante", es: "Buscar impresora", pt: "Buscar impressora", it: "Cerca stampante", zh: "搜索打印机"))
        .keyboardDismissable()
        .navigationTitle(lz(en: "Build volume", de: "Druckvolumen", fr: "Volume d'impression", es: "Volumen de impresión", pt: "Volume de impressão", it: "Volume di stampa", zh: "打印空间"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let b = BedSize.for(printer)
            x = "\(Int(b.x))"; y = "\(Int(b.y))"; z = "\(Int(b.z))"
        }
    }
}
