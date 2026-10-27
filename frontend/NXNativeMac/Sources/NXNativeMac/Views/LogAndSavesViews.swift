import NXCore
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
    @State private var backups: [URL] = []
    @State private var message: String?
    @State private var pendingRestore: URL?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Partida guardada").font(.headline)
                    Text(game.saveDirectory.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("Mostrar") { Finder.open(game.saveDirectory) }
                Button("Hacer copia ahora") {
                    Task {
                        busy = true
                        defer { busy = false }
                        do {
                            let url = try await SaveBackups.backup(game)
                            message = "Copia creada: \(url.lastPathComponent)"
                        } catch { message = error.localizedDescription }
                        reload()
                    }
                }
                .disabled(busy || model.runner.isRunning(game))
            }
            if model.runner.isRunning(game) {
                Text("El juego está en marcha: deténlo antes de copiar o restaurar, o la copia puede quedar a medias.")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let message { Text(message).font(.callout) }

            List {
                Section("Copias (\(SaveBackups.directory(for: game).path))") {
                    if backups.isEmpty { Text("Ninguna todavía.").foregroundStyle(.secondary) }
                    ForEach(backups, id: \.self) { url in
                        HStack {
                            Image(systemName: "archivebox")
                            Text(url.lastPathComponent).monospaced()
                            Spacer()
                            Button("Mostrar") { Finder.reveal(url) }
                            Button("Restaurar…") { pendingRestore = url }
                                .disabled(busy || model.runner.isRunning(game))
                        }
                    }
                }
            }
        }
        .padding()
        .onAppear(perform: reload)
        .confirmationDialog("¿Restaurar \(pendingRestore?.lastPathComponent ?? "")?",
                            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })) {
            Button("Restaurar", role: .destructive) {
                guard let url = pendingRestore else { return }
                Task {
                    busy = true
                    defer { busy = false }
                    do {
                        try await SaveBackups.restore(url, into: game)
                        message = "Restaurada. La partida anterior quedó copiada y en la Papelera."
                    } catch { message = error.localizedDescription }
                    reload()
                }
            }
        } message: {
            Text("Antes se hace una copia de la partida actual, y la carpeta vieja va a la Papelera.")
        }
    }

    private func reload() { backups = SaveBackups.list(for: game) }
}
