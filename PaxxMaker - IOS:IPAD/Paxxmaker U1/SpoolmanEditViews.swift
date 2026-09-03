import SwiftUI

// Shared little helpers
private func numField(_ title: String, _ text: Binding<String>) -> some View {
    HStack {
        Text(title)
        Spacer()
        TextField("—", text: text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 120)
    }
}
private func dbl(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".")) }
private func intv(_ s: String) -> Int? { Int(s) }

// MARK: - Spool detail
struct SpoolDetailView: View {
    @ObservedObject var store: SpoolmanStore
    let spool: SpoolmanSpool
    @Environment(\.dismiss) private var dismiss

    @State private var useAmount = ""
    @State private var showEdit = false
    @State private var showDeleteConfirm = false
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ColorDot(hex: spool.filament.color_hex)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(spool.filament.displayName).font(.headline)
                        if let m = spool.filament.material { Text(m).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let frac = spool.remainingFraction {
                    VStack(alignment: .leading, spacing: 4) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.2))
                                Capsule().fill(frac < 0.1 ? Color.red : frac < 0.25 ? .orange : .green)
                                    .frame(width: g.size.width * frac)
                            }
                        }.frame(height: 8)
                        Text("\(Int(frac * 100)) %").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section(lz(en: "Amounts", de: "Mengen", fr: "Quantités", es: "Cantidades", pt: "Quantidades", it: "Quantità", zh: "数量")) {
                infoRow(lz(en: "Remaining", de: "Verbleibend", fr: "Restant", es: "Restante", pt: "Restante", it: "Rimanente", zh: "剩余"), spool.remaining_weight.map { "\(Int($0)) g" })
                infoRow(lz(en: "Used", de: "Verbraucht", fr: "Utilisé", es: "Usado", pt: "Usado", it: "Usato", zh: "已用"), "\(Int(spool.used_weight)) g")
                infoRow(lz(en: "Remaining length", de: "Restlänge", fr: "Longueur restante", es: "Longitud restante", pt: "Comprimento restante", it: "Lunghezza rimanente", zh: "剩余长度"), spool.remaining_length.map { "\(Int($0/1000)) m" })
                infoRow(lz(en: "Price", de: "Preis", fr: "Prix", es: "Precio", pt: "Preço", it: "Prezzo", zh: "价格"), spool.price.map { String(format: "%.2f", $0) })
                infoRow(lz(en: "Location", de: "Standort", fr: "Emplacement", es: "Ubicación", pt: "Localização", it: "Posizione", zh: "位置"), spool.location)
                infoRow(lz(en: "Lot no.", de: "Chargennr.", fr: "N° de lot", es: "N.º de lote", pt: "N.º do lote", it: "N. lotto", zh: "批号"), spool.lot_nr)
            }

            // Consume filament manually
            Section(lz(en: "Use filament", de: "Filament verbrauchen", fr: "Utiliser du filament", es: "Consumir filamento", pt: "Consumir filamento", it: "Consuma filamento", zh: "消耗耗材")) {
                HStack {
                    TextField(lz(en: "Grams", de: "Gramm", fr: "Grammes", es: "Gramos", pt: "Gramas", it: "Grammi", zh: "克"), text: $useAmount)
                        .keyboardType(.decimalPad)
                    Button(lz(en: "Subtract", de: "Abziehen", fr: "Soustraire", es: "Restar", pt: "Subtrair", it: "Sottrai", zh: "扣除")) {
                        guard let w = dbl(useAmount), w > 0 else { return }
                        Task {
                            busy = true
                            await store.perform { _ = try await $0.useSpool(spool.id, useWeight: w) }
                            busy = false; dismiss()
                        }
                    }
                    .disabled(dbl(useAmount) == nil || busy)
                }
            }

            Section {
                Button {
                    Task { await store.perform { _ = try await $0.updateSpool(spool.id, ["archived": !spool.archived]) }; dismiss() }
                } label: {
                    Label(spool.archived
                          ? lz(en: "Unarchive", de: "Aus Archiv holen", fr: "Désarchiver", es: "Desarchivar", pt: "Desarquivar", it: "Ripristina", zh: "取消归档")
                          : lz(en: "Archive", de: "Archivieren", fr: "Archiver", es: "Archivar", pt: "Arquivar", it: "Archivia", zh: "归档"),
                          systemImage: spool.archived ? "tray.and.arrow.up" : "archivebox")
                }
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Label(lz(en: "Delete spool", de: "Spule löschen", fr: "Supprimer la bobine", es: "Eliminar carrete", pt: "Excluir bobina", it: "Elimina bobina", zh: "删除料盘"), systemImage: "trash")
                }
                // Attach the confirmation to the button itself so it presents
                // from the bottom next to it, not as a popover near the title.
                .confirmationDialog(lz(en: "Delete this spool?", de: "Diese Spule löschen?", fr: "Supprimer cette bobine ?", es: "¿Eliminar este carrete?", pt: "Excluir esta bobina?", it: "Eliminare questa bobina?", zh: "删除此料盘？"), isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                    Button(lz(en: "Delete", de: "Löschen", fr: "Supprimer", es: "Eliminar", pt: "Excluir", it: "Elimina", zh: "删除"), role: .destructive) {
                        Task { await store.perform { try await $0.deleteSpool(spool.id) }; dismiss() }
                    }
                }
            }
        }
        .navigationTitle("#\(spool.id)")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(lz(en: "Edit", de: "Bearbeiten", fr: "Modifier", es: "Editar", pt: "Editar", it: "Modifica", zh: "编辑")) { showEdit = true }
            }
        }
        .sheet(isPresented: $showEdit) { SpoolEditView(store: store, spool: spool) }
    }

    @ViewBuilder private func infoRow(_ t: String, _ v: String?) -> some View {
        if let v, !v.isEmpty {
            HStack { Text(t).foregroundStyle(.secondary); Spacer(); Text(v) }
        }
    }
}

// MARK: - Spool create / edit
struct SpoolEditView: View {
    @ObservedObject var store: SpoolmanStore
    let spool: SpoolmanSpool?
    @Environment(\.dismiss) private var dismiss

    @State private var filamentID: Int?
    @State private var initialWeight = ""
    @State private var spoolWeight = ""
    @State private var price = ""
    @State private var location = ""
    @State private var lotNr = ""
    @State private var comment = ""
    @State private var busy = false

