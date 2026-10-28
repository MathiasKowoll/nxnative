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
                    model.play(game)
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
                ButtonGlyphsSection(store: store)
                HighRefreshSection(store: store)
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

/// Iconos de botones en el texto del juego: los de Switch o los de un mando
/// de Sony en la misma posición. No viene de launcher.json: es de esta app.
struct ButtonGlyphsSection: View {
    @Environment(AppModel.self) private var model
    @Bindable var store: GameSettingsStore
    @State private var busy = false

    var body: some View {
        Section("Iconos de botones") {
            if let current = store.buttonGlyphs {
                Picker("Mando", selection: Binding(get: { current }, set: { style in
                    Task {
                        busy = true
                        await store.setButtonGlyphs(style, repository: model.repository, python: model.toolchain.python)
                        busy = false
                    }
                })) {
                    Text("Switch (A B X Y)").tag(ButtonGlyphs.nintendo)
                    Text("PlayStation (○ ✕ △ □)").tag(ButtonGlyphs.playstation)
                }
                .disabled(busy)
            } else {
                Text("El env.txt de este juego apunta a otra fuente (\(ButtonGlyphs.envKey)), puesta a mano: se respeta. Para volver a elegir aquí, quita esa línea en Avanzado.")
                    .foregroundStyle(.secondary)
            }
            Text("Los botones se asignan por posición: el de la derecha es A (○), abajo B (✕), arriba X (△), izquierda Y (□); L/R y ZL/ZR son L1/R1 y L2/R2. Cambia los juegos que dibujan los botones con la fuente del sistema (los de Nintendo, sobre todo); un juego con sus propias imágenes de botones sigue enseñando las suyas. Vale desde el siguiente arranque.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 120 Hz por juego: los cuatro interruptores de HighRefresh. Experimental
/// porque depende de cómo mide el tiempo el motor del juego.
struct HighRefreshSection: View {
    @Bindable var store: GameSettingsStore

    private var screenHz: Int { NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60 }

    var body: some View {
        Section("120 Hz (experimental)") {
            Toggle("Hasta 120 imágenes por segundo", isOn: Binding(get: { store.highRefresh }, set: { store.setHighRefresh($0) }))
            if !store.highRefresh, !store.highRefreshConflicts.isEmpty {
                Text("Este juego ya fija a mano \(store.highRefreshConflicts.joined(separator: ", ")) en su env.txt; encenderlo lo cambia.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if screenHz < 120 {
                Text("Ninguna pantalla conectada pasa de \(screenHz) Hz: con este modo el juego no se verá a más de \(screenHz).")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Solo funciona en juegos cuyo motor mide el tiempo entre imágenes (Unreal y muchos de Unity; Batman: Arkham Knight llegó a 119,8 fps). Un juego con la lógica atada a 30 o 60 se queda en su tope o va acelerado: si pasa, apágalo. Pide el doble de GPU que 60 fps. Si se queda en 60, puede que haga falta reconstruir el juego con esta versión de nxnative. Vale desde el siguiente arranque.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SettingRow: View {
    @Bindable var store: GameSettingsStore
    let setting: Setting

    var body: some View {
        let value = store.value(setting)
        VStack(alignment: .leading, spacing: 3) {
            control(value)
                .disabled(store.ownedByHighRefresh(setting))
            if store.ownedByHighRefresh(setting) {
                Text("Lo controla el modo 120 Hz.").font(.caption).foregroundStyle(.secondary)
            }
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

/// Interruptores sueltos del env.txt del jugador. Arriba lo que ya fija este
/// juego, editable; debajo los conocidos (docs/env_switches.tsv) por grupos,
/// con los valores que su propia descripción nombra. El archivo en bruto
/// sigue a mano, plegado.
struct AdvancedEnvView: View {
    @Environment(AppModel.self) private var model
    @Bindable var store: GameSettingsStore
    @State private var group: EnvSwitch.Group = .player
    @State private var search = ""
    @State private var adding: EnvSwitch?
    @State private var rawOpen = false
    @State private var text = ""

    var body: some View {
        Form {
            Section {
                if store.activeSwitches.isEmpty {
                    Text("Ninguno. Los ajustes de la pestaña Ajustes también se guardan aquí.").foregroundStyle(.secondary)
                }
                ForEach(store.activeSwitches, id: \.key) { entry in
                    ActiveSwitchRow(key: entry.key, value: entry.value, known: known(entry.key)) { v in store.setSwitch(entry.key, v) }
                }
            } header: {
                Text("Activos en este juego")
            } footer: {
                Text("Valen desde el siguiente arranque, también al abrir el juego desde Finder. Un valor que pase la app al arrancar (por ejemplo los de «Todos los juegos») no pisa los de aquí.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Tipo", selection: $group) {
                    ForEach(EnvSwitch.Group.allCases.filter(\.offered), id: \.self) { g in
                        Text("\(g.title) (\(model.switches.filter { $0.group == g }.count))").tag(g)
                    }
                }
                .pickerStyle(.segmented)
                TextField("Buscar por nombre o descripción", text: $search)
                if group == .diagnostic || group == .test {
                    Label("Pensados para investigar fallos: pueden llenar el log, frenar el juego o cambiar cómo se comporta.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach(filtered) { s in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(s.name).monospaced().font(.callout.weight(.medium))
                            Text(s.formattedMeaning).font(.caption).foregroundStyle(.secondary).lineLimit(5)
                        }
                        Spacer()
                        if let v = store.activeSwitches.first(where: { $0.key == s.name })?.value {
                            Text(v.isEmpty ? "(vacío)" : v).monospaced().font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.green.opacity(0.15), in: Capsule())
                        } else {
                            Button("Añadir…") { adding = s }.controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Interruptores de nxnative")
            } footer: {
                Text("Las descripciones son las de nxnative (docs/env_switches.tsv). Las rutas no se ofrecen: las pone el lanzador con las carpetas de la app.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("Editar el archivo a mano", isExpanded: $rawOpen) {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 140)
                    HStack {
                        Text("Una línea KEY=VALUE por variable; # comenta; gana la primera aparición.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Descartar") { text = store.rawText }
                        Button("Guardar") { store.saveRaw(text) }.keyboardShortcut("s").disabled(text == store.rawText)
                    }
                }
                .onChange(of: rawOpen) { if rawOpen { text = store.rawText } }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $adding) { s in
            AddSwitchSheet(sw: s) { value in store.setSwitch(s.name, value); adding = nil } cancel: { adding = nil }
        }
    }

    private func known(_ key: String) -> EnvSwitch? { model.switches.first { $0.name == key } }

    private var filtered: [EnvSwitch] {
        model.switches.filter { s in
            guard s.group.offered else { return false }
            if !search.isEmpty { return s.name.localizedCaseInsensitiveContains(search) || s.meaning.localizedCaseInsensitiveContains(search) }
            return s.group == group
        }
    }
}

/// Una variable que el env.txt ya fija: su valor, editable, y quitarla.
struct ActiveSwitchRow: View {
    let key: String
    let value: String
    let known: EnvSwitch?
    var set: (String?) -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(key).monospaced().font(.callout.weight(.medium))
                Spacer()
                if let options = known?.suggestedValues, options.count > 1, options.contains(value) || value.isEmpty {
                    Picker("", selection: Binding(get: { value }, set: { set($0) })) {
                        ForEach(options, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                } else {
                    TextField("valor", text: $draft, prompt: Text(known?.placeholder ?? "valor"))
                        .monospaced().frame(width: 140)
                        .onSubmit { set(draft) }
                }
                Button { set(nil) } label: { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.red).help("Quitar del env.txt")
            }
            if let k = known { Text(k.formattedMeaning).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            else { Text("No está en la lista de nxnative: puede ser de otra versión o un error al escribirlo.").font(.caption).foregroundStyle(.orange) }
        }
        .onAppear { draft = value }
        .onChange(of: value) { draft = value }
    }
}

/// Añadir un interruptor: los valores que nombra su descripción como botones,
/// o el valor escrito.
struct AddSwitchSheet: View {
    let sw: EnvSwitch
    var add: (String) -> Void
    var cancel: () -> Void
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(sw.name).font(.title3.weight(.semibold)).monospaced()
            Text(sw.formattedMeaning).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !sw.suggestedValues.isEmpty {
                Text("Valores que nombra la descripción").font(.caption).foregroundStyle(.secondary)
                HStack {
                    ForEach(sw.suggestedValues, id: \.self) { v in
                        Button(v) { add(v) }.monospaced()
                    }
                }
            }
            HStack {
                TextField("Otro valor", text: $value, prompt: Text(sw.placeholder ?? "valor"))
                    .monospaced().onSubmit { if !value.isEmpty { add(value) } }
                Button("Añadir") { add(value) }.disabled(value.isEmpty).keyboardShortcut(.defaultAction)
            }
            HStack { Spacer(); Button("Cancelar", action: cancel).keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .frame(width: 520)
    }
}
