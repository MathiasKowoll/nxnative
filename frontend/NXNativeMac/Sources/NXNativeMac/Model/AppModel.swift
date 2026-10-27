import Foundation
import NXCore
import Observation

/// El estado de la app: preferencias, lo encontrado en disco y los gestores.
@MainActor @Observable
final class AppModel {
    let prefs = Preferences()
    let toolchain = Toolchain()
    let builds = BuildQueue()
    let runner = GameRunner()

    private(set) var games: [MacGameBundle] = []
    /// Los juegos en disco, agrupados por title ID base.
    private(set) var library: [GameEntry] = []
    /// Archivos sin title ID legible (un XCI sin etiqueta en el nombre).
    private(set) var unidentified: [GameFile] = []
    /// Carpetas ya preparadas con enlaces, por title ID.
    private(set) var prepared: [TitleID: URL] = [:]
    private(set) var profiles: Set<TitleID> = []
    private(set) var compatibility: [CompatibilityEntry] = []
    private(set) var switches: [EnvSwitch] = []
    private(set) var scanning = false
    /// Mensaje de la última operación de mantenimiento (git, etc.).
    var notice: String?

    var repository: NXRepository { NXRepository(root: prefs.repositoryURL) }

    func refresh() async {
        scanning = true
        defer { scanning = false }
        let repo = repository
        let gameRoots = prefs.gameRootURLs
        let appRoots = prefs.appRootURLs + gameRoots
        let assigned = prefs.assignedTitleIDs.compactMapValues { TitleID($0) }
        // Recorrer discos y leer cabeceras puede tardar: fuera del hilo principal.
        let (g, scans, prep, p, c, s) = await Task.detached {
            let scans = gameRoots.map { root -> LibraryScan in
                var scan = GameLibrary.group(GameLibrary.collect(root: root), assigned: assigned)
                for i in scan.games.indices { scan.games[i].root = root }
                return scan
            }
            var prep: [TitleID: URL] = [:]
            for r in gameRoots { prep.merge(PreparedFolder.existing(root: r)) { a, _ in a } }
            return (MacGameBundle.scan(roots: appRoots, depth: 3), scans, prep,
                    repo.profiles(), repo.compatibility(), repo.switches())
        }.value
        games = g
        library = scans.flatMap(\.games)
        unidentified = scans.flatMap(\.unidentified)
        prepared = prep
        profiles = p
        compatibility = c
        switches = s
        await toolchain.refresh(prefs)
    }

    enum ProfileState { case registered, unknown }

    func profileState(_ game: GameEntry) -> ProfileState {
        profiles.contains(game.base) ? .registered : .unknown
    }

    func game(for id: TitleID) -> MacGameBundle? { games.first { $0.titleID.uppercased() == id.description } }
    func entry(for id: TitleID) -> GameEntry? { library.first { $0.base == id } }
    func compat(for id: TitleID) -> CompatibilityEntry? { compatibility.first { $0.titleID == id } }

    func name(for game: GameEntry) -> String { compat(for: game.base)?.name ?? game.displayName }

    /// La carpeta que recibe el script: la del juego si la tiene para él solo,
    /// si no la preparada con enlaces.
    func buildFolder(for game: GameEntry) -> URL? { game.ownFolder ?? prepared[game.base] }

    /// `<carpeta>/<title ID>_build`.
    func buildDirectory(for game: GameEntry) -> URL? {
        buildFolder(for: game)?.appendingPathComponent("\(game.base)_build", isDirectory: true)
    }

    /// Crea o pone al día los enlaces del juego. Se llama antes de cada build:
    /// si aparece una actualización o un DLC nuevo, entra solo.
    func prepare(_ game: GameEntry) throws -> URL {
        if let own = game.ownFolder { return own }
        guard let root = game.root else { throw NSError(domain: "NXNativeMac", code: 10) }
        let dir = try PreparedFolder.sync(game, root: root, name: name(for: game))
        prepared[game.base] = dir
        return dir
    }

    func assign(_ id: TitleID, to file: GameFile) async {
        prefs.assignedTitleIDs[file.url.path] = id.description
        await refresh()
    }

    func outputs(for game: GameEntry) -> [URL] {
        guard let dir = buildFolder(for: game) else { return [] }
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items.filter { ["ipa", "app"].contains($0.pathExtension.lowercased()) }
    }

