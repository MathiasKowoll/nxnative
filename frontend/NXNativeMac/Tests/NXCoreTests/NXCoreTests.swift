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

    @Test func fileNames() {
        let f = GameFile(url: URL(fileURLWithPath: "/x/Super Mario [010015100B514800][v327680].nsp"), size: 1)
        #expect(f.titleID?.description == "010015100B514800")
        #expect(f.version == 327680)
        let folder = NSPFolder(url: URL(fileURLWithPath: "/x"), files: [
            GameFile(url: URL(fileURLWithPath: "/x/M [010015100B514000][v0].nsp"), size: 1), f,
            GameFile(url: URL(fileURLWithPath: "/x/M DLC [010015100B515001][v0].nsp"), size: 1),
        ])
        #expect(folder.baseTitleID?.description == "010015100B514000")
        #expect(folder.packages == ["v327680", "v0"])
        #expect(folder.addOns.count == 1)
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
