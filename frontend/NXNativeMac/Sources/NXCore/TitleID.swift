import Foundation

/// Un title ID de Switch: 16 dígitos hexadecimales.
///
/// El juego base tiene los 12 bits bajos a cero; su actualización, `base |
/// 0x800`; un DLC, `base + 0x1000 + índice`. Es la convención de Horizon, y
/// aquí solo sirve para AGRUPAR archivos en la vista: quien decide de verdad
/// qué perfil se usa es el script de nxnative, leyendo el ticket.
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

/// Un archivo de juego dentro de una carpeta NSP.
public struct GameFile: Sendable, Hashable {
    public var url: URL
    public var titleID: TitleID?
    /// `[vN]` del nombre: la versión interna (v0 = base, v65536 = 1.0.1…).
    public var version: Int?
    public var size: Int64

    public static let extensions: Set<String> = ["nsp", "nsz", "xci", "xcz"]

    private static let idPattern = try! NSRegularExpression(pattern: #"\[([0-9A-Fa-f]{16})\]"#)
    private static let versionPattern = try! NSRegularExpression(pattern: #"\[v(\d+)\]"#)

    public init(url: URL, size: Int64) {
        self.url = url
        self.size = size
        let name = url.lastPathComponent
        let range = NSRange(name.startIndex..., in: name)
        titleID = Self.idPattern.firstMatch(in: name, range: range)
            .flatMap { Range($0.range(at: 1), in: name) }.flatMap { TitleID(name[$0]) }
        version = Self.versionPattern.firstMatch(in: name, range: range)
            .flatMap { Range($0.range(at: 1), in: name) }.flatMap { Int(name[$0]) }
    }
}

/// Una carpeta con los NSP de UN juego, que es lo que recibe el script.
public struct NSPFolder: Sendable, Hashable, Identifiable {
    public var url: URL
    public var files: [GameFile]

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    /// El title ID base que más se repite entre los archivos.
    public var baseTitleID: TitleID? {
        let bases = files.compactMap { $0.titleID?.base }
        return Dictionary(grouping: bases, by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }

    public var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    public var updates: [GameFile] { files.filter { $0.titleID?.kind == .update } }
    public var addOns: [GameFile] { files.filter { $0.titleID?.kind == .addOn } }

    /// Los paquetes que puede elegir `-p`: `v0` y las versiones de las
    /// actualizaciones, de mayor a menor.
    public var packages: [String] {
        let vs = Set(files.filter { $0.titleID?.kind != .addOn }.compactMap(\.version))
        return vs.sorted(by: >).map { "v\($0)" }
    }

    /// `<title ID>_build/`, donde el script deja lo reutilizable y los logs.
    public var buildDirectory: URL? {
        baseTitleID.map { url.appendingPathComponent("\($0)_build", isDirectory: true) }
    }

    public var outputs: [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items.filter { ["ipa", "app"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Recorre `root` hasta `depth` niveles y devuelve cada carpeta que tenga
    /// archivos de juego. No entra en las carpetas `_build`/`-work` del
    /// script ni en bundles `.app`: pueden pesar decenas de GB.
    public static func scan(root: URL, depth: Int = 2) -> [NSPFolder] {
        var found: [NSPFolder] = []
        func visit(_ dir: URL, _ level: Int) {
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isPackageKey]
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
            var files: [GameFile] = []
            for item in items {
                let rv = try? item.resourceValues(forKeys: Set(keys))
                if rv?.isDirectory == true {
                    let n = item.lastPathComponent
                    if level < depth, rv?.isPackage != true,
                       !n.hasSuffix("_build"), !n.hasSuffix("-work"), !n.hasSuffix("_survey") {
                        visit(item, level + 1)
                    }
                } else if GameFile.extensions.contains(item.pathExtension.lowercased()) {
                    files.append(GameFile(url: item, size: Int64(rv?.fileSize ?? 0)))
                }
            }
            if !files.isEmpty {
                found.append(NSPFolder(url: dir, files: files.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }))
            }
        }
        visit(root, 0)
        return found
    }
}
