import Foundation

/// Durable build metadata. Key paths are stored, never key contents.
public struct WorkshopBuild: Codable, Sendable, Identifiable, Equatable {
    public static let workerOptions = [1, 2, 4, 6]

    public static func normalizedWorkers(_ workers: Int) -> Int {
        workerOptions.min { lhs, rhs in
            abs(lhs - workers) < abs(rhs - workers)
        } ?? 1
    }

    public static func adjustedWorkers(_ workers: Int, delta: Int) -> Int {
        let current = normalizedWorkers(workers)
        let index = workerOptions.firstIndex(of: current) ?? 0
        let count = workerOptions.count
        return workerOptions[(index + delta % count + count) % count]
    }

    public enum Status: String, Codable, Sendable { case queued, running, succeeded, failed, cancelled, interrupted }
    public var id: UUID
    public var title: String
    public var folder: URL
    public var arguments: [String]
    public var executable: URL?
    public var workingDirectory: URL?
    public var resultDirectory: URL?
    public var logsDirectory: URL?
    public var titleID: String?
    public var workers: Int
    public var status: Status
    public var started: Date?
    public var finished: Date?
    public var error: String?
    public var processID: Int32?

    public init(id: UUID = UUID(), title: String, folder: URL, arguments: [String],
                executable: URL? = nil, workingDirectory: URL? = nil, resultDirectory: URL? = nil,
                logsDirectory: URL? = nil, titleID: String? = nil, workers: Int = 1,
                status: Status = .queued, started: Date? = nil, finished: Date? = nil, error: String? = nil, processID: Int32? = nil) {
        self.id = id; self.title = title; self.folder = folder; self.arguments = arguments
        self.executable = executable; self.workingDirectory = workingDirectory
        self.resultDirectory = resultDirectory; self.logsDirectory = logsDirectory
        self.titleID = titleID; self.workers = Self.normalizedWorkers(workers); self.status = status
        self.started = started; self.finished = finished; self.error = error
        self.processID = processID
    }

    /// Never restart expensive work implicitly after a crash or a relaunch.
    public var recovered: Self {
        var copy = self
        copy.workers = Self.normalizedWorkers(copy.workers)
        if status == .running || status == .queued {
            copy.status = .interrupted
            copy.error = "The previous session ended. Review the source and retry explicitly."
        }
        return copy
    }

    public static func environment(workers: Int) -> [String: String] {
        let count = String(normalizedWorkers(workers))
        return ["J": count, "DM_REWRITE_J": count, "MAKEFLAGS": "-j" + count,
                "CMAKE_BUILD_PARALLEL_LEVEL": count, "SWIFT_BUILD_JOBS": count,
                "DOTNET_PROCESSOR_COUNT": count, "OMP_NUM_THREADS": count]
    }
}

/// Shared controller/keyboard selection, stable when jobs or sources change.
public struct WorkshopFocus: Sendable {
    public var selected: String?
    public init(selected: String? = nil) { self.selected = selected }
    public mutating func reconcile(_ rows: [String]) {
        if !rows.contains(selected ?? "") { selected = rows.first }
    }
    public mutating func move(_ delta: Int, in rows: [String]) {
        guard !rows.isEmpty else { selected = nil; return }
        let index = rows.firstIndex(of: selected ?? "") ?? 0
        selected = rows[min(rows.count - 1, max(0, index + delta))]
    }
}
