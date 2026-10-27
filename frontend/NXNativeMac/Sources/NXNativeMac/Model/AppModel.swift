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
    private(set) var folders: [NSPFolder] = []
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
        // Recorrer discos puede tardar: fuera del hilo principal.
        let (g, f, p, c, s) = await Task.detached {
            (MacGameBundle.scan(roots: appRoots, depth: 2),
             gameRoots.flatMap { NSPFolder.scan(root: $0, depth: 2) },
             repo.profiles(), repo.compatibility(), repo.switches())
        }.value
        games = g
        folders = f.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        profiles = p
        compatibility = c
        switches = s
        await toolchain.refresh(prefs)
    }

    enum ProfileState { case registered, unknown, noTitleID }

    func profileState(_ folder: NSPFolder) -> ProfileState {
        guard let id = folder.baseTitleID else { return .noTitleID }
        return profiles.contains(id) ? .registered : .unknown
    }

    func game(for id: TitleID) -> MacGameBundle? { games.first { $0.titleID.uppercased() == id.description } }
    func folder(for id: TitleID) -> NSPFolder? { folders.first { $0.baseTitleID == id } }

    func defaultOptions(for folder: NSPFolder) -> BuildOptions? {
        guard let keys = prefs.keysURL else { return nil }
        var o = BuildOptions(nspFolder: folder.url, keys: keys)
        o.macSign = prefs.macSignIdentity
        return o
    }

    /// Devuelve un error legible, o nil si el build quedó en cola.
    func startBuild(_ options: BuildOptions, title: String) -> String? {
        let output = options.output?.deletingLastPathComponent() ?? options.nspFolder
        let job = BuildJob(title: title, folder: options.nspFolder,
                           arguments: options.arguments(script: repository.buildScript),
                           resultDirectory: output)
        return enqueue(job)
    }

    /// `scripts/bench.py <build>`: la ruta fija del perfil, con percentiles de
    /// tiempo de fotograma. Exige un build `--platform mac` previo.
    func startBenchmark(_ folder: NSPFolder, runs: Int = 2) -> String? {
        guard let build = folder.buildDirectory else { return "La carpeta no tiene title ID." }
        let job = BuildJob(title: "Benchmark · \(folder.name)", folder: folder.url,
                           arguments: [repository.benchScript.path, build.path, "--runs", "\(runs)"],
                           resultDirectory: build.appendingPathComponent("bench", isDirectory: true))
        return enqueue(job)
    }

    private func enqueue(_ job: BuildJob) -> String? {
        guard let python = toolchain.python else { return "No hay python3 >= 3.12: revisa Entorno." }
        guard repository.isValid else { return "No hay checkout de nxnative: revisa Entorno." }
        builds.enqueue(job, python: python, repository: prefs.repositoryURL)
        return nil
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
