import Foundation
import Testing
import NXCore
@testable import NXNativeMac

@Suite("Workshop process queue", .serialized)
@MainActor struct BuildQueueTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(condition(), "The lightweight test process did not finish within five seconds")
    }

    @Test func failedJobDoesNotBlockNextAndHistoryRecovers() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = ConfigurationDatabase(url: folder.appendingPathComponent("history.sqlite"))
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let queue = BuildQueue(database: db)
        let failed = BuildJob(title: "Fails", folder: folder, arguments: ["-c", "exit 7"], executable: URL(fileURLWithPath: "/bin/sh"))
        let passed = BuildJob(title: "Passes", folder: folder,
                              arguments: ["-c", "test \"$J\" = 1 && test \"$DM_REWRITE_J\" = 1"],
                              executable: URL(fileURLWithPath: "/bin/sh"))
        queue.enqueue(failed, python: "/usr/bin/python3", repository: folder)
        queue.enqueue(passed, python: "/usr/bin/python3", repository: folder)
        try await waitUntil { queue.pendingCount == 0 }
        #expect(failed.status == .failed(7))
        #expect(passed.status == .succeeded)
        #expect(try db.loadBuildHistory().count == 2)
        let recovered = BuildQueue(database: db)
        #expect(recovered.pendingCount == 0)
        #expect(recovered.jobs.contains { $0.status == .succeeded })
    }

    @Test func cancelDuringPreparationNeverLaunchesProcess() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let queue = BuildQueue(database: ConfigurationDatabase(url: folder.appendingPathComponent("history.sqlite")))
        queue.beforeStart = { _ in try? await Task.sleep(for: .milliseconds(100)); return nil }
        let marker = folder.appendingPathComponent("unexpected")
        let job = BuildJob(title: "Cancelled", folder: folder, arguments: [marker.path], executable: URL(fileURLWithPath: "/usr/bin/touch"))
        queue.enqueue(job, python: "/usr/bin/python3", repository: folder)
        queue.cancelAll()
        try await Task.sleep(for: .milliseconds(200))
        #expect(job.status == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func restoredActiveWorkRequiresExplicitRetry() throws {
        let record = WorkshopBuild(title: "Interrupted", folder: URL(fileURLWithPath: "/tmp"), arguments: [], status: .running)
        let job = BuildJob(record: record)
        #expect(job.status == .interrupted)
        #expect(!job.isActive)
        let retry = job.retryCopy()
        #expect(retry.id != job.id)
        #expect(retry.status == .queued)
    }

    @Test func activeProcessCancelsAndNoQueuedJobEscapesCancelAll() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let queue = BuildQueue(database: ConfigurationDatabase(url: folder.appendingPathComponent("history.sqlite")))
        let active = BuildJob(title: "Waits for cancellation", folder: folder,
                              arguments: ["-c", "trap 'exit 130' INT; echo ready; while :; do sleep 0.05; done"],
                              executable: URL(fileURLWithPath: "/bin/sh"))
        let marker = folder.appendingPathComponent("unexpected")
        let queued = BuildJob(title: "Queued", folder: folder, arguments: [marker.path], executable: URL(fileURLWithPath: "/usr/bin/touch"))
        queue.enqueue(active, python: "/usr/bin/python3", repository: folder)
        queue.enqueue(queued, python: "/usr/bin/python3", repository: folder)
        try await waitUntil { active.messages.contains { $0.text == "ready" } }
        queue.cancelAll()
        try await waitUntil { queue.pendingCount == 0 }
        #expect(active.status == .cancelled)
        #expect(queued.status == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
