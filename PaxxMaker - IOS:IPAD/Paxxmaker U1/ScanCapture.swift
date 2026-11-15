import SwiftUI
import RealityKit
import SceneKit
import Combine

// MARK: - Scanning an object into the slicer (Beta)
//
// Apple's Object Capture does the hard part: a guided walk around the object
// (camera for the detail, LiDAR for tracking and the real size), then the
// reconstruction on the device itself — nothing leaves the phone. What comes
// out is a textured USDZ; `ScanMesh` turns it into a closed, flat-bottomed
// mesh in millimetres, and from there it is an ordinary model: onto the
// plate, or out as an STL.
//
// The order follows Apple's own sample: the capture session is released
// before the reconstruction starts, because both need the GPU and memory.

/// Keeps the interface upright while scanning — the controls turn instead
/// (see `HeldOrientation`).
enum OrientationLock {
    @MainActor static func set(_ mask: UIInterfaceOrientationMask?) {
        AppDelegate.orientationOverride = mask
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        var top = scene.keyWindow?.rootViewController
        while let next = top?.presentedViewController { top = next }
        top?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if let mask { scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in } }
    }
}

/// How the phone is held while scanning: upright, turned to either side, or
/// upside down. Lying flat (looking straight down at the object) says
/// nothing about up and down, so the last direction is kept.
@MainActor
final class HeldOrientation: ObservableObject {
    @Published private(set) var angle: Angle = .zero
    private var observer: NSObjectProtocol?

    var isSideways: Bool { abs(abs(angle.degrees) - 90) < 1 }

    func start() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        update(UIDevice.current.orientation, animated: false)
        observer = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(UIDevice.current.orientation, animated: true) }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    private func update(_ o: UIDeviceOrientation, animated: Bool) {
        let new: Angle
        switch o {
        case .portrait: new = .zero
        case .landscapeLeft: new = .degrees(90)
        case .landscapeRight: new = .degrees(-90)
        case .portraitUpsideDown: new = .degrees(180)
        default: return          // flat or unknown: keep what it was
        }
        guard new != angle else { return }
        if animated { withAnimation(.easeInOut(duration: 0.25)) { angle = new } } else { angle = new }
    }
}

/// What Scan to Duplicate does, how exact it is and where it stops — behind
/// the question mark next to the entry.
struct ScanHelpText: View {
    @AppStorage("app_language") private var appLanguage: String = "en"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Scan to Duplicate").font(.headline)
                Text(lz(en: "The phone photographs the object all the way round; the LiDAR sensor supplies the real size. The 3D model is built on the phone itself. Afterwards it is made printable automatically: loose bits removed, holes closed, the base cut flat.",
                        de: "Das iPhone fotografiert das Objekt rundherum, der LiDAR-Sensor liefert die echte Größe. Das 3D-Modell entsteht auf dem iPhone selbst. Danach wird es automatisch druckfertig gemacht: lose Teile entfernt, Löcher geschlossen, der Boden plan geschnitten.",
                        fr: "Le téléphone photographie l'objet tout autour ; le capteur LiDAR fournit la taille réelle. Le modèle 3D est calculé sur le téléphone. Ensuite il est rendu imprimable automatiquement : fragments retirés, trous fermés, base aplanie.",
                        es: "El teléfono fotografía el objeto por todos lados; el sensor LiDAR aporta el tamaño real. El modelo 3D se calcula en el propio teléfono. Después se prepara para imprimir automáticamente: fragmentos fuera, agujeros cerrados, base aplanada.",
                        pt: "O telefone fotografa o objeto por todos os lados; o sensor LiDAR fornece o tamanho real. O modelo 3D é calculado no próprio telefone. Depois fica pronto para imprimir automaticamente: fragmentos removidos, furos fechados, base aplanada.",
                        it: "Il telefono fotografa l'oggetto tutto intorno; il sensore LiDAR fornisce le dimensioni reali. Il modello 3D viene calcolato sul telefono. Poi viene reso stampabile automaticamente: frammenti rimossi, fori chiusi, base spianata.",
                        zh: "手机会环绕物体拍照，LiDAR 传感器提供真实尺寸。3D 模型直接在手机上生成。之后会自动处理为可打印模型：去除碎片、补洞、底部切平。"))
                Text(lz(en: "Accuracy", de: "Genauigkeit", fr: "Précision", es: "Precisión", pt: "Precisão", it: "Precisione", zh: "精度")).font(.subheadline.weight(.semibold))
                Text(lz(en: "Typically within about 0.5–1 mm of the real object (measured in studies of Apple's Object Capture). Good for figures, decoration and shaped parts — not for fits, threads or parts that have to be exact to a tenth of a millimetre.",
                        de: "Meist etwa 0,5–1 mm Abweichung vom echten Objekt (gemessen in Studien zu Apples Object Capture). Gut für Figuren, Deko und Formteile — nicht für Passungen, Gewinde oder Teile, die auf Zehntelmillimeter stimmen müssen.",
                        fr: "Généralement à environ 0,5–1 mm de l'objet réel (mesuré dans des études sur Object Capture d'Apple). Bien pour des figurines, de la déco et des pièces de forme — pas pour des ajustements, filetages ou pièces précises au dixième.",
                        es: "Normalmente con una desviación de unos 0,5–1 mm respecto al objeto real (medido en estudios sobre Object Capture de Apple). Bien para figuras, decoración y piezas de forma; no para ajustes, roscas o piezas exactas a la décima.",
                        pt: "Normalmente cerca de 0,5–1 mm de diferença do objeto real (medido em estudos sobre o Object Capture da Apple). Bom para figuras, decoração e peças de forma — não para encaixes, roscas ou peças exatas ao décimo de milímetro.",
                        it: "In genere entro circa 0,5–1 mm dall'oggetto reale (misurato in studi su Object Capture di Apple). Adatto a figure, decorazioni e pezzi sagomati — non ad accoppiamenti, filettature o pezzi precisi al decimo.",
                        zh: "通常与实物相差约 0.5–1 毫米（来自对 Apple Object Capture 的研究测量）。适合手办、装饰和造型件——不适合配合件、螺纹或需精确到 0.1 毫米的零件。"))
                Text(lz(en: "Limits", de: "Grenzen", fr: "Limites", es: "Límites", pt: "Limites", it: "Limiti", zh: "限制")).font(.subheadline.weight(.semibold))
                Text(lz(en: "Works best with matte, textured objects of about 5 cm and up, in even light. Shiny, transparent, very dark or very thin objects scan poorly. Colours are not taken over — paint the heads on the plate as usual.",
                        de: "Am besten mit matten, strukturierten Objekten ab etwa 5 cm, bei gleichmäßigem Licht. Glänzende, durchsichtige, sehr dunkle oder sehr dünne Objekte scannen schlecht. Farben werden nicht übernommen — die Köpfe wie gewohnt auf der Platte einfärben.",
                        fr: "Idéal pour des objets mats et texturés d'environ 5 cm ou plus, sous une lumière homogène. Les objets brillants, transparents, très sombres ou très fins passent mal. Les couleurs ne sont pas reprises — peins les têtes sur le plateau comme d'habitude.",
                        es: "Funciona mejor con objetos mate y con textura de unos 5 cm o más, con luz uniforme. Los objetos brillantes, transparentes, muy oscuros o muy finos se escanean mal. Los colores no se transfieren: pinta los cabezales en la placa como siempre.",
                        pt: "Funciona melhor com objetos foscos e com textura a partir de uns 5 cm, com luz uniforme. Objetos brilhantes, transparentes, muito escuros ou muito finos escaneiam mal. As cores não são transferidas — pinte as cabeças na mesa como de costume.",
                        it: "Funziona meglio con oggetti opachi e con texture da circa 5 cm in su, con luce uniforme. Oggetti lucidi, trasparenti, molto scuri o molto sottili si scansionano male. I colori non vengono ripresi — colora le teste sul piano come al solito.",
                        zh: "最适合约 5 厘米以上、表面哑光且有纹理的物体，并需光线均匀。反光、透明、很暗或很薄的物体效果差。颜色不会被保留——请像平时一样在打印板上为各喷头上色。"))
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(18)
        }
        // A scroll view has no height of its own to offer, and a popover
        // sized from nothing collapses — so it gets a fixed one.
        .frame(width: 340, height: 440)
    }
}

