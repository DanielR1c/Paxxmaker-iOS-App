import SwiftUI

// MARK: - The slice screen's layout, as the user arranges it
//
// The screen used to be a fixed list of sections. Now every setting is an
// entry with an OrcaSlicer key, and the layout says which group it sits in
// and in which order — the default layout is exactly what the screen showed
// before. "Profiles" at the top and "Result" at the bottom are not part of
// it: they are the way in and the way out and stay where they are.
//
// Beyond the settings the screen always had, the catalogue offers the rest of
// what OrcaSlicer's command line understands. PaxxMaker-Connect passes any key
// it does not know itself straight through as `--key=value`, so a setting
// added here needs no new version of the app on the computer — only one that
// is new enough to forward unknown keys.

/// OrcaSlicer's words may stay English while the app speaks another language
/// (Settings live in the slicer tab: "OrcaSlicer language").
func orcaLz(en: String, de: String, fr: String, es: String, pt: String? = nil, it: String? = nil, zh: String? = nil) -> String {
    UserDefaults.standard.string(forKey: "orca_language") == "en" ? en : lz(en: en, de: de, fr: fr, es: es, pt: pt, it: it, zh: zh)
}

/// How one setting is edited.
enum SliceKind {
    case toggle
    case stepper(ClosedRange<Int>)
    case percent                      // slider 0…100, sent as "15%"
    case decimal(String)              // free number with a unit
    case choice([(String, String)])   // Orca's value + what it is called
    case text
}

struct SliceOption: Identifiable {
    let key: String                   // OrcaSlicer's own key
    let title: String
    let kind: SliceKind
    /// Group it lands in when it is switched on in the editor.
    let group: String
    /// OrcaSlicer's own category, shown in the editor's list.
    var category: String = ""
    var id: String { key }
}

enum SliceCatalog {
    static let quality  = "quality"
    static let strength = "strength"
    static let support  = "support"
    static let brim     = "brim"
    static let other    = "other"
    static let speed    = "speed"
    static let surface  = "surface"
    static let tower    = "tower"

    static func groupTitle(_ id: String) -> String {
        switch id {
        case quality:  return orcaLz(en: "Quality", de: "Qualität", fr: "Qualité", es: "Calidad", pt: "Qualidade", it: "Qualità", zh: "质量")
        case strength: return orcaLz(en: "Strength", de: "Stärke", fr: "Résistance", es: "Resistencia", pt: "Resistência", it: "Resistenza", zh: "强度")
        case support:  return "Support"
        case brim:     return orcaLz(en: "Brim & skirt", de: "Rand & Skirt", fr: "Bordure & jupe", es: "Borde y falda", pt: "Borda e saia", it: "Brim e skirt", zh: "裙边与 Brim")
        case other:    return orcaLz(en: "Others", de: "Sonstiges", fr: "Autres", es: "Otros", pt: "Outros", it: "Altro", zh: "其他")
        case speed:    return orcaLz(en: "Speed", de: "Geschwindigkeit", fr: "Vitesse", es: "Velocidad", pt: "Velocidade", it: "Velocità", zh: "速度")
        case surface:  return orcaLz(en: "Surface", de: "Oberfläche", fr: "Surface", es: "Superficie", pt: "Superfície", it: "Superficie", zh: "表面")
        case tower:    return orcaLz(en: "Multi-material", de: "Mehrfarbig", fr: "Multi-matériaux", es: "Multimaterial", pt: "Multimaterial", it: "Multimateriale", zh: "多材料")
        default:       return id
        }
    }

    /// The settings the screen has always had; they keep their own rows.
    static let builtInKeys: Set<String> = [
        "layer_height", "initial_layer_print_height", "seam_position",
        "wall_loops", "top_shell_layers", "bottom_shell_layers", "sparse_infill_density", "sparse_infill_pattern",
        "enable_support", "support_type", "support_on_build_plate_only", "support_threshold_angle",
        "brim_type", "brim_width", "brim_object_gap", "skirt_loops",
        "spiral_mode", "print_sequence",
    ]

