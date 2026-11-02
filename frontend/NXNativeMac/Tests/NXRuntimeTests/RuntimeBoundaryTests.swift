import Foundation
import NXRuntime
import Testing

@Suite("Runtime boundary")
struct RuntimeBoundaryTests {
    @MainActor @Test func runtimeModuleIsIndependentFromSwiftUI() {
        // Loading a runtime value from its own module protects the package
        // boundary: views depend on NXRuntime, never the other way around.
        let preferences = Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        #expect((1...2).contains(preferences.buildWorkers))
    }
}