enum ScanSupport {
    /// LiDAR, A14 or newer. Everywhere else the entry is not shown at all.
    @MainActor static var available: Bool { ObjectCaptureSession.isSupported && PhotogrammetrySession.isSupported }
}

@MainActor
final class ScanModel: ObservableObject {
    enum Phase: Equatable { case capturing, reconstructing, processing, done, failed(String) }

    @Published var phase: Phase = .capturing
    @Published private(set) var session: ObjectCaptureSession?
    @Published var passCompleted = false
    @Published var passes = 1
    /// How the current round was started: after turning the object over, or
    /// the same way up from a different angle.
    @Published var lastPassFlipped = false
    /// Photos taken when the current round began — for "photos this round".
    @Published var passStartShots = 0
    @Published var progress: Double = 0
    @Published var remaining: TimeInterval? = nil
    @Published var stage = ""
    @Published var mesh: TriMesh? = nil
    @Published var report: ScanMesh.Report? = nil
    /// Built once per result, not on every redraw of the screen.
    /// Made once per scan. Changing the base cut only swaps the mesh inside
    /// it — a new scene would throw the view back to where it started while
    /// someone is zoomed in on the very edge they are trimming.
    @Published private(set) var preview: ScanPreviewScene? = nil
    @Published var detectionFailed = false

    private let folder: URL
    private var images: URL { folder.appendingPathComponent("Images", isDirectory: true) }
    private var checkpoints: URL { folder.appendingPathComponent("Checkpoint", isDirectory: true) }
    private var model: URL { folder.appendingPathComponent("scan.usdz") }
    private var tasks: [Task<Void, Never>] = []
    private var photogrammetry: PhotogrammetrySession? = nil

    init() {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaxxMakerScan", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        let s = ObjectCaptureSession()
        var cfg = ObjectCaptureSession.Configuration()
        cfg.checkpointDirectory = checkpoints
        cfg.isOverCaptureEnabled = true
        s.start(imagesDirectory: images, configuration: cfg)
        session = s
        if case let .failed(e) = s.state { phase = .failed(e.localizedDescription); return }
        listen(to: s)
    }

    private func listen(to s: ObjectCaptureSession) {
        tasks.append(Task { [weak self] in
            for await state in s.stateUpdates {
                guard let self else { return }
                switch state {
                case .completed:
                    // Its own task: `reconstruct` stops these listeners, and
                    // it must not stop itself with them.
                    Task { await self.reconstruct() }
                    return
                case .failed(let e):
                    if case ObjectCaptureSession.Error.cancelled = e { return }
                    self.phase = .failed(e.localizedDescription)
                default: break
                }
            }
        })
        tasks.append(Task { [weak self] in
            for await done in s.userCompletedScanPassUpdates {
                guard let self else { return }
                if done { self.passDone() }
            }
        })
    }

    // MARK: capture controls

    func detect() { detectionFailed = !(session?.startDetecting() ?? false) }
    func redetect() { _ = session?.resetDetection() }
    func startCapturing() { session?.startCapturing() }

