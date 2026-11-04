import AppKit
import NXCore
import SwiftUI

extension ConsolePage {
    var title: String {
        switch self {
        case .games: "Juegos"
        case .settings: "Ajustes"
        case .log: "Registro"
        case .saves: "Partidas"
        case .advanced: "Avanzado"
        case .environment: "Global"
        case .developer: "Desarrollo"
        case .tools: "Taller"
        }
    }
    var symbol: String {
        switch self {
        case .games: "gamecontroller.fill"
        case .settings: "slider.horizontal.3"
        case .log: "text.alignleft"
        case .saves: "externaldrive"
        case .advanced: "switch.2"
        case .environment: "gearshape.fill"
        case .developer: "wrench.and.screwdriver.fill"
        case .tools: "shippingbox"
        }
    }
}

struct ConsoleTopBar: View {
    @Environment(AppModel.self) private var model
    @Binding var panel: ConsolePage
    let game: MacGameBundle?

    var body: some View {
        HStack(spacing: 18) {
            Text("NXNATIVE")
                .font(.headline.weight(.black))
                .tracking(2)
            if panel == .games {
                Text("Juegos").font(.title2.weight(.semibold))
                Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
                Text("\(model.games.count) juegos").foregroundStyle(.secondary)
                Image(systemName: model.gamepad.showsControllerPrompts ? "gamecontroller.fill" : "keyboard")
                    .help(model.gamepad.showsControllerPrompts ? model.gamepad.controllerName : "Mouse y teclado")
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(context.date, style: .time).monospacedDigit()
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(ConsolePage.allCases.filter { $0 != .games }) { item in
                            Button { panel = item } label: {
                                Text(item.title)
                                    .font(.callout.weight(panel == item ? .semibold : .regular))
                                    .padding(.horizontal, 12).padding(.vertical, 9)
                                    .background(panel == item ? .white.opacity(0.18) : .clear, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(game == nil && ![.environment, .developer, .tools].contains(item))
                            .accessibilityAddTraits(panel == item ? .isSelected : [])
                        }
                    }
                }
                if model.gamepad.showsControllerPrompts {
                    Text(model.gamepad.family.shoulders + " · secciones")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 28)
        .frame(height: 64)
        .background(.black.opacity(0.2))
    }
}

struct ConsoleCommandBar: View {
    @Environment(AppModel.self) private var model
    let page: ConsolePage
    let hasGame: Bool
    var canPlay = true
    let action: (ConsoleAction) -> Void

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 22) {
                if page == .games {
                    Label("Elegir", systemImage: "arrow.left.and.right")
                    if hasGame {
                        Button { action(.primary) } label: {
                            command(model.gamepad.primaryPrompt, key: "↩", title: "Jugar")
                        }
                        .disabled(!canPlay)
                    }
                    Button { action(.configure) } label: {
                        command(model.gamepad.configurationPrompt, key: "C", title: "Configuración")
                    }
                    .keyboardShortcut("c", modifiers: [])
                    Spacer()
                    if !model.gamepad.showsControllerPrompts {
                        Text("Clic: elegir · doble clic: jugar").foregroundStyle(.secondary)
                    }
                } else {
                    Button { action(.back) } label: {
                        command(model.gamepad.backPrompt, key: "Esc", title: page == .tools ? (model.workshopBackLabel ?? "Volver a juegos") : "Volver a juegos")
                    }
                    if model.gamepad.showsControllerPrompts, page == .settings || page == .advanced {
                        command(model.gamepad.primaryPrompt, key: "↩", title: page == .settings ? "Aplicar" : "Añadir / quitar")
                    }
                    Spacer()
                    if model.gamepad.showsControllerPrompts {
                        Text(model.gamepad.family.shoulders + " · secciones").foregroundStyle(.secondary)
                    } else {
                        Button { action(.previousTab) } label: { Text("‹ Anterior") }
                            .keyboardShortcut("[", modifiers: .command)
                        Button { action(.nextTab) } label: { Text("Siguiente ›") }
                            .keyboardShortcut("]", modifiers: .command)
                        Text("⌘[ / ⌘] · secciones").foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
            .buttonStyle(.plain)
            if page == .games {
                Text(model.gamepad.showsControllerPrompts
                     ? "Cruceta / stick: elegir · \(model.gamepad.primaryPrompt.text) jugar · \(model.gamepad.configurationPrompt.text) configurar"
                     : "← → elegir · Enter jugar · C configurar · Tab cambiar foco")
                    .font(.caption).foregroundStyle(.secondary)
                if model.gamepad.showsControllerPrompts, model.prefs.globalExitEnabled {
                    Text(exitHint).font(.caption2).foregroundStyle(.secondary)
                }
            } else if page == .tools {
                if model.gamepad.showsControllerPrompts {
                    HStack(spacing: 16) {
                        Text("Cruceta / stick: elegir y cambiar")
                        Text(model.gamepad.family.triggers + " · cambiar vista")
                        command(model.gamepad.primaryPrompt, key: "↩", title: "Aceptar")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("↑↓ elegir · ←→ cambiar · Enter aceptar · T cambiar vista")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(model.gamepad.showsControllerPrompts
                     ? "Cruceta / stick: elegir y cambiar · \(model.gamepad.backPrompt.text) volver"
                     : "Tab: recorrer controles · Espacio: activar · Esc: volver")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .background(.black.opacity(0.4))
    }

    private var exitHint: String {
        var gestures: [String] = []
        if model.prefs.globalExitSelectStart { gestures.append("Select + Start") }
        if model.prefs.globalExitTouchpad, model.gamepad.family == .playStation { gestures.append("clic del touchpad") }
        guard !gestures.isEmpty else { return "" }
        return "Durante el juego: mantener \(gestures.joined(separator: " o ")) \(Int(model.prefs.globalExitHoldSeconds)) s para volver"
    }

    private func command(_ prompt: GamepadInput.Prompt, key: String, title: String) -> some View {
        HStack(spacing: 8) {
            if model.gamepad.showsControllerPrompts, let symbol = prompt.symbol {
                Image(systemName: symbol).font(.title3)
            } else {
                Text(model.gamepad.showsControllerPrompts ? prompt.text : key)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
            }
            Text(title)
        }
    }
}

struct ConsolePanelContent: View {
    let panel: ConsolePage
    let game: MacGameBundle
    let store: GameSettingsStore?
    let tail: LogTail?
    var openWorkshop: () -> Void = {}
    @State private var advancedEditor = false

    var body: some View {
        Group {
            switch panel {
            case .games:
                ConsoleHeroView(game: game)
            case .settings:
                ConsolePanelSurface {
                    if let store { GamepadSettingsView(store: store, rebuild: openWorkshop) }
                    else { ProgressView("Cargando ajustes…") }
                }
            case .log:
                ConsolePanelSurface {
                    if let tail { LogView(tail: tail, game: game) }
                    else { ProgressView("Cargando registro…") }
                }
            case .saves:
                ConsolePanelSurface { SavesView(game: game) }
            case .advanced:
                ConsolePanelSurface {
                    if let store {
                        VStack(spacing: 10) {
                            Toggle("Editor de texto", isOn: $advancedEditor)
                                .toggleStyle(.switch)
                                .help("Editar variables libres con mouse y teclado")
                            if advancedEditor { AdvancedEnvView(store: store) }
                            else { GamepadAdvancedView(store: store) }
                        }
                    } else { ProgressView("Cargando ajustes avanzados…") }
                }
            case .environment, .developer, .tools: EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ConsolePanelSurface<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial.opacity(0.88), in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12)) }
            .padding(18)
    }
}

struct ConsoleHeroView: View {
    @Environment(AppModel.self) private var model
    let game: MacGameBundle

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 380
            ZStack(alignment: .leading) {
                GameHeroArtwork(game: game)
                LinearGradient(colors: [.black.opacity(0.9), .black.opacity(0.65), .black.opacity(0.18)],
                               startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.black.opacity(0.12), .clear, .black.opacity(0.52)],
                               startPoint: .top, endPoint: .bottom)
                VStack {
                    HStack { Spacer(); ArtworkMenu(game: game) }
                    Spacer()
                }
                .padding(22)
                VStack(alignment: .leading, spacing: compact ? 10 : 18) {
                    Text("TU BIBLIOTECA").font(.caption.weight(.bold)).tracking(3).foregroundStyle(.white.opacity(0.8))
                    Text(game.name)
                        .font(.system(size: compact ? 34 : 48, weight: .bold, design: .rounded))
                        .lineLimit(3).minimumScaleFactor(0.65)
                    HStack(spacing: 10) {
                        if !game.version.isEmpty { ConsoleBadge("v\(game.version)") }
                        if let language = game.language, !language.isEmpty { ConsoleBadge(language) }
                        if model.runner.isRunning(game) { ConsoleBadge("En ejecución") }
                    }
                    Button { model.play(game) } label: {
                        Label(model.runner.isRunning(game) ? "Continuar" : "Jugar", systemImage: "play.fill")
                            .font(.headline)
                            .frame(width: 160).padding(.vertical, 7)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(model.isBuildingGame(game))
                    if model.isBuildingGame(game) {
                        Text("Reconstrucción en curso · consulta el Taller").font(.callout).foregroundStyle(.secondary)
                    }
                    if let error = model.runner.lastError {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                }
                .shadow(color: .black.opacity(0.75), radius: 3, y: 2)
                .frame(maxWidth: min(680, proxy.size.width * 0.62), alignment: .leading)
            }
            .padding(.horizontal, proxy.size.width < 1000 ? 32 : 56)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.14)) }
            .padding(18)
        }
        .foregroundStyle(.white)
    }
}

private struct ArtworkMenu: View {
    @Environment(AppModel.self) private var model
    let game: MacGameBundle
    @State private var error: String?

