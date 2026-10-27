import Foundation

/// Un title ID de Switch: 16 dígitos hexadecimales.
///
/// El juego base tiene los 12 bits bajos a cero; su actualización, `base |
/// 0x800`; un DLC, `base + 0x1000 + índice`. Es la misma regla que usa
/// `scan_nsps()` del script.
public struct TitleID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let value: UInt64

    public init?(_ text: some StringProtocol) {
        guard text.count == 16, let v = UInt64(text, radix: 16) else { return nil }
        value = v
    }

    public init(value: UInt64) { self.value = value }

    public var description: String { String(format: "%016llX", value) }

    public enum Kind: Sendable { case base, update, addOn }

    public var kind: Kind {
        switch value & 0xFFF {
        case 0: return .base
        case 0x800: return .update
        default: return .addOn
        }
    }

    public var base: TitleID {
        switch kind {
        case .base: return self
        case .update: return TitleID(value: value & ~0xFFF)
        case .addOn: return TitleID(value: (value - 0x1000) & ~0xFFF)
        }
    }

    public static func < (a: TitleID, b: TitleID) -> Bool { a.value < b.value }
}

/// Un archivo de juego (.nsp, .nsz, .xci, .xcz) y lo que se sabe de él sin
/// claves.
public struct GameFile: Sendable, Hashable, Identifiable {
    public enum Source: String, Sendable { case ticket, fileName, assigned }

    public var url: URL
    public var size: Int64
    public var titleID: TitleID?
    /// De dónde salió el title ID. El ticket gana al nombre, como en
    /// `title_of()` del script: la etiqueta del nombre puede estar mal.
    public var source: Source?
    /// La versión interna (v0 = base, v65536 = 1.0.1…), del nombre.
    public var version: Int?
    /// Solo para un cartucho.
    public var xci: Containers.XCIInfo?

    public var id: URL { url }
    public var ext: String { url.pathExtension.lowercased() }
    public var isCartridge: Bool { ext == "xci" || ext == "xcz" }

    public static let extensions: Set<String> = ["nsp", "nsz", "xci", "xcz"]

    // Title ID: 16 hex que empiezan por 01, con o sin corchetes, en mayúsculas
    // o minúsculas (`[0100…]`, `_0100…_`, `…175f002`).
    private static let idPattern = try! NSRegularExpression(pattern: #"(?<![0-9A-Fa-f])(01[0-9A-Fa-f]{14})(?![0-9A-Fa-f])"#)
    // Versión: `[v123]`, `_v123_`, ` v123`.
    private static let versionPattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])v(\d{1,10})(?!\d)"#)

    /// Lee del nombre y, si `readHeaders`, de las cabeceras sin cifrar.
    public init(url: URL, size: Int64, readHeaders: Bool = true) {
        self.url = url
        self.size = size
        let name = url.lastPathComponent
        let range = NSRange(name.startIndex..., in: name)
        if let m = Self.idPattern.firstMatch(in: name, range: range), let r = Range(m.range(at: 1), in: name) {
            titleID = TitleID(name[r]); source = .fileName
        }
        if let m = Self.versionPattern.firstMatch(in: name, range: range), let r = Range(m.range(at: 1), in: name) {
            version = Int(name[r])
        }
        guard readHeaders, size > 0 else { return }
        if isCartridge {
            xci = Containers.xciInfo(url)
        } else if let names = Containers.pfs0Names(url), let t = Containers.ticketTitleIDs(names).first {
            titleID = t; source = .ticket
        }
    }

    /// El title ID que el jugador asignó a mano (un XCI sin etiqueta).
    public func assigning(_ id: TitleID) -> GameFile {
        var f = self
        f.titleID = id; f.source = .assigned
        return f
    }
}

/// Un juego tal y como está en disco: sus archivos, estén donde estén.
public struct GameEntry: Sendable, Hashable, Identifiable {
    public var base: TitleID
    public var files: [GameFile]
    /// La carpeta que se le puede dar al script tal cual: todos los archivos
    /// del juego están en ella y no hay archivos de otro juego. nil = hay que
    /// preparar una (ver `PreparedFolder`).
    public var ownFolder: URL?
    /// La carpeta de juegos (de las configuradas) donde se encontró.
    public var root: URL?

    public var id: TitleID { base }

    public var baseFiles: [GameFile] { files.filter { $0.titleID?.kind == .base } }
    public var updates: [GameFile] { files.filter { $0.titleID?.kind == .update } }
    public var addOns: [GameFile] { files.filter { $0.titleID?.kind == .addOn } }
    public var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
    public var hasBase: Bool { !baseFiles.isEmpty }

    /// Los paquetes que puede elegir `-p`: `v0` y las versiones de las
    /// actualizaciones, de mayor a menor.
    public var packages: [String] {
        let vs = Set([0] + updates.compactMap(\.version))
        return vs.sorted(by: >).map { "v\($0)" }
    }

    /// Un nombre para enseñar, sacado del archivo base (o del primero).
    public var displayName: String {
        GameLibrary.cleanName((baseFiles.first ?? files.first)?.url.deletingPathExtension().lastPathComponent ?? base.description)
    }

