import NXCore
import UniformTypeIdentifiers
import SwiftUI

struct LogView: View {
    let tail: LogTail
    let game: MacGameBundle
    @State private var onlyRed = false
    @State private var follow = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Solo [RED]", isOn: $onlyRed)
                Toggle("Seguir", isOn: $follow)
                Spacer()
                if tail.redCount > 0 {
                    Label("\(tail.redCount) líneas [RED]", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.callout)
                }
                Button("Copiar") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(visible.map(\.text).joined(separator: "\n"), forType: .string)
                }
                Button("Abrir en Consola") { Finder.open(game.log) }
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal).padding(.bottom, 8)

            if !tail.exists {
                ContentUnavailableView("Sin log todavía", systemImage: "doc.text",
                                       description: Text("Aparece en \(game.log.path) cuando el juego arranca."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(visible) { line in
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(line.isRed ? Color.red : Color.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }
                        .padding(8)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: tail.lines.last?.id) { _, last in
                        if follow, let last = visible.last?.id ?? last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            Text("El log es diagnóstico para personas, no una interfaz: su redacción puede cambiar entre versiones de nxnative.")
                .font(.caption2).foregroundStyle(.tertiary).padding(6)
        }
    }

    private var visible: [LogTail.Line] { onlyRed ? tail.lines.filter(\.isRed) : tail.lines }
}

struct SavesView: View {
    @Environment(AppModel.self) private var model
    let game: MacGameBundle
    @State private var backups: [SaveVault.Entry] = []
    @State private var message: String?
    @State private var pendingRestore: URL?
    @State private var confirmDelete = false
    @State private var busy = false

    var body: some View {
        @Bindable var prefs = model.prefs
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.activeProfile.isMain ? "Partida guardada" : "Partida guardada · \(model.activeProfile.name)").font(.headline)
                    Text(model.saveDirectory(for: game).path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Está fuera de la app: reinstalar o reconstruir el juego no la borra. Un desinstalador que limpie Application Support sí, y por eso están las copias.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Mostrar") { Finder.open(model.saveDirectory(for: game)) }
            }

            HStack {
                Button("Hacer copia ahora") { run { try await model.backup(game, kind: .manual).map { "Copia creada: \($0.lastPathComponent)" } ?? "Este juego aún no tiene partida guardada." } }
                Button("Exportar…") { exportCurrent() }
                    .help("Guarda la partida actual en un zip donde quieras: iCloud Drive, otro disco, otro Mac.")
                Button("Importar…") { importArchive() }
                    .help("Restaura la partida desde un zip exportado. Antes se copia la actual.")
                Button("Borrar partida…", role: .destructive) { confirmDelete = true }
                    .help("Empieza de cero. Antes se hace una copia, y la carpeta va a la Papelera.")
                Spacer()
                Toggle("Copia automática al jugar y al reconstruir", isOn: $prefs.autoBackup)
                    .toggleStyle(.checkbox)
            }
            .disabled(busy || model.runner.isRunning(game))

            if model.runner.isRunning(game) {
                Text("El juego está en marcha: deténlo antes de copiar o restaurar, o la copia puede quedar a medias.")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let message { Text(message).font(.callout).textSelection(.enabled) }

            List {
                Section {
                    if backups.isEmpty { Text("Ninguna todavía.").foregroundStyle(.secondary) }
                    ForEach(backups) { e in
                        HStack {
                            Image(systemName: icon(e.kind)).foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(e.date.formatted(date: .abbreviated, time: .standard))
                                Text(label(e.kind)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Exportar…") { exportCopy(e.url) }
                            Button("Mostrar") { Finder.reveal(e.url) }
                            Button("Restaurar…") { pendingRestore = e.url }
                                .disabled(busy || model.runner.isRunning(game))
                        }
                    }
                } header: {
                    Text("Copias · \(model.vault.directory(for: game.titleID).path)")
                } footer: {
                    Text("Se guardan las \(model.vault.keepAuto) copias automáticas más nuevas; las manuales y las de antes de restaurar o de borrar no se borran nunca. La carpeta se cambia en Entorno.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .onAppear(perform: reload)
        .onChange(of: model.activeProfile.id) { message = nil; reload() }
        .confirmationDialog("¿Borrar la partida de \(game.name)?", isPresented: $confirmDelete) {
            Button("Borrar partida", role: .destructive) {
                run {
                    try await model.deleteSave(game)
                    return "Partida borrada. Quedó una copia («antes de borrar») y la carpeta está en la Papelera."
                }
            }
        } message: {
            Text(model.activeProfile.isMain
                 ? "El juego empezará de cero. Antes se hace una copia que puedes restaurar desde esta lista."
                 : "Solo la de \(model.activeProfile.name): las de los demás perfiles no se tocan. Antes se hace una copia que puedes restaurar desde esta lista.")
        }
        .confirmationDialog("¿Restaurar esta copia?",
                            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })) {
            Button("Restaurar", role: .destructive) {
                guard let url = pendingRestore else { return }
                restore(url)
            }
        } message: {
            Text("Antes se hace una copia de la partida actual, y la carpeta vieja va a la Papelera.")
        }
    }

    private func run(_ work: @escaping () async throws -> String) {
        Task {
            busy = true
            defer { busy = false }
            do { message = try await work() } catch { message = error.localizedDescription }
            reload()
        }
    }

    private func restore(_ url: URL) {
        run {
            try await model.vault.restore(url, saveDir: model.saveDirectory(for: game), titleID: game.titleID,
                                          game: game.name, version: game.version)
            return "Restaurada. La partida anterior quedó copiada («antes de restaurar») y en la Papelera."
        }
    }

    private var exportName: String {
        let d = Date().formatted(.iso8601.year().month().day())
        return "\(game.name) - partida \(d).zip".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
    }

    private func exportCurrent() {
        let p = NSSavePanel()
        p.nameFieldStringValue = exportName
        p.allowedContentTypes = [.zip]
        guard p.runModal() == .OK, let out = p.url else { return }
        run {
            try await model.vault.export(saveDir: model.saveDirectory(for: game), titleID: game.titleID,
                                         game: game.name, version: game.version, to: out)
            return "Exportada a \(out.path)"
        }
    }

    private func exportCopy(_ url: URL) {
        let p = NSSavePanel()
        p.nameFieldStringValue = exportName
        p.allowedContentTypes = [.zip]
        guard p.runModal() == .OK, let out = p.url else { return }
        run {
            if FileManager.default.fileExists(atPath: out.path) { try FileManager.default.removeItem(at: out) }
            try FileManager.default.copyItem(at: url, to: out)
            return "Copiada a \(out.path)"
        }
    }

    private func importArchive() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.zip]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return }
        pendingRestore = url
    }

    private func label(_ k: SaveVault.Kind) -> String {
        switch k {
        case .auto: "Automática"
        case .manual: "Manual"
        case .beforeRestore: "Antes de restaurar"
        case .beforeDelete: "Antes de borrar"
        }
    }

    private func icon(_ k: SaveVault.Kind) -> String {
        switch k {
        case .auto: "clock.arrow.circlepath"
        case .manual: "archivebox"
        case .beforeRestore: "arrow.uturn.backward"
        case .beforeDelete: "trash"
        }
    }

    private func reload() { backups = model.vault.list(game.titleID) }
}
