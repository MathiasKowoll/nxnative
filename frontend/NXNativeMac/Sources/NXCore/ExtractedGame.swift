import Foundation

/// Metadata-only discovery. Never walk RomFS or infer identity from folder names.
public struct ExtractedGame: Sendable, Hashable {
    public let folder: URL
    public let exefs: URL
    public let romfs: URL
    public let titleID: TitleID
    public let canonicalLayout: Bool
    public var isSwitch2: Bool { titleID.value >> 56 == 4 }

    public static func inspect(_ folder: URL) -> ExtractedGame? {
        let fm = FileManager.default
        func directory(_ parent: URL, _ name: String) -> URL? {
            let matches = ((try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { $0.lastPathComponent.lowercased() == name && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            return matches.count == 1 ? matches[0] : nil
        }
        let roots = [folder] + (directory(folder, "base").map { [$0] } ?? [])
        let pairs = roots.compactMap { root -> (URL, URL, URL)? in
            guard let exe = directory(root, "exefs"), let rom = directory(root, "romfs") else { return nil }
            return (root, exe, rom)
        }
        guard pairs.count == 1, let pair = pairs.first else { return nil }
        let npdm = pair.1.appendingPathComponent("main.npdm")
        guard let size = try? npdm.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              (128...1_048_576).contains(size), let handle = try? FileHandle(forReadingFrom: npdm) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: size), data.count == size,
              data.prefix(4) == Data("META".utf8), data[12] & 1 != 0 else { return nil }
        func word(_ offset: Int, _ bytes: Int) -> UInt64 {
            (0..<bytes).reduce(0) { $0 | UInt64(data[offset + $1]) << (8 * $1) }
        }
        let offset = Int(word(0x70, 4)), length = Int(word(0x74, 4))
        guard offset >= 128, length >= 32, offset <= data.count,
              length <= data.count - offset,
              data.subdata(in: offset..<offset + 4) == Data("ACI0".utf8) else { return nil }
        let id = word(offset + 16, 8)
        guard id != 0, id & 0xfff == 0 else { return nil }
        for module in ["main", "sdk"] {
            guard let h = try? FileHandle(forReadingFrom: pair.1.appendingPathComponent(module)) else { return nil }
            let magic = try? h.read(upToCount: 4); try? h.close()
            guard magic == Data("NSO0".utf8) else { return nil }
        }
        return ExtractedGame(folder: folder, exefs: pair.1, romfs: pair.2, titleID: TitleID(value: id),
                             canonicalLayout: pair.0.standardizedFileURL != folder.standardizedFileURL && pair.0.lastPathComponent == "base" && pair.1.lastPathComponent == "exefs" && pair.2.lastPathComponent == "romfs")
    }

    public static func collect(root: URL, depth: Int = 3) -> [ExtractedGame] {
        var result: [ExtractedGame] = []
        var visited = Set<String>()
        func visit(_ folder: URL, _ level: Int) {
            guard visited.insert(folder.resolvingSymlinksInPath().path).inserted else { return }
            if let source = inspect(folder) { result.append(source); return }
            guard level < depth else { return }
            for child in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? [] {
                let name = child.lastPathComponent.lowercased()
                guard !GameLibrary.skip(child.lastPathComponent), !["exefs", "romfs", "updates", "dlc", "references"].contains(name),
                      !name.hasSuffix(".app"), !name.hasSuffix("_survey"),
                      let attrs = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      attrs.isDirectory == true, attrs.isSymbolicLink != true else { continue }
                visit(child, level + 1)
            }
        }
        visit(root, 0)
        return result.sorted { $0.folder.path < $1.folder.path }
    }
}

extension GameLibrary {
    public static func discover(root: URL, keyset: Keyset? = nil, assigned: [String: TitleID] = [:]) -> LibraryScan {
        var scan = group(collect(root: root, keyset: keyset), assigned: assigned)
        for i in scan.games.indices { scan.games[i].root = root }
        var seen = Set(scan.games.map(\.base))
        for source in ExtractedGame.collect(root: root) where seen.insert(source.titleID).inserted {
            scan.games.append(GameEntry(base: source.titleID, files: [], ownFolder: source.folder, root: root, extracted: source))
        }
        scan.games.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return scan
    }
}