    var body: some View {
        Menu {
            Button("Buscar fondo en la web") { model.artwork.searchWeb(for: game, role: .hero) }
            Button("Elegir fondo…") { choose(.hero) }
            Button("Elegir carátula…") { choose(.cover) }
            if model.artwork.image(for: game, role: .hero) != nil || model.artwork.image(for: game, role: .cover) != nil {
                Divider()
                if model.artwork.image(for: game, role: .hero) != nil {
                    Button("Restablecer fondo", role: .destructive) { remove(.hero) }
                }
                if model.artwork.image(for: game, role: .cover) != nil {
                    Button("Restablecer carátula", role: .destructive) { remove(.cover) }
                }
            }
        } label: {
            Label("Arte", systemImage: "photo.on.rectangle")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.black.opacity(0.38), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .help("Las imágenes se guardan solo en este Mac")
        .alert("No se pudo usar la imagen", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Aceptar", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func choose(_ role: ArtworkStore.Role) {
        do { _ = try model.artwork.chooseArtwork(for: game, role: role) }
        catch { self.error = error.localizedDescription }
    }

    private func remove(_ role: ArtworkStore.Role) {
        do { try model.artwork.removeArtwork(for: game, role: role) }
        catch { self.error = error.localizedDescription }
    }
}

struct ConsoleBadge: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.white.opacity(0.12), in: Capsule())
    }
}

