import SwiftUI
import simd

// MARK: - Saved plates
//
// A plate can be put away and picked up later, and there can be several of
// them side by side. One folder per project holds a small description and the
// models themselves as STL — the same bytes that go to the slicer, so the
// triangles keep their numbers and the painting still fits after reloading.
//
//   <Application Support>/PaxxMakerPlates/<id>/project.json
//                                             /obj_0.stl …

struct PlateProject: Codable, Identifiable {
    struct Object: Codable {
        var file: String
        var name: String
        var rotation: [Float]          // x, y, z, w
        var scale: [Float]
        var offset: [Float]
        var extruder: Int
        var settings: QuickSettings?
        /// Painted faces, as the undo snapshots hold them.
        var paint: [String: PaintSelector.Snap]?
    }
    var id: String
    var name: String
    var printerID: String
    var modified: Date
    var towerEnabled: Bool
    var towerPos: [Float]?
    var objects: [Object]

    var objectCount: Int { objects.count }
}

enum PlateStore {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaxxMakerPlates", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Newest first.
    static func list() -> [PlateProject] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { read($0.lastPathComponent) }.sorted { $0.modified > $1.modified }
    }

    static func read(_ id: String) -> PlateProject? {
        let url = root.appendingPathComponent(id).appendingPathComponent("project.json")
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(PlateProject.self, from: d)
    }

    static func delete(_ id: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id))
    }

    static func rename(_ id: String, to name: String) {
        update(id) { $0.name = name }
    }

    /// A saved plate belongs to a printer — that is the one it opens on.
    static func setPrinter(_ id: String, to printerID: String) {
        update(id) { $0.printerID = printerID }
    }

    private static func update(_ id: String, _ change: (inout PlateProject) -> Void) {
        guard var p = read(id) else { return }
        change(&p)
        p.modified = Date()
        try? write(p)
    }

    private static func write(_ p: PlateProject) throws {
        let dir = root.appendingPathComponent(p.id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(p).write(to: dir.appendingPathComponent("project.json"), options: .atomic)
    }

    /// Writes the plate; `id` keeps an existing project, nil starts a new one.
    @discardableResult
    static func save(plate: PlateModel, printerID: String, name: String, id: String? = nil) throws -> PlateProject {
        let pid = id ?? UUID().uuidString
        let dir = root.appendingPathComponent(pid, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Models that are no longer on the plate should not stay behind.
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension.lowercased() == "stl" {
            try? FileManager.default.removeItem(at: f)
        }
        var objects: [PlateProject.Object] = []
        for (i, o) in plate.objects.enumerated() {
            let file = "obj_\(i).stl"
            try o.mesh.stlData.write(to: dir.appendingPathComponent(file), options: .atomic)
            let r = o.rotation.vector
            var paint: [String: PaintSelector.Snap]? = nil
            let snaps = o.paintSnapshot
            if !snaps.isEmpty { paint = Dictionary(uniqueKeysWithValues: snaps.map { (String($0.key), $0.value) }) }
            objects.append(.init(file: file, name: o.name,
                                 rotation: [r.x, r.y, r.z, r.w],
                                 scale: [o.scale.x, o.scale.y, o.scale.z],
                                 offset: [o.offset.x, o.offset.y],
                                 extruder: o.extruder, settings: o.settings, paint: paint))
        }
        let project = PlateProject(id: pid, name: name, printerID: printerID, modified: Date(),
                                   towerEnabled: plate.towerEnabled,
                                   towerPos: plate.towerPos.map { [$0.x, $0.y] },
                                   objects: objects)
        try write(project)
        return project
    }

    /// Rebuilds the plate from a saved project.
    static func load(_ project: PlateProject, bed: BedSize) -> PlateModel? {
        let dir = root.appendingPathComponent(project.id, isDirectory: true)
        let plate = PlateModel(bed: bed)
        for o in project.objects {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(o.file)),
                  var mesh = try? STLParser.parse(data), mesh.triangleCount > 0 else { continue }
            mesh.name = o.name
            plate.add(mesh)
            guard let placed = plate.objects.last else { continue }
            if o.rotation.count == 4 {
                placed.rotation = simd_quatf(ix: o.rotation[0], iy: o.rotation[1], iz: o.rotation[2], r: o.rotation[3])
            }
            if o.scale.count == 3 { placed.scale = SIMD3(o.scale[0], o.scale[1], o.scale[2]) }
            if o.offset.count == 2 { placed.offset = SIMD2(o.offset[0], o.offset[1]) }
            placed.extruder = o.extruder
            placed.settings = o.settings
            if let paint = o.paint, !paint.isEmpty {
                placed.restorePaint(Dictionary(uniqueKeysWithValues: paint.compactMap { k, v in
                    Int32(k).map { ($0, v) }
                }))
            }
        }
        guard !plate.objects.isEmpty else { return nil }
        plate.towerEnabled = project.towerEnabled
        if let t = project.towerPos, t.count == 2 { plate.towerPos = SIMD2(t[0], t[1]) }
        plate.selectedID = plate.objects.first?.id
        return plate
    }

    /// A name to offer when saving for the first time: the first model.
    static func suggestedName(for plate: PlateModel) -> String {
        let first = plate.objects.first?.name ?? "Plate"
        return plate.objects.count > 1 ? "\(first) +\(plate.objects.count - 1)" : first
    }
}

