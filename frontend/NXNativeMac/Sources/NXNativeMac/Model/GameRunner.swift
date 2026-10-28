import AppKit
import Foundation
import NXCore
import Observation

/// Arranca y para las apps de juego. Se abren por LaunchServices, como desde
/// Finder: el lanzador de nxnative (`dm/mac/launcher.c`) tiene que ser el
/// proceso responsable para que TCC le deje leer un disco externo; si lo
/// lanzáramos como hijo nuestro, el permiso nos lo pediría a nosotros.
@MainActor @Observable
final class GameRunner {
    private(set) var running: [String: NSRunningApplication] = [:]   // por title ID
    private(set) var lastError: String?
    private var observer: NSObjectProtocol?

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let pid else { return }
                self.running = self.running.filter { $0.value.processIdentifier != pid }
            }
        }
    }

    func isRunning(_ game: MacGameBundle) -> Bool {
        // La notificación de término de NSWorkspace se puede perder (firma
        // ad-hoc, salidas por crash): se confirma con isTerminated antes de
        // creerle al caché, si no el juego se queda «corriendo» para siempre.
        if let app = running[game.titleID] {
            if !app.isTerminated { return true }
            running[game.titleID] = nil
        }
        // Arrancada desde Finder o desde otra sesión de la app.
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.standardizedFileURL == game.url.standardizedFileURL }) {
            running[game.titleID] = app
            return true
        }
        return false
    }

    /// Los ajustes ya están en `env.txt` de Application Support, que el
    /// lanzador lee; `extra` son variables solo para esta partida (las del
    /// entorno ganan a las del archivo).
    func launch(_ game: MacGameBundle, extra: [String: String] = [:]) {
        lastError = nil
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        cfg.createsNewApplicationInstance = false
        if !extra.isEmpty { cfg.environment = extra }
        NSWorkspace.shared.openApplication(at: game.url, configuration: cfg) { [weak self] app, error in
            let message = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                if let app { self.running[game.titleID] = app }
                self.lastError = message
            }
        }
    }

    /// SIGTERM al lanzador, que lo reenvía al host y sale con su código.
    func stop(_ game: MacGameBundle) {
        guard let app = running[game.titleID] else { return }
        kill(app.processIdentifier, SIGTERM)
    }
}
