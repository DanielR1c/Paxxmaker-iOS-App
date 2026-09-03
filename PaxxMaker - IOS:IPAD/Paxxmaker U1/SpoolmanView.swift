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
        guard let id = printer.effectiveActiveSpoolId else { return nil }
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
                     : "#\(printer.effectiveActiveSpoolId!)")
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
        .onChange(of: printer.fwSlotSpoolIds) { _, _ in Task { await load() } }
        .onChange(of: printer.mcSlotSpools) { _, _ in Task { await load() } }
        .sheet(isPresented: $showPicker) {
            // U1 (multi-nozzle): the 4-color sheet (auto-tracking + per-nozzle
            // assignment). Single-nozzle: the plain single-spool picker.
            if printer.printerType == .snapmakerU1 {
                MultiColorSpoolSheet(printer: printer, spools: spools)
            } else {
                ActiveSpoolPicker(spools: spools, activeId: printer.effectiveActiveSpoolId) { id in
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
                        .listRowBackground(printer.effectiveActiveSpoolId == nil ? Color.green.opacity(0.12) : Color(.secondarySystemGroupedBackground))
                        ForEach(spools) { s in
                            Button { printer.setActiveSpool(s.id); dismiss() } label: {
                                SpoolRow(spool: s).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(s.id == printer.effectiveActiveSpoolId ? Color.green.opacity(0.12) : Color(.secondarySystemGroupedBackground))
                        }
                    }
                }
            }
            .navigationTitle(lz(en: "Active Spool", de: "Aktive Spule", fr: "Bobine active", es: "Bobina activa", pt: "Bobina ativa", it: "Bobina attiva", zh: "当前料盘"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(lz(en: "Done", de: "Fertig", fr: "OK", es: "Listo", pt: "Concluído", it: "Fine", zh: "完成")) {
                        // Pull both sources the tiles read from, so changes made
                        // in here are visible on the dashboard right away
                        // instead of only at the next poll.
                        printer.fetchFilamentSlots()
                        printer.fetchSpoollinkState()
                        dismiss()
                    }
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
                    printer.assignSpoolManually(channel: box.id, spoolId: id)
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

// MARK: - Spoollink (paxx12 "Filament Manager")
// The dashboard's Spools tile turns into the Spoollink tile and opens this
// sheet; there is no separate Spoollink tile.
private struct SpoollinkChannelBox: Identifiable { let id: Int }

struct SpoollinkSheet: View {
    @ObservedObject var printer: PrinterService
    @Environment(\.dismiss) private var dismiss
    @AppStorage("spoolman_url") private var spoolmanURL: String = ""

    @State private var spools: [SpoolmanSpool] = []
    @State private var pickChannel: SpoollinkChannelBox? = nil
    @State private var linkChannel: SpoollinkChannelBox? = nil
    @State private var busy = false
    @State private var status: String? = nil

    private func spool(_ id: Int) -> SpoolmanSpool? { spools.first { $0.id == id } }

    // The "Tag" row always shows what the printer read off the spool's NFC chip.
    // A linked Spoolman spool may well carry a different colour — that one
    // belongs to the "Material" row below and must not bleed up here.
    private func tagRowHex(ch: Int) -> String? {
        printer.slotColorHexes[safe: ch] ?? nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        busy = true
                        status = lz(en: "Reading tags…", de: "Tags werden gelesen…", fr: "Lecture des tags…", es: "Leyendo etiquetas…", pt: "Lendo etiquetas…", it: "Lettura tag…", zh: "正在读取标签…")
                        printer.spoollinkReadTags()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { busy = false; status = nil }
                    } label: {
                        HStack {
                            Label(lz(en: "Read spool tags", de: "Spulen-Tags lesen", fr: "Lire les tags", es: "Leer etiquetas", pt: "Ler etiquetas", it: "Leggi i tag", zh: "读取料盘标签"),
                                  systemImage: "wave.3.right")
                            Spacer()
                            if busy { ProgressView() }
                        }
                    }
                    .disabled(busy)
                    if let s = status { Text(s).font(.caption).foregroundStyle(.secondary) }
                }

                ForEach(0..<4, id: \.self) { ch in
                    Section(lz(en: "Nozzle \(ch + 1)", de: "Düse \(ch + 1)", fr: "Buse \(ch + 1)", es: "Boquilla \(ch + 1)", pt: "Bico \(ch + 1)", it: "Ugello \(ch + 1)", zh: "喷嘴 \(ch + 1)")) {
                        // Firmware assignment wins; our own mapping fills the gap
                        // on builds without SET_SPOOL_ID.
                        let sid = printer.resolvedSpoolId(forChannel: ch) ?? 0
                        let uid = printer.slotCardUIDs[safe: ch] ?? ""

                        HStack {
                            Text(lz(en: "Tag", de: "Tag", fr: "Tag", es: "Etiqueta", pt: "Etiqueta", it: "Tag", zh: "标签"))
                            Spacer()
                            let mat = printer.slotMaterials[safe: ch] ?? ""
                            let ven = printer.slotVendors[safe: ch] ?? ""
                            let hex = tagRowHex(ch: ch)
                            if let hex, !hex.isEmpty, !(mat.isEmpty || mat == "NONE") {
                                ColorDot(hex: hex, size: 14)
                            }
                            Text(mat.isEmpty || mat == "NONE" ? "–" : "\(ven == "NONE" ? "" : ven) \(mat)".trimmingCharacters(in: .whitespaces))
                                .foregroundStyle(.secondary)
                        }

                        // Without a tag there is nothing that could identify the
                        // spool, so assign it by hand. With a tag the row below
                        // owns the assignment — showing both invited conflicts.
                        if uid.isEmpty {
                        Button { pickChannel = SpoollinkChannelBox(id: ch) } label: {
                            HStack {
                                Text(lz(en: "Spool", de: "Spule", fr: "Bobine", es: "Bobina", pt: "Bobina", it: "Bobina", zh: "料盘"))
                                Spacer()
                                if sid > 0 {
                                    if let sp = spool(sid) {
                                        ColorDot(hex: sp.filament.color_hex, size: 14)
                                        Text(sp.filament.rowTitle).foregroundStyle(.secondary).lineLimit(1)
                                    } else {
                                        Text("#\(sid)").foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text(lz(en: "None", de: "Keine", fr: "Aucune", es: "Ninguna", pt: "Nenhuma", it: "Nessuna", zh: "无")).foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        }

                        HStack {
                            Text(lz(en: "Card UID", de: "Karten-UID", fr: "UID de carte", es: "UID de tarjeta", pt: "UID do cartão", it: "UID scheda", zh: "卡片 UID"))
                            Spacer()
                            Text(uid.isEmpty ? "–" : uid).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                        }

                        // Tag disagrees with what the printer has loaded — offer
                        // the same comparison + fix as the printer's own page.
                        if printer.tagMismatch(ch) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption).foregroundStyle(.orange)
                                    Text(lz(en: "Tag differs from printer", de: "Tag weicht vom Drucker ab", fr: "Le tag diffère de l'imprimante", es: "La etiqueta difiere de la impresora", pt: "A etiqueta difere da impressora", it: "Il tag differisce dalla stampante", zh: "标签与打印机不一致"))
                                        .font(.caption).fontWeight(.semibold)
                                }
                                mismatchRow(lz(en: "Vendor", de: "Hersteller", fr: "Marque", es: "Marca", pt: "Marca", it: "Marca", zh: "品牌"),
                                            printer.tagVendors[safe: ch] ?? "", printer.slotVendors[safe: ch] ?? "")
                                mismatchRow(lz(en: "Type", de: "Typ", fr: "Type", es: "Tipo", pt: "Tipo", it: "Tipo", zh: "类型"),
                                            printer.tagTypes[safe: ch] ?? "", printer.slotMaterials[safe: ch] ?? "")
                                mismatchRow(lz(en: "Subtype", de: "Untertyp", fr: "Sous-type", es: "Subtipo", pt: "Subtipo", it: "Sottotipo", zh: "子类型"),
                                            printer.tagSubtypes[safe: ch] ?? "", printer.slotSubtypes[safe: ch] ?? "")
                                mismatchRow(lz(en: "Colour", de: "Farbe", fr: "Couleur", es: "Color", pt: "Cor", it: "Colore", zh: "颜色"),
                                            printer.tagColorHexes[safe: ch] ?? "", printer.slotColorHexes[safe: ch] ?? "",
                                            showsColour: true)
                                let lo = printer.tagTempMin[safe: ch] ?? 0, hi = printer.tagTempMax[safe: ch] ?? 0
                                if lo > 0 || hi > 0 {
                                    Text(lz(en: "Tag hotend: \(lo)–\(hi) °C", de: "Tag Düse: \(lo)–\(hi) °C", fr: "Tag buse : \(lo)–\(hi) °C", es: "Etiqueta boquilla: \(lo)–\(hi) °C", pt: "Etiqueta bico: \(lo)–\(hi) °C", it: "Tag ugello: \(lo)–\(hi) °C", zh: "标签喷嘴：\(lo)–\(hi) °C"))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Button {
                                    printer.applyTagToPrinter(channel: ch)
                                } label: {
                                    Label(lz(en: "Apply tag to printer", de: "Tag auf Drucker anwenden", fr: "Appliquer le tag à l'imprimante", es: "Aplicar etiqueta a la impresora", pt: "Aplicar etiqueta à impressora", it: "Applica il tag alla stampante", zh: "将标签应用到打印机"),
                                          systemImage: "arrow.down.circle.fill")
                                        .font(.callout)
                                }
                                .disabled(busy)
                                .padding(.top, 2)
                            }
                            .padding(.vertical, 2)
                        }

                        // Link the scanned tag to a Spoolman spool: writing the
                        // card UID into that spool is what makes the firmware
                        // recognise it by itself ("no spool found for card …").
                        // One row does both: shows which spool the tag belongs to
                        // and opens the picker to (re)link it.
                        if !uid.isEmpty {
                            let linked = spools.first { $0.cardUIDs.contains(uid.uppercased()) }
                            Button { linkChannel = SpoollinkChannelBox(id: ch) } label: {
                                HStack {
                                    Text(lz(en: "Material", de: "Material", fr: "Matériau", es: "Material", pt: "Material", it: "Materiale", zh: "材料"))
                                    Spacer()
                                    if let l = linked {
                                        // Once linked, showing the spool's colour
                                        // here is helpful rather than redundant.
                                        ColorDot(hex: l.filament.color_hex, size: 14)
                                        Text(l.filament.rowTitle).foregroundStyle(.secondary).lineLimit(1)
                                    } else {
                                        Text(lz(en: "link", de: "verknüpfen", fr: "lier", es: "vincular", pt: "vincular", it: "collega", zh: "关联"))
                                            .foregroundStyle(.orange)
                                    }
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(busy)
                        }

                        // Last row of the nozzle: unlinks the tag, clears the assignment and
                        // removes the printer's cached copy for that UID.
                        if !uid.isEmpty || sid > 0 {
                            // Same plain style + explicit hit area as the rows
                            // above: the default Form button style reacted only
                            // after a noticeably long press.
                            Button {
                                printer.assignSpoolManually(channel: ch, spoolId: nil)
                                reloadSoon()
                            } label: {
                                Label(lz(en: "Reset tag link", de: "Tag-Verknüpfung zurücksetzen", fr: "Réinitialiser le lien du tag", es: "Restablecer vínculo de etiqueta", pt: "Redefinir vínculo da etiqueta", it: "Reimposta collegamento tag", zh: "重置标签关联"),
                                      systemImage: "arrow.counterclockwise")
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(busy)
                        }

                    }
                }

                // One explanation, at the very bottom.
                Section {
                    Text(explanation)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("SpoolLink")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(lz(en: "Done", de: "Fertig", fr: "OK", es: "Listo", pt: "Concluído", it: "Fine", zh: "完成")) { dismiss() }
                }
            }
            // Keep polling while the screen is open — tags can be swapped at the
            // printer at any moment and a stale UID looks like a wrong one.
            .task {
                printer.fetchSpoollinkState()
                await loadSpools()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if Task.isCancelled { break }
                    printer.fetchSpoollinkState()
                }
            }
            .refreshable { printer.fetchSpoollinkState(); await loadSpools() }
            .sheet(item: $linkChannel) { box in
                ActiveSpoolPicker(
                    spools: spools,
                    activeId: nil,
                    title: lz(en: "Link tag", de: "Tag verknüpfen", fr: "Lier le tag", es: "Vincular etiqueta", pt: "Vincular etiqueta", it: "Collega il tag", zh: "关联标签"),
                    noneLabel: lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消")
                ) { id in
                    let ch = box.id
                    linkChannel = nil
                    // Only a real pick changes anything — resetting has its own
                    // row in the nozzle section.
                    guard let id else { return }
                    printer.assignSpoolManually(channel: ch, spoolId: id)
                    reloadSoon()
                }
            }
            .sheet(item: $pickChannel) { box in
                ActiveSpoolPicker(
                    spools: spools,
                    activeId: {
                        let fw = printer.fwSlotSpoolIds[safe: box.id] ?? 0
                        if fw > 0 { return fw }
                        let own = printer.mcSlotSpools[safe: box.id] ?? -1
                        return own > 0 ? own : nil
                    }(),
                    title: lz(en: "Nozzle \(box.id + 1)", de: "Düse \(box.id + 1)", fr: "Buse \(box.id + 1)", es: "Boquilla \(box.id + 1)", pt: "Bico \(box.id + 1)", it: "Ugello \(box.id + 1)", zh: "喷嘴 \(box.id + 1)"),
                    noneLabel: lz(en: "Clear spool", de: "Spule lösen", fr: "Retirer la bobine", es: "Quitar bobina", pt: "Remover bobina", it: "Rimuovi bobina", zh: "清除料盘")
                ) { id in
                    printer.assignSpoolManually(channel: box.id, spoolId: id)
                    pickChannel = nil
                    reloadSoon()
                }
            }
        }
    }

    /// Everything worth explaining about this screen, in one place.
    private var explanation: String {
        let base = lz(
            en: "“Read spool tags” re-reads the RFID tag in every channel on the printer. Linking a tag to a spool makes the assignment follow that spool — also when you swap it to another nozzle.",
            de: "„Spulen-Tags lesen“ liest das RFID-Tag in jedem Kanal am Drucker neu ein. Wird ein Tag mit einer Spule verknüpft, wandert die Zuordnung mit dieser Spule mit — auch beim Wechsel auf eine andere Düse.",
            fr: "« Lire les tags » relit le tag RFID de chaque canal. Lier un tag à une bobine fait suivre l'attribution avec cette bobine, même changée de buse.",
            es: "«Leer etiquetas» vuelve a leer la etiqueta RFID de cada canal. Vincular una etiqueta a una bobina hace que la asignación la siga, incluso al cambiarla de boquilla.",
            pt: "“Ler etiquetas” relê a etiqueta RFID de cada canal. Vincular uma etiqueta a uma bobina faz a atribuição segui-la, mesmo trocando de bico.",
            it: "«Leggi i tag» rilegge il tag RFID di ogni canale. Collegare un tag a una bobina fa seguire l'assegnazione a quella bobina, anche cambiando ugello.",
            zh: "“读取料盘标签”会重新读取各通道的 RFID 标签。将标签关联到料盘后，分配会跟随该料盘，换到其他喷嘴也一样。")
        guard !printer.spoollinkCommandsReady else { return base }
        return base + "\n\n" + lz(
            en: "This firmware has no manual assignment command (SET_SPOOL_ID), so linking the tag is the way to assign a spool.",
            de: "Diese Firmware kennt keinen Befehl zur manuellen Zuweisung (SET_SPOOL_ID) — die Zuweisung läuft deshalb über das Verknüpfen des Tags.",
            fr: "Ce firmware n'a pas de commande d'attribution manuelle (SET_SPOOL_ID) : l'attribution passe donc par le tag.",
            es: "Este firmware no tiene comando de asignación manual (SET_SPOOL_ID); la asignación se hace vinculando la etiqueta.",
            pt: "Este firmware não tem comando de atribuição manual (SET_SPOOL_ID); a atribuição é feita vinculando a etiqueta.",
            it: "Questo firmware non ha un comando di assegnazione manuale (SET_SPOOL_ID): l'assegnazione avviene collegando il tag.",
            zh: "此固件没有手动分配命令（SET_SPOOL_ID），因此通过关联标签来分配料盘。")
    }

    // One comparison line: what the tag says vs what the printer has loaded.
    @ViewBuilder
    private func mismatchRow(_ label: String, _ tag: String, _ printerVal: String, showsColour: Bool = false) -> some View {
        let differs = !tag.isEmpty && !printerVal.isEmpty
            && tag.caseInsensitiveCompare(printerVal) != .orderedSame
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            if showsColour, !tag.isEmpty { ColorDot(hex: tag, size: 10) }
            Text(tag.isEmpty ? "–" : tag)
                .font(.caption2).foregroundStyle(differs ? .orange : .secondary)
            Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.tertiary)
            if showsColour, !printerVal.isEmpty { ColorDot(hex: printerVal, size: 10) }
            Text(printerVal.isEmpty ? "–" : printerVal)
                .font(.caption2).foregroundStyle(differs ? .orange : .secondary)
            Spacer(minLength: 0)
        }
    }

    /// Spoolman needs a moment to store the change; re-read so the row shows the
    /// new link immediately instead of only after closing and reopening.
    private func reloadSoon() {
        Task {
            for delay in [0.4, 1.2] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await loadSpools()
            }
        }
    }

    private func loadSpools() async {
        guard let svc = SpoolmanService(rawHost: spoolmanURL) else { return }
        if let list = try? await svc.spools(includeArchived: false) {
            await MainActor.run { self.spools = list }
            await MainActor.run { printer.refreshSpoolCardIndex() }
        }
    }
}