// MARK: - The list on the slicer page

struct PlateProjectRow: View {
    let project: PlateProject
    /// Name of the printer the plate is assigned to, when it still exists.
    var printerName: String? = nil
    @AppStorage("app_language") private var appLanguage: String = "en"

    private var subtitle: String {
        let one = lz(en: "object", de: "Objekt", fr: "objet", es: "objeto", pt: "objeto", it: "oggetto", zh: "个对象")
        let many = lz(en: "objects", de: "Objekte", fr: "objets", es: "objetos", pt: "objetos", it: "oggetti", zh: "个对象")
        var parts = ["\(project.objectCount) " + (project.objectCount == 1 ? one : many)]
        parts.append(project.modified.formatted(date: .abbreviated, time: .shortened))
        if let printerName, !printerName.isEmpty { parts.append(printerName) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack {
            Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Asks for a name — used for "Save as" and for renaming.
struct PlateNameAlert: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var text: String
    let title: String
    let action: (String) -> Void
    @AppStorage("app_language") private var appLanguage: String = "en"

    func body(content: Content) -> some View {
        content.alert(title, isPresented: $isPresented) {
            TextField(lz(en: "Name", de: "Name", fr: "Nom", es: "Nombre", pt: "Nome", it: "Nome", zh: "名称"), text: $text)
            Button(lz(en: "Save", de: "Speichern", fr: "Enregistrer", es: "Guardar", pt: "Guardar", it: "Salva", zh: "保存")) {
                let n = text.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { action(n) }
            }
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {}
        }
    }
}

extension View {
    func plateNameAlert(_ title: String, isPresented: Binding<Bool>, text: Binding<String>,
                        action: @escaping (String) -> Void) -> some View {
        modifier(PlateNameAlert(isPresented: isPresented, text: text, title: title, action: action))
    }
}

// MARK: - Is there a newer PaxxMaker-Connect?
//
// The paired computer reports the version it runs. Which version is current is
// stated right here and travels with an app update — the app asks no server,
// so nothing goes out over the internet for this.
//
// ** When a new PaxxMaker-Connect is released, raise `current`. **

enum ConnectUpdate {
    /// The newest PaxxMaker-Connect this app knows about.
    static let current = "1.3"
    static let releasesURL = "https://github.com/DanielR1c/PaxxMaker-Connect/releases/latest"

    struct Release { let version: String; let url: String }

    /// Set when the computer runs an older version than the one above.
    static func newer(than installed: String?) -> Release? {
        guard let installed, !installed.isEmpty, compare(current, installed) > 0 else { return nil }
        return Release(version: current, url: releasesURL)
    }

    /// "1.4" against "1.3.2", number by number.
    static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] {
            s.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}

/// Name and printer of a saved plate.
struct PlateProjectEditor: View {
    let project: PlateProject
    /// Called with the new name and printer id.
    var onSave: (String, String) -> Void
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("app_language") private var appLanguage: String = "en"
    @State private var name: String
    @State private var printerID: String

    init(project: PlateProject, onSave: @escaping (String, String) -> Void) {
        self.project = project
        self.onSave = onSave
        _name = State(initialValue: project.name)
        _printerID = State(initialValue: project.printerID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(lz(en: "Name", de: "Name", fr: "Nom", es: "Nombre", pt: "Nome", it: "Nome", zh: "名称"), text: $name)
                }
                Section {
                    Picker(lz(en: "Printer", de: "Drucker", fr: "Imprimante", es: "Impresora", pt: "Impressora", it: "Stampante", zh: "打印机"), selection: $printerID) {
                        ForEach(settings.printers) { p in
                            Label(p.name, systemImage: p.type.icon).tag(p.id.uuidString)
                        }
                    }
                } footer: {
                    Text(lz(en: "The plate opens on this printer, with its build volume.",
                            de: "Die Druckplatte öffnet sich auf diesem Drucker, mit dessen Druckraum.",
                            fr: "Le plateau s'ouvre sur cette imprimante, avec son volume.",
                            es: "La placa se abre en esta impresora, con su volumen.",
                            pt: "A mesa abre nesta impressora, com o volume dela.",
                            it: "Il piano si apre su questa stampante, con il suo volume.",
                            zh: "该打印板将在这台打印机上打开，并使用它的打印空间。"))
                }
                Section {
                    LabeledContent(lz(en: "Objects", de: "Objekte", fr: "Objets", es: "Objetos", pt: "Objetos", it: "Oggetti", zh: "对象"), value: "\(project.objectCount)")
                    LabeledContent(lz(en: "Last change", de: "Zuletzt geändert", fr: "Dernière modification", es: "Último cambio", pt: "Última alteração", it: "Ultima modifica", zh: "最后修改"),
                                   value: project.modified.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .keyboardDismissable()
            .navigationTitle(lz(en: "Saved plate", de: "Gespeicherte Druckplatte", fr: "Plateau enregistré", es: "Placa guardada", pt: "Mesa guardada", it: "Piano salvato", zh: "已保存的打印板"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(lz(en: "Done", de: "Fertig", fr: "OK", es: "Listo", pt: "OK", it: "Fine", zh: "完成")) {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        onSave(n.isEmpty ? project.name : n, printerID)
                        dismiss()
                    }
                }
            }
        }
    }
}
