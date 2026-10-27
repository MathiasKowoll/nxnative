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
                PathRow(label: "prod.keys", path: $prefs.keysPath, directory: false)
                PathRow(label: "python3", path: $prefs.pythonPath, directory: false, placeholder: "automático (>= 3.12)")
            } header: {
                Text("Claves y herramientas")
            } footer: {
                Text("Las claves salen de TU consola. La app guarda solo la ruta y nunca abre el archivo: se lo pasa al script con -k.")
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
