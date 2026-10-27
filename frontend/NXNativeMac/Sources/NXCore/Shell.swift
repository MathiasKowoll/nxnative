import Foundation

/// Ejecutar un comando corto y recoger su salida. Para los procesos largos
/// (el build, el juego) la app tiene sus propios gestores.
public enum Shell {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
        public var ok: Bool { status == 0 }
    }

    /// Una app lanzada desde Finder hereda un PATH mínimo: se le añaden las
    /// rutas de Homebrew para encontrar python3, git y compañía.
    public static func environment(extraPath: [String] = []) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let base = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var parts = extraPath + ["/opt/homebrew/bin", "/usr/local/bin"]
        for p in base.split(separator: ":").map(String.init) where !parts.contains(p) { parts.append(p) }
        env["PATH"] = parts.joined(separator: ":")
        return env
    }

    public static func run(_ executable: String, _ args: [String], cwd: URL? = nil,
                           env: [String: String]? = nil) async -> Output {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = args
            p.currentDirectoryURL = cwd
            p.environment = env ?? environment()
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            do {
                try p.run()
            } catch {
                cont.resume(returning: Output(status: -1, stdout: "", stderr: error.localizedDescription))
                return
            }
            // Leer las dos tuberías a la vez y antes de esperar: si una se
            // llena mientras leemos la otra, el hijo se bloquea.
            DispatchQueue.global().async {
                nonisolated(unsafe) var e = Data()
                let g = DispatchGroup()
                DispatchQueue.global().async(group: g) { e = err.fileHandleForReading.readDataToEndOfFile() }
                let o = out.fileHandleForReading.readDataToEndOfFile()
                g.wait()
                p.waitUntilExit()
                cont.resume(returning: Output(status: p.terminationStatus,
                                              stdout: String(decoding: o, as: UTF8.self),
                                              stderr: String(decoding: e, as: UTF8.self)))
            }
        }
    }

    /// `/usr/bin/env <tool>`, para lo que vive en el PATH.
    public static func tool(_ name: String, _ args: [String], cwd: URL? = nil) async -> Output {
        await run("/usr/bin/env", [name] + args, cwd: cwd)
    }
}
