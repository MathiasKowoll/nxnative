import NXCore
import SwiftUI

/// Los juegos en disco, agrupados por title ID aunque estén todos en una
/// carpeta y sus DLC en otras. nxnative exige una carpeta por juego: cuando el
/// juego no la tiene, la app prepara una con enlaces (`PreparedFolder`).
struct DiskGamesView: View {
    @Environment(AppModel.self) private var model
    var onBuild: () -> Void
    @State private var selection: TitleID?
    @State private var showUnidentified = false

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                Section("Juegos (\(model.library.count))") {
                    ForEach(model.library) { GameRow(game: $0).tag($0.id) }
                }
                if !model.unidentified.isEmpty {
                    Section("Sin title ID (\(model.unidentified.count))") {
                        ForEach(model.unidentified) { f in
                            Label(f.url.lastPathComponent, systemImage: "questionmark.square.dashed")
                                .lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.secondary)
                                .onTapGesture { showUnidentified = true }
                        }
                    }
                }
            }
            .frame(minWidth: 280, idealWidth: 320)
            .overlay {
                if model.library.isEmpty && model.unidentified.isEmpty {
                    ContentUnavailableView {
                        Label("Sin juegos", systemImage: "externaldrive.badge.questionmark")
                    } description: {
                        Text("Añade en Entorno la carpeta donde guardas tus volcados (.nsp, .xci, .nsz, .xcz). Puede ser una carpeta por juego o todos juntos.")
                    }
                }
            }

            Group {
                if let g = model.library.first(where: { $0.id == selection }) {
                    GameOnDiskView(game: g, onBuild: onBuild)
                } else if showUnidentified {
                    UnidentifiedView()
                } else {
                    Text("Elige un juego").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selection) { if selection != nil { showUnidentified = false } }
        .navigationTitle("Juegos en disco")
        .toolbar {
            if !model.unidentified.isEmpty {
                Button { selection = nil; showUnidentified = true } label: {
                    Label("Sin identificar", systemImage: "questionmark.square.dashed")
                }
            }
            Button { Task { await model.refresh() } } label: { Label("Escanear", systemImage: "arrow.clockwise") }
        }
    }
}

struct GameRow: View {
    @Environment(AppModel.self) private var model
    let game: GameEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.name(for: game)).lineLimit(1)
            HStack(spacing: 6) {
                ProfileBadge(state: model.profileState(game))
                Text(summary)
                if !game.warnings.isEmpty { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        var p: [String] = []
        if game.baseFiles.contains(where: \.isCartridge) { p.append("XCI") }
        if !game.updates.isEmpty { p.append("\(game.updates.count) act.") }
        if !game.addOns.isEmpty { p.append("\(game.addOns.count) DLC") }
        p.append(game.totalSize.bytes)
        return p.joined(separator: " · ")
    }
}

struct ProfileBadge: View {
    let state: AppModel.ProfileState
    var body: some View {
        switch state {
        case .registered: Label("Con perfil", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .unknown: Label("Sin perfil", systemImage: "questionmark.diamond").foregroundStyle(.orange)
        }
    }
}

struct GameOnDiskView: View {
    @Environment(AppModel.self) private var model
    let game: GameEntry
    var onBuild: () -> Void
    @State private var sheet: BuildOptions?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name(for: game)).font(.title2.weight(.semibold))
                    HStack {
                        ProfileBadge(state: model.profileState(game))
                        Text(game.base.description).monospaced().textSelection(.enabled)
                        if let e = model.compat(for: game.base) { Text("· \(e.engine) · \(e.graphics)") }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }

                if model.profileState(game) == .unknown {
                    note("nxnative no tiene perfil para este title ID. El script hará una encuesta y un perfil provisional adivinado; la app resultante puede no arrancar. Si es una edición regional de un build conocido, el script lo detecta solo.", .orange)
                }
                ForEach(game.warnings, id: \.self) { note($0, .orange) }

                GroupBox("Carpeta para nxnative") { folderBox.padding(6) }

