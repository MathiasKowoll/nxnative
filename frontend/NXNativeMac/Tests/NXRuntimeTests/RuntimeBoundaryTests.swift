import Foundation
import NXCore
import NXRuntime
import Testing

@Suite("Runtime boundary")
struct RuntimeBoundaryTests {
    @MainActor @Test func runtimeModuleIsIndependentFromSwiftUI() {
        // Loading a runtime value from its own module protects the package
        // boundary: views depend on NXRuntime, never the other way around.
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(6, forKey: "buildWorkers")
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.buildWorkers == 6)
        preferences.buildWorkers = 5
        #expect(preferences.buildWorkers == 4)
        #expect(defaults.integer(forKey: "buildWorkers") == 4)
    }
}
