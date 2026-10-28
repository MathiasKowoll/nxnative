import CryptoKit
import Foundation

/// Lo que va dentro de cada copia, junto a `save/`: para qué juego es y
/// cómo estaba la partida. Permite negarse a importar la partida de otro juego
/// y saltarse una copia automática si nada cambió desde la anterior.
public struct SaveManifest: Codable, Sendable, Equatable {
    public var format = 1
    public var titleID: String
    public var game: String
    public var version: String
    public var created: Date
    /// Huella de los archivos (ruta, tamaño, fecha): igual = misma partida.
    public var fingerprint: String
    public var files: Int
    public var bytes: Int64

    public static let fileName = "nxnative-save.json"
}

/// Copias de las partidas de las apps de juego.
///
/// Las partidas viven en `~/Library/Application Support/nxnative/<title ID>/save`,
/// fuera de la app: reinstalar o reconstruir el juego no las toca. Lo que sí
/// las borra es un desinstalador que limpia Application Support, borrar la
/// carpeta, o cambiar de Mac sin migrarla. Por eso las copias van a una
/// carpeta propia, que el jugador puede llevar a iCloud Drive o a otro disco.
///
/// Cada copia es un zip con `save/` y `nxnative-save.json`. El tipo va en el
/// nombre: `2026-10-27_12-00-00_auto.zip`.
public struct SaveVault: Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// Antes de jugar o de reconstruir; se guardan las `keepAuto` últimas.
        case auto
        /// Pedida por el jugador; nunca se borra sola.
        case manual
        /// La partida que había antes de restaurar o importar otra.
        case beforeRestore = "antes-de-restaurar"
    }

    public struct Entry: Sendable, Hashable, Identifiable {
        public var url: URL
        public var kind: Kind
        public var date: Date
        public var id: URL { url }
    }

    public var root: URL
    public var keepAuto: Int

    public init(root: URL = SaveVault.defaultRoot, keepAuto: Int = 10) {
        self.root = root
        self.keepAuto = keepAuto
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NXNativeMac/Backups", isDirectory: true)
    }

    public func directory(for titleID: String) -> URL {
        root.appendingPathComponent(titleID, isDirectory: true)
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    /// Las copias de un juego, la más nueva primero.
    public func list(_ titleID: String) -> [Entry] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory(for: titleID), includingPropertiesForKeys: nil)) ?? []
        return items.compactMap { url -> Entry? in
            guard url.pathExtension == "zip" else { return nil }
            let stem = url.deletingPathExtension().lastPathComponent
            guard stem.count > 20, let date = Self.stamp.date(from: String(stem.prefix(19))),
                  let kind = Kind(rawValue: String(stem.dropFirst(20))) else { return nil }
            return Entry(url: url, kind: kind, date: date)
        }
        .sorted { $0.date > $1.date }
    }

    // MARK: huella

    /// Rutas relativas, tamaños y fechas de modificación de todos los
    /// archivos, ordenados. No lee el contenido: una partida de varios cientos
    /// de MB no debe costar segundos cada vez que se abre el juego.
    public static func fingerprint(_ dir: URL) -> (hash: String, files: Int, bytes: Int64) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return ("", 0, 0) }
        let base = dir.standardizedFileURL.path
        var rows: [String] = []
        var bytes: Int64 = 0
        for case let u as URL in e {
            guard let rv = try? u.resourceValues(forKeys: Set(keys)), rv.isRegularFile == true else { continue }
            let size = Int64(rv.fileSize ?? 0)
            bytes += size
            let rel = String(u.standardizedFileURL.path.dropFirst(base.count))
            rows.append("\(rel)\t\(size)\t\(rv.contentModificationDate?.timeIntervalSince1970 ?? 0)")
        }
        rows.sort()
        let digest = SHA256.hash(data: Data(rows.joined(separator: "\n").utf8))
        return (digest.map { String(format: "%02x", $0) }.joined(), rows.count, bytes)
    }

    // MARK: copiar

    /// Hace una copia de `saveDir`. Devuelve nil si no hay partida.
    @discardableResult
    public func backup(saveDir: URL, titleID: String, game: String, version: String,
                       kind: Kind, now: Date = Date()) async throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: saveDir.path) else { return nil }
        let fp = Self.fingerprint(saveDir)
        let manifest = SaveManifest(titleID: titleID, game: game, version: version, created: now,
                                    fingerprint: fp.hash, files: fp.files, bytes: fp.bytes)
        let dir = directory(for: titleID)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Dos copias en el mismo segundo: la segunda se fecha un segundo
        // después, para que el nombre siga diciendo fecha y tipo.
        var when = now
        var out = dir.appendingPathComponent("\(Self.stamp.string(from: when))_\(kind.rawValue).zip")
        while fm.fileExists(atPath: out.path) {
            when = when.addingTimeInterval(1)
            out = dir.appendingPathComponent("\(Self.stamp.string(from: when))_\(kind.rawValue).zip")
        }
        try await Self.pack(saveDir: saveDir, manifest: manifest, to: out)
        if kind == .auto { prune(titleID) }
        return out
    }

    /// La copia automática: solo si la partida cambió desde la última copia.
    @discardableResult
    public func autoBackup(saveDir: URL, titleID: String, game: String, version: String,
                           now: Date = Date()) async throws -> URL? {
        guard FileManager.default.fileExists(atPath: saveDir.path) else { return nil }
        let current = Self.fingerprint(saveDir).hash
        if let last = list(titleID).first, let m = await Self.manifest(of: last.url), m.fingerprint == current {
            return nil
        }
        return try await backup(saveDir: saveDir, titleID: titleID, game: game, version: version, kind: .auto, now: now)
    }

    /// Deja las `keepAuto` copias automáticas más nuevas. Las manuales y las
    /// de antes de restaurar no se tocan.
    public func prune(_ titleID: String) {
        for e in list(titleID).filter({ $0.kind == .auto }).dropFirst(keepAuto) {
            try? FileManager.default.removeItem(at: e.url)
        }
    }

    // MARK: zip

    /// `save/` y el manifiesto en un zip. Se monta en una carpeta temporal
    /// (copia con clon APFS cuando se puede) para que el zip tenga la misma
    /// forma venga de donde venga.
    static func pack(saveDir: URL, manifest: SaveManifest, to out: URL) async throws {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("nxsave-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        try fm.copyItem(at: saveDir, to: stage.appendingPathComponent("save", isDirectory: true))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: stage.appendingPathComponent(SaveManifest.fileName))
        let partial = out.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        let r = await Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", stage.path, partial.path])
        guard r.ok else { throw SaveError.tool("ditto -c: \(r.stderr)") }
        // Solo un zip completo lleva el nombre bueno.
        try fm.moveItem(at: partial, to: out)
    }

    /// El manifiesto de una copia, sin descomprimir el resto.
    public static func manifest(of archive: URL) async -> SaveManifest? {
        let r = await Shell.run("/usr/bin/unzip", ["-p", archive.path, SaveManifest.fileName])
        guard r.ok else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(SaveManifest.self, from: Data(r.stdout.utf8))
    }

    /// Exporta la partida actual a un zip donde diga el jugador.
    public func export(saveDir: URL, titleID: String, game: String, version: String, to out: URL) async throws {
        guard FileManager.default.fileExists(atPath: saveDir.path) else { throw SaveError.noSave }
        let fp = Self.fingerprint(saveDir)
        let m = SaveManifest(titleID: titleID, game: game, version: version, created: Date(),
                             fingerprint: fp.hash, files: fp.files, bytes: fp.bytes)
        if FileManager.default.fileExists(atPath: out.path) { try FileManager.default.removeItem(at: out) }
        try await Self.pack(saveDir: saveDir, manifest: m, to: out)
    }

    // MARK: restaurar

    public enum SaveError: LocalizedError, Equatable {
        case noSave
        case notASave
        case otherGame(expected: String, found: String, game: String)
        case tool(String)

        public var errorDescription: String? {
            switch self {
            case .noSave: "Este juego aún no tiene partida guardada."
            case .notASave: "El archivo no es una copia de partida: no contiene una carpeta save/."
            case let .otherGame(expected, found, game):
                "Esta copia es de otro juego (\(game), \(found)); este es \(expected). No se importa."
            case let .tool(s): s
            }
        }
    }

    /// Restaura (o importa) una copia en `saveDir`. Antes copia la partida
    /// actual, y la carpeta vieja va a la Papelera: es la única operación que
    /// podría perder datos, así que deja dos caminos de vuelta.
    public func restore(_ archive: URL, saveDir: URL, titleID: String, game: String, version: String) async throws {
        let fm = FileManager.default
        if let m = await Self.manifest(of: archive), m.titleID.uppercased() != titleID.uppercased() {
            throw SaveError.otherGame(expected: titleID, found: m.titleID, game: m.game)
        }
        let staging = saveDir.deletingLastPathComponent().appendingPathComponent(".restore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let r = await Shell.run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path])
        guard r.ok else { throw SaveError.tool("ditto -x: \(r.stderr)") }
        let restored = staging.appendingPathComponent("save", isDirectory: true)
        guard fm.fileExists(atPath: restored.path) else { throw SaveError.notASave }

        if fm.fileExists(atPath: saveDir.path) {
            try await backup(saveDir: saveDir, titleID: titleID, game: game, version: version, kind: .beforeRestore)
            try fm.trashItem(at: saveDir, resultingItemURL: nil)
        }
        try fm.moveItem(at: restored, to: saveDir)
    }
}
