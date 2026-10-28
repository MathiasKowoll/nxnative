import Foundation

/// «120 Hz (experimental)»: los cuatro interruptores con los que nxnative
/// presenta hasta 120 imágenes por segundo (docs/reference/frame-rate.md,
/// «One frame per tick of a 120 Hz display link»: Batman: Arkham Knight a
/// 119,8 fps en un M2 Max).
///
/// Solo sirve en juegos cuyo motor mide el tiempo entre imágenes (Unreal,
/// muchos de Unity) y sin un tope propio a 30 o 60; uno con la lógica atada
/// a las imágenes no pasa de su tope o va acelerado. Por eso es por juego y
/// experimental: se prueba y se deja donde va bien.
public enum HighRefresh {
    /// Variable → valor. DM_FPS_TARGET=0 deja el límite propio del juego en
    /// vez del tope de 30/60 del perfil.
    public static let values: [(key: String, value: String)] = [
        ("DM_PRESENT_LINK", "2"),          // reloj de la pantalla a 120 Hz
        ("DM_PRESENT_HZ", "120"),          // hasta 120 imágenes por segundo
        ("DM_PRESENT_INTERVAL", "display"),// una imagen por refresco, no el intervalo del juego
        ("DM_FPS_TARGET", "0"),            // sin el tope 30/60 del perfil
    ]

    /// Encendido = las cuatro variables con estos valores.
    public static func isOn(_ env: EnvFile) -> Bool {
        values.allSatisfy { env[$0.key] == $0.value }
    }

    /// Variables que el jugador fijó a mano con otro valor: encender las
    /// pisaría, así que se enseñan antes.
    public static func conflicts(_ env: EnvFile) -> [String] {
        values.compactMap { v in env[v.key].flatMap { $0 != v.value ? "\(v.key)=\($0)" : nil } }
    }

    /// Apagar quita solo lo que tenga exactamente nuestro valor: una línea que
    /// el jugador escribió con otro valor se queda.
    public static func set(_ on: Bool, in env: inout EnvFile) {
        for v in values {
            if on { env[v.key] = v.value }
            else if env[v.key] == v.value { env[v.key] = nil }
        }
    }
}
