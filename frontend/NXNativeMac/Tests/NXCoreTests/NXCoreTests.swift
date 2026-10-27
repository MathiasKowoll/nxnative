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
        let (strs, offs) = strings(names)
        var d = Data("PFS0".utf8) + le32(UInt32(names.count)) + le32(UInt32(strs.count)) + le32(0)
        for (i, _) in names.enumerated() { d += le64(UInt64(i)) + le64(1) + le32(offs[i]) + le32(0) }
        return d + strs + Data(repeating: 0, count: names.count)
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
        let secureData = hfs0(secure.map { ($0, Data(repeating: 0xAB, count: 4)) })
        let root = hfs0([("update", hfs0([])), ("normal", hfs0([])), ("secure", secureData)])
        var header = Data(repeating: 0, count: 0x200)
        header.replaceSubrange(0x100..<0x104, with: Data("HEAD".utf8))
        // La dirección es relativa al inicio de la tarjeta: un volcado con
        // el área de claves delante (0x1000) no la cambia.
        let prefix = keyArea ? 0x1000 : 0
        header.replaceSubrange(0x130..<0x138, with: le64(0x200))
        return Data(repeating: 0, count: prefix) + header + root
    }
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
