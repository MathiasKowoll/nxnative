import Foundation
import Testing
@testable import NXCore

@Suite struct ExtractedGameTests {
    private func fixture(_ root: URL, name: String, id: UInt64 = 0x040074A01BF12000) throws -> URL {
        let folder = root.appendingPathComponent(name)
        let exe = folder.appendingPathComponent("base/exefs")
        try FileManager.default.createDirectory(at: exe, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("base/romfs"), withIntermediateDirectories: true)
        var data = Data(repeating: 0, count: 160)
        data.replaceSubrange(0..<4, with: Data("META".utf8)); data[12] = 1
        data[0x70] = 128; data[0x74] = 32
        data.replaceSubrange(128..<132, with: Data("ACI0".utf8))
        for i in 0..<8 { data[144 + i] = UInt8(truncatingIfNeeded: id >> (8 * i)) }
        try data.write(to: exe.appendingPathComponent("main.npdm"))
        for name in ["main", "sdk"] { try Data("NSO0".utf8).write(to: exe.appendingPathComponent(name)) }
        return folder
    }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func discoversSourcesWithoutAddingInstalledApps() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try fixture(root, name: "Any name")
        _ = try fixture(root, name: "Another", id: 0x0400C3F00006E000)
        _ = try fixture(root, name: "ignored_build")
        let scan = GameLibrary.discover(root: root)
        #expect(scan.games.count == 2)
        #expect(scan.games.allSatisfy { $0.extracted?.isSwitch2 == true && $0.hasBase && $0.scriptReadable })
        #expect(MacGameBundle.scan(roots: [root]).isEmpty)
        let options = BuildOptions(nspFolder: scan.games[0].ownFolder!, keys: nil)
        let args = options.arguments(script: URL(fileURLWithPath: "/builder.py"))
        #expect(!args.contains("-k"))
        #expect(args[1] == scan.games[0].ownFolder?.path)
    }

    @Test func invalidMetadataAndMissingModulesAreRejected() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, name: "Bad")
        let npdm = folder.appendingPathComponent("base/exefs/main.npdm")
        var data = try Data(contentsOf: npdm); data[0x70] = 240; try data.write(to: npdm)
        #expect(ExtractedGame.inspect(folder) == nil)
        _ = try fixture(root, name: "Bad")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("base/exefs/sdk"))
        #expect(ExtractedGame.inspect(folder) == nil)
    }

    @Test func directAndDuplicateSourcesRemainUnambiguous() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = try fixture(root, name: "Direct")
        #expect(ExtractedGame.inspect(folder.appendingPathComponent("base"))?.canonicalLayout == false)
        _ = try fixture(root, name: "Copy")
        #expect(GameLibrary.discover(root: root).games.count == 1)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        #expect(ExtractedGame.collect(root: root).count == 2)
    }

    @Test func configuredLiveFolder() throws {
        guard let path = ProcessInfo.processInfo.environment["NX_TEST_EXTRACTED_ROOT"] else { return }
        let sources = ExtractedGame.collect(root: URL(fileURLWithPath: path))
        #expect(!sources.isEmpty)
        for source in sources { print("Extracted source: \(source.titleID) \(source.folder.lastPathComponent)") }
    }
}