    /// The rows the screen has always had — these keep the app's own wording
    /// and their own look.
    static let builtIn: [SliceOption] = [
        SliceOption(key: "layer_height", title: orcaLz(en: "Layer height", de: "Layerhöhe", fr: "Hauteur de couche", es: "Altura de capa", pt: "Altura de camada", it: "Altezza layer", zh: "层高"), kind: .decimal("mm"), group: quality),
        SliceOption(key: "initial_layer_print_height", title: orcaLz(en: "First layer height", de: "Erste Layerhöhe", fr: "Hauteur 1re couche", es: "Altura 1.ª capa", pt: "Altura 1.ª camada", it: "Altezza 1° layer", zh: "首层层高"), kind: .decimal("mm"), group: quality),
        SliceOption(key: "seam_position", title: orcaLz(en: "Seam", de: "Naht", fr: "Couture", es: "Costura", pt: "Costura", it: "Cucitura", zh: "接缝"), kind: .choice(QuickSettings.seams), group: quality),
        SliceOption(key: "wall_loops", title: orcaLz(en: "Walls", de: "Wände", fr: "Parois", es: "Paredes", pt: "Paredes", it: "Pareti", zh: "墙"), kind: .stepper(1...10), group: strength),
        SliceOption(key: "top_shell_layers", title: orcaLz(en: "Top layers", de: "Obere Schichten", fr: "Couches sup.", es: "Capas superiores", pt: "Camadas superiores", it: "Layer superiori", zh: "顶层"), kind: .stepper(0...15), group: strength),
        SliceOption(key: "bottom_shell_layers", title: orcaLz(en: "Bottom layers", de: "Untere Schichten", fr: "Couches inf.", es: "Capas inferiores", pt: "Camadas inferiores", it: "Layer inferiori", zh: "底层"), kind: .stepper(0...15), group: strength),
        SliceOption(key: "sparse_infill_density", title: orcaLz(en: "Infill", de: "Infill", fr: "Remplissage", es: "Relleno", pt: "Preenchimento", it: "Riempimento", zh: "填充"), kind: .percent, group: strength),
        SliceOption(key: "sparse_infill_pattern", title: orcaLz(en: "Infill pattern", de: "Infill-Muster", fr: "Motif", es: "Patrón", pt: "Padrão", it: "Motivo", zh: "填充图案"), kind: .choice(QuickSettings.patterns), group: strength),
        SliceOption(key: "enable_support", title: orcaLz(en: "Enable support", de: "Support aktivieren", fr: "Activer les supports", es: "Activar soportes", pt: "Ativar suportes", it: "Attiva supporti", zh: "启用支撑"), kind: .toggle, group: support),
        SliceOption(key: "support_type", title: orcaLz(en: "Type", de: "Art", fr: "Type", es: "Tipo", pt: "Tipo", it: "Tipo", zh: "类型"), kind: .choice([("tree(auto)", orcaLz(en: "Tree", de: "Baum", fr: "Arbre", es: "Árbol", pt: "Árvore", it: "Albero", zh: "树状")), ("normal(auto)", "Normal")]), group: support),
        SliceOption(key: "support_on_build_plate_only", title: orcaLz(en: "On build plate only", de: "Nur auf Druckbett", fr: "Sur le plateau uniquement", es: "Solo sobre la cama", pt: "Somente na mesa", it: "Solo sul piano", zh: "仅在打印板上"), kind: .toggle, group: support),
        SliceOption(key: "support_threshold_angle", title: orcaLz(en: "Threshold angle", de: "Schwellwinkel", fr: "Angle seuil", es: "Ángulo umbral", pt: "Ângulo limite", it: "Angolo soglia", zh: "临界角"), kind: .stepper(0...90), group: support),
        SliceOption(key: "brim_type", title: orcaLz(en: "Brim type", de: "Rand-Typ", fr: "Type de bordure", es: "Tipo de borde", pt: "Tipo de borda", it: "Tipo di brim", zh: "Brim 类型"), kind: .choice(QuickSettings.brims), group: brim),
        SliceOption(key: "brim_width", title: orcaLz(en: "Brim width", de: "Randbreite", fr: "Largeur", es: "Ancho", pt: "Largura", it: "Larghezza", zh: "宽度"), kind: .decimal("mm"), group: brim),
        SliceOption(key: "brim_object_gap", title: orcaLz(en: "Brim-object gap", de: "Abstand zum Objekt", fr: "Écart objet", es: "Separación", pt: "Distância", it: "Distanza", zh: "与模型间距"), kind: .decimal("mm"), group: brim),
        SliceOption(key: "skirt_loops", title: orcaLz(en: "Skirt loops", de: "Skirt-Schleifen", fr: "Boucles de jupe", es: "Vueltas de falda", pt: "Voltas da saia", it: "Giri skirt", zh: "裙边圈数"), kind: .stepper(0...10), group: brim),
        SliceOption(key: "spiral_mode", title: orcaLz(en: "Spiral vase", de: "Spiralvase", fr: "Vase spirale", es: "Vaso en espiral", pt: "Vaso espiral", it: "Vaso a spirale", zh: "螺旋花瓶"), kind: .toggle, group: other),
        SliceOption(key: "print_sequence", title: orcaLz(en: "Print sequence", de: "Druckreihenfolge", fr: "Ordre d'impression", es: "Secuencia", pt: "Sequência", it: "Sequenza", zh: "打印顺序"), kind: .choice([("by layer", orcaLz(en: "By layer", de: "Nach Layer", fr: "Par couche", es: "Por capa", pt: "Por camada", it: "Per layer", zh: "逐层")), ("by object", orcaLz(en: "By object", de: "Nach Objekt", fr: "Par objet", es: "Por objeto", pt: "Por objeto", it: "Per oggetto", zh: "逐个"))]), group: other),
    ]

