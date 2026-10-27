import Foundation

/// Un evento de `build_ipa_from_nsp.py --progress json`: un objeto JSON por
/// línea, con `ev` y `t`. El contrato está en `docs/frontends.md` de nxnative.
public enum BuildEvent: Sendable, Equatable {
    case stage(k: Int, n: Int, name: String, step: String)
    case step(k: Int, name: String, step: String)
    case progress(BuildProgress)
    case stageEnd(k: Int, name: String, ok: Bool, summary: String, elapsed: Double?)
    case say(String)
    /// Un `ev` que esta versión no conoce. Se conserva en vez de tirarlo: si
    /// nxnative añade eventos, que se vean.
    case unknown(ev: String, raw: String)
}

public struct BuildProgress: Sendable, Equatable {
    public var k: Int
    public var name: String
    public var step: String
    public var done: Double?
    public var total: Double?
    /// `''`, `'B'` (bytes), `'files'`…
    public var unit: String
    /// El total es una estimación (el script lo marca con `~`).
    public var estimated: Bool
    public var note: String
    /// De 0 a 0,99, o nil cuando el trabajo no se puede contar.
    public var fraction: Double?
    public var eta: Double?
    public var elapsed: Double?

    public init(k: Int, name: String, step: String, done: Double? = nil, total: Double? = nil,
                unit: String = "", estimated: Bool = false, note: String = "",
                fraction: Double? = nil, eta: Double? = nil, elapsed: Double? = nil) {
        self.k = k; self.name = name; self.step = step; self.done = done; self.total = total
        self.unit = unit; self.estimated = estimated; self.note = note
        self.fraction = fraction; self.eta = eta; self.elapsed = elapsed
    }
}

public struct TimedBuildEvent: Sendable, Equatable {
    public var event: BuildEvent
    public var time: Date?
}

public enum BuildEventParser {
    /// Prefijo de las líneas de error del proyecto.
    public static let redPrefix = "[RED] "

    /// Devuelve nil para una línea que no es un objeto JSON con `ev`: el script
    /// no debería escribir otra cosa en stdout, pero un `print` olvidado no
    /// tiene que tumbar la vista.
    public static func parse(_ line: String) -> TimedBuildEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ev = obj["ev"] as? String else { return nil }
        let time = number(obj["t"]).map { Date(timeIntervalSince1970: $0) }
        let k = Int(number(obj["k"]) ?? 0)
        let name = string(obj["name"])
        let step = string(obj["step"])
        let event: BuildEvent
        switch ev {
        case "stage":
            event = .stage(k: k, n: Int(number(obj["n"]) ?? 0), name: name, step: step)
        case "step":
            event = .step(k: k, name: name, step: step)
        case "progress":
            event = .progress(BuildProgress(
                k: k, name: name, step: step,
                done: number(obj["done"]), total: number(obj["total"]),
                unit: string(obj["unit"]), estimated: (obj["est"] as? Bool) ?? false,
                note: string(obj["note"]), fraction: number(obj["frac"]),
                eta: number(obj["eta"]), elapsed: number(obj["elapsed"])))
        case "stage_end":
            event = .stageEnd(k: k, name: name, ok: (obj["ok"] as? Bool) ?? false,
                              summary: string(obj["summary"]), elapsed: number(obj["elapsed"]))
        case "say":
            event = .say(string(obj["msg"]))
        default:
            event = .unknown(ev: ev, raw: trimmed)
        }
        return TimedBuildEvent(event: event, time: time)
    }

    /// `[RED] ` al principio, o tras la hora que el script antepone a
    /// algunos mensajes (`[12:00:00] [RED] …`).
    public static func isError(_ message: String) -> Bool {
        if message.hasPrefix(redPrefix) { return true }
        guard message.hasPrefix("["), let close = message.firstIndex(of: "]") else { return false }
        return message[message.index(after: close)...].hasPrefix(" " + redPrefix)
    }

    // `null` llega como NSNull y un booleano como NSNumber: solo se aceptan
    // números de verdad.
    static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    static func string(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = number(v) { return n == n.rounded() ? String(Int(n)) : String(n) }
        return ""
    }
}

/// Junta los trozos que llegan de una tubería y entrega líneas completas.
public struct LineSplitter: Sendable {
    private var pending = Data()
    public init() {}

    public mutating func feed(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<nl]
            lines.append(String(decoding: lineData, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        return lines
    }

    /// Lo que quede sin salto de línea al cerrar la tubería.
    public mutating func flush() -> [String] {
        guard !pending.isEmpty else { return [] }
        defer { pending.removeAll() }
        return [String(decoding: pending, as: UTF8.self)]
    }
}
