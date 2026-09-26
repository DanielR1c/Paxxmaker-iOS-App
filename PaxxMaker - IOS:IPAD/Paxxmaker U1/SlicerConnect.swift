import SwiftUI
import Combine
import Network
import simd
import VisionKit
import Vision

// MARK: - EasyPrint, stage 2: the Mac does the slicing.
// PaxxMaker-Connect (separate project on the Desktop, a Mac menu bar app) wraps the installed OrcaSlicer in a
// small HTTP API on the LAN. This file is the phone's side of it: finding the
// Connect app, pairing with its code, listing Orca's profiles, running a job
// with the plate from the viewer, and sending the G-code to the printer.

// MARK: Client

struct ConnectConfig: Codable, Equatable {
    var host: String
    var port: Int
    var token: String
    var name: String

    static let key = "slicer_connect"
    static func load() -> ConnectConfig? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ConnectConfig.self, from: d)
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key) }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
    /// IPv6 addresses only work in a URL inside brackets.
    var baseURL: String {
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "http://\(h):\(port)"
    }

    /// Is this something a URL can be built from at all?
    static func usable(host: String) -> Bool {
        let t = host.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains(" ") else { return false }
        return ConnectConfig(host: t, port: 8765, token: "", name: "").baseURL.isEmpty == false
            && URL(string: ConnectConfig(host: t, port: 8765, token: "", name: "").baseURL) != nil
    }
}

struct SlicerProfiles: Decodable {
    struct Preset: Decodable, Identifiable, Hashable {
        var name: String
        var origin: String
        var inherits: String?
        var compatible_printers: [String]?
        var bed_x: Double?
        var bed_y: Double?
        var bed_z: Double?
        var extruders: Int?
        var printer_model: String?
        var id: String { name }
    }
    var machine: [Preset]
    var process: [Preset]
    var filament: [Preset]
}

struct SliceJob: Decodable {
    /// A failed slice in plain words. OrcaSlicer only reports a number
    /// (Utils.hpp: negative codes, the process shows them as 256 + code), and
    /// a bare number helps nobody — so the meaning is spelled out and the
    /// number kept at the end, for a bug report.
    static func explain(code: Int?, message: String?) -> String {
        // PaxxMaker-Connect already prefixes its message with the number.
        var detail = (message ?? "").trimmingCharacters(in: .whitespaces)
        if let r = detail.range(of: #"^Orca Exit -?\d+\s*(–|-)?\s*"#, options: .regularExpression) {
            detail.removeSubrange(r)
        }
        guard let code else { return detail.isEmpty ? unknownText : detail }
        let orca = code >= 128 ? code - 256 : code
        var out = text(orca) ?? unknownText
        // Only when this side has nothing to say about the code: then the
        // detail from the computer (log excerpt) is all there is.
        if text(orca) == nil, !detail.isEmpty { out += "\n" + detail }
        out += "\n(OrcaSlicer \(code))"
        return out
    }

    /// Kept for older call sites.
    static func readable(code: Int?) -> String? { code.map { explain(code: $0, message: nil) } }

    private static var unknownText: String {
        lz(en: "OrcaSlicer stopped with an error of its own. The details are in the log of PaxxMaker-Connect on the computer.",
           de: "OrcaSlicer hat mit einem eigenen Fehler abgebrochen. Einzelheiten stehen im Protokoll von PaxxMaker-Connect auf dem Computer.",
           fr: "OrcaSlicer s'est arrêté sur une erreur interne. Les détails sont dans le journal de PaxxMaker-Connect sur l'ordinateur.",
           es: "OrcaSlicer se detuvo con un error propio. Los detalles están en el registro de PaxxMaker-Connect en el ordenador.",
           pt: "O OrcaSlicer parou com um erro próprio. Os detalhes estão no registo do PaxxMaker-Connect no computador.",
           it: "OrcaSlicer si è interrotto con un errore interno. I dettagli sono nel registro di PaxxMaker-Connect sul computer.",
           zh: "OrcaSlicer 因自身错误中止。详细信息在电脑上 PaxxMaker-Connect 的日志里。")
    }

    /// One sentence per exit code, with what to do where that is clear.
    private static func text(_ code: Int) -> String? {
        switch code {
        case -1:
            return lz(en: "OrcaSlicer could not start properly on the computer. Open it once by hand and try again.",
                      de: "OrcaSlicer konnte auf dem Computer nicht richtig starten. Öffne es dort einmal von Hand und versuche es erneut.",
                      fr: "OrcaSlicer n'a pas pu démarrer correctement sur l'ordinateur. Ouvre-le une fois à la main puis réessaie.",
                      es: "OrcaSlicer no pudo arrancar bien en el ordenador. Ábrelo una vez a mano y vuelve a intentarlo.",
                      pt: "O OrcaSlicer não conseguiu iniciar no computador. Abra-o uma vez à mão e tente de novo.",
                      it: "OrcaSlicer non è riuscito ad avviarsi sul computer. Aprilo una volta a mano e riprova.",
                      zh: "OrcaSlicer 在电脑上未能正常启动。请在电脑上手动打开一次后重试。")
        case -2:
            return lz(en: "OrcaSlicer rejected the instructions it was given. A setting in the slice screen probably holds a value it does not accept.",
                      de: "OrcaSlicer hat die Anweisungen abgelehnt. Wahrscheinlich steht in einer Einstellung auf der Slice-Seite ein Wert, den es nicht annimmt.",
                      fr: "OrcaSlicer a refusé les instructions reçues. Un réglage de la page de tranchage contient sans doute une valeur qu'il n'accepte pas.",
                      es: "OrcaSlicer rechazó las instrucciones. Probablemente un ajuste de la página de laminado tiene un valor que no acepta.",
                      pt: "O OrcaSlicer recusou as instruções. Provavelmente um ajuste na página de fatiamento tem um valor que ele não aceita.",
                      it: "OrcaSlicer ha rifiutato le istruzioni. Probabilmente un'impostazione della pagina di slicing ha un valore che non accetta.",
                      zh: "OrcaSlicer 拒绝了收到的指令。可能是切片页面上的某个设置填了它不接受的值。")
        case -3, -4, -6:
            return lz(en: "OrcaSlicer could not read a file it was handed. Send the model again.",
                      de: "OrcaSlicer konnte eine übergebene Datei nicht lesen. Schicke das Modell noch einmal.",
                      fr: "OrcaSlicer n'a pas pu lire un fichier transmis. Renvoie le modèle.",
                      es: "OrcaSlicer no pudo leer un archivo recibido. Envía el modelo otra vez.",
                      pt: "O OrcaSlicer não conseguiu ler um ficheiro recebido. Envie o modelo novamente.",
                      it: "OrcaSlicer non è riuscito a leggere un file ricevuto. Invia di nuovo il modello.",
                      zh: "OrcaSlicer 无法读取传过去的文件。请重新发送模型。")
        case -5:
            return lz(en: "OrcaSlicer rejected one of the profiles. Choose another filament or process profile — an incomplete filament profile is the usual cause on a multi-colour print.",
                      de: "OrcaSlicer hat eines der Profile abgelehnt. Wähle ein anderes Filament- oder Prozessprofil — bei Mehrfarbdrucken ist meist ein unvollständiges Filamentprofil schuld.",
                      fr: "OrcaSlicer a refusé l'un des profils. Choisis un autre profil de filament ou de processus — sur une impression multicolore, c'est souvent un profil de filament incomplet.",
                      es: "OrcaSlicer rechazó uno de los perfiles. Elige otro perfil de filamento o de proceso: en impresiones multicolor suele ser un perfil de filamento incompleto.",
                      pt: "O OrcaSlicer recusou um dos perfis. Escolha outro perfil de filamento ou de processo — em impressões multicolor costuma ser um perfil de filamento incompleto.",
                      it: "OrcaSlicer ha rifiutato uno dei profili. Scegli un altro profilo di filamento o di processo — nelle stampe multicolore di solito è un profilo di filamento incompleto.",
                      zh: "OrcaSlicer 拒绝了其中一个配置。请改用其他耗材或工艺配置——多色打印时通常是耗材配置不完整。")
        case -7, -8:
            return lz(en: "OrcaSlicer's command line does not support this printer or this operation.",
                      de: "Die Kommandozeile von OrcaSlicer unterstützt diesen Drucker oder diesen Vorgang nicht.",
                      fr: "La ligne de commande d'OrcaSlicer ne prend pas en charge cette imprimante ou cette opération.",
                      es: "La línea de comandos de OrcaSlicer no admite esta impresora o esta operación.",
                      pt: "A linha de comando do OrcaSlicer não suporta esta impressora ou esta operação.",
                      it: "La riga di comando di OrcaSlicer non supporta questa stampante o questa operazione.",
                      zh: "OrcaSlicer 的命令行不支持这台打印机或此操作。")
        case -9, -10, -21, -22:
            return lz(en: "OrcaSlicer could not place or scale the objects by itself. Arrange them on the plate by hand.",
                      de: "OrcaSlicer konnte die Objekte nicht selbst anordnen oder skalieren. Ordne sie auf der Platte von Hand an.",
                      fr: "OrcaSlicer n'a pas pu placer ou redimensionner les objets. Dispose-les à la main sur le plateau.",
                      es: "OrcaSlicer no pudo colocar o escalar los objetos. Colócalos a mano en la placa.",
                      pt: "O OrcaSlicer não conseguiu posicionar ou redimensionar os objetos. Organize-os à mão na mesa.",
                      it: "OrcaSlicer non è riuscito a disporre o ridimensionare gli oggetti. Sistemali a mano sul piano.",
                      zh: "OrcaSlicer 无法自动摆放或缩放对象。请在打印板上手动排列。")
        case -11, -12, -13:
            return lz(en: "OrcaSlicer could not write the result. Check that there is free space on the computer.",
                      de: "OrcaSlicer konnte das Ergebnis nicht schreiben. Prüfe, ob auf dem Computer noch Platz frei ist.",
                      fr: "OrcaSlicer n'a pas pu écrire le résultat. Vérifie l'espace libre sur l'ordinateur.",
                      es: "OrcaSlicer no pudo escribir el resultado. Comprueba si queda espacio libre en el ordenador.",
                      pt: "O OrcaSlicer não conseguiu gravar o resultado. Verifique se há espaço livre no computador.",
                      it: "OrcaSlicer non è riuscito a scrivere il risultato. Controlla lo spazio libero sul computer.",
                      zh: "OrcaSlicer 无法写出结果。请检查电脑上是否还有可用空间。")
        case -14:
            return lz(en: "OrcaSlicer ran out of memory. A smaller layer height or fewer objects helps.",
                      de: "OrcaSlicer ist der Speicher ausgegangen. Weniger Objekte oder eine gröbere Layerhöhe helfen.",
                      fr: "OrcaSlicer a manqué de mémoire. Moins d'objets ou une hauteur de couche plus grande aide.",
                      es: "OrcaSlicer se quedó sin memoria. Ayuda reducir objetos o usar una altura de capa mayor.",
                      pt: "O OrcaSlicer ficou sem memória. Ajuda usar menos objetos ou uma altura de camada maior.",
                      it: "OrcaSlicer ha esaurito la memoria. Aiutano meno oggetti o un'altezza layer maggiore.",
                      zh: "OrcaSlicer 内存不足。减少对象或加大层高会有帮助。")
        case -15, -16, -18, -19, -23, -24:
            return lz(en: "The data sent does not fit this printer or this OrcaSlicer version. Pick the printer profile again.",
                      de: "Die übergebenen Daten passen nicht zu diesem Drucker oder zu dieser OrcaSlicer-Version. Wähle das Druckerprofil neu.",
                      fr: "Les données envoyées ne correspondent pas à cette imprimante ou à cette version d'OrcaSlicer. Resélectionne le profil d'imprimante.",
                      es: "Los datos enviados no encajan con esta impresora o versión de OrcaSlicer. Vuelve a elegir el perfil de impresora.",
                      pt: "Os dados enviados não servem para esta impressora ou versão do OrcaSlicer. Escolha o perfil da impressora de novo.",
                      it: "I dati inviati non corrispondono a questa stampante o versione di OrcaSlicer. Riseleziona il profilo stampante.",
                      zh: "发送的数据与这台打印机或此 OrcaSlicer 版本不匹配。请重新选择打印机配置。")
        case -17:
            return lz(en: "The process profile does not fit this printer. Choose another one.",
                      de: "Das Prozessprofil passt nicht zu diesem Drucker. Wähle ein anderes.",
                      fr: "Le profil de processus ne convient pas à cette imprimante. Choisis-en un autre.",
                      es: "El perfil de proceso no encaja con esta impresora. Elige otro.",
                      pt: "O perfil de processo não serve para esta impressora. Escolha outro.",
                      it: "Il profilo di processo non è adatto a questa stampante. Scegline un altro.",
                      zh: "工艺配置与这台打印机不匹配。请选择其他配置。")
        case -20, -52:
            return lz(en: "An object sticks out of the print volume. Move it towards the middle or make it smaller.",
                      de: "Ein Objekt ragt aus dem Druckraum. Schiebe es zur Mitte oder mache es kleiner.",
                      fr: "Un objet dépasse du volume d'impression. Rapproche-le du centre ou réduis-le.",
                      es: "Un objeto sobresale del volumen de impresión. Muévelo al centro o hazlo más pequeño.",
                      pt: "Um objeto sai do volume de impressão. Mova-o para o centro ou reduza-o.",
                      it: "Un oggetto esce dal volume di stampa. Spostalo verso il centro o rimpiccioliscilo.",
                      zh: "有对象超出打印空间。请移向中间或缩小它。")
        case -50, -60:
            return lz(en: "Nothing printable is left on the plate.",
                      de: "Auf der Platte ist nichts Druckbares übrig.",
                      fr: "Il ne reste rien d'imprimable sur le plateau.",
                      es: "No queda nada imprimible en la placa.",
                      pt: "Não sobra nada imprimível na mesa.",
                      it: "Sul piano non resta nulla di stampabile.",
                      zh: "打印板上没有可打印的东西了。")
        case -51:
            return lz(en: "OrcaSlicer's own check refused the print. Often an object outside the plate or an impossible setting.",
                      de: "Die eigene Prüfung von OrcaSlicer hat den Druck abgelehnt. Meist liegt ein Objekt außerhalb der Platte oder eine Einstellung ist unmöglich.",
                      fr: "La vérification d'OrcaSlicer a refusé l'impression. Souvent un objet hors plateau ou un réglage impossible.",
                      es: "La comprobación de OrcaSlicer rechazó la impresión. Suele ser un objeto fuera de la placa o un ajuste imposible.",
                      pt: "A verificação do OrcaSlicer recusou a impressão. Normalmente um objeto fora da mesa ou um ajuste impossível.",
                      it: "Il controllo di OrcaSlicer ha rifiutato la stampa. Di solito un oggetto fuori dal piano o un'impostazione impossibile.",
                      zh: "OrcaSlicer 的自检拒绝了本次打印。通常是有对象超出打印板或某个设置无法实现。")
        case -53, -54, -55, -56, -57:
            return lz(en: "OrcaSlicer could not use its working folder on the computer. Restart PaxxMaker-Connect there.",
                      de: "OrcaSlicer konnte seinen Arbeitsordner auf dem Computer nicht nutzen. Starte PaxxMaker-Connect dort neu.",
                      fr: "OrcaSlicer n'a pas pu utiliser son dossier de travail. Redémarre PaxxMaker-Connect sur l'ordinateur.",
                      es: "OrcaSlicer no pudo usar su carpeta de trabajo. Reinicia PaxxMaker-Connect en el ordenador.",
                      pt: "O OrcaSlicer não conseguiu usar a sua pasta de trabalho. Reinicie o PaxxMaker-Connect no computador.",
                      it: "OrcaSlicer non è riuscito a usare la sua cartella di lavoro. Riavvia PaxxMaker-Connect sul computer.",
                      zh: "OrcaSlicer 无法使用它的工作文件夹。请在电脑上重新启动 PaxxMaker-Connect。")
        case -58:
            return lz(en: "Slicing took too long and was stopped. Fewer objects or a bigger layer height help.",
                      de: "Das Slicen hat zu lange gedauert und wurde abgebrochen. Weniger Objekte oder eine gröbere Layerhöhe helfen.",
                      fr: "Le tranchage a pris trop de temps et a été interrompu. Moins d'objets ou une couche plus épaisse aide.",
                      es: "El laminado tardó demasiado y se detuvo. Ayuda usar menos objetos o capas más gruesas.",
                      pt: "O fatiamento demorou demais e foi interrompido. Ajuda usar menos objetos ou camadas mais altas.",
                      it: "Lo slicing ha impiegato troppo ed è stato interrotto. Aiutano meno oggetti o layer più spessi.",
                      zh: "切片耗时过长已被中止。减少对象或加大层高会有帮助。")
        case -59:
            return lz(en: "The model has too many triangles for OrcaSlicer. Simplify it before sending.",
                      de: "Das Modell hat zu viele Dreiecke für OrcaSlicer. Vereinfache es vor dem Senden.",
                      fr: "Le modèle a trop de triangles pour OrcaSlicer. Simplifie-le avant l'envoi.",
                      es: "El modelo tiene demasiados triángulos para OrcaSlicer. Simplifícalo antes de enviarlo.",
                      pt: "O modelo tem triângulos demais para o OrcaSlicer. Simplifique-o antes de enviar.",
                      it: "Il modello ha troppi triangoli per OrcaSlicer. Semplificalo prima di inviarlo.",
                      zh: "模型三角面过多，OrcaSlicer 处理不了。请先简化后再发送。")
        case -61:
            return lz(en: "The filament does not go with the plate the printer uses. Choose another filament or another plate.",
                      de: "Das Filament passt nicht zur eingestellten Druckplatte. Wähle ein anderes Filament oder eine andere Platte.",
                      fr: "Le filament ne convient pas au plateau réglé. Choisis un autre filament ou un autre plateau.",
                      es: "El filamento no va con la placa configurada. Elige otro filamento u otra placa.",
                      pt: "O filamento não combina com a mesa configurada. Escolha outro filamento ou outra mesa.",
                      it: "Il filamento non è adatto al piano impostato. Scegli un altro filamento o un altro piano.",
                      zh: "耗材与所选打印板不匹配。请换耗材或换打印板。")
        case -62:
            return lz(en: "The chosen filaments need different bed temperatures and cannot be printed together.",
                      de: "Die gewählten Filamente brauchen unterschiedliche Betttemperaturen und lassen sich nicht zusammen drucken.",
                      fr: "Les filaments choisis demandent des températures de plateau différentes et ne peuvent pas être imprimés ensemble.",
                      es: "Los filamentos elegidos necesitan temperaturas de cama distintas y no se pueden imprimir juntos.",
                      pt: "Os filamentos escolhidos precisam de temperaturas de mesa diferentes e não podem ser impressos juntos.",
                      it: "I filamenti scelti richiedono temperature del piano diverse e non si possono stampare insieme.",
                      zh: "所选耗材需要不同的热床温度，无法一起打印。")
        case -63:
            return lz(en: "Printing object by object, the print head would hit an already printed part. Move the objects apart or print by layer.",
                      de: "Beim Druck nach Objekt würde der Kopf ein fertiges Teil treffen. Objekte weiter auseinander stellen oder nach Layer drucken.",
                      fr: "En impression objet par objet, la tête heurterait une pièce déjà imprimée. Écarte les objets ou imprime par couche.",
                      es: "Imprimiendo objeto por objeto, el cabezal chocaría con una pieza ya impresa. Sepáralos o imprime por capa.",
                      pt: "Imprimindo objeto a objeto, a cabeça bateria numa peça já impressa. Afaste os objetos ou imprima por camada.",
                      it: "Stampando oggetto per oggetto, la testa colpirebbe un pezzo già stampato. Allontana gli oggetti o stampa per layer.",
                      zh: "逐个打印时喷头会撞到已打印的部件。请把对象拉开距离，或改为逐层打印。")
        case -64, -101:
            return lz(en: "The print paths collide: objects are too close together, or one touches the prime tower. Move them apart.",
                      de: "Die Druckpfade überschneiden sich: Objekte liegen zu nah beieinander, oder eines berührt den Reinigungsturm. Schiebe sie auseinander.",
                      fr: "Les trajectoires se chevauchent : objets trop proches ou contact avec la tour de purge. Écarte-les.",
                      es: "Las trayectorias chocan: los objetos están demasiado juntos o uno toca la torre de purga. Sepáralos.",
                      pt: "Os percursos colidem: objetos muito próximos ou um toca na torre de purga. Afaste-os.",
                      it: "I percorsi si sovrappongono: oggetti troppo vicini o contatto con la torre di spurgo. Allontanali.",
                      zh: "打印路径相撞：对象之间太近，或碰到了擦料塔。请拉开距离。")
        case -65:
            return lz(en: "Spiral vase does not work with these settings — it needs one object, one wall and no top layers.",
                      de: "Die Spiralvase passt nicht zu diesen Einstellungen — sie braucht ein Objekt, eine Wand und keine oberen Schichten.",
                      fr: "Le mode vase spirale ne va pas avec ces réglages — il faut un objet, une paroi et aucune couche supérieure.",
                      es: "El vaso en espiral no funciona con estos ajustes: necesita un objeto, una pared y ninguna capa superior.",
                      pt: "O vaso espiral não funciona com estes ajustes: precisa de um objeto, uma parede e nenhuma camada superior.",
                      it: "Il vaso a spirale non funziona con queste impostazioni: servono un oggetto, una parete e nessun layer superiore.",
                      zh: "螺旋花瓶模式与当前设置冲突——需要单个对象、一层墙且没有顶层。")
        case -66:
            return lz(en: "The filaments could not be assigned to the heads. Check which head each object uses.",
                      de: "Die Filamente ließen sich den Köpfen nicht zuordnen. Prüfe, welcher Kopf für welches Objekt eingestellt ist.",
                      fr: "Impossible d'attribuer les filaments aux têtes. Vérifie la tête choisie pour chaque objet.",
                      es: "No se pudieron asignar los filamentos a los cabezales. Revisa qué cabezal usa cada objeto.",
                      pt: "Não foi possível atribuir os filamentos às cabeças. Verifique que cabeça cada objeto usa.",
                      it: "Impossibile assegnare i filamenti alle teste. Controlla quale testa usa ogni oggetto.",
                      zh: "无法把耗材分配到喷头。请检查每个对象使用的喷头。")
        case -67:
            return lz(en: "Only one TPU filament can be used per print.",
                      de: "Pro Druck ist nur ein TPU-Filament möglich.",
                      fr: "Un seul filament TPU par impression.",
                      es: "Solo se puede usar un filamento TPU por impresión.",
                      pt: "Só é possível um filamento TPU por impressão.",
                      it: "È possibile un solo filamento TPU per stampa.",
                      zh: "每次打印只能使用一种 TPU 耗材。")
        case -68:
            return lz(en: "One of the filaments does not suit the head it is meant for.",
                      de: "Eines der Filamente passt nicht zu dem Kopf, für den es gedacht ist.",
                      fr: "L'un des filaments ne convient pas à la tête prévue.",
                      es: "Uno de los filamentos no es apto para el cabezal previsto.",
                      pt: "Um dos filamentos não serve para a cabeça prevista.",
                      it: "Uno dei filamenti non è adatto alla testa prevista.",
                      zh: "其中一种耗材不适合指定的喷头。")
        case -100:
            return lz(en: "Slicing itself failed. Check the model in OrcaSlicer — broken geometry is the usual cause.",
                      de: "Das Slicen selbst ist fehlgeschlagen. Prüfe das Modell in OrcaSlicer — meist ist die Geometrie defekt.",
                      fr: "Le tranchage lui-même a échoué. Vérifie le modèle dans OrcaSlicer — souvent une géométrie défectueuse.",
                      es: "El laminado falló. Revisa el modelo en OrcaSlicer: normalmente es geometría dañada.",
                      pt: "O fatiamento falhou. Verifique o modelo no OrcaSlicer — normalmente é geometria defeituosa.",
                      it: "Lo slicing è fallito. Controlla il modello in OrcaSlicer — di solito la geometria è difettosa.",
                      zh: "切片本身失败。请在 OrcaSlicer 中检查模型——通常是几何数据损坏。")
        case -102:
            return lz(en: "The print paths leave the printable area. Move the object towards the middle.",
                      de: "Die Druckpfade liegen außerhalb des Druckbereichs. Schiebe das Objekt weiter zur Mitte.",
                      fr: "Les trajectoires sortent de la zone imprimable. Rapproche l'objet du centre.",
                      es: "Las trayectorias salen del área imprimible. Acerca el objeto al centro.",
                      pt: "Os percursos saem da área imprimível. Mova o objeto para o centro.",
                      it: "I percorsi escono dall'area stampabile. Sposta l'oggetto verso il centro.",
                      zh: "打印路径超出可打印区域。请把对象移向中间。")
        default:
            return nil
        }
    }

