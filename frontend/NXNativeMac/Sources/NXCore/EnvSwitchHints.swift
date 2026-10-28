import Foundation

/// Lo que la pestaña Avanzado enseña de un interruptor de docs/env_switches.tsv:
/// su grupo, en palabras de jugador, y los valores que su propia descripción
/// nombra, para elegirlos sin escribir.
public extension EnvSwitch {
    enum Group: String, CaseIterable, Sendable {
        case player, setting, diagnostic, test, path

        /// La clase de la tabla (player, switch, diagnostic, test, path).
        init(kind: String) {
            switch kind {
            case "player": self = .player
            case "diagnostic": self = .diagnostic
            case "test": self = .test
            case "path": self = .path
            default: self = .setting
            }
        }

        public var title: String {
            switch self {
            case .player: "Para jugadores"
            case .setting: "Técnicos"
            case .diagnostic: "Diagnóstico"
            case .test: "Pruebas"
            case .path: "Rutas"
            }
        }

        /// Las rutas las pone el lanzador con las carpetas de la app: cambiar
        /// una desde aquí haría que el juego no encuentre sus datos.
        public var offered: Bool { self != .path }
    }

    var group: Group { Group(kind: kind) }

    /// Los valores literales que la descripción nombra entre comillas
    /// invertidas, en orden y sin repetir: «`on` / `off` …» → on, off;
    /// «`display` presents …; `game` follows …» → display, game. Se quedan
    /// fuera los nombres de otros interruptores, rutas, archivos y frases.
    var suggestedValues: [String] {
        var out: [String] = []
        for token in Self.codeSpans(meaning) {
            let t = token.hasPrefix("=") ? String(token.dropFirst()) : token
            let number = Double(t) != nil   // 0.5, 1.0: un valor, aunque lleve punto
            guard !t.isEmpty, t.count <= 16, !t.contains(" "), !t.hasPrefix("DM_"), !t.contains("/"), !t.contains("<"),
                  !t.contains("("), number || !t.contains("."), !t.contains("_") || t.allSatisfy({ $0.isNumber || $0 == "_" }),
                  !out.contains(t) else { continue }
            out.append(t)
            if out.count == 6 { break }
        }
        return out
    }

    /// El formato que pide, cuando la descripción empieza por «`=<algo>`»:
    /// «`=<frames>` splits …» → frames;
    /// o un rango, «`=0..0.9` …» → «de 0 a 0.9».
    var placeholder: String? {
        guard let first = Self.codeSpans(meaning).first else { return nil }
        if first.hasPrefix("=<"), first.hasSuffix(">") { return String(first.dropFirst(2).dropLast()) }
        let r = (first.hasPrefix("=") ? String(first.dropFirst()) : first).components(separatedBy: "..")
        if r.count == 2, Double(r[0]) != nil, Double(r[1]) != nil { return "de \(r[0]) a \(r[1])" }
        return nil
    }

    /// La descripción como texto con formato: lo que va entre comillas
    /// invertidas sale como código.
    var formattedMeaning: AttributedString {
        (try? AttributedString(markdown: meaning, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(meaning)
    }

    internal static func codeSpans(_ text: String) -> [String] {
        var spans: [String] = []; var inside = false; var cur = ""
        for ch in text {
            if ch == "`" { if inside { spans.append(cur); cur = "" }; inside.toggle() } else if inside { cur.append(ch) }
        }
        return spans
    }
}