    /// A round is over — reported by Object Capture once the object was
    /// circled, or ended by hand. Stops the camera and asks what comes next,
    /// with a short vibration so it is noticed while walking.
    func passDone() {
        guard !passCompleted, session != nil else { return }
        passCompleted = true
        session?.pause()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Next round: turned over for the underside, or the same way up from
    /// another angle when the object must not be turned.
    func nextPass(flipped: Bool) {
        guard let s = session else { return }
        if flipped { s.beginNewScanPassAfterFlip() } else { s.beginNewScanPass() }
        passes += 1
        lastPassFlipped = flipped
        passStartShots = s.numberOfShotsTaken
        passCompleted = false
        s.resume()
    }

    func finish() {
        passCompleted = false
        session?.finish()
    }

    var canFlip: Bool { !(session?.feedback.contains(.objectNotFlippable) ?? false) }

    // MARK: reconstruction

    private func reconstruct() async {
        // Capture first gives back its GPU and memory — Apple's sample does
        // the same; both at once does not fit on a phone.
        tasks.forEach { $0.cancel() }; tasks.removeAll()
        session = nil
        phase = .reconstructing
        progress = 0
        do {
            var cfg = PhotogrammetrySession.Configuration()
            cfg.checkpointDirectory = checkpoints
            let p = try PhotogrammetrySession(input: images, configuration: cfg)
            photogrammetry = p
            try p.process(requests: [.modelFile(url: model)])
            var failure: String? = nil
            outputs: for try await out in p.outputs {
                switch out {
                case .requestProgress(_, let f): progress = f
                case .requestProgressInfo(_, let info):
                    remaining = info.estimatedRemainingTime
                    stage = info.processingStage.map(Self.stageText) ?? stage
                case .requestError(_, let e): failure = e.localizedDescription
                case .processingCancelled: failure = "cancelled"; break outputs
                case .processingComplete: break outputs
                default: break
                }
            }
            photogrammetry = nil
            if let failure {
                if failure != "cancelled" { phase = .failed(failure) }
                return
            }
            await processModel()
        } catch {
            photogrammetry = nil
            phase = .failed(error.localizedDescription)
        }
    }

    /// USDZ → printable mesh. The heavy part runs off the main thread.
    private func processModel() async {
        phase = .processing
        do {
            let raw = try await ScanMesh.triangles(fromModelFile: model)
            let result = try await Task.detached(priority: .userInitiated) { try ScanMesh.prepare(raw) }.value
            var m = TriMesh()
            m.vertices = result.vertices
            m.name = Self.defaultName()
            mesh = m
            report = result.report
            preview = ScanPreviewScene(mesh: m)
            phase = .done
            // The photos and the textured model are no longer needed.
            try? FileManager.default.removeItem(at: images)
            try? FileManager.default.removeItem(at: checkpoints)
        } catch ScanMesh.Failure.tooSmall {
            phase = .failed(lz(en: "The scan came out too small to print. Scan a bigger object or get closer.",
                               de: "Der Scan ist zu klein zum Drucken geworden. Ein größeres Objekt scannen oder näher herangehen.",
                               fr: "Le scan est trop petit pour être imprimé. Scanne un objet plus grand ou rapproche-toi.",
                               es: "El escaneo quedó demasiado pequeño para imprimir. Escanea un objeto mayor o acércate más.",
                               pt: "O scan ficou pequeno demais para imprimir. Escaneie um objeto maior ou aproxime-se.",
                               it: "La scansione è troppo piccola per la stampa. Scansiona un oggetto più grande o avvicinati.",
                               zh: "扫描结果太小，无法打印。请扫描更大的物体或靠近一些。"))
        } catch {
            phase = .failed(lz(en: "The scan could not be turned into a printable model.",
                               de: "Aus dem Scan ließ sich kein druckbares Modell machen.",
                               fr: "Impossible de transformer le scan en modèle imprimable.",
                               es: "No se pudo convertir el escaneo en un modelo imprimible.",
                               pt: "Não foi possível transformar o scan num modelo imprimível.",
                               it: "Non è stato possibile trasformare la scansione in un modello stampabile.",
                               zh: "无法把扫描结果转换为可打印的模型。"))
        }
    }

    /// Takes a different amount off the bottom and redoes the clean-up.
    func recut(_ mm: Float) async {
        guard let url = FileManager.default.fileExists(atPath: model.path) ? model : nil else { return }
        do {
            let raw = try await ScanMesh.triangles(fromModelFile: url)
            let result = try await Task.detached(priority: .userInitiated) { try ScanMesh.prepare(raw, cut: mm) }.value
            let name = mesh?.name ?? Self.defaultName()
            var m = TriMesh(); m.vertices = result.vertices; m.name = name
            mesh = m; report = result.report
            if let preview { preview.show(m) } else { preview = ScanPreviewScene(mesh: m) }
        } catch {}
    }

    /// Stops everything and leaves nothing behind on the phone.
    func cancelAll() {
        tasks.forEach { $0.cancel() }; tasks.removeAll()
        session?.cancel(); session = nil
        photogrammetry?.cancel(); photogrammetry = nil
        cleanUp()
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    /// Where the STL for the share sheet lives, named after the scan.
    func exportURL(for name: String) -> URL {
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        return folder.appendingPathComponent((safe.isEmpty ? "Scan" : safe) + ".stl")
    }

    /// Writes the STL (after a new result); renaming only moves the file.
    func writeExport(named name: String) -> URL? {
        guard let m = mesh else { return nil }
        let url = exportURL(for: name)
        do { try m.stlData.write(to: url, options: .atomic); return url } catch { return nil }
    }

    func renameExport(from old: URL, to name: String) -> URL {
        let new = exportURL(for: name)
        guard new != old else { return old }
        try? FileManager.default.removeItem(at: new)
        return (try? FileManager.default.moveItem(at: old, to: new)) != nil ? new : old
    }

    static func defaultName() -> String {
        let f = DateFormatter(); f.dateFormat = "dd.MM. HH-mm"
        return "Scan " + f.string(from: Date())
    }

    static func stageText(_ s: PhotogrammetrySession.Output.ProcessingStage) -> String {
        switch s {
        case .preProcessing: return lz(en: "Preparing…", de: "Vorbereiten…", fr: "Préparation…", es: "Preparando…", pt: "Preparando…", it: "Preparazione…", zh: "准备中…")
        case .imageAlignment: return lz(en: "Aligning photos…", de: "Fotos ausrichten…", fr: "Alignement des photos…", es: "Alineando fotos…", pt: "Alinhando fotos…", it: "Allineamento foto…", zh: "对齐照片…")
        case .pointCloudGeneration: return lz(en: "Building point cloud…", de: "Punktwolke erzeugen…", fr: "Nuage de points…", es: "Generando nube de puntos…", pt: "Gerando nuvem de pontos…", it: "Nuvola di punti…", zh: "生成点云…")
        case .meshGeneration: return lz(en: "Building mesh…", de: "Netz erzeugen…", fr: "Création du maillage…", es: "Generando malla…", pt: "Gerando malha…", it: "Creazione mesh…", zh: "生成网格…")
        case .textureMapping: return lz(en: "Textures…", de: "Texturen…", fr: "Textures…", es: "Texturas…", pt: "Texturas…", it: "Texture…", zh: "贴图…")
        case .optimization: return lz(en: "Optimising…", de: "Optimieren…", fr: "Optimisation…", es: "Optimizando…", pt: "Otimizando…", it: "Ottimizzazione…", zh: "优化中…")
        @unknown default: return ""
        }
    }
}

// MARK: - The flow

struct ScanFlowView: View {
    /// Called with the finished mesh when it should go onto the plate.
    var onPlate: (TriMesh) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("app_language") private var appLanguage: String = "en"
    @StateObject private var model = ScanModel()
    @State private var name = ""
    @State private var cut: Double = 0
    @State private var exportURL: URL? = nil

    var body: some View {
        Group {
            switch model.phase {
            case .capturing:
                if let s = model.session { CaptureScreen(model: model, session: s, onCancel: close) }
            case .reconstructing, .processing:
                reconstructing
            case .done:
                result
            case .failed(let text):
                failed(text)
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; model.cancelAll() }
    }

    private func close() { model.cancelAll(); dismiss() }

    // MARK: reconstruction

    private var reconstructing: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "cube.transparent").font(.system(size: 54)).foregroundColor(.accentColor)
            Text(model.phase == .processing
                 ? lz(en: "Making it printable…", de: "Druckfertig machen…", fr: "Préparation pour l'impression…", es: "Preparando para imprimir…", pt: "Preparando para impressão…", it: "Preparazione per la stampa…", zh: "正在处理为可打印模型…")
                 : lz(en: "Building the 3D model", de: "3D-Modell wird berechnet", fr: "Calcul du modèle 3D", es: "Calculando el modelo 3D", pt: "Calculando o modelo 3D", it: "Calcolo del modello 3D", zh: "正在生成 3D 模型"))
                .font(.title3.bold())
            if model.phase == .reconstructing {
                ProgressView(value: model.progress).padding(.horizontal, 40)
                HStack {
                    Text(model.stage)
                    Spacer()
                    if let r = model.remaining, r > 0 {
                        Text(lz(en: "about", de: "noch ca.", fr: "encore env.", es: "aprox.", pt: "cerca de", it: "circa", zh: "约") + " " + Self.minutes(r))
                    }
                }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 40)
                Text(lz(en: "This runs on the phone and takes a few minutes. Please keep the app open.",
                        de: "Das läuft auf dem iPhone selbst und dauert einige Minuten. Bitte die App geöffnet lassen.",
                        fr: "Le calcul se fait sur le téléphone et prend quelques minutes. Garde l'app ouverte.",
                        es: "Se calcula en el propio teléfono y tarda unos minutos. Mantén la app abierta.",
                        pt: "Isso roda no próprio telefone e leva alguns minutos. Mantenha o app aberto.",
                        it: "Il calcolo avviene sul telefono e richiede alcuni minuti. Tieni l'app aperta.",
                        zh: "计算在手机上进行，需要几分钟。请保持 App 打开。"))
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
            } else {
                ProgressView()
            }
            Spacer()
            Button(role: .destructive) { close() } label: {
                Text(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消"))
            }
            .padding(.bottom, 30)
        }
    }