    var body: some View {
        NavigationView {
            Form {
                Section(lz(en: "Filament", de: "Filament", fr: "Filament", es: "Filamento", pt: "Filamento", it: "Filamento", zh: "耗材")) {
                    Picker(lz(en: "Type", de: "Typ", fr: "Type", es: "Tipo", pt: "Tipo", it: "Tipo", zh: "类型"), selection: $filamentID) {
                        Text("—").tag(Int?.none)
                        ForEach(store.filaments) { f in Text(f.displayName).tag(Int?.some(f.id)) }
                    }
                }
                Section {
                    numField(lz(en: "Initial weight (g)", de: "Anfangsgewicht (g)", fr: "Poids initial (g)", es: "Peso inicial (g)", pt: "Peso inicial (g)", it: "Peso iniziale (g)", zh: "初始重量 (g)"), $initialWeight)
                    numField(lz(en: "Empty spool (g)", de: "Leergewicht (g)", fr: "Bobine vide (g)", es: "Carrete vacío (g)", pt: "Bobina vazia (g)", it: "Bobina vuota (g)", zh: "空盘重 (g)"), $spoolWeight)
                    numField(lz(en: "Price", de: "Preis", fr: "Prix", es: "Precio", pt: "Preço", it: "Prezzo", zh: "价格"), $price)
                }
                Section {
                    TextField(lz(en: "Location", de: "Standort", fr: "Emplacement", es: "Ubicación", pt: "Localização", it: "Posizione", zh: "位置"), text: $location)
                    TextField(lz(en: "Lot no.", de: "Chargennr.", fr: "N° de lot", es: "N.º de lote", pt: "N.º do lote", it: "N. lotto", zh: "批号"), text: $lotNr)
                    TextField(lz(en: "Comment", de: "Kommentar", fr: "Commentaire", es: "Comentario", pt: "Comentário", it: "Commento", zh: "备注"), text: $comment)
                }
            }
            .navigationTitle(spool == nil
                             ? lz(en: "New spool", de: "Neue Spule", fr: "Nouvelle bobine", es: "Nuevo carrete", pt: "Nova bobina", it: "Nuova bobina", zh: "新料盘")
                             : lz(en: "Edit spool", de: "Spule bearbeiten", fr: "Modifier bobine", es: "Editar carrete", pt: "Editar bobina", it: "Modifica bobina", zh: "编辑料盘"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(lz(en: "Save", de: "Speichern", fr: "Enregistrer", es: "Guardar", pt: "Salvar", it: "Salva", zh: "保存")) { save() }
                        .disabled(filamentID == nil || busy)
                }
            }
            .onAppear(perform: load)
            // Selecting a filament pre-fills the new spool from it (initial +
            // empty weight + price) — only for new spools, never overwriting an
            // existing spool's own values.
            .onChange(of: filamentID) { _, newID in fillFromFilament(newID) }
        }
        .navigationViewStyle(.stack)
    }

    private func fillFromFilament(_ id: Int?) {
        guard spool == nil, let f = store.filaments.first(where: { $0.id == id }) else { return }
        if let w = f.weight       { initialWeight = String(Int(w)) }
        if let w = f.spool_weight { spoolWeight   = String(Int(w)) }
        if let p = f.price        { price         = String(p) }
    }

    private func load() {
        guard let s = spool else {
            if filamentID == nil {
                filamentID = store.filaments.first?.id
                fillFromFilament(filamentID)
            }
            return
        }
        filamentID = s.filament.id
        initialWeight = s.initial_weight.map { String(Int($0)) } ?? ""
        spoolWeight = s.spool_weight.map { String(Int($0)) } ?? ""
        price = s.price.map { String($0) } ?? ""
        location = s.location ?? ""
        lotNr = s.lot_nr ?? ""
        comment = s.comment ?? ""
    }

    private func save() {
        guard let fid = filamentID else { return }
        var body: [String: Any] = ["filament_id": fid]
        if let v = dbl(initialWeight) { body["initial_weight"] = v }
        if let v = dbl(spoolWeight)  { body["spool_weight"]  = v }
        if let v = dbl(price)        { body["price"]         = v }
        body["location"] = location
        body["lot_nr"]   = lotNr
        body["comment"]  = comment
        busy = true
        Task {
            await store.perform { svc in
                if let s = spool { _ = try await svc.updateSpool(s.id, body) }
                else { _ = try await svc.createSpool(body) }
            }
            busy = false; dismiss()
        }
    }
}

// MARK: - Filament create / edit
struct FilamentEditView: View {
    @ObservedObject var store: SpoolmanStore
    let filament: SpoolmanFilament?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var vendorName = ""
    @State private var material = ""
    @State private var color: Color = .gray
    @State private var price = ""
    @State private var density = "1.24"
    @State private var diameter = "1.75"
    @State private var weight = ""
    @State private var spoolWeight = ""
    @State private var articleNr = ""
    @State private var comment = ""
    @State private var extruderTemp = ""
    @State private var bedTemp = ""
    @State private var showDelete = false
    @State private var busy = false
    @State private var showDBSearch = false
    @StateObject private var nfc = OpenSpoolNFCManager()

    private func applyDB(_ f: DBFilament) {
        if let m = f.material, !m.isEmpty { material = m }
        if !f.manufacturer.isEmpty { vendorName = f.manufacturer }
        if let n = f.name, !n.isEmpty { name = n }
        if let hex = f.color_hex, let c = Color(hex: hex.replacingOccurrences(of: "#", with: "")) { color = c }
        if let d = f.density { density = String(d) }
        if let dia = f.diameter { diameter = String(dia) }
        if let w = f.weight { weight = String(Int(w)) }
        if let sw = f.spool_weight { spoolWeight = String(Int(sw)) }
        if let e = f.extruder_temp { extruderTemp = String(e) }
        if let b = f.bed_temp { bedTemp = String(b) }
    }

