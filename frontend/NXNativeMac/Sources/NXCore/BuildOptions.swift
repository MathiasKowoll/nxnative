import Foundation

/// Las opciones de `build_ipa_from_nsp.py` que expone la app. Se traducen a
/// argumentos aquí, en un solo sitio, para poder probarlo sin lanzar nada.
public struct BuildOptions: Sendable, Equatable, Codable, Identifiable {
    public enum Platform: String, Sendable, Codable, CaseIterable {
        case macApp = "mac-app", mac, ios
    }

    public var nspFolder: URL
    public var keys: URL
    public var platform: Platform = .macApp
    /// `-p`: vacío = la más nueva de la carpeta.
    public var package: String = ""
    public var output: URL?
    public var appName: String = ""
    public var language: String = ""
    public var gpu: String = ""
    public var macSign: String = ""
    public var keepExtracted: Bool = true
    public var showFPS: Bool = false
    public var allowDamaged: Bool = false
    public var allowShaderRegressions: Bool = false
    public var allowOtherMetal: Bool = false
    public var provisional: Bool = false
    public var surveyOnly: Bool = false
    public var envFile: URL?

    public var id: URL { nspFolder }

    public init(nspFolder: URL, keys: URL) {
        self.nspFolder = nspFolder; self.keys = keys
    }

    /// Siempre con `--progress json`: así el script no pregunta nada y su
    /// salida es la que sabemos leer.
    public func arguments(script: URL) -> [String] {
        var a = [script.path, nspFolder.path, "-k", keys.path, "--progress", "json",
                 "--platform", platform.rawValue]
        if !package.isEmpty { a += ["-p", package] }
        if let output { a += ["-o", output.path] }
        if !appName.isEmpty { a += ["--app-name", appName] }
        if !language.isEmpty { a += ["-l", language] }
        if !gpu.isEmpty { a += ["--gpu", gpu] }
        if platform == .macApp, !macSign.isEmpty { a += ["--mac-sign", macSign] }
        a.append(keepExtracted ? "--keep-extracted" : "--no-keep-extracted")
        if platform == .ios { a.append(showFPS ? "--show-fps" : "--no-show-fps") }
        if allowDamaged { a.append("--allow-damaged") }
        if allowShaderRegressions { a.append("--allow-shader-regressions") }
        if allowOtherMetal { a.append("--allow-other-metal") }
        if provisional { a.append("--provisional") }
        if surveyOnly { a.append("--survey-only") }
        if let envFile { a += ["--env-file", envFile.path] }
        return a
    }

    /// Los idiomas que acepta `-l` (de `--help`). El juego tiene que admitirlo.
    public static let languages: [(code: String, name: String)] = [
        ("", "Inglés (por defecto)"), ("en-GB", "Inglés (Reino Unido)"), ("ja", "Japonés"),
        ("fr", "Francés"), ("fr-CA", "Francés (Canadá)"), ("de", "Alemán"), ("es", "Español"),
        ("es-419", "Español (Latinoamérica)"), ("it", "Italiano"), ("nl", "Neerlandés"),
        ("pt", "Portugués"), ("pt-BR", "Portugués (Brasil)"), ("ru", "Ruso"), ("ko", "Coreano"),
        ("zh-Hans", "Chino simplificado"), ("zh-Hant", "Chino tradicional"),
    ]
}
