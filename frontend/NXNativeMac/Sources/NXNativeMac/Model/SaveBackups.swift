import Foundation
import NXCore

/// Copias de las partidas guardadas de una app de juego. Van a
/// `~/Library/Application Support/NXNativeMac/Backups/<title ID>/`, fuera de
/// la carpeta de nxnative, para que borrar un juego no se lleve las copias.
enum SaveBackups {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NXNativeMac/Backups", isDirectory: true)
    }

    static func directory(for game: MacGameBundle) -> URL {
        root.appendingPathComponent(game.titleID, isDirectory: true)
    }

    static func list(for game: MacGameBundle) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory(for: game), includingPropertiesForKeys: [.creationDateKey])) ?? []
        return items.filter { $0.pathExtension == "zip" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// `ditto` conserva atributos y metadatos, y comprime en zip.
    static func backup(_ game: MacGameBundle) async throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: game.saveDirectory.path) else {
            throw NSError(domain: "NXNativeMac", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Este juego aún no tiene partida guardada."])
        }
        try fm.createDirectory(at: directory(for: game), withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let out = directory(for: game).appendingPathComponent("save_\(f.string(from: Date())).zip")
        let r = await Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent",
                                                   game.saveDirectory.path, out.path])
        guard r.ok else { throw NSError(domain: "NXNativeMac", code: 2, userInfo: [NSLocalizedDescriptionKey: r.stderr]) }
        return out
    }

    /// Antes de restaurar se hace copia de lo que hay: restaurar sin ella
    /// sería la única operación de la app que destruye datos del jugador.
    static func restore(_ archive: URL, into game: MacGameBundle) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: game.saveDirectory.path) {
            _ = try await backup(game)
        }
        let staging = game.supportDirectory.appendingPathComponent(".restore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let r = await Shell.run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path])
        guard r.ok else { throw NSError(domain: "NXNativeMac", code: 3, userInfo: [NSLocalizedDescriptionKey: r.stderr]) }
        let restored = staging.appendingPathComponent("save", isDirectory: true)
        guard fm.fileExists(atPath: restored.path) else {
            throw NSError(domain: "NXNativeMac", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "El archivo no contiene una carpeta save/."])
        }
        if fm.fileExists(atPath: game.saveDirectory.path) {
            try fm.trashItem(at: game.saveDirectory, resultingItemURL: nil)
        }
        try fm.moveItem(at: restored, to: game.saveDirectory)
    }
}