    private static func minutes(_ t: TimeInterval) -> String {
        t < 60 ? "\(Int(t)) s" : "\(Int((t / 60).rounded(.up))) min"
    }

    // MARK: result

    private var result: some View {
        NavigationStack {
            Form {
                if let m = model.mesh {
                    if let pv = model.preview {
                        Section {
                            ScanPreviewView(preview: pv)
                                .frame(height: 260)
                                .listRowInsets(EdgeInsets())
                        }
                    }
                    Section {
                        TextField(lz(en: "Name", de: "Name", fr: "Nom", es: "Nombre", pt: "Nome", it: "Nome", zh: "名称"), text: $name)
                    } header: {
                        Text(lz(en: "Name", de: "Name", fr: "Nom", es: "Nombre", pt: "Nome", it: "Nome", zh: "名称"))
                    }
                    if let r = model.report { reportSection(r) }
                    Section {
                        Button {
                            var out = m
                            out.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? m.name : name
                            onPlate(out)
                            dismiss()
                        } label: {
                            Label(lz(en: "Put on the build plate", de: "Auf die Druckplatte", fr: "Mettre sur le plateau", es: "Poner en la placa", pt: "Colocar na mesa", it: "Metti sul piano", zh: "放到打印板上"),
                                  systemImage: "square.3.layers.3d.down.right")
                                .fontWeight(.semibold)
                        }
                        if let url = exportURL {
                            ShareLink(item: url) {
                                Label(lz(en: "Export (STL)", de: "Exportieren (STL)", fr: "Exporter (STL)", es: "Exportar (STL)", pt: "Exportar (STL)", it: "Esporta (STL)", zh: "导出（STL）"),
                                      systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }
            }
            .keyboardDismissable()
            .navigationTitle(lz(en: "Scan", de: "Scan", fr: "Scan", es: "Escaneo", pt: "Scan", it: "Scansione", zh: "扫描"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lz(en: "Discard", de: "Verwerfen", fr: "Jeter", es: "Descartar", pt: "Descartar", it: "Scarta", zh: "放弃")) { close() }
                }
            }
            .onAppear {
                name = model.mesh?.name ?? ""
                cut = Double(model.report?.cutHeight ?? 0)
                exportURL = model.writeExport(named: name)
            }
            .onChange(of: name) { _, new in
                if var m = model.mesh, !new.trimmingCharacters(in: .whitespaces).isEmpty { m.name = new; model.mesh = m }
                if let old = exportURL { exportURL = model.renameExport(from: old, to: new) }
            }
        }
    }


    @ViewBuilder private func reportSection(_ r: ScanMesh.Report) -> some View {
        Section {
            LabeledContent(lz(en: "Size", de: "Maße", fr: "Dimensions", es: "Medidas", pt: "Medidas", it: "Dimensioni", zh: "尺寸"),
                           value: String(format: "%.1f × %.1f × %.1f mm", r.size.x, r.size.y, r.size.z))
            LabeledContent(lz(en: "Triangles", de: "Dreiecke", fr: "Triangles", es: "Triángulos", pt: "Triângulos", it: "Triangoli", zh: "三角形"), value: "\(r.trianglesOut)")
            Stepper(value: $cut, in: 0...10, step: 0.2) {
                LabeledContent(lz(en: "Base cut flat", de: "Boden plan geschnitten", fr: "Base aplanie", es: "Base aplanada", pt: "Base aplanada", it: "Base spianata", zh: "底部切平"),
                               value: String(format: "%.1f mm", cut))
            }
            .onChange(of: cut) { _, new in
                // Setting it from the result on appear is not a change.
                guard abs(new - Double(model.report?.cutHeight ?? -1)) > 0.01 else { return }
                Task {
                    await model.recut(Float(new))
                    exportURL = model.writeExport(named: name)
                }
            }
            if r.removedParts > 0 {
                LabeledContent(lz(en: "Loose bits removed", de: "Lose Teile entfernt", fr: "Fragments retirés", es: "Fragmentos quitados", pt: "Fragmentos removidos", it: "Frammenti rimossi", zh: "已移除碎片"), value: "\(r.removedParts)")
            }
            if r.holesFilled > 0 {
                LabeledContent(lz(en: "Holes closed", de: "Löcher geschlossen", fr: "Trous fermés", es: "Agujeros cerrados", pt: "Furos fechados", it: "Fori chiusi", zh: "已补洞"), value: "\(r.holesFilled)")
            }
            Label(r.watertight
                  ? lz(en: "Closed surface — ready to print", de: "Geschlossene Oberfläche — druckbereit", fr: "Surface fermée — prête à imprimer", es: "Superficie cerrada — lista para imprimir", pt: "Superfície fechada — pronta para imprimir", it: "Superficie chiusa — pronta per la stampa", zh: "表面封闭——可直接打印")
                  : lz(en: "Not fully closed — OrcaSlicer usually repairs this when slicing", de: "Nicht ganz geschlossen — OrcaSlicer repariert das beim Slicen meist selbst", fr: "Pas entièrement fermé — OrcaSlicer le répare généralement", es: "No del todo cerrado — OrcaSlicer suele repararlo al laminar", pt: "Não totalmente fechado — o OrcaSlicer costuma reparar ao fatiar", it: "Non del tutto chiuso — di solito OrcaSlicer lo ripara", zh: "未完全封闭——OrcaSlicer 切片时通常会自动修复"),
                  systemImage: r.watertight ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(r.watertight ? .green : .orange)
                .font(.footnote)
        } footer: {
            Text(lz(en: "Scans are accurate to roughly half a millimetre to a millimetre — fine for figures and shapes, not for tight fits.",
                    de: "Scans sind auf etwa einen halben bis einen Millimeter genau — gut für Figuren und Formteile, nicht für enge Passungen.",
                    fr: "Les scans sont précis à environ un demi-millimètre à un millimètre — bien pour des figurines et des formes, pas pour des ajustements serrés.",
                    es: "Los escaneos tienen una precisión de medio a un milímetro: bien para figuras y formas, no para ajustes precisos.",
                    pt: "Os scans têm precisão de cerca de meio a um milímetro — bom para figuras e formas, não para encaixes justos.",
                    it: "Le scansioni sono precise da mezzo a un millimetro circa — bene per figure e forme, non per accoppiamenti precisi.",
                    zh: "扫描精度约为 0.5–1 毫米——适合模型和造型件，不适合精密配合。"))
        }
    }

    private func failed(_ text: String) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 48)).foregroundColor(.orange)
            Text(text).multilineTextAlignment(.center).padding(.horizontal, 30)
            Spacer()
            Button(lz(en: "Close", de: "Schließen", fr: "Fermer", es: "Cerrar", pt: "Fechar", it: "Chiudi", zh: "关闭")) { close() }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 30)
        }
    }
}

