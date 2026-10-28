import Foundation

/// Un perfil: las partidas de una persona en este Mac, separadas de las de las
/// demás. El lanzador de nxnative fija la carpeta de partidas (DM_SAVE) solo
/// si no viene ya fijada, así que basta con pasarla al arrancar: no hace falta
/// tocar nxnative.
///
/// «Principal» usa la carpeta de siempre (`…/nxnative/<title ID>/save`): un
/// juego abierto desde Finder, sin esta app, sigue con esas partidas, y no hay
/// nada que migrar. Los demás perfiles van en `…/nxnative/<title ID>/perfiles/<id>/save`;
/// el host deja la partida del «dispositivo» en `<DM_SAVE>_device` y su lista
/// de pipelines en la carpeta de encima, así que también quedan por perfil.
public struct Profile: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) { self.id = id; self.name = name }

    public static let main = Profile(id: "principal", name: "Principal")
    public var isMain: Bool { id == Self.main.id }

    /// La carpeta de partidas de este perfil para un juego, dada la carpeta de
    /// Application Support del juego (`MacGameBundle.supportDirectory`).
    public func saveDirectory(support: URL) -> URL {
        isMain ? support.appendingPathComponent("save", isDirectory: true)
               : support.appendingPathComponent("perfiles/\(id)/save", isDirectory: true)
    }

    /// Dónde van las copias de este perfil dentro de la carpeta de copias.
    public func backupsRoot(base: URL) -> URL {
        isMain ? base : base.appendingPathComponent("perfiles/\(id)", isDirectory: true)
    }
}

/// La lista de perfiles y el activo, en un JSON propio de la app.
public struct ProfileBook: Codable, Equatable, Sendable {
    public var profiles: [Profile]
    public var active: String

    public init(profiles: [Profile] = [.main], active: String = Profile.main.id) {
        self.profiles = profiles; self.active = active
    }

    public var activeProfile: Profile { profiles.first { $0.id == active } ?? .main }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NXNativeMac/perfiles.json")
    }

    /// Siempre con «Principal» el primero, aunque el archivo falte o esté mal.
    public static func load(from url: URL = defaultURL) -> ProfileBook {
        guard let data = try? Data(contentsOf: url), var b = try? JSONDecoder().decode(ProfileBook.self, from: data) else { return ProfileBook() }
        b.profiles.removeAll { $0.isMain }
        b.profiles.insert(.main, at: 0)
        if !b.profiles.contains(where: { $0.id == b.active }) { b.active = Profile.main.id }
        return b
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    /// Un perfil nuevo. El id sale del nombre, con un sufijo si se repite, y
    /// no cambia al renombrar: las carpetas cuelgan del id, no del nombre.
    @discardableResult
    public mutating func add(name: String) -> Profile {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var slug = clean.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { s, c in if !(c == "-" && s.hasSuffix("-")) { s.append(c) } }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty || slug == Profile.main.id { slug = "perfil" }
        var id = slug; var n = 2
        while profiles.contains(where: { $0.id == id }) { id = "\(slug)-\(n)"; n += 1 }
        let p = Profile(id: id, name: clean.isEmpty ? "Perfil" : clean)
        profiles.append(p)
        return p
    }

    public mutating func rename(_ id: String, to name: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }), !profiles[i].isMain else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { profiles[i].name = clean }
    }

    /// Quita el perfil de la lista (no sus partidas: eso lo decide quien llama).
    /// «Principal» no se quita.
    public mutating func remove(_ id: String) {
        guard id != Profile.main.id else { return }
        profiles.removeAll { $0.id == id }
        if active == id { active = Profile.main.id }
    }
}