    // Build an OpenSpool tag from the current form values (works even before
    // saving). The tag carries the filament identity: color, material, temps.
    private var openSpoolTag: OpenSpoolData {
        var d = OpenSpoolData()
        d.colorHex = color.hexString
        d.type = material.isEmpty ? "PLA" : material
        d.brand = vendorName.isEmpty ? "Generic" : vendorName
        d.name = name
        if let dia = dbl(diameter) { d.diameter = dia }
        if let t = intv(extruderTemp) { d.minTemp = t; d.maxTemp = t }
        if let b = intv(bedTemp) { d.bedMinTemp = b; d.bedMaxTemp = b }
        if let w = intv(weight) { d.weight = w }
        if let p = dbl(price) { d.price = p }
        if let sw = intv(spoolWeight) { d.spoolWeight = sw }
        if let de = dbl(density) { d.density = de }
        d.articleNumber = articleNr
        d.comment = comment
        return d
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Button {
                        showDBSearch = true
                    } label: {
                        Label(lz(en: "Search filament database", de: "Filament-Datenbank durchsuchen", fr: "Rechercher dans la base", es: "Buscar en la base de datos", pt: "Pesquisar na base de dados", it: "Cerca nel database", zh: "搜索耗材数据库"), systemImage: "magnifyingglass")
                    }
                } footer: {
                    Text(lz(en: "Auto-fill weight, density, temperatures and color from ~7000 known products.", de: "Füllt Gewicht, Dichte, Temperaturen und Farbe automatisch aus ~7000 bekannten Produkten.", fr: "Remplit poids, densité, températures et couleur depuis ~7000 produits connus.", es: "Rellena peso, densidad, temperaturas y color desde ~7000 productos.", pt: "Preenche peso, densidade, temperaturas e cor de ~7000 produtos.", it: "Compila peso, densità, temperature e colore da ~7000 prodotti.", zh: "从约 7000 个已知产品自动填充重量、密度、温度和颜色。"))
                }
                Section {
                    TextField(lz(en: "Name", de: "Name", fr: "Nom", es: "Nombre", pt: "Nome", it: "Nome", zh: "名称"), text: $name)
                    TextField(lz(en: "Material (PLA, PETG…)", de: "Material (PLA, PETG…)", fr: "Matériau (PLA, PETG…)", es: "Material (PLA, PETG…)", pt: "Material (PLA, PETG…)", it: "Materiale (PLA, PETG…)", zh: "材料 (PLA, PETG…)"), text: $material)
                    ColorPicker(lz(en: "Color", de: "Farbe", fr: "Couleur", es: "Color", pt: "Cor", it: "Colore", zh: "颜色"), selection: $color, supportsOpacity: false)
                    // Combined field: type a new vendor OR pick a known one from
                    // the dropdown. New names are created automatically on save
                    // and then remembered for the next filament.
                    HStack {
                        TextField(lz(en: "Vendor", de: "Hersteller", fr: "Fabricant", es: "Fabricante", pt: "Fabricante", it: "Produttore", zh: "厂商"), text: $vendorName)
                        if !store.vendors.isEmpty {
                            Menu {
                                ForEach(store.vendors) { v in
                                    Button(v.name) { vendorName = v.name }
                                }
                            } label: {
                                Image(systemName: "chevron.down.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section(lz(en: "Physical", de: "Physik", fr: "Physique", es: "Físico", pt: "Físico", it: "Fisico", zh: "物理")) {
                    numField(lz(en: "Density (g/cm³)", de: "Dichte (g/cm³)", fr: "Densité (g/cm³)", es: "Densidad (g/cm³)", pt: "Densidade (g/cm³)", it: "Densità (g/cm³)", zh: "密度 (g/cm³)"), $density)
                    numField(lz(en: "Diameter (mm)", de: "Durchmesser (mm)", fr: "Diamètre (mm)", es: "Diámetro (mm)", pt: "Diâmetro (mm)", it: "Diametro (mm)", zh: "直径 (mm)"), $diameter)
                    numField(lz(en: "Full weight (g)", de: "Vollgewicht (g)", fr: "Poids plein (g)", es: "Peso lleno (g)", pt: "Peso cheio (g)", it: "Peso pieno (g)", zh: "满卷重 (g)"), $weight)
                    numField(lz(en: "Empty spool (g)", de: "Leergewicht (g)", fr: "Bobine vide (g)", es: "Carrete vacío (g)", pt: "Bobina vazia (g)", it: "Bobina vuota (g)", zh: "空盘重 (g)"), $spoolWeight)
                    numField(lz(en: "Price", de: "Preis", fr: "Prix", es: "Precio", pt: "Preço", it: "Prezzo", zh: "价格"), $price)
                }
                Section(lz(en: "Temperatures", de: "Temperaturen", fr: "Températures", es: "Temperaturas", pt: "Temperaturas", it: "Temperature", zh: "温度")) {
                    numField(lz(en: "Extruder (°C)", de: "Extruder (°C)", fr: "Extrudeur (°C)", es: "Extrusor (°C)", pt: "Extrusora (°C)", it: "Estrusore (°C)", zh: "挤出机 (°C)"), $extruderTemp)
                    numField(lz(en: "Bed (°C)", de: "Bett (°C)", fr: "Plateau (°C)", es: "Cama (°C)", pt: "Mesa (°C)", it: "Piano (°C)", zh: "热床 (°C)"), $bedTemp)
                }
                Section {
                    TextField(lz(en: "Article number", de: "Artikelnummer", fr: "Référence", es: "N.º de artículo", pt: "N.º do artigo", it: "Codice articolo", zh: "货号"), text: $articleNr)
                    TextField(lz(en: "Comment", de: "Kommentar", fr: "Commentaire", es: "Comentario", pt: "Comentário", it: "Commento", zh: "备注"), text: $comment)
                }
                // Write this filament's identity (color, material, temps) to an
                // NFC tag in OpenSpool format for later scanning.
                Section {
                    Button {
                        nfc.write(data: openSpoolTag)
                    } label: {
                        Label(lz(en: "Write to NFC tag", de: "Auf NFC-Tag schreiben", fr: "Écrire sur tag NFC", es: "Escribir en etiqueta NFC", pt: "Gravar em etiqueta NFC", it: "Scrivi su tag NFC", zh: "写入 NFC 标签"), systemImage: "wave.3.right")
                    }
                } footer: {
                    Text(lz(en: "Stores color, material and temperatures on the tag so this filament is recognized when scanned.", de: "Speichert Farbe, Material und Temperaturen auf dem Tag, damit dieses Filament beim Scannen erkannt wird.", fr: "Enregistre couleur, matériau et températures sur le tag pour reconnaître ce filament au scan.", es: "Guarda color, material y temperaturas en la etiqueta para reconocer este filamento al escanear.", pt: "Grava cor, material e temperaturas na etiqueta para reconhecer este filamento ao ler.", it: "Salva colore, materiale e temperature sul tag per riconoscere questo filamento alla scansione.", zh: "将颜色、材料和温度写入标签，扫描时即可识别此耗材。"))
                }
                if filament != nil {
                    Section {
                        Button {
                            commit(duplicate: true)
                        } label: {
                            Label(lz(en: "Duplicate", de: "Duplizieren", fr: "Dupliquer", es: "Duplicar", pt: "Duplicar", it: "Duplica", zh: "复制"), systemImage: "plus.square.on.square")
                        }
                        .disabled(busy)
                        Button(role: .destructive) { showDelete = true } label: {
                            Label(lz(en: "Delete filament", de: "Filament löschen", fr: "Supprimer le filament", es: "Eliminar filamento", pt: "Excluir filamento", it: "Elimina filamento", zh: "删除耗材"), systemImage: "trash")
                        }
                        // Attach the confirmation to the button so it pops up
                        // next to it, not as a popover at the top.
                        .confirmationDialog(lz(en: "Delete this filament?", de: "Dieses Filament löschen?", fr: "Supprimer ce filament ?", es: "¿Eliminar este filamento?", pt: "Excluir este filamento?", it: "Eliminare questo filamento?", zh: "删除此耗材？"), isPresented: $showDelete, titleVisibility: .visible) {
                            Button(lz(en: "Delete", de: "Löschen", fr: "Supprimer", es: "Eliminar", pt: "Excluir", it: "Elimina", zh: "删除"), role: .destructive) {
                                if let f = filament { Task { await store.perform { try await $0.deleteFilament(f.id) }; dismiss() } }
                            }
                        }
                    }
                }
            }
            .navigationTitle(filament == nil
                             ? lz(en: "New filament", de: "Neues Filament", fr: "Nouveau filament", es: "Nuevo filamento", pt: "Novo filamento", it: "Nuovo filamento", zh: "新耗材")
                             : lz(en: "Edit filament", de: "Filament bearbeiten", fr: "Modifier filament", es: "Editar filamento", pt: "Editar filamento", it: "Modifica filamento", zh: "编辑耗材"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(lz(en: "Save", de: "Speichern", fr: "Enregistrer", es: "Guardar", pt: "Salvar", it: "Salva", zh: "保存")) { save() }.disabled(busy)
                }
            }
            .onAppear(perform: load)
            // Picking a known vendor auto-fills the empty spool weight the
            // vendor was last saved with, so you don't retype it per filament.
            .onChange(of: vendorName) { _, newName in
                let trimmed = newName.trimmingCharacters(in: .whitespaces).lowercased()
                // 1) A vendor already in Spoolman remembers its empty weight.
                if let v = store.vendors.first(where: { $0.name.lowercased() == trimmed }),
                   let w = v.empty_spool_weight {
                    spoolWeight = String(Int(w))
                    return
                }
                // 2) Otherwise ask SpoolmanDB — only auto-fill if that brand uses
                //    a single spool weight across all its products (unambiguous).
                let brand = newName
                Task {
                    if let w = await SpoolmanDB.shared.unambiguousSpoolWeight(manufacturer: brand),
                       spoolWeight.isEmpty {
                        await MainActor.run { spoolWeight = String(Int(w)) }
                    }
                }
            }
            .sheet(isPresented: $showDBSearch) {
                FilamentDBSearchView { picked in applyDB(picked) }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func load() {
        guard let f = filament else {
            // New filament: pre-fill the most common full-spool weight.
            if weight.isEmpty { weight = "1000" }
            return
        }
        name = f.name ?? ""
        vendorName = f.vendor?.name ?? ""
        material = f.material ?? ""
        if let hex = f.color_hex, let c = Color(hex: hex.replacingOccurrences(of: "#", with: "")) { color = c }
        price = f.price.map { String($0) } ?? ""
        density = String(f.density)
        diameter = String(f.diameter)
        weight = f.weight.map { String(Int($0)) } ?? ""
        spoolWeight = f.spool_weight.map { String(Int($0)) } ?? ""
        articleNr = f.article_number ?? ""
        comment = f.comment ?? ""
        extruderTemp = f.settings_extruder_temp.map { String($0) } ?? ""
        bedTemp = f.settings_bed_temp.map { String($0) } ?? ""
    }

    private func filamentBody() -> [String: Any] {
        var body: [String: Any] = [
            "density": dbl(density) ?? 1.24,
            "diameter": dbl(diameter) ?? 1.75,
            "color_hex": color.hexString,
        ]
        body["name"] = name
        body["material"] = material
        if let v = dbl(price) { body["price"] = v }
        if let v = dbl(weight) { body["weight"] = v }
        if let v = dbl(spoolWeight) { body["spool_weight"] = v }
        if let v = intv(extruderTemp) { body["settings_extruder_temp"] = v }
        if let v = intv(bedTemp) { body["settings_bed_temp"] = v }
        body["article_number"] = articleNr
        body["comment"] = comment
        return body
    }

    private func save() { commit(duplicate: false) }

    // Shared writer for Save and Duplicate. `duplicate: true` always creates a
    // brand-new filament (with a "(Copy)" name), never updates the original.
    private func commit(duplicate: Bool) {
        var body = filamentBody()
        if duplicate {
            let base = (body["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? material
            body["name"] = base + " " + lz(en: "(Copy)", de: "(Kopie)", fr: "(Copie)", es: "(Copia)", pt: "(Cópia)", it: "(Copia)", zh: "（副本）")
        }
        busy = true
        let wantedVendor = vendorName.trimmingCharacters(in: .whitespaces)
        let emptyW = dbl(spoolWeight)
        Task {
            await store.perform { svc in
                // Resolve the vendor name → existing id, or create a new vendor.
                // The empty spool weight is stored ON the vendor so it becomes a
                // remembered default for the next filament of the same brand.
                if !wantedVendor.isEmpty {
                    if let existing = store.vendors.first(where: { $0.name.lowercased() == wantedVendor.lowercased() }) {
                        body["vendor_id"] = existing.id
                        if let w = emptyW, existing.empty_spool_weight != w {
                            _ = try await svc.updateVendor(existing.id, ["empty_spool_weight": w])
                        }
                    } else {
                        var vbody: [String: Any] = ["name": wantedVendor]
                        if let w = emptyW { vbody["empty_spool_weight"] = w }
                        body["vendor_id"] = try await svc.createVendor(vbody).id
                    }
                }
                if let f = filament, !duplicate { _ = try await svc.updateFilament(f.id, body) }
                else { _ = try await svc.createFilament(body) }
            }
            busy = false; dismiss()
        }
    }
}

// MARK: - Vendor create / edit
struct VendorEditView: View {
    @ObservedObject var store: SpoolmanStore
    let vendor: SpoolmanVendor?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var comment = ""
    @State private var showDelete = false
    @State private var busy = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField(lz(en: "Name", de: "Name", fr: "Nom", es: "Nombre", pt: "Nome", it: "Nome", zh: "名称"), text: $name)
                    TextField(lz(en: "Comment", de: "Kommentar", fr: "Commentaire", es: "Comentario", pt: "Comentário", it: "Commento", zh: "备注"), text: $comment)
                }
                if vendor != nil {
                    Section {
                        Button(role: .destructive) { showDelete = true } label: {
                            Label(lz(en: "Delete vendor", de: "Hersteller löschen", fr: "Supprimer le fabricant", es: "Eliminar fabricante", pt: "Excluir fabricante", it: "Elimina produttore", zh: "删除厂商"), systemImage: "trash")
                        }
                        .confirmationDialog(lz(en: "Delete this vendor?", de: "Diesen Hersteller löschen?", fr: "Supprimer ce fabricant ?", es: "¿Eliminar este fabricante?", pt: "Excluir este fabricante?", it: "Eliminare questo produttore?", zh: "删除此厂商？"), isPresented: $showDelete, titleVisibility: .visible) {
                            Button(lz(en: "Delete", de: "Löschen", fr: "Supprimer", es: "Eliminar", pt: "Excluir", it: "Elimina", zh: "删除"), role: .destructive) {
                                if let v = vendor { Task { await store.perform { try await $0.deleteVendor(v.id) }; dismiss() } }
                            }
                        }
                    }
                }
            }
            .navigationTitle(vendor == nil
                             ? lz(en: "New vendor", de: "Neuer Hersteller", fr: "Nouveau fabricant", es: "Nuevo fabricante", pt: "Novo fabricante", it: "Nuovo produttore", zh: "新厂商")
                             : lz(en: "Edit vendor", de: "Hersteller bearbeiten", fr: "Modifier fabricant", es: "Editar fabricante", pt: "Editar fabricante", it: "Modifica produttore", zh: "编辑厂商"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(lz(en: "Save", de: "Speichern", fr: "Enregistrer", es: "Guardar", pt: "Salvar", it: "Salva", zh: "保存")) { save() }.disabled(name.isEmpty || busy)
                }
            }
            .onAppear {
                if let v = vendor {
                    name = v.name; comment = v.comment ?? ""
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func save() {
        let body: [String: Any] = ["name": name, "comment": comment]
        busy = true
        Task {
            await store.perform { svc in
                if let v = vendor { _ = try await svc.updateVendor(v.id, body) }
                else { _ = try await svc.createVendor(body) }
            }
            busy = false; dismiss()
        }
    }
}

// MARK: - NFC → add to Spoolman
// Reads an OpenSpool tag, tries to match an existing filament (material + color),
// otherwise creates the filament from the tag, then creates a spool for it.
struct SpoolmanNFCAddView: View {
    @ObservedObject var store: SpoolmanStore
    // Editable: the scanned values can be corrected/completed before adding.
    @State var tag: OpenSpoolData
    @Environment(\.dismiss) private var dismiss

    @State private var showTagEditor = false
    @State private var existing: SpoolmanSpool? = nil
    @State private var busy = false
    @State private var resultText: String?
    @State private var isError = false

    private var matchedFilament: SpoolmanFilament? {
        let tagColor = tag.normalizedColorHex
        let tagMat = tag.type.uppercased()
        return store.filaments.first { f in
            (f.material?.uppercased() == tagMat) &&
            ((f.color_hex?.replacingOccurrences(of: "#", with: "").uppercased() ?? "") == tagColor)
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section(lz(en: "Scanned tag", de: "Gescanntes Tag", fr: "Tag scanné", es: "Etiqueta escaneada", pt: "Etiqueta lida", it: "Tag letto", zh: "已扫描标签")) {
                    HStack(spacing: 14) {
                        ColorDot(hex: tag.colorHex)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(tag.brand) \(tag.type)\(tag.subtype.isEmpty ? "" : " " + tag.subtype)").font(.headline)
                            Text("\(tag.minTemp)–\(tag.maxTemp) °C · #\(tag.normalizedColorHex)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Button {
                        showTagEditor = true
                    } label: {
                        Label(lz(en: "Edit scanned filament", de: "Gescanntes Filament bearbeiten", fr: "Modifier le filament scanné", es: "Editar filamento escaneado", pt: "Editar filamento lido", it: "Modifica filamento letto", zh: "编辑已扫描耗材"),
                              systemImage: "square.and.pencil")
                    }
                }
                Section {
                    if existing != nil {
                        Label(lz(en: "The scanned values will be written to this spool.", de: "Die gescannten Werte werden auf diese Rolle geschrieben.", fr: "Les valeurs scannées seront écrites sur cette bobine.", es: "Los valores escaneados se escribirán en esta bobina.", pt: "Os valores lidos serão gravados nesta bobina.", it: "I valori letti verranno scritti su questa bobina.", zh: "扫描到的数值将写入此料盘。"), systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(.blue).font(.subheadline)
                    } else if let m = matchedFilament {
                        Label(lz(en: "Matches existing filament: ", de: "Passt zu vorhandenem Filament: ", fr: "Correspond au filament : ", es: "Coincide con filamento: ", pt: "Corresponde ao filamento: ", it: "Corrisponde al filamento: ", zh: "匹配现有耗材：") + m.displayName, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.subheadline)
                        Text(lz(en: "A new spool will be added for this filament.", de: "Für dieses Filament wird eine neue Spule angelegt.", fr: "Une nouvelle bobine sera ajoutée pour ce filament.", es: "Se añadirá un nuevo carrete para este filamento.", pt: "Uma nova bobina será adicionada para este filamento.", it: "Verrà aggiunta una nuova bobina per questo filamento.", zh: "将为此耗材添加一个新料盘。")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label(lz(en: "No matching filament — a new one will be created.", de: "Kein passendes Filament — ein neues wird erstellt.", fr: "Aucun filament correspondant — un nouveau sera créé.", es: "Sin filamento coincidente — se creará uno nuevo.", pt: "Nenhum filamento correspondente — um novo será criado.", it: "Nessun filamento corrispondente — ne verrà creato uno nuovo.", zh: "无匹配耗材——将创建新耗材。"), systemImage: "plus.circle.fill")
                            .foregroundStyle(.blue).font(.subheadline)
                    }
                }
                if let r = resultText {
                    Section { Label(r, systemImage: isError ? "xmark.octagon.fill" : "checkmark.seal.fill").foregroundStyle(isError ? .red : .green).font(.subheadline) }
                }
            }
            .navigationTitle(lz(en: "Add to Spoolman", de: "Zu Spoolman hinzufügen", fr: "Ajouter à Spoolman", es: "Añadir a Spoolman", pt: "Adicionar ao Spoolman", it: "Aggiungi a Spoolman", zh: "添加到 Spoolman"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(lz(en: "Close", de: "Schließen", fr: "Fermer", es: "Cerrar", pt: "Fechar", it: "Chiudi", zh: "关闭")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil
                           ? lz(en: "Add", de: "Hinzufügen", fr: "Ajouter", es: "Añadir", pt: "Adicionar", it: "Aggiungi", zh: "添加")
                           : lz(en: "Update", de: "Aktualisieren", fr: "Mettre à jour", es: "Actualizar", pt: "Atualizar", it: "Aggiorna", zh: "更新")) {
                        if let e = existing { updateExisting(e) } else { add() }
                    }.disabled(busy)
                }
            }
            .task { if store.filaments.isEmpty { await store.reloadAll() } }
            .sheet(isPresented: $showTagEditor) {
                NFCTagEditView(source: tag, store: store) { edited, picked in
                    tag = edited
                    existing = picked
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // Write the scanned tag onto an existing spool: update its filament fields
    // and store the card UID, so the printer recognises it from now on. The
    // spool stays fully editable afterwards.
    private func updateExisting(_ spool: SpoolmanSpool) {
        busy = true; resultText = nil
        Task {
            guard let svc = SpoolmanConfig.service else { busy = false; return }
            do {
                var fbody: [String: Any] = [
                    "material": tag.type,
                    "color_hex": tag.normalizedColorHex,
                ]
                let fallbackName = tag.subtype.isEmpty ? tag.type : "\(tag.type) \(tag.subtype)"
                fbody["name"] = tag.name.isEmpty ? fallbackName : tag.name
                if tag.diameter > 0 { fbody["diameter"] = tag.diameter }
                if tag.density > 0 { fbody["density"] = tag.density }
                if tag.minTemp > 0 { fbody["settings_extruder_temp"] = tag.minTemp }
                if tag.bedMinTemp > 0 { fbody["settings_bed_temp"] = tag.bedMinTemp }
                if !tag.articleNumber.isEmpty { fbody["article_number"] = tag.articleNumber }
                if !tag.comment.isEmpty { fbody["comment"] = tag.comment }
                _ = try await svc.updateFilament(spool.filament.id, fbody)

                var sbody: [String: Any] = [:]
                if tag.weight > 0 { sbody["initial_weight"] = Double(tag.weight) }
                if tag.spoolWeight > 0 { sbody["spool_weight"] = Double(tag.spoolWeight) }
                if tag.price > 0 { sbody["price"] = tag.price }
                if !sbody.isEmpty { _ = try await svc.updateSpool(spool.id, sbody) }

                await store.reloadAll()
                resultText = lz(en: "Spool updated ✓", de: "Rolle aktualisiert ✓", fr: "Bobine mise à jour ✓", es: "Bobina actualizada ✓", pt: "Bobina atualizada ✓", it: "Bobina aggiornata ✓", zh: "料盘已更新 ✓")
                isError = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { dismiss() }
            } catch {
                resultText = (error as? SpoolmanError)?.errorDescription ?? SpoolmanService.localizedTransport(error)
                isError = true
            }
            busy = false
        }
    }

    private func add() {
        busy = true; resultText = nil
        Task {
            guard let svc = SpoolmanConfig.service else { busy = false; return }
            do {
                let filamentID: Int
                if let m = matchedFilament {
                    filamentID = m.id
                } else {
                    // Match / create the vendor by name first
                    var vendorID: Int?
                    if !tag.brand.isEmpty && tag.brand.lowercased() != "generic" {
                        let vendors = try await svc.vendors()
                        if let existing = vendors.first(where: { $0.name.lowercased() == tag.brand.lowercased() }) {
                            vendorID = existing.id
                        } else {
                            vendorID = try await svc.createVendor(["name": tag.brand]).id
                        }
                    }
                    var fbody: [String: Any] = [
                        "material": tag.type,
                        "color_hex": tag.normalizedColorHex,
                        "diameter": tag.diameter,
                        "density": tag.density > 0 ? tag.density : 1.24,
                    ]
                    // Prefer the tag's stored name, else material (+ subtype).
                    let fallbackName = tag.subtype.isEmpty ? tag.type : "\(tag.type) \(tag.subtype)"
                    fbody["name"] = tag.name.isEmpty ? fallbackName : tag.name
                    if let v = vendorID { fbody["vendor_id"] = v }
                    if tag.minTemp > 0 { fbody["settings_extruder_temp"] = tag.minTemp }
                    if tag.bedMinTemp > 0 { fbody["settings_bed_temp"] = tag.bedMinTemp }
                    if tag.weight > 0 { fbody["weight"] = Double(tag.weight) }
                    if tag.spoolWeight > 0 { fbody["spool_weight"] = Double(tag.spoolWeight) }
                    if tag.price > 0 { fbody["price"] = tag.price }
                    if !tag.articleNumber.isEmpty { fbody["article_number"] = tag.articleNumber }
                    if !tag.comment.isEmpty { fbody["comment"] = tag.comment }
                    filamentID = try await svc.createFilament(fbody).id
                }
                var sbody: [String: Any] = ["filament_id": filamentID]
                if tag.weight > 0 { sbody["initial_weight"] = Double(tag.weight) }
                if tag.spoolWeight > 0 { sbody["spool_weight"] = Double(tag.spoolWeight) }
                if tag.price > 0 { sbody["price"] = tag.price }
                _ = try await svc.createSpool(sbody)
                await store.reloadAll()
                resultText = lz(en: "Spool added ✓", de: "Spule hinzugefügt ✓", fr: "Bobine ajoutée ✓", es: "Carrete añadido ✓", pt: "Bobina adicionada ✓", it: "Bobina aggiunta ✓", zh: "已添加料盘 ✓")
                isError = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { dismiss() }
            } catch {
                resultText = (error as? SpoolmanError)?.errorDescription ?? error.localizedDescription
                isError = true
            }
            busy = false
        }
    }
}

// MARK: - SpoolmanDB search
struct FilamentDBSearchView: View {
    let onPick: (DBFilament) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [DBFilament] = []
    @State private var loading = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationView {
            List {
                if loading { HStack { Spacer(); ProgressView(); Spacer() } }
                ForEach(results) { f in
                    Button {
                        onPick(f); dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            ColorDot(hex: f.color_hex)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.display).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                                HStack(spacing: 8) {
                                    if let sw = f.spool_weight { Text("\(lz(en: "Empty", de: "Leer", fr: "Vide", es: "Vacío", pt: "Vazio", it: "Vuoto", zh: "空")): \(Int(sw)) g").font(.caption2).foregroundStyle(.secondary) }
                                    if let t = f.spool_type, !t.isEmpty { Text(t).font(.caption2).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
                if !loading && !query.isEmpty && results.isEmpty {
                    Text(lz(en: "No matches", de: "Keine Treffer", fr: "Aucun résultat", es: "Sin resultados", pt: "Sem resultados", it: "Nessun risultato", zh: "无结果")).foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, prompt: lz(en: "Manufacturer, material, color…", de: "Hersteller, Material, Farbe…", fr: "Fabricant, matériau, couleur…", es: "Fabricante, material, color…", pt: "Fabricante, material, cor…", it: "Produttore, materiale, colore…", zh: "厂商、材料、颜色…"))
            .onChange(of: query) { _, q in
                searchTask?.cancel()
                guard q.trimmingCharacters(in: .whitespaces).count >= 2 else { results = []; return }
                loading = true
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 250_000_000)   // debounce
                    guard !Task.isCancelled else { return }
                    let r = await SpoolmanDB.shared.search(q)
                    if Task.isCancelled { return }
                    await MainActor.run { results = r; loading = false }
                }
            }
            .navigationTitle(lz(en: "Filament database", de: "Filament-Datenbank", fr: "Base de filaments", es: "Base de filamentos", pt: "Base de filamentos", it: "Database filamenti", zh: "耗材数据库"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消")) { dismiss() } } }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - Edit a scanned NFC tag before adding it to Spoolman
// Lets the user correct what the tag reported and fill in the fields Spoolman
// wants but the tag left empty. "OK" hands the edited values back to the add
// sheet; "Write to NFC tag" burns them onto a tag.
struct NFCTagEditView: View {
    let source: OpenSpoolData
    @ObservedObject var store: SpoolmanStore
    var onOK: (OpenSpoolData, SpoolmanSpool?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var d: OpenSpoolData
    @State private var picked: SpoolmanSpool? = nil
    @State private var showSpoolPicker = false
    @StateObject private var nfc = OpenSpoolNFCManager()

    init(source: OpenSpoolData, store: SpoolmanStore, onOK: @escaping (OpenSpoolData, SpoolmanSpool?) -> Void) {
        self.source = source
        self.store = store
        self.onOK = onOK
        _d = State(initialValue: source)
    }

    // Known manufacturers already in Spoolman (plus whatever the tag reported).
    private var vendorOptions: [String] {
        var set = Set(store.vendors.map(\.name))
        set.formUnion(store.filaments.compactMap { $0.vendor?.name })
        set = set.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return set.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // Materials seen in Spoolman first, then the usual suspects.
    private var materialOptions: [String] {
        let common = ["PLA", "PLA+", "PETG", "ABS", "ASA", "TPU", "PC", "PA", "PVA", "HIPS"]
        var seen = Set(store.filaments.compactMap { $0.material }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        var out = seen.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        for c in common where !seen.contains(where: { $0.caseInsensitiveCompare(c) == .orderedSame }) {
            out.append(c); seen.insert(c)
        }
        return out
    }

    private let subtypeOptions = ["Basic", "Matte", "Silk", "Tough", "HF", "CF", "GF", "Glow", "Wood"]

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(hex: d.normalizedColorHex) ?? .orange },
                set: { d.colorHex = $0.hexString })
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Button { showSpoolPicker = true } label: {
                        HStack {
                            Text(lz(en: "Existing spool", de: "Vorhandene Rolle", fr: "Bobine existante", es: "Bobina existente", pt: "Bobina existente", it: "Bobina esistente", zh: "现有料盘"))
                            Spacer()
                            if let p = picked {
                                ColorDot(hex: p.filament.color_hex, size: 14)
                                Text(p.filament.rowTitle).foregroundStyle(.secondary).lineLimit(1)
                            } else {
                                Text(lz(en: "New spool", de: "Neue Rolle", fr: "Nouvelle bobine", es: "Nueva bobina", pt: "Nova bobina", it: "Nuova bobina", zh: "新建料盘"))
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text(lz(en: "Pick a spool to fill in what the tag didn't provide, then adjust below. Scanned values are kept — only empty fields are filled.",
                            de: "Wähle eine Rolle, um zu ergänzen, was das Tag nicht liefert — darunter kannst du alles anpassen. Gescannte Werte bleiben erhalten, nur leere Felder werden gefüllt.",
                            fr: "Choisissez une bobine pour compléter ce que le tag ne fournit pas, puis ajustez ci-dessous. Seuls les champs vides sont remplis.",
                            es: "Elige una bobina para completar lo que la etiqueta no aporta y ajusta abajo. Solo se rellenan campos vacíos.",
                            pt: "Escolha uma bobina para completar o que a etiqueta não traz e ajuste abaixo. Apenas campos vazios são preenchidos.",
                            it: "Scegli una bobina per completare ciò che il tag non fornisce, poi regola sotto. Solo i campi vuoti vengono riempiti.",
                            zh: "选择一个料盘来补全标签未提供的内容，然后在下方调整。仅填充空白字段。"))
                }
                Section(lz(en: "Material", de: "Material", fr: "Matériau", es: "Material", pt: "Material", it: "Materiale", zh: "材料")) {
                    LabeledTextRow(lz(en: "Name", de: "Name", fr: "Nom", es: "Nombre", pt: "Nome", it: "Nome", zh: "名称"), text: $d.name)
                    SuggestTextRow(lz(en: "Brand", de: "Hersteller", fr: "Marque", es: "Marca", pt: "Marca", it: "Marca", zh: "品牌"), text: $d.brand, options: vendorOptions)
                    SuggestTextRow(lz(en: "Type", de: "Typ", fr: "Type", es: "Tipo", pt: "Tipo", it: "Tipo", zh: "类型"), text: $d.type, options: materialOptions)
                    SuggestTextRow(lz(en: "Subtype", de: "Untertyp", fr: "Sous-type", es: "Subtipo", pt: "Subtipo", it: "Sottotipo", zh: "子类型"), text: $d.subtype, options: subtypeOptions)
                    ColorPicker(selection: colorBinding, supportsOpacity: false) {
                        HStack {
                            Text(lz(en: "Colour", de: "Farbe", fr: "Couleur", es: "Color", pt: "Cor", it: "Colore", zh: "颜色"))
                            Spacer()
                            Text("#\(d.normalizedColorHex)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section(lz(en: "Temperatures", de: "Temperaturen", fr: "Températures", es: "Temperaturas", pt: "Temperaturas", it: "Temperature", zh: "温度")) {
                    LabeledIntRow(lz(en: "Nozzle min", de: "Düse min", fr: "Buse min", es: "Boquilla mín", pt: "Bico mín", it: "Ugello min", zh: "喷嘴最低"), value: $d.minTemp, unit: "°C")
                    LabeledIntRow(lz(en: "Nozzle max", de: "Düse max", fr: "Buse max", es: "Boquilla máx", pt: "Bico máx", it: "Ugello max", zh: "喷嘴最高"), value: $d.maxTemp, unit: "°C")
                    LabeledIntRow(lz(en: "Bed min", de: "Bett min", fr: "Plateau min", es: "Cama mín", pt: "Mesa mín", it: "Piano min", zh: "热床最低"), value: $d.bedMinTemp, unit: "°C")
                    LabeledIntRow(lz(en: "Bed max", de: "Bett max", fr: "Plateau max", es: "Cama máx", pt: "Mesa máx", it: "Piano max", zh: "热床最高"), value: $d.bedMaxTemp, unit: "°C")
                }

                Section(lz(en: "Spool", de: "Spule", fr: "Bobine", es: "Bobina", pt: "Bobina", it: "Bobina", zh: "料盘")) {
                    LabeledDoubleRow(lz(en: "Diameter", de: "Durchmesser", fr: "Diamètre", es: "Diámetro", pt: "Diâmetro", it: "Diametro", zh: "直径"), value: $d.diameter, unit: "mm", options: [1.75, 2.85, 3.0])
                    LabeledIntRow(lz(en: "Filament weight", de: "Filamentgewicht", fr: "Poids filament", es: "Peso filamento", pt: "Peso do filamento", it: "Peso filamento", zh: "耗材重量"), value: $d.weight, unit: "g")
                    LabeledIntRow(lz(en: "Empty spool", de: "Leergewicht", fr: "Bobine vide", es: "Bobina vacía", pt: "Bobina vazia", it: "Bobina vuota", zh: "空盘重量"), value: $d.spoolWeight, unit: "g")
                    LabeledDoubleRow(lz(en: "Density", de: "Dichte", fr: "Densité", es: "Densidad", pt: "Densidade", it: "Densità", zh: "密度"), value: $d.density, unit: "g/cm³")
                    LabeledDoubleRow(lz(en: "Price", de: "Preis", fr: "Prix", es: "Precio", pt: "Preço", it: "Prezzo", zh: "价格"), value: $d.price, unit: "")
                }

                Section(lz(en: "Other", de: "Sonstiges", fr: "Autre", es: "Otros", pt: "Outros", it: "Altro", zh: "其他")) {
                    LabeledTextRow(lz(en: "Article no.", de: "Artikelnr.", fr: "Réf. article", es: "N.º artículo", pt: "N.º do artigo", it: "N. articolo", zh: "货号"), text: $d.articleNumber)
                    LabeledTextRow(lz(en: "Comment", de: "Kommentar", fr: "Commentaire", es: "Comentario", pt: "Comentário", it: "Commento", zh: "备注"), text: $d.comment)
                }

                Section {
                    Button {
                        nfc.write(data: d)
                    } label: {
                        HStack {
                            Label(lz(en: "Write to NFC tag", de: "Auf NFC-Tag schreiben", fr: "Écrire sur le tag NFC", es: "Escribir en etiqueta NFC", pt: "Gravar na etiqueta NFC", it: "Scrivi sul tag NFC", zh: "写入 NFC 标签"),
                                  systemImage: "wave.3.right")
                            Spacer()
                            if nfc.isScanning { ProgressView() }
                        }
                    }
                    .disabled(nfc.isScanning)
                    if !nfc.statusMessage.isEmpty {
                        Text(nfc.statusMessage).font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(lz(en: "“OK” only applies the values here — it does not change the tag.", de: "„OK“ übernimmt die Werte nur hier — das Tag wird dadurch nicht geändert.", fr: "« OK » applique les valeurs ici seulement — le tag n'est pas modifié.", es: "«OK» solo aplica los valores aquí — no modifica la etiqueta.", pt: "“OK” aplica os valores apenas aqui — não altera a etiqueta.", it: "«OK» applica i valori solo qui — il tag non viene modificato.", zh: "“确定”仅在此处应用数值——不会更改标签。"))
                }
            }
            .task { if store.vendors.isEmpty && store.filaments.isEmpty { await store.reloadAll() } }
            .navigationTitle(lz(en: "Edit filament", de: "Filament bearbeiten", fr: "Modifier le filament", es: "Editar filamento", pt: "Editar filamento", it: "Modifica filamento", zh: "编辑耗材"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { onOK(d, picked); dismiss() }.fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showSpoolPicker) {
                ActiveSpoolPicker(
                    spools: store.spools,
                    activeId: picked?.id,
                    title: lz(en: "Existing spools", de: "Vorhandene Rollen", fr: "Bobines existantes", es: "Bobinas existentes", pt: "Bobinas existentes", it: "Bobine esistenti", zh: "现有料盘"),
                    noneLabel: lz(en: "Create new spool", de: "Neue Rolle anlegen", fr: "Créer une bobine", es: "Crear nueva bobina", pt: "Criar nova bobina", it: "Crea nuova bobina", zh: "新建料盘")
                ) { id in
                    picked = id.flatMap { pid in store.spools.first { $0.id == pid } }
                    if let p = picked { fillGaps(from: p) }
                    showSpoolPicker = false
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    /// Copy a spool's values into fields the tag left empty. Scanned values win,
    /// so choosing a spool can never overwrite what the tag actually reported.
    private func fillGaps(from p: SpoolmanSpool) {
        let f = p.filament
        if d.name.isEmpty { d.name = f.name ?? "" }
        if d.brand.isEmpty || d.brand == "Generic" { d.brand = f.vendor?.name ?? d.brand }
        if source.type.isEmpty, let m = f.material, !m.isEmpty { d.type = m }
        if source.colorHex.isEmpty || source.colorHex == "888888", let c = f.color_hex { d.colorHex = c }
        if d.diameter <= 0 { d.diameter = f.diameter }
        if d.density <= 0 { d.density = f.density }
        if d.weight <= 0, let w = f.weight { d.weight = Int(w) }
        if d.spoolWeight <= 0, let w = f.spool_weight { d.spoolWeight = Int(w) }
        if d.price <= 0, let pr = f.price { d.price = pr }
        if d.minTemp <= 0, let t = f.settings_extruder_temp { d.minTemp = t }
        if d.bedMinTemp <= 0, let t = f.settings_bed_temp { d.bedMinTemp = t }
        if d.articleNumber.isEmpty { d.articleNumber = f.article_number ?? "" }
        if d.comment.isEmpty { d.comment = f.comment ?? "" }
    }
}

// Small labelled input rows used by the tag editor.
private struct LabeledTextRow: View {
    let title: String
    @Binding var text: String
    init(_ title: String, text: Binding<String>) { self.title = title; self._text = text }
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("–", text: $text)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .autocorrectionDisabled(true)
        }
    }
}

private struct LabeledIntRow: View {
    let title: String
    @Binding var value: Int
    let unit: String
    init(_ title: String, value: Binding<Int>, unit: String) { self.title = title; self._value = value; self.unit = unit }
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: $value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 90)
            if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct LabeledDoubleRow: View {
    let title: String
    @Binding var value: Double
    let unit: String
    let options: [Double]
    init(_ title: String, value: Binding<Double>, unit: String, options: [Double] = []) {
        self.title = title; self._value = value; self.unit = unit; self.options = options
    }
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: $value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 90)
            if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary) }
            if !options.isEmpty {
                Menu {
                    ForEach(options, id: \.self) { o in
                        Button(String(format: "%g", o)) { value = o }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2).foregroundStyle(.secondary).padding(.leading, 4)
                }
            }
        }
    }
}


// Free-text row with a dropdown of known values (manufacturers, materials, …).
// You can still type anything — the menu is just a shortcut.
private struct SuggestTextRow: View {
    let title: String
    @Binding var text: String
    let options: [String]
    init(_ title: String, text: Binding<String>, options: [String]) {
        self.title = title; self._text = text; self.options = options
    }
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("–", text: $text)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .autocorrectionDisabled(true)
            if !options.isEmpty {
                Menu {
                    ForEach(options, id: \.self) { o in
                        Button {
                            text = o
                        } label: {
                            if o.caseInsensitiveCompare(text) == .orderedSame {
                                Label(o, systemImage: "checkmark")
                            } else {
                                Text(o)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }
        }
    }
}
