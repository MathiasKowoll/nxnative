import Foundation

/// `dm/launcher.json` de una app empaquetada: los ajustes que admite su juego,
/// escritos por `dm/games/settings.py` desde `dm/games/settings.tsv`.
public struct LauncherSettings: Codable, Sendable, Equatable {
    public var game: String
    public var settings: [Setting]

    public init(game: String, settings: [Setting]) {
        self.game = game; self.settings = settings
    }

    public static func load(from url: URL) throws -> LauncherSettings {
        try JSONDecoder().decode(LauncherSettings.self, from: Data(contentsOf: url))
    }

    /// Las secciones en el orden en que las enseña la app del iPhone; una que
    /// no conocemos va al final, no se pierde.
    public static let sectionOrder = ["Game", "Controls", "Performance"]

    public var sections: [(name: String, settings: [Setting])] {
        var names = Self.sectionOrder.filter { s in settings.contains { $0.section == s } }
        for s in settings where !names.contains(s.section) { names.append(s.section) }
        return names.map { n in (n, settings.filter { $0.section == n }) }
    }
}

public struct Setting: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case choice, range, toggle }

    public var env: String
    public var kind: Kind
    public var section: String
    public var label: String
    public var note: String
    /// El valor con el que se probó el juego, ya como lo toma la variable.
    public var defaultValue: String
    public var options: [[String]]?
    public var min: Double?
    public var max: Double?
    public var step: Double?
    public var on: String?
    public var off: String?

    public var id: String { env }

    enum CodingKeys: String, CodingKey {
        case env, kind, section, label, note, options, min, max, step, on, off
        case defaultValue = "default"
    }

    public init(env: String, kind: Kind, section: String, label: String, note: String = "",
                defaultValue: String, options: [[String]]? = nil, min: Double? = nil,
                max: Double? = nil, step: Double? = nil, on: String? = nil, off: String? = nil) {
        self.env = env; self.kind = kind; self.section = section; self.label = label
        self.note = note; self.defaultValue = defaultValue; self.options = options
        self.min = min; self.max = max; self.step = step; self.on = on; self.off = off
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        env = try c.decode(String.self, forKey: .env)
        kind = try c.decode(Kind.self, forKey: .kind)
        section = try c.decodeIfPresent(String.self, forKey: .section) ?? "Game"
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? env
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        // `default` es una cadena hoy; se acepta también un número por si acaso.
        if let s = try? c.decode(String.self, forKey: .defaultValue) {
            defaultValue = s
        } else if let d = try? c.decode(Double.self, forKey: .defaultValue) {
            defaultValue = String(d)
        } else {
            defaultValue = ""
        }
        options = try c.decodeIfPresent([[String]].self, forKey: .options)
        min = try c.decodeIfPresent(Double.self, forKey: .min)
        max = try c.decodeIfPresent(Double.self, forKey: .max)
        step = try c.decodeIfPresent(Double.self, forKey: .step)
        on = try c.decodeIfPresent(String.self, forKey: .on)
        off = try c.decodeIfPresent(String.self, forKey: .off)
    }

    /// Las opciones de un `choice` como pares (valor, etiqueta).
    public var choices: [(value: String, label: String)] {
        (options ?? []).compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
    }

    /// Decimales que pide el paso de un `range` (0,05 → 2).
    public var decimals: Int {
        guard let step, step > 0 else { return 2 }
        var d = 0
        var s = step
        while d < 6 && abs(s - s.rounded()) > 1e-9 { s *= 10; d += 1 }
        return d
    }

    /// Formatea un valor de `range` como lo escribiría el TSV: con punto y los
    /// decimales del paso, al menos uno (`1.0`, no `1`).
    public func format(range value: Double) -> String {
        String(format: "%.\(Swift.max(decimals, 1))f", value)
    }

    /// Un valor equivale al probado: para un `range`, numéricamente
    /// (`1` y `1.0` son lo mismo); en lo demás, la cadena exacta.
    public func isDefault(_ value: String) -> Bool {
        if kind == .range, let a = Double(value), let b = Double(defaultValue) {
            return abs(a - b) < 1e-9
        }
        return value == defaultValue
    }
}
