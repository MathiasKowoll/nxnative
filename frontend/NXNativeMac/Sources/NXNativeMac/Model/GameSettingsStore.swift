import Foundation
import NXCore
import Observation

/// Los ajustes de una app de juego, guardados en SQLite y materializados en
/// su `env.txt` de Application Support, que el lanzador lee al arrancar. Así
/// valen también cuando el juego se abre desde Finder, sin esta app.
///
/// Como hace la app del iPhone, solo se escriben las elecciones que DIFIEREN
/// del valor probado: si un build nuevo cambia el valor probado, le llega al
/// jugador que no lo había tocado.
@MainActor @Observable
final class GameSettingsStore {
    let game: MacGameBundle
    private let database = ConfigurationDatabase()
    private(set) var settings: LauncherSettings?
    private(set) var env = EnvFile()
    /// `Resources/dm/env.txt` del bundle (`--env-file` al empaquetar).
    private(set) var bundled = EnvFile()
    private(set) var error: String?
    private(set) var syncAction: ConfigurationDatabase.SyncAction = .unchanged
    private var syncedFileExists = false
    private var syncedRawText: String?

    init(game: MacGameBundle) {
        self.game = game
        reload()
    }

    func reload() {
        settings = game.launcherSettings()
        bundled = EnvFile(contentsOf: game.bundledEnv)
        synchronize()
    }

    /// Vuelve a leer SQLite y `env.txt` y actualiza la vista sin cambiar
    /// ninguna elección. Se ofrece explícitamente porque el archivo también
    /// puede editarse desde Finder o un editor externo.
    func synchronize() {
        do {
            let result = try database.synchronize(titleID: game.titleID, envURL: game.userEnv)
            env = result.env
            syncAction = result.action
            rememberDiskState()
            error = nil
        } catch let databaseError {
            // El archivo sigue siendo una salida compatible y permite jugar
            // aunque la base esté dañada o no se pueda abrir.
            env = EnvFile(contentsOf: game.userEnv)
            rememberDiskState()
            syncAction = .unchanged
            self.error = "SQLite no disponible; se usa env.txt: " + databaseError.localizedDescription
        }
    }

    var syncSummary: String {
        switch syncAction {
        case .created, .unchanged, .saved: return "SQLite y env.txt sincronizados"
        case .importedFromFile: return "Se importó la edición de env.txt en SQLite"
        case .restoredToFile: return "Se restauró env.txt desde SQLite"
        }
    }

    func value(_ s: Setting) -> String { env[s.env] ?? bundled[s.env] ?? s.defaultValue }
    func isChanged(_ s: Setting) -> Bool { env[s.env] != nil }
    func bundledValue(_ s: Setting) -> String? { bundled[s.env] }

    func set(_ s: Setting, _ value: String) {
        // Igual al probado y sin nada en el bundle que haya que pisar: fuera.
        synchronizeIfNeeded()
        env[s.env] = (s.isDefault(value) && bundled[s.env] == nil) ? nil : value
        save()
    }

    /// «Restablecer valores probados»: quita las elecciones de la lista, deja
    /// el resto del archivo (interruptores escritos a mano) como estaba.
    func resetAll() {
        synchronizeIfNeeded()
        for s in settings?.settings ?? [] { env[s.env] = nil }
        save()
    }

    // MARK: iconos de botones

    /// nil = el env.txt apunta a una fuente puesta a mano, que no se toca.
    var buttonGlyphs: ButtonGlyphs? { ButtonGlyphs.current(in: env) }

    func setButtonGlyphs(_ style: ButtonGlyphs, repository: NXRepository, python: String?) async {
        do {
            if style.font != nil {
                guard let python else { throw NSError(domain: "NXNativeMac", code: 21, userInfo: [NSLocalizedDescriptionKey: "Hace falta Python con fonttools: pulsa «Preparar Python» en Entorno."]) }
                try await style.ensureFont(repository: repository, python: python)
            }
            synchronizeIfNeeded()
            style.apply(to: &env)
            save()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: 120 Hz (experimental)

    var highRefresh: Bool { HighRefresh.isOn(env) }
    var highRefreshConflicts: [String] { HighRefresh.conflicts(env) }
    /// Una variable que gobierna el modo 120 Hz: mientras está encendido, su
    /// fila de ajustes no se toca por separado.
    func ownedByHighRefresh(_ s: Setting) -> Bool { highRefresh && HighRefresh.values.contains { $0.key == s.env } }

    func setHighRefresh(_ on: Bool) {
        synchronizeIfNeeded()
        HighRefresh.set(on, in: &env)
        save()
    }

    // MARK: interruptores sueltos (pestaña Avanzado)

    /// Lo que el env.txt fija, en su orden: la primera aparición de cada
    /// variable, que es la que vale para el lanzador.
    var activeSwitches: [(key: String, value: String)] { env.keys.map { ($0, env[$0] ?? "") } }

    /// Pone o quita (nil) una variable, dejando el resto del archivo como está.
    func setSwitch(_ key: String, _ value: String?) {
        synchronizeIfNeeded()
        env[key] = value
        save()
    }

    var rawText: String { env.text }

    func saveRaw(_ text: String) {
        synchronizeIfNeeded()
        env = EnvFile(text: text)
        save()
    }

    private func save() {
        do {
            try database.save(titleID: game.titleID, env: env, envURL: game.userEnv)
            syncAction = .saved
            rememberDiskState()
            error = nil
        } catch {
            // `ConfigurationDatabase.save` escribe env.txt antes de tocar
            // SQLite. Este respaldo conserva la ruta antigua si el fallo fue
            // abrir la base o migrarla.
            do {
                if env.lines.isEmpty {
                    if FileManager.default.fileExists(atPath: game.userEnv.path) {
                        try FileManager.default.removeItem(at: game.userEnv)
                    }
                } else {
                    try env.write(to: game.userEnv)
                }
                self.error = "SQLite no disponible; env.txt sí se guardó: " + error.localizedDescription
                rememberDiskState()
                syncAction = .unchanged
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Evita abrir SQLite en cada movimiento de un slider si el archivo no
    /// cambió. Si alguien editó o borró `env.txt` mientras esta vista estaba
    /// abierta, se reconcilia antes de aplicar la nueva elección.
    private func synchronizeIfNeeded() {
        let exists = FileManager.default.fileExists(atPath: game.userEnv.path)
        let raw = exists ? try? String(contentsOf: game.userEnv, encoding: .utf8) : nil
        guard exists != syncedFileExists || raw != syncedRawText else { return }
        synchronize()
    }

    private func rememberDiskState() {
        syncedFileExists = FileManager.default.fileExists(atPath: game.userEnv.path)
        syncedRawText = syncedFileExists ? try? String(contentsOf: game.userEnv, encoding: .utf8) : nil
    }
}
