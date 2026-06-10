import AppIntents
import WidgetKit

private func lz(en: String, de: String, fr: String, es: String) -> String {
    let code = Locale.current.language.languageCode?.identifier ?? "en"
    switch code { case "de": return de; case "fr": return fr; case "es": return es; default: return en }
}

// MARK: - Printer App Entity
struct PrinterEntity: AppEntity {
    var id: String
    var name: String

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
            return [PrinterEntity(id: "__none__", name: lz(en: "No printer found – open app", de: "Kein Drucker gefunden – App öffnen", fr: "Aucune imprimante – ouvrir l'app", es: "Sin impresora – abrir app"))]
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
