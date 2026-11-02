import Foundation
import NXCore

extension AppModel {
    func workshopIssues(for source: GameEntry?, platform: BuildOptions.Platform) -> [String] {
        var issues: [String] = []
        guard let source else { return ["No se encuentran los archivos originales. Añade su carpeta y vuelve a escanear."] }
        if !source.hasBase { issues.append("Falta el archivo base del juego.") }
        if source.files.contains(where: { !FileManager.default.fileExists(atPath: $0.url.path) }) {
            issues.append("Algunos archivos ya no están disponibles. Comprueba el disco y vuelve a escanear.")
        }
        if prefs.keysURL.map({ FileManager.default.fileExists(atPath: $0.path) }) != true {
            issues.append("Elige tu archivo prod.keys.")
        }
        if toolchain.python == nil { issues.append("Falta Python 3.12 o posterior; revísalo en Global.") }
        if !repository.isValid { issues.append("La toolchain de la app no está disponible.") }
        if !toolchain.missingModules.isEmpty { issues.append("Faltan módulos: " + toolchain.missingModules.joined(separator: ", ")) }
        if !toolchain.missingBuildTools.isEmpty { issues.append("Faltan herramientas: " + toolchain.missingBuildTools.joined(separator: ", ")) }
        if source.base == FCInstallTarget.fc26.titleID {
            if platform == .ios { issues.append("El builder específico de FC26 produce una app de Mac.") }
            if !toolchain.missingFC26Tools.isEmpty { issues.append("Faltan dependencias de FC26: " + toolchain.missingFC26Tools.joined(separator: ", ")) }
        }
        if source.files.contains(where: { ["nsz", "xcz"].contains($0.url.pathExtension.lowercased()) }), toolchain.nszMissing {
            issues.append("Hace falta el módulo nsz para estos archivos comprimidos.")
        }
        if let installed = game(for: source.base), runner.isRunning(installed) || gameLaunchPending(installed.titleID) {
            issues.append("Cierra este juego antes de reconstruirlo.")
        }
        if builds.jobs.contains(where: { $0.isActive && $0.titleID == source.base.description }) { issues.append("Este juego ya tiene un trabajo activo o en cola.") }
        return issues
    }

    func workshopOutput(for source: GameEntry, platform: BuildOptions.Platform, directory: URL?) -> URL {
        if platform == .macApp, directory == nil, let installed = game(for: source.base) { return installed.url }
        let folder = directory ?? (platform == .macApp ? prefs.gameAppsURL : (source.root ?? prefs.gameAppsURL))
        let name = self.name(for: source).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return folder.appendingPathComponent(name).appendingPathExtension(platform == .ios ? "ipa" : "app")
    }

    func startWorkshopBuild(source: GameEntry, platform: BuildOptions.Platform, output: URL) -> String? {
        let issues = workshopIssues(for: source, platform: platform)
        guard issues.isEmpty else { return issues.joined(separator: "\n") }
        do {
            var options = try defaultOptions(for: source).get()
            options.platform = platform
            options.output = output
            options.appName = name(for: source)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let error: String?
            if source.base == FCInstallTarget.fc26.titleID {
                error = startOneStepMacApp(gameFolder: options.nspFolder, keys: options.keys, output: output, appName: options.appName)
            } else {
                error = startBuild(options, game: source)
            }
            if error == nil, platform == .macApp {
                let path = output.deletingLastPathComponent().path
                if !prefs.appRoots.contains(path) { prefs.appRoots.append(path) }
            }
            return error
        } catch { return error.localizedDescription }
    }

    func retryWorkshopBuild(_ job: BuildJob) -> String? {
        guard !job.isActive else { return "El trabajo sigue activo." }
        guard !job.earlierProcessMayBeRunning else { return "Todavía existe un proceso de la sesión anterior. Revisa su estado antes de reintentar; no se lanzará una segunda compilación." }
        return enqueue(job.retryCopy())
    }

    /// Rechecked when a queued job actually starts, including retries after relaunch.
    func prepareWorkshopJob(_ job: BuildJob) async -> String? {
        if !toolchain.missingModules.isEmpty { return "Faltan módulos de Python: " + toolchain.missingModules.joined(separator: ", ") }
        if !toolchain.missingBuildTools.isEmpty { return "Faltan herramientas: " + toolchain.missingBuildTools.joined(separator: ", ") }
        if job.titleID == FCInstallTarget.fc26.titleID.description, !toolchain.missingFC26Tools.isEmpty {
            return "Faltan dependencias de FC26: " + toolchain.missingFC26Tools.joined(separator: ", ")
        }
        guard FileManager.default.fileExists(atPath: job.folder.path) else { return "No se encuentra el disco o la carpeta de origen." }
        if let script = job.arguments.first, !FileManager.default.fileExists(atPath: script) { return "No se encuentra el script del builder. Vuelve a preparar este trabajo." }
        for key in ["-k", "--keys"] {
            if let index = job.arguments.firstIndex(of: key), job.arguments.indices.contains(index + 1),
               !FileManager.default.fileExists(atPath: job.arguments[index + 1]) { return "No se encuentra el archivo de claves del trabajo." }
        }
        if let id = job.titleID.flatMap(TitleID.init), let installed = game(for: id) {
            guard !runner.isRunning(installed), !gameLaunchPending(installed.titleID) else { return "El juego está abierto. Ciérralo antes de reconstruirlo." }
            await autoBackup(installed)
        }
        return nil
    }
}
