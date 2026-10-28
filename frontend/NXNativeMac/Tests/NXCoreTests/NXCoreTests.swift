import Foundation
import Testing
@testable import NXCore

@Suite struct BuildEventTests {
    @Test func stageAndProgress() throws {
        let s = try #require(BuildEventParser.parse(#"{"ev":"stage","t":1700000000.5,"k":2,"n":7,"name":"extract v327680","step":"RomFS"}"#))
        #expect(s.event == .stage(k: 2, n: 7, name: "extract v327680", step: "RomFS"))
        #expect(s.time == Date(timeIntervalSince1970: 1700000000.5))

        let p = try #require(BuildEventParser.parse(#"{"ev":"progress","t":1,"k":7,"name":"IPA pack","step":"packing","done":1900000000,"total":4500000000,"unit":"B","est":true,"note":"13,597 entries","frac":0.42,"eta":7,"elapsed":5}"#))
        guard case let .progress(pr) = p.event else { Issue.record("no es progress"); return }
        #expect(pr.done == 1_900_000_000)
        #expect(pr.estimated)
        #expect(pr.fraction == 0.42)
        #expect(pr.unit == "B")
    }

    @Test func nullsAreNil() throws {
        let p = try #require(BuildEventParser.parse(#"{"ev":"progress","t":1,"k":3,"name":"rewrite","step":"","done":null,"total":null,"unit":"","est":false,"note":"","frac":null,"eta":null,"elapsed":1.5}"#))
        guard case let .progress(pr) = p.event else { Issue.record("no es progress"); return }
        #expect(pr.done == nil && pr.fraction == nil && pr.eta == nil)
        #expect(pr.elapsed == 1.5)
    }

    /// Un booleano no es un número: `est: true` no puede colarse como 1.
    @Test func boolIsNotNumber() {
        #expect(BuildEventParser.number(true as NSNumber) == nil)
        #expect(BuildEventParser.number(3 as NSNumber) == 3)
    }

    @Test func stageEndSayUnknown() throws {
        let e = try #require(BuildEventParser.parse(#"{"ev":"stage_end","t":1,"k":2,"name":"extract","ok":true,"summary":"9,779 files, 5.0 GB","elapsed":20}"#))
        #expect(e.event == .stageEnd(k: 2, name: "extract", ok: true, summary: "9,779 files, 5.0 GB", elapsed: 20))
        let s = try #require(BuildEventParser.parse(#"{"ev":"say","t":1,"msg":"[RED] no prod.keys"}"#))
        #expect(s.event == .say("[RED] no prod.keys"))
        #expect(BuildEventParser.isError("[RED] no prod.keys"))
        let u = try #require(BuildEventParser.parse(#"{"ev":"nuevo","t":1}"#))
        if case .unknown("nuevo", _) = u.event {} else { Issue.record("debía ser unknown") }
        #expect(BuildEventParser.parse("Traceback (most recent call last):") == nil)
    }

    @Test func splitterJoinsChunks() {
        var s = LineSplitter()
        #expect(s.feed(Data("{\"a\":".utf8)).isEmpty)
        #expect(s.feed(Data("1}\n{\"b\"".utf8)) == ["{\"a\":1}"])
        #expect(s.feed(Data(":2}\nfin".utf8)) == ["{\"b\":2}"])
        #expect(s.flush() == ["fin"])
    }
}

@Suite struct EnvFileTests {
    /// Las reglas de `env_file()` en `dm/mac/launcher.c`.
    @Test func parsesLikeTheLauncher() {
        let f = EnvFile(text: "  # comentario\nDM_FPS_TARGET=60\n\tDM_RUMBLE =0  \nsin igual\n=vacio\nDM_FPS_TARGET=30\n")
        #expect(f.effective == ["DM_FPS_TARGET": "60", "DM_RUMBLE": "0"])
        #expect(f.keys == ["DM_FPS_TARGET", "DM_RUMBLE"])
    }

    @Test func editsKeepForeignLines() {
        var f = EnvFile(text: "# mío\nDM_NVN_GPUPROF=every:60\nDM_FPS_TARGET=30\nDM_FPS_TARGET=60\n")
        f["DM_FPS_TARGET"] = "60"
        #expect(f.text == "# mío\nDM_NVN_GPUPROF=every:60\nDM_FPS_TARGET=60\n")
        f["DM_FPS_TARGET"] = nil
        f["DM_RENDER_SCALE"] = "0.75"
        #expect(f.text == "# mío\nDM_NVN_GPUPROF=every:60\nDM_RENDER_SCALE=0.75\n")
        #expect(EnvFile(text: f.text) == f)
    }

    @Test func emptyRoundTrip() {
        #expect(EnvFile(text: "").text == "")
        var f = EnvFile()
        f["A"] = "1"
        #expect(f.text == "A=1\n")
    }
}

