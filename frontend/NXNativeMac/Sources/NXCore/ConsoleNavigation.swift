/// Shared routing for keyboard and controller input. Only the library can launch.
public enum ConsoleAction: Equatable, Sendable {
    case left, right, up, down, primary, configure, back, previousTab, nextTab, previousSection, nextSection, closeGame
}

public enum ConsolePage: String, CaseIterable, Identifiable, Sendable {
    case games, settings, log, saves, advanced, environment, developer, tools
    public var id: Self { self }
}

public struct ConsoleNavigation: Equatable, Sendable {
    public var page: ConsolePage = .games
    public init() {}
    public enum Effect: Equatable { case none, moveGame(Int), play, closeGame }

    @discardableResult
    public mutating func handle(_ action: ConsoleAction, hasGame: Bool) -> Effect {
        switch action {
        case .configure:
            if page == .games { page = hasGame ? .settings : .environment }
        case .back:
            page = .games
        case .previousTab, .nextTab:
            guard page != .games else { return .none }
            let pages: [ConsolePage] = hasGame
                ? [.settings, .log, .saves, .advanced, .environment, .developer, .tools]
                : [.environment, .developer, .tools]
            let index = pages.firstIndex(of: page) ?? 0
            let delta = action == .nextTab ? 1 : -1
            page = pages[(index + delta + pages.count) % pages.count]
        case .left where page == .games: return hasGame ? .moveGame(-1) : .none
        case .right where page == .games: return hasGame ? .moveGame(1) : .none
        case .primary where page == .games: return hasGame ? .play : .none
        case .closeGame:
            page = .games
            return .closeGame
        default: break
        }
        return .none
    }
}

/// Fallbacks only: actual glyphs come from GameController, including remapping.
public enum ConsoleControllerFamily: Sendable {
    case playStation, nintendo, xbox
    public init(category: String, vendor: String = "") {
        let name = (category + " " + vendor).lowercased()
        if ["dualsense", "dualshock", "playstation"].contains(where: name.contains) {
            self = .playStation
        } else if ["nintendo", "switch", "joy-con"].contains(where: name.contains) {
            self = .nintendo
        } else {
            self = .xbox
        }
    }
    public var primary: String { self == .playStation ? "✕" : "A" }
    public var back: String { self == .playStation ? "○" : "B" }
    public var confirmOnRight: Bool { self == .nintendo }
    public var configure: String { self == .playStation ? "△" : self == .nintendo ? "X" : "Y" }
    public var shoulders: String { self == .playStation ? "L1 / R1" : self == .nintendo ? "L / R" : "LB / RB" }
    public var triggers: String { self == .playStation ? "L2 / R2" : self == .nintendo ? "ZL / ZR" : "LT / RT" }
}
