import Foundation
import NXCore
import Observation

/// Lo que el usuario configura una vez. Solo se guardan RUTAS; de `prod.keys`
/// la app solo lee `header_key` para identificar archivos sin etiqueta (los
/// valores nunca se muestran ni se registran) y al script se lo pasa con `-k`.
@MainActor @Observable
final class Preferences {
    private let defaults = UserDefaults.standard

    var keysPath: String { didSet { defaults.set(keysPath, forKey: "keysPath") } }
    /// Vacío = buscar uno >= 3.12 automáticamente.
    var pythonPath: String { didSet { defaults.set(pythonPath, forKey: "pythonPath") } }
    /// Carpetas donde viven las carpetas NSP (una por juego).
    var gameRoots: [String] { didSet { defaults.set(gameRoots, forKey: "gameRoots") } }
    /// Carpetas extra donde buscar apps de juego ya empaquetadas.
    var appRoots: [String] { didSet { defaults.set(appRoots, forKey: "appRoots") } }
    /// Carpeta por defecto para las apps que genera el instalador FC26/FC27.
    var gameAppsPath: String { didSet { defaults.set(gameAppsPath, forKey: "gameAppsPath") } }
    var macSignIdentity: String { didSet { defaults.set(macSignIdentity, forKey: "macSignIdentity") } }
    /// Dónde van las copias de partidas. Vacío = la carpeta por defecto. Puede
    /// ser iCloud Drive u otro disco, para que sobrevivan a un desinstalador
    /// que limpie Application Support o a un cambio de Mac.
    var backupsPath: String { didSet { defaults.set(backupsPath, forKey: "backupsPath") } }
    /// Copia automática antes de jugar y antes de reconstruir un juego.
    var autoBackup: Bool { didSet { defaults.set(autoBackup, forKey: "autoBackup") } }
    /// Valores para todos los juegos (GlobalDefaults): pantalla completa al
    /// arrancar, filtro de escalado ("" = cada juego) y nitidez (<0 = cada juego).
    var globalFullscreen: Bool { didSet { defaults.set(globalFullscreen, forKey: "globalFullscreen") } }
    var globalFilter: String { didSet { defaults.set(globalFilter, forKey: "globalFilter") } }
    var globalSharpen: Double { didSet { defaults.set(globalSharpen, forKey: "globalSharpen") } }
    /// Title IDs asignados a mano a archivos sin etiqueta, por ruta.
    var assignedTitleIDs: [String: String] { didSet { defaults.set(assignedTitleIDs, forKey: "assignedTitleIDs") } }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        keysPath = defaults.string(forKey: "keysPath") ?? ""
        pythonPath = defaults.string(forKey: "pythonPath") ?? ""
        gameRoots = defaults.stringArray(forKey: "gameRoots") ?? []
        appRoots = defaults.stringArray(forKey: "appRoots") ?? ["\(home)/Applications", "/Applications"]
        gameAppsPath = defaults.string(forKey: "gameAppsPath") ?? "\(home)/Applications"
        macSignIdentity = defaults.string(forKey: "macSignIdentity") ?? ""
        backupsPath = defaults.string(forKey: "backupsPath") ?? ""
        autoBackup = defaults.object(forKey: "autoBackup") as? Bool ?? true
        globalFullscreen = defaults.bool(forKey: "globalFullscreen")
        globalFilter = defaults.string(forKey: "globalFilter") ?? ""
        globalSharpen = defaults.object(forKey: "globalSharpen") as? Double ?? -1
        assignedTitleIDs = defaults.dictionary(forKey: "assignedTitleIDs") as? [String: String] ?? [:]
    }

    var bundledRepositoryURL: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let root = resources.appendingPathComponent("nxnative", isDirectory: true)
        let marker = root.appendingPathComponent(".nxnative-bundled")
        let script = root.appendingPathComponent("scripts/build_ipa_from_nsp.py")
        guard FileManager.default.fileExists(atPath: marker.path),
              FileManager.default.fileExists(atPath: script.path) else { return nil }
        return root
    }

    var repositoryURL: URL {
        if let bundledRepositoryURL { return bundledRepositoryURL }
        // Fallback solo para ejecuciones de desarrollo fuera del bundle. Las
        // apps distribuidas siempre llevan el payload dentro de Resources.
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Development/nxnative", isDirectory: true)
        return root
    }

    var bundledFC26URL: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let root = resources.appendingPathComponent("fc26-mac-port", isDirectory: true)
        let marker = root.appendingPathComponent(".fc26-builder-bundled")
        let script = root.appendingPathComponent("games/fc26/build.sh")
        guard FileManager.default.fileExists(atPath: marker.path),
              FileManager.default.isExecutableFile(atPath: script.path) else { return nil }
        return root
    }

    var keysURL: URL? {
        keysPath.isEmpty ? nil : URL(fileURLWithPath: (keysPath as NSString).expandingTildeInPath)
    }
    var globalDefaults: GlobalDefaults {
        GlobalDefaults(fullscreen: globalFullscreen, filter: globalFilter.isEmpty ? nil : globalFilter,
                       sharpen: globalSharpen < 0 ? nil : globalSharpen)
    }
    var backupsURL: URL {
        backupsPath.isEmpty ? SaveVault.defaultRoot
            : URL(fileURLWithPath: (backupsPath as NSString).expandingTildeInPath, isDirectory: true)
    }
    var gameAppsURL: URL {
        URL(fileURLWithPath: (gameAppsPath as NSString).expandingTildeInPath, isDirectory: true)
    }
    var gameRootURLs: [URL] { gameRoots.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) } }
    /// Las raíces configuradas más la carpeta que contiene esta app. Así,
    /// al poner NXNative.app junto a las apps de juego en un disco externo,
    /// el selector las encuentra sin guardar una ruta fija del usuario.
    var appRootURLs: [URL] {
        var paths = appRoots
        if !gameAppsPath.isEmpty { paths.append(gameAppsPath) }
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            paths.append(bundle.deletingLastPathComponent().path)
        }
        var seen = Set<String>()
        return paths.compactMap { path in
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
            return seen.insert(url.path).inserted ? url : nil
        }
    }

    static let pythonCandidates = [
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
        "/usr/bin/python3",
    ]
}
