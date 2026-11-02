import NXCore
import SwiftUI

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedGameID: MacGameBundle.ID?
    @State private var navigation = ConsoleNavigation()
    @State private var store: GameSettingsStore?
    @State private var tail: LogTail?
    @FocusState private var libraryFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ConsoleTopBar(panel: $navigation.page, game: selectedGame)
                    .disabled(model.gamepad.dialogPresented)
                if navigation.page == .games, !model.games.isEmpty {
                    GameCarouselView(games: model.games, selection: $selectedGameID,
                                     configure: { game in
                        selectedGameID = game.id
                        handle(.configure)
                    })
                }
                activePanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                ConsoleCommandBar(page: navigation.page, hasGame: selectedGame != nil,
                                  canPlay: selectedGame.map { !model.isBuildingGame($0) } ?? false,
                                  action: handle)
                    .disabled(model.gamepad.dialogPresented)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            // Artwork is a background, never a participant in window measurement.
            .background { ConsoleBackdrop(game: selectedGame).clipped() }
            .clipped()
        }
        .preferredColorScheme(.dark)
        .focusable()
        .focusEffectDisabled()
        .focused($libraryFocused)
        .onKeyPress(.leftArrow) { libraryKey(.left) }
        .onKeyPress(.rightArrow) { libraryKey(.right) }
        .onKeyPress(.return, phases: .down) { _ in libraryKey(.primary) }
        .focusedSceneValue(\.consoleConfigurationAction, { handle(.configure) })
        .onExitCommand {
            handle(.back)
        }
        .onAppear {
            selectFirstIfNeeded()
            libraryFocused = true
        }
        .onChange(of: model.games) { _, _ in selectFirstIfNeeded() }
        .onChange(of: navigation.page) { _, page in
            if page == .games { libraryFocused = true }
        }
        .task(id: selectedGameID) {
            store = selectedGame.map { GameSettingsStore(game: $0) }
        }
        .task(id: navigation.page) {
            tail?.stop()
            tail = nil
            if navigation.page == .log, let game = selectedGame {
                let log = LogTail(url: game.log)
                log.start()
                tail = log
            }
        }
        .onDisappear { tail?.stop() }
        .onChange(of: model.gamepad.sequence) { _, _ in
            handle(model.gamepad.lastAction)
        }
    }

    private var selectedGame: MacGameBundle? {
        model.games.first { $0.id == selectedGameID }
    }

    @ViewBuilder private var activePanel: some View {
        switch navigation.page {
        case .environment:
            ConsolePanelSurface { EnvironmentView(compact: false) }
        case .tools:
            ConsolePanelSurface { WorkshopView(preferredGame: selectedGame) }
        default:
            if let game = selectedGame {
                ConsolePanelContent(panel: navigation.page, game: game,
                                    store: store?.game.id == game.id ? store : nil, tail: tail,
                                    openWorkshop: { navigation.page = .tools })
                    .id(game.id)
            } else {
                ConsoleEmptyLibrary()
            }
        }
    }

    private func libraryKey(_ action: ConsoleAction) -> KeyPress.Result {
        guard navigation.page == .games, !model.gamepad.dialogPresented else { return .ignored }
        handle(action)
        return .handled
    }

    private func selectFirstIfNeeded() {
        if selectedGame == nil { selectedGameID = model.games.first?.id }
        if selectedGame == nil, navigation.page != .games { navigation.page = .environment }
    }

    private func handle(_ action: ConsoleAction) {
        if navigation.page == .tools, model.workshopInput?(action) == true { return }
        guard !model.gamepad.dialogPresented else { return }
        switch navigation.handle(action, hasGame: selectedGame != nil) {
        case .none: break
        case .moveGame(let delta):
            guard !model.games.isEmpty else { return }
            let current = model.games.firstIndex { $0.id == selectedGameID } ?? 0
            selectedGameID = model.games[min(max(0, current + delta), model.games.count - 1)].id
        case .play:
            if let game = selectedGame { model.play(game) }
        case .closeGame:
            _ = model.runner.stopCurrent()
        }
    }
}
