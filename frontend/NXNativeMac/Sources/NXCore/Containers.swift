import Foundation

/// Las cabeceras de los contenedores de Switch que se pueden leer SIN claves:
/// un NSP es una PFS0 y un XCI lleva una HFS0 con sus particiones. Ninguna de
/// las dos va cifrada; lo cifrado son los NCA de dentro. Si el jugador da sus
/// `prod.keys`, `titleID(_:cartridge:keyset:)` lee además la cabecera del NCA
/// de metadatos (0x400 bytes, nunca el contenido); sin claves queda lo que
/// dice el nombre del archivo o el ticket.
///
/// Todo índice se valida contra el tamaño del archivo antes de usarse: un
/// archivo cortado o que no es lo que dice su extensión devuelve nil.
public enum Containers {
    // MARK: PFS0 (NSP, NSZ)

    /// Los nombres de los archivos de una PFS0.
    public static func pfs0Names(_ url: URL) -> [String]? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        return pfs0Entries(h, at: 0, limit: fileSize(url))?.map(\.name)
    }

    struct PFS0Entry { var name: String; var offset: UInt64; var size: UInt64 }

    static func pfs0Entries(_ h: FileHandle, at base: UInt64, limit: UInt64) -> [PFS0Entry]? {
        guard let head = read(h, base, 16), head.count == 16, head.prefix(4) == Data("PFS0".utf8) else { return nil }
        let n = UInt64(head.u32(4)), strSize = UInt64(head.u32(8))
        let tableSize = n * 0x18
        let dataStart = base + 16 + tableSize + strSize
        guard n < 100_000, strSize < 16 << 20, base + 16 + tableSize + strSize <= limit,
              let table = read(h, base + 16, Int(tableSize)), let strs = read(h, base + 16 + tableSize, Int(strSize)),
              table.count == Int(tableSize), strs.count == Int(strSize) else { return nil }
        return (0..<Int(n)).compactMap { i in
            guard let name = cString(strs, at: Int(table.u32(i * 0x18 + 0x10))) else { return nil }
            return PFS0Entry(name: name, offset: dataStart + table.u64(i * 0x18), size: table.u64(i * 0x18 + 8))
        }
    }

    /// Title IDs de los tickets de una PFS0: un ticket se llama
    /// `<rights ID>.tik` y los 16 primeros dígitos del rights ID son el title
    /// ID. Es lo que lee primero `title_of()` del script, porque la etiqueta
    /// del nombre puede estar mal.
    public static func ticketTitleIDs(_ names: [String]) -> [TitleID] {
        names.compactMap { n in
            guard n.count == 36, n.lowercased().hasSuffix(".tik") else { return nil }
            return TitleID(n.prefix(16))
        }
    }

    // MARK: XCI (XCI, XCZ)

    public struct XCIInfo: Sendable, Hashable {
        /// Bytes antes de la cabecera: 0, o 0x1000 en un volcado que incluye
        /// el área de claves de la tarjeta.
        public var headerOffset: UInt64
        public var partitions: [String]
        /// Los archivos de la partición `secure`, donde van los NCA del juego.
        public var secureFiles: [String]

        /// Paquetes en el cartucho: un `.cnmt.nca` por contenido (juego base,
        /// actualización o DLC).
        public var contentMetaCount: Int {
            secureFiles.filter { $0.lowercased().hasSuffix(".cnmt.nca") || $0.lowercased().hasSuffix(".cnmt.ncz") }.count
        }

        /// Un «1G+1U» o con DLC: nxnative solo usa la base del cartucho.
        public var carriesMoreThanBase: Bool { contentMetaCount > 1 }
    }

    public static func xciInfo(_ url: URL) -> XCIInfo? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let s = xciScan(h, limit: fileSize(url)) else { return nil }
        return XCIInfo(headerOffset: s.headerOffset, partitions: s.partitions, secureFiles: s.secure.map(\.name))
    }

    /// Lo que se lee de un cartucho sin claves más sus entradas de `secure`
    /// con posición (para las cabeceras NCA cifradas, cuando hay claves).
    struct XCIScan { var headerOffset: UInt64; var partitions: [String]; var secure: [HFS0Entry] }

    static func xciScan(_ h: FileHandle, limit: UInt64) -> XCIScan? {
        for off: UInt64 in [0, 0x1000] {
            guard let hdr = read(h, off + 0x100, 0x40), hdr.count == 0x40, hdr.prefix(4) == Data("HEAD".utf8) else { continue }
            // 0x130: dirección de la cabecera de la HFS0 raíz.
            let root = off + hdr.u64(0x30)
            guard let entries = hfs0Entries(h, at: root, limit: limit) else { return nil }
            var secure: [HFS0Entry] = []
            if let s = entries.first(where: { $0.name == "secure" }) {
                secure = hfs0Entries(h, at: s.offset, limit: limit) ?? []
            }
            return XCIScan(headerOffset: off, partitions: entries.map(\.name), secure: secure)
        }
        return nil
    }

    // MARK: title ID con claves

    /// El title ID del archivo leyendo la cabecera cifrada de su NCA de
    /// metadatos (`*.cnmt.nca` en la PFS0 del NSP o en la partición `secure`
    /// del cartucho). En un contenedor con varios contenidos (un «1G+1U») se
    /// prefiere el de la base: es al que corresponde el archivo entero, y el
    /// aviso de que trae la actualización dentro sigue saliendo por la cuenta
    /// de `XCIInfo`. Un `*.cnmt.ncz` va comprimido (zstd) y no se puede leer
    /// así. nil = claves que no valen para ese archivo o contenedor ilegible.
    public static func titleID(_ url: URL, cartridge: Bool, keyset: Keyset) -> TitleID? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let limit = fileSize(url)
        let metas: [UInt64]
        if cartridge {
            metas = xciScan(h, limit: limit)?.secure
                .filter { $0.name.lowercased().hasSuffix(".cnmt.nca") }.map(\.offset) ?? []
        } else {
            metas = pfs0Entries(h, at: 0, limit: limit)?
                .filter { $0.name.lowercased().hasSuffix(".cnmt.nca") }.map(\.offset) ?? []
        }
        let ids = metas.compactMap { NCAHeader.titleID(h, at: $0, keyset: keyset) }
        return ids.first { $0.kind == .base } ?? ids.first
    }

    struct HFS0Entry { var name: String; var offset: UInt64; var size: UInt64 }

    /// Una HFS0: 16 bytes de cabecera, entradas de 0x40 (offset, tamaño,
    /// nombre, hash) y la tabla de cadenas. Los offsets son relativos al fin
    /// de la tabla de cadenas; aquí se devuelven absolutos.
    static func hfs0Entries(_ h: FileHandle, at base: UInt64, limit: UInt64) -> [HFS0Entry]? {
        guard let head = read(h, base, 16), head.count == 16, head.prefix(4) == Data("HFS0".utf8) else { return nil }
        let n = UInt64(head.u32(4)), strSize = UInt64(head.u32(8))
        let tableSize = n * 0x40
        let dataStart = base + 16 + tableSize + strSize
        guard n < 100_000, strSize < 16 << 20, dataStart <= limit,
              let table = read(h, base + 16, Int(tableSize)), let strs = read(h, base + 16 + tableSize, Int(strSize)),
              table.count == Int(tableSize), strs.count == Int(strSize) else { return nil }
        return (0..<Int(n)).compactMap { i in
            let e = i * 0x40
            guard let name = cString(strs, at: Int(table.u32(e + 0x10))) else { return nil }
            return HFS0Entry(name: name, offset: dataStart + table.u64(e), size: table.u64(e + 8))
        }
    }

    // MARK: utilidades

    static func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    static func read(_ h: FileHandle, _ offset: UInt64, _ count: Int) -> Data? {
        guard count >= 0, (try? h.seek(toOffset: offset)) != nil else { return nil }
        return count == 0 ? Data() : try? h.read(upToCount: count)
    }

    static func cString(_ d: Data, at offset: Int) -> String? {
        guard offset >= 0, offset < d.count else { return nil }
        let start = d.startIndex + offset
        let end = d[start...].firstIndex(of: 0) ?? d.endIndex
        return String(data: d[start..<end], encoding: .utf8)
    }
}

extension Data {
    func u32(_ o: Int) -> UInt32 {
        let s = startIndex + o
        return UInt32(self[s]) | UInt32(self[s + 1]) << 8 | UInt32(self[s + 2]) << 16 | UInt32(self[s + 3]) << 24
    }

    func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) | UInt64(u32(o + 4)) << 32 }
}
