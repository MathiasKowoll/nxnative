import Foundation

/// Valores que el jugador quiere en TODOS los juegos: pantalla completa al
/// arrancar, filtro de escalado y nitidez. Se pasan en el entorno del
/// arranque, así que valen al abrir un juego desde esta app (no desde
/// Finder).
///
/// Un juego con su propia elección (en su `env.txt`, que es donde la app
/// guarda los Ajustes de cada juego) se queda con la suya: el entorno del
/// arranque ganaría al `env.txt` en el lanzador, por eso aquí se omite la
/// variable cuando el juego ya la fija.
public struct GlobalDefaults: Sendable, Equatable {
    public var fullscreen: Bool
    /// nil = cada juego con lo suyo. Si no: bilinear, bicubic, lanczos, sharp.
    public var filter: String?
    /// nil = cada juego con lo suyo. Si no: de 0 a 1.
    public var sharpen: Double?

    public init(fullscreen: Bool = false, filter: String? = nil, sharpen: Double? = nil) {
        self.fullscreen = fullscreen; self.filter = filter; self.sharpen = sharpen
    }

    public static let filters: [(value: String, label: String)] = [
        ("bilinear", "Bilineal"), ("bicubic", "Bicúbico"), ("lanczos", "Lanczos"), ("sharp", "Píxel nítido"),
    ]

    /// Las variables que hay que añadir al arranque de un juego cuyo
    /// `env.txt` del jugador es `userEnv`.
    public func environment(userEnv: EnvFile) -> [String: String] {
        var out: [String: String] = [:]
        func put(_ key: String, _ value: String?) {
            guard let value, userEnv[key] == nil else { return }
            out[key] = value
        }
        put("DM_FULLSCREEN", fullscreen ? "1" : nil)
        put("DM_PRESENT_FILTER", filter.flatMap { f in Self.filters.contains { $0.value == f } ? f : nil })
        put("DM_PRESENT_SHARPEN", sharpen.map { String(format: "%.2f", min(max($0, 0), 1)) })
        return out
    }
}
