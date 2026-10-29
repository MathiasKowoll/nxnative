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
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        guard let id = Self.titleID(in: plist) else { return nil }
        self.url = url
        titleID = id
        name = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        version = (plist["CFBundleShortVersionString"] as? String) ?? ""
        bundleID = (plist["CFBundleIdentifier"] as? String) ?? ""
        language = plist["DMLanguage"] as? String
    }

    /// Los wrappers anteriores al formato `mac-app` no traen `DMTitleID`, pero
    /// apuntan a una carpeta de trabajo con el manifiesto de extracción. Ese
    /// manifiesto identifica la misma app sin codificar un título concreto.
    private static func titleID(in plist: [String: Any]) -> String? {
        if let id = plist["DMTitleID"] as? String,
           !id.isEmpty, !id.contains("/"), TitleID(id) != nil {
            return id.uppercased()
        }
        guard let path = (plist["DMWorkFolder"] as? String) ?? (plist["FC26WorkFolder"] as? String),
              !path.isEmpty else { return nil }
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        var manifests = [root.appendingPathComponent("extraction-manifest.json")]
        let extracted = root.appendingPathComponent("extracted", isDirectory: true)
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: extracted, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            manifests += versions.map { $0.appendingPathComponent("extraction-manifest.json") }
        }
        for manifest in manifests {
            guard let data = try? Data(contentsOf: manifest),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let inventory = object["nca_inventory"] as? [[String: Any]] {
                for item in inventory {
                    guard let raw = item["title_id"] as? String,
                          let title = TitleID(raw) else { continue }
                    return title.base.description
                }
            }
            if let source = object["source"] as? String, let id = titleID(inFileName: source) {
                return id
            }
        }
        return nil
    }

    private static func titleID(inFileName name: String) -> String? {
        guard let open = name.firstIndex(of: "["),
              let close = name[name.index(after: open)...].firstIndex(of: "]") else { return nil }
        let raw = String(name[name.index(after: open)..<close])
        return TitleID(raw)?.base.description
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
    /// los bundles: una `.app` es una hoja. Si dos copias declaran el mismo
    /// título, deja la que se modificó más recientemente para que el selector
    /// no muestre el mismo juego dos veces.
    public static func scan(roots: [URL], depth: Int = 2) -> [MacGameBundle] {
        var seen = Set<String>()
        var byTitle: [String: (date: Date, game: MacGameBundle)] = [:]
        func visit(_ dir: URL, _ level: Int) {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
            for item in items {
                if item.pathExtension == "app" {
                    guard let game = MacGameBundle(url: item),
                          seen.insert(item.standardizedFileURL.path).inserted else { continue }
                    let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                        ?? .distantPast
                    if let previous = byTitle[game.titleID], previous.date >= date { continue }
                    byTitle[game.titleID] = (date, game)
                } else if level < depth, (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                          !item.lastPathComponent.hasSuffix("_build"), !item.lastPathComponent.hasSuffix("-work") {
                    visit(item, level + 1)
                }
            }
        }
        for r in roots { visit(r, 0) }
        return byTitle.values.map(\.game)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