    struct Result: Decodable {
        var time_s: Int?
        var filament_g: Double?
        var filament_g_tools: [Double]?
        var filament_mm: Double?
        var cost: Double?
        var layers: Int?
        var height_mm: Double?
        var gcode: String?
        var size: Int?
        var support: [String: String]?
    }
    var id: String
    var state: String
    var progress: Double
    var stage: String
    var error_code: Int?
    var error: String?
    var result: Result?
}

enum ConnectError: LocalizedError {
    case unreachable, badCode, http(Int), decode, badAddress
    var errorDescription: String? {
        switch self {
        case .unreachable: return lz(en: "PaxxMaker-Connect not reachable — is it running on the computer?", de: "PaxxMaker-Connect nicht erreichbar — läuft es am Computer?", fr: "PaxxMaker-Connect injoignable — tourne-t-il sur l'ordinateur ?", es: "PaxxMaker-Connect no accesible — ¿está en marcha en el ordenador?", pt: "PaxxMaker-Connect inacessível — está rodando no computador?", it: "PaxxMaker-Connect non raggiungibile — è in esecuzione sul computer?", zh: "无法连接 PaxxMaker-Connect——它在电脑上运行吗？")
        case .badAddress: return lz(en: "That is not an address the app can reach. Enter the computer's IP address, for example 192.168.1.20.",
                                    de: "Damit kann die App nichts anfangen. Gib die IP-Adresse des Computers ein, zum Beispiel 192.168.1.20.",
                                    fr: "Ce n'est pas une adresse joignable. Saisis l'adresse IP de l'ordinateur, par exemple 192.168.1.20.",
                                    es: "Esa no es una dirección que la app pueda usar. Escribe la IP del ordenador, por ejemplo 192.168.1.20.",
                                    pt: "Esse não é um endereço utilizável. Digite o IP do computador, por exemplo 192.168.1.20.",
                                    it: "Non è un indirizzo raggiungibile. Inserisci l'IP del computer, ad esempio 192.168.1.20.",
                                    zh: "这不是可用的地址。请输入电脑的 IP 地址，例如 192.168.1.20。")
        case .badCode: return lz(en: "Wrong pairing code.", de: "Falscher Kopplungscode.", fr: "Code d'appairage incorrect.", es: "Código de vinculación incorrecto.", pt: "Código de pareamento incorreto.", it: "Codice di associazione errato.", zh: "配对码错误。")
        case .http(let c): return ConnectError.httpText(c)
        case .decode: return lz(en: "Unexpected answer from PaxxMaker-Connect.", de: "Unerwartete Antwort von PaxxMaker-Connect.", fr: "Réponse inattendue de PaxxMaker-Connect.", es: "Respuesta inesperada de PaxxMaker-Connect.", pt: "Resposta inesperada do PaxxMaker-Connect.", it: "Risposta inattesa da PaxxMaker-Connect.", zh: "PaxxMaker-Connect 返回了意外的响应。")
        }
    }
}

extension ConnectError {
    /// A web error number on its own tells nobody anything — say what it means
    /// and keep the number for a bug report.
    static func httpText(_ code: Int) -> String {
        let meaning: String
        switch code {
        case 0:
            meaning = lz(en: "the computer gave no answer", de: "der Computer hat nicht geantwortet", fr: "l'ordinateur n'a pas répondu", es: "el ordenador no respondió", pt: "o computador não respondeu", it: "il computer non ha risposto", zh: "电脑没有回应")
        case 401, 403:
            meaning = lz(en: "the pairing is no longer valid — pair the app with the computer again",
                         de: "die Kopplung gilt nicht mehr — koppele die App erneut mit dem Computer",
                         fr: "l'appairage n'est plus valable — réappaire l'app avec l'ordinateur",
                         es: "la vinculación ya no vale — vuelve a vincular la app con el ordenador",
                         pt: "o pareamento já não vale — pareie a app com o computador de novo",
                         it: "l'associazione non è più valida — riassocia l'app al computer",
                         zh: "配对已失效——请重新把 App 与电脑配对")
        case 404:
            meaning = lz(en: "the computer does not know this request — PaxxMaker-Connect there is probably older than the app",
                         de: "der Computer kennt diese Anfrage nicht — PaxxMaker-Connect dort ist vermutlich älter als die App",
                         fr: "l'ordinateur ne connaît pas cette requête — PaxxMaker-Connect y est sans doute plus ancien que l'app",
                         es: "el ordenador no conoce esta petición — PaxxMaker-Connect allí es probablemente más antiguo que la app",
                         pt: "o computador não conhece este pedido — o PaxxMaker-Connect lá deve ser mais antigo que a app",
                         it: "il computer non conosce questa richiesta — PaxxMaker-Connect lì è probabilmente più vecchio dell'app",
                         zh: "电脑不认识该请求——那边的 PaxxMaker-Connect 可能比 App 旧")
        case 408, 504:
            meaning = lz(en: "the computer took too long to answer", de: "der Computer hat zu lange gebraucht", fr: "l'ordinateur a mis trop de temps", es: "el ordenador tardó demasiado", pt: "o computador demorou demais", it: "il computer ha impiegato troppo", zh: "电脑响应超时")
        case 413:
            meaning = lz(en: "the model is too large to send", de: "das Modell ist zu groß zum Senden", fr: "le modèle est trop gros à envoyer", es: "el modelo es demasiado grande para enviarlo", pt: "o modelo é grande demais para enviar", it: "il modello è troppo grande da inviare", zh: "模型太大，无法发送")
        case 500...599:
            meaning = lz(en: "something went wrong inside PaxxMaker-Connect on the computer",
                         de: "in PaxxMaker-Connect auf dem Computer ist etwas schiefgegangen",
                         fr: "un problème est survenu dans PaxxMaker-Connect sur l'ordinateur",
                         es: "algo falló dentro de PaxxMaker-Connect en el ordenador",
                         pt: "algo correu mal dentro do PaxxMaker-Connect no computador",
                         it: "qualcosa è andato storto in PaxxMaker-Connect sul computer",
                         zh: "电脑上的 PaxxMaker-Connect 内部出错")
        default:
            meaning = lz(en: "the computer refused the request", de: "der Computer hat die Anfrage abgelehnt", fr: "l'ordinateur a refusé la requête", es: "el ordenador rechazó la petición", pt: "o computador recusou o pedido", it: "il computer ha rifiutato la richiesta", zh: "电脑拒绝了该请求")
        }
        return meaning.prefix(1).uppercased() + meaning.dropFirst() + " (HTTP \(code))."
    }
}

struct ConnectClient {
    let config: ConnectConfig

    private func request(_ path: String, method: String = "GET", body: Data? = nil, headers: [String: String] = [:], timeout: TimeInterval = 20) throws -> URLRequest {
        // A Bonjour service name ("MacBook Air von Isabell") is not an address:
        // with the space in it there is no URL, and forcing one crashed the app.
        guard let url = URL(string: config.baseURL + path) else { throw ConnectError.badAddress }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue(config.token, forHTTPHeaderField: "X-Paxx-Token")
        headers.forEach { r.setValue($0.value, forHTTPHeaderField: $0.key) }
        r.httpBody = body
        return r
    }