    /// Worth offering even when the chosen profile does not mention them.
    /// Their names, units and choices come from OrcaSlicer itself.
    private static let suggested = [
        "wall_generator", "wall_sequence", "detect_thin_wall", "detect_overhang_wall", "reduce_crossing_wall",
        "infill_combination", "infill_direction", "minimum_sparse_infill_area",
        "top_surface_pattern", "bottom_surface_pattern", "ironing_type", "ironing_flow", "ironing_spacing", "ironing_speed",
        "fuzzy_skin", "fuzzy_skin_thickness", "fuzzy_skin_point_distance",
        "line_width", "initial_layer_line_width", "outer_wall_line_width", "inner_wall_line_width",
        "top_surface_line_width", "sparse_infill_line_width", "elefant_foot_compensation",
        "xy_hole_compensation", "xy_contour_compensation", "precise_outer_wall", "enable_arc_fitting", "resolution",
        "outer_wall_speed", "inner_wall_speed", "sparse_infill_speed", "internal_solid_infill_speed",
        "top_surface_speed", "initial_layer_speed", "travel_speed", "bridge_speed", "gap_infill_speed", "support_speed",
        "support_style", "support_top_z_distance", "support_bottom_z_distance", "support_object_xy_distance",
        "support_interface_top_layers", "support_interface_bottom_layers", "support_interface_spacing",
        "support_base_pattern", "tree_support_branch_angle", "raft_layers",
        "skirt_distance", "skirt_height", "draft_shield",
        "enable_prime_tower", "prime_tower_width", "prime_tower_brim_width", "flush_into_infill", "flush_into_objects",
        "timelapse_type", "gcode_comments",
    ]

    /// OrcaSlicer's categories, onto the groups this screen starts with.
    private static func group(forCategory c: String) -> String {
        switch c {
        case "Quality", "Layers and Perimeters": return quality
        case "Strength":                          return strength
        case "Support":                           return support
        case "Speed":                             return speed
        case "Extruders", "Flush options":        return tower
        default:                                  return other
        }
    }