@Suite struct LauncherSettingsTests {
    /// El ejemplo de Breath of the Wild de `docs/frontends.md`.
    static let json = #"""
    {"game": "01007EF00011E000", "settings": [
     {"env": "DM_FPS_HOLD", "kind": "toggle", "section": "Performance", "label": "Hold frames when late", "note": "", "default": "on", "on": "on", "off": "off"},
     {"env": "DM_FPS_TARGET", "kind": "choice", "section": "Game", "label": "Frame rate", "note": "", "default": "60",
      "options": [["30", "30 fps"], ["60", "60 fps"]]},
     {"env": "DM_RENDER_SCALE", "kind": "range", "section": "Game", "label": "Render scale", "note": "", "default": "1.0", "min": 0.5, "max": 1.0, "step": 0.05},
     {"env": "DM_X", "kind": "toggle", "section": "Rara", "label": "X", "note": "", "default": "1", "on": "1", "off": "0"}
    ]}
    """#

    @Test func decodesAndOrdersSections() throws {
        let s = try JSONDecoder().decode(LauncherSettings.self, from: Data(Self.json.utf8))
        #expect(s.sections.map(\.name) == ["Game", "Performance", "Rara"])
        let fps = try #require(s.settings.first { $0.env == "DM_FPS_TARGET" })
        #expect(fps.choices.map(\.value) == ["30", "60"])
        let scale = try #require(s.settings.first { $0.env == "DM_RENDER_SCALE" })
        #expect(scale.decimals == 2)
        #expect(scale.format(range: 0.75) == "0.75")
        #expect(scale.isDefault("1"))
        #expect(!scale.isDefault("0.95"))
    }

    @Test func rangeFormatKeepsOneDecimal() {
        let r = Setting(env: "DM_RUMBLE_GAIN", kind: .range, section: "Controls", label: "", defaultValue: "1.0", min: 0, max: 3, step: 0.1)
        #expect(r.format(range: 2) == "2.0")
    }
}

@Suite struct TitleIDTests {
    @Test func kinds() throws {
        let base = try #require(TitleID("010015100B514000"))
        #expect(base.kind == .base)
        let upd = try #require(TitleID("010015100B514800"))
        #expect(upd.kind == .update && upd.base == base)
        let dlc = try #require(TitleID("010015100B515001"))
        #expect(dlc.kind == .addOn && dlc.base == base)
        #expect(TitleID("nope") == nil)
    }

    @Test func fileNameVariants() {
        func f(_ n: String) -> GameFile { GameFile(url: URL(fileURLWithPath: "/x/" + n), size: 1, readHeaders: false) }
        let a = f("Super Mario [010015100B514800][v327680].nsp")
        #expect(a.titleID?.description == "010015100B514800" && a.version == 327680 && a.source == .fileName)
        let b = f("Crash_Team_Racing_Nitro-Fueled_0100F9F00C696000_v0_(site).nsp")
        #expect(b.titleID?.description == "0100F9F00C696000" && b.version == 0)
        let c = f("Crash 4 Skins DLC [010073401175f002].nsp")
        #expect(c.titleID?.description == "010073401175F002" && c.titleID?.kind == .addOn)
        let d = f("Crash Team Racing[0100F9F00C696800][US][v983040].nsp")
        #expect(d.titleID?.kind == .update && d.version == 983040)
        let e = f("Mario Kart 8 Deluxe (World) (En,Ja,Fr).xci")
        #expect(e.titleID == nil && e.version == nil)
    }

    @Test func cleanAndSuggest() {
        #expect(GameLibrary.cleanName("The_Legend_of_Zelda_Breath_of_the_Wild_[01007EF00011E000][v0][site]") == "The Legend of Zelda Breath of the Wild")
        let table = [CompatibilityEntry(name: "The Legend of Zelda: Tears of the Kingdom", titleID: TitleID("0100F2C0115B6000")!, build: "", sdk: "", engine: "", graphics: ""),
                     CompatibilityEntry(name: "Mario Kart 8 Deluxe", titleID: TitleID("0100152000022000")!, build: "", sdk: "", engine: "", graphics: "")]
        let totk = GameFile(url: URL(fileURLWithPath: "/x/The_Legend_of_Zelda_Tears_of_the_Kingdom.xci"), size: 1, readHeaders: false)
        #expect(GameLibrary.suggest(for: totk, in: table)?.titleID.description == "0100F2C0115B6000")
        let mk = GameFile(url: URL(fileURLWithPath: "/x/Mario Kart 8 Deluxe (World) (En,Ja).xci"), size: 1, readHeaders: false)
        #expect(GameLibrary.suggest(for: mk, in: table)?.name == "Mario Kart 8 Deluxe")
        let other = GameFile(url: URL(fileURLWithPath: "/x/Luigi's Mansion 3 (Europe).xci"), size: 1, readHeaders: false)
        #expect(GameLibrary.suggest(for: other, in: table) == nil)
    }
}

/// Contenedores fabricados aquí, con la disposición de switchbrew: sin datos
/// de ningún juego, solo cabeceras.
enum Synth {
    static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    static func le64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    static func strings(_ names: [String]) -> (Data, [UInt32]) {
        var d = Data(); var offs: [UInt32] = []
        for n in names { offs.append(UInt32(d.count)); d.append(Data(n.utf8)); d.append(0) }
        while d.count % 4 != 0 { d.append(0) }
        return (d, offs)
    }

    static func pfs0(_ names: [String]) -> Data {
        pfs0Files(names.map { ($0, Data(repeating: 0, count: 1)) })
    }

    static func pfs0Files(_ files: [(String, Data)]) -> Data {
        let (strs, offs) = strings(files.map(\.0))
        var d = Data("PFS0".utf8) + le32(UInt32(files.count)) + le32(UInt32(strs.count)) + le32(0)
        var off: UInt64 = 0
        for (i, f) in files.enumerated() {
            d += le64(off) + le64(UInt64(f.1.count)) + le32(offs[i]) + le32(0)
            off += UInt64(f.1.count)
        }
        d += strs
        for f in files { d += f.1 }
        return d
    }

    static func hfs0(_ files: [(String, Data)]) -> Data {
        let (strs, offs) = strings(files.map(\.0))
        var d = Data("HFS0".utf8) + le32(UInt32(files.count)) + le32(UInt32(strs.count)) + le32(0)
        var off: UInt64 = 0
        for (i, f) in files.enumerated() {
            d += le64(off) + le64(UInt64(f.1.count)) + le32(offs[i]) + le32(0) + le64(0) + Data(repeating: 0, count: 0x20)
            off += UInt64(f.1.count)
        }
        d += strs
        for f in files { d += f.1 }
        return d
    }

    static func xci(secure: [String], keyArea: Bool = false) -> Data {
        xciFiles(secure: secure.map { ($0, Data(repeating: 0xAB, count: 4)) }, keyArea: keyArea)
    }

    static func xciFiles(secure: [(String, Data)], keyArea: Bool = false) -> Data {
        let secureData = hfs0(secure)
        let root = hfs0([("update", hfs0([])), ("normal", hfs0([])), ("secure", secureData)])
        var header = Data(repeating: 0, count: 0x200)
        header.replaceSubrange(0x100..<0x104, with: Data("HEAD".utf8))
        // La dirección es relativa al inicio de la tarjeta: un volcado con
        // el área de claves delante (0x1000) no la cambia.
        let prefix = keyArea ? 0x1000 : 0
        header.replaceSubrange(0x130..<0x138, with: le64(0x200))
        return Data(repeating: 0, count: prefix) + header + root
    }

    /// Cabeceras NCA3 sintéticas (title ID 010076F0049A2000 y su actualización
    /// …800, keyrev 14) cifradas XTS con `cryptography` —la implementación de
    /// referencia, no el AES128 de NXCore— bajo `testKeyHex`. Son el punto de
    /// comprobación de `NCAHeader` y del descifrado entero.
    static let testKeyHex = "202326292c2f3235383b3e4144474a4d505356595c5f6265686b6e7174777a7d"
    static let cnmtBaseCT = Data(hex: "a1648ea9abda647587ad4df847d5a2b1bc58af660fd73114344a98e0fec1d722dcfccfd29a4f2bb5552c6287728c7b7df1edcec5bbd8bc5770e682bc92a9a1cabca8c18abebf432596eab38edb95b4664a22e1475d040c4758328705112c988c88c44dda8b022489185933a2fd202d27b0c7e878f3b5d9d5760138b5236df5da8a303fa1bda52203b6fff37042d57cd1eb3188e2be32f806fe82106e796dc38667af5e6223e454140f34fc802fda33e9b5f6e63ab3b3f50713c79dc7f66bb62010db87e3cd1a6f7f088b13c4d178666f3bf90ac6e61008617bd84bddf15eff1ff08efa399f3014205f6ae34d2ad4c42b697707ed64f5825210b46ddffa551c2a61abf26801aa82c63f6f369bbcbcbbd2874bc19fe0e212a9bd56375ef715ded57242956129863b3ffedbc0a3005f41d52af8a17087a037b68531533fb589ff7d5351d8aa28c595af70d3afd3397a6bd962bca0cf33f7799cae2622e4d3fd1e5ae2c3b21275fb3fe6a2ea4fea89c7ea391176478fd76a3e46935d98b354fbc823597509cb3596773779cb917b6ff3697d394518b4114214ee4786f4376adb95a85757c563657f4a6f557adcbbfa6de6eb9c3b86f43e2a61a6d7ed632d88cbcee7c5c1b4c9067ae5e88b67259eac7a0a694fad596817d324eba4a25170e499ab810f55829e86416e53a27b8c3fec49415e54a7f0e37efc9d141a3e372a2bcb987323123ae426c886eba988a839d7739fbc4becc380d6b6cc2b3854d2483abc1875ea589999685dac09c7595a1638e22c530251c813c13b350055cf362e64a16d5855f12576005ed101bdb5fdf755a79272fdece06bf85f77a67b4f9aa5e18ff2c4a036377c3b299af98477f870bbf1eccfdf7d635b80b3cf43b2697041cc0444e9c3c01f76ccd41e89670b1d96899f6ce764182834d87c696bd2a96bde279058b76850f58a5aebcf51780d492d86b27d98c47e07406c0c3e1bfea9d27101c3c40eee29dc02fc966349edfa0b299a9c08f3aac32dbd25e3cb9143f61abd65ccb7429cea50038648a74552b5c217463d3dcdbaf03a1acb896f95fda794f4d4e519ac2b9e86f7739ade9f522e21d82e7393c058da3462c82dd1f5e2d2a10bf57769f6c17955fc7527d54463b03973d2f5f90ce463d016b6a2f93f2077b2c70f205f02f11b58fd198494cd2534ffac2ce4034125aa84aa4963cb9383837ac5494d5ae48b5e81188bb68d362a42a9f82ad400157c24f6f46225adb866b6d585b52a8276aca399c80217a6326ea4b04fd8f8c223fee58d24dcb26caa196caf054a21616a14b8dcea59aa68d8aad583d111bbc0b411224377887814a876c942925e7a2cb1973f78fe92e78fd1c418b9c8f114ce061b6d591454edf5917866d3344c1189b3eb6861b59cc5b09b849e849131efb15d70d71fa78cfb15c435436758173eb385")!
    static let cnmtUpdateCT = Data(hex: "a1648ea9abda647587ad4df847d5a2b1bc58af660fd73114344a98e0fec1d722dcfccfd29a4f2bb5552c6287728c7b7df1edcec5bbd8bc5770e682bc92a9a1cabca8c18abebf432596eab38edb95b4664a22e1475d040c4758328705112c988c88c44dda8b022489185933a2fd202d27b0c7e878f3b5d9d5760138b5236df5da8a303fa1bda52203b6fff37042d57cd1eb3188e2be32f806fe82106e796dc38667af5e6223e454140f34fc802fda33e9b5f6e63ab3b3f50713c79dc7f66bb62010db87e3cd1a6f7f088b13c4d178666f3bf90ac6e61008617bd84bddf15eff1ff08efa399f3014205f6ae34d2ad4c42b697707ed64f5825210b46ddffa551c2a61abf26801aa82c63f6f369bbcbcbbd2874bc19fe0e212a9bd56375ef715ded57242956129863b3ffedbc0a3005f41d52af8a17087a037b68531533fb589ff7d5351d8aa28c595af70d3afd3397a6bd962bca0cf33f7799cae2622e4d3fd1e5ae2c3b21275fb3fe6a2ea4fea89c7ea391176478fd76a3e46935d98b354fbc823597509cb3596773779cb917b6ff3697d394518b4114214ee4786f4376adb95a85757c563657f4a6f557adcbbfa6de6eb9c3b86f43e2a61a6d7ed632d88cbcee7c5c1b4c9067ae5e88b67259eac7a0a694fad596817d324eba4a25170e499ab810f55829e86416e53a27b8c3fec49415e54a7f0e37efc9d141a3e372a2bcb987323123ae426c886eba988a839d7739fbcec90557037adc7cbf55552477762c727ea589999685dac09c7595a1638e22c530251c813c13b350055cf362e64a16d5855f12576005ed101bdb5fdf755a79272fdece06bf85f77a67b4f9aa5e18ff2c4a036377c3b299af98477f870bbf1eccfdf7d635b80b3cf43b2697041cc0444e9c3c01f76ccd41e89670b1d96899f6ce764182834d87c696bd2a96bde279058b76850f58a5aebcf51780d492d86b27d98c47e07406c0c3e1bfea9d27101c3c40eee29dc02fc966349edfa0b299a9c08f3aac32dbd25e3cb9143f61abd65ccb7429cea50038648a74552b5c217463d3dcdbaf03a1acb896f95fda794f4d4e519ac2b9e86f7739ade9f522e21d82e7393c058da3462c82dd1f5e2d2a10bf57769f6c17955fc7527d54463b03973d2f5f90ce463d016b6a2f93f2077b2c70f205f02f11b58fd198494cd2534ffac2ce4034125aa84aa4963cb9383837ac5494d5ae48b5e81188bb68d362a42a9f82ad400157c24f6f46225adb866b6d585b52a8276aca399c80217a6326ea4b04fd8f8c223fee58d24dcb26caa196caf054a21616a14b8dcea59aa68d8aad583d111bbc0b411224377887814a876c942925e7a2cb1973f78fe92e78fd1c418b9c8f114ce061b6d591454edf5917866d3344c1189b3eb6861b59cc5b09b849e849131efb15d70d71fa78cfb15c435436758173eb385")!
}

@Suite struct ContainerTests {
    let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("nxcore-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func write(_ name: String, _ data: Data, in sub: String = "") throws -> URL {
        let d = sub.isEmpty ? dir : dir.appendingPathComponent(sub, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let u = d.appendingPathComponent(name)
        try data.write(to: u)
        return u
    }

    /// El ticket gana a la etiqueta del nombre, como en `title_of()`.
    @Test func ticketWins() throws {
        let u = try write("Juego [0100AAAA00000001][v0].nsp",
                          Synth.pfs0(["0123.nca", "0100AAAA000000000000000000000004.tik", "0100AAAA000000000000000000000004.cert"]))
        let f = GameFile(url: u, size: 100)
        #expect(f.titleID?.description == "0100AAAA00000000")
        #expect(f.source == .ticket)
    }

    @Test(arguments: [false, true]) func cartridge(keyArea: Bool) throws {
        let u = try write("Cart.xci", Synth.xci(secure: ["a.nca", "b.cnmt.nca", "c.nca", "d.cnmt.nca"], keyArea: keyArea))
        let x = try #require(Containers.xciInfo(u))
        #expect(x.headerOffset == (keyArea ? 0x1000 : 0))
        #expect(x.partitions == ["update", "normal", "secure"])
        #expect(x.contentMetaCount == 2)
        #expect(x.carriesMoreThanBase)
    }

    @Test func garbageIsNil() throws {
        let u = try write("roto.xci", Data("HEAD esto no es un cartucho".utf8))
        #expect(Containers.xciInfo(u) == nil)
        let n = try write("roto.nsp", Data("PFS0\u{FF}\u{FF}\u{FF}\u{7F}".utf8))
        #expect(Containers.pfs0Names(n) == nil)
    }

    /// Una biblioteca plana: varios juegos en la raíz, DLC en subcarpetas, un
    /// XCI sin etiqueta y un NSP sin etiqueta que se identifica por su ticket.
    @Test func flatLibraryAndPreparedFolder() throws {
        _ = try write("Juego A [0100AAAA00000000][v0].xci", Synth.xci(secure: ["x.cnmt.nca"]))
        _ = try write("Juego A [0100AAAA00000800][v65536].nsp", Synth.pfs0(["u.nca"]))
        _ = try write("Juego A DLC [0100AAAA00001001][v0].nsp", Synth.pfs0(["d.nca"]), in: "DLCs A")
        _ = try write("Juego B.nsp", Synth.pfs0(["0100BBBB000000000000000000000000.tik"]))
        _ = try write("Juego C (World).xci", Synth.xci(secure: ["y.cnmt.nca"]))
        _ = try write("vacio [0100CCCC00000000].nsp", Data())
        let solo = try write("Juego D [0100DDDD00000000][v0].nsp", Synth.pfs0([]), in: "Juego D")

        let scan = GameLibrary.group(GameLibrary.collect(root: dir))
        #expect(scan.games.map(\.base.description).sorted() == ["0100AAAA00000000", "0100BBBB00000000", "0100DDDD00000000"])
        #expect(scan.unidentified.map(\.url.lastPathComponent) == ["Juego C (World).xci"])
        let a = try #require(scan.games.first { $0.base.description == "0100AAAA00000000" })
        #expect(a.baseFiles.count == 1 && a.updates.count == 1 && a.addOns.count == 1)
        #expect(a.ownFolder == nil)
        #expect(a.packages == ["v65536", "v0"])
        let d = try #require(scan.games.first { $0.base.description == "0100DDDD00000000" })
        #expect(d.ownFolder?.standardizedFileURL == solo.deletingLastPathComponent().standardizedFileURL)

        // Asignar el XCI sin etiqueta lo saca de «sin identificar».
        let c = scan.unidentified[0]
        let again = GameLibrary.group(GameLibrary.collect(root: dir), assigned: [c.url.path: TitleID("0100CCCC00000000")!])
        #expect(again.unidentified.isEmpty)

        // La carpeta preparada: enlaces con [TID][vN], y nada se mueve.
        let folder = try PreparedFolder.sync(a, root: dir, name: "Juego A")
        let links = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(links == ["Juego A DLC [0100AAAA00001001][v0].nsp", "Juego A [0100AAAA00000000][v0].xci", "Juego A [0100AAAA00000800][v65536].nsp"])
        for n in links {
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(n).path))
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent(n).path)) != nil)
        }
        #expect(PreparedFolder.existing(root: dir)[a.base] != nil)
        // Volver a escanear no cuenta los enlaces como juegos nuevos.
        #expect(GameLibrary.group(GameLibrary.collect(root: dir)).games.count == 3)
        // Un archivo normal dentro de la carpeta preparada no se toca.
        try Data("mío".utf8).write(to: folder.appendingPathComponent("notas.txt"))
        try PreparedFolder.sync(a, root: dir, name: "Juego A")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("notas.txt").path))
    }
}

@Suite struct OptionsAndTables {
    @Test func arguments() {
        var o = BuildOptions(nspFolder: URL(fileURLWithPath: "/g/Mario"), keys: URL(fileURLWithPath: "/k/prod.keys"))
        o.package = "v0"
        o.language = "ja"
        o.allowDamaged = true
        let a = o.arguments(script: URL(fileURLWithPath: "/r/scripts/build_ipa_from_nsp.py"))
        #expect(a.prefix(8) == ["/r/scripts/build_ipa_from_nsp.py", "/g/Mario", "-k", "/k/prod.keys",
                                "--progress", "json", "--platform", "mac-app"])
        #expect(a.contains("--allow-damaged"))
        #expect(!a.contains("--show-fps") && !a.contains("--no-show-fps"))
        #expect(a.contains("--keep-extracted"))
    }

    @Test func compatibilityTable() {
        let md = """
        | Who | Picks |
        |---|---|
        | x | y |