    private func run<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw ConnectError.unreachable }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw ConnectError.badCode }
        guard (200..<300).contains(code) else { throw ConnectError.http(code) }
        guard let v = try? JSONDecoder().decode(T.self, from: data) else { throw ConnectError.decode }
        return v
    }

    struct Info: Decodable { var name: String; var version: String; var host: String; var orca: Bool; var apps: [String] }
    func info() async throws -> Info { try await run(try request("/v1/info", timeout: 6), as: Info.self) }

    func profiles(app: String) async throws -> SlicerProfiles {
        try await run(try request("/v1/profiles?app=\(app)"), as: SlicerProfiles.self)
    }

    /// One preset flattened through its inheritance chain (Orca's own keys and string values).
    func profile(app: String, kind: String, name: String) async throws -> [String: Any] {
        let n = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: try request("/v1/profile?app=\(app)&kind=\(kind)&name=\(n)")) }
        catch { throw ConnectError.unreachable }
        guard (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConnectError.decode }
        return d
    }

    struct Uploaded: Decodable { var model: String; var bytes: Int }
    func upload(_ data: Data, ext: String) async throws -> String {
        try await run(try request("/v1/models", method: "POST", body: data, headers: ["X-Paxx-Ext": ext], timeout: 120), as: Uploaded.self).model
    }

    func createJob(_ spec: [String: Any]) async throws -> SliceJob {
        let body = try JSONSerialization.data(withJSONObject: spec)
        return try await run(try request("/v1/jobs", method: "POST", body: body, headers: ["Content-Type": "application/json"]), as: SliceJob.self)
    }

    func job(_ id: String) async throws -> SliceJob { try await run(try request("/v1/jobs/\(id)", timeout: 10), as: SliceJob.self) }

    func gcode(_ id: String) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: try request("/v1/jobs/\(id)/gcode", timeout: 120))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw ConnectError.http((resp as? HTTPURLResponse)?.statusCode ?? 0) }
        return data
    }
}

// MARK: Discovery (Bonjour)

final class ConnectBrowser: ObservableObject {
    struct Found: Identifiable, Hashable { let id: String; let name: String; let endpoint: NWEndpoint }
    @Published var found: [Found] = []
    private var browser: NWBrowser?

    func start() {
        stop()
        let b = NWBrowser(for: .bonjour(type: "_paxxconnect._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let list = results.compactMap { r -> Found? in
                if case let .service(name, _, _, _) = r.endpoint { return Found(id: name, name: name, endpoint: r.endpoint) }
                return nil
            }
            DispatchQueue.main.async { self?.found = list }
        }
        b.start(queue: .main)
        browser = b
    }
    func stop() { browser?.cancel(); browser = nil }

    /// Bonjour hands out a service endpoint; the HTTP client needs host:port.
    /// A short TCP connect resolves it.
    static func resolve(_ endpoint: NWEndpoint) async -> (String, Int)? {
        final class Flag: @unchecked Sendable { nonisolated(unsafe) var done = false }
        return await withCheckedContinuation { cont in
            let c = NWConnection(to: endpoint, using: .tcp)
            let q = DispatchQueue(label: "paxxmaker.resolve")
            let flag = Flag()
            c.stateUpdateHandler = { st in
                guard !flag.done else { return }
                switch st {
                case .ready:
                    flag.done = true
                    if case let .hostPort(host, port)? = c.currentPath?.remoteEndpoint {
                        var h = "\(host)"
                        if let i = h.firstIndex(of: "%") { h = String(h[..<i]) }      // strip scope id
                        cont.resume(returning: (h, Int(port.rawValue)))
                    } else { cont.resume(returning: nil) }
                    c.cancel()
                case .failed, .cancelled:
                    flag.done = true; cont.resume(returning: nil)
                default: break
                }
            }
            c.start(queue: q)
            q.asyncAfter(deadline: .now() + 5) {
                if !flag.done { flag.done = true; c.cancel(); cont.resume(returning: nil) }
            }
        }
    }
}

// MARK: QR pairing — paxxmaker://connect?host=…&port=…&code=…&name=…
// Scanned with the iPhone's own camera; the app opens and pairs itself.

extension Notification.Name {
    static let paxxConnectPaired = Notification.Name("paxxmaker.connectPaired")
    /// "Done" after a send: close the slicer screens and show that printer.
    /// `object` is the printer's id as a string.
    static let paxxShowPrinter = Notification.Name("paxxmaker.showPrinter")
}

enum ConnectPairing {
    static func handle(_ url: URL) async -> String? {
        guard url.scheme == "paxxmaker", url.host == "connect",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func q(_ k: String) -> String? { items.first { $0.name == k }?.value }
        guard let host = q("host"), let code = q("code") else { return nil }
        let cfg = ConnectConfig(host: host, port: Int(q("port") ?? "") ?? 8765, token: code.uppercased(),
                                  name: q("name")?.removingPercentEncoding ?? host)
        do {
            let client = ConnectClient(config: cfg)
            let info = try await client.info()
            _ = try await client.profiles(app: info.apps.first ?? "orca")     // checks the code
            cfg.save()
            UserDefaults.standard.set(true, forKey: "show_slicer_tab")
            NotificationCenter.default.post(name: .paxxConnectPaired, object: nil)
            return lz(en: "Paired with \(cfg.name).", de: "Mit \(cfg.name) gekoppelt.", fr: "Appairé avec \(cfg.name).", es: "Vinculado con \(cfg.name).", pt: "Pareado com \(cfg.name).", it: "Associato a \(cfg.name).", zh: "已与 \(cfg.name) 配对。")
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: QR scanner (VisionKit) — reads PaxxMaker-Connect's QR in the app itself

struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    static var available: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           qualityLevel: .balanced, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }
    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        var fired = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !fired else { return }
            for item in added {
                if case let .barcode(b) = item, let s = b.payloadStringValue {
                    fired = true
                    scanner.stopScanning()
                    onCode(s)
                    return
                }
            }
        }
    }
}

struct QRPairSheet: View {
    var onResult: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    var body: some View {
        NavigationStack {
            ZStack {
                if QRScannerView.available {
                    QRScannerView { code in
                        guard !busy else { return }
                        busy = true
                        Task {
                            let msg = await ConnectPairing.handle(URL(string: code) ?? URL(string: "paxxmaker://none")!)
                            await MainActor.run {
                                onResult(msg ?? lz(en: "That is not a PaxxMaker-Connect code.", de: "Das ist kein PaxxMaker-Connect-Code.", fr: "Ce n'est pas un code PaxxMaker-Connect.", es: "No es un código de PaxxMaker-Connect.", pt: "Não é um código do PaxxMaker-Connect.", it: "Non è un codice PaxxMaker-Connect.", zh: "这不是 PaxxMaker-Connect 的二维码。"))
                                busy = false
                                dismiss()
                            }
                        }
                    }
                    .ignoresSafeArea()
                } else {
                    Text(lz(en: "Camera not available on this device.", de: "Kamera auf diesem Gerät nicht verfügbar.", fr: "Caméra indisponible sur cet appareil.", es: "Cámara no disponible en este dispositivo.", pt: "Câmera indisponível neste dispositivo.", it: "Fotocamera non disponibile su questo dispositivo.", zh: "此设备无法使用相机。"))
                }
                if busy { ProgressView().scaleEffect(1.5) }
                VStack {
                    Spacer()
                    Text(lz(en: "Point the camera at the QR code that PaxxMaker-Connect shows on the computer.", de: "Kamera auf den QR-Code richten, den PaxxMaker-Connect am Computer anzeigt.", fr: "Vise le QR code affiché par PaxxMaker-Connect sur l'ordinateur.", es: "Apunta la cámara al código QR que PaxxMaker-Connect muestra en el ordenador.", pt: "Aponte a câmera para o QR code que o PaxxMaker-Connect mostra no computador.", it: "Inquadra il QR code che PaxxMaker-Connect mostra sul computer.", zh: "将相机对准电脑上 PaxxMaker-Connect 显示的二维码。"))
                        .font(.footnote).multilineTextAlignment(.center)
                        .padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10)).padding()
                }
            }
            .navigationTitle(lz(en: "Scan QR code", de: "QR-Code scannen", fr: "Scanner le QR code", es: "Escanear código QR", pt: "Ler QR code", it: "Scansiona QR code", zh: "扫描二维码"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消")) { dismiss() } } }
        }
    }
}

// MARK: Pairing UI (lives in the slicer tab)

struct ConnectSection: View {
    @AppStorage("app_language") private var appLanguage: String = "en"
    @State private var config = ConnectConfig.load()
    @State private var showScanner = false
    @State private var scanMessage: String? = nil
    @State private var pendingMessage: String? = nil

