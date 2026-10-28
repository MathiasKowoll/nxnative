import GameController
import NXCore
import SwiftUI

struct EnvironmentView: View {
    @Environment(AppModel.self) private var model
    /// En la ventana de Ajustes solo van las rutas.
    var compact: Bool
    @State private var identities: [String] = []
    @State private var controllers: [String] = []

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            if !compact {
                Section {
                    ForEach(model.toolchain.checks) { c in
                        HStack(alignment: .firstTextBaseline) {
                            icon(c.status).frame(width: 18)
                            Text(c.title).frame(width: 150, alignment: .leading)
                            Text(c.detail).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    if model.toolchain.metalToolchainMissing {
                        HStack {
                            Spacer()
                            if model.downloadingMetal { ProgressView().controlSize(.small) }
                            Button("Descargar Metal Toolchain") { Task { await model.downloadMetalToolchain() } }
                                .disabled(model.downloadingMetal)
                        }
                    }
                } header: {
                    HStack {
                        Text("Comprobaciones")
                        Spacer()
                        Button("Repetir") { Task { await model.toolchain.refresh(model.prefs) } }
                            .disabled(model.toolchain.running)
                    }
                }
            }

            Section("nxnative") {
                PathRow(label: "Checkout", path: $prefs.repositoryPath, directory: true)
                HStack {
                    if model.repository.isValid {
                        Button("Actualizar (git pull --ff-only)") { Task { await model.updateRepository() } }
                    } else {
                        Button("Clonar \(AppModel.upstream)") { Task { await model.cloneRepository() } }
                    }
                    Button("Abrir en Finder") { Finder.open(model.prefs.repositoryURL) }
                        .disabled(!model.repository.isValid)
                }
                if let n = model.notice { Text(n).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Entorno de Python de la app")
                        Spacer()
                        if model.settingUpPython { ProgressView().controlSize(.small) }
                        Button("Preparar Python") { Task { await model.setUpPython(includeOptional: false) } }
                            .disabled(model.settingUpPython)
                        if model.toolchain.nszMissing {
                            Button("Añadir nsz") { Task { await model.setUpPython(includeOptional: true) } }
                                .disabled(model.settingUpPython)
                        }
                    }
                    Text("El Python de Homebrew no deja instalar paquetes con pip. La app crea uno propio en \(PythonEnv.directory.path) con lz4, capstone y fonttools, y lo usa para los builds.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(model.pythonLog.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                            .foregroundStyle(BuildEventParser.isError(line) ? .red : .secondary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Python")
            }

            Section {
                PathRow(label: "prod.keys", path: $prefs.keysPath, directory: false)
                PathRow(label: "python3", path: $prefs.pythonPath, directory: false, placeholder: "automático: el entorno de la app, si no uno >= 3.12")
            } header: {
                Text("Claves y herramientas")
            } footer: {
                Text("Las claves salen de TU consola. La app guarda la ruta y solo lee header_key, para descifrar la cabecera del NCA de metadatos e identificar archivos sin etiqueta; nunca muestra los valores. Al script se lo pasa con -k.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                FolderList(paths: $prefs.gameRoots)
            } header: {
                Text("Carpetas de juegos")
            } footer: {
                Text("Cada una contiene carpetas NSP, una por juego. El script escribe ahí <title ID>_build/ (puede ocupar decenas de GB): mejor un disco externo que la carpeta de inicio.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Dónde buscar apps de juego") {
                FolderList(paths: $prefs.appRoots)
            }

            Section {
                Toggle("Pantalla completa al arrancar", isOn: $prefs.globalFullscreen)
                Picker("Filtro de escalado", selection: $prefs.globalFilter) {
                    Text("El de cada juego").tag("")
                    ForEach(GlobalDefaults.filters, id: \.value) { Text($0.label).tag($0.value) }
                }
                Toggle("Nitidez para todos", isOn: Binding(get: { model.prefs.globalSharpen >= 0 },
                                                           set: { model.prefs.globalSharpen = $0 ? 0.5 : -1 }))
                if model.prefs.globalSharpen >= 0 {
                    LabeledContent("Cantidad") {
                        HStack {
                            Slider(value: Binding(get: { max(0, model.prefs.globalSharpen) },
                                                  set: { model.prefs.globalSharpen = (($0 * 20).rounded() / 20) }), in: 0...1)
                            Text("\(Int((max(0, model.prefs.globalSharpen) * 100).rounded())) %").monospacedDigit().frame(width: 48, alignment: .trailing)
                        }
                    }
                }
            } header: {
                Text("Todos los juegos")
            } footer: {
                Text("Se aplican al jugar desde esta app. Un juego con su propia elección en Ajustes se queda con la suya. El filtro y la nitidez necesitan el juego construido con esta versión de nxnative; la pantalla completa vale ya. Bicúbico con nitidez 50 % es la combinación que más se acercó a la imagen real en las pruebas.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                PathRow(label: "Copias de partidas", path: $prefs.backupsPath, directory: true,
                        placeholder: SaveVault.defaultRoot.path)
                Toggle("Copia automática al jugar y al reconstruir", isOn: $prefs.autoBackup)
            } header: {
                Text("Partidas")
            } footer: {
                Text("Una carpeta en iCloud Drive o en otro disco hace que las copias sobrevivan a un desinstalador que limpie Application Support o a un cambio de Mac. Las copias que ya existan no se mueven solas.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Firma de las apps de Mac") {
                Picker("Identidad por defecto", selection: $prefs.macSignIdentity) {
                    Text("Ad hoc").tag("")
                    ForEach(identities, id: \.self) { Text($0).tag($0) }
                }
            }

            if !compact {
                Section("Mandos que ve macOS") {
                    if controllers.isEmpty {
                        Text("Ninguno conectado.").foregroundStyle(.secondary)
                    }
                    ForEach(controllers, id: \.self) { Label($0, systemImage: "gamecontroller") }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Entorno")
        .task {
            identities = await Toolchain.signingIdentities()
            refreshControllers()
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in refreshControllers() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in refreshControllers() }
        .onChange(of: model.prefs.gameRoots) { Task { await model.refresh() } }
        .onChange(of: model.prefs.appRoots) { Task { await model.refresh() } }
        .onChange(of: model.prefs.repositoryPath) { Task { await model.refresh() } }
        .onChange(of: model.prefs.keysPath) { Task { await model.toolchain.refresh(model.prefs) } }
        .onChange(of: model.prefs.pythonPath) { Task { await model.toolchain.refresh(model.prefs) } }
    }

    private func refreshControllers() {
        controllers = GCController.controllers().map { c in
            let kind = c.extendedGamepad != nil ? "completo" : "básico"
            let haptics = c.haptics != nil ? ", vibración" : ""
            return "\(c.vendorName ?? "Mando") (\(c.productCategory), \(kind)\(haptics))"
        }
    }

    @ViewBuilder private func icon(_ s: Check.Status) -> some View {
        switch s {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failure: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .info: Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
    }
}

struct PathRow: View {
    let label: String
    @Binding var path: String
    let directory: Bool
    var placeholder = ""

    var body: some View {
        LabeledContent(label) {
            HStack {
                TextField("", text: $path, prompt: Text(placeholder))
                    .textFieldStyle(.roundedBorder)
                Button("Elegir…") {
                    if let url = directory ? Finder.chooseFolder() : Finder.chooseFile() { path = url.path }
                }
            }
        }
    }
}

struct FolderList: View {
    @Binding var paths: [String]

    var body: some View {
        ForEach(paths, id: \.self) { p in
            HStack {
                Image(systemName: FileManager.default.fileExists(atPath: (p as NSString).expandingTildeInPath)
                      ? "folder" : "folder.badge.questionmark")
                Text(p).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { paths.removeAll { $0 == p } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
        }
        Button("Añadir carpeta…") {
            if let url = Finder.chooseFolder(prompt: "Añadir"), !paths.contains(url.path) { paths.append(url.path) }
        }
    }
}
