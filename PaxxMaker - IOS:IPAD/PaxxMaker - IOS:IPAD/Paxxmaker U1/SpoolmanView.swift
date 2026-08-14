import SwiftUI
import Combine

// MARK: - Spoolman store (view model)
@MainActor
final class SpoolmanStore: ObservableObject {
    @Published var spools: [SpoolmanSpool] = []
    @Published var filaments: [SpoolmanFilament] = []
    @Published var vendors: [SpoolmanVendor] = []
    @Published var isLoading = false
    @Published var errorText: String?
    @Published var showArchived = false

    private var service: SpoolmanService? { SpoolmanConfig.service }

    func reloadAll() async {
        guard let svc = service else {
            errorText = SpoolmanError.notConfigured.localizedDescription
            return
        }
        isLoading = true; errorText = nil
        do {
            async let s = svc.spools(includeArchived: showArchived)
            async let f = svc.filaments()
            async let v = svc.vendors()
            let (sp, fi, ve) = try await (s, f, v)
            spools = sp.sorted { ($0.filament.displayName) < ($1.filament.displayName) }
            filaments = fi.sorted { $0.displayName < $1.displayName }
            vendors = ve.sorted { $0.name < $1.name }
        } catch {
            errorText = (error as? SpoolmanError)?.errorDescription ?? SpoolmanService.localizedTransport(error)
        }
        isLoading = false
    }

    // Generic wrapper: run a mutating call, surface errors, reload afterwards.
    func perform(_ op: @escaping (SpoolmanService) async throws -> Void) async {
        guard let svc = service else { errorText = SpoolmanError.notConfigured.localizedDescription; return }
        errorText = nil
        do { try await op(svc); await reloadAll() }
        catch { errorText = (error as? SpoolmanError)?.errorDescription ?? SpoolmanService.localizedTransport(error) }
    }
}

// MARK: - Root
struct SpoolmanView: View {
    @StateObject private var store = SpoolmanStore()
    @StateObject private var nfc = OpenSpoolNFCManager()
    @State private var tab = 0
    @State private var showAdd = false
    @State private var nfcAdd: OpenSpoolData?

    var body: some View {
        NavigationView {
            Group {
                if !SpoolmanConfig.isEnabled || SpoolmanConfig.service == nil {
                    notConfigured
                } else {
                    content
                }
            }
            .navigationTitle("Spoolman")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if tab == 0 {
                        // Spools: choose how to add — scan an NFC tag or fill in
                        // the form manually.
                        Menu {
                            Button {
                                nfc.read()
                            } label: {
                                Label(lz(en: "Scan NFC tag", de: "NFC-Tag scannen", fr: "Scanner un tag NFC", es: "Escanear etiqueta NFC", pt: "Ler etiqueta NFC", it: "Scansiona tag NFC", zh: "扫描 NFC 标签"), systemImage: "wave.3.right")
                            }
                            Button {
                                showAdd = true
                            } label: {
                                Label(lz(en: "Add manually", de: "Manuell hinzufügen", fr: "Ajouter manuellement", es: "Añadir manualmente", pt: "Adicionar manualmente", it: "Aggiungi manualmente", zh: "手动添加"), systemImage: "square.and.pencil")
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(SpoolmanConfig.service == nil)
                    } else {
                        Button { showAdd = true } label: { Image(systemName: "plus") }
                            .disabled(SpoolmanConfig.service == nil)
                    }
                }
            }
            .task { if store.spools.isEmpty { await store.reloadAll() } }
        }
        .navigationViewStyle(.stack)
        // NFC read → offer to add to Spoolman
        .onChange(of: nfc.lastRead) { _, new in
            if let new { nfcAdd = new }
        }
        .sheet(isPresented: $showAdd) {
            addSheet
        }
        .sheet(isPresented: Binding(get: { nfcAdd != nil }, set: { if !$0 { nfcAdd = nil } })) {
            if let d = nfcAdd { SpoolmanNFCAddView(store: store, tag: d) }
        }
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(lz(en: "Spools", de: "Spulen", fr: "Bobines", es: "Carretes", pt: "Bobinas", it: "Bobine", zh: "料盘")).tag(0)
                Text(lz(en: "Filaments", de: "Filamente", fr: "Filaments", es: "Filamentos", pt: "Filamentos", it: "Filamenti", zh: "耗材")).tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.top, 8)

