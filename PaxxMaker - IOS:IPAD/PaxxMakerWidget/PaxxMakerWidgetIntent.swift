import AppIntents
import WidgetKit

private func lz(en: String, de: String, fr: String, es: String, pt: String = "", it: String = "", zh: String = "") -> String {
    // Follow the language chosen in the app (mirrored into the shared app
    // group); only fall back to the system language if it was never set.
    let code = UserDefaults(suiteName: "group.paxxmaker.u1")?.string(forKey: "app_language")
        ?? Locale.current.language.languageCode?.identifier ?? "en"
    switch code {
    case "de": return de
    case "fr": return fr
    case "es": return es
    case "pt": return pt.isEmpty ? en : pt
    case "it": return it.isEmpty ? en : it
    case "zh": return zh.isEmpty ? en : zh
    default: return en
    }
}

// MARK: - Printer App Entity
struct PrinterEntity: AppEntity {
    var id: String
    var name: String

    // NOTE: AppIntents strings are extracted at BUILD time, so they must stay
    // literals — they cannot use lz(). They are localized by Apple via a String
    // Catalog and follow the system language, unlike the widget's own content.
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Printer"
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
    static var defaultQuery = PrinterEntityQuery()
}

// MARK: - Query
struct PrinterEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PrinterEntity] {
        allEntities().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [PrinterEntity] {
        let entities = allEntities()
        guard !entities.isEmpty else {
            return [PrinterEntity(id: "__none__", name: lz(en: "No printer found – open app", de: "Kein Drucker gefunden – App öffnen", fr: "Aucune imprimante – ouvrir l'app", es: "Sin impresora – abrir app", pt: "Nenhuma impressora encontrada – abrir app", it: "Nessuna stampante trovata – apri l'app", zh: "未找到打印机——请打开应用"))]
        }
        return entities
    }
    func defaultResult() async -> PrinterEntity? { nil }

    private func allEntities() -> [PrinterEntity] {
        PrinterWidgetEntry.loadAll().map { PrinterEntity(id: $0.id, name: $0.name) }
    }
}

// MARK: - Configuration Intent
struct SelectPrinterIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Select Printer"
    static var description = IntentDescription("Select the printer for this widget.")

    @Parameter(title: "Printer")
    var printer: PrinterEntity?
}
