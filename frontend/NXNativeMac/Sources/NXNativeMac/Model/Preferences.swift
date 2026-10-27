import Foundation
import Observation

/// Lo que el usuario configura una vez. Solo se guardan RUTAS: la app nunca
/// abre `prod.keys`, se la pasa al script con `-k`.
@MainActor @Observable
final class Preferences {
    private let defaults = UserDefaults.standard

    var repositoryPath: String { didSet { defaults.set(repositoryPath, forKey: "repositoryPath") } }
    var keysPath: String { didSet { defaults.set(keysPath, forKey: "keysPath") } }
    /// Vacío = buscar uno >= 3.12 automáticamente.
    var pythonPath: String { didSet { defaults.set(pythonPath, forKey: "pythonPath") } }
    /// Carpetas donde viven las carpetas NSP (una por juego).
    var gameRoots: [String] { didSet { defaults.set(gameRoots, forKey: "gameRoots") } }
    /// Carpetas extra donde buscar apps de juego ya empaquetadas.
    var appRoots: [String] { didSet { defaults.set(appRoots, forKey: "appRoots") } }
    var macSignIdentity: String { didSet { defaults.set(macSignIdentity, forKey: "macSignIdentity") } }
    /// Title IDs asignados a mano a archivos sin etiqueta, por ruta.
    var assignedTitleIDs: [String: String] { didSet { defaults.set(assignedTitleIDs, forKey: "assignedTitleIDs") } }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        repositoryPath = defaults.string(forKey: "repositoryPath") ?? "\(home)/Development/nxnative"
        keysPath = defaults.string(forKey: "keysPath") ?? ""
        pythonPath = defaults.string(forKey: "pythonPath") ?? ""
        gameRoots = defaults.stringArray(forKey: "gameRoots") ?? []
        appRoots = defaults.stringArray(forKey: "appRoots") ?? ["\(home)/Applications", "/Applications"]
        macSignIdentity = defaults.string(forKey: "macSignIdentity") ?? ""
        assignedTitleIDs = defaults.dictionary(forKey: "assignedTitleIDs") as? [String: String] ?? [:]
    }

    var repositoryURL: URL { URL(fileURLWithPath: (repositoryPath as NSString).expandingTildeInPath, isDirectory: true) }
    var keysURL: URL? {
        keysPath.isEmpty ? nil : URL(fileURLWithPath: (keysPath as NSString).expandingTildeInPath)
    }
    var gameRootURLs: [URL] { gameRoots.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) } }
    var appRootURLs: [URL] { appRoots.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) } }

    static let pythonCandidates = [
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
        "/usr/bin/python3",
    ]
}