    /// One setting, named and typed the way OrcaSlicer does it; without an
    /// entry there, the profile's own value decides how it is edited.
    static func option(for key: String, profileValue: String?) -> SliceOption {
        if let b = builtIn.first(where: { $0.key == key }) { return b }
        if let d = OrcaOptions.def(key) {
            let unit = OrcaOptions.tr(d.unit)
            let kind: SliceKind
            switch d.type {
            case "coBool":
                kind = .toggle
            case "coEnum" where !d.values.isEmpty:
                kind = .choice(zip(d.values, d.valueLabels).map { ($0, OrcaOptions.tr($1)) })
            case "coInt" where d.min != nil && d.max != nil && (d.max! - d.min!) <= 60:
                kind = .stepper(Int(d.min!)...Int(d.max!))
            case "coFloat", "coInt":
                kind = .decimal(unit)
            default:
                // Percent and "mm or %" carry their own spelling in the value.
                kind = .text
            }
            return SliceOption(key: key, title: OrcaOptions.tr(d.label), kind: kind,
                               group: group(forCategory: d.category), category: OrcaOptions.tr(d.category))
        }
        let v = profileValue ?? ""
        let kind: SliceKind
        if v == "0" || v == "1" { kind = .toggle }
        else if v.hasSuffix("%"), Double(v.dropLast()) != nil { kind = .text }
        else if Double(v) != nil { kind = .decimal("") }
        else { kind = .text }
        return SliceOption(key: key, title: prettify(key), kind: kind, group: other)
    }

    /// Everything the editor can offer: the built-in rows, the suggestions and
    /// every other setting the chosen process profile carries.
    static func all(extraKeys: [String: String]) -> [SliceOption] {
        var keys = Set(suggested)
        for (k, v) in extraKeys where usable(key: k, value: v) { keys.insert(k) }
        keys.subtract(builtInKeys)
        let rest = keys.sorted().map { option(for: $0, profileValue: extraKeys[$0]) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return builtIn + rest
    }

    /// Bookkeeping fields and whole G-code blocks are not settings.
    private static func usable(key: String, value: String) -> Bool {
        guard !value.isEmpty, !value.contains("\n"), value.count < 40,
              !key.hasPrefix("compatible_"), !key.hasSuffix("_settings_id"), !key.contains("gcode") || value.count < 12,
              !["name", "from", "inherits", "version", "type", "instantiation", "is_custom_defined"].contains(key)
        else { return false }
        return true
    }

    /// "outer_wall_acceleration" → "Outer wall acceleration".
    static func prettify(_ key: String) -> String {
        let words = key.split(separator: "_").map(String.init)
        guard let first = words.first else { return key }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }
}

// MARK: - The arrangement itself

struct SliceLayout: Codable, Equatable {
    struct Group: Codable, Equatable, Identifiable {
        var id: String
        /// Empty for the built-in groups — those are named in the app's language.
        var title: String = ""
        var keys: [String]
    }
    var groups: [Group]

    func title(of g: Group) -> String { g.title.isEmpty ? SliceCatalog.groupTitle(g.id) : g.title }

    /// Which group a setting currently sits in.
    func group(of key: String) -> Group? { groups.first { $0.keys.contains(key) } }
    var usedKeys: Set<String> { Set(groups.flatMap(\.keys)) }

    mutating func add(_ key: String, to groupID: String) {
        remove(key)
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[i].keys.append(key)
    }
    mutating func remove(_ key: String) {
        for i in groups.indices { groups[i].keys.removeAll { $0 == key } }
    }

    /// What the screen showed before it could be arranged.
    static let standard = SliceLayout(groups: [
        Group(id: SliceCatalog.quality,  keys: ["layer_height", "initial_layer_print_height", "seam_position"]),
        Group(id: SliceCatalog.strength, keys: ["wall_loops", "top_shell_layers", "bottom_shell_layers", "sparse_infill_density", "sparse_infill_pattern"]),
        Group(id: SliceCatalog.support,  keys: ["enable_support", "support_type", "support_on_build_plate_only", "support_threshold_angle"]),
        Group(id: SliceCatalog.brim,     keys: ["brim_type", "brim_width", "brim_object_gap", "skirt_loops"]),
        Group(id: SliceCatalog.other,    keys: ["spiral_mode", "fuzzy_skin", "print_sequence"]),
    ])

    private static let storageKey = "slice_layout_v1"

