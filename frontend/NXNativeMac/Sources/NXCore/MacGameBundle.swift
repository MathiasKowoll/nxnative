import Foundation

/// Una app de Mac hecha con `--platform mac-app`. La reconoce `DMTitleID` en
/// su `Info.plist`; las rutas son las de `dm/mac/launcher.c`.
public struct MacGameBundle: Sendable, Hashable, Identifiable {
    public var url: URL
    public var titleID: String
    public var name: String
    public var version: String
    public var bundleID: String
    public var language: String?

    public var id: URL { url }

    public init?(url: URL) {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = plist["DMTitleID"] as? String, !id.isEmpty, !id.contains("/") else { return nil }
        self.url = url
        titleID = id
        name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        version = (plist["CFBundleShortVersionString"] as? String) ?? ""
        bundleID = (plist["CFBundleIdentifier"] as? String) ?? ""
        language = plist["DMLanguage"] as? String
    }

    public var launcher: URL { url.appendingPathComponent("Contents/MacOS/nxnative") }
    public var resources: URL { url.appendingPathComponent("Contents/Resources", isDirectory: true) }
    public var launcherJSON: URL { resources.appendingPathComponent("dm/launcher.json") }
    public var bundledEnv: URL { resources.appendingPathComponent("dm/env.txt") }
    public var hasPipelineArchive: Bool {
        FileManager.default.fileExists(atPath: resources.appendingPathComponent("pso").path)
    }
    public var hasAddOns: Bool {
        FileManager.default.fileExists(atPath: resources.appendingPathComponent("aoc").path)
    }

    public static var supportRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/nxnative", isDirectory: true)
    }

    /// `~/Library/Application Support/nxnative/<title ID>/`: DM_ROOT del juego.
    public var supportDirectory: URL { Self.supportRoot.appendingPathComponent(titleID, isDirectory: true) }
    public var userEnv: URL { supportDirectory.appendingPathComponent("env.txt") }
    public var saveDirectory: URL { supportDirectory.appendingPathComponent("save", isDirectory: true) }
    public var logsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/nxnative", isDirectory: true)
    }
    public var log: URL { logsDirectory.appendingPathComponent("\(titleID).log") }
    public var previousLog: URL { logsDirectory.appendingPathComponent("\(titleID).prev.log") }

    public func launcherSettings() -> LauncherSettings? { try? LauncherSettings.load(from: launcherJSON) }

    /// Busca apps de juego en cada raíz, hasta `depth` niveles. No entra en
    /// los bundles: una `.app` es una hoja.
    public static func scan(roots: [URL], depth: Int = 2) -> [MacGameBundle] {
        var seen = Set<String>()
        var out: [MacGameBundle] = []
        func visit(_ dir: URL, _ level: Int) {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for item in items {
                if item.pathExtension == "app" {
                    if let g = MacGameBundle(url: item), seen.insert(item.standardizedFileURL.path).inserted { out.append(g) }
                } else if level < depth, (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                          !item.lastPathComponent.hasSuffix("_build"), !item.lastPathComponent.hasSuffix("-work") {
                    visit(item, level + 1)
                }
            }
        }
        for r in roots { visit(r, 0) }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
