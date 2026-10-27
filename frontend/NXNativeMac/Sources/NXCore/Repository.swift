import Foundation

/// Lo que la app lee de un checkout de nxnative. Solo lectura: nada de aquí
/// cambia el repositorio.
public struct NXRepository: Sendable {
    public var root: URL

    public init(root: URL) { self.root = root }

    public var buildScript: URL { root.appendingPathComponent("scripts/build_ipa_from_nsp.py") }
    public var benchScript: URL { root.appendingPathComponent("scripts/bench.py") }
    public var gamesDirectory: URL { root.appendingPathComponent("dm/games", isDirectory: true) }
    public var gamesReadme: URL { gamesDirectory.appendingPathComponent("README.md") }
    public var chainLock: URL { root.appendingPathComponent("dm/gfx/tools/dmsh_chain.lock") }
    public var envSwitches: URL { root.appendingPathComponent("docs/env_switches.tsv") }

    public var isValid: Bool { FileManager.default.fileExists(atPath: buildScript.path) }

    /// Los perfiles registrados: las carpetas de `dm/games` con nombre de
    /// title ID.
    public func profiles() -> Set<TitleID> {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: gamesDirectory.path)) ?? []
        return Set(items.compactMap { TitleID($0) })
    }

    public func hasBenchRoute(_ id: TitleID) -> Bool {
        FileManager.default.fileExists(
            atPath: gamesDirectory.appendingPathComponent("\(id)/bench.tsv").path)
    }

    public func compatibility() -> [CompatibilityEntry] {
        guard let text = try? String(contentsOf: gamesReadme, encoding: .utf8) else { return [] }
        return CompatibilityEntry.parse(readme: text)
    }

    public func chainLockValues() -> [String: String] {
        guard let text = try? String(contentsOf: chainLock, encoding: .utf8) else { return [:] }
        return ChainLock.parse(text)
    }

    public func switches() -> [EnvSwitch] {
        guard let text = try? String(contentsOf: envSwitches, encoding: .utf8) else { return [] }
        return EnvSwitch.parse(tsv: text)
    }
}

/// Una fila de la tabla de juegos de `dm/games/README.md`.
public struct CompatibilityEntry: Sendable, Hashable, Identifiable {
    public var name: String
    public var titleID: TitleID
    public var build: String
    public var sdk: String
    public var engine: String
    public var graphics: String

    public var id: TitleID { titleID }

    /// La tabla empieza tras la cabecera `| Game | Title ID | …`. Se lee por
    /// columnas con nombre para que reordenarlas no rompa nada.
    public static func parse(readme: String) -> [CompatibilityEntry] {
        var header: [String]?
        var out: [CompatibilityEntry] = []
        for line in readme.split(separator: "\n") {
            guard line.hasPrefix("|") else { header = nil; continue }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
            if header == nil {
                if cells.first == "Game", cells.contains("Title ID") { header = cells }
                continue
            }
            guard let header, cells.count == header.count,
                  !(cells.first?.hasPrefix("---") ?? true) else { continue }
            func col(_ name: String) -> String {
                header.firstIndex(of: name).map { cells[$0] } ?? ""
            }
            guard let id = TitleID(col("Title ID").trimmingCharacters(in: CharacterSet(charactersIn: "`"))) else { continue }
            out.append(CompatibilityEntry(
                name: stripLink(col("Game")), titleID: id, build: col("Build"), sdk: col("SDK"),
                engine: stripLink(col("Engine")), graphics: col("Graphics")))
        }
        return out
    }

    /// `[Nombre](ruta)` → `Nombre`.
    static func stripLink(_ s: String) -> String {
        guard s.hasPrefix("["), let close = s.firstIndex(of: "]") else { return s }
        return String(s[s.index(after: s.startIndex)..<close])
    }
}

public enum ChainLock {
    /// `clave<TAB>valor`, `#` comenta.
    public static func parse(_ text: String) -> [String: String] {
        var d: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            if parts.count == 2 { d[String(parts[0])] = String(parts[1]) }
        }
        return d
    }
}

/// Una fila de `docs/env_switches.tsv`: name, class, meaning.
public struct EnvSwitch: Sendable, Hashable, Identifiable {
    public var name: String
    public var kind: String
    public var meaning: String
    public var id: String { name }

    public static func parse(tsv: String) -> [EnvSwitch] {
        tsv.split(separator: "\n").dropFirst().compactMap { line in
            let c = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard c.count == 3 else { return nil }
            return EnvSwitch(name: String(c[0]), kind: String(c[1]), meaning: String(c[2]))
        }
    }
}