            if let err = store.errorText {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.top, 6)
            }

            switch tab {
            case 1: filamentList
            default: spoolList
            }
        }
    }

    // ── Spools ──────────────────────────────────────────────────────────────
    private var spoolList: some View {
        List {
            ForEach(store.spools) { spool in
                NavigationLink { SpoolDetailView(store: store, spool: spool) } label: {
                    SpoolRow(spool: spool)
                }
            }
            // Archive toggle at the very bottom, out of the way.
            Section {
                Toggle(lz(en: "Show archived", de: "Archivierte anzeigen", fr: "Afficher archivées", es: "Mostrar archivados", pt: "Mostrar arquivados", it: "Mostra archiviate", zh: "显示已归档"), isOn: $store.showArchived)
                    .onChange(of: store.showArchived) { _, _ in Task { await store.reloadAll() } }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.reloadAll() }
        .overlay { if store.isLoading && store.spools.isEmpty { ProgressView() } }
    }

    // ── Filaments ───────────────────────────────────────────────────────────
    private var filamentList: some View {
        List {
            ForEach(store.filaments) { fil in
                NavigationLink { FilamentEditView(store: store, filament: fil) } label: {
                    HStack(spacing: 12) {
                        ColorDot(hex: fil.color_hex)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fil.rowTitle).font(.subheadline).bold()
                            HStack(spacing: 6) {
                                if !(fil.name ?? "").isEmpty, let m = fil.material { tagChip(m, .blue) }
                                if let v = fil.vendor?.name, !v.isEmpty { Text(v).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                .contextMenu {
                    Button(role: .destructive) {
                        Task { await store.perform { try await $0.deleteFilament(fil.id) } }
                    } label: {
                        Label(lz(en: "Delete", de: "Löschen", fr: "Supprimer", es: "Eliminar", pt: "Excluir", it: "Elimina", zh: "删除"), systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.reloadAll() }
    }

    @ViewBuilder private var addSheet: some View {
        switch tab {
        case 1: FilamentEditView(store: store, filament: nil)
        default: SpoolEditView(store: store, spool: nil)
        }
    }

    private var notConfigured: some View {
        VStack(spacing: 14) {
            Image(systemName: "record.circle.fill").font(.system(size: 42)).foregroundStyle(.secondary)
            Text(lz(en: "Spoolman is disabled", de: "Spoolman ist deaktiviert", fr: "Spoolman est désactivé", es: "Spoolman está desactivado", pt: "Spoolman está desativado", it: "Spoolman è disattivato", zh: "Spoolman 已禁用"))
                .font(.headline)
            Text(lz(en: "Enable it under Settings → Extra Features and enter your Spoolman address.", de: "Aktiviere es unter Einstellungen → Zusatzfunktionen und trage deine Spoolman-Adresse ein.", fr: "Activez-le dans Réglages → Fonctions supplémentaires et saisissez l'adresse de Spoolman.", es: "Actívalo en Ajustes → Funciones adicionales e introduce la dirección de Spoolman.", pt: "Ative em Configurações → Recursos Extras e informe o endereço do Spoolman.", it: "Attivalo in Impostazioni → Funzioni Extra e inserisci l'indirizzo di Spoolman.", zh: "在 设置 → 附加功能 中启用并输入 Spoolman 地址。"))
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
        }
    }

    private func tagChip(_ t: String, _ c: Color) -> some View {
        Text(t).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
            .background(c.opacity(0.15)).foregroundStyle(c).cornerRadius(4)
    }
}

// MARK: - Spool row
struct SpoolRow: View {
    let spool: SpoolmanSpool
    var body: some View {
        HStack(spacing: 12) {
            ColorDot(hex: spool.filament.color_hex)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(spool.filament.rowTitle).font(.subheadline).bold().lineLimit(1)
                    if spool.archived {
                        Image(systemName: "archivebox.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !spool.filament.rowSubtitle.isEmpty {
                    Text(spool.filament.rowSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let frac = spool.remainingFraction {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.2))
                            Capsule().fill(barColor(frac)).frame(width: g.size.width * frac)
                        }
                    }.frame(height: 5)
                }
                HStack(spacing: 8) {
                    if let rem = spool.remaining_weight {
                        Text("\(Int(rem)) g").font(.caption).foregroundStyle(.secondary)
                    }
                    if let loc = spool.location, !loc.isEmpty {
                        Label(loc, systemImage: "mappin.and.ellipse").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
    private func barColor(_ f: Double) -> Color { f < 0.1 ? .red : (f < 0.25 ? .orange : .green) }
}

struct ColorDot: View {
    let hex: String?
    var size: CGFloat = 30
    var body: some View {
        Circle()
            .fill(Color(hex: (hex ?? "888888").replacingOccurrences(of: "#", with: "")) ?? .gray)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Active Spool tile (Spoolman via Moonraker)
// Shows the spool Moonraker currently deducts from; tap to pick another.
// Appears only when the printer's Moonraker has [spoolman] connected.
struct ActiveSpoolTileView: View {
    @ObservedObject var printer: PrinterService
    @AppStorage("spoolman_url") private var spoolmanURL: String = ""
    @State private var spools: [SpoolmanSpool] = []
    @State private var showPicker = false

    private var active: SpoolmanSpool? {
        guard let id = printer.activeSpoolId else { return nil }
        return spools.first { $0.id == id }
    }

    var body: some View {
        // A plain view (NOT a Button) so it behaves like the other tiles when
        // dragged in edit mode; the tap is a gesture, disabled in edit mode by
        // the dashboard's allowsHitTesting(false).
        VStack(alignment: .leading, spacing: 0) {
            // Header — top-left, matching every other tile's section label.
            HStack(spacing: 5) {
                Image(systemName: "smallcircle.filled.circle").font(.system(size: 11)).foregroundColor(.secondary)
                Text(lz(en: "Active Spool", de: "Aktive Spule", fr: "Bobine active", es: "Bobina activa", pt: "Bobina ativa", it: "Bobina attiva", zh: "当前料盘"))
                    .font(.caption2).fontWeight(.semibold).foregroundColor(.secondary).textCase(.uppercase).tracking(1)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            }

            if let a = active {
                Spacer(minLength: 12)
                // Identity — spool colour + name/material, centred in the free space.
                HStack(spacing: 12) {
                    ColorDot(hex: a.filament.color_hex, size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(a.filament.rowTitle).font(.headline).foregroundColor(.primary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        let sub = [a.filament.material, a.remaining_weight.map { "\(Int($0)) g" }].compactMap { $0 }.joined(separator: " · ")
                        if !sub.isEmpty {
                            Text(sub).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 12)
                // Fill bar — pinned to the bottom, full width, with a % readout.
                if let frac = a.remainingFraction {
                    HStack(spacing: 8) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.2))
                                Capsule().fill(barColor(frac)).frame(width: g.size.width * max(0, min(frac, 1)))
                            }
                        }.frame(height: 6)
                        Text("\(Int((max(0, min(frac, 1))) * 100))%")
                            .font(.caption2).fontWeight(.semibold).foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
            } else {
                Spacer(minLength: 12)
                Text(printer.activeSpoolId == nil
                     ? lz(en: "None — tap to choose", de: "Keine — zum Wählen tippen", fr: "Aucune — appuyez", es: "Ninguna — toca", pt: "Nenhuma — toque", it: "Nessuna — tocca", zh: "无 — 点击选择")
                     : "#\(printer.activeSpoolId!)")
                    .font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 12)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 84, maxHeight: .infinity, alignment: .topLeading)
        // Same chrome as the dashboard's glassCard so this tile picks up the
        // themed background tint and matches every other tile's size & look.
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(.thinMaterial)
                RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06))
            }
        )
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { showPicker = true }
        .onAppear { Task { await load() }; if printer.printerType == .snapmakerU1 { printer.fetchMultiColorHook() } }
        .onChange(of: printer.activeSpoolId) { _, _ in Task { await load() } }
        .sheet(isPresented: $showPicker) {
            // U1 (multi-nozzle): the 4-color sheet (auto-tracking + per-nozzle
            // assignment). Single-nozzle: the plain single-spool picker.
            if printer.printerType == .snapmakerU1 {
                MultiColorSpoolSheet(printer: printer, spools: spools)
            } else {
                ActiveSpoolPicker(spools: spools, activeId: printer.activeSpoolId) { id in
                    printer.setActiveSpool(id)
                    showPicker = false
                }
            }
        }
    }

    private func barColor(_ f: Double) -> Color { f < 0.1 ? .red : (f < 0.25 ? .orange : .green) }

    private func load() async {
        guard let svc = SpoolmanService(rawHost: spoolmanURL) else { return }
        if let list = try? await svc.spools(includeArchived: false) {
            await MainActor.run { self.spools = list }
        }
    }
}

struct ActiveSpoolPicker: View {
    let spools: [SpoolmanSpool]
    let activeId: Int?
    var title: String = lz(en: "Active Spool", de: "Aktive Spule", fr: "Bobine active", es: "Bobina activa", pt: "Bobina ativa", it: "Bobina attiva", zh: "当前料盘")
    var noneLabel: String = lz(en: "Eject spool", de: "Spule Auswerfen", fr: "Éjecter la bobine", es: "Expulsar bobina", pt: "Ejetar bobina", it: "Espelli bobina", zh: "退出料盘")
    let onSelect: (Int?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // "Eject": clear the active spool — for using a spool that
                // isn't registered in Spoolman (so nothing is mis-tracked).
                Button { onSelect(nil) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "eject.fill").font(.system(size: 17)).foregroundColor(.secondary).frame(width: 30)
                        Text(noneLabel)
                            .font(.subheadline).bold().foregroundColor(.primary)
                        Spacer()
                    }
                    .padding(10)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 14).fill(activeId == nil ? Color.green.opacity(0.10) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(activeId == nil ? Color.green : Color.clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))

                ForEach(spools) { s in
                    Button { onSelect(s.id) } label: {
                        // Same row style as the Spoolman tab (colour, name, fill
                        // bar, grams). The active spool is framed with a green
                        // rounded outline instead of a checkmark (which would
                        // overlap the fill bar).
                        SpoolRow(spool: s)
                            .padding(10)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(s.id == activeId ? Color.green.opacity(0.10) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(s.id == activeId ? Color.green : Color.clear, lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }
            }
            .listStyle(.plain)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消")) { dismiss() }
                }
            }
        }
    }
}

private struct SlotBox: Identifiable { let id: Int }

// "Spoolman Hook entfernen" — shown in the printer's settings ONLY when the
// 4-color hook is installed (U1). Fully undoes the install (idle only).
struct MultiColorHookRemoveSection: View {
    @ObservedObject var service: PrinterService
    @State private var showConfirm = false
    var body: some View {
        if service.mcHookInstalled {
            Section {
                Button(role: .destructive) { showConfirm = true } label: {
                    HStack {
                        Spacer()
                        Label(lz(en: "Remove Spoolman hook", de: "Spoolman Hook entfernen", fr: "Retirer le hook Spoolman", es: "Eliminar hook de Spoolman", pt: "Remover hook do Spoolman", it: "Rimuovi hook Spoolman", zh: "移除 Spoolman 挂钩"),
                              systemImage: "trash")
                        Spacer()
                        if service.mcBusy { ProgressView() }
                    }
                }
                .disabled(service.mcBusy)
                if let msg = service.mcStatusMsg {
                    Text(msg).font(.caption).foregroundColor(.secondary)
                }
            } footer: {
                Text(lz(en: "Removes the 4-color tracking config and restarts the printer (idle only).", de: "Entfernt die 4-Farben-Config und startet den Drucker neu (nur im Leerlauf).", fr: "Supprime la config de suivi 4 couleurs et redémarre l'imprimante (à l'arrêt).", es: "Elimina la config de seguimiento 4 colores y reinicia la impresora (solo en reposo).", pt: "Remove a config de rastreamento 4 cores e reinicia a impressora (só ociosa).", it: "Rimuove la config di tracciamento 4 colori e riavvia la stampante (solo ferma).", zh: "移除四色跟踪配置并重启打印机（仅空闲时）。"))
            }
            .confirmationDialog(
                lz(en: "Remove hook?", de: "Hook entfernen?", fr: "Retirer le hook ?", es: "¿Eliminar hook?", pt: "Remover hook?", it: "Rimuovere hook?", zh: "移除挂钩？"),
                isPresented: $showConfirm, titleVisibility: .visible
            ) {
                Button(lz(en: "Remove", de: "Entfernen", fr: "Retirer", es: "Eliminar", pt: "Remover", it: "Rimuovi", zh: "移除"), role: .destructive) {
                    service.removeMultiColorHook()
                }
                Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {}
            } message: {
                Text(lz(en: "Undo everything and restart the printer.", de: "Alles rückgängig machen und den Drucker neu starten.", fr: "Tout annuler et redémarrer l'imprimante.", es: "Deshacer todo y reiniciar la impresora.", pt: "Desfazer tudo e reiniciar a impressora.", it: "Annulla tutto e riavvia la stampante.", zh: "撤销全部并重启打印机。"))
            }
        }
    }
}

// 4-color (U1 / multi-nozzle) sheet: set up / toggle auto-tracking and assign a
// Spoolman spool to each nozzle. Only reached from the U1 "Active Spool" tile.
struct MultiColorSpoolSheet: View {
    @ObservedObject var printer: PrinterService
    let spools: [SpoolmanSpool]
    @Environment(\.dismiss) private var dismiss
    @State private var editSlot: SlotBox? = nil

    private func spool(_ id: Int) -> SpoolmanSpool? { spools.first { $0.id == id } }
    private func nozzleName(_ slot: Int) -> String {
        lz(en: "Nozzle \(slot + 1)", de: "Düse \(slot + 1)", fr: "Buse \(slot + 1)", es: "Boquilla \(slot + 1)", pt: "Bico \(slot + 1)", it: "Ugello \(slot + 1)", zh: "喷嘴 \(slot + 1)")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if printer.mcHookInstalled {
                        Toggle(isOn: Binding(get: { printer.mcAutoTracking },
                                             set: { printer.setAutoTracking($0) })) {
                            Label(lz(en: "Auto-tracking", de: "Auto-Tracking", fr: "Suivi auto", es: "Seguimiento auto", pt: "Rastreamento auto", it: "Tracciamento auto", zh: "自动跟踪"),
                                  systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(printer.mcBusy)
                    } else {
                        Button { printer.installMultiColorHook() } label: {
                            HStack {
                                Label(lz(en: "Set up 4-color tracking", de: "4-Farben-Tracking einrichten", fr: "Configurer le suivi 4 couleurs", es: "Configurar seguimiento 4 colores", pt: "Configurar rastreamento 4 cores", it: "Configura tracciamento 4 colori", zh: "设置四色跟踪"),
                                      systemImage: "square.stack.3d.up.fill")
                                Spacer()
                                if printer.mcBusy { ProgressView() }
                            }
                        }
                        .disabled(printer.mcBusy || !printer.mcIsIdle)
                    }
                    if let msg = printer.mcStatusMsg {
                        Text(msg).font(.caption).foregroundColor(.secondary)
                    }
                    if !printer.mcHookInstalled && !printer.mcIsIdle {
                        Text(lz(en: "Setup needs the printer idle (it restarts briefly).", de: "Einrichtung nur im Leerlauf (Drucker startet kurz neu).", fr: "La configuration nécessite l'imprimante à l'arrêt (redémarrage bref).", es: "La configuración requiere la impresora en reposo (se reinicia brevemente).", pt: "A configuração exige a impressora ociosa (reinicia brevemente).", it: "La configurazione richiede la stampante ferma (si riavvia brevemente).", zh: "设置需要打印机空闲（会短暂重启）。"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                } header: {
                    Text(lz(en: "4-Color Tracking", de: "4-Farben-Tracking", fr: "Suivi 4 couleurs", es: "Seguimiento 4 colores", pt: "Rastreamento 4 Cores", it: "Tracciamento 4 Colori", zh: "四色跟踪"))
                } footer: {
                    Text(lz(en: "Spoolman deducts filament from the spool matching the active nozzle.", de: "Spoolman bucht Filament von der Spule der aktiven Düse ab.", fr: "Spoolman déduit le filament de la bobine correspondant à la buse active.", es: "Spoolman descuenta filamento de la bobina de la boquilla activa.", pt: "O Spoolman deduz filamento da bobina do bico ativo.", it: "Spoolman scala il filamento dalla bobina dell'ugello attivo.", zh: "Spoolman 从与当前喷嘴匹配的料盘扣除耗材。"))
                }

                if printer.mcHookInstalled && printer.mcAutoTracking {
                    // Auto-tracking ON → assign a spool to each of the 4 nozzles.
                    Section(header: Text(lz(en: "Nozzle assignment", de: "Düsen-Zuordnung", fr: "Affectation des buses", es: "Asignación de boquillas", pt: "Atribuição de bicos", it: "Assegnazione ugelli", zh: "喷嘴分配"))) {
                        ForEach(0..<4, id: \.self) { slot in
                            Button { editSlot = SlotBox(id: slot) } label: { slotRow(slot) }
                                .buttonStyle(.plain)
                        }
                    }
                } else {
                    // Auto-tracking OFF (or not set up) → single active spool, like
                    // a single-nozzle printer (the one loaded in Klipper).
                    Section(header: Text(lz(en: "Active spool", de: "Aktive Spule", fr: "Bobine active", es: "Bobina activa", pt: "Bobina ativa", it: "Bobina attiva", zh: "当前料盘"))) {
                        Button { printer.setActiveSpool(nil); dismiss() } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "eject.fill").font(.system(size: 17)).foregroundColor(.secondary).frame(width: 30)
                                Text(lz(en: "Eject spool", de: "Spule Auswerfen", fr: "Éjecter la bobine", es: "Expulsar bobina", pt: "Ejetar bobina", it: "Espelli bobina", zh: "退出料盘"))
                                    .font(.subheadline).bold().foregroundColor(.primary)
                                Spacer()
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(printer.activeSpoolId == nil ? Color.green.opacity(0.12) : Color(.secondarySystemGroupedBackground))
                        ForEach(spools) { s in
                            Button { printer.setActiveSpool(s.id); dismiss() } label: {
                                SpoolRow(spool: s).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(s.id == printer.activeSpoolId ? Color.green.opacity(0.12) : Color(.secondarySystemGroupedBackground))
                        }
                    }
                }
            }
            .navigationTitle(lz(en: "Active Spool", de: "Aktive Spule", fr: "Bobine active", es: "Bobina activa", pt: "Bobina ativa", it: "Bobina attiva", zh: "当前料盘"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(lz(en: "Done", de: "Fertig", fr: "OK", es: "Listo", pt: "Concluído", it: "Fine", zh: "完成")) { dismiss() }
                }
            }
            .onAppear { printer.fetchMultiColorHook() }
            .sheet(item: $editSlot) { box in
                let cur = (printer.mcSlotSpools[safe: box.id] ?? -1)
                ActiveSpoolPicker(
                    spools: spools,
                    activeId: cur >= 0 ? cur : nil,
                    title: nozzleName(box.id),
                    noneLabel: lz(en: "Clear slot", de: "Slot leeren", fr: "Vider l'emplacement", es: "Vaciar ranura", pt: "Limpar slot", it: "Svuota slot", zh: "清空槽位")
                ) { id in
                    printer.setSlotSpool(box.id, id)
                    editSlot = nil
                }
            }
        }
    }

    @ViewBuilder private func slotRow(_ slot: Int) -> some View {
        let id = printer.mcSlotSpools[safe: slot] ?? -1
        HStack(spacing: 12) {
            ColorDot(hex: id >= 0 ? spool(id)?.filament.color_hex : nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(nozzleName(slot)).font(.subheadline).bold().foregroundColor(.primary)
                if id >= 0, let s = spool(id) {
                    Text(s.filament.rowTitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
                } else {
                    Text(lz(en: "Empty", de: "Leer", fr: "Vide", es: "Vacío", pt: "Vazio", it: "Vuoto", zh: "空")).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
    }
}
