import NXCore
import SwiftUI

/// La tabla de juegos de `dm/games/README.md`, cruzada con lo que hay en
/// disco. Lo que dice cada juego viene de nxnative, no de esta app.
struct CompatibilityView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var onlyMine = false
    @State private var sort = [KeyPathComparator(\Row.name)]

    struct Row: Identifiable {
        var entry: CompatibilityEntry
        var name: String { entry.name }
        var id: String { entry.titleID.description }
        var engine: String { entry.engine }
        var graphics: String { entry.graphics }
        var build: String { entry.build }
        var mine: String
    }

    var body: some View {
        Table(rows, sortOrder: $sort) {
            TableColumn("Juego", value: \.name) { r in
                Link(r.name, destination: noteURL(r.entry))
            }
            .width(min: 200, ideal: 280)
            TableColumn("Title ID", value: \.id) { Text($0.id).monospaced() }.width(150)
            TableColumn("Build", value: \.build).width(90)
            TableColumn("Motor", value: \.engine).width(min: 120, ideal: 220)
            TableColumn("Gráficos", value: \.graphics).width(80)
            TableColumn("En este Mac", value: \.mine).width(110)
        }
        .searchable(text: $search, prompt: "Juego, motor, title ID")
        .navigationTitle("Compatibilidad (\(model.compatibility.count))")
        .toolbar {
            Toggle("Solo los que tengo", isOn: $onlyMine).toggleStyle(.checkbox)
        }
        .overlay {
            if model.compatibility.isEmpty {
                ContentUnavailableView("Sin tabla de juegos", systemImage: "tablecells",
                                       description: Text("Se lee de dm/games/README.md del checkout de nxnative."))
            }
        }
    }

    private var rows: [Row] {
        model.compatibility.map { e in
            let mine = model.game(for: e.titleID) != nil ? "App lista"
                : model.folder(for: e.titleID) != nil ? "NSP" : ""
            return Row(entry: e, mine: mine)
        }
        .filter { !onlyMine || !$0.mine.isEmpty }
        .filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || $0.engine.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search)
        }
        .sorted(using: sort)
    }

    /// La nota del juego en el checkout local: estado, problemas, cómo jugarlo.
    private func noteURL(_ e: CompatibilityEntry) -> URL {
        model.repository.gamesDirectory.appendingPathComponent("\(e.titleID)/README.md")
    }
}