    // Presentation modifiers must sit on ONE view: inside a Form a modifier on
    // the Section is applied to every row, which presented the scanner several
    // times at once and left it stuck. So the sheet and alerts live on single
    // rows below; only the (idempotent) notification handler stays up here.
    var body: some View {
        pairingSection
            // On the section itself: the QR rows vanish the moment pairing
            // succeeds, and an alert hung on them was left pending — it popped
            // up later, on unpairing, when those rows came back.
            .alert(lz(en: "PaxxMaker-Connect", de: "PaxxMaker-Connect", fr: "PaxxMaker-Connect", es: "PaxxMaker-Connect", pt: "PaxxMaker-Connect", it: "PaxxMaker-Connect", zh: "PaxxMaker-Connect"),
                   isPresented: Binding(get: { scanMessage != nil }, set: { if !$0 { scanMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(scanMessage ?? "") }
            .onReceive(NotificationCenter.default.publisher(for: .paxxConnectPaired)) { _ in
                config = ConnectConfig.load()
                // Unpaired: nothing from an earlier pairing is left to say.
                if config == nil { scanMessage = nil; pendingMessage = nil }
            }
    }

    /// The scan result is shown once the scanner sheet is gone; an alert on
    /// top of the sheet would fight its dismissal.
    private func showPendingResult() {
        guard let m = pendingMessage else { return }
        pendingMessage = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { scanMessage = m }
    }

    // Unpaired: two doors — QR code, or the manual page with the network
    // search and address entry. Both on one screen next to each other
    // confused people ("scan, or is the MacBook already there?").
    private var pairingSection: some View {
        Section {
            pairingRows
        } footer: {
            if config == nil {
                // The address is a tap target, not something to type off the
                // screen — markdown needs Text(.init(…)) to become a link.
                let link = "https://github.com/DanielR1c/PaxxMaker-Connect"
                Text(.init(lz(
                    en: "Install \"PaxxMaker-Connect\" on your Mac or Windows PC ([tap here](\(link))) and open it — it shows a QR code for pairing. Slicing then uses the OrcaSlicer installed there, with your own profiles, so the computer has to be switched on and awake while you slice.",
                    de: "„PaxxMaker-Connect“ auf dem Mac oder Windows-PC installieren ([hier klicken](\(link))) und öffnen — es zeigt einen QR-Code zum Koppeln. Gesliced wird dann mit dem dort installierten OrcaSlicer und deinen eigenen Profilen: Der Computer muss dabei laufen und darf nicht schlafen.",
                    fr: "Installe « PaxxMaker-Connect » sur ton Mac ou PC Windows ([cliquer ici](\(link))) et ouvre-le — il affiche un QR code pour l'appairage. Le tranchage utilise ensuite l'OrcaSlicer installé, avec tes profils : l'ordinateur doit donc être allumé et éveillé.",
                    es: "Instala «PaxxMaker-Connect» en tu Mac o PC con Windows ([pulsa aquí](\(link))) y ábrelo — muestra un código QR para vincular. El laminado usa entonces el OrcaSlicer instalado, con tus perfiles: el ordenador tiene que estar encendido y despierto.",
                    pt: "Instale o \"PaxxMaker-Connect\" no seu Mac ou PC com Windows ([toque aqui](\(link))) e abra-o — ele mostra um QR code para parear. O fatiamento usa então o OrcaSlicer instalado, com seus perfis: o computador precisa estar ligado e acordado.",
                    it: "Installa «PaxxMaker-Connect» sul Mac o su un PC Windows ([tocca qui](\(link))) e aprilo — mostra un QR code per l'associazione. Lo slicing usa poi l'OrcaSlicer installato, con i tuoi profili: il computer deve restare acceso e sveglio.",
                    zh: "在 Mac 或 Windows 电脑上安装“PaxxMaker-Connect”（[点这里](\(link))）并打开——它会显示用于配对的二维码。之后使用那里安装的 OrcaSlicer 和你自己的配置进行切片：切片时电脑必须开机且未休眠。")))
            }
        }
    }

    @ViewBuilder private var pairingRows: some View {
        if config != nil {
            ConnectStatusView()
        } else {
            if QRScannerView.available {
                Button { showScanner = true } label: {
                    HStack {
                        Image(systemName: "qrcode.viewfinder").foregroundColor(.accentColor).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lz(en: "Connect with QR code", de: "Per QR-Code verbinden", fr: "Connecter par QR code", es: "Conectar con código QR", pt: "Conectar por QR code", it: "Connetti con QR code", zh: "通过二维码连接"))
                            Text(lz(en: "Scan the code in the PaxxMaker-Connect window", de: "Den Code im PaxxMaker-Connect-Fenster scannen", fr: "Scanner le code de la fenêtre PaxxMaker-Connect", es: "Escanear el código de la ventana de PaxxMaker-Connect", pt: "Ler o código na janela do PaxxMaker-Connect", it: "Scansiona il codice nella finestra di PaxxMaker-Connect", zh: "扫描 PaxxMaker-Connect 窗口中的二维码"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .sheet(isPresented: $showScanner, onDismiss: showPendingResult) {
                    QRPairSheet { msg in pendingMessage = msg }
                }
            }
            NavigationLink {
                ManualPairPage()
            } label: {
                HStack {
                    Image(systemName: "network").foregroundColor(.accentColor).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lz(en: "Connect manually", de: "Manuell verbinden", fr: "Connecter manuellement", es: "Conectar manualmente", pt: "Conectar manualmente", it: "Connetti manualmente", zh: "手动连接"))
                        Text(lz(en: "Find the computer on the network or enter its address, then the code", de: "Computer im Netzwerk suchen oder Adresse eingeben, dann den Code", fr: "Chercher l'ordinateur sur le réseau ou saisir son adresse, puis le code", es: "Buscar el ordenador en la red o escribir su dirección, luego el código", pt: "Procurar o computador na rede ou digitar o endereço, depois o código", it: "Cerca il computer nella rete o inserisci l'indirizzo, poi il codice", zh: "在网络中查找电脑或输入地址，然后输入配对码"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

}

/// Manual pairing: the Macs found via Bonjour, or an address typed in; both
/// end in the code prompt. Pops back once the Mac answered.
/// The computer this app is paired with: name, state, version — and the hint
/// when a newer PaxxMaker-Connect is out. Used on the slicer page and, since
/// that is where people look for it, in Settings under the slicer switch.
struct ConnectStatusView: View {
    /// Called after unpairing, so the surrounding view can refresh.
    var onUnpair: () -> Void = {}
    @AppStorage("app_language") private var appLanguage: String = "en"
    @State private var config: ConnectConfig? = ConnectConfig.load()
    @State private var online: Bool? = nil
    @State private var info: ConnectClient.Info? = nil

    var body: some View {
        if let c = config {
            HStack {
                Image(systemName: online == true ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark")
                    .foregroundColor(online == true ? .green : (online == nil ? .secondary : .orange)).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.name.isEmpty ? c.host : c.name)
                    // Engine and profiles both come from the installed OrcaSlicer.
                    Text(statusLine)
                        .font(.caption).foregroundStyle(.secondary)
                    if let v = info?.version, !v.isEmpty {
                        Text("PaxxMaker-Connect \(v)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(lz(en: "Unpair", de: "Trennen", fr: "Dissocier", es: "Desvincular", pt: "Desparear", it: "Dissocia", zh: "解除配对")) {
                    ConnectConfig.clear(); config = nil; online = nil; info = nil
                    NotificationCenter.default.post(name: .paxxConnectPaired, object: nil)
                    onUnpair()
                }
                .font(.caption).foregroundColor(.red).buttonStyle(.plain)
            }
            .task(id: c) { await check(c) }
            .onReceive(NotificationCenter.default.publisher(for: .paxxConnectPaired)) { _ in
                config = ConnectConfig.load(); online = nil; info = nil
            }
            if let newer = ConnectUpdate.newer(than: info?.version), let url = URL(string: newer.url) {
                Link(destination: url) {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill").foregroundColor(.orange).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lz(en: "Version \(newer.version) available", de: "Version \(newer.version) verfügbar", fr: "Version \(newer.version) disponible", es: "Versión \(newer.version) disponible", pt: "Versão \(newer.version) disponível", it: "Versione \(newer.version) disponibile", zh: "有新版本 \(newer.version)"))
                            Text(lz(en: "Update PaxxMaker-Connect on the computer", de: "PaxxMaker-Connect am Computer aktualisieren", fr: "Mets à jour PaxxMaker-Connect sur l'ordinateur", es: "Actualiza PaxxMaker-Connect en el ordenador", pt: "Atualize o PaxxMaker-Connect no computador", it: "Aggiorna PaxxMaker-Connect sul computer", zh: "请在电脑上更新 PaxxMaker-Connect"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary).font(.caption)
                    }
                }
            }
        }
    }

    private var statusLine: String {
        guard online == true else {
            return online == nil ? "…" : lz(en: "not reachable", de: "nicht erreichbar", fr: "injoignable", es: "no accesible", pt: "inacessível", it: "non raggiungibile", zh: "无法连接")
        }
        guard let i = info else { return "" }
        return i.orca
            ? "OrcaSlicer ✓ · " + lz(en: "profiles found", de: "Profile gefunden", fr: "profils trouvés", es: "perfiles encontrados", pt: "perfis encontrados", it: "profili trovati", zh: "已找到配置")
            : "OrcaSlicer ✗"
    }

    private func check(_ c: ConnectConfig) async {
        online = nil
        if let i = try? await ConnectClient(config: c).info() { info = i; online = true } else { online = false }
    }
}

struct ManualPairPage: View {
    @AppStorage("app_language") private var appLanguage: String = "en"
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = ConnectBrowser()
    @State private var pairing: ConnectBrowser.Found? = nil
    @State private var manualHost = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String? = nil

    var body: some View {
        Form {
            Section(lz(en: "Found on the network", de: "Im Netzwerk gefunden", fr: "Trouvés sur le réseau", es: "Encontrados en la red", pt: "Encontrados na rede", it: "Trovati nella rete", zh: "网络中找到")) {
                ForEach(browser.found) { f in
                    Button { pairing = f } label: {
                        HStack {
                            Image(systemName: "desktopcomputer").foregroundColor(.blue).frame(width: 28)
                            Text(f.name)
                            Spacer()
                            Text(lz(en: "Pair", de: "Koppeln", fr: "Appairer", es: "Vincular", pt: "Parear", it: "Associa", zh: "配对")).foregroundColor(.accentColor)
                        }
                    }
                }
                if browser.found.isEmpty {
                    HStack {
                        ProgressView().frame(width: 28)
                        Text(lz(en: "Looking for PaxxMaker-Connect on the network…", de: "Suche PaxxMaker-Connect im Netzwerk…", fr: "Recherche de PaxxMaker-Connect sur le réseau…", es: "Buscando PaxxMaker-Connect en la red…", pt: "Procurando PaxxMaker-Connect na rede…", it: "Cerco PaxxMaker-Connect nella rete…", zh: "正在网络中查找 PaxxMaker-Connect…"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                HStack {
                    Image(systemName: "network").foregroundColor(.secondary).frame(width: 28)
                    TextField(lz(en: "IP address, e.g. 192.168.1.20", de: "IP-Adresse, z. B. 192.168.1.20", fr: "Adresse IP, ex. 192.168.1.20", es: "Dirección IP, p. ej. 192.168.1.20", pt: "Endereço IP, ex. 192.168.1.20", it: "Indirizzo IP, es. 192.168.1.20", zh: "IP 地址，例如 192.168.1.20"), text: $manualHost)
                        .textInputAutocapitalization(.never).disableAutocorrection(true).keyboardType(.URL)
                    if !manualHost.isEmpty {
                        Button(lz(en: "Pair", de: "Koppeln", fr: "Appairer", es: "Vincular", pt: "Parear", it: "Associa", zh: "配对")) {
                            let h = manualHost.trimmingCharacters(in: .whitespaces)
                            guard ConnectConfig.usable(host: h) else { error = ConnectError.badAddress.errorDescription; return }
                            error = nil
                            pairing = ConnectBrowser.Found(id: h, name: h, endpoint: .hostPort(host: NWEndpoint.Host(h), port: 8765))
                        }
                    }
                }
                .alert(lz(en: "Pairing code", de: "Kopplungscode", fr: "Code d'appairage", es: "Código de vinculación", pt: "Código de pareamento", it: "Codice di associazione", zh: "配对码"),
                       isPresented: Binding(get: { pairing != nil }, set: { if !$0 { pairing = nil } }), presenting: pairing) { f in
                    TextField("ABC123", text: $code).textInputAutocapitalization(.characters).disableAutocorrection(true)
                    Button(lz(en: "Pair", de: "Koppeln", fr: "Appairer", es: "Vincular", pt: "Parear", it: "Associa", zh: "配对")) { Task { await pair(f) } }
                    Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {}
                } message: { f in
                    Text(lz(en: "The code that PaxxMaker-Connect shows on the computer.", de: "Der Code, den PaxxMaker-Connect am Computer anzeigt.", fr: "Le code affiché par PaxxMaker-Connect sur l'ordinateur.", es: "El código que muestra PaxxMaker-Connect en el ordenador.", pt: "O código mostrado pelo PaxxMaker-Connect no computador.", it: "Il codice mostrato da PaxxMaker-Connect sul computer.", zh: "电脑上 PaxxMaker-Connect 显示的代码。"))
                }
            } header: {
                Text(lz(en: "Or by address", de: "Oder per Adresse", fr: "Ou par adresse", es: "O por dirección", pt: "Ou por endereço", it: "Oppure per indirizzo", zh: "或通过地址"))
            } footer: {
                Text(lz(en: "Computer and iPhone must be on the same Wi-Fi. The 6-character code is shown by PaxxMaker-Connect (Mac: the window of the menu bar cube, Windows: the page in the browser).",
                        de: "Computer und iPhone müssen im selben WLAN sein. Den 6-stelligen Code zeigt PaxxMaker-Connect an (Mac: Fenster des Würfels in der Menüleiste, Windows: Seite im Browser).",
                        fr: "L'ordinateur et l'iPhone doivent être sur le même Wi-Fi. Le code à 6 caractères est affiché par PaxxMaker-Connect (Mac : fenêtre du cube dans la barre des menus, Windows : page dans le navigateur).",
                        es: "El ordenador y el iPhone deben estar en la misma Wi-Fi. PaxxMaker-Connect muestra el código de 6 caracteres (Mac: ventana del cubo en la barra de menús, Windows: página en el navegador).",
                        pt: "Computador e iPhone precisam estar no mesmo Wi-Fi. O PaxxMaker-Connect mostra o código de 6 caracteres (Mac: janela do cubo na barra de menus, Windows: página no navegador).",
                        it: "Computer e iPhone devono essere nella stessa rete Wi-Fi. PaxxMaker-Connect mostra il codice a 6 caratteri (Mac: finestra del cubo nella barra dei menu, Windows: pagina nel browser).",
                        zh: "电脑和 iPhone 必须在同一 Wi-Fi 中。PaxxMaker-Connect 会显示 6 位配对码（Mac：菜单栏立方体的窗口；Windows：浏览器页面）。"))
            }
            if busy {
                HStack { ProgressView().frame(width: 28); Text(lz(en: "Pairing…", de: "Koppeln…", fr: "Appairage…", es: "Vinculando…", pt: "Pareando…", it: "Associazione…", zh: "正在配对…")).foregroundStyle(.secondary) }
            }
            if let e = error { Text(e).font(.caption).foregroundColor(.orange) }
        }
        .keyboardDismissable()
        .navigationTitle(lz(en: "Connect manually", de: "Manuell verbinden", fr: "Connecter manuellement", es: "Conectar manualmente", pt: "Conectar manualmente", it: "Connetti manualmente", zh: "手动连接"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private func pair(_ f: ConnectBrowser.Found) async {
        busy = true; error = nil
        defer { busy = false }
        var host = "", port = 8765
        if case let .hostPort(h, p) = f.endpoint {
            host = "\(h)"
            if let i = host.firstIndex(of: "%") { host = String(host[..<i]) }   // strip the scope id
            port = Int(p.rawValue)
        } else if let r = await ConnectBrowser.resolve(f.endpoint) {
            host = r.0; port = r.1
        }
        // Bonjour sometimes hands out no address at all (it happens in the
        // simulator). macOS builds its local name from the computer name by
        // turning the spaces into hyphens, so that is worth a try before
        // giving up.
        if !ConnectConfig.usable(host: host) {
            let guess = f.name.replacingOccurrences(of: " ", with: "-") + ".local"
            if ConnectConfig.usable(host: guess) { host = guess; port = 8765 }
        }
        // Without an address there is nothing to talk to — the name from the
        // network browser is not one.
        guard ConnectConfig.usable(host: host) else {
            error = lz(en: "The computer's address could not be found. Enter its IP address below.",
                       de: "Die Adresse des Computers war nicht zu ermitteln. Trage unten seine IP-Adresse ein.",
                       fr: "L'adresse de l'ordinateur n'a pas pu être déterminée. Saisis son adresse IP ci-dessous.",
                       es: "No se pudo averiguar la dirección del ordenador. Escribe su IP abajo.",
                       pt: "Não foi possível descobrir o endereço do computador. Digite o IP dele abaixo.",
                       it: "Non è stato possibile ricavare l'indirizzo del computer. Inserisci il suo IP qui sotto.",
                       zh: "无法获取电脑的地址。请在下方输入它的 IP 地址。")
            return
        }
        let cfg = ConnectConfig(host: host, port: port, token: code.trimmingCharacters(in: .whitespaces).uppercased(), name: f.name)
        do {
            _ = try await ConnectClient(config: cfg).profiles(app: "orca")
            cfg.save(); code = ""
            NotificationCenter.default.post(name: .paxxConnectPaired, object: nil)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: Slice settings + job

/// Orca's "simple mode" process settings — what the sidebar shows without
/// switching to advanced. Filled from the chosen process preset, edited
/// here, sent back as CLI overrides.
struct QuickSettings: Codable, Equatable {
    var process = ""                    // the preset these values came from
    var layerHeight = "0.2"
    var firstLayerHeight = "0.2"
    var seam = "aligned"
    var walls = 2
    var topLayers = 4
    var bottomLayers = 3
    var infill: Double = 15
    var infillPattern = "grid"
    var support = false
    var tree = true
    var plateOnly = false
    var thresholdAngle = 30
    var brimType = "auto_brim"
    var brimWidth = "5"
    var brimGap = "0.1"
    var skirtLoops = 0
    var spiral = false
    var sequence = "by layer"

    static let seams: [(String, String)] = [
        ("aligned", orcaLz(en: "Aligned", de: "Ausgerichtet", fr: "Alignée", es: "Alineada", pt: "Alinhada", it: "Allineata", zh: "对齐")),
        ("aligned_back", orcaLz(en: "Aligned back", de: "Ausgerichtet hinten", fr: "Alignée arrière", es: "Alineada atrás", pt: "Alinhada atrás", it: "Allineata dietro", zh: "对齐后侧")),
        ("nearest", orcaLz(en: "Nearest", de: "Nächste", fr: "Plus proche", es: "Más cercana", pt: "Mais próxima", it: "Più vicina", zh: "最近")),
        ("back", orcaLz(en: "Back", de: "Hinten", fr: "Arrière", es: "Atrás", pt: "Atrás", it: "Dietro", zh: "后侧")),
        ("random", orcaLz(en: "Random", de: "Zufällig", fr: "Aléatoire", es: "Aleatoria", pt: "Aleatória", it: "Casuale", zh: "随机")),
    ]
    static let patterns: [(String, String)] = [
        ("grid", orcaLz(en: "Grid", de: "Gitter", fr: "Grille", es: "Rejilla", pt: "Grade", it: "Griglia", zh: "网格")),
        ("gyroid", "Gyroid"),
        ("cubic", orcaLz(en: "Cubic", de: "Kubisch", fr: "Cubique", es: "Cúbico", pt: "Cúbico", it: "Cubico", zh: "立方体")),
        ("adaptivecubic", orcaLz(en: "Adaptive cubic", de: "Adaptiv kubisch", fr: "Cubique adaptatif", es: "Cúbico adaptativo", pt: "Cúbico adaptativo", it: "Cubico adattivo", zh: "自适应立方体")),
        ("crosshatch", orcaLz(en: "Cross hatch", de: "Kreuzschraffur", fr: "Hachures croisées", es: "Trama cruzada", pt: "Hachura cruzada", it: "Tratteggio incrociato", zh: "交叉线")),
        ("triangles", orcaLz(en: "Triangles", de: "Dreiecke", fr: "Triangles", es: "Triángulos", pt: "Triângulos", it: "Triangoli", zh: "三角形")),
        ("tri-hexagon", "Tri-Hexagon"),
        ("honeycomb", orcaLz(en: "Honeycomb", de: "Waben", fr: "Nid d'abeille", es: "Panal", pt: "Favo", it: "Nido d'ape", zh: "蜂窝")),
        ("3dhoneycomb", orcaLz(en: "3D honeycomb", de: "3D-Waben", fr: "Nid d'abeille 3D", es: "Panal 3D", pt: "Favo 3D", it: "Nido d'ape 3D", zh: "3D 蜂窝")),
        ("lightning", "Lightning"),
        ("zig-zag", orcaLz(en: "Rectilinear", de: "Geradlinig", fr: "Rectiligne", es: "Rectilíneo", pt: "Retilíneo", it: "Rettilineo", zh: "直线")),
        ("alignedrectilinear", orcaLz(en: "Aligned rectilinear", de: "Ausgerichtet geradlinig", fr: "Rectiligne aligné", es: "Rectilíneo alineado", pt: "Retilíneo alinhado", it: "Rettilineo allineato", zh: "对齐直线")),
        ("line", orcaLz(en: "Line", de: "Linie", fr: "Ligne", es: "Línea", pt: "Linha", it: "Linea", zh: "线")),
        ("concentric", orcaLz(en: "Concentric", de: "Konzentrisch", fr: "Concentrique", es: "Concéntrico", pt: "Concêntrico", it: "Concentrico", zh: "同心")),
        ("supportcubic", orcaLz(en: "Support cubic", de: "Support kubisch", fr: "Cubique support", es: "Cúbico soporte", pt: "Cúbico suporte", it: "Cubico supporto", zh: "支撑立方体")),
    ]
    static let brims: [(String, String)] = [
        ("auto_brim", orcaLz(en: "Auto", de: "Automatisch", fr: "Auto", es: "Auto", pt: "Auto", it: "Auto", zh: "自动")),
        ("outer_only", orcaLz(en: "Outer only", de: "Nur außen", fr: "Extérieur", es: "Solo exterior", pt: "Só externa", it: "Solo esterna", zh: "仅外侧")),
        ("inner_only", orcaLz(en: "Inner only", de: "Nur innen", fr: "Intérieur", es: "Solo interior", pt: "Só interna", it: "Solo interna", zh: "仅内侧")),
        ("outer_and_inner", orcaLz(en: "Outer and inner", de: "Außen und innen", fr: "Extérieur et intérieur", es: "Exterior e interior", pt: "Externa e interna", it: "Esterna e interna", zh: "内外侧")),
        ("brim_ears", orcaLz(en: "Mouse ears", de: "Mausohren", fr: "Oreilles", es: "Orejas", pt: "Orelhas", it: "Orecchie", zh: "鼠耳")),
        ("no_brim", orcaLz(en: "No brim", de: "Kein Rand", fr: "Sans bordure", es: "Sin borde", pt: "Sem borda", it: "Nessun brim", zh: "无")),
    ]

    /// Orca stores everything as strings ("15%", "1", "tree(auto)").
    static func from(profile d: [String: Any], process: String) -> QuickSettings {
        func str(_ k: String) -> String? {
            if let v = d[k] as? String { return v }
            if let v = d[k] as? NSNumber { return v.stringValue }
            return nil
        }
        func num(_ k: String) -> Double? { str(k).flatMap { Double($0.replacingOccurrences(of: "%", with: "")) } }
        func bool(_ k: String) -> Bool? { str(k).map { $0 == "1" || $0.lowercased() == "true" } }
        var q = QuickSettings()
        q.process = process
        if let v = str("layer_height") { q.layerHeight = v }
        if let v = str("initial_layer_print_height") { q.firstLayerHeight = v }
        if let v = str("seam_position") { q.seam = v }
        if let v = num("wall_loops") { q.walls = Int(v) }
        if let v = num("top_shell_layers") { q.topLayers = Int(v) }
        if let v = num("bottom_shell_layers") { q.bottomLayers = Int(v) }
        if let v = num("sparse_infill_density") { q.infill = v }
        if let v = str("sparse_infill_pattern") { q.infillPattern = v }
        if let v = bool("enable_support") { q.support = v }
        if let v = str("support_type") { q.tree = v.hasPrefix("tree") }
        if let v = bool("support_on_build_plate_only") { q.plateOnly = v }
        if let v = num("support_threshold_angle") { q.thresholdAngle = Int(v) }
        if let v = str("brim_type") { q.brimType = v }
        if let v = str("brim_width") { q.brimWidth = v }
        if let v = str("brim_object_gap") { q.brimGap = v }
        if let v = num("skirt_loops") { q.skirtLoops = Int(v) }
        if let v = bool("spiral_mode") { q.spiral = v }
        if let v = str("print_sequence") { q.sequence = v }
        return q
    }

    private static func mm(_ s: String) -> Double? { Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }

    /// The object-level subset as Orca's own keys and value spellings, for
    /// an object's entry in model_settings.config.
    var objectOverrides: [String: String] {
        var o: [String: String] = [
            "wall_loops": "\(walls)", "top_shell_layers": "\(topLayers)", "bottom_shell_layers": "\(bottomLayers)",
            "sparse_infill_density": "\(Int(infill))%", "sparse_infill_pattern": infillPattern,
            "enable_support": support ? "1" : "0", "support_type": tree ? "tree(auto)" : "normal(auto)",
            "support_on_build_plate_only": plateOnly ? "1" : "0", "support_threshold_angle": "\(thresholdAngle)",
            "seam_position": seam, "brim_type": brimType,
        ]
        if let v = Self.mm(layerHeight), v > 0 { o["layer_height"] = String(format: "%g", v) }
        if let v = Self.mm(brimWidth), v >= 0 { o["brim_width"] = String(format: "%g", v) }
        if let v = Self.mm(brimGap), v >= 0 { o["brim_object_gap"] = String(format: "%g", v) }
        return o
    }

    var overrides: [String: Any] {
        var o: [String: Any] = [
            "seam_position": seam, "wall_loops": walls, "top_shell_layers": topLayers, "bottom_shell_layers": bottomLayers,
            "sparse_infill_density": infill, "sparse_infill_pattern": infillPattern,
            "enable_support": support, "support_type": tree ? "tree(auto)" : "normal(auto)",
            "support_on_build_plate_only": plateOnly, "support_threshold_angle": thresholdAngle,
            "brim_type": brimType, "skirt_loops": skirtLoops, "spiral_mode": spiral, "print_sequence": sequence,
        ]
        if let v = Self.mm(layerHeight), v > 0 { o["layer_height"] = v }
        if let v = Self.mm(firstLayerHeight), v > 0 { o["initial_layer_print_height"] = v }
        if let v = Self.mm(brimWidth), v >= 0 { o["brim_width"] = v }
        if let v = Self.mm(brimGap), v >= 0 { o["brim_object_gap"] = v }
        return o
    }
}

struct SliceSettingsSheet: View {
    @ObservedObject var plate: PlateModel
    let printer: PrinterConfig
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var printerServices: PrinterServicesManager
    @AppStorage("app_language") private var appLanguage: String = "en"

    @State private var profiles: SlicerProfiles? = nil
    @State private var loadError: String? = nil
    /// The profile source PaxxMaker-Connect serves — the installed OrcaSlicer.
    @State private var app = "orca"
    @State private var machine = ""
    @State private var process = ""
    @State private var filaments = ["", "", "", ""]
    @State private var q = QuickSettings()
    @State private var loadingProfile = false
    /// How the middle of this screen is arranged — the user's own order,
    /// groups and choice of settings ("Edit" at the bottom).
    @State private var layout = SliceLayout.load()
    @State private var showEditor = false
    /// Every value the chosen process profile holds, for the settings that
    /// have no row of their own.
    @State private var profileValues: [String: String] = [:]
    /// What was changed on top of the profile, by Orca key.
    @State private var edits: [String: String] = [:]
    /// The profile's own values, to tell a changed setting from an untouched
    /// one (changed ones are shown in colour and can be reset one by one).
    @State private var baseQ = QuickSettings()
    @State private var baseNozzleTemps: [Int] = [0, 0, 0, 0]
    @State private var baseBedTemp = 0
    /// Temperatures shown next to the filaments: nozzle per head, bed once.
    /// They start at the filament's own values and go to Orca as they stand.
    @State private var nozzleTemps: [Int] = [0, 0, 0, 0]
    /// Material per head ("PETG", "PLA" …) — part of the file name.
    @State private var filamentTypes: [String] = ["", "", "", ""]
    /// The colour the chosen filament carries in OrcaSlicer, for the preview.
    @State private var filamentColors: [String] = ["", "", "", ""]
    @State private var bedTemp = 0
    @State private var bedTypeName = ""
    @FocusState private var tempFocus: Int?

    @State private var running = false
    @State private var progress: Double = 0
    @State private var stage = ""
    @State private var job: SliceJob? = nil
    @State private var jobError: String? = nil
    @State private var printing = false
    @State private var printed = false
    /// Whether the last send also started the print (Orca: "Send" vs "Print").
    @State private var printStarted = false
    @State private var askPrint = false
    @State private var gcodeData: Data? = nil
    @State private var showPreview = false
    @State private var fetchingPreview = false

    private var config: ConnectConfig? { ConnectConfig.load() }
    private var key: String { "slicer_last_\(printer.name)" }
    private var isU1: Bool { printer.type == .snapmakerU1 }
    /// Heads the plate uses (U1): each object's own plus painted regions.
    /// Several heads = a multi-material slice; one head is sliced as T0 and
    /// rewritten by PaxxMaker-Connect.
    private var usedHeads: [Int] {
        guard isU1 else { return [1] }
        var set = Set<Int>()
        for o in plate.objects { set.insert(o.extruder); set.formUnion(o.paintedHeads) }
        return set.isEmpty ? [1] : set.sorted()
    }
    private var multi: Bool { usedHeads.count > 1 }
    private var head: Int { usedHeads.first ?? 1 }
    private var usedExtruders: [Int] { usedHeads }

    private var machinePresets: [SlicerProfiles.Preset] {
        guard let p = profiles else { return [] }
        // Same printer family first (user presets on top), everything else below.
        let want = isU1 ? "U1" : nil
        return p.machine.sorted { a, b in
            let am = want.map { a.name.contains($0) || (a.printer_model ?? "").contains($0) } ?? true
            let bm = want.map { b.name.contains($0) || (b.printer_model ?? "").contains($0) } ?? true
            if am != bm { return am }
            if (a.origin == "user") != (b.origin == "user") { return a.origin == "user" }
            return a.name < b.name
        }
    }
    /// Orca's drop-down rule (Preset.cpp is_compatible_with_printer): a preset
    /// without `compatible_printers` fits every printer; otherwise the list
    /// must name the selected printer or, for a user printer, its parent.
    private func compatible(_ list: [SlicerProfiles.Preset]) -> [SlicerProfiles.Preset] {
        let m = machinePresets.first { $0.name == machine }
        var names: Set<String> = [machine]
        if let m, m.origin == "user", let parent = m.inherits, !parent.isEmpty { names.insert(parent) }
        return list.filter { p in
            guard let c = p.compatible_printers, !c.isEmpty else { return true }
            return !names.isDisjoint(with: c)
        }.sorted { a, b in
            let au = a.origin == "user", bu = b.origin == "user"
            if au != bu { return au }
            return a.name < b.name
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let e = loadError {
                    Section { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange) }
                } else if profiles == nil {
                    Section { HStack { ProgressView(); Text(lz(en: "Loading profiles from the computer…", de: "Lade Profile vom Computer…", fr: "Chargement des profils depuis l'ordinateur…", es: "Cargando perfiles del ordenador…", pt: "Carregando perfis do computador…", it: "Carico i profili dal computer…", zh: "正在从电脑加载配置…")) } }
                } else if let p = profiles {
                    profileSection(p)
                    layoutSections
                    perObjectSection
                }
                resultSection
                bottomBar
            }
            .navigationTitle(lz(en: "Slice", de: "Slicen", fr: "Trancher", es: "Laminar", pt: "Fatiar", it: "Slice", zh: "切片"))
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDismissable()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lz(en: "Close", de: "Schließen", fr: "Fermer", es: "Cerrar", pt: "Fechar", it: "Chiudi", zh: "关闭")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(lz(en: "Slice", de: "Slicen", fr: "Trancher", es: "Laminar", pt: "Fatiar", it: "Slice", zh: "切片")) { Task { await slice() } }
                        .disabled(running || profiles == nil || machine.isEmpty || process.isEmpty || usedExtruders.contains { filaments[$0 - 1].isEmpty })
                }
            }
            .task { await load() }
            .sheet(isPresented: $showEditor, onDismiss: { layout.save() }) {
                SliceLayoutEditor(layout: $layout, options: SliceCatalog.all(extraKeys: profileValues))
            }
            .fullScreenCover(isPresented: $showPreview) {
                if let d = gcodeData {
                    // The preview shows what was sliced, so the filament
                    // picked here gives the colour — not what happens to be
                    // in the printer.
                    GCodePreviewView(gcode: d, bed: BedSize.for(printer), printerName: printer.name,
                                     toolColorHexes: previewColorHexes, colorsFromSlicer: true,
                                     printerService: printerServices.services.first { $0.name == printer.name }) { start in Task { await sendToPrinter(start: start) } }
                }
            }
            .onChange(of: machine) { _, _ in
                // Keep the pickers valid when the printer changes.
                if let p = profiles, !compatible(p.process).contains(where: { $0.name == process }) { process = compatible(p.process).first?.name ?? "" }
            }
            .onChange(of: process) { _, new in
                // A different preset brings its own values.
                if profiles != nil, q.process != new { Task { await fillFromProfile() } }
            }
            .onChange(of: filaments) { _, _ in
                // A different filament brings its own temperatures.
                guard profiles != nil else { return }
                Task { for e in usedExtruders { await loadTemps(head: e) } }
            }
            .onChange(of: machine) { _, _ in
                guard profiles != nil else { return }
                Task { await loadBedType(); for e in usedExtruders { await loadTemps(head: e) } }
            }
        }
    }

    @ViewBuilder private func profileSection(_ p: SlicerProfiles) -> some View {
                    Section {
                        Picker(lz(en: "Printer", de: "Drucker", fr: "Imprimante", es: "Impresora", pt: "Impressora", it: "Stampante", zh: "打印机"), selection: $machine) {
                            ForEach(machinePresets) { m in Text(m.name).tag(m.name) }
                        }
                        Picker(lz(en: "Process", de: "Prozess", fr: "Processus", es: "Proceso", pt: "Processo", it: "Processo", zh: "工艺"), selection: $process) {
                            ForEach(compatible(p.process)) { m in Text(m.name).tag(m.name) }
                        }
                        ForEach(usedExtruders, id: \.self) { e in
                            Picker(isU1 ? lz(en: "Filament head \(e)", de: "Filament Kopf \(e)", fr: "Filament tête \(e)", es: "Filamento cabezal \(e)", pt: "Filamento cabeça \(e)", it: "Filamento testa \(e)", zh: "喷头 \(e) 耗材") : lz(en: "Filament", de: "Filament", fr: "Filament", es: "Filamento", pt: "Filamento", it: "Filamento", zh: "耗材"),
                                   selection: $filaments[e - 1]) {
                                ForEach(compatible(p.filament)) { m in Text(m.name).tag(m.name) }
                            }
                            tempRow(lz(en: "Nozzle", de: "Düse", fr: "Buse", es: "Boquilla", pt: "Bico", it: "Ugello", zh: "喷嘴")
                                    + (isU1 && usedExtruders.count > 1 ? " \(e)" : ""),
                                    value: Binding(get: { nozzleTemps[e - 1] }, set: { nozzleTemps[e - 1] = $0 }), tag: e, key: "nozzle_\(e)")
                        }
                        tempRow(lz(en: "Heated bed", de: "Heizbett", fr: "Plateau", es: "Cama", pt: "Mesa", it: "Piano", zh: "热床"),
                                value: $bedTemp, tag: 0, key: "bed_temp")
                        if anyChanged {
                            Button(lz(en: "Reset to profile values", de: "Auf Profilwerte zurücksetzen", fr: "Rétablir les valeurs du profil", es: "Restablecer valores del perfil", pt: "Repor valores do perfil", it: "Ripristina valori del profilo", zh: "恢复配置值")) {
                                edits.removeAll()
                                nozzleTemps = baseNozzleTemps
                                bedTemp = baseBedTemp
                                Task { await fillFromProfile() }
                            }
                            .disabled(loadingProfile || process.isEmpty)
                        }
                    } header: {
                        Text(lz(en: "Profiles", de: "Profile", fr: "Profils", es: "Perfiles", pt: "Perfis", it: "Profili", zh: "配置"))
                    } footer: {
                        Text(lz(en: "Temperatures come from the filament profile — change them here for this print. Picking another filament brings its values back.",
                                de: "Die Temperaturen kommen aus dem Filamentprofil — hier für diesen Druck änderbar. Ein anderes Filament setzt wieder dessen Werte.",
                                fr: "Les températures viennent du profil de filament — modifiables ici pour cette impression. Un autre filament rétablit ses valeurs.",
                                es: "Las temperaturas vienen del perfil de filamento — cámbialas aquí para esta impresión. Otro filamento restablece sus valores.",
                                pt: "As temperaturas vêm do perfil de filamento — altere-as aqui para esta impressão. Outro filamento traz os valores dele.",
                                it: "Le temperature vengono dal profilo del filamento — modificabili qui per questa stampa. Un altro filamento riporta i suoi valori.",
                                zh: "温度来自耗材配置——可在此为本次打印修改。换用其他耗材会恢复该耗材的数值。"))
                    }
    }

    // MARK: the arrangeable middle

    /// The groups as the user put them together; a group without a visible
    /// setting is left out entirely.
    @ViewBuilder private var layoutSections: some View {
        ForEach(layout.groups) { g in
            if !g.keys.isEmpty {
                Section {
                    ForEach(g.keys, id: \.self) { key in
                        settingRow(key)
                    }
                } header: {
                    HStack {
                        Text(layout.title(of: g))
                        Spacer()
                        if loadingProfile { ProgressView().controlSize(.mini) }
                    }
                }
            }
        }
    }

    /// Objects can carry their own settings — that list is not part of the
    /// arrangement, it belongs to the plate.
    @ViewBuilder private var perObjectSection: some View {
        if plate.objects.count > 1 {
            Section {
                ForEach(plate.objects) { o in
                    NavigationLink {
                        ObjectSettingsPage(object: o, general: q)
                    } label: {
                        HStack {
                            Text(o.name).lineLimit(1)
                            Spacer()
                            Text(o.settings == nil
                                 ? lz(en: "general", de: "allgemein", fr: "général", es: "general", pt: "geral", it: "generale", zh: "通用")
                                 : lz(en: "own", de: "eigene", fr: "propres", es: "propios", pt: "próprios", it: "proprie", zh: "自定义"))
                                .foregroundStyle(o.settings == nil ? .secondary : Color.accentColor).font(.footnote)
                        }
                    }
                }
            } header: {
                Text(lz(en: "Per object", de: "Je Objekt", fr: "Par objet", es: "Por objeto", pt: "Por objeto", it: "Per oggetto", zh: "按对象"))
            } footer: {
                Text(lz(en: "An object can override the general settings above (walls, infill, support, seam, brim, layer height).",
                        de: "Ein Objekt kann die allgemeinen Einstellungen oben überschreiben (Wände, Infill, Support, Naht, Rand, Layerhöhe).",
                        fr: "Un objet peut remplacer les réglages généraux ci-dessus (parois, remplissage, supports, couture, bordure, hauteur de couche).",
                        es: "Un objeto puede sobrescribir los ajustes generales (paredes, relleno, soportes, costura, borde, altura de capa).",
                        pt: "Um objeto pode sobrepor os ajustes gerais (paredes, preenchimento, suportes, costura, borda, altura de camada).",
                        it: "Un oggetto può sovrascrivere le impostazioni generali (pareti, riempimento, supporti, cucitura, brim, altezza layer).",
                        zh: "对象可以覆盖上面的通用设置（墙、填充、支撑、接缝、Brim、层高）。"))
            }
        }
    }

    /// Below the result: back to the profile's values, and the editor.
    @ViewBuilder private var bottomBar: some View {
        Section {
            Button {
                showEditor = true
            } label: {
                Label(lz(en: "Edit", de: "Bearbeiten", fr: "Modifier", es: "Editar", pt: "Editar", it: "Modifica", zh: "编辑"),
                      systemImage: "slider.horizontal.3")
            }
        } footer: {
            Text(lz(en: "\"Edit\" arranges this screen: show or hide settings, group them, change the order. Everything OrcaSlicer's command line offers is available there.",
                    de: "„Bearbeiten\" richtet diese Seite ein: Einstellungen ein- oder ausblenden, gruppieren, Reihenfolge ändern. Dort steht alles zur Verfügung, was die OrcaSlicer-Kommandozeile kann.",
                    fr: "« Modifier » organise cette page : afficher ou masquer des réglages, les grouper, changer l'ordre. Tout ce que propose la ligne de commande d'OrcaSlicer s'y trouve.",
                    es: "«Editar» organiza esta página: mostrar u ocultar ajustes, agruparlos, cambiar el orden. Allí está todo lo que ofrece la línea de comandos de OrcaSlicer.",
                    pt: "\"Editar\" organiza esta página: mostrar ou ocultar ajustes, agrupá-los, mudar a ordem. Lá está tudo o que a linha de comando do OrcaSlicer oferece.",
                    it: "«Modifica» organizza questa pagina: mostrare o nascondere impostazioni, raggrupparle, cambiarne l'ordine. Lì c'è tutto ciò che offre la riga di comando di OrcaSlicer.",
                    zh: "“编辑”用于安排此页面：显示或隐藏设置、分组、调整顺序。那里提供 OrcaSlicer 命令行支持的全部设置。"))
        }
    }

    // MARK: one row

    @ViewBuilder private func settingRow(_ key: String) -> some View {
        Group {
            if let row = builtInRow(key) {
                row
            } else if let o = catalogOption(key) {
                genericRow(o)
            }
        }
        .modifier(ResetOnLongPress(armed: isChanged(key), title: settingTitle(key)) { reset(key) })
    }

    private func catalogOption(_ key: String) -> SliceOption? {
        SliceCatalog.option(for: key, profileValue: profileValues[key])
    }

    /// The rows the screen always had — they keep their own look and write
    /// straight into the quick settings. A changed value is shown in colour.
    private func builtInRow(_ key: String) -> AnyView? {
        switch key {
        case "layer_height":
            return AnyView(numberRow(label(key, orcaLz(en: "Layer height", de: "Layerhöhe", fr: "Hauteur de couche", es: "Altura de capa", pt: "Altura de camada", it: "Altezza layer", zh: "层高")), text: $q.layerHeight, unit: "mm", placeholder: "0.2"))
        case "initial_layer_print_height":
            return AnyView(numberRow(label(key, orcaLz(en: "First layer height", de: "Erste Layerhöhe", fr: "Hauteur 1re couche", es: "Altura 1.ª capa", pt: "Altura 1.ª camada", it: "Altezza 1° layer", zh: "首层层高")), text: $q.firstLayerHeight, unit: "mm", placeholder: "0.2"))
        case "seam_position":
            return AnyView(Picker(selection: $q.seam) {
                ForEach(QuickSettings.seams, id: \.0) { Text($0.1).tag($0.0) }
                if !QuickSettings.seams.contains(where: { $0.0 == q.seam }) { Text(q.seam).tag(q.seam) }
            } label: { label(key, orcaLz(en: "Seam", de: "Naht", fr: "Couture", es: "Costura", pt: "Costura", it: "Cucitura", zh: "接缝")) })
        case "wall_loops":
            return AnyView(Stepper(value: $q.walls, in: 1...10) {
                HStack { label(key, orcaLz(en: "Walls", de: "Wände", fr: "Parois", es: "Paredes", pt: "Paredes", it: "Pareti", zh: "墙")); Spacer(); Text("\(q.walls)").foregroundStyle(.secondary) }
            })
        case "top_shell_layers":
            return AnyView(Stepper(value: $q.topLayers, in: 0...15) {
                HStack { label(key, orcaLz(en: "Top layers", de: "Obere Schichten", fr: "Couches sup.", es: "Capas superiores", pt: "Camadas superiores", it: "Layer superiori", zh: "顶层")); Spacer(); Text("\(q.topLayers)").foregroundStyle(.secondary) }
            })
        case "bottom_shell_layers":
            return AnyView(Stepper(value: $q.bottomLayers, in: 0...15) {
                HStack { label(key, orcaLz(en: "Bottom layers", de: "Untere Schichten", fr: "Couches inf.", es: "Capas inferiores", pt: "Camadas inferiores", it: "Layer inferiori", zh: "底层")); Spacer(); Text("\(q.bottomLayers)").foregroundStyle(.secondary) }
            })
        case "sparse_infill_density":
            return AnyView(HStack {
                label(key, orcaLz(en: "Infill", de: "Infill", fr: "Remplissage", es: "Relleno", pt: "Preenchimento", it: "Riempimento", zh: "填充"))
                Slider(value: $q.infill, in: 0...100, step: 5)
                Text("\(Int(q.infill)) %").frame(width: 48, alignment: .trailing).monospacedDigit()
            })
        case "sparse_infill_pattern":
            return AnyView(Picker(selection: $q.infillPattern) {
                ForEach(QuickSettings.patterns, id: \.0) { Text($0.1).tag($0.0) }
                if !QuickSettings.patterns.contains(where: { $0.0 == q.infillPattern }) { Text(q.infillPattern).tag(q.infillPattern) }
            } label: { label(key, orcaLz(en: "Infill pattern", de: "Infill-Muster", fr: "Motif", es: "Patrón", pt: "Padrão", it: "Motivo", zh: "填充图案")) })
        case "enable_support":
            return AnyView(Toggle(isOn: $q.support) { label(key, orcaLz(en: "Enable support", de: "Support aktivieren", fr: "Activer les supports", es: "Activar soportes", pt: "Ativar suportes", it: "Attiva supporti", zh: "启用支撑")) })
        case "support_type":
            return AnyView(Picker(selection: $q.tree) {
                Text(orcaLz(en: "Tree", de: "Baum", fr: "Arbre", es: "Árbol", pt: "Árvore", it: "Albero", zh: "树状")).tag(true)
                Text("Normal").tag(false)
            } label: { label(key, orcaLz(en: "Type", de: "Art", fr: "Type", es: "Tipo", pt: "Tipo", it: "Tipo", zh: "类型")) }.pickerStyle(.segmented))
        case "support_on_build_plate_only":
            return AnyView(Toggle(isOn: $q.plateOnly) { label(key, orcaLz(en: "On build plate only", de: "Nur auf Druckbett", fr: "Sur le plateau uniquement", es: "Solo sobre la cama", pt: "Somente na mesa", it: "Solo sul piano", zh: "仅在打印板上")) })
        case "support_threshold_angle":
            return AnyView(Stepper(value: $q.thresholdAngle, in: 0...90, step: 5) {
                HStack { label(key, orcaLz(en: "Threshold angle", de: "Schwellwinkel", fr: "Angle seuil", es: "Ángulo umbral", pt: "Ângulo limite", it: "Angolo soglia", zh: "临界角")); Spacer(); Text("\(q.thresholdAngle)°").foregroundStyle(.secondary) }
            })
        case "brim_type":
            return AnyView(Picker(selection: $q.brimType) {
                ForEach(QuickSettings.brims, id: \.0) { Text($0.1).tag($0.0) }
                if !QuickSettings.brims.contains(where: { $0.0 == q.brimType }) { Text(q.brimType).tag(q.brimType) }
            } label: { label(key, orcaLz(en: "Brim type", de: "Rand-Typ", fr: "Type de bordure", es: "Tipo de borde", pt: "Tipo de borda", it: "Tipo di brim", zh: "Brim 类型")) })
        case "brim_width":
            return AnyView(numberRow(label(key, orcaLz(en: "Brim width", de: "Randbreite", fr: "Largeur", es: "Ancho", pt: "Largura", it: "Larghezza", zh: "宽度")), text: $q.brimWidth, unit: "mm", placeholder: "5"))
        case "brim_object_gap":
            return AnyView(numberRow(label(key, orcaLz(en: "Brim-object gap", de: "Abstand zum Objekt", fr: "Écart objet", es: "Separación", pt: "Distância", it: "Distanza", zh: "与模型间距")), text: $q.brimGap, unit: "mm", placeholder: "0.1"))
        case "skirt_loops":
            return AnyView(Stepper(value: $q.skirtLoops, in: 0...10) {
                HStack { label(key, orcaLz(en: "Skirt loops", de: "Skirt-Schleifen", fr: "Boucles de jupe", es: "Vueltas de falda", pt: "Voltas da saia", it: "Giri skirt", zh: "裙边圈数")); Spacer(); Text("\(q.skirtLoops)").foregroundStyle(.secondary) }
            })
        case "spiral_mode":
            return AnyView(Toggle(isOn: $q.spiral) { label(key, orcaLz(en: "Spiral vase", de: "Spiralvase", fr: "Vase spirale", es: "Vaso en espiral", pt: "Vaso espiral", it: "Vaso a spirale", zh: "螺旋花瓶")) })
        case "print_sequence":
            return AnyView(Picker(selection: $q.sequence) {
                Text(orcaLz(en: "By layer", de: "Nach Layer", fr: "Par couche", es: "Por capa", pt: "Por camada", it: "Per layer", zh: "逐层")).tag("by layer")
                Text(orcaLz(en: "By object", de: "Nach Objekt", fr: "Par objet", es: "Por objeto", pt: "Por objeto", it: "Per oggetto", zh: "逐个")).tag("by object")
            } label: { label(key, orcaLz(en: "Print sequence", de: "Druckreihenfolge", fr: "Ordre d'impression", es: "Secuencia", pt: "Sequência", it: "Sequenza", zh: "打印顺序")) }.pickerStyle(.segmented))
        default:
            return nil
        }
    }

    /// Is anything at all different from the profile? Only then is there
    /// something to reset.
    private var anyChanged: Bool {
        var keys = SliceCatalog.builtInKeys
        keys.insert("bed_temp")
        for i in 1...4 { keys.insert("nozzle_\(i)") }
        keys.formUnion(edits.keys)
        return keys.contains { isChanged($0) }
    }

    /// A setting's name, in colour when it no longer matches the profile.
    private func label(_ key: String, _ text: String) -> Text {
        Text(text).foregroundColor(isChanged(key) ? .accentColor : .primary)
    }

    private func settingTitle(_ key: String) -> String {
        if key.hasPrefix("nozzle_") {
            return lz(en: "Nozzle", de: "Düse", fr: "Buse", es: "Boquilla", pt: "Bico", it: "Ugello", zh: "喷嘴")
        }
        if key == "bed_temp" {
            return lz(en: "Heated bed", de: "Heizbett", fr: "Plateau", es: "Cama", pt: "Mesa", it: "Piano", zh: "热床")
        }
        return catalogOption(key)?.title ?? SliceCatalog.prettify(key)
    }

    /// Does this setting still hold what the profile says?
    private func isChanged(_ key: String) -> Bool {
        func same(_ a: String, _ b: String) -> Bool {
            if let x = Double(a.replacingOccurrences(of: ",", with: ".")),
               let y = Double(b.replacingOccurrences(of: ",", with: ".")) { return abs(x - y) < 1e-6 }
            return a == b
        }
        switch key {
        case "layer_height":                 return !same(q.layerHeight, baseQ.layerHeight)
        case "initial_layer_print_height":   return !same(q.firstLayerHeight, baseQ.firstLayerHeight)
        case "seam_position":                return q.seam != baseQ.seam
        case "wall_loops":                   return q.walls != baseQ.walls
        case "top_shell_layers":             return q.topLayers != baseQ.topLayers
        case "bottom_shell_layers":          return q.bottomLayers != baseQ.bottomLayers
        case "sparse_infill_density":        return abs(q.infill - baseQ.infill) > 0.01
        case "sparse_infill_pattern":        return q.infillPattern != baseQ.infillPattern
        case "enable_support":               return q.support != baseQ.support
        case "support_type":                 return q.tree != baseQ.tree
        case "support_on_build_plate_only":  return q.plateOnly != baseQ.plateOnly
        case "support_threshold_angle":      return q.thresholdAngle != baseQ.thresholdAngle
        case "brim_type":                    return q.brimType != baseQ.brimType
        case "brim_width":                   return !same(q.brimWidth, baseQ.brimWidth)
        case "brim_object_gap":              return !same(q.brimGap, baseQ.brimGap)
        case "skirt_loops":                  return q.skirtLoops != baseQ.skirtLoops
        case "spiral_mode":                  return q.spiral != baseQ.spiral
        case "print_sequence":               return q.sequence != baseQ.sequence
        case "bed_temp":                     return baseBedTemp > 0 && bedTemp != baseBedTemp
        default:
            if key.hasPrefix("nozzle_"), let i = Int(key.dropFirst(7)), i >= 1, i <= 4 {
                return baseNozzleTemps[i - 1] > 0 && nozzleTemps[i - 1] != baseNozzleTemps[i - 1]
            }
            guard let e = edits[key] else { return false }
            return e != (profileValues[key] ?? "")
        }
    }

    /// Long press on a changed setting: back to the profile's value.
    private func reset(_ key: String) {
        switch key {
        case "layer_height":                 q.layerHeight = baseQ.layerHeight
        case "initial_layer_print_height":   q.firstLayerHeight = baseQ.firstLayerHeight
        case "seam_position":                q.seam = baseQ.seam
        case "wall_loops":                   q.walls = baseQ.walls
        case "top_shell_layers":             q.topLayers = baseQ.topLayers
        case "bottom_shell_layers":          q.bottomLayers = baseQ.bottomLayers
        case "sparse_infill_density":        q.infill = baseQ.infill
        case "sparse_infill_pattern":        q.infillPattern = baseQ.infillPattern
        case "enable_support":               q.support = baseQ.support
        case "support_type":                 q.tree = baseQ.tree
        case "support_on_build_plate_only":  q.plateOnly = baseQ.plateOnly
        case "support_threshold_angle":      q.thresholdAngle = baseQ.thresholdAngle
        case "brim_type":                    q.brimType = baseQ.brimType
        case "brim_width":                   q.brimWidth = baseQ.brimWidth
        case "brim_object_gap":              q.brimGap = baseQ.brimGap
        case "skirt_loops":                  q.skirtLoops = baseQ.skirtLoops
        case "spiral_mode":                  q.spiral = baseQ.spiral
        case "print_sequence":               q.sequence = baseQ.sequence
        case "bed_temp":                     bedTemp = baseBedTemp
        default:
            if key.hasPrefix("nozzle_"), let i = Int(key.dropFirst(7)), i >= 1, i <= 4 {
                nozzleTemps[i - 1] = baseNozzleTemps[i - 1]
            } else {
                edits[key] = nil
            }
        }
    }

    private func numberRow(_ title: Text, text: Binding<String>, unit: String, placeholder: String) -> some View {
        HStack {
            title
            Spacer()
            TextField(placeholder, text: text).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 70)
            if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
        }
    }

    /// A setting without a row of its own: type taken from the profile value,
    /// sent to OrcaSlicer as `--key=value` when it was touched.
    private func genericRow(_ o: SliceOption) -> AnyView {
        let title = label(o.key, o.title)
        let text = Binding<String>(get: { edits[o.key] ?? profileValues[o.key] ?? "" },
                                   set: { edits[o.key] = $0 })
        switch o.kind {
        case .toggle:
            let on = Binding<Bool>(get: { (edits[o.key] ?? profileValues[o.key] ?? "0") == "1" },
                                   set: { edits[o.key] = $0 ? "1" : "0" })
            return AnyView(Toggle(isOn: on) { title })
        case .stepper(let range):
            let v = Binding<Int>(get: { Int(Double(edits[o.key] ?? profileValues[o.key] ?? "0") ?? 0) },
                                 set: { edits[o.key] = "\($0)" })
            return AnyView(Stepper(value: v, in: range) {
                HStack { title; Spacer(); Text("\(v.wrappedValue)").foregroundStyle(.secondary) }
            })
        case .percent:
            let v = Binding<Double>(get: { Double((edits[o.key] ?? profileValues[o.key] ?? "0").replacingOccurrences(of: "%", with: "")) ?? 0 },
                                    set: { edits[o.key] = "\(Int($0))%" })
            return AnyView(HStack {
                title
                Slider(value: v, in: 0...100, step: 5)
                Text("\(Int(v.wrappedValue)) %").frame(width: 48, alignment: .trailing).monospacedDigit()
            })
        case .decimal(let unit):
            return AnyView(HStack {
                title
                Spacer()
                TextField("", text: text).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).frame(width: 80)
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
            })
        case .choice(let options):
            let sel = Binding<String>(get: { edits[o.key] ?? profileValues[o.key] ?? options.first?.0 ?? "" },
                                      set: { edits[o.key] = $0 })
            return AnyView(Picker(selection: sel) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
                if !options.contains(where: { $0.0 == sel.wrappedValue }) { Text(sel.wrappedValue).tag(sel.wrappedValue) }
            } label: { title })
        case .text:
            return AnyView(HStack {
                title
                Spacer()
                TextField("", text: text).multilineTextAlignment(.trailing).frame(maxWidth: 140)
            })
        }
    }

    @ViewBuilder private var resultSection: some View {
                if running || job != nil || jobError != nil {
                    Section(lz(en: "Result", de: "Ergebnis", fr: "Résultat", es: "Resultado", pt: "Resultado", it: "Risultato", zh: "结果")) {
                        if running {
                            VStack(alignment: .leading, spacing: 6) {
                                ProgressView(value: progress)
                                Text(stageText).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let e = jobError {
                            Label { Text(e).fixedSize(horizontal: false, vertical: true) }
                            icon: { Image(systemName: "xmark.octagon.fill") }
                                .foregroundColor(.red).font(.footnote)
                        }
                        if let r = job?.result {
                            row(lz(en: "Print time", de: "Druckzeit", fr: "Durée", es: "Tiempo", pt: "Tempo", it: "Tempo", zh: "打印时间"), r.time_s.map { EnergyLog.duration($0) } ?? "—")
                            row(lz(en: "Filament", de: "Filament", fr: "Filament", es: "Filamento", pt: "Filamento", it: "Filamento", zh: "耗材"),
                                r.filament_g.map { String(format: "%.1f g", $0) } ?? "—")
                            if let t = r.filament_g_tools, t.count > 1 {
                                row("", perToolText(t))
                            }
                            row(lz(en: "Filament cost", de: "Filamentkosten", fr: "Coût filament", es: "Coste filamento", pt: "Custo filamento", it: "Costo filamento", zh: "耗材费用"), r.cost.map { EnergyLog.money($0, printer.energyCurrency) } ?? "—")
                            row(lz(en: "Layers", de: "Layer", fr: "Couches", es: "Capas", pt: "Camadas", it: "Layer", zh: "层数"), r.layers.map(String.init) ?? "—")
                            row("Support", supportText(r.support))
                            Button {
                                Task { await openPreview() }
                            } label: {
                                HStack {
                                    Spacer()
                                    if fetchingPreview { ProgressView().padding(.trailing, 6) }
                                    Label(lz(en: "Preview", de: "Vorschau", fr: "Aperçu", es: "Vista previa", pt: "Pré-visualização", it: "Anteprima", zh: "预览"), systemImage: "cube.transparent")
                                    Spacer()
                                }
                            }
                            .disabled(fetchingPreview || printing)
                            Button {
                                askPrint = true
                            } label: {
                                HStack {
                                    Spacer()
                                    if printing { ProgressView().padding(.trailing, 6) }
                                    Text(printed
                                         ? (printStarted
                                            ? lz(en: "Sent — print started", de: "Gesendet — Druck gestartet", fr: "Envoyé — impression lancée", es: "Enviado — impresión iniciada", pt: "Enviado — impressão iniciada", it: "Inviato — stampa avviata", zh: "已发送——打印已开始")
                                            : lz(en: "Sent to \(printer.name)", de: "An \(printer.name) gesendet", fr: "Envoyé à \(printer.name)", es: "Enviado a \(printer.name)", pt: "Enviado para \(printer.name)", it: "Inviato a \(printer.name)", zh: "已发送到 \(printer.name)"))
                                         : lz(en: "Print on \(printer.name)", de: "Auf \(printer.name) drucken", fr: "Imprimer sur \(printer.name)", es: "Imprimir en \(printer.name)", pt: "Imprimir em \(printer.name)", it: "Stampa su \(printer.name)", zh: "在 \(printer.name) 上打印"))
                                        .fontWeight(.semibold)
                                    Spacer()
                                }
                            }
                            .disabled(printing || printed)
                            .confirmationDialog(printer.name, isPresented: $askPrint, titleVisibility: .visible) {
                                Button(lz(en: "Send and print", de: "Senden und drucken", fr: "Envoyer et imprimer", es: "Enviar e imprimir", pt: "Enviar e imprimir", it: "Invia e stampa", zh: "发送并打印")) { Task { await sendToPrinter(start: true) } }
                                Button(lz(en: "Send to printer only", de: "Nur an Drucker senden", fr: "Envoyer seulement", es: "Solo enviar a la impresora", pt: "Apenas enviar para a impressora", it: "Invia soltanto", zh: "仅发送到打印机")) { Task { await sendToPrinter(start: false) } }
                                Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"), role: .cancel) {}
                            } message: {
                                Text(lz(en: "Upload the G-code to the printer and start right away, or just store it there.",
                                        de: "G-Code an den Drucker übertragen und sofort starten – oder nur dort ablegen.",
                                        fr: "Envoyer le G-code à l'imprimante et lancer tout de suite, ou seulement l'y déposer.",
                                        es: "Subir el G-code a la impresora y empezar ya, o solo guardarlo allí.",
                                        pt: "Enviar o G-code para a impressora e começar já, ou apenas guardá-lo lá.",
                                        it: "Invia il G-code alla stampante e avvia subito, oppure salvalo soltanto.",
                                        zh: "将 G-code 上传到打印机并立即开始，或仅保存到打印机。"))
                            }
                            if printed {
                                // Sent — the way on is to the printer that got
                                // the file, not back through the slicer screens.
                                Button {
                                    dismiss()
                                    // Let the sheet close first, then the plate
                                    // view, then change the tab underneath.
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                        NotificationCenter.default.post(name: .paxxShowPrinter, object: printer.id.uuidString)
                                    }
                                } label: {
                                    HStack {
                                        Spacer()
                                        Label(lz(en: "Done", de: "Fertig", fr: "Terminé", es: "Listo", pt: "Concluído", it: "Fine", zh: "完成"),
                                              systemImage: "checkmark.circle.fill")
                                            .fontWeight(.semibold)
                                        Spacer()
                                    }
                                }
                                Text(lz(en: "Takes you to \(printer.name).", de: "Bringt dich zu \(printer.name).", fr: "T'amène à \(printer.name).", es: "Te lleva a \(printer.name).", pt: "Leva você a \(printer.name).", it: "Ti porta a \(printer.name).", zh: "带你前往 \(printer.name)。"))
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .listRowSeparator(.hidden)
                            }
                        }
                    }
                }
    }

    private var stageText: String {
        switch stage {
        case "prepare": return lz(en: "Preparing profiles…", de: "Profile werden vorbereitet…", fr: "Préparation des profils…", es: "Preparando perfiles…", pt: "Preparando perfis…", it: "Preparo i profili…", zh: "正在准备配置…")
        case "model": return lz(en: "Sending models…", de: "Modelle werden übertragen…", fr: "Envoi des modèles…", es: "Enviando modelos…", pt: "Enviando modelos…", it: "Invio dei modelli…", zh: "正在发送模型…")
        case "slice": return lz(en: "OrcaSlicer is slicing…", de: "OrcaSlicer sliced…", fr: "OrcaSlicer tranche…", es: "OrcaSlicer está laminando…", pt: "OrcaSlicer está fatiando…", it: "OrcaSlicer sta facendo lo slicing…", zh: "OrcaSlicer 正在切片…")
        case "download": return lz(en: "Fetching G-code…", de: "G-Code wird geholt…", fr: "Récupération du G-code…", es: "Obteniendo G-code…", pt: "Buscando G-code…", it: "Recupero il G-code…", zh: "正在获取 G-code…")
        default: return stage
        }
    }

    /// What Orca actually used, from the G-code — so a setting that did not
    /// take is visible here instead of only in the print.
    private func supportText(_ s: [String: String]?) -> String {
        guard let s, s["enable_support"] == "1" else { return lz(en: "off", de: "aus", fr: "désactivé", es: "desactivado", pt: "desativado", it: "disattivato", zh: "关闭") }
        var parts: [String] = []
        parts.append((s["support_type"] ?? "").hasPrefix("tree") ? lz(en: "Tree", de: "Baum", fr: "Arbre", es: "Árbol", pt: "Árvore", it: "Albero", zh: "树状") : "Normal")
        if s["support_on_build_plate_only"] == "1" { parts.append(lz(en: "plate only", de: "nur Druckbett", fr: "plateau seul", es: "solo cama", pt: "só mesa", it: "solo piano", zh: "仅打印板")) }
        return parts.joined(separator: " · ")
    }

    private func perToolText(_ t: [Double]) -> String {
        var parts: [String] = []
        for (i, g) in t.enumerated() where g > 0 { parts.append(String(format: "K%d %.1f g", i + 1, g)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func row(_ l: String, _ v: String) -> some View {
        HStack { Text(l); Spacer(); Text(v).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
    }

    private func load() async {
        guard let cfg = config else {
            loadError = lz(en: "PaxxMaker-Connect not paired — see the slicer tab.", de: "PaxxMaker-Connect nicht gekoppelt — siehe Slicer-Tab.", fr: "PaxxMaker-Connect non appairé — voir l'onglet slicer.", es: "PaxxMaker-Connect no vinculado — ver la pestaña del slicer.", pt: "PaxxMaker-Connect não pareado — veja a aba do slicer.", it: "PaxxMaker-Connect non associato — vedi la scheda slicer.", zh: "未配对 PaxxMaker-Connect——请查看切片标签页。")
            return
        }
        let client = ConnectClient(config: cfg)
        do {
            let info = try await client.info()
            app = info.apps.first ?? "orca"
            let p = try await client.profiles(app: app)
            profiles = p
            // Last choice for this printer, else the first fitting preset.
            if let saved = UserDefaults.standard.dictionary(forKey: key) {
                machine = saved["machine"] as? String ?? ""
                process = saved["process"] as? String ?? ""
                filaments = saved["filaments"] as? [String] ?? filaments
                if let js = saved["quick"] as? String, let d = js.data(using: .utf8), let sq = try? JSONDecoder().decode(QuickSettings.self, from: d) { q = sq }
                if let e = saved["edits"] as? [String: String] { edits = e }
            }
            if !machinePresets.contains(where: { $0.name == machine }) { machine = machinePresets.first?.name ?? "" }
            if !compatible(p.process).contains(where: { $0.name == process }) { process = compatible(p.process).first?.name ?? "" }
            let fil = compatible(p.filament)
            for i in 0..<4 where !fil.contains(where: { $0.name == filaments[i] }) { filaments[i] = fil.first?.name ?? "" }
            // Remembered tweaks belong to the preset they were made on. On the
            // same preset they stay; the profile is still read, because the
            // rows without a field of their own start from its values.
            await fillFromProfile(keepTweaks: q.process == process)
            await loadBedType()
            for e in usedExtruders { await loadTemps(head: e) }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func remember() {
        let js = (try? JSONEncoder().encode(q)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        UserDefaults.standard.set(["machine": machine, "process": process, "filaments": filaments,
                                   "quick": js, "edits": edits], forKey: key)
    }

    /// The chosen preset's own values, flattened by PaxxMaker-Connect.
    /// Print time the way the printer names its files: "3h52m", else "46m37s".
    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? "\(h)h\(m)m" : "\(m)m\(s)s"
    }

    /// One temperature line: label, value in °C, editable.
    @ViewBuilder private func tempRow(_ text: String, value: Binding<Int>, tag: Int, key: String) -> some View {
        HStack {
            label(key, text)
            Spacer()
            TextField("0", value: value, format: .number)
                .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                .frame(width: 58).focused($tempFocus, equals: tag)
                .monospacedDigit()
            Text("°C").foregroundStyle(.secondary)
        }
        .modifier(ResetOnLongPress(armed: isChanged(key), title: settingTitle(key)) { reset(key) })
    }

    /// The filament's own temperatures: nozzle, and the bed value of the plate
    /// this printer uses (Orca keeps one per plate type).
    private func loadTemps(head: Int) async {
        guard let cfg = config else { return }
        let name = filaments[head - 1]
        filamentColors[head - 1] = ""
        guard !name.isEmpty, let d = try? await ConnectClient(config: cfg).profile(app: app, kind: "filament", name: name) else { return }
        func first(_ key: String) -> Int? {
            if let a = d[key] as? [String], let v = a.first { return Int(Double(v) ?? 0) }
            if let v = d[key] as? String { return Int(Double(v) ?? 0) }
            return nil
        }
        if let n = first("nozzle_temperature"), n > 0 { nozzleTemps[head - 1] = n; baseNozzleTemps[head - 1] = n }
        if let t = (d["filament_type"] as? [String])?.first ?? d["filament_type"] as? String { filamentTypes[head - 1] = t }
        if let c = (d["filament_colour"] as? [String])?.first ?? d["filament_colour"] as? String {
            filamentColors[head - 1] = c.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        }
        let key: String
        switch bedTypeName.lowercased() {
        case let t where t.contains("textured"): key = "textured_plate_temp"
        case let t where t.contains("engineering"): key = "eng_plate_temp"
        case let t where t.contains("cool"), let t where t.contains("supertack"): key = "cool_plate_temp"
        default: key = "hot_plate_temp"
        }
        if let b = first(key), b > 0 { bedTemp = b; baseBedTemp = b }
    }

    /// Which plate the printer uses — it decides which bed temperature counts.
    private func loadBedType() async {
        guard let cfg = config, !machine.isEmpty else { return }
        if let d = try? await ConnectClient(config: cfg).profile(app: app, kind: "machine", name: machine),
           let t = d["default_bed_type"] as? String { bedTypeName = t }
    }

    private func fillFromProfile(keepTweaks: Bool = false) async {
        guard let cfg = config, !process.isEmpty else { return }
        loadingProfile = true
        defer { loadingProfile = false }
        if let d = try? await ConnectClient(config: cfg).profile(app: app, kind: "process", name: process) {
            baseQ = QuickSettings.from(profile: d, process: process)
            if !keepTweaks { q = baseQ }
            // Every value the preset holds — the rows that have no field of
            // their own read their starting value from here.
            // Only plain values: a per-extruder list must keep its length, so
            // those are not offered as a single field.
            profileValues = d.compactMapValues { v -> String? in
                if let s = v as? String { return s }
                if let n = v as? NSNumber { return n.stringValue }
                return nil
            }
            if !keepTweaks { edits.removeAll() }
        } else if !keepTweaks {
            q.process = process
        }
    }

    private func slice() async {
        guard let cfg = config else { return }
        remember()
        // New slice = new G-code: drop the cached one, or the preview and the
        // print would keep using the previous result.
        running = true; job = nil; jobError = nil; printed = false; gcodeData = nil; progress = 0.02; stage = "model"
        let client = ConnectClient(config: cfg)
        do {
            var spec: [String: Any] = ["app": app, "machine": machine, "process": process]
            if multi {
                // One filament per head in head order; heads that are not
                // printed get a used one so Orca sees four profiles.
                spec["multi"] = true
                // The prime tower where the plate shows it (dragged or automatic).
                let tower = plate.towerRect.min
                spec["wipe_tower"] = [Double(tower.x), Double(tower.y)]
                let fallback = filaments[head - 1]
                spec["filaments"] = (0..<4).map { usedHeads.contains($0 + 1) && !filaments[$0].isEmpty ? filaments[$0] : fallback }
            } else {
                // One filament: the one loaded in the chosen head. The
                // Connect app slices for T0 and rewrites the G-code to that head.
                spec["head"] = head
                spec["filaments"] = [filaments[head - 1]]
            }
            // The settings with their own rows go as before; everything added
            // in the editor rides along as its Orca key.
            var overrides = q.overrides
            for (k, v) in edits where !SliceCatalog.builtInKeys.contains(k) && !v.isEmpty { overrides[k] = v }
            spec["overrides"] = overrides
            // Temperatures as shown in the sheet (0 = leave the profile alone).
            spec["nozzle_temps"] = (0..<4).map { usedHeads.contains($0 + 1) ? nozzleTemps[$0] : 0 }
            spec["bed_temp"] = bedTemp
            // The colours loaded in the printer, per head — Orca's CLI needs a
            // colour per filament and the preview shows the print in them.
            spec["filament_colours"] = toolColorHexes.map { $0.isEmpty ? "" : "#" + $0 }
            // Each object goes as the STL held here (same triangle order on
            // both sides) with its placement, head and painted faces.
            var objs: [[String: Any]] = []
            for o in plate.objects {
                let mid = try await client.upload(o.mesh.stlData, ext: "stl")
                let m = o.matrix
                let flat: [Double] = (0..<4).flatMap { c in (0..<4).map { r in Double(m[c][r]) } }
                var d: [String: Any] = ["name": o.name, "model": mid, "transform": flat, "extruder": multi ? o.extruder : 1]
                if let own = o.settings { d["settings"] = own.objectOverrides }
                if multi {
                    let strings = o.paintStrings
                    if !strings.isEmpty { d["paint"] = Dictionary(uniqueKeysWithValues: strings.map { (String($0.key), $0.value) }) }
                }
                objs.append(d)
            }
            spec["objects"] = objs
            stage = "slice"; progress = 0.15
            var j = try await client.createJob(spec)
            while j.state == "queued" || j.state == "running" {
                try? await Task.sleep(nanoseconds: 700_000_000)
                j = try await client.job(j.id)
                progress = max(progress, 0.15 + j.progress * 0.8)
                if !j.stage.isEmpty { stage = j.stage == "done" ? "slice" : j.stage }
            }
            if j.state == "failed" { jobError = SliceJob.explain(code: j.error_code, message: j.error) }
            job = j
        } catch {
            jobError = error.localizedDescription
        }
        running = false; progress = 1
    }

    /// What the preview paints with: the colour of the filament chosen for
    /// each head, falling back to the one loaded in the printer.
    private var previewColorHexes: [String] {
        // One entry per head the printer has — a single-nozzle machine must
        // not end up with a per-head legend.
        (0..<(printer.type == .snapmakerU1 ? 4 : 1)).map { i in
            let own = filamentColors[safe: i] ?? ""
            return own.isEmpty ? (toolColorHexes[safe: i] ?? "") : own
        }
    }

    /// Colours of the filaments loaded in the printer's heads, for "by head".
    private var toolColorHexes: [String] {
        printerServices.services.first(where: { $0.name == printer.name })?.slotColorHexes ?? []
    }

    /// The G-code is fetched once and shared by preview and print.
    private func fetchGcode() async throws -> Data {
        if let d = gcodeData { return d }
        guard let cfg = config, let j = job, j.state == "done" else { throw ConnectError.decode }
        let d = try await ConnectClient(config: cfg).gcode(j.id)
        gcodeData = d
        return d
    }

    private func openPreview() async {
        fetchingPreview = true; jobError = nil
        defer { fetchingPreview = false }
        do { _ = try await fetchGcode(); showPreview = true } catch { jobError = error.localizedDescription }
    }

    /// Upload the G-code to the printer; `start` also begins the print
    /// (Orca's "Print" versus "Send").
    private func sendToPrinter(start: Bool) async {
        guard job?.state == "done",
              let svc = printerServices.services.first(where: { $0.name == printer.name }) else { return }
        printing = true; jobError = nil
        defer { printing = false }
        do {
            stage = "download"
            var data = try await fetchGcode()
            // Orca cannot render thumbnails without a screen, so the plate is
            // drawn here and written into the G-code — that is the picture the
            // printer shows in its file list.
            let colours: [UIColor] = (0..<4).map { i in
                let hex = toolColorHexes[safe: i] ?? ""
                return hex.isEmpty ? UIColor.systemGray : UIColor(Color(hex: hex) ?? .gray)
            }
            if let shot = PlateThumbnail.render(plate: plate, headColors: colours,
                                                accent: UIColor(Color(hex: printer.themeColor) ?? .blue)) {
                data = PlateThumbnail.inject(into: data, image: shot)
            }
            // Named like a normal upload: model, material and print time —
            // e.g. "laptop_stand_PETG_3h52m". A number is only added when the
            // printer already holds a file of that name.
            var parts = [(plate.objects.first?.name ?? "PaxxMaker").asPrintFileName]
            let material = filamentTypes[max(0, head - 1)].trimmingCharacters(in: .whitespaces)
            if !material.isEmpty { parts.append(material) }
            if let secs = job?.result?.time_s, secs > 0 { parts.append(Self.duration(secs)) }
            let base = parts.joined(separator: "_")
            var name = base + ".gcode"
            if svc.files.contains(where: { $0.filename == name }) {
                var n = 2
                while svc.files.contains(where: { $0.filename == "\(base)_\(n).gcode" }) { n += 1 }
                name = "\(base)_\(n).gcode"
            }
            let ok = await withCheckedContinuation { cont in svc.uploadFileData(filename: name, data: data) { cont.resume(returning: $0) } }
            guard ok else { jobError = lz(en: "Upload to the printer failed.", de: "Upload zum Drucker fehlgeschlagen.", fr: "Échec de l'envoi à l'imprimante.", es: "Error al subir a la impresora.", pt: "Falha no envio para a impressora.", it: "Invio alla stampante non riuscito.", zh: "上传到打印机失败。"); return }
            if start { svc.startPrint(filename: name) }
            svc.fetchFiles()
            printed = true; printStarted = start
        } catch {
            jobError = error.localizedDescription
        }
    }
}

/// Orca's simple-mode process fields for one set of values: the general
/// ones in the slice sheet, or one object's own (`perObject` hides what
/// only exists print-wide).
struct ProcessFields: View {
    @Binding var q: QuickSettings
    var loading = false
    var perObject = false

    var body: some View {
        Section {
            HStack {
                Text(lz(en: "Layer height", de: "Layerhöhe", fr: "Hauteur de couche", es: "Altura de capa", pt: "Altura de camada", it: "Altezza layer", zh: "层高"))
                Spacer()
                TextField("0.2", text: $q.layerHeight).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 60)
                Text("mm").foregroundStyle(.secondary)
            }
            if !perObject {
                HStack {
                    Text(lz(en: "First layer height", de: "Erste Layerhöhe", fr: "Hauteur 1re couche", es: "Altura 1.ª capa", pt: "Altura 1.ª camada", it: "Altezza 1° layer", zh: "首层层高"))
                    Spacer()
                    TextField("0.2", text: $q.firstLayerHeight).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 60)
                    Text("mm").foregroundStyle(.secondary)
                }
            }
            Picker(lz(en: "Seam", de: "Naht", fr: "Couture", es: "Costura", pt: "Costura", it: "Cucitura", zh: "接缝"), selection: $q.seam) {
                ForEach(QuickSettings.seams, id: \.0) { Text($0.1).tag($0.0) }
                if !QuickSettings.seams.contains(where: { $0.0 == q.seam }) { Text(q.seam).tag(q.seam) }
            }
        } header: {
            HStack {
                Text(lz(en: "Quality", de: "Qualität", fr: "Qualité", es: "Calidad", pt: "Qualidade", it: "Qualità", zh: "质量"))
                Spacer()
                if loading { ProgressView().controlSize(.mini) }
            }
        }
        Section(lz(en: "Strength", de: "Stärke", fr: "Résistance", es: "Resistencia", pt: "Resistência", it: "Resistenza", zh: "强度")) {
            Stepper(value: $q.walls, in: 1...10) {
                HStack { Text(lz(en: "Walls", de: "Wände", fr: "Parois", es: "Paredes", pt: "Paredes", it: "Pareti", zh: "墙")); Spacer(); Text("\(q.walls)").foregroundStyle(.secondary) }
            }
            Stepper(value: $q.topLayers, in: 0...15) {
                HStack { Text(lz(en: "Top layers", de: "Obere Schichten", fr: "Couches sup.", es: "Capas superiores", pt: "Camadas superiores", it: "Layer superiori", zh: "顶层")); Spacer(); Text("\(q.topLayers)").foregroundStyle(.secondary) }
            }
            Stepper(value: $q.bottomLayers, in: 0...15) {
                HStack { Text(lz(en: "Bottom layers", de: "Untere Schichten", fr: "Couches inf.", es: "Capas inferiores", pt: "Camadas inferiores", it: "Layer inferiori", zh: "底层")); Spacer(); Text("\(q.bottomLayers)").foregroundStyle(.secondary) }
            }
            HStack {
                Text(lz(en: "Infill", de: "Infill", fr: "Remplissage", es: "Relleno", pt: "Preenchimento", it: "Riempimento", zh: "填充"))
                Slider(value: $q.infill, in: 0...100, step: 5)
                Text("\(Int(q.infill)) %").frame(width: 48, alignment: .trailing).monospacedDigit()
            }
            Picker(lz(en: "Infill pattern", de: "Infill-Muster", fr: "Motif", es: "Patrón", pt: "Padrão", it: "Motivo", zh: "填充图案"), selection: $q.infillPattern) {
                ForEach(QuickSettings.patterns, id: \.0) { Text($0.1).tag($0.0) }
                if !QuickSettings.patterns.contains(where: { $0.0 == q.infillPattern }) { Text(q.infillPattern).tag(q.infillPattern) }
            }
        }
        Section("Support") {
            Toggle(lz(en: "Enable support", de: "Support aktivieren", fr: "Activer les supports", es: "Activar soportes", pt: "Ativar suportes", it: "Attiva supporti", zh: "启用支撑"), isOn: $q.support)
            if q.support {
                Picker(lz(en: "Type", de: "Art", fr: "Type", es: "Tipo", pt: "Tipo", it: "Tipo", zh: "类型"), selection: $q.tree) {
                    Text(lz(en: "Tree", de: "Baum", fr: "Arbre", es: "Árbol", pt: "Árvore", it: "Albero", zh: "树状")).tag(true)
                    Text("Normal").tag(false)
                }.pickerStyle(.segmented)
                Toggle(lz(en: "On build plate only", de: "Nur auf Druckbett", fr: "Sur le plateau uniquement", es: "Solo sobre la cama", pt: "Somente na mesa", it: "Solo sul piano", zh: "仅在打印板上"), isOn: $q.plateOnly)
                Stepper(value: $q.thresholdAngle, in: 0...90, step: 5) {
                    HStack { Text(lz(en: "Threshold angle", de: "Schwellwinkel", fr: "Angle seuil", es: "Ángulo umbral", pt: "Ângulo limite", it: "Angolo soglia", zh: "临界角")); Spacer(); Text("\(q.thresholdAngle)°").foregroundStyle(.secondary) }
                }
            }
        }
        Section(perObject ? lz(en: "Brim", de: "Rand", fr: "Bordure", es: "Borde", pt: "Borda", it: "Brim", zh: "Brim")
                          : lz(en: "Brim & skirt", de: "Rand & Skirt", fr: "Bordure & jupe", es: "Borde y falda", pt: "Borda e saia", it: "Brim e skirt", zh: "裙边与 Brim")) {
            Picker(lz(en: "Brim type", de: "Rand-Typ", fr: "Type de bordure", es: "Tipo de borde", pt: "Tipo de borda", it: "Tipo di brim", zh: "Brim 类型"), selection: $q.brimType) {
                ForEach(QuickSettings.brims, id: \.0) { Text($0.1).tag($0.0) }
                if !QuickSettings.brims.contains(where: { $0.0 == q.brimType }) { Text(q.brimType).tag(q.brimType) }
            }
            if q.brimType != "no_brim" {
                if q.brimType != "auto_brim" {
                    HStack {
                        Text(lz(en: "Brim width", de: "Randbreite", fr: "Largeur", es: "Ancho", pt: "Largura", it: "Larghezza", zh: "宽度"))
                        Spacer()
                        TextField("5", text: $q.brimWidth).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 60)
                        Text("mm").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(lz(en: "Brim-object gap", de: "Abstand zum Objekt", fr: "Écart objet", es: "Separación", pt: "Distância", it: "Distanza", zh: "与模型间距"))
                    Spacer()
                    TextField("0.1", text: $q.brimGap).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 60)
                    Text("mm").foregroundStyle(.secondary)
                }
            }
            if !perObject {
                Stepper(value: $q.skirtLoops, in: 0...10) {
                    HStack { Text(lz(en: "Skirt loops", de: "Skirt-Schleifen", fr: "Boucles de jupe", es: "Vueltas de falda", pt: "Voltas da saia", it: "Giri skirt", zh: "裙边圈数")); Spacer(); Text("\(q.skirtLoops)").foregroundStyle(.secondary) }
                }
            }
        }
    }
}

/// One object's own settings: off = the general ones apply.
struct ObjectSettingsPage: View {
    @ObservedObject var object: ModelPlacement
    let general: QuickSettings
    @AppStorage("app_language") private var appLanguage: String = "en"

    var body: some View {
        Form {
            Section {
                Toggle(lz(en: "Own settings for this object", de: "Eigene Einstellungen für dieses Objekt", fr: "Réglages propres à cet objet", es: "Ajustes propios para este objeto", pt: "Ajustes próprios para este objeto", it: "Impostazioni proprie per questo oggetto", zh: "此对象使用自定义设置"),
                       isOn: Binding(get: { object.settings != nil }, set: { on in object.settings = on ? (object.settings ?? general) : nil }))
            } footer: {
                Text(object.settings == nil
                     ? lz(en: "The object uses the general settings.", de: "Das Objekt nutzt die allgemeinen Einstellungen.", fr: "L'objet utilise les réglages généraux.", es: "El objeto usa los ajustes generales.", pt: "O objeto usa os ajustes gerais.", it: "L'oggetto usa le impostazioni generali.", zh: "该对象使用通用设置。")
                     : lz(en: "Starts from the general values; only this object is affected.", de: "Startet mit den allgemeinen Werten; betrifft nur dieses Objekt.", fr: "Part des valeurs générales ; ne concerne que cet objet.", es: "Parte de los valores generales; solo afecta a este objeto.", pt: "Parte dos valores gerais; afeta só este objeto.", it: "Parte dai valori generali; riguarda solo questo oggetto.", zh: "以通用值为起点；仅影响此对象。"))
            }
            if object.settings != nil {
                ProcessFields(q: Binding(get: { object.settings ?? general }, set: { object.settings = $0 }), perObject: true)
            }
        }
        .keyboardDismissable()
        .navigationTitle(object.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
