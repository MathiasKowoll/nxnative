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
        // Si hay prod.keys configurado, los archivos sin etiqueta ni ticket se
        // identifican descifrando la cabecera de su NCA de metadatos.
        let keyset = prefs.keysURL.flatMap(Keyset.init(url:))
        // Recorrer discos y leer cabeceras puede tardar: fuera del hilo principal.
        let (g, scans, prep, p, c, s) = await Task.detached {
            let scans = gameRoots.map { root -> LibraryScan in
                var scan = GameLibrary.group(GameLibrary.collect(root: root, keyset: keyset), assigned: assigned)
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
    /// Una carpeta propia solo vale si el script la sabe leer (ver
    /// `GameEntry.scriptReadable`): un XCI sin etiqueta va por la preparada.
    func buildFolder(for game: GameEntry) -> URL? {
        if game.scriptReadable, let own = game.ownFolder { return own }
        return prepared[game.base]
    }

    /// `<carpeta>/<title ID>_build`.
    func buildDirectory(for game: GameEntry) -> URL? {
        buildFolder(for: game)?.appendingPathComponent("\(game.base)_build", isDirectory: true)
    }

    /// Crea o pone al día los enlaces del juego. Se llama antes de cada build:
    /// si aparece una actualización o un DLC nuevo, entra solo.
    func prepare(_ game: GameEntry) throws -> URL {
        if game.scriptReadable, let own = game.ownFolder { return own }
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
        // El build no toca las partidas, pero reconstruir es justo cuando
        // alguien borra cosas «para empezar limpio»: copia antes, por si acaso.
        if let installed = self.game(for: game.base) { Task { await autoBackup(installed) } }
        let output = options.output?.deletingLastPathComponent() ?? options.nspFolder
        let job = BuildJob(title: "\(options.platform.label) · \(name(for: game))", folder: options.nspFolder,
                           arguments: options.arguments(script: repository.buildScript),
                           resultDirectory: output,
                           logsDirectory: options.nspFolder.appendingPathComponent("\(game.base)_build/logs"))
        return enqueue(job)
    }

    enum FCInstallTarget: Sendable, Equatable {
        case fc26, fc27

        var title: String { self == .fc26 ? "EA Sports FC 26" : "EA Sports FC 27" }
        var titleID: TitleID {
            TitleID(self == .fc26 ? "01004FF021942000" : "0100C49025D3E000")!
        }
    }

    /// Identifica FC26/FC27 leyendo los title IDs de los NSP/NSZ/XCI/XCZ.
    /// El nombre de la carpeta solo se usa como último fallback para dumps sin
    /// etiqueta que todavía no se pueden descifrar con las claves elegidas.
    func detectFCInstallTarget(gameFolder: URL, keys: URL) -> FCInstallTarget? {
        let keyset = Keyset(url: keys)
        let files = GameLibrary.collect(root: gameFolder, depth: 3, readHeaders: true, keyset: keyset)
        let bases = Set(files.compactMap { $0.titleID?.base.description.uppercased() })
        if bases.contains("01004FF021942000") { return .fc26 }
        if bases.contains("0100C49025D3E000") { return .fc27 }
        let name = gameFolder.path.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        if name.localizedCaseInsensitiveContains("fc26") { return .fc26 }
        if name.localizedCaseInsensitiveContains("fc27") { return .fc27 }
        return nil
    }

    /// Flujo de instalación de un juego que el usuario ya posee. Detecta FC26
    /// o FC27 y envía el mismo formulario al builder específico correspondiente.
    func startOneStepMacApp(gameFolder: URL, keys: URL, output: URL,
                            appName: String = "EA Sports FC 27") -> String? {
        guard let target = detectFCInstallTarget(gameFolder: gameFolder, keys: keys) else {
            return "No pude identificar FC26 o FC27 en la carpeta seleccionada. Verifica que incluya el juego y prod.keys."
        }
        guard toolchain.python != nil else {
            return "No se puede iniciar: falta Python 3.12 o posterior. Abre Entorno y pulsa «Preparar Python» o selecciona un Python compatible."
        }
        guard toolchain.missingModules.isEmpty else {
            return "No se puede iniciar: faltan módulos de Python (\(toolchain.missingModules.joined(separator: ", "))). Abre Entorno y pulsa «Preparar Python»."
        }
        guard toolchain.missingBuildTools.isEmpty else {
            return "No se puede iniciar: faltan herramientas de build (\(toolchain.missingBuildTools.joined(separator: ", "))). Corrígelo en Entorno y repite la comprobación."
        }
        if target == .fc26, !toolchain.missingFC26Tools.isEmpty {
            return "No se puede iniciar FC26: faltan dependencias (\(toolchain.missingFC26Tools.joined(separator: ", "))). Instala opus y libvpx con Homebrew y repite la comprobación."
        }
        let needsNSZ = (try? FileManager.default
            .subpathsOfDirectory(atPath: gameFolder.path)
            .contains { path in
                let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
                return ext == "nsz" || ext == "xcz"
            }) ?? false
        if needsNSZ, toolchain.nszMissing {
            return "La carpeta contiene NSZ/XCZ, pero falta el módulo nsz. Abre Entorno y pulsa «Añadir nsz»."
        }
        if target == .fc26 { return startFC26Build(gameFolder: gameFolder, keys: keys, output: output) }
        var options = BuildOptions(nspFolder: gameFolder, keys: keys)
        options.platform = .macApp
        options.output = output
        options.appName = appName
        // Cadena vacía = firma ad hoc. Si la persona eligió una identidad
        // instalada en Entorno, build_ipa_from_nsp.py la usa para el app.
        options.macSign = prefs.macSignIdentity

        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
        } catch {
            return "No se pudo preparar el destino: \(error.localizedDescription)"
        }
        let job = BuildJob(title: "Instalar \(appName)", folder: gameFolder,
                           arguments: options.arguments(script: repository.buildScript),
                           resultDirectory: output.deletingLastPathComponent())
        return enqueue(job)
    }

    private func startFC26Build(gameFolder: URL, keys: URL, output: URL) -> String? {
        let fc26Root = prefs.bundledFC26URL
            ?? URL(fileURLWithPath: "/Users/mathias/Development/fc26-mac-port", isDirectory: true)
        let script = fc26Root.appendingPathComponent("games/fc26/build.sh")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            return "Detecté FC26, pero no encuentro su builder en \(script.path). Configura el checkout fc26-mac-port."
        }
        let files = GameLibrary.collect(root: gameFolder, depth: 3, readHeaders: true, keyset: Keyset(url: keys))
        let scan = GameLibrary.group(files)
        guard let game = scan.games.first(where: { $0.base == FCInstallTarget.fc26.titleID }),
              let base = game.baseFiles.first?.url else {
            return "Detecté FC26, pero no pude separar el NSP base de la actualización."
        }
        let update = game.updates.max { ($0.version ?? 0) < ($1.version ?? 0) }?.url
        let parent = output.deletingLastPathComponent()
        let work = parent.appendingPathComponent("FC26_build", isDirectory: true)
        var args = [script.path, "--base", base.path, "--keys", keys.path, "--work", work.path, "--app", output.path, "--self-contained"]
        if let update { args += ["--update", update.path] }
        if !prefs.macSignIdentity.isEmpty { args += ["--mac-sign", prefs.macSignIdentity] }
        do { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        catch { return "No se pudo preparar el destino: \(error.localizedDescription)" }
        let job = BuildJob(title: "Construir EA Sports FC 26", folder: gameFolder, arguments: args,
                           resultDirectory: output.deletingLastPathComponent(), executable: URL(fileURLWithPath: "/bin/bash"),
                           workingDirectory: fc26Root)
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
        guard repository.isValid else { return "La toolchain de nxnative no está disponible dentro de esta app." }
        builds.enqueue(job, python: python, repository: prefs.repositoryURL)
        return nil
    }

    // MARK: - Partidas

    /// Los perfiles: cada persona que juega en este Mac con sus partidas.
    private(set) var profileBook = ProfileBook.load()
    var activeProfile: Profile { profileBook.activeProfile }

    /// La carpeta de partidas del perfil activo para este juego.
    func saveDirectory(for game: MacGameBundle) -> URL { activeProfile.saveDirectory(support: game.supportDirectory) }

    /// Las copias van separadas por perfil: restaurar nunca ofrece la partida de otro.
    var vault: SaveVault { SaveVault(root: activeProfile.backupsRoot(base: prefs.backupsURL)) }

    func backup(_ game: MacGameBundle, kind: SaveVault.Kind) async throws -> URL? {
        try await vault.backup(saveDir: saveDirectory(for: game), titleID: game.titleID, game: game.name,
                               version: game.version, kind: kind)
    }

    /// Una copia si la partida cambió desde la última. Un fallo aquí no debe
    /// impedir jugar: se anota y se sigue.
    func autoBackup(_ game: MacGameBundle) async {
        guard prefs.autoBackup else { return }
        do {
            if let url = try await vault.autoBackup(saveDir: saveDirectory(for: game), titleID: game.titleID,
                                                     game: game.name, version: game.version) {
                notice = "Copia automática de \(game.name): \(url.lastPathComponent)"
            }
        } catch {
            notice = "No se pudo hacer la copia automática de \(game.name): \(error.localizedDescription)"
        }
    }

    func selectProfile(_ id: String) {
        guard profileBook.profiles.contains(where: { $0.id == id }) else { return }
        profileBook.active = id
        saveProfiles()
    }

    @discardableResult
    func addProfile(named name: String) -> Profile {
        let p = profileBook.add(name: name)
        saveProfiles()
        return p
    }

    func renameProfile(_ id: String, to name: String) {
        profileBook.rename(id, to: name)
        saveProfiles()
    }

    /// Quita un perfil. Con `discardSaves`, sus partidas y sus copias van a la
    /// Papelera (no se borran); sin él se quedan en disco, y un perfil nuevo
    /// con el mismo nombre las vuelve a encontrar.
    func removeProfile(_ id: String, discardSaves: Bool) {
        guard let p = profileBook.profiles.first(where: { $0.id == id }), !p.isMain else { return }
        if discardSaves {
            var dirs = [p.backupsRoot(base: prefs.backupsURL)]
            if let ids = try? FileManager.default.contentsOfDirectory(atPath: MacGameBundle.supportRoot.path) {
                dirs += ids.map { MacGameBundle.supportRoot.appendingPathComponent("\($0)/perfiles/\(p.id)", isDirectory: true) }
            }
            var failed = 0
            for d in dirs where FileManager.default.fileExists(atPath: d.path) {
                do { try SaveVault.toTrash(d) } catch { failed += 1 }
            }
            if failed > 0 { notice = "\(failed) carpetas de \(p.name) no se pudieron llevar a la Papelera." }
        }
        profileBook.remove(id)
        saveProfiles()
    }

    private func saveProfiles() {
        do { try profileBook.save() } catch { notice = "No se pudieron guardar los perfiles: \(error.localizedDescription)" }
    }

    /// Borra la partida del perfil activo, con una copia antes.
    func deleteSave(_ game: MacGameBundle) async throws {
        try await vault.delete(saveDir: saveDirectory(for: game), titleID: game.titleID, game: game.name, version: game.version)
    }

    /// Todas las partidas del perfil activo, de los juegos instalados, en un zip.
    func exportAllSaves(to out: URL) async throws -> Int {
        let list = games.map { SaveVault.GameSave(titleID: $0.titleID, game: $0.name, version: $0.version, saveDir: saveDirectory(for: $0)) }
        return try await vault.exportAll(list, profile: activeProfile.name, to: out)
    }

    /// Importa en el perfil activo. Un juego que no está instalado también
    /// recibe su partida, en la carpeta que usará al instalarlo (la de su
    /// title ID): reinstalar o construir después no la pierde.
    func importAllSaves(from archive: URL) async throws -> [SaveVault.ImportResult] {
        let installed = games, profile = activeProfile
        return try await vault.importAll(archive) { e in
            if let g = installed.first(where: { $0.titleID.uppercased() == e.titleID.uppercased() }) {
                return .init(titleID: g.titleID, game: g.name, version: g.version, saveDir: profile.saveDirectory(support: g.supportDirectory))
            }
            let support = MacGameBundle.supportRoot.appendingPathComponent(e.titleID.uppercased(), isDirectory: true)
            return .init(titleID: e.titleID.uppercased(), game: e.game, version: "", saveDir: profile.saveDirectory(support: support))
        }
    }

    /// Jugar desde la app: primero la copia automática, luego el juego.
    func play(_ game: MacGameBundle) {
        Task {
            await autoBackup(game)
            // El lanzador solo crea su carpeta de partidas, no la que le pasan.
            if !activeProfile.isMain { try? FileManager.default.createDirectory(at: saveDirectory(for: game), withIntermediateDirectories: true) }
            runner.launch(game, extra: Self.launchEnvironment(for: game, globals: prefs.globalDefaults, profile: activeProfile))
        }
    }

    /// Variables que tienen que estar en el entorno ANTES de que arranque el
    /// host. Metal lee `MTL_HUD_ENABLED` al cargar su librería, antes que los
    /// constructores del host, así que el `setenv` que hace el host al leer
    /// `DM_METAL_HUD` llega tarde y el HUD no sale. Medido en macOS 27: con
    /// la variable puesta antes del arranque el HUD aparece, por las dos vías
    /// de presentado (clásica y Metal 4); puesta en un constructor, no. El
    /// lanzador lo pasa al host tal cual (`posix_spawn` con su `environ`).
    /// Los lanzadores nuevos ya lo hacen solos; esto cubre las apps hechas
    /// antes de ese cambio.
    ///
    /// `DM_LAUNCHER=0`: el launcher genérico no muestra su ventana porque esta
    /// app administra los ajustes desde su propia interfaz. Los launchers FC
    /// específicos se integrarán en el bundle final de cada juego.
    ///
    /// `globals`: los valores para todos los juegos (Entorno), salvo los que
    /// el juego fija en su propio env.txt.
    ///
    /// `profile`: con un perfil que no es «Principal», `DM_SAVE` apunta a su
    /// carpeta. El lanzador solo pone la suya si no viene ya fijada.
    static func launchEnvironment(for game: MacGameBundle, globals: GlobalDefaults = GlobalDefaults(),
                                  profile: Profile = .main) -> [String: String] {
        var env = globals.environment(userEnv: EnvFile(contentsOf: game.userEnv))
        env["DM_LAUNCHER"] = "0"
        if !profile.isMain { env["DM_SAVE"] = profile.saveDirectory(support: game.supportDirectory).path }
        // El mismo orden que el lanzador: el env.txt del jugador gana al del bundle.
        let hud = EnvFile(contentsOf: game.userEnv)["DM_METAL_HUD"] ?? EnvFile(contentsOf: game.bundledEnv)["DM_METAL_HUD"]
        if let hud, (Int(hud.trimmingCharacters(in: .whitespaces)) ?? 0) != 0 {
            env["MTL_HUD_ENABLED"] = "1"; env["MTL_HUD_HIDE_METALFX_METRICS"] = "1"
        }
        return env
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

}
