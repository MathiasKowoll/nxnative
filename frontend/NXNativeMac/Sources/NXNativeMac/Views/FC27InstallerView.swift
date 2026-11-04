import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Instalador de un solo paso para una copia legítima que el usuario ya tiene.
/// El juego y prod.keys se eligen desde Finder; ninguno se empaqueta en esta
/// aplicación ni se copia al resultado. El title ID decide automáticamente si
/// el builder debe ejecutar FC26 o FC27.
struct FC27InstallerView: View {
    @Environment(AppModel.self) private var model
    var onBuild: () -> Void

    @State private var gameFolder: URL?
    @State private var keysURL: URL?
    @State private var outputURL: URL?
    @State private var detectedTarget: AppModel.FCInstallTarget?
    @State private var outputWasChosen = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                steps

                GroupBox("Origen del juego") {
                    VStack(alignment: .leading, spacing: 10) {
                        PathChoiceRow(
                            title: "Carpeta con tu juego",
                            detail: "Debe contener el NSP/NSZ/XCI/XCZ base y, si corresponde, la actualización y DLC.",
                            url: gameFolder,
                            symbol: "folder",
                            choose: chooseGameFolder,
                            clear: { gameFolder = nil }
                        )
                    }
                    .padding(8)
                }

                GroupBox("Claves del usuario") {
                    VStack(alignment: .leading, spacing: 10) {
                        PathChoiceRow(
                            title: "prod.keys",
                            detail: "Solo se pasa su ruta al proceso. La app no muestra ni copia sus valores.",
                            url: keysURL,
                            symbol: "key",
                            choose: chooseKeys,
                            clear: { keysURL = nil }
                        )
                    }
                    .padding(8)
                }

                GroupBox("Resultado") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "app.fill").foregroundStyle(Color.accentColor)
                            Text((outputURL ?? defaultOutputURL).path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer()
                            Button("Cambiar…", action: chooseOutput)
                        }
                        Text("El builder detecta FC26/FC27 por su title ID y genera una app autocontenida con runtime, juego, módulos, shaders y launcher específico. Usa firma ad hoc por defecto; puedes seleccionar una identidad Developer ID instalada en Entorno. La carpeta original no se modifica.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                HStack {
                    Button {
                        start()
                    } label: {
                        Label("Generar \(detectedTarget?.title ?? "EA Sports FC 26/27").app", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canStart || model.builds.active != nil)

                    if model.builds.active != nil {
                        ProgressView()
                            .controlSize(.small)
                        Text("Hay una construcción en curso…")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if let notice = model.notice {
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(28)
        }
        .navigationTitle("Instalar FC26/FC27")
        .toolbar {
            Button("Abrir construcciones") { onBuild() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Instalador de EA Sports FC26/FC27", systemImage: "shippingbox.fill")
                .font(.largeTitle.weight(.semibold))
            Text("Elige tu propia copia del juego y tus propias claves. El title ID identifica automáticamente FC26 o FC27; después un solo clic ejecuta el pipeline y deja la app lista para abrir.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var steps: some View {
        HStack(alignment: .top, spacing: 14) {
            InstallerStep(number: "1", title: "Selecciona", detail: "Juego y prod.keys")
            InstallerStep(number: "2", title: "Procesa", detail: "Extracción, parches y shaders")
            InstallerStep(number: "3", title: "Obtén", detail: detectedTarget?.title ?? "EA Sports FC26/FC27.app")
        }
    }

    private var canStart: Bool {
        guard let gameFolder, let keysURL else { return false }
        var isDirectory: ObjCBool = false
        let fm = FileManager.default
        return fm.fileExists(atPath: gameFolder.path, isDirectory: &isDirectory) && isDirectory.boolValue
            && fm.isReadableFile(atPath: keysURL.path)
    }

    private func chooseGameFolder() {
        if let url = Finder.chooseFolder(prompt: "Usar carpeta del juego") {
            gameFolder = url
            detectTarget()
            error = nil
        }
    }

    private func chooseKeys() {
        if let url = Finder.chooseFile(prompt: "Usar prod.keys") {
            keysURL = url
            detectTarget()
            error = nil
        }
    }

    private func chooseOutput() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(detectedTarget?.title ?? "EA Sports FC 27").app"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.applicationBundle]
        if panel.runModal() == .OK, let url = panel.url {
            outputURL = url.pathExtension == "app" ? url : url.appendingPathExtension("app")
            outputWasChosen = true
            error = nil
        }
    }

    private func start() {
        guard let gameFolder, let keysURL else { return }
        error = model.startOneStepMacApp(gameFolder: gameFolder, keys: keysURL, output: outputURL ?? defaultOutputURL,
                                         appName: detectedTarget?.title ?? "EA Sports FC 27")
        if error == nil { onBuild() }
    }

    private func detectTarget() {
        guard let gameFolder, let keysURL else { return }
        let target = model.detectFCInstallTarget(gameFolder: gameFolder, keys: keysURL)
        detectedTarget = target
        guard !outputWasChosen, target != nil else { return }
        outputURL = nil
    }

    private var defaultOutputURL: URL {
        model.prefs.gameAppsURL.appendingPathComponent(
            "\(detectedTarget?.title ?? "EA Sports FC 27").app", isDirectory: true)
    }
}

private struct InstallerStep: View {
    let number: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(Color.accentColor, in: Circle())
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PathChoiceRow: View {
    let title: String
    let detail: String
    let url: URL?
    let symbol: String
    let choose: () -> Void
    let clear: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 24)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(url?.path ?? detail)
                    .font(url == nil ? .callout : .caption)
                    .foregroundStyle(url == nil ? .secondary : .primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            if url != nil {
                Button("Quitar", action: clear)
            }
            Button(url == nil ? "Elegir…" : "Cambiar…", action: choose)
        }
    }
}
