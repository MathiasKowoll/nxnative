import Foundation

/// Los iconos de botones que el juego dibuja en su texto («pulsa Ⓐ»).
///
/// Salen de la fuente de extensión que nxnative genera (`dm/tools/make_ext_font.py`)
/// y que el host sirve como fuente compartida de tipo 5. El host mira antes
/// `DM_SHARED_FONT_EXT` que la fuente de la app (`hle_sdk16.c` `font_first`),
/// así que cambiar de estilo es una línea en el `env.txt` del juego, sin
/// reconstruirlo.
///
/// Solo cambia los juegos que dibujan los botones con esa fuente del sistema
/// (los de Nintendo, sobre todo); un juego que trae sus propias texturas de
/// botones (muchos de Unity) sigue enseñando las suyas.
public enum ButtonGlyphs: String, CaseIterable, Sendable {
    case nintendo, playstation

    public static let envKey = "DM_SHARED_FONT_EXT"

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NXNativeMac/fonts", isDirectory: true)
    }

    /// La fuente generada para este estilo. El de Nintendo no necesita una:
    /// es la que ya trae la app.
    public var font: URL? {
        self == .playstation ? Self.directory.appendingPathComponent("nintendo_ext_playstation.ttf") : nil
    }

    /// El estilo que dice un `env.txt`; nil si apunta a otra fuente que no
    /// es nuestra (puesta a mano), que no se toca.
    public static func current(in env: EnvFile) -> ButtonGlyphs? {
        guard let v = env[envKey] else { return .nintendo }
        return allCases.first { $0.font?.path == v }
    }

    public func apply(to env: inout EnvFile) {
        env[Self.envKey] = font?.path
    }

    /// Genera la fuente si falta o si el generador es más nuevo que ella.
    public func ensureFont(repository: NXRepository, python: String) async throws {
        guard let out = font else { return }
        let script = repository.root.appendingPathComponent("dm/tools/make_ext_font.py")
        let fm = FileManager.default
        let mtime = { (u: URL) in (try? fm.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? .distantPast }
        if fm.fileExists(atPath: out.path), mtime(out) >= mtime(script) { return }
        try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let r = await Shell.run(python, [script.path, out.path, "--style", rawValue])
        guard r.ok, fm.fileExists(atPath: out.path) else {
            let why = (r.stderr + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "NXCore", code: 20, userInfo: [NSLocalizedDescriptionKey:
                "No se pudo generar la fuente de iconos: \(why.isEmpty ? "make_ext_font.py falló" : why)"])
        }
    }
}
