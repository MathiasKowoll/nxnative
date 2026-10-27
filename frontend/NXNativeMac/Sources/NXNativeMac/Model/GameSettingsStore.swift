import Foundation
import NXCore
import Observation

/// Los ajustes de una app de juego, guardados en su `env.txt` de Application
/// Support, que el lanzador lee al arrancar. Así valen también cuando el
/// juego se abre desde Finder, sin esta app.
///
/// Como hace la app del iPhone, solo se escriben las elecciones que DIFIEREN
/// del valor probado: si un build nuevo cambia el valor probado, le llega al
/// jugador que no lo había tocado.
@MainActor @Observable
final class GameSettingsStore {
    let game: MacGameBundle
    private(set) var settings: LauncherSettings?
    private(set) var env = EnvFile()
    /// `Resources/dm/env.txt` del bundle (`--env-file` al empaquetar).
    private(set) var bundled = EnvFile()
    private(set) var error: String?

    init(game: MacGameBundle) {
        self.game = game
        reload()
    }

    func reload() {
        settings = game.launcherSettings()
        env = EnvFile(contentsOf: game.userEnv)
        bundled = EnvFile(contentsOf: game.bundledEnv)
    }

    func value(_ s: Setting) -> String { env[s.env] ?? bundled[s.env] ?? s.defaultValue }
    func isChanged(_ s: Setting) -> Bool { env[s.env] != nil }
    func bundledValue(_ s: Setting) -> String? { bundled[s.env] }

    func set(_ s: Setting, _ value: String) {
        // Igual al probado y sin nada en el bundle que haya que pisar: fuera.
        env[s.env] = (s.isDefault(value) && bundled[s.env] == nil) ? nil : value
        save()
    }

    /// «Restablecer valores probados»: quita las elecciones de la lista, deja
    /// el resto del archivo (interruptores escritos a mano) como estaba.
    func resetAll() {
        for s in settings?.settings ?? [] { env[s.env] = nil }
        save()
    }

    var rawText: String { env.text }

    func saveRaw(_ text: String) {
        env = EnvFile(text: text)
        save()
    }

    private func save() {
        do {
            if env.lines.isEmpty {
                try? FileManager.default.removeItem(at: game.userEnv)
            } else {
                try env.write(to: game.userEnv)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
