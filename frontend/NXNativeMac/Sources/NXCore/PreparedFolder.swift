import Foundation

/// La carpeta de un juego para el script, hecha con enlaces simbólicos a sus
/// archivos: `<raíz>/_nxnative/<nombre> [<title ID>]/`.
///
/// `build_ipa_from_nsp.py` exige una carpeta por juego. En una biblioteca
/// plana (todos los juegos juntos, los DLC en subcarpetas) eso obligaría a
/// mover archivos; los enlaces no mueven nada ni ocupan espacio, y el script
/// los sigue (`glob`, `stat` y `nx_extract` abren el destino).
///
/// El nombre del enlace lleva `[title ID]` y `[vN]`, que es lo que lee el
/// script cuando no hay ticket: un XCI sin etiqueta en su nombre original se
/// identifica así. `<title ID>_build/` (decenas de GB) queda dentro de esta
/// carpeta, en el mismo disco que los juegos.
public enum PreparedFolder {
    public static let directoryName = "_nxnative"

    public static func url(for game: GameEntry, root: URL, name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
        return root.appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("\(safe) [\(game.base)]", isDirectory: true)
    }

    /// El nombre del enlace: `<nombre limpio> [TID][vN].<ext>`.
    public static func linkName(for file: GameFile) -> String {
        var stem = GameLibrary.cleanName(file.url.deletingPathExtension().lastPathComponent)
        if stem.isEmpty { stem = "game" }
        let tid = file.titleID.map { " [\($0)]" } ?? ""
        let v = file.version.map { "[v\($0)]" } ?? ""
        return "\(stem)\(tid)\(v).\(file.ext)"
    }

    /// Crea o pone al día la carpeta. Solo toca ENLACES: un archivo normal
    /// que alguien haya dejado dentro no se borra nunca, y la carpeta
    /// `_build` del script se respeta.
    @discardableResult
    public static func sync(_ game: GameEntry, root: URL, name: String) throws -> URL {
        let fm = FileManager.default
        let dir = url(for: game, root: root, name: name)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var wanted: [String: URL] = [:]
        for f in game.files {
            var n = linkName(for: f)
            // Dos archivos con el mismo nombre limpio: se numeran.
            var i = 2
            while wanted[n] != nil { n = "\(i) \(linkName(for: f))"; i += 1 }
            wanted[n] = f.url
        }

        let existing = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for n in existing {
            let p = dir.appendingPathComponent(n)
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: p.path) else { continue }
            if wanted[n]?.path != dest { try fm.removeItem(at: p) }
        }
        for (n, target) in wanted {
            let p = dir.appendingPathComponent(n)
            if (try? fm.destinationOfSymbolicLink(atPath: p.path)) == target.path { continue }
            guard !fm.fileExists(atPath: p.path) else {
                throw NSError(domain: "NXCore", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Ya existe \(p.path) y no es un enlace: no se toca."])
            }
            try fm.createSymbolicLink(at: p, withDestinationURL: target)
        }
        return dir
    }

    /// Las carpetas ya preparadas bajo una raíz, por title ID.
    public static func existing(root: URL) -> [TitleID: URL] {
        let base = root.appendingPathComponent(directoryName, isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        var out: [TitleID: URL] = [:]
        for d in items {
            let n = d.lastPathComponent
            guard n.hasSuffix("]"), let open = n.lastIndex(of: "[") else { continue }
            if let t = TitleID(n[n.index(after: open)..<n.index(before: n.endIndex)]) { out[t] = d }
        }
        return out
    }
}
