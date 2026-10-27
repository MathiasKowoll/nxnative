import Foundation
import Metal
import NXCore
import Observation

/// Una comprobación del entorno, con lo que hay que hacer si falla.
struct Check: Identifiable, Sendable {
    enum Status: Sendable { case ok, warning, failure, info }
    var id: String
    var title: String
    var status: Status
    var detail: String
}

/// Lo que nxnative necesita en este Mac, comprobado de verdad: versiones
/// leídas de las herramientas, no supuestas.
@MainActor @Observable
final class Toolchain {
    private(set) var checks: [Check] = []
    private(set) var running = false
    /// El python3 que usarán los builds (el elegido o el primero >= 3.12).
    private(set) var python: String?
    /// Un Python del sistema >= 3.12 con el que crear el entorno de la app.
    private(set) var baseCandidate: String?
    private(set) var missingModules: [String] = []
    private(set) var nszMissing = false
    private(set) var metalToolchainMissing = false
    private(set) var gpuArchitecture: String = ""
    private(set) var repoStatus: String = ""

    func refresh(_ prefs: Preferences) async {
        running = true
        defer { running = false }
        var out: [Check] = []

        // Apple silicon y Metal 4: el host de Mac no corre sin ellos.
        let arm = Self.sysctlInt("hw.optional.arm64") == 1
        out.append(Check(id: "cpu", title: "Apple silicon", status: arm ? .ok : .failure,
                         detail: arm ? "arm64" : "El host de nxnative necesita un Mac con Apple silicon."))
        let os = ProcessInfo.processInfo.operatingSystemVersion
        out.append(Check(id: "os", title: "macOS", status: os.majorVersion >= 26 ? .ok : .warning,
                         detail: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"))
        if let dev = MTLCreateSystemDefaultDevice() {
            gpuArchitecture = dev.architecture.name
            var m4 = false
            if #available(macOS 26.0, *) { m4 = dev.supportsFamily(.metal4) }
            out.append(Check(id: "gpu", title: "GPU", status: m4 ? .ok : .failure,
                             detail: "\(dev.name) · \(dev.architecture.name)"
                                 + (m4 ? " · Metal 4" : " · sin Metal 4: los juegos NVN no arrancan")))
        } else {
            out.append(Check(id: "gpu", title: "GPU", status: .failure, detail: "No hay dispositivo Metal."))
        }

        // Python >= 3.12: el script lo exige para leer la RomFS por rangos.
        python = nil
        baseCandidate = nil
        // El entorno de la app primero: es el que tiene los módulos.
        let candidates = prefs.pythonPath.isEmpty ? [PythonEnv.python] + Preferences.pythonCandidates : [prefs.pythonPath]
        var pyDetail = "No se encontró python3 >= 3.12 (brew install python)."
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            let r = await Shell.run(c, ["-c", "import sys;print('%d.%d.%d'%sys.version_info[:3])"])
            let v = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = v.split(separator: ".").compactMap { Int($0) }
            if r.ok, parts.count >= 2, (parts[0], parts[1]) >= (3, 12) {
                if c != PythonEnv.python, baseCandidate == nil { baseCandidate = c }
                if python != nil { continue }
                python = c
                pyDetail = "\(v) · \(c)"
                continue
            }
            if python == nil { pyDetail = "\(c) es \(v.isEmpty ? "ilegible" : v); hace falta 3.12 o más." }
        }
        out.append(Check(id: "python", title: "Python", status: python == nil ? .failure : .ok, detail: pyDetail))
        if let python {
            // Lo que pide check_prereqs() del script: sin esto el build se
            // para en la primera etapa.
            missingModules = await PythonEnv.missingPackages(python)
            out.append(Check(id: "modules", title: "Módulos de Python",
                             status: missingModules.isEmpty ? .ok : .failure,
                             detail: missingModules.isEmpty ? "lz4, capstone, fonttools, zstd"
                                 : "Faltan \(missingModules.joined(separator: ", ")). Pulsa «Preparar Python» abajo."))
            let nsz = await PythonEnv.missingPackages(python, includeOptional: true).contains("nsz")
            nszMissing = nsz
            out.append(Check(id: "nsz", title: "nsz (NSZ/XCZ)", status: nsz ? .info : .ok,
                             detail: nsz ? "Solo hace falta para .nsz/.xcz." : "instalado"))
        }

        // Xcode y el compilador de Metal contra el que se probó la cadena.
        let xc = await Shell.run("/usr/bin/xcodebuild", ["-version"])
        let xcVersion = xc.stdout.split(separator: "\n").first.map(String.init) ?? ""
        out.append(Check(id: "xcode", title: "Xcode", status: xc.ok ? .ok : .failure,
                         detail: xc.ok ? xcVersion : "Instala Xcode y ejecuta xcode-select -s."))
        let repo = NXRepository(root: prefs.repositoryURL)
        let metal = await Shell.run("/usr/bin/xcrun", ["-sdk", "macosx", "metal", "--version"])
        let metalLine = metal.stdout.split(separator: "\n").first.map(String.init) ?? ""
        // Desde Xcode 26 el compilador de Metal es un componente aparte: sin
        // él, xcrun encuentra el «metal» de Xcode pero no puede ejecutarlo.
        metalToolchainMissing = !metal.ok && (metal.stderr + metal.stdout).contains("Metal Toolchain")
        if metalToolchainMissing {
            out.append(Check(id: "metal", title: "Compilador de Metal", status: .failure,
                             detail: "Falta el Metal Toolchain de Xcode (unos cientos de MB de Apple). Pulsa «Descargar Metal Toolchain» abajo, o: xcodebuild -downloadComponent MetalToolchain"))
        } else if !metal.ok {
            out.append(Check(id: "metal", title: "Compilador de Metal", status: .failure,
                             detail: "xcrun metal no se ejecuta: \(metal.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"))
        } else if let wanted = repo.chainLockValues()["metal_macosx"] {
            let same = metalLine == wanted
            out.append(Check(id: "metal", title: "Compilador de Metal", status: same ? .ok : .warning,
                             detail: same ? metalLine
                                 : "Tienes «\(metalLine)»; la cadena se probó con «\(wanted)». Un juego NVN se detiene salvo con «Permitir otro Metal».")
            )
        }

        // El checkout de nxnative.
        if repo.isValid {
            let head = await Shell.run("/usr/bin/git", ["-C", repo.root.path, "log", "-1", "--format=%h %cs %s"])
            let branch = await Shell.run("/usr/bin/git", ["-C", repo.root.path, "rev-parse", "--abbrev-ref", "HEAD"])
            repoStatus = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(Check(id: "repo", title: "nxnative", status: .ok,
                             detail: "\(branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) · \(repoStatus)"))
            out.append(Check(id: "profiles", title: "Perfiles", status: .info,
                             detail: "\(repo.profiles().count) perfiles de juego en dm/games"))
        } else {
            out.append(Check(id: "repo", title: "nxnative", status: .failure,
                             detail: "No hay checkout en \(repo.root.path). Clónalo desde Entorno."))
        }

        // Las claves: solo se comprueba que existen y quién puede leerlas.
        if let keys = prefs.keysURL {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: keys.path),
               let perms = attrs[.posixPermissions] as? Int {
                let open = perms & 0o077 != 0
                out.append(Check(id: "keys", title: "prod.keys", status: open ? .warning : .ok,
                                 detail: open ? "Otros usuarios pueden leerlo (\(String(perms, radix: 8))): chmod 600"
                                              : "presente, solo legible por ti"))
            } else {
                out.append(Check(id: "keys", title: "prod.keys", status: .failure, detail: "No existe \(keys.path)"))
            }
        } else {
            out.append(Check(id: "keys", title: "prod.keys", status: .failure,
                             detail: "Elige el prod.keys volcado de TU consola. La app no lo lee: se lo pasa al script."))
        }

        // Espacio libre donde se construye.
        for root in prefs.gameRootURLs {
            if let v = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeNameKey]),
               let free = v.volumeAvailableCapacityForImportantUsage {
                let gb = Double(free) / 1e9
                out.append(Check(id: "disk-\(root.path)", title: "Espacio · \(v.volumeName ?? root.lastPathComponent)",
                                 status: gb < 30 ? .warning : .ok,
                                 detail: String(format: "%.0f GB libres en %@", gb, root.path)))
            }
        }
        checks = out
    }

    nonisolated static func sysctlInt(_ name: String) -> Int {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : 0
    }

    /// Identidades de firma de código del llavero, para `--mac-sign`.
    static func signingIdentities() async -> [String] {
        let r = await Shell.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
        return r.stdout.split(separator: "\n").compactMap { line in
            guard let a = line.firstIndex(of: "\""), let b = line.lastIndex(of: "\""), a < b else { return nil }
            return String(line[line.index(after: a)..<b])
        }
    }
}
