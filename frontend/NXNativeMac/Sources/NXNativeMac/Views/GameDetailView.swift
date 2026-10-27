import NXCore
import SwiftUI

struct GameDetailView: View {
    @Environment(AppModel.self) private var model
    let game: MacGameBundle

    enum Tab: String, CaseIterable, Identifiable {
        case settings = "Ajustes", log = "Registro", saves = "Partidas", advanced = "Avanzado"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .settings
    @State private var store: GameSettingsStore?
    @State private var tail: LogTail?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 460)
            .padding(.vertical, 10)

            Group {
                switch tab {
                case .settings: if let store { SettingsFormView(store: store) }
                case .log: if let tail { LogView(tail: tail, game: game) }
                case .saves: SavesView(game: game)
                case .advanced: if let store { AdvancedEnvView(store: store) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(game.name)
        .task(id: game.id) {
            store = GameSettingsStore(game: game)
            let t = LogTail(url: game.log)
            t.start()
            tail = t
        }
        .onDisappear { tail?.stop() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: game.url.path))
                .resizable().frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(game.name).font(.title2.weight(.semibold))
                HStack(spacing: 10) {
                    if !game.version.isEmpty { Text("v\(game.version)") }
                    Text(game.titleID).monospaced().textSelection(.enabled)
                    if let lang = game.language, !lang.isEmpty { Text(lang) }
                    if game.hasPipelineArchive { Label("Archivo de pipelines", systemImage: "cpu").help("La app trae sus bases de pipeline hechas offline: el primer arranque no las construye.") }
                    if game.hasAddOns { Label("DLC", systemImage: "shippingbox") }
                }
                .font(.callout).foregroundStyle(.secondary)
                if let err = model.runner.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Menu {
                Button("Mostrar la app en Finder") { Finder.reveal(game.url) }
                Button("Abrir carpeta de datos") { Finder.open(game.supportDirectory) }
                Button("Abrir el log en Consola") { Finder.open(game.log) }
                Button("Abrir el log anterior") { Finder.open(game.previousLog) }
            } label: {
                Label("Carpetas", systemImage: "folder")
            }
            .fixedSize()
            if model.runner.isRunning(game) {
                Button(role: .destructive) { model.runner.stop(game) } label: {
                    Label("Detener", systemImage: "stop.fill")
                }
                .controlSize(.large)
            } else {
                Button {
                    model.runner.launch(game)
                    tab = .log
                } label: {
                    Label("Jugar", systemImage: "play.fill")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
    }
}

// MARK: - Ajustes

struct SettingsFormView: View {
    @Bindable var store: GameSettingsStore

    var body: some View {
        if let settings = store.settings, !settings.settings.isEmpty {
            Form {
                ForEach(settings.sections, id: \.name) { section in
                    Section(sectionTitle(section.name)) {
                        ForEach(section.settings) { SettingRow(store: store, setting: $0) }
                    }
                }
                Section {
                    HStack {
                        Text("Se guardan en \(store.game.userEnv.path) y valen también al abrir el juego desde Finder. Solo se escribe lo que difiere del valor probado.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restablecer valores probados") { store.resetAll() }
                    }
                    if let e = store.error { Text(e).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Sin ajustes", systemImage: "slider.horizontal.3",
                                   description: Text("Esta app no trae dm/launcher.json: se arranca tal cual. Los interruptores de diagnóstico están en Avanzado."))
        }
    }

    private func sectionTitle(_ s: String) -> String {
        ["Game": "Juego", "Controls": "Controles", "Performance": "Rendimiento"][s] ?? s
    }
}

struct SettingRow: View {
    @Bindable var store: GameSettingsStore
    let setting: Setting

    var body: some View {
        let value = store.value(setting)
        VStack(alignment: .leading, spacing: 3) {
            control(value)
            HStack(spacing: 6) {
                Text(setting.env).monospaced()
                if store.isChanged(setting) {
                    Text("· cambiado (probado: \(display(setting.defaultValue)))")
                }
                if let b = store.bundledValue(setting) {
                    Text("· el bundle trae \(display(b))")
                }
            }
            .font(.caption2).foregroundStyle(.tertiary)
            if !setting.note.isEmpty {
                Text(setting.note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func control(_ value: String) -> some View {
        switch setting.kind {
        case .choice:
            Picker(setting.label, selection: Binding(get: { value }, set: { store.set(setting, $0) })) {
                ForEach(setting.choices, id: \.value) { Text($0.label).tag($0.value) }
                // Un valor que no está en la lista (escrito a mano): que se vea.
                if !setting.choices.contains(where: { $0.value == value }) {
                    Text("\(value) (fuera de la lista)").tag(value)
                }
            }
        case .toggle:
            Toggle(setting.label, isOn: Binding(
                get: { value == (setting.on ?? "1") },
                set: { store.set(setting, $0 ? (setting.on ?? "1") : (setting.off ?? "0")) }))
        case .range:
            let lo = setting.min ?? 0, hi = setting.max ?? 1
            let current = Double(value) ?? Double(setting.defaultValue) ?? lo
            LabeledContent(setting.label) {
                HStack {
                    Slider(value: Binding(get: { current },
                                          set: { store.set(setting, setting.format(range: snap($0))) }),
                           in: lo...hi)
                        .frame(minWidth: 180)
                    Text(percent(current)).monospacedDigit().frame(width: 52, alignment: .trailing)
                }
            }
        }
    }

    private func snap(_ v: Double) -> Double {
        guard let step = setting.step, step > 0 else { return v }
        let lo = setting.min ?? 0
        return lo + ((v - lo) / step).rounded() * step
    }

    /// Los `range` se enseñan en porcentaje, como en `settings.tsv`.
    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }

    private func display(_ v: String) -> String {
        switch setting.kind {
        case .range: return Double(v).map(percent) ?? v
        case .choice: return setting.choices.first { $0.value == v }?.label ?? v
        case .toggle: return v == (setting.on ?? "1") ? "sí" : "no"
        }
    }
}

// MARK: - Avanzado

struct AdvancedEnvView: View {
    @Environment(AppModel.self) private var model
    @Bindable var store: GameSettingsStore
    @State private var text = ""
    @State private var search = ""

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text("env.txt del jugador").font(.headline)
                Text("Una línea KEY=VALUE por variable; # comenta. Gana la primera aparición, y este archivo gana al dm/env.txt del bundle.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .border(.separator)
                HStack {
                    Button("Descartar") { text = store.rawText }
                    Spacer()
                    Button("Guardar") { store.saveRaw(text) }
                        .keyboardShortcut("s")
                        .disabled(text == store.rawText)
                }
            }
            .padding()
            .frame(minWidth: 320)

            VStack(alignment: .leading, spacing: 8) {
                Text("Interruptores conocidos").font(.headline)
                TextField("Buscar", text: $search).textFieldStyle(.roundedBorder)
                List(filtered) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(s.name).monospaced().font(.callout.weight(.medium))
                            Text(s.kind).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button("Añadir") { text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + "\(s.name)=\n" }
                                .controlSize(.small)
                        }
                        Text(s.meaning).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                    }
                }
            }
            .padding()
            .frame(minWidth: 320)
        }
        .onAppear { text = store.rawText }
    }

    private var filtered: [EnvSwitch] {
        search.isEmpty ? model.switches
            : model.switches.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.meaning.localizedCaseInsensitiveContains(search) }
    }
}