        ## Games

        | Game | Title ID | Build | SDK | Engine | Graphics |
        |---|---|---|---|---|---|
        | [13 Sentinels: Aegis Rim](01003FC01670C000/README.md) | `01003FC01670C000` | 1.10 | 11.4.3 | Vanillaware's engine | NVN |
        | [Balatro](0100CD801CE5E000/README.md) | `0100CD801CE5E000` | 1.1.3 | 18.3.2 | LÖVE 11.4 (love-nx, LuaJIT, SDL) | OpenGL |
        """
        let rows = CompatibilityEntry.parse(readme: md)
        #expect(rows.map(\.name) == ["13 Sentinels: Aegis Rim", "Balatro"])
        #expect(rows[1].graphics == "OpenGL")
    }

    /// Contra el propio checkout: la app vive en `frontend/NXNativeMac` del
    /// fork, así que el repo está cinco niveles por encima de este archivo.
    @Test func realCheckout() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let repo = NXRepository(root: root)
        try #require(repo.isValid, "no se encontró el checkout en \(root.path)")
        let rows = repo.compatibility()
        #expect(rows.count >= 70)
        #expect(repo.profiles().contains(TitleID("010015100B514000")!))
        #expect(repo.chainLockValues()["metal_macosx"] != nil)
        #expect(repo.switches().count > 200)
    }
}

/// `Fixtures/progress.jsonl` lo escribió la clase `Progress` REAL de
/// `scripts/build_ipa_from_nsp.py` (modo json), no una imitación: si
/// nxnative cambia su salida, se regenera y esta prueba lo dice.
@Suite struct RealEmitterReplay {
    @Test func replay() throws {
        let url = try #require(Bundle.module.url(forResource: "progress", withExtension: "jsonl", subdirectory: "Fixtures"))
        var state = BuildState()
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            state.apply(line: String(line))
        }
        #expect(state.stageCount == 3)
        #expect(state.stages.map(\.name) == ["extract v0", "rewrite", "IPA pack"])
        #expect(state.stages.map(\.ok) == [true, true, false])
        #expect(state.stages[0].summary == "9,779 files, 5.0 GB")
        #expect(state.stages[1].step == "main")
        #expect(state.messages.map(\.text) == ["[12:00:00] note line", "[RED] something broke"])
        #expect(state.lastError == "[RED] something broke")
        #expect(state.overallFraction == 1)
    }

    @Test func redAfterTimestamp() {
        #expect(BuildEventParser.isError("[12:00:00] [RED] no keys"))
        #expect(!BuildEventParser.isError("[12:00:00] fine [RED] later"))
    }
}

/// La parte del escaneo que necesita `prod.keys`: el AES-128/XTS de NXCore,
/// el parseo del archivo de claves y la identificación de archivos sin
/// etiqueta ni ticket. Las cabeceras cifradas vienen de `cryptography`
/// (referencia), no del propio código, así el test no es circular.
@Suite struct KeysetTests {
    let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("nxcore-keys-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    func write(_ name: String, _ data: Data) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try data.write(to: u)
        return u
    }

    var keys: Keyset {
        get throws { try #require(Keyset(text: "header_key = \(Synth.testKeyHex)")) }
    }

    /// El vector oficial de la FIPS-197, en los dos sentidos: es la primitiva
    /// de la que depende todo lo demás aquí.
    @Test func aesFipsVector() throws {
        let aes = AES128(try #require(Data(hex: "000102030405060708090a0b0c0d0e0f")))
        let p = try #require(Data(hex: "00112233445566778899aabbccddeeff"))
        let c = try #require(Data(hex: "69c4e0d86a7b0430d8cdb78070b4c55a"))
        #expect(Data(aes.encrypt([UInt8](p))) == c)
        #expect(Data(aes.decrypt([UInt8](c))) == p)
    }

    /// Solo se acepta un `header_key` de 32 bytes; el resto del archivo sobra
    /// y las entradas sin `= no rompen nada.
    @Test func keysetParses() {
        #expect(Keyset(text: "línea suelta\nmaster_key_00 = aabbcc\nheader_key = \(Synth.testKeyHex)\n")?.headerKey.count == 32)
        #expect(Keyset(text: "header_key = aabb") == nil)
        #expect(Keyset(text: "nada=1") == nil)
    }

    /// Un XCI solo se sabe por el nombre; con las claves sale de su cnmt.
    /// Un NSP sin ticket (de los que se convierten desde cartucho) igual.
    @Test func cartridgeAndTicketlessNSPResolve() throws {
        let keys = try self.keys
        let xci = try write("Mario Kart 8.xci", Synth.xciFiles(secure: [("a.nca", Data(repeating: 0, count: 4)), ("m.cnmt.nca", Synth.cnmtBaseCT)]))
        let f = GameFile(url: xci, size: 100, keyset: keys)
        #expect(f.titleID?.description == "010076F0049A2000")
        #expect(f.source == .keyset)
        // Sin claves sigue sin identificarse: el escaneo no cambia para el resto.
        #expect(GameFile(url: xci, size: 100).titleID == nil)

        let nsp = try write("Kirby and the Forgotten Land.nsp", Synth.pfs0Files([("a.nca", Data(repeating: 0, count: 4)), ("m.cnmt.nca", Synth.cnmtBaseCT)]))
        let g = GameFile(url: nsp, size: 100, keyset: keys)
        #expect(g.titleID?.description == "010076F0049A2000")
        #expect(g.source == .keyset)
    }

    /// Un «1G+1U» trae base y actualización: el cartucho es la base aunque la
    /// actualización venga primero en la tabla.
    @Test func baseWinsInMultiContentCartridge() throws {
        let keys = try self.keys
        let u = try write("Cart.xci", Synth.xciFiles(secure: [("upd.cnmt.nca", Synth.cnmtUpdateCT), ("base.cnmt.nca", Synth.cnmtBaseCT)]))
        #expect(GameFile(url: u, size: 100, keyset: keys).titleID?.description == "010076F0049A2000")
    }

    /// Con una clave que no vale no sale la magia NCA3 y el archivo queda sin
    /// identificar, no identificado de mentira.
    /// Regla de la carpeta para el script: ticket o etiqueta la hacen legible
    /// tal cual; claves o asignación a mano no (el script no los lee).
    @Test func scriptReadabilityFollowsTheSource() throws {
        let tick = try write("T.nsp", Synth.pfs0(["0100AAAA000000000000000000000004.tik"]))
        let tagged = try write("B [0100BBBB00000000].xci", Synth.xci(secure: []))
        let plain = try write("C.xci", Synth.xci(secure: []))
        let k = try self.keys
        let byTicket = GameFile(url: tick, size: 100)
        let byName = GameFile(url: tagged, size: 100)
        let byKeys = GameFile(url: plain, size: 100, keyset: k)
        let byHand = GameFile(url: plain, size: 100).assigning(TitleID("0100CCCC00000000")!)
        for (f, esperado) in [(byTicket, true), (byName, true), (byKeys, false), (byHand, false)] {
            let g = GameEntry(base: f.titleID ?? TitleID("0100999900000000")!, files: [f], ownFolder: nil)
            #expect(g.scriptReadable == esperado, Comment(rawValue: "\(f.url.lastPathComponent): fuera \(f.source.map(String.init(describing:)) ?? "nil")"))
        }
    }

    @Test func wrongKeyIdentifiesNothing() throws {
        let wrong = try #require(Keyset(text: "header_key = " + String(repeating: "ab", count: 32)))
        let xci = try write("Mario Kart 8.xci", Synth.xciFiles(secure: [("m.cnmt.nca", Synth.cnmtBaseCT)]))
        #expect(GameFile(url: xci, size: 100, keyset: wrong).titleID == nil)
    }
}

@Suite struct SaveVaultTests {
    let base: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("nxvault-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    var save: URL { base.appendingPathComponent("support/save", isDirectory: true) }
    var vault: SaveVault { SaveVault(root: base.appendingPathComponent("backups"), keepAuto: 3) }
    let tid = "0100AAAA00000000"

    func writeSave(_ text: String, file: String = "slot0/data.bin") throws {
        let u = save.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
    }

    func t(_ s: Int) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + Double(s)) }

    @Test func noSaveNoBackup() async throws {
        #expect(try await vault.autoBackup(saveDir: save, titleID: tid, game: "A", version: "1.0", now: t(0)) == nil)
        #expect(vault.list(tid).isEmpty)
    }

    /// La automática se salta si nada cambió, y vuelve a copiar si cambió.
    @Test func autoSkipsUnchanged() async throws {
        try writeSave("uno")
        let first = try await vault.autoBackup(saveDir: save, titleID: tid, game: "A", version: "1.0", now: t(0))
        #expect(first != nil)
        #expect(try await vault.autoBackup(saveDir: save, titleID: tid, game: "A", version: "1.0", now: t(10)) == nil)
        try writeSave("dos, más largo")
        #expect(try await vault.autoBackup(saveDir: save, titleID: tid, game: "A", version: "1.0", now: t(20)) != nil)
        #expect(vault.list(tid).map(\.kind) == [.auto, .auto])
        let firstURL = try #require(first)
        let m = try #require(await SaveVault.manifest(of: firstURL))
        #expect(m.titleID == tid && m.files == 1 && m.bytes == 3 && m.game == "A")
    }

    /// Solo se podan las automáticas; las manuales se quedan.
    @Test func pruneKeepsManual() async throws {
        try writeSave("x")
        try await vault.backup(saveDir: save, titleID: tid, game: "A", version: "", kind: .manual, now: t(0))
        for i in 1...5 {
            try writeSave(String(repeating: "x", count: i + 1))
            try await vault.autoBackup(saveDir: save, titleID: tid, game: "A", version: "", now: t(i * 10))
        }
        let l = vault.list(tid)
        #expect(l.filter { $0.kind == .auto }.count == 3)
        #expect(l.filter { $0.kind == .manual }.count == 1)
        #expect(l.first?.date == t(50))
    }

    @Test func sameSecondDoesNotOverwrite() async throws {
        try writeSave("x")
        try await vault.backup(saveDir: save, titleID: tid, game: "A", version: "", kind: .manual, now: t(0))
        try await vault.backup(saveDir: save, titleID: tid, game: "A", version: "", kind: .manual, now: t(0))
        #expect(vault.list(tid).count == 2)
    }

    /// Restaurar deja la partida de la copia, y guarda antes la que había.
    @Test func restoreKeepsPrevious() async throws {
        try writeSave("vieja")
        let old = try #require(try await vault.backup(saveDir: save, titleID: tid, game: "A", version: "", kind: .manual, now: t(0)))
        try writeSave("nueva")
        try await vault.restore(old, saveDir: save, titleID: tid, game: "A", version: "")
        #expect(try String(contentsOf: save.appendingPathComponent("slot0/data.bin"), encoding: .utf8) == "vieja")
        let kinds = vault.list(tid).map(\.kind)
        #expect(kinds.contains(.beforeRestore))
    }

    /// Exportar e importar en otra «instalación», y negarse con otro juego.
    @Test func exportImportAndWrongGame() async throws {
        try writeSave("partida")
        let out = base.appendingPathComponent("Mi partida.zip")
        try await vault.export(saveDir: save, titleID: tid, game: "A", version: "1.0", to: out)
        try FileManager.default.removeItem(at: save)   // un desinstalador se la llevó
        try await vault.restore(out, saveDir: save, titleID: tid, game: "A", version: "1.0")
        #expect(try String(contentsOf: save.appendingPathComponent("slot0/data.bin"), encoding: .utf8) == "partida")

        await #expect(throws: SaveVault.SaveError.otherGame(expected: "0100BBBB00000000", found: tid, game: "A")) {
            try await vault.restore(out, saveDir: save, titleID: "0100BBBB00000000", game: "B", version: "")
        }
    }

    @Test func notASave() async throws {
        let junk = base.appendingPathComponent("junk")
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        try Data("hola".utf8).write(to: junk.appendingPathComponent("readme.txt"))
        let zip = base.appendingPathComponent("junk.zip")
        _ = await Shell.run("/usr/bin/ditto", ["-c", "-k", junk.path, zip.path])
        await #expect(throws: SaveVault.SaveError.notASave) {
            try await vault.restore(zip, saveDir: save, titleID: tid, game: "A", version: "")
        }
    }
}

@Suite struct ButtonGlyphsTests {
    @Test func readAndWrite() throws {
        var env = EnvFile(text: "DM_RUMBLE=0\n")
        #expect(ButtonGlyphs.current(in: env) == .nintendo)
        ButtonGlyphs.playstation.apply(to: &env)
        #expect(env[ButtonGlyphs.envKey] == ButtonGlyphs.playstation.font?.path)
        #expect(ButtonGlyphs.current(in: env) == .playstation)
        ButtonGlyphs.nintendo.apply(to: &env)
        #expect(env.text == "DM_RUMBLE=0\n")   // volver a Switch deja el archivo como estaba
    }

    /// Una fuente puesta a mano no es «nintendo» ni «playstation»: no se pisa.
    @Test func handSetFontIsRespected() {
        let env = EnvFile(text: "DM_SHARED_FONT_EXT=/Users/x/mi_fuente.ttf\n")
        #expect(ButtonGlyphs.current(in: env) == nil)
    }

    /// Con el generador real del checkout y el Python de la app, si están.
    @Test func generatesWithRealScript() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let repo = NXRepository(root: root)
        try #require(FileManager.default.isExecutableFile(atPath: PythonEnv.python), "sin el venv de la app; se omite")
        try #require(await PythonEnv.missingPackages(PythonEnv.python).isEmpty, "venv sin fonttools; se omite")
        let font = try #require(ButtonGlyphs.playstation.font)
        try? FileManager.default.removeItem(at: font)
        try await ButtonGlyphs.playstation.ensureFont(repository: repo, python: PythonEnv.python)
        let size = (try FileManager.default.attributesOfItem(atPath: font.path)[.size] as? NSNumber)?.intValue ?? 0
        #expect(size > 1000)
        // La segunda vez no regenera: la fecha no cambia.
        let before = try FileManager.default.attributesOfItem(atPath: font.path)[.modificationDate] as? Date
        try await ButtonGlyphs.playstation.ensureFont(repository: repo, python: PythonEnv.python)
        #expect(try FileManager.default.attributesOfItem(atPath: font.path)[.modificationDate] as? Date == before)
    }
}

@Suite struct GlobalDefaultsTests {
    @Test func nothingByDefault() {
        #expect(GlobalDefaults().environment(userEnv: EnvFile()) == [:])
    }

    @Test func appliesToEveryGame() {
        let g = GlobalDefaults(fullscreen: true, filter: "bicubic", sharpen: 0.5)
        #expect(g.environment(userEnv: EnvFile()) == ["DM_FULLSCREEN": "1", "DM_PRESENT_FILTER": "bicubic", "DM_PRESENT_SHARPEN": "0.50"])
    }

    /// La elección propia del juego (su env.txt) gana: no se pisa con el entorno.
    @Test func aGamesOwnChoiceWins() {
        let g = GlobalDefaults(fullscreen: true, filter: "lanczos", sharpen: 1)
        let env = EnvFile(text: "DM_FULLSCREEN=0\nDM_PRESENT_FILTER=sharp\n")
        #expect(g.environment(userEnv: env) == ["DM_PRESENT_SHARPEN": "1.00"])
    }

    @Test func rejectsUnknownFilterAndClampsSharpen() {
        let g = GlobalDefaults(fullscreen: false, filter: "magic", sharpen: 7)
        #expect(g.environment(userEnv: EnvFile()) == ["DM_PRESENT_SHARPEN": "1.00"])
    }
}

@Suite struct HighRefreshTests {
    @Test func onAndOff() {
        var env = EnvFile(text: "DM_RUMBLE=0\n")
        #expect(!HighRefresh.isOn(env))
        HighRefresh.set(true, in: &env)
        #expect(HighRefresh.isOn(env))
        #expect(env["DM_PRESENT_LINK"] == "2" && env["DM_PRESENT_HZ"] == "120" && env["DM_PRESENT_INTERVAL"] == "display" && env["DM_FPS_TARGET"] == "0")
        HighRefresh.set(false, in: &env)
        #expect(env.text == "DM_RUMBLE=0\n")   // apagar deja el archivo como estaba
    }

    /// Un valor escrito a mano con otro valor no se quita al apagar, y se avisa antes de encender.
    @Test func handSetValuesAreKept() {
        var env = EnvFile(text: "DM_FPS_TARGET=60\nDM_PRESENT_HZ=90\n")
        #expect(HighRefresh.conflicts(env) == ["DM_PRESENT_HZ=90", "DM_FPS_TARGET=60"])
        HighRefresh.set(false, in: &env)
        #expect(env["DM_FPS_TARGET"] == "60" && env["DM_PRESENT_HZ"] == "90")
    }
}

@Suite struct EnvSwitchHintsTests {
    func sw(_ name: String, _ kind: String, _ meaning: String) -> EnvSwitch { EnvSwitch(name: name, kind: kind, meaning: meaning) }

    @Test func valuesFromTheDescription() {
        #expect(sw("DM_FPS_HOLD", "player", "`on` / `off` overrides the profile's `fps_hold`: whether late frames may raise the hold").suggestedValues == ["on", "off"])
        #expect(sw("DM_PRESENT_INTERVAL", "switch", "`display` presents one frame per display-link tick; `game` follows the game's present interval (default: the profile's `present_interval`)").suggestedValues == ["display", "game"])
        #expect(sw("DM_ALLOW_OTHER_METAL", "switch", "`1` lets `own_compilers.py` build the shader libraries with a Metal compiler other than the one in `dmsh_chain.lock`").suggestedValues == ["1"])
    }

    @Test func placeholderForFreeValues() {
        let s = sw("DM_AB", "diagnostic", "`=<frames>` splits the run into phases of that many frames and alternates every switch set to `ab`")
        #expect(s.placeholder == "frames")
        #expect(s.suggestedValues == ["ab"])
    }

    @Test func numbersAndRanges() {
        #expect(sw("DM_RENDER_SCALE", "player", "`0.5` to `1.0`: fixes the game's 3D views at that fraction; `1.0` (the default) keeps it").suggestedValues == ["0.5", "1.0"])
        let r = sw("DM_RUMBLE_MIN", "player", "`=0..0.9`: controller rumble levels below it stay silent (default 0)")
        #expect(r.placeholder == "de 0 a 0.9" && r.suggestedValues.isEmpty)
    }

    @Test func groupsAndPaths() {
        #expect(sw("DM_AOC_DIR", "path", "Folder of add-on content").group == .path)
        #expect(!EnvSwitch.Group.path.offered && EnvSwitch.Group.player.offered)
        #expect(sw("X", "switch", "").group == .setting)
    }

    /// Contra la tabla real del checkout: cada clase cae en un grupo, y ningún interruptor de jugador se queda sin forma de elegir valor.
    @Test func realTable() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let all = NXRepository(root: root).switches()
        try #require(!all.isEmpty)
        let player = all.filter { $0.group == .player }
        #expect(player.count >= 15)
        #expect(player.allSatisfy { !$0.suggestedValues.isEmpty || $0.placeholder != nil }, "\(player.filter { $0.suggestedValues.isEmpty && $0.placeholder == nil }.map(\.name))")
    }
}