    public var warnings: [String] {
        var w: [String] = []
        if !hasBase { w.append("Falta el juego base: solo hay actualizaciones o DLC.") }
        if baseFiles.count > 1 { w.append("Hay \(baseFiles.count) archivos de juego base; nxnative usará solo uno.") }
        for f in baseFiles where f.xci?.carriesMoreThanBase == true {
            w.append("\(f.url.lastPathComponent) trae \(f.xci!.contentMetaCount) contenidos en el cartucho (base más actualización o DLC). nxnative solo usa la base: la actualización tiene que estar como NSP aparte.")
        }
        return w
    }
}

public struct LibraryScan: Sendable {
    public var games: [GameEntry]
    /// Archivos sin title ID legible: un XCI sin etiqueta en el nombre.
    public var unidentified: [GameFile]
}

public enum GameLibrary {
    /// Carpetas que no se recorren: las del script (pueden pesar decenas de
    /// GB), los bundles y la carpeta de juegos preparados.
    static func skip(_ name: String) -> Bool {
        name.hasSuffix("_build") || name.hasSuffix("-work") || name.hasSuffix("_survey")
            || name == PreparedFolder.directoryName || name.hasSuffix(".app")
    }

    /// Todos los archivos de juego bajo `root`, hasta `depth` niveles.
    public static func collect(root: URL, depth: Int = 3, readHeaders: Bool = true) -> [GameFile] {
        var out: [GameFile] = []
        func visit(_ dir: URL, _ level: Int) {
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isPackageKey, .isSymbolicLinkKey]
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
            for item in items {
                let rv = try? item.resourceValues(forKeys: Set(keys))
                if rv?.isDirectory == true {
                    if level < depth, rv?.isPackage != true, !skip(item.lastPathComponent) { visit(item, level + 1) }
                } else if rv?.isSymbolicLink != true, GameFile.extensions.contains(item.pathExtension.lowercased()) {
                    out.append(GameFile(url: item, size: Int64(rv?.fileSize ?? 0), readHeaders: readHeaders))
                }
            }
        }
        visit(root, 0)
        return out
    }

    /// Agrupa por title ID base. `assigned` son los title IDs que el jugador
    /// dio a mano, por ruta.
    public static func group(_ files: [GameFile], assigned: [String: TitleID] = [:]) -> LibraryScan {
        var byBase: [TitleID: [GameFile]] = [:]
        var unidentified: [GameFile] = []
        for var f in files where f.size > 0 {
            if f.titleID == nil, let a = assigned[f.url.path] { f = f.assigning(a) }
            if let t = f.titleID { byBase[t.base, default: []].append(f) } else { unidentified.append(f) }
        }
        // Qué juegos tienen archivos en cada carpeta: una carpeta compartida no
        // vale como carpeta del juego, porque el script exige uno por carpeta.
        var gamesInDir: [URL: Set<TitleID>] = [:]
        for (base, fs) in byBase { for f in fs { gamesInDir[f.url.deletingLastPathComponent(), default: []].insert(base) } }
        for f in unidentified { gamesInDir[f.url.deletingLastPathComponent(), default: []].insert(TitleID(value: 0)) }

        let games = byBase.map { base, fs -> GameEntry in
            let dirs = Set(fs.map { $0.url.deletingLastPathComponent() })
            let own = dirs.count == 1 && gamesInDir[dirs.first!] == [base] ? dirs.first : nil
            return GameEntry(base: base, files: fs.sorted { ($0.titleID ?? $0.base0, $0.version ?? 0) < ($1.titleID ?? $1.base0, $1.version ?? 0) }, ownFolder: own)
        }
        return LibraryScan(games: games.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending },
                           unidentified: unidentified.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent })
    }

    /// `The_Legend_of_Zelda_[0100…][v0][rpg].nsp` → `The Legend of Zelda`.
    public static func cleanName(_ stem: String) -> String {
        var s = stem.replacingOccurrences(of: "_", with: " ")
        for p in [#"\[[^\]]*\]"#, #"\([^)]*\)"#, #"(?<![0-9A-Fa-f])01[0-9A-Fa-f]{14}(?![0-9A-Fa-f])"#, #"(?<![A-Za-z0-9])v\d+(?!\d)"#] {
            s = s.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "-.")))
    }

    /// Para comparar nombres: minúsculas, sin acentos ni puntuación.
    public static func normalize(_ s: String) -> String {
        cleanName(s).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Un juego de la tabla de compatibilidad con el mismo nombre que el
    /// archivo. Es solo una SUGERENCIA para un XCI sin etiqueta: el jugador
    /// la confirma, y el script comprueba luego los build IDs contra el perfil.
    public static func suggest(for file: GameFile, in table: [CompatibilityEntry]) -> CompatibilityEntry? {
        let n = normalize(file.url.deletingPathExtension().lastPathComponent)
        guard !n.isEmpty else { return nil }
        let matches = table.filter { normalize($0.name) == n }
        return matches.count == 1 ? matches[0] : nil
    }
}

private extension GameFile {
    var base0: TitleID { TitleID(value: 0) }
}
