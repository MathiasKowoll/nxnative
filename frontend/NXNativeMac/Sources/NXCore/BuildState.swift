import Foundation

/// Una etapa del build, como la cuenta el script.
public struct StageState: Identifiable, Sendable, Equatable {
    public var k: Int
    public var name: String
    public var step: String = ""
    public var progress: BuildProgress?
    /// nil mientras corre.
    public var ok: Bool?
    public var summary: String = ""
    public var elapsed: Double?
    public var id: Int { k }
}

public struct BuildMessage: Identifiable, Sendable, Equatable {
    public let id: Int
    public var time: Date
    public var text: String
    public var isError: Bool { BuildEventParser.isError(text) }
}

/// Lo que se sabe de un build a partir de sus eventos. Es un valor puro para
/// poder reproducir en pruebas la salida real del script.
public struct BuildState: Sendable, Equatable {
    public private(set) var stages: [StageState] = []
    /// `n` puede crecer a mitad del build (el chequeo de heap de un perfil
    /// provisional añade etapas): se guarda el mayor visto.
    public private(set) var stageCount = 0
    public private(set) var messages: [BuildMessage] = []
    public var maxMessages = 4000
    private var nextID = 0

    public init() {}

    public var current: StageState? { stages.last }
    public var lastError: String? { messages.last(where: \.isError)?.text }

    /// Fracción global aproximada: etapas terminadas más la fracción de la
    /// actual, sobre el total conocido. Orientativa.
    public var overallFraction: Double? {
        guard stageCount > 0 else { return nil }
        let done = Double(stages.filter { $0.ok != nil }.count)
        let partial = stages.last.flatMap { $0.ok == nil ? $0.progress?.fraction : nil } ?? 0
        return min(1, (done + partial) / Double(stageCount))
    }

    /// Una línea de stdout. Lo que no es un evento se guarda como mensaje.
    public mutating func apply(line: String) {
        if let e = BuildEventParser.parse(line) {
            apply(e)
        } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
            note(line)
        }
    }

    public mutating func apply(_ e: TimedBuildEvent) {
        switch e.event {
        case let .stage(k, n, name, step):
            stageCount = max(stageCount, n, k)
            if let i = index(k) {
                stages[i].name = name; stages[i].step = step
            } else {
                stages.append(StageState(k: k, name: name, step: step))
            }
        case let .step(k, _, step):
            // Un paso nuevo empieza sin cuenta.
            if let i = index(k) { stages[i].step = step; stages[i].progress = nil }
        case let .progress(p):
            if let i = index(p.k) { stages[i].progress = p; stages[i].step = p.step }
        case let .stageEnd(k, _, ok, summary, elapsed):
            if let i = index(k) {
                stages[i].ok = ok; stages[i].summary = summary
                stages[i].elapsed = elapsed; stages[i].progress = nil
            }
        case let .say(msg):
            note(msg, time: e.time)
        case let .unknown(ev, raw):
            note("[\(ev)] \(raw)", time: e.time)
        }
    }

    public mutating func note(_ text: String, time: Date? = nil) {
        nextID += 1
        messages.append(BuildMessage(id: nextID, time: time ?? Date(), text: text))
        if messages.count > maxMessages { messages.removeFirst(messages.count - maxMessages) }
    }

    private func index(_ k: Int) -> Int? { stages.firstIndex { $0.k == k } }
}