struct ConsoleBackdrop: View {
    let game: MacGameBundle?
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: [Color(red: 0.025, green: 0.02, blue: 0.08),
                                        Color(red: 0.11, green: 0.04, blue: 0.20)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if let game {
                    GameArtworkImage(game: game)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .blur(radius: 50).opacity(0.3)
                }
                LinearGradient(colors: [.black.opacity(0.25), .clear, .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct GameArtworkImage: View {
    @Environment(AppModel.self) private var model
    let game: MacGameBundle
    var body: some View {
        Image(nsImage: model.artwork.image(for: game, role: .cover) ?? NSImage(contentsOf: game.iconURL) ?? NSWorkspace.shared.icon(forFile: game.url.path))
            .resizable().interpolation(.high).scaledToFit().padding(12)
            .accessibilityHidden(true)
    }
}

private struct GameHeroArtwork: View {
    @Environment(AppModel.self) private var model
    let game: MacGameBundle

    var body: some View {
        Image(nsImage: model.artwork.image(for: game, role: .hero)
              ?? model.artwork.image(for: game, role: .cover)
              ?? NSImage(contentsOf: game.iconURL)
              ?? NSWorkspace.shared.icon(forFile: game.url.path))
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .accessibilityHidden(true)
    }
}

struct ConsoleEmptyLibrary: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 46))
            Text("Tu biblioteca empieza aquí").font(.title2.weight(.semibold))
            Text("Abre Configuración → Taller para preparar un juego,\no Configuración → Global para elegir la carpeta de tus apps.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
