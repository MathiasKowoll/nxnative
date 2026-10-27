import NXCore
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [MacGameBundle] = []

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 18)]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.games.isEmpty {
                    ContentUnavailableView {
                        Label("Sin juegos empaquetados", systemImage: "gamecontroller")
                    } description: {
                        Text("Las apps de Mac que crea nxnative (--platform mac-app) aparecen aquí. Construye una desde Carpetas NSP, o añade la carpeta donde las guardas en Entorno.")
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 22) {
                            ForEach(model.games) { game in
                                NavigationLink(value: game) { GameTile(game: game) }
                                    .buttonStyle(.plain)
                                    .contextMenu { tileMenu(game) }
                            }
                        }
                        .padding(22)
                    }
                }
            }
            .navigationTitle("Biblioteca")
            .navigationDestination(for: MacGameBundle.self) { GameDetailView(game: $0) }
            .toolbar {
                Button { Task { await model.refresh() } } label: { Label("Escanear", systemImage: "arrow.clockwise") }
            }
        }
    }

    @ViewBuilder private func tileMenu(_ game: MacGameBundle) -> some View {
        Button("Jugar") { model.runner.launch(game) }
        Button("Mostrar en Finder") { Finder.reveal(game.url) }
        Button("Abrir el log") { Finder.open(game.log) }
    }
}

struct GameTile: View {
    @Environment(AppModel.self) private var model
    let game: MacGameBundle

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: game.url.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
                .overlay(alignment: .topTrailing) {
                    if model.runner.isRunning(game) {
                        Image(systemName: "play.circle.fill")
                            .font(.title2).foregroundStyle(.white, .green)
                    }
                }
            Text(game.name).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
            Text(game.version.isEmpty ? game.titleID : "v\(game.version)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .contentShape(Rectangle())
    }
}