                GroupBox("Construir") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button { quick(.macApp) } label: { Label("App de Mac", systemImage: "macbook") }
                                .buttonStyle(.borderedProminent)
                            Button { quick(.ios) } label: { Label("IPA", systemImage: "iphone") }
                            Button { quick(.mac) } label: { Label("Desarrollo", systemImage: "wrench.and.screwdriver") }
                                .help("--platform mac: solo lo que hace falta para correr en este Mac.")
                            Spacer()
                            Button("Opciones…") { withOptions { sheet = $0 } }
                        }
                        .disabled(!game.hasBase)
                        if let error { Text(error).foregroundStyle(.red).font(.callout) }
                    }
                    .padding(6)
                }

                let outs = model.outputs(for: game)
                if !outs.isEmpty {
                    GroupBox("Salidas") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(outs, id: \.self) { url in
                                HStack {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                                    Text(url.lastPathComponent)
                                    Spacer()
                                    if url.pathExtension == "app", let g = MacGameBundle(url: url) {
                                        Button("Jugar") { model.play(g) }
                                    }
                                    Button("Mostrar") { Finder.reveal(url) }
                                }
                            }
                        }
                        .padding(6)
                    }
                }

                if let build = model.buildDirectory(for: game), FileManager.default.fileExists(atPath: build.path) {
                    GroupBox("Carpeta de build") {
                        HStack {
                            Button("Abrir logs") { Finder.open(build.appendingPathComponent("logs")) }
                            Button("Mostrar build") { Finder.reveal(build) }
                            if model.repository.hasBenchRoute(game.base),
                               FileManager.default.fileExists(atPath: build.appendingPathComponent("tools/dmhost").path) {
                                Button("Benchmark en este Mac") {
                                    error = model.startBenchmark(game)
                                    if error == nil { onBuild() }
                                }
                            }
                            Spacer()
                        }
                        .padding(6)
                    }
                }

                GroupBox("Archivos") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(game.files) { f in
                            HStack {
                                Text(kind(f)).font(.caption).frame(width: 110, alignment: .leading).foregroundStyle(.secondary)
                                Text(f.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    .help(f.url.path)
                                Spacer()
                                Text(source(f)).font(.caption2).foregroundStyle(.tertiary)
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
            BuildSheet(packages: game.packages, title: model.name(for: game), options: opts) { final in
                sheet = nil
                error = model.startBuild(final, game: game)
                if error == nil { onBuild() }
            } cancel: { sheet = nil }
        }
    }

    @ViewBuilder private var folderBox: some View {
        if let own = game.ownFolder {
            HStack {
                Label("Tiene su propia carpeta", systemImage: "checkmark.circle").foregroundStyle(.green)
                Text(own.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Mostrar") { Finder.open(own) }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sus archivos comparten carpeta con otros juegos o están repartidos. nxnative necesita uno por carpeta, así que la app crea una con ENLACES a estos archivos: no se mueve ni se renombra nada, y no ocupa espacio. Se pone al día antes de cada build.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    if let dir = model.prepared[game.base] {
                        Label("Preparada", systemImage: "link").foregroundStyle(.green)
                        Text(dir.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Mostrar") { Finder.open(dir) }
                    } else {
                        Spacer()
                    }
                    Button(model.prepared[game.base] == nil ? "Preparar carpeta" : "Actualizar enlaces") {
                        do { _ = try model.prepare(game); error = nil } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }

    private func note(_ text: String, _ color: Color) -> some View {
        Text(text).font(.callout).padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func kind(_ f: GameFile) -> String {
        let v = f.version.map { " v\($0)" } ?? ""
        let cart = f.isCartridge ? " (XCI)" : ""
        switch f.titleID?.kind {
        case .base: return "Base" + cart + v
        case .update: return "Actualización" + v
        case .addOn: return "DLC"
        case nil: return "?"
        }
    }

    private func source(_ f: GameFile) -> String {
        switch f.source {
        case .ticket: "ticket"
        case .fileName: "nombre"
        case .keyset: "claves"
        case .assigned: "asignado"
        case nil: ""
        }
    }

    private func withOptions(_ then: (BuildOptions) -> Void) {
        switch model.defaultOptions(for: game) {
        case let .success(o): error = nil; then(o)
        case let .failure(e): error = e.localizedDescription
        }
    }

    private func quick(_ p: BuildOptions.Platform) {
        withOptions { o in
            var o = o
            o.platform = p
            error = model.startBuild(o, game: game)
            if error == nil { onBuild() }
        }
    }
}

/// Archivos sin title ID legible: sin etiqueta en el nombre, sin ticket (los
/// pocos NSP que no lo traen) y con el NCA de metadatos que no descifra el
/// `prod.keys` configurado. Aquí se asigna a mano, con una sugerencia por
/// nombre desde la tabla de compatibilidad.
struct UnidentifiedView: View {
    @Environment(AppModel.self) private var model
    @State private var typed: [URL: String] = [:]

    var body: some View {
        Form {
            Section {
                Text("Con el prod.keys configurado en Entorno la app identifica sola estos archivos descifrando la cabecera de su NCA de metadatos; sin claves solo se sabe por el nombre o el ticket. Los que quedan aquí se asignan a mano: la app no renombra el archivo, lo pone en el nombre del enlace que ve nxnative. Si te equivocas, el script lo detecta al comparar los build IDs con el perfil.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.unidentified) { f in
                Section(f.url.lastPathComponent) {
                    if let s = GameLibrary.suggest(for: f, in: model.compatibility) {
                        HStack {
                            Text("¿Es \(s.name)? (\(s.titleID.description))")
                            Spacer()
                            Button("Usar") { Task { await model.assign(s.titleID, to: f) } }
                        }
                    }
                    HStack {
                        TextField("Title ID (16 dígitos hex)", text: Binding(get: { typed[f.url] ?? "" }, set: { typed[f.url] = $0 }))
                            .monospaced()
                        Button("Asignar") {
                            if let t = TitleID(typed[f.url] ?? "") { Task { await model.assign(t.base, to: f) } }
                        }
                        .disabled(TitleID(typed[f.url] ?? "") == nil)
                    }
                    if let x = f.xci {
                        Text("Cartucho: \(x.partitions.joined(separator: ", ")) · \(x.contentMetaCount) contenido(s) en secure")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(f.url.path).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
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
    let packages: [String]
    let title: String
    @State var options: BuildOptions
    var start: (BuildOptions) -> Void
    var cancel: () -> Void
    @State private var identities: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Construir \(title)").font(.title3.weight(.semibold)).padding()
            Form {
                Section("Destino") {
                    Picker("Plataforma", selection: $options.platform) {
                        ForEach(BuildOptions.Platform.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Versión", selection: $options.package) {
                        Text("La más nueva de la carpeta").tag("")
                        ForEach(packages, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Idioma del juego", selection: $options.language) {
                        ForEach(BuildOptions.languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    TextField("Nombre de la app", text: $options.appName, prompt: Text("el del juego"))
                    LabeledContent("Salida") {
                        HStack {
                            Text(options.output?.path ?? "en la carpeta del juego").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
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
                    Toggle("Aceptar archivos dañados (--allow-damaged)", isOn: $options.allowDamaged)
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
        p.nameFieldStringValue = options.platform == .ios ? "\(title).ipa" : "\(title).app"
        if p.runModal() == .OK { options.output = p.url }
    }
}
