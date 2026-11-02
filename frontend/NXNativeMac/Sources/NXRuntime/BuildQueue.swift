import AppKit
import Foundation
import NXCore
import Observation

/// Un build de `build_ipa_from_nsp.py`, lanzado con `--progress json`.
@MainActor @Observable
public final class BuildJob: Identifiable {
    public enum Status: Equatable { case queued, running, succeeded, failed(Int32), cancelled, interrupted }

    public let id: UUID
    public var workers = 1
    public var titleID: String?
    var onChange: (() -> Void)?
    public let title: String
    /// La carpeta NSP del juego: de ahí salen los logs y las salidas.
    public let folder: URL
    /// Los argumentos de python: el script y sus opciones.
    public let arguments: [String]
    /// Ejecutable alternativo para builders externos (por ejemplo, el build.sh
    /// de FC26). nil = usar el Python del checkout de nxnative.
    public let executable: URL?
    /// Carpeta de trabajo del ejecutable alternativo. nil = el checkout de nxnative.
    public let workingDirectory: URL?
    /// La carpeta que enseñar al terminar (la salida, o los resultados).
    public let resultDirectory: URL?
    /// `<carpeta>/<title ID>_build/logs`, donde el script deja un log por paso.
    public let logsDirectory: URL?
    public private(set) var status: Status = .queued { didSet { onChange?() } }
    private(set) var state = BuildState()
    public private(set) var stderrTail = ""
    public private(set) var started: Date?
    public private(set) var finished: Date?

    private var process: Process?
    private var previousProcessID: Int32?
    private var splitter = LineSplitter()
    public private(set) var cancellationRequested = false

    public init(title: String, folder: URL, arguments: [String], resultDirectory: URL? = nil, logsDirectory: URL? = nil,
                executable: URL? = nil, workingDirectory: URL? = nil, id: UUID = UUID()) {
        self.id = id
        self.title = title
        self.folder = folder
        self.arguments = arguments
        self.resultDirectory = resultDirectory
        self.logsDirectory = logsDirectory
        self.executable = executable
        self.workingDirectory = workingDirectory
    }

    public convenience init(record: WorkshopBuild) {
        let record = record.recovered
        self.init(title: record.title, folder: record.folder, arguments: record.arguments,
                  resultDirectory: record.resultDirectory, logsDirectory: record.logsDirectory,
                  executable: record.executable, workingDirectory: record.workingDirectory, id: record.id)
        workers = record.workers; titleID = record.titleID
        previousProcessID = record.processID
        started = record.started; finished = record.finished
        switch record.status {
        case .succeeded: status = .succeeded
        case .failed: status = .failed(-1)
        case .cancelled: status = .cancelled
        default: status = .interrupted
        }
        if let error = record.error { state.note(BuildEventParser.redPrefix + error) }
    }

    public var record: WorkshopBuild {
        let savedStatus: WorkshopBuild.Status
        switch status {
        case .queued: savedStatus = .queued
        case .running: savedStatus = .running
        case .succeeded: savedStatus = .succeeded
        case .failed: savedStatus = .failed
        case .cancelled: savedStatus = .cancelled
        case .interrupted: savedStatus = .interrupted
        }
        return WorkshopBuild(id: id, title: title, folder: folder, arguments: arguments,
                             executable: executable, workingDirectory: workingDirectory,
                             resultDirectory: resultDirectory, logsDirectory: logsDirectory,
                             titleID: titleID, workers: workers, status: savedStatus,
                             started: started, finished: finished, error: lastError ?? String(stderrTail.suffix(4000)),
                             processID: process?.processIdentifier ?? previousProcessID)
    }

    public func retryCopy() -> BuildJob {
        let copy = BuildJob(title: title, folder: folder, arguments: arguments, resultDirectory: resultDirectory,
                            logsDirectory: logsDirectory, executable: executable, workingDirectory: workingDirectory)
        copy.workers = workers; copy.titleID = titleID
        return copy
    }

    public var earlierProcessMayBeRunning: Bool {
        guard let pid = previousProcessID, pid > 0 else { return false }
        // A PID alone is not enough identity to terminate anything. Conservatively
        // refuse a retry until the old PID disappears; never signal it here.
        return kill(pid, 0) == 0 || errno == EPERM
    }

    func prepare() {
        started = Date()
        status = .running
    }

    func fail(_ message: String) {
        append(BuildEventParser.redPrefix + message)
        finished = Date()
        status = .failed(-1)
    }

    public var isActive: Bool { status == .queued || status == .running }
    public var stages: [StageState] { state.stages }
    public var stageCount: Int { state.stageCount }
    public var messages: [BuildMessage] { state.messages }
    public var overallFraction: Double? { state.overallFraction }
    public var lastError: String? { state.lastError }

