import NXCore
import SwiftUI

struct FoldersView: View {
    @Environment(AppModel.self) private var model
    var onBuild: () -> Void
    @State private var selection: NSPFolder.ID?

    var body: some View {
        HSplitView {
            List(model.folders, selection: $selection) { folder in
                FolderRow(folder: folder).tag(folder.id)
            }
            .frame(minWidth: 260, idealWidth: 300)
            .overlay {
                if model.folders.isEmpty {
                    ContentUnavailableView {
                        Label("Sin carpetas de juego", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text("Añade en Entorno la carpeta que contiene tus carpetas NSP (una por juego, con base, actualización y DLC).")
                    }
                }
            }

            Group {
                if let folder = model.folders.first(where: { $0.id == selection }) {
                    FolderDetailView(folder: folder, onBuild: onBuild)
                } else {
                    Text("Elige una carpeta").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Carpetas NSP")
        .toolbar {
            Button { Task { await model.refresh() } } label: { Label("Escanear", systemImage: "arrow.clockwise") }
        }
    }
}

struct FolderRow: View {
    @Environment(AppModel.self) private var model
    let folder: NSPFolder

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(folder.name).lineLimit(1)
            HStack(spacing: 6) {
                ProfileBadge(state: model.profileState(folder))
                Text(folder.totalSize.bytes)
                if !folder.outputs.isEmpty { Image(systemName: "shippingbox.fill").help("Ya tiene salidas") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct ProfileBadge: View {
    let state: AppModel.ProfileState
    var body: some View {
        switch state {
        case .registered: Label("Con perfil", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .unknown: Label("Sin perfil", systemImage: "questionmark.diamond").foregroundStyle(.orange)
        case .noTitleID: Label("Sin title ID", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }
}

struct FolderDetailView: View {
    @Environment(AppModel.self) private var model
    let folder: NSPFolder
    var onBuild: () -> Void
    @State private var sheet: BuildOptions?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry?.name ?? folder.name).font(.title2.weight(.semibold))
                    HStack {
                        ProfileBadge(state: model.profileState(folder))
                        if let id = folder.baseTitleID { Text(id.description).monospaced().textSelection(.enabled) }
                        if let e = entry { Text("· \(e.engine) · \(e.graphics)") }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    Text(folder.url.path).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                }

                explanation

                GroupBox("Construir") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button { quick(.macApp) } label: { Label("App de Mac", systemImage: "macbook") }
                                .buttonStyle(.borderedProminent)
                            Button { quick(.ios) } label: { Label("IPA para iPhone/iPad", systemImage: "iphone") }
                            Button { quick(.mac) } label: { Label("Build de desarrollo", systemImage: "wrench.and.screwdriver") }
                                .help("--platform mac: solo lo que hace falta para correr en este Mac; imprime el comando de arranque.")
                            Spacer()
                            Button("Opciones…") { sheet = model.defaultOptions(for: folder) ?? missingKeys() }
                        }
                        Text("Un segundo build reutiliza lo que no ha cambiado en \(folder.baseTitleID.map { "\($0)_build" } ?? "_build"): tarda una fracción del primero.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let error { Text(error).foregroundStyle(.red).font(.callout) }
                    }
                    .padding(6)
                }

                if !folder.outputs.isEmpty {
                    GroupBox("Salidas") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(folder.outputs, id: \.self) { url in
                                HStack {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                                    Text(url.lastPathComponent)
                                    Spacer()
                                    if url.pathExtension == "app", let g = MacGameBundle(url: url) {
                                        Button("Jugar") { model.runner.launch(g) }
                                    }
                                    Button("Mostrar") { Finder.reveal(url) }
                                }
                            }
                        }
                        .padding(6)
                    }
                }

                if let build = folder.buildDirectory, FileManager.default.fileExists(atPath: build.path) {
                    GroupBox("Carpeta de build") {
                        HStack {
                            Button("Abrir logs") { Finder.open(build.appendingPathComponent("logs")) }
                            Button("Mostrar build") { Finder.reveal(build) }
                            if canBench {
                                Button("Benchmark en este Mac") {
                                    error = model.startBenchmark(folder)
                                    if error == nil { onBuild() }
                                }
                                .help("scripts/bench.py: la ruta fija del perfil, percentiles de tiempo de fotograma y GPU.")
                            }
                            Spacer()
                        }
                        .padding(6)
                    }
                }

                GroupBox("Archivos") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(folder.files, id: \.url) { f in
                            HStack {
                                Text(kind(f)).font(.caption).frame(width: 90, alignment: .leading).foregroundStyle(.secondary)
                                Text(f.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(f.size.bytes).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(6)
                }
            }
            .padding(20)
        }
        .sheet(item: $sheet) { opts in
            BuildSheet(folder: folder, options: opts) { final in
                sheet = nil
                error = model.startBuild(final, title: "\(final.platform.label) · \(entry?.name ?? folder.name)")
                if error == nil { onBuild() }
            } cancel: { sheet = nil }
        }
    }

    private var entry: CompatibilityEntry? {
        folder.baseTitleID.flatMap { id in model.compatibility.first { $0.titleID == id } }
    }

    private var canBench: Bool {
        guard let id = folder.baseTitleID, let build = folder.buildDirectory else { return false }
        return model.repository.hasBenchRoute(id)
            && FileManager.default.fileExists(atPath: build.appendingPathComponent("tools/dmhost").path)
    }

    @ViewBuilder private var explanation: some View {
        switch model.profileState(folder) {
        case .registered:
            EmptyView()
        case .unknown:
            Text("nxnative no tiene perfil para este title ID. El script hará una encuesta (`_survey/survey.md`) y un perfil provisional adivinado de los archivos; la app resultante puede no arrancar. Si es una edición regional de un build conocido, el script lo detecta solo.")
                .font(.callout).padding(10)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        case .noTitleID:
            Text("Ningún archivo lleva [title ID] en el nombre. El script puede leerlo del ticket del NSP; aquí solo no se puede agrupar.")
                .font(.callout).padding(10)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func kind(_ f: GameFile) -> String {
        let v = f.version.map { " v\($0)" } ?? ""
        switch f.titleID?.kind {
        case .base: return "Base" + v
        case .update: return "Actualización" + v
        case .addOn: return "DLC"
        case nil: return "?"
        }
    }

    private func quick(_ p: BuildOptions.Platform) {
        guard var o = model.defaultOptions(for: folder) else { error = "Falta prod.keys: elígelo en Entorno."; return }
        o.platform = p
        error = model.startBuild(o, title: "\(p.label) · \(entry?.name ?? folder.name)")
        if error == nil { onBuild() }
    }

    private func missingKeys() -> BuildOptions? {
        error = "Falta prod.keys: elígelo en Entorno."
        return nil
    }
}

extension BuildOptions.Platform {
    var label: String {
        switch self {
        case .macApp: "App de Mac"
        case .mac: "Build de desarrollo"
        case .ios: "IPA"
        }
    }
}

struct BuildSheet: View {
    @Environment(AppModel.self) private var model
    let folder: NSPFolder
    @State var options: BuildOptions
    var start: (BuildOptions) -> Void
    var cancel: () -> Void
    @State private var identities: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Construir \(folder.name)").font(.title3.weight(.semibold)).padding()
            Form {
                Section("Destino") {
                    Picker("Plataforma", selection: $options.platform) {
                        ForEach(BuildOptions.Platform.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Versión", selection: $options.package) {
                        Text("La más nueva de la carpeta").tag("")
                        ForEach(folder.packages, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Idioma del juego", selection: $options.language) {
                        ForEach(BuildOptions.languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    TextField("Nombre de la app", text: $options.appName, prompt: Text("el del juego"))
                    LabeledContent("Salida") {
                        HStack {
                            Text(options.output?.path ?? "junto a los NSP").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button("Cambiar…") { chooseOutput() }
                            if options.output != nil { Button("Por defecto") { options.output = nil } }
                        }
                    }
                }
                if options.platform == .macApp {
                    Section("Firma") {
                        Picker("Identidad", selection: $options.macSign) {
                            Text("Ad hoc").tag("")
                            ForEach(identities, id: \.self) { Text($0).tag($0) }
                        }
                        Text("Sin hardened runtime (el host necesita memoria ejecutable), así que la app no se notariza: en otro Mac, Gatekeeper la bloquea hasta permitirla en Privacidad y seguridad.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Rendimiento") {
                    TextField("Arquitecturas GPU (--gpu)", text: $options.gpu,
                              prompt: Text(options.platform == .ios ? "g18p por defecto si el perfil usa pso_mtl4" : "la de este Mac (\(model.toolchain.gpuArchitecture))"))
                    if options.platform == .ios { Toggle("Contador de fps en pantalla", isOn: $options.showFPS) }
                    Toggle("Conservar los archivos extraídos", isOn: $options.keepExtracted)
                        .help("Acelera el siguiente build y permite correr el juego en el Mac. Un build de Mac los conserva siempre.")
                }
                Section("Cuando algo no cuadra") {
                    Toggle("Aceptar NSP dañados (--allow-damaged)", isOn: $options.allowDamaged)
                    Toggle("Empaquetar aunque haya regresiones de shaders", isOn: $options.allowShaderRegressions)
                    Toggle("Permitir otro compilador de Metal", isOn: $options.allowOtherMetal)
                    Toggle("Forzar perfil provisional (probar las conjeturas)", isOn: $options.provisional)
                    Toggle("Solo la encuesta (juego sin perfil)", isOn: $options.surveyOnly)
                    LabeledContent("Interruptores horneados (--env-file)") {
                        HStack {
                            Text(options.envFile?.lastPathComponent ?? "ninguno").foregroundStyle(.secondary)
                            Button("Elegir…") { options.envFile = Finder.chooseFile() }
                            if options.envFile != nil { Button("Quitar") { options.envFile = nil } }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Construir") { start(options) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 600, height: 640)
        .task { identities = await Toolchain.signingIdentities() }
    }

    private func chooseOutput() {
        let p = NSSavePanel()
        p.nameFieldStringValue = options.platform == .ios ? "\(folder.name).ipa" : "\(folder.name).app"
        if p.runModal() == .OK { options.output = p.url }
    }
}
