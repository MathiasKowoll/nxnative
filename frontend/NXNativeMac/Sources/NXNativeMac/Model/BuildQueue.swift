import AppKit
import Foundation
import NXCore
import Observation

/// Un build de `build_ipa_from_nsp.py`, lanzado con `--progress json`.
@MainActor @Observable
final class BuildJob: Identifiable {
    enum Status: Equatable { case queued, running, succeeded, failed(Int32), cancelled }

    let id = UUID()
    let title: String
    /// La carpeta NSP del juego: de ahí salen los logs y las salidas.
    let folder: URL
    /// Los argumentos de python: el script y sus opciones.
    let arguments: [String]
    /// Ejecutable alternativo para builders externos (por ejemplo, el build.sh
    /// de FC26). nil = usar el Python del checkout de nxnative.
    let executable: URL?
    /// Carpeta de trabajo del ejecutable alternativo. nil = el checkout de nxnative.
    let workingDirectory: URL?
    /// La carpeta que enseñar al terminar (la salida, o los resultados).
    let resultDirectory: URL?
    /// `<carpeta>/<title ID>_build/logs`, donde el script deja un log por paso.
    let logsDirectory: URL?
    private(set) var status: Status = .queued
    private(set) var state = BuildState()
    private(set) var stderrTail = ""
    private(set) var started: Date?
    private(set) var finished: Date?

    private var process: Process?
    private var splitter = LineSplitter()

    init(title: String, folder: URL, arguments: [String], resultDirectory: URL? = nil, logsDirectory: URL? = nil,
         executable: URL? = nil, workingDirectory: URL? = nil) {
        self.title = title
        self.folder = folder
        self.arguments = arguments
        self.resultDirectory = resultDirectory
        self.logsDirectory = logsDirectory
        self.executable = executable
        self.workingDirectory = workingDirectory
    }

    var isActive: Bool { status == .queued || status == .running }
    var stages: [StageState] { state.stages }
    var stageCount: Int { state.stageCount }
    var messages: [BuildMessage] { state.messages }
    var overallFraction: Double? { state.overallFraction }
    var lastError: String? { state.lastError }

    func start(python: String, repository: URL) {
        let p = Process()
        let program = executable ?? URL(fileURLWithPath: python)
        p.executableURL = program
        p.arguments = arguments
        p.currentDirectoryURL = workingDirectory ?? repository
        var env = Shell.environment(extraPath: [URL(fileURLWithPath: python).deletingLastPathComponent().path,
                                                 program.deletingLastPathComponent().path])
        env["PYTHONUNBUFFERED"] = "1"
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
            status = .running
            started = Date()
            append("$ \(([program.path] + (p.arguments ?? [])).joined(separator: " "))")
        } catch {
            append(BuildEventParser.redPrefix + "No se pudo lanzar el builder: \(error.localizedDescription)")
            status = .failed(-1)
            finished = Date()
        }
    }

    /// SIGINT, como un Ctrl-C: el script sale con 130 y deja lo reutilizable.
    func cancel() {
        guard let process, process.isRunning else {
            if status == .queued { status = .cancelled }
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
        if code == 0 { status = .succeeded }
        else if code == 130 || bySignal { status = .cancelled }
        else { status = .failed(code) }
        process = nil
        NSApp.requestUserAttention(.informationalRequest)
    }
}

/// Los builds van de uno en uno: cada uno usa todos los núcleos y el disco.
@MainActor @Observable
final class BuildQueue {
    private(set) var jobs: [BuildJob] = []

    var active: BuildJob? { jobs.first { $0.status == .running } }
    var pendingCount: Int { jobs.filter(\.isActive).count }

    func enqueue(_ job: BuildJob, python: String, repository: URL) {
        jobs.insert(job, at: 0)
        pump(python: python, repository: repository)
    }

    func clearFinished() { jobs.removeAll { !$0.isActive } }

    /// Lanza el siguiente en cola si no hay ninguno corriendo, y vuelve a
    /// mirar cuando termina el actual.
    private func pump(python: String, repository: URL) {
        updateBadge()
        guard active == nil, let next = jobs.last(where: { $0.status == .queued }) else { return }
        next.start(python: python, repository: repository)
        observe(next, python: python, repository: repository)
    }

    private func observe(_ job: BuildJob, python: String, repository: URL) {
        withObservationTracking { _ = job.status } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if job.isActive { self.observe(job, python: python, repository: repository) }
                else { self.pump(python: python, repository: repository) }
            }
        }
    }

    private func updateBadge() {
        let n = pendingCount
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }
}