    static func load() -> SliceLayout {
        guard let d = UserDefaults.standard.data(forKey: storageKey),
              let l = try? JSONDecoder().decode(SliceLayout.self, from: d), !l.groups.isEmpty else { return standard }
        return l
    }
    func save() {
        if self == Self.standard { UserDefaults.standard.removeObject(forKey: Self.storageKey); return }
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.storageKey) }
    }
}

// MARK: - The editor

struct SliceLayoutEditor: View {
    @Binding var layout: SliceLayout
    /// Everything that can be shown, including the keys found in the profile.
    let options: [SliceOption]
    @Environment(\.dismiss) private var dismiss
    @AppStorage("app_language") private var appLanguage: String = "en"
    @State private var search = ""
    @State private var newGroup = ""
    @State private var confirmReset = false

    private func option(_ key: String) -> SliceOption? { options.first { $0.key == key } }

    private var matches: [SliceOption] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return options.filter { $0.title.lowercased().contains(q) || $0.key.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !search.isEmpty {
                    searchResults
                } else {
                    groupList
                    newGroupRow
                    Section {
                        Button(role: .destructive) { confirmReset = true } label: {
                            Text(lz(en: "Reset to the standard layout", de: "Auf Standard-Aufbau zurücksetzen", fr: "Rétablir la disposition standard", es: "Restablecer la disposición estándar", pt: "Repor a disposição padrão", it: "Ripristina la disposizione standard", zh: "恢复标准布局"))
                        }
                        .confirmationDialog(lz(en: "Discard your arrangement?", de: "Eigenen Aufbau verwerfen?", fr: "Abandonner ta disposition ?", es: "¿Descartar tu disposición?", pt: "Descartar a sua disposição?", it: "Scartare la tua disposizione?", zh: "放弃你的布局？"),
                                            isPresented: $confirmReset, titleVisibility: .visible) {
                            Button(lz(en: "Reset", de: "Zurücksetzen", fr: "Rétablir", es: "Restablecer", pt: "Repor", it: "Ripristina", zh: "恢复"), role: .destructive) { layout = .standard }
                            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {}
                        }
                    }
                }
            }
            .keyboardDismissable()
            .navigationTitle(lz(en: "Edit screen", de: "Seite bearbeiten", fr: "Modifier la page", es: "Editar la página", pt: "Editar a página", it: "Modifica pagina", zh: "编辑页面"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: lz(en: "Find a setting", de: "Einstellung suchen", fr: "Chercher un réglage", es: "Buscar un ajuste", pt: "Procurar um ajuste", it: "Cerca un'impostazione", zh: "查找设置"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button(lz(en: "Done", de: "Fertig", fr: "OK", es: "Listo", pt: "OK", it: "Fine", zh: "完成")) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder private var groupList: some View {
        Section {
            ForEach($layout.groups) { $g in
                NavigationLink {
                    SliceGroupPage(group: $g, layout: $layout, options: options)
                } label: {
                    HStack {
                        Text(layout.title(of: g))
                        Spacer()
                        Text("\(g.keys.count)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onMove { from, to in layout.groups.move(fromOffsets: from, toOffset: to) }
            .onDelete { idx in layout.groups.remove(atOffsets: idx) }
        } header: {
            Text(lz(en: "Groups", de: "Gruppen", fr: "Groupes", es: "Grupos", pt: "Grupos", it: "Gruppi", zh: "分组"))
        } footer: {
            Text(lz(en: "Arrange the middle of the slice screen: order, groups and which settings are shown. Profiles stays at the top and Result at the bottom — those two are not part of it.",
                    de: "Hier bestimmst du die Mitte der Slice-Seite: Reihenfolge, Gruppen und welche Einstellungen sichtbar sind. Profile bleibt oben und Ergebnis unten — die beiden gehören nicht dazu.",
                    fr: "Organise le milieu de la page de tranchage : ordre, groupes et réglages affichés. Profils reste en haut et Résultat en bas — ces deux-là n'en font pas partie.",
                    es: "Organiza el centro de la página de laminado: orden, grupos y qué ajustes se ven. Perfiles queda arriba y Resultado abajo: esos dos no forman parte.",
                    pt: "Organize o meio da página de fatiamento: ordem, grupos e quais ajustes aparecem. Perfis fica em cima e Resultado embaixo — esses dois não fazem parte.",
                    it: "Organizza il centro della pagina di slicing: ordine, gruppi e impostazioni visibili. Profili resta in alto e Risultato in basso — quei due non ne fanno parte.",
                    zh: "在这里安排切片页面的中间部分：顺序、分组以及显示哪些设置。“配置”固定在最上方、“结果”固定在最下方，这两者不在其中。"))
        }
    }

    @ViewBuilder private var newGroupRow: some View {
        Section {
            HStack {
                TextField(lz(en: "New group", de: "Neue Gruppe", fr: "Nouveau groupe", es: "Nuevo grupo", pt: "Novo grupo", it: "Nuovo gruppo", zh: "新建分组"), text: $newGroup)
                Button {
                    let name = newGroup.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    layout.groups.append(.init(id: UUID().uuidString, title: name, keys: []))
                    newGroup = ""
                } label: { Image(systemName: "plus.circle.fill") }
                .disabled(newGroup.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    @ViewBuilder private var searchResults: some View {
        Section {
            ForEach(matches) { o in
                Button {
                    if layout.group(of: o.key) != nil {
                        layout.remove(o.key)
                    } else {
                        // Into its own group when that exists, else the last one.
                        let target = layout.groups.first { $0.id == o.group }?.id ?? layout.groups.last?.id
                        if let target { layout.add(o.key, to: target) }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(o.title).foregroundStyle(Color.primary)
                            Text(layout.group(of: o.key).map { layout.title(of: $0) }
                                 ?? lz(en: "hidden", de: "ausgeblendet", fr: "masqué", es: "oculto", pt: "oculto", it: "nascosto", zh: "已隐藏"))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: layout.group(of: o.key) != nil ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(layout.group(of: o.key) != nil ? Color.accentColor : Color.secondary)
                    }
                }
            }
        } header: {
            Text("\(matches.count) " + lz(en: "settings", de: "Einstellungen", fr: "réglages", es: "ajustes", pt: "ajustes", it: "impostazioni", zh: "项设置"))
        } footer: {
            Text(lz(en: "Tap to show or hide. A setting that is switched on lands in its own group.",
                    de: "Antippen blendet ein oder aus. Eine eingeschaltete Einstellung landet in ihrer Gruppe.",
                    fr: "Touche pour afficher ou masquer. Un réglage activé rejoint son groupe.",
                    es: "Toca para mostrar u ocultar. Un ajuste activado va a su grupo.",
                    pt: "Toque para mostrar ou ocultar. Um ajuste ativado vai para o seu grupo.",
                    it: "Tocca per mostrare o nascondere. Un'impostazione attivata finisce nel suo gruppo.",
                    zh: "点击以显示或隐藏。启用的设置会进入它所属的分组。"))
        }
    }
}

/// One group: rename it, sort its settings, take some out, add others.
struct SliceGroupPage: View {
    @Binding var group: SliceLayout.Group
    @Binding var layout: SliceLayout
    let options: [SliceOption]
    @AppStorage("app_language") private var appLanguage: String = "en"
    @State private var adding = false

    private func title(_ key: String) -> String {
        options.first { $0.key == key }?.title ?? SliceCatalog.prettify(key)
    }

    var body: some View {
        List {
            Section {
                TextField(SliceCatalog.groupTitle(group.id),
                          text: Binding(get: { group.title }, set: { group.title = $0 }))
            } header: {
                Text(lz(en: "Name", de: "Name", fr: "Nom", es: "Nombre", pt: "Nome", it: "Nome", zh: "名称"))
            }
            Section {
                ForEach(group.keys, id: \.self) { key in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(key))
                        Text(key).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .onMove { from, to in group.keys.move(fromOffsets: from, toOffset: to) }
                .onDelete { idx in group.keys.remove(atOffsets: idx) }
                if group.keys.isEmpty {
                    Text(lz(en: "No settings yet — add some with +.", de: "Noch keine Einstellungen — mit + hinzufügen.", fr: "Aucun réglage — ajoute-en avec +.", es: "Sin ajustes todavía: añade con +.", pt: "Ainda sem ajustes — adicione com +.", it: "Ancora nessuna impostazione — aggiungi con +.", zh: "还没有设置——用 + 添加。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text(lz(en: "Settings", de: "Einstellungen", fr: "Réglages", es: "Ajustes", pt: "Ajustes", it: "Impostazioni", zh: "设置"))
            } footer: {
                Text(lz(en: "Drag to reorder, swipe to take out.", de: "Ziehen zum Sortieren, wischen zum Entfernen.", fr: "Glisse pour trier, balaie pour retirer.", es: "Arrastra para ordenar, desliza para quitar.", pt: "Arraste para ordenar, deslize para remover.", it: "Trascina per ordinare, scorri per rimuovere.", zh: "拖动排序，滑动移除。"))
            }
        }
        .environment(\.editMode, .constant(.active))
        .keyboardDismissable()
        .navigationTitle(layout.title(of: group))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $adding) {
            SliceOptionPicker(options: options, layout: $layout, groupID: group.id)
        }
    }
}

/// Searchable list of everything that can be added to a group.
struct SliceOptionPicker: View {
    let options: [SliceOption]
    @Binding var layout: SliceLayout
    let groupID: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage("app_language") private var appLanguage: String = "en"
    @State private var search = ""

    private var shown: [SliceOption] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? options : options.filter { $0.title.lowercased().contains(q) || $0.key.lowercased().contains(q) }
        return list.sorted { a, b in
            let au = layout.usedKeys.contains(a.key), bu = layout.usedKeys.contains(b.key)
            if au != bu { return !au }          // what is not in use yet first
            return a.title < b.title
        }
    }

    var body: some View {
        NavigationStack {
            List(shown) { o in
                Button {
                    layout.add(o.key, to: groupID)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(o.title).foregroundStyle(Color.primary)
                            Text(o.category.isEmpty ? o.key : o.category + " · " + o.key)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let g = layout.group(of: o.key) {
                            Text(layout.title(of: g)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: lz(en: "Find a setting", de: "Einstellung suchen", fr: "Chercher un réglage", es: "Buscar un ajuste", pt: "Procurar um ajuste", it: "Cerca un'impostazione", zh: "查找设置"))
            .keyboardDismissable()
            .navigationTitle(lz(en: "Add setting", de: "Einstellung hinzufügen", fr: "Ajouter un réglage", es: "Añadir ajuste", pt: "Adicionar ajuste", it: "Aggiungi impostazione", zh: "添加设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消")) { dismiss() }
                }
            }
        }
    }
}

/// Long press on a setting that no longer matches the profile: the question
/// opens right on that row, not somewhere else on the screen. It runs
/// alongside the row's own control, so a slider or a stepper keeps working.
struct ResetOnLongPress: ViewModifier {
    let armed: Bool
    let title: String
    let action: () -> Void

    func body(content: Content) -> some View {
        if armed {
            content.contextMenu {
                Section(title) {
                    Button(role: .destructive) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        action()
                    } label: {
                        Label(lz(en: "Reset to the profile value", de: "Auf Profilwert zurücksetzen", fr: "Rétablir la valeur du profil", es: "Restablecer al valor del perfil", pt: "Repor o valor do perfil", it: "Ripristina il valore del profilo", zh: "恢复为配置中的数值"),
                              systemImage: "arrow.uturn.backward")
                    }
                }
            }
        } else {
            content
        }
    }
}


extension View {
    /// Swiping the list down puts the keyboard away again, and every keyboard
    /// gets a "Done" key — the number pad has none of its own.
    func keyboardDismissable() -> some View {
        self.scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(lz(en: "Done", de: "Fertig", fr: "OK", es: "Listo", pt: "OK", it: "Fine", zh: "完成")) {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    .font(.body.weight(.semibold))
                }
            }
    }
}
