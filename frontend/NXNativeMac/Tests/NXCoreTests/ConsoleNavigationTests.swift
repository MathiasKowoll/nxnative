import Testing
@testable import NXCore

@Suite("Console navigation")
struct ConsoleNavigationTests {
    @Test func libraryOnlyLaunchesWithPrimary() {
        var navigation = ConsoleNavigation()
        for action in [ConsoleAction.back, .previousTab, .nextTab, .up, .down] {
            #expect(navigation.handle(action, hasGame: true) == .none)
            #expect(navigation.page == .games)
        }
        #expect(navigation.handle(.primary, hasGame: true) == .play)
        #expect(navigation.handle(.left, hasGame: true) == .moveGame(-1))
        #expect(navigation.handle(.right, hasGame: true) == .moveGame(1))
    }

    @Test func settingsNeverLaunchOrMoveGames() {
        var navigation = ConsoleNavigation()
        #expect(navigation.handle(.configure, hasGame: true) == .none)
        #expect(navigation.page == .settings)
        for _ in 0..<12 {
            for action in [ConsoleAction.primary, .left, .right, .configure] {
                #expect(navigation.handle(action, hasGame: true) == .none)
                #expect(navigation.page != .games)
            }
            navigation.handle(.nextTab, hasGame: true)
        }
        #expect(navigation.handle(.back, hasGame: true) == .none)
        #expect(navigation.page == .games)
    }

    @Test func emptyLibraryStillHasGlobalConfiguration() {
        var navigation = ConsoleNavigation()
        #expect(navigation.handle(.primary, hasGame: false) == .none)
        #expect(navigation.handle(.left, hasGame: false) == .none)
        navigation.handle(.configure, hasGame: false)
        #expect(navigation.page == .environment)
        navigation.handle(.nextTab, hasGame: false)
        #expect(navigation.page == .developer)
        navigation.handle(.nextTab, hasGame: false)
        #expect(navigation.page == .tools)
        navigation.handle(.nextTab, hasGame: false)
        #expect(navigation.page == .environment)
    }

    @Test func onlyExplicitExitStopsGame() {
        var navigation = ConsoleNavigation()
        navigation.handle(.configure, hasGame: true)
        #expect(navigation.handle(.back, hasGame: true) == .none)
        #expect(navigation.handle(.back, hasGame: true) == .none)
        #expect(navigation.handle(.closeGame, hasGame: true) == .closeGame)
        #expect(navigation.page == .games)
    }

    @Test func consoleButtonConventions() {
        let sony = ConsoleControllerFamily(category: "DualSense", vendor: "DualSense Edge")
        #expect(sony.configure == "△")
        #expect(sony.primary == "✕")
        #expect(!sony.confirmOnRight)
        let nintendo = ConsoleControllerFamily(category: "HID", vendor: "Nintendo Switch Pro Controller")
        #expect(nintendo.configure == "X")
        #expect(nintendo.primary == "A")
        #expect(nintendo.confirmOnRight)
        let xbox = ConsoleControllerFamily(category: "Xbox One")
        #expect(xbox.configure == "Y")
        #expect(xbox.primary == "A")
        #expect(!xbox.confirmOnRight)
    }

    @Test func analogueTriggerEmitsOncePerPull() {
        var latch = ConsoleTriggerLatch()
        let idle = latch.update(value: 0.2, pressed: false)
        let pulled = latch.update(value: 0.7, pressed: false)
        let held = latch.update(value: 0.5, pressed: false)
        let released = latch.update(value: 0.3, pressed: false)
        let pressedFallback = latch.update(value: 0.0, pressed: true)
        let finalRelease = latch.update(value: 0.0, pressed: false)
        #expect(!idle)
        #expect(pulled)
        #expect(!held)
        #expect(!released)
        #expect(pressedFallback)
        #expect(!finalRelease)
    }
}