// MARK: - Capture screen

private struct CaptureScreen: View {
    @ObservedObject var model: ScanModel
    let session: ObjectCaptureSession
    var onCancel: () -> Void
    @AppStorage("app_language") private var appLanguage: String = "en"
    @StateObject private var held = HeldOrientation()

    var body: some View {
        ZStack {
            ObjectCaptureView(session: session)
                .ignoresSafeArea()
            // The camera stays as it is; only the controls turn with the
            // phone, so they read the right way up however it is held.
            GeometryReader { g in
                let w = held.isSideways ? g.size.height : g.size.width
                let h = held.isSideways ? g.size.width : g.size.height
                ZStack {
                    VStack {
                        topBar
                        if let hint = feedbackText { Text(hint).font(.callout.weight(.semibold)).padding(10)
                                .background(.ultraThinMaterial, in: Capsule()).padding(.top, 6) }
                        Spacer()
                        bottomPanel.frame(maxWidth: 520)
                    }
                    .padding()
                    if model.passCompleted { passPanel(compact: held.isSideways) }
                }
                .frame(width: w, height: h)
                .rotationEffect(held.angle)
                .frame(width: g.size.width, height: g.size.height)
            }
        }
        .onChange(of: session.userCompletedScanPass) { _, done in
            if done { model.passDone() }
        }
        .onAppear {
            OrientationLock.set(.portrait)
            held.start()
        }
        .onDisappear {
            held.stop()
            OrientationLock.set(nil)
        }
    }

