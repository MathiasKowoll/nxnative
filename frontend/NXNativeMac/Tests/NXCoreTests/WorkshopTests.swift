import Foundation
import Testing
@testable import NXCore

@Suite("Workshop state")
struct WorkshopTests {
    @Test func focusSurvivesChangesAndClampsAtEdges() {
        var focus = WorkshopFocus(selected: "second")
        focus.reconcile(["first", "second", "third"])
        #expect(focus.selected == "second")
        focus.move(10, in: ["first", "second", "third"])
        #expect(focus.selected == "third")
        focus.reconcile(["first"])
        #expect(focus.selected == "first")
        focus.move(-1, in: [])
        #expect(focus.selected == nil)
    }

    @Test func workerPolicyIsBoundedForAllCompilers() {
        for (requested, expected) in [(-10, "1"), (1, "1"), (2, "2"), (3, "2"), (4, "4"), (5, "4"), (6, "6"), (100, "6")] {
            let env = WorkshopBuild.environment(workers: requested)
            #expect(env["J"] == expected)
            #expect(env["DM_REWRITE_J"] == expected)
            #expect(env["MAKEFLAGS"] == "-j" + expected)
            #expect(env["DOTNET_PROCESSOR_COUNT"] == expected)
        }
        #expect(WorkshopBuild.adjustedWorkers(1, delta: 1) == 2)
        #expect(WorkshopBuild.adjustedWorkers(2, delta: 1) == 4)
        #expect(WorkshopBuild.adjustedWorkers(4, delta: 1) == 6)
        #expect(WorkshopBuild.adjustedWorkers(6, delta: 1) == 1)
        #expect(WorkshopBuild.adjustedWorkers(1, delta: -1) == 6)
    }

    @Test func historySharesSQLiteWithoutChangingGameSettings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = ConfigurationDatabase(url: folder.appendingPathComponent("configuration.sqlite"))
        let env = folder.appendingPathComponent("env.txt")
        try Data("DM_METAL_HUD=1\n".utf8).write(to: env)
        _ = try db.loadOrImport(titleID: "0100000000000000", envURL: env)
        let record = WorkshopBuild(title: "Test", folder: folder, arguments: ["script", "-k", "path only"], status: .running)
        try db.saveBuildHistory([record])
        let loaded = try db.loadBuildHistory()
        #expect(loaded == [record])
        #expect(loaded.first?.recovered.status == .interrupted)
        #expect(try String(contentsOf: env, encoding: .utf8) == "DM_METAL_HUD=1\n")
        try db.saveBuildHistory([])
        #expect(try db.loadBuildHistory().isEmpty)
    }
}