    func start(python: String, repository: URL) {
        guard status == .running, !cancellationRequested else { return }
        let p = Process()
        let program = executable ?? URL(fileURLWithPath: python)
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        p.arguments = ["-n", "10", program.path] + arguments
        p.qualityOfService = .background
        p.currentDirectoryURL = workingDirectory ?? repository
        var env = Shell.environment(extraPath: [URL(fileURLWithPath: python).deletingLastPathComponent().path,
                                                 program.deletingLastPathComponent().path])
        env["PYTHONUNBUFFERED"] = "1"
        env.merge(WorkshopBuild.environment(workers: workers)) { _, bounded in bounded }
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            Task { @MainActor in self?.consume(data) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            Task { @MainActor in self?.consumeStderr(data) }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let rest = out.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor in
                self?.consume(rest)
                self?.finish(code: code)
            }
        }
        do {
            try p.run()
            process = p
            onChange?()
            append("Workers: \(workers); background priority.\n$ \(([program.path] + arguments).joined(separator: " "))")
        } catch {
            fail("No se pudo lanzar el builder: \(error.localizedDescription)")
        }
    }

    /// SIGINT, como un Ctrl-C: el script sale con 130 y deja lo reutilizable.
    public func cancel(reason: String? = nil) {
        if let reason { append(BuildEventParser.redPrefix + reason) }
        cancellationRequested = true
        guard let process, process.isRunning else {
            if isActive { finished = Date(); status = .cancelled }
            return
        }
        process.interrupt()
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        for line in splitter.feed(data) { handle(line) }
    }

    private func consumeStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        stderrTail += String(decoding: data, as: UTF8.self)
        if stderrTail.count > 20_000 { stderrTail = String(stderrTail.suffix(20_000)) }
    }

    private func handle(_ line: String) { state.apply(line: line) }

    private func append(_ text: String) { state.note(text) }

    private func finish(code: Int32) {
        for line in splitter.flush() { handle(line) }
        finished = Date()
        let bySignal = process?.terminationReason == .uncaughtSignal && code == SIGINT
        process = nil
        if cancellationRequested || code == 130 || bySignal { status = .cancelled }
        else if code == 0 { status = .succeeded }
        else { status = .failed(code) }
        NSApp?.requestUserAttention(.informationalRequest)
    }
}

/// One bounded build at a time, with durable history and explicit recovery.
@MainActor @Observable
public final class BuildQueue {
    public private(set) var jobs: [BuildJob] = []
    public private(set) var persistenceError: String?
    public private(set) var memoryPressure = false
    public var beforeStart: ((BuildJob) async -> String?)?
    public var onSuccess: (() -> Void)?
    private var python: String?
    private var repository: URL?
    private var memoryMonitor: (any DispatchSourceMemoryPressure)?
    private let database: ConfigurationDatabase
    private var cancellingAll = false

    public init(database: ConfigurationDatabase = ConfigurationDatabase()) {
        self.database = database
        do { jobs = try database.loadBuildHistory().map(BuildJob.init(record:)) }
        catch { persistenceError = error.localizedDescription }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let critical = self.memoryMonitor?.data.contains(.critical) ?? false
                let warning = self.memoryMonitor?.data.contains(.warning) ?? false
                self.memoryPressure = critical || warning
                if critical { self.active?.cancel(reason: "Build cancelled because macOS reported critical memory pressure.") }
                if !self.memoryPressure { self.pump() }
            }
        }
        source.resume()
        memoryMonitor = source
    }

    public var active: BuildJob? { jobs.first { $0.status == .running } }
    public var pendingCount: Int { jobs.filter(\.isActive).count }

    public func enqueue(_ job: BuildJob, python: String, repository: URL) {
        self.python = python; self.repository = repository
        job.onChange = { [weak self, weak job] in
            guard let self, let job else { return }
            self.save()
            self.updateBadge()
            if !job.isActive {
                if job.status == .succeeded { self.onSuccess?() }
                self.pump()
            }
        }
        jobs.insert(job, at: 0)
        save()
        pump()
    }

    public func clearFinished() { jobs.removeAll { !$0.isActive }; save() }

    public func cancelAll() {
        cancellingAll = true
        // Cancel queued entries first so finishing the active one cannot launch another.
        for job in jobs where job.status == .queued { job.cancel() }
        active?.cancel()
        cancellingAll = false
    }

    private func save() {
        do {
            try database.saveBuildHistory(jobs.filter(\.isActive).map(\.record)
                + jobs.filter { !$0.isActive }.prefix(100).map(\.record))
            persistenceError = nil
        } catch { persistenceError = error.localizedDescription }
    }

    /// Lanza el siguiente en cola si no hay ninguno corriendo, y vuelve a
    /// mirar cuando termina el actual.
    private func pump() {
        updateBadge()
        guard !cancellingAll, !memoryPressure, active == nil, let python, let repository,
              let next = jobs.last(where: { $0.status == .queued }) else { return }
        next.prepare()
        Task { @MainActor [weak self] in
            if let error = await self?.beforeStart?(next) {
                if next.status == .running { next.fail(error) }
            } else {
                next.start(python: python, repository: repository)
            }
        }
    }

    private func updateBadge() {
        let n = pendingCount
        NSApp?.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }
}