    private var topBar: some View {
        HStack {
            Button(lz(en: "Cancel", de: "Abbrechen", fr: "Annuler", es: "Cancelar", pt: "Cancelar", it: "Annulla", zh: "取消")) { onCancel() }
                .padding(.horizontal, 14).padding(.vertical, 8).background(.ultraThinMaterial, in: Capsule())
            Spacer()
            if case .capturing = session.state {
                Text(lz(en: "Round \(model.passes)", de: "Runde \(model.passes)", fr: "Tour \(model.passes)", es: "Vuelta \(model.passes)", pt: "Volta \(model.passes)", it: "Giro \(model.passes)", zh: "第 \(model.passes) 圈")
                     + " · \(session.numberOfShotsTaken) / \(session.maximumNumberOfInputImages)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 12).padding(.vertical, 8).background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    @ViewBuilder private var bottomPanel: some View {
        VStack(spacing: 12) {
            switch session.state {
            case .ready:
                instruction(lz(en: "Put the object on a plain, textured surface in good light and aim at it.",
                               de: "Objekt auf eine ruhige, strukturierte Unterlage in gutes Licht stellen und anpeilen.",
                               fr: "Pose l'objet sur une surface texturée, bien éclairée, et vise-le.",
                               es: "Pon el objeto sobre una superficie con textura, con buena luz, y apunta hacia él.",
                               pt: "Coloque o objeto numa superfície com textura, com boa luz, e aponte para ele.",
                               it: "Metti l'oggetto su una superficie con texture, ben illuminata, e inquadralo.",
                               zh: "把物体放在光线充足、有纹理的平面上，并对准它。"))
                if model.detectionFailed {
                    instruction(lz(en: "No object found — get a little closer and keep it in the middle.",
                                   de: "Kein Objekt gefunden — etwas näher heran und mittig halten.",
                                   fr: "Aucun objet trouvé — rapproche-toi et garde-le au centre.",
                                   es: "No se encontró el objeto: acércate un poco y mantenlo centrado.",
                                   pt: "Nenhum objeto encontrado — aproxime-se e mantenha-o no centro.",
                                   it: "Nessun oggetto trovato — avvicinati e tienilo al centro.",
                                   zh: "未找到物体——稍微靠近并保持在画面中央。"))
                }
                primary(lz(en: "Detect object", de: "Objekt erkennen", fr: "Détecter l'objet", es: "Detectar objeto", pt: "Detectar objeto", it: "Rileva oggetto", zh: "识别物体")) { model.detect() }
            case .detecting:
                instruction(lz(en: "Adjust the box so it just holds the object.",
                               de: "Rahmen so anpassen, dass er das Objekt knapp umschließt.",
                               fr: "Ajuste le cadre pour qu'il entoure juste l'objet.",
                               es: "Ajusta el cuadro para que rodee justo el objeto.",
                               pt: "Ajuste a caixa para envolver só o objeto.",
                               it: "Regola il riquadro in modo che racchiuda appena l'oggetto.",
                               zh: "调整框体，使其刚好包住物体。"))
                HStack(spacing: 12) {
                    secondary(lz(en: "Detect again", de: "Neu erkennen", fr: "Redétecter", es: "Detectar de nuevo", pt: "Detectar de novo", it: "Rileva di nuovo", zh: "重新识别")) { model.redetect() }
                    primary(lz(en: "Start", de: "Aufnahme starten", fr: "Démarrer", es: "Empezar", pt: "Iniciar", it: "Avvia", zh: "开始拍摄")) { model.startCapturing() }
                }
            case .capturing:
                instruction(roundInstruction)
                // Object Capture only counts a round once the object was fully
                // circled. When it never says so (small object, a gap in the
                // circle, against a wall), the way on must not depend on it.
                if session.numberOfShotsTaken - model.passStartShots >= 25 {
                    secondary(lz(en: "End this round", de: "Runde abschließen", fr: "Terminer ce tour", es: "Terminar esta vuelta", pt: "Terminar esta volta", it: "Chiudi questo giro", zh: "结束本圈")) { model.passDone() }
                }
            case .finishing:
                HStack(spacing: 10) {
                    ProgressView()
                    Text(lz(en: "Finishing the photos…", de: "Fotos werden abgeschlossen…", fr: "Finalisation des photos…", es: "Terminando las fotos…", pt: "Finalizando as fotos…", it: "Completamento foto…", zh: "正在完成拍摄…"))
                }
                .padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            default:
                EmptyView()
            }
        }
    }

    /// After a round: turn it over for the underside, go round again from
    /// another height, or build the model. Held sideways there is less
    /// height than width, so the point cloud moves next to the choices.
    private func passPanel(compact: Bool) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Group {
                if compact {
                    HStack(alignment: .center, spacing: 16) {
                        pointCloud.frame(width: 200, height: 170)
                        passChoices
                    }
                } else {
                    VStack(spacing: 12) {
                        pointCloud.frame(height: 220)
                        passChoices
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: compact ? 640 : 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .padding()
        }
    }

    private var pointCloud: some View {
        ObjectCapturePointCloudView(session: session)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var passChoices: some View {
        VStack(spacing: 10) {
            Text(lz(en: "Round \(model.passes) done", de: "Runde \(model.passes) fertig", fr: "Tour \(model.passes) terminé", es: "Vuelta \(model.passes) lista", pt: "Volta \(model.passes) concluída", it: "Giro \(model.passes) completato", zh: "第 \(model.passes) 圈完成"))
                .font(.headline)
            Text(nextStepText)
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            // Turning the object is always the first choice: only a second
            // view of it captures the underside. Even when Object Capture
            // thinks it is hard to match (smooth, symmetric) — Apple's own
            // sample still offers "flip anyway".
            primary(lz(en: "Object turned — scan on", de: "Objekt gedreht — weiter scannen", fr: "Objet tourné — continuer", es: "Objeto girado — seguir escaneando", pt: "Objeto virado — continuar", it: "Oggetto girato — continua", zh: "物体已翻转——继续扫描")) { model.nextPass(flipped: true) }
            secondary(lz(en: "Don't turn — only from another height", de: "Nicht drehen — nur aus anderer Höhe", fr: "Ne pas tourner — seulement d'une autre hauteur", es: "No girar — solo desde otra altura", pt: "Não virar — só de outra altura", it: "Non girare — solo da un'altra altezza", zh: "不翻转——只换个高度")) { model.nextPass(flipped: false) }
            if model.passes >= 2 {
                primary(lz(en: "Done — build model", de: "Fertig — Modell berechnen", fr: "Terminé — calculer", es: "Listo — calcular modelo", pt: "Pronto — calcular modelo", it: "Fatto — calcola modello", zh: "完成——生成模型")) { model.finish() }
            } else {
                secondary(lz(en: "Done — build model now", de: "Fertig — Modell jetzt berechnen", fr: "Terminé — calculer maintenant", es: "Listo — calcular ahora", pt: "Pronto — calcular agora", it: "Fatto — calcola ora", zh: "完成——立即生成模型")) { model.finish() }
            }
        }
    }

    /// What the next round is for, in one sentence.
    private var nextStepText: String {
        var text = model.passes == 1
            ? lz(en: "Now turn the object — on its side or upside down — so it is seen from a new perspective and the underside is captured too. Then tap “Object turned”.",
                 de: "Jetzt das Objekt drehen — auf die Seite oder auf den Kopf —, damit es aus einer neuen Perspektive erfasst wird, auch von unten. Danach „Objekt gedreht“ tippen.",
                 fr: "Tourne maintenant l'objet — sur le côté ou à l'envers — pour le capturer sous une nouvelle perspective, dessous compris. Puis touche « Objet tourné ».",
                 es: "Ahora gira el objeto — de lado o boca abajo — para capturarlo desde una nueva perspectiva, también por debajo. Luego toca «Objeto girado».",
                 pt: "Agora vire o objeto — de lado ou de cabeça para baixo — para capturá-lo de uma nova perspectiva, incluindo a parte de baixo. Depois toque em “Objeto virado”.",
                 it: "Ora gira l'oggetto — su un lato o capovolto — per acquisirlo da una nuova prospettiva, anche da sotto. Poi tocca «Oggetto girato».",
                 zh: "现在把物体翻转——侧放或倒放——从新的角度扫描，包括底面。然后点“物体已翻转”。")
            : lz(en: "Seen from enough sides? Then build the model — or turn it once more for what is still missing.",
                 de: "Von genug Seiten erfasst? Dann Modell berechnen — oder noch einmal drehen für das, was noch fehlt.",
                 fr: "Assez de côtés capturés ? Alors calcule le modèle — ou tourne-le encore pour ce qui manque.",
                 es: "¿Capturado desde suficientes lados? Calcula el modelo, o gíralo otra vez para lo que falte.",
                 pt: "Capturado de lados suficientes? Calcule o modelo — ou vire mais uma vez para o que falta.",
                 it: "Acquisito da abbastanza lati? Calcola il modello — o giralo ancora per ciò che manca.",
                 zh: "各个面都扫到了吗？那就生成模型——或再翻一次补上缺少的部分。")
        if !model.canFlip {
            text += "\n" + lz(en: "Note: the scan finds this object hard to match after turning (very smooth or symmetric). Turning still works — a sticker or a bit of tape as a marker helps.",
                              de: "Hinweis: Der Scan hält dieses Objekt nach dem Drehen für schwer zuzuordnen (sehr glatt oder symmetrisch). Drehen geht trotzdem — ein Aufkleber oder etwas Klebeband als Markierung hilft.",
                              fr: "Remarque : le scan trouve cet objet difficile à recaler après rotation (très lisse ou symétrique). Tourner reste possible — un autocollant ou un bout de ruban comme repère aide.",
                              es: "Nota: al escáner le cuesta reconocer este objeto tras girarlo (muy liso o simétrico). Girarlo sigue siendo posible: una pegatina o un trozo de cinta como marca ayuda.",
                              pt: "Nota: o scan tem dificuldade em reconhecer este objeto depois de virado (muito liso ou simétrico). Virar continua possível — um adesivo ou um pedaço de fita como marca ajuda.",
                              it: "Nota: la scansione fatica a riconoscere questo oggetto dopo averlo girato (molto liscio o simmetrico). Girarlo è comunque possibile — un adesivo o un pezzo di nastro come riferimento aiuta.",
                              zh: "提示：扫描认为此物体翻转后难以对齐（过于光滑或对称）。仍然可以翻转——贴一张贴纸或一段胶带作为标记会有帮助。")
        }
        return text
    }

    /// What to do in the current round — Apple's recommended order: once
    /// around, then turned over; objects that must stay upright from low and
    /// from above instead.
    private var roundInstruction: String {
        if model.passes == 1 {
            return lz(en: "Walk slowly all the way around the object. The ring around it fills up as you go.",
                      de: "Langsam einmal ganz um das Objekt herumgehen. Der Ring um das Objekt füllt sich dabei.",
                      fr: "Fais lentement tout le tour de l'objet. L'anneau autour se remplit au fur et à mesure.",
                      es: "Da una vuelta lenta completa alrededor del objeto. El anillo se va llenando.",
                      pt: "Dê uma volta devagar completa ao redor do objeto. O anel vai se preenchendo.",
                      it: "Fai lentamente un giro completo intorno all'oggetto. L'anello si riempie man mano.",
                      zh: "慢慢绕物体完整走一圈，周围的圆环会随之填满。")
        }
        if model.lastPassFlipped {
            return lz(en: "New perspective: the object lies differently now — once more all the way around.",
                      de: "Neue Perspektive: Das Objekt liegt jetzt anders — noch einmal ganz herum.",
                      fr: "Nouvelle perspective : l'objet est posé autrement — refais un tour complet.",
                      es: "Nueva perspectiva: el objeto está en otra posición — da otra vuelta completa.",
                      pt: "Nova perspectiva: o objeto está em outra posição — dê mais uma volta completa.",
                      it: "Nuova prospettiva: l'oggetto è posizionato diversamente — fai un altro giro completo.",
                      zh: "新的角度：物体已换了摆放方式——再完整绕一圈。")
        }
        return model.passes == 2
            ? lz(en: "Hold the phone low, nearly level with the table, and go round once more.",
                 de: "iPhone tief halten, fast auf Tischhöhe, und noch einmal herum.",
                 fr: "Tiens le téléphone bas, presque au niveau de la table, et refais un tour.",
                 es: "Sostén el teléfono bajo, casi a la altura de la mesa, y da otra vuelta.",
                 pt: "Segure o telefone baixo, quase na altura da mesa, e dê mais uma volta.",
                 it: "Tieni il telefono basso, quasi all'altezza del tavolo, e fai un altro giro.",
                 zh: "把手机放低，几乎与桌面平齐，再绕一圈。")
            : lz(en: "Now look down at the object from above and go round once more.",
                 de: "Jetzt von oben auf das Objekt schauen und noch einmal herum.",
                 fr: "Regarde maintenant l'objet d'en haut et refais un tour.",
                 es: "Ahora mira el objeto desde arriba y da otra vuelta.",
                 pt: "Agora olhe o objeto de cima e dê mais uma volta.",
                 it: "Ora guarda l'oggetto dall'alto e fai un altro giro.",
                 zh: "现在从上方俯视物体，再绕一圈。")
    }

    private var feedbackText: String? {
        let f = session.feedback
        if f.contains(.environmentTooDark) { return lz(en: "Too dark", de: "Zu dunkel", fr: "Trop sombre", es: "Demasiado oscuro", pt: "Escuro demais", it: "Troppo buio", zh: "太暗") }
        if f.contains(.environmentLowLight) { return lz(en: "More light would help", de: "Mehr Licht wäre besser", fr: "Plus de lumière aiderait", es: "Más luz ayudaría", pt: "Mais luz ajudaria", it: "Più luce aiuterebbe", zh: "光线不足") }
        if f.contains(.movingTooFast) { return lz(en: "Slower", de: "Langsamer", fr: "Plus lentement", es: "Más despacio", pt: "Mais devagar", it: "Più lentamente", zh: "慢一点") }
        if f.contains(.objectTooClose) { return lz(en: "Too close — step back", de: "Zu nah — etwas zurück", fr: "Trop près — recule", es: "Demasiado cerca — aléjate", pt: "Perto demais — afaste-se", it: "Troppo vicino — allontanati", zh: "太近——后退一点") }
        if f.contains(.objectTooFar) { return lz(en: "Too far — come closer", de: "Zu weit — näher heran", fr: "Trop loin — approche-toi", es: "Demasiado lejos — acércate", pt: "Longe demais — aproxime-se", it: "Troppo lontano — avvicinati", zh: "太远——靠近一点") }
        if f.contains(.outOfFieldOfView) { return lz(en: "Keep the object in view", de: "Objekt im Bild behalten", fr: "Garde l'objet dans le cadre", es: "Mantén el objeto a la vista", pt: "Mantenha o objeto no quadro", it: "Tieni l'oggetto inquadrato", zh: "保持物体在画面中") }
        if f.contains(.overCapturing) { return lz(en: "Enough photos from this side", de: "Genug Fotos von dieser Seite", fr: "Assez de photos de ce côté", es: "Suficientes fotos de este lado", pt: "Fotos suficientes deste lado", it: "Abbastanza foto da questo lato", zh: "这一侧照片已足够") }
        return nil
    }

    private func instruction(_ text: String) -> some View {
        Text(text).font(.callout).multilineTextAlignment(.center)
            .padding(12).frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 13)
        }
        .buttonStyle(.borderedProminent)
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity).padding(.vertical, 13)
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Preview of the finished scan

/// The scan in a small scene. The scene, its camera and the node stay the
/// same for the whole result screen; `show` only replaces the geometry, so
/// the view the user has turned and zoomed to is kept.
@MainActor
final class ScanPreviewScene {
    let scene = SCNScene()
    let camera = SCNNode()
    private let node = SCNNode()

    init(mesh: TriMesh) {
        scene.rootNode.addChildNode(node)
        show(mesh)
        // Framed once, for the first result.
        let (mn, mx) = Self.bounds(mesh)
        let size = max(simd_length(mx - mn), 1)
        let centre = SCNVector3((mn.x + mx.x) / 2, (mn.z + mx.z) / 2, -(mn.y + mx.y) / 2)
        camera.camera = SCNCamera()
        camera.camera?.zNear = Double(size) * 0.01
        camera.camera?.zFar = Double(size) * 20
        camera.position = SCNVector3(centre.x + size * 0.9, centre.y + size * 0.7, centre.z + size * 1.3)
        camera.look(at: centre)
        scene.rootNode.addChildNode(camera)
    }

    func show(_ mesh: TriMesh) {
        var pos: [SCNVector3] = [], nor: [SCNVector3] = []
        pos.reserveCapacity(mesh.vertices.count); nor.reserveCapacity(mesh.vertices.count)
        let v = mesh.vertices
        var i = 0
        while i + 2 < v.count {
            var n = simd_cross(v[i + 1] - v[i], v[i + 2] - v[i]); let l = simd_length(n); if l > 0 { n /= l }
            for k in 0..<3 { let p = v[i + k]; pos.append(SCNVector3(p.x, p.z, -p.y)) }   // Z up → SceneKit Y up
            let sn = SCNVector3(n.x, n.z, -n.y); nor += [sn, sn, sn]
            i += 3
        }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: pos), SCNGeometrySource(normals: nor)],
                            elements: [SCNGeometryElement(indices: (0..<Int32(pos.count)).map { $0 }, primitiveType: .triangles)])
        g.firstMaterial?.diffuse.contents = UIColor.systemTeal
        g.firstMaterial?.lightingModel = .blinn
        node.geometry = g
    }

    private static func bounds(_ mesh: TriMesh) -> (SIMD3<Float>, SIMD3<Float>) {
        var mn = SIMD3<Float>(repeating: .greatestFiniteMagnitude), mx = -mn
        for p in mesh.vertices { mn = simd_min(mn, p); mx = simd_max(mx, p) }
        return mesh.vertices.isEmpty ? (.zero, .zero) : (mn, mx)
    }
}

/// Its own SCNView: SwiftUI's SceneView may hand the camera back to its
/// starting point on an update; this one keeps whatever the fingers did.
private struct ScanPreviewView: UIViewRepresentable {
    let preview: ScanPreviewScene

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = preview.scene
        v.pointOfView = preview.camera
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = true
        v.antialiasingMode = .multisampling4X
        v.backgroundColor = UIColor(white: 0.08, alpha: 1)
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        // Only a different scan gets a different scene; a new cut does not.
        if v.scene !== preview.scene { v.scene = preview.scene; v.pointOfView = preview.camera }
    }
}
