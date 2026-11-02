import Foundation

/// Un `env.txt` de nxnative: una línea `KEY=VALUE` por variable, `#` empieza
/// un comentario. Replica `env_file()` de `dm/mac/launcher.c`:
///
/// - se quitan los espacios del principio y los del final de la línea;
/// - la clave pierde los espacios de su final; el valor se queda como está;
/// - una línea sin `=`, o con `=` en la primera posición, se ignora;
/// - **gana la primera aparición** de una clave (el lanzador usa
///   `setenv(..., 0)` y no pisa lo ya puesto).
///
/// Las líneas que no son nuestras se conservan en su sitio: el jugador puede
/// tener interruptores de diagnóstico escritos a mano en el mismo archivo.
public struct EnvFile: Sendable, Equatable {
    public enum Line: Sendable, Equatable {
        case entry(key: String, value: String)
        case other(String)
    }

    public var lines: [Line]

    public init() { lines = [] }

    public init(text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let s = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
            guard !s.hasPrefix("#"), let eq = s.firstIndex(of: "="), eq != s.startIndex else {
                return .other(String(raw))
            }
            let key = s[s.startIndex..<eq].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            return .entry(key: key, value: String(s[s.index(after: eq)...]))
        }
        // `split` deja una línea vacía final si el texto termina en salto.
        if case .other("") = lines.last { lines.removeLast() }
    }

    public init(contentsOf url: URL) {
        self.init(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    public var text: String {
        guard !lines.isEmpty else { return "" }
        return lines.map {
            switch $0 {
            case let .entry(key, value): return "\(key)=\(value)"
            case let .other(s): return s
            }
        }.joined(separator: "\n") + "\n"
    }

    /// Las variables tal y como las vería el lanzador: la primera gana.
    public var effective: [String: String] {
        var d: [String: String] = [:]
        for case let .entry(key, value) in lines where d[key] == nil { d[key] = value }
        return d
    }

    public var keys: [String] {
        var seen = Set<String>()
        return lines.compactMap {
            guard case let .entry(key, _) = $0, seen.insert(key).inserted else { return nil }
            return key
        }
    }

    /// Asignar nil quita todas las apariciones de la clave. Asignar un valor
    /// reescribe la primera y quita las demás (que el lanzador ignoraba igual).
    public subscript(key: String) -> String? {
        get { effective[key] }
        set {
            var replaced = false
            lines = lines.compactMap { line in
                guard case let .entry(k, _) = line, k == key else { return line }
                guard let newValue, !replaced else { return nil }
                replaced = true
                return .entry(key: key, value: newValue)
            }
            if let newValue, !replaced { lines.append(.entry(key: key, value: newValue)) }
        }
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
