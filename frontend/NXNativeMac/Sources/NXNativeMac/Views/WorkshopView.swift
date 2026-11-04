import NXCore
import NXRuntime
import SwiftUI

struct WorkshopView: View {
    @Environment(AppModel.self) private var model
    let preferredGame: MacGameBundle?
    private enum Section: String, CaseIterable { case prepare = "Preparar", activity = "Actividad", utilities = "Herramientas" }
    private enum Pending {
        case build(GameEntry, BuildOptions.Platform, URL), retry(BuildJob), cancel(BuildJob)
    }
    @State private var section: Section = .prepare
    @State private var gameID: String?
    @State private var platform: BuildOptions.Platform = .macApp
    @State private var outputDirectory: URL?
    @State private var focus = WorkshopFocus()
    @State private var detailID: UUID?
    @State private var legacyTools = false
    @State private var pending: Pending?
    @State private var confirmSelected = false
    @State private var message: String?
    @State private var logPage = 0
    @FocusState private var keyboardFocused: Bool

    private var candidates: [(id: String, name: String)] {
        var names = Dictionary(model.games.map { ($0.titleID.uppercased(), $0.name) }, uniquingKeysWith: { first, _ in first })
        for source in model.library { names[source.base.description] = model.name(for: source) }
        return names.map { (id: $0.key, name: $0.value) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var source: GameEntry? { model.library.first { $0.base.description == gameID } }
    private var gameName: String { candidates.first { $0.id == gameID }?.name ?? "Selecciona un juego" }
    private var detail: BuildJob? { model.builds.jobs.first { $0.id == detailID } }
    private var issues: [String] { model.workshopIssues(for: source, platform: platform) }
    private var output: URL? { source.map { model.workshopOutput(for: $0, platform: platform, directory: outputDirectory) } }

    private var rows: [String] {
        if legacyTools { return [] }
        if let job = detail {
            return ["log"] + (job.isActive ? ["cancel"] : (job.status == .succeeded ? [] : ["retry"]))
                + (job.logsDirectory == nil ? [] : ["logs"]) + (job.resultDirectory == nil ? [] : ["output"]) + ["jobs"]
        }
        switch section {
        case .prepare: return ["game", "platform", "workers", "destination", "start"]
        case .activity: return model.builds.jobs.map { $0.id.uuidString } + ["prepare"]
        case .utilities: return ["sources", "keys", "scan", "legacy"]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if pending != nil {
                confirmation
            } else if legacyTools {
                VStack {
                    Button("Volver al Taller") { leaveDetail() }
                    ConsoleToolsView()
                }.padding(12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 10) {
                            if let detail { activityDetail(detail) }
                            else { sectionContent }
                            if let message { Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                            if let error = model.builds.persistenceError {
                                Text("No se pudo guardar el historial: " + error).font(.caption).foregroundStyle(.orange)
                            }
                        }.padding(20)
                    }
                    .onChange(of: focus.selected) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        }
        .focusable().focusEffectDisabled().focused($keyboardFocused)
        .onKeyPress(.upArrow) { key(.up) }
        .onKeyPress(.downArrow) { key(.down) }
        .onKeyPress(.leftArrow) { key(.left) }
        .onKeyPress(.rightArrow) { key(.right) }
        .onKeyPress(.return, phases: .down) { _ in key(.primary) }
        .onKeyPress("t", phases: .down) { _ in key(.configure) }
        .onAppear {
            gameID = preferredGame?.titleID.uppercased() ?? candidates.first?.id
            focus.reconcile(rows)
            keyboardFocused = true
            model.workshopInput = handle
        }
        .onChange(of: rows) { _, rows in focus.reconcile(rows) }
        .onChange(of: candidates.map(\.id)) { _, ids in
            if !ids.contains(gameID ?? "") { gameID = ids.first }
        }
        .onDisappear {
            model.workshopInput = nil
            model.workshopBackLabel = nil
            model.gamepad.dialogPresented = false
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("Taller", systemImage: "hammer.fill").font(.title2.bold())
            ForEach(Section.allCases, id: \.self) { item in
                Button { setSection(item) } label: {
                    Text(item.rawValue).font(.callout.weight(section == item ? .semibold : .regular))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(section == item ? .white.opacity(0.18) : .clear, in: Capsule())
                }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(section == item ? .isSelected : [])
                    .disabled(pending != nil)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(model.builds.pendingCount) en cola / en curso")
                Text(model.builds.memoryPressure ? "Esperando: presión de memoria" : "1 build a la vez · hasta 2 trabajadores")
                    .foregroundStyle(model.builds.memoryPressure ? .orange : .secondary)
                Text(model.gamepad.showsControllerPrompts ? "\(model.gamepad.family.triggers) · cambiar sección" : "T · cambiar sección")
                    .foregroundStyle(.secondary)
            }.font(.caption)
        }.padding(18)
    }

    @ViewBuilder private var sectionContent: some View {
        switch section {
        case .prepare:
            Text("Prepara o reconstruye una app usando tus archivos originales.")
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Text("\(model.library.count) juegos con archivos detectados · \(model.library.filter { model.profileState($0) == .registered }.count) con perfil disponible")
                .font(.callout).foregroundStyle(.secondary)
            row("game", "Juego", value: gameName, symbol: "gamecontroller", adjustable: true)
            if let source {
                Label(model.profileState(source) == .registered ? "Perfil de transformación disponible" : "Sin perfil de transformación registrado",
                      systemImage: model.profileState(source) == .registered ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.callout)
                Text(issues.isEmpty ? "Archivos detectados · listo para revisar el build" : "Archivos detectados · revisa los requisitos pendientes")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Solo app instalada · faltan los archivos originales para trabajar en el Taller")
                    .font(.callout).foregroundStyle(.orange)
            }
            row("platform", "Salida", value: platform == .macApp ? "App de Mac" : "IPA sin firmar", symbol: "shippingbox", adjustable: true)
            row("workers", "Recursos", value: workerLabel, symbol: "cpu", adjustable: true)
            row("destination", "Destino", value: output?.path ?? "Depende del juego", symbol: "folder")
            if let source {
                if let dump = source.extracted {
                    Text(dump.isSwitch2 ? "Switch 2 · carpeta extraída · sin claves" : "Carpeta extraída · sin claves")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("Origen: \(source.ownFolder?.path ?? source.root?.path ?? "—")")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                if model.profileState(source) == .unknown && source.extracted == nil {
                    Text("Perfil provisional: la app resultante podría no arrancar.").foregroundStyle(.orange).font(.callout)
                }
            }
            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(issues, id: \.self) { Label($0, systemImage: "exclamationmark.circle") }
                    Text("Usa Herramientas para elegir archivos o Global para comprobar dependencias.")
                }.font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            row("start", model.games.contains(where: { $0.titleID.uppercased() == gameID }) ? "Reconstruir juego" : "Preparar build", value: "Revisar antes de empezar", symbol: "hammer", enabled: issues.isEmpty && !model.scanning)
        case .activity:
            if model.builds.jobs.isEmpty {
                ContentUnavailableView("Todavía no hay trabajos", systemImage: "clock", description: Text("Aquí verás el progreso y podrás reintentar un build fallido."))
            }
            ForEach(model.builds.jobs) { job in
                row(job.id.uuidString, job.title, value: job.workshopStatus, symbol: job.isActive ? "hourglass" : "shippingbox")
                if job.status == .running { ProgressView(value: job.overallFraction ?? 0).padding(.horizontal, 16) }
            }
            row("prepare", "Preparar otro juego", value: "Volver a Preparar", symbol: "plus.circle")
        case .utilities:
            row("sources", "Añadir carpeta de juegos", value: "NSP, XCI, NSZ, XCZ o carpetas extraídas", symbol: "externaldrive")
            row("keys", "Archivo de claves", value: model.prefs.keysURL?.lastPathComponent ?? "Elegir prod.keys", symbol: "key")
            row("scan", "Volver a escanear", value: model.scanning ? "Escaneando…" : "Actualizar archivos y apps", symbol: "arrow.clockwise", enabled: !model.scanning)
            row("legacy", "Herramientas avanzadas", value: "Instalador FC, opciones detalladas, perfiles y partidas", symbol: "wrench.and.screwdriver")
            Text("Los selectores de archivos de macOS se manejan con mouse o teclado.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func activityDetail(_ job: BuildJob) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(job.title).font(.title3.bold())
            Text(job.workshopStatus + " · \(job.workers) trabajador(es)").foregroundStyle(.secondary)
            if let fraction = job.overallFraction { ProgressView(value: fraction) }
            if let current = job.stages.last { StageRow(stage: current, total: job.stageCount) }
            if let error = job.lastError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            row("log", "Mensajes", value: "← anteriores · posteriores →", symbol: "text.alignleft", adjustable: true)
            Text(logText(job)).font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
            if job.isActive { row("cancel", "Cancelar trabajo", value: "Pedir confirmación", symbol: "stop.circle") }
            else if job.status != .succeeded { row("retry", "Reintentar", value: "Revisar y reutilizar lo compilado", symbol: "arrow.clockwise") }
            if job.logsDirectory != nil { row("logs", "Abrir carpeta de logs", value: "Finder", symbol: "doc.text") }
            if job.resultDirectory != nil { row("output", "Mostrar salida", value: "Finder", symbol: "folder") }
            row("jobs", "Volver a actividad", value: "Todos los trabajos", symbol: "arrow.left")
        }
    }

    private func row(_ id: String, _ title: String, value: String, symbol: String,
                     adjustable: Bool = false, enabled: Bool = true) -> some View {
        WorkshopControl(title: title, value: value, symbol: symbol, selected: focus.selected == id,
                        adjustable: adjustable, enabled: enabled,
                        activate: { focus.selected = id; activate(id) },
                        adjust: { delta in focus.selected = id; adjust(id, delta: delta) })
            .id(id)
    }

    private func key(_ action: ConsoleAction) -> KeyPress.Result { handle(action) ? .handled : .ignored }

    /// The library routes controller input here once, avoiding competing observers.
    private func handle(_ action: ConsoleAction) -> Bool {
        if pending != nil {
            switch action {
            case .left, .up: confirmSelected = false
            case .right, .down: confirmSelected = true
            case .primary: confirmSelected ? performPending() : dismissConfirmation()
            case .back: dismissConfirmation()
            default: break
            }
            return true
        }
        if model.gamepad.dialogPresented { return true }
        switch action {
        case .back:
            if detailID != nil || legacyTools { leaveDetail(); return true }
            return false
        case .configure:
            cycleSection(by: 1)
        case .previousSection: cycleSection(by: -1)
        case .nextSection: cycleSection(by: 1)
        case .up: focus.move(-1, in: rows)
        case .down: focus.move(1, in: rows)
        case .left: if let id = focus.selected { adjust(id, delta: -1) }
        case .right: if let id = focus.selected { adjust(id, delta: 1) }
        case .primary: if let id = focus.selected { activate(id) }
        default: return false
        }
        return true
    }

    private func adjust(_ id: String, delta: Int) {
        switch id {
        case "game":
            guard !candidates.isEmpty else { return }
            let index = candidates.firstIndex { $0.id == gameID } ?? 0
            gameID = candidates[(index + delta + candidates.count) % candidates.count].id
        case "platform": platform = platform == .macApp ? .ios : .macApp
        case "workers": model.prefs.buildWorkers = WorkshopBuild.adjustedWorkers(model.prefs.buildWorkers, delta: delta)
        case "log":
            let total = max(1, ((detail?.messages.count ?? 0) + 11) / 12)
            logPage = min(total - 1, max(0, logPage - delta))
        default: break
        }
    }

    private var workerLabel: String {
        switch WorkshopBuild.normalizedWorkers(model.prefs.buildWorkers) {
        case 1: return "Tranquilo · 1 trabajador"
        case 2: return "Equilibrado · 2 trabajadores"
        case 4: return "Rápido · 4 trabajadores"
        default: return "Máximo · 6 trabajadores"
        }
    }

    private func activate(_ id: String) {
        message = nil
        switch id {
        case "game", "platform", "workers", "log": adjust(id, delta: 1)
        case "destination": choose { outputDirectory = Finder.chooseFolder(prompt: "Usar este destino") ?? outputDirectory }
        case "sources": choose {
            if let folder = Finder.chooseFolder(prompt: "Añadir juegos") {
                if !model.prefs.gameRoots.contains(folder.path) { model.prefs.gameRoots.append(folder.path) }
                Task { await model.refresh() }
            }
        }
        case "keys": choose {
            if let keys = Finder.chooseFile(prompt: "Usar claves") { model.prefs.keysPath = keys.path; Task { await model.refresh() } }
        }
        case "scan": if !model.scanning { Task { await model.refresh() } }
        case "start":
            guard issues.isEmpty, !model.scanning, let source, let output else { return }
            showConfirmation(.build(source, platform, output))
        case "retry": if let detail { showConfirmation(.retry(detail)) }
        case "cancel": if let detail { showConfirmation(.cancel(detail)) }
        case "logs": if let url = detail?.logsDirectory { Finder.open(url) }
        case "output": if let url = detail?.resultDirectory { Finder.reveal(url) }
        case "prepare": setSection(.prepare)
        case "jobs": leaveDetail()
        case "legacy": legacyTools = true; model.workshopBackLabel = "Volver al Taller"
        default:
            if let id = UUID(uuidString: id) {
                detailID = id; logPage = 0; focus.selected = "log"
                model.workshopBackLabel = "Volver a actividad"
            }
        }
    }

    private func setSection(_ next: Section) {
        section = next; leaveDetail(); focus.selected = nil; focus.reconcile(rows)
    }
    private func cycleSection(by delta: Int) {
        let sections = Section.allCases
        let index = sections.firstIndex(of: section) ?? 0
        setSection(sections[(index + delta + sections.count) % sections.count])
    }
    private func leaveDetail() {
        detailID = nil; legacyTools = false; model.workshopBackLabel = nil; focus.reconcile(rows)
        keyboardFocused = true
    }
    private func choose(_ operation: () -> Void) {
        model.gamepad.dialogPresented = true
        defer { model.gamepad.dialogPresented = false; keyboardFocused = true }
        operation()
    }
    private func showConfirmation(_ value: Pending) {
        pending = value; confirmSelected = false; model.gamepad.dialogPresented = true; keyboardFocused = true
    }
    private func dismissConfirmation() {
        pending = nil; model.gamepad.dialogPresented = false; keyboardFocused = true
    }

    private var confirmationText: (title: String, details: String, action: String) {
        switch pending {
        case let .build(source, platform, output):
            return ("Revisar build · " + model.name(for: source),
                    "\(platform == .ios ? "IPA sin firmar" : "App de Mac")\n\(output.path)\n\(model.prefs.buildWorkers) trabajador(es) · prioridad baja\nLa salida existente se reemplaza. Las partidas y los ajustes permanecen fuera del bundle.", "Añadir a la cola")
        case let .retry(job): return ("Reintentar · " + job.title, "Se usarán el origen y destino del trabajo anterior, comprobándolos de nuevo antes de empezar.", "Reintentar")
        case let .cancel(job): return ("Cancelar · " + job.title, "Se solicitará la detención al builder. Lo reutilizable permanecerá en la carpeta del juego.", "Cancelar trabajo")
        case nil: return ("", "", "")
        }
    }
    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(confirmationText.title).font(.title2.bold())
            Text(confirmationText.details).font(.body).textSelection(.enabled)
            HStack(spacing: 20) {
                Button("Volver") { dismissConfirmation() }.buttonStyle(.bordered)
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(confirmSelected ? .clear : Color.accentColor, lineWidth: 3) }
                Button(confirmationText.action) { performPending() }.buttonStyle(.borderedProminent)
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(confirmSelected ? Color.white : .clear, lineWidth: 3) }
            }.controlSize(.large)
            Text(model.gamepad.showsControllerPrompts
                 ? "Cruceta / stick: elegir · \(model.gamepad.primaryPrompt.text) confirmar · \(model.gamepad.backPrompt.text) volver"
                 : "← → elegir · Enter confirmar · Esc volver")
                .foregroundStyle(.secondary)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
    private func performPending() {
        let operation = pending
        dismissConfirmation()
        switch operation {
        case let .build(source, platform, output): message = model.startWorkshopBuild(source: source, platform: platform, output: output)
        case let .retry(job): message = model.retryWorkshopBuild(job)
        case let .cancel(job): job.cancel()
        case nil: return
        }
        if message == nil { setSection(.activity) }
    }
    private func logText(_ job: BuildJob) -> String {
        let end = max(0, job.messages.count - logPage * 12)
        let start = max(0, end - 12)
        let lines = job.messages[start..<end].map(\.text).joined(separator: "\n")
        return lines.isEmpty ? (job.stderrTail.isEmpty ? "Los mensajes aparecerán al empezar. Los logs anteriores permanecen en la carpeta del juego." : String(job.stderrTail.suffix(2400))) : String(lines.suffix(4000))
    }
}
