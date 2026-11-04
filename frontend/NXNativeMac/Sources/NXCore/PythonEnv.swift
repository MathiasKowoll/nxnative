import Foundation

/// El Python con el que la app lanza los scripts de nxnative.
///
/// El de Homebrew es «externally managed» (PEP 668): `pip install` se niega
/// a instalar en él. Por eso la app usa un entorno virtual propio en
/// `~/Library/Application Support/NXNativeMac/venv`, hecho a partir de un
/// Python >= 3.12 del sistema, con los módulos que pide
/// `check_prereqs()` de `build_ipa_from_nsp.py`.
public enum PythonEnv {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NXNativeMac/venv", isDirectory: true)
    }

    public static var python: String { directory.appendingPathComponent("bin/python3").path }

    /// Módulo que se importa → paquete de pip que lo trae. La misma lista que
    /// `check_prereqs()`; `compression.zstd` viene con Python 3.14 y antes
    /// hace falta `backports.zstd`.
    public static let required: [(module: String, package: String)] = [
        ("lz4.block", "lz4"), ("capstone", "capstone"), ("fontTools", "fonttools"),
    ]
    public static let zstd = (builtin: "compression.zstd", module: "backports.zstd", package: "backports.zstd")
    /// Solo para .nsz/.xcz.
    public static let optional: [(module: String, package: String)] = [("nsz", "nsz")]

    /// Los módulos que no se pueden importar en `python`, como paquetes de pip.
    public static func missingPackages(_ python: String, includeOptional: Bool = false) async -> [String] {
        var mods = required + (includeOptional ? optional : [])
        mods.append((zstd.module, zstd.package))
        // Un solo proceso: find_spec no importa nada, solo busca.
        let probe = """
        import importlib.util, sys
        def ok(m):
            try: return importlib.util.find_spec(m) is not None
            except ModuleNotFoundError: return False
        z = ok('\(zstd.builtin)') or ok('\(zstd.module)')
        for m in sys.argv[1:]:
            if m == '\(zstd.module)':
                if not z: print(m)
            elif not ok(m): print(m)
        """
        let r = await Shell.run(python, ["-c", probe] + mods.map(\.module))
        guard r.ok else { return mods.map(\.package) }
        let missing = Set(r.stdout.split(separator: "\n").map(String.init))
        return mods.filter { missing.contains($0.module) }.map(\.package)
    }

    /// Crea el entorno (si no existe) con `base` e instala lo que falte.
    /// `log` recibe cada paso, para enseñarlo.
    public static func setUp(base: String, includeOptional: Bool,
                             log: @Sendable (String) async -> Void) async -> Bool {
        let fm = FileManager.default
        if !fm.isExecutableFile(atPath: python) {
            await log("Creando el entorno con \(base)…")
            try? fm.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            let r = await Shell.run(base, ["-m", "venv", directory.path])
            guard r.ok else { await log("[RED] venv falló: \(r.stderr)"); return false }
        }
        let missing = await missingPackages(python, includeOptional: includeOptional)
        guard !missing.isEmpty else { await log("Nada que instalar: ya están todos."); return true }
        await log("Instalando \(missing.joined(separator: ", "))…")
        let r = await Shell.run(python, ["-m", "pip", "install", "--disable-pip-version-check"] + missing)
        guard r.ok else {
            await log("[RED] pip install falló:\n" + String(r.stderr.suffix(2000)))
            return false
        }
        let still = await missingPackages(python, includeOptional: includeOptional)
        await log(still.isEmpty ? "Listo: \(missing.joined(separator: ", "))." : "[RED] Siguen faltando: \(still.joined(separator: ", "))")
        return still.isEmpty
    }
}