    func defaultOptions(for game: GameEntry) -> Result<BuildOptions, Error> {
        guard let keys = prefs.keysURL else {
            return .failure(NSError(domain: "NXNativeMac", code: 11, userInfo: [NSLocalizedDescriptionKey: "Falta prod.keys: elígelo en Entorno."]))
        }
        return Result {
            var o = BuildOptions(nspFolder: try prepare(game), keys: keys)
            o.macSign = prefs.macSignIdentity
            return o
        }
    }

    /// Devuelve un error legible, o nil si el build quedó en cola.
    func startBuild(_ options: BuildOptions, game: GameEntry) -> String? {
        let output = options.output?.deletingLastPathComponent() ?? options.nspFolder
        let job = BuildJob(title: "\(options.platform.label) · \(name(for: game))", folder: options.nspFolder,
                           arguments: options.arguments(script: repository.buildScript),
                           resultDirectory: output,
                           logsDirectory: options.nspFolder.appendingPathComponent("\(game.base)_build/logs"))
        return enqueue(job)
    }

    /// `scripts/bench.py <build>`: la ruta fija del perfil, con percentiles de
    /// tiempo de fotograma. Exige un build `--platform mac` previo.
    func startBenchmark(_ game: GameEntry, runs: Int = 2) -> String? {
        guard let build = buildDirectory(for: game), let folder = buildFolder(for: game) else { return "El juego no tiene carpeta de build." }
        let job = BuildJob(title: "Benchmark · \(name(for: game))", folder: folder,
                           arguments: [repository.benchScript.path, build.path, "--runs", "\(runs)"],
                           resultDirectory: build.appendingPathComponent("bench", isDirectory: true),
                           logsDirectory: build.appendingPathComponent("bench", isDirectory: true))
        return enqueue(job)
    }

    private func enqueue(_ job: BuildJob) -> String? {
        guard let python = toolchain.python else { return "No hay python3 >= 3.12: revisa Entorno." }
        guard repository.isValid else { return "No hay checkout de nxnative: revisa Entorno." }
        builds.enqueue(job, python: python, repository: prefs.repositoryURL)
        return nil
    }

    // MARK: - Python

    private(set) var settingUpPython = false
    private(set) var pythonLog: [String] = []

    /// Crea el entorno virtual de la app e instala los módulos del script.
    func setUpPython(includeOptional: Bool) async {
        guard let base = toolchain.baseCandidate ?? toolchain.python else {
            pythonLog = ["[RED] No hay un python3 >= 3.12 con el que crear el entorno (brew install python)."]
            return
        }
        settingUpPython = true
        pythonLog = []
        let ok = await PythonEnv.setUp(base: base, includeOptional: includeOptional) { line in
            await MainActor.run { self.pythonLog.append(line) }
        }
        // Que los builds usen el entorno, aunque se hubiera elegido otro Python.
        if ok, prefs.pythonPath != PythonEnv.python { prefs.pythonPath = "" }
        settingUpPython = false
        await toolchain.refresh(prefs)
    }

    private(set) var downloadingMetal = false

    /// `xcodebuild -downloadComponent MetalToolchain`: lo descarga Apple, la
    /// app solo lo lanza cuando el jugador pulsa el botón.
    func downloadMetalToolchain() async {
        downloadingMetal = true
        notice = "Descargando el Metal Toolchain de Apple…"
        let r = await Shell.run("/usr/bin/xcodebuild", ["-downloadComponent", "MetalToolchain"])
        notice = r.ok ? "Metal Toolchain instalado."
                      : "La descarga falló: \(String(r.stderr.suffix(600)))"
        downloadingMetal = false
        await toolchain.refresh(prefs)
    }

    // MARK: - El checkout de nxnative

    static let upstream = "https://github.com/MathiasKowoll/nxnative.git"

    func cloneRepository() async {
        let dest = prefs.repositoryURL
        notice = "Clonando \(Self.upstream)…"
        let r = await Shell.run("/usr/bin/git", ["clone", Self.upstream, dest.path])
        notice = r.ok ? "Clonado en \(dest.path)" : "git clone falló: \(r.stderr)"
        await refresh()
    }

    /// Solo avance rápido: si hay cambios locales o ramas divergentes, git se
    /// niega y se dice; la app no resuelve conflictos por su cuenta.
    func updateRepository() async {
        notice = "Actualizando nxnative…"
        let r = await Shell.run("/usr/bin/git", ["-C", prefs.repositoryURL.path, "pull", "--ff-only"])
        notice = r.ok ? r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                      : "git pull --ff-only falló: \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        await refresh()
    }
}
