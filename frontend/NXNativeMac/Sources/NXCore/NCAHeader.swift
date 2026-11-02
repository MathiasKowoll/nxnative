import Foundation

/// El `prod.keys` del jugador, solo para identificar archivos. De las cientos
/// de claves del archivo se lee una, `header_key`: con ella se descifra la
/// CABECERA del NCA de metadatos de un archivo (0x400 bytes) y ahí está el
/// title ID. El contenido no se descifra aquí y los valores de las claves no
/// se muestran ni se registran (regla del repositorio).
public struct Keyset: Sendable {
    /// 32 bytes: clave de datos || clave de tweak.
    let headerKey: Data

    /// nil si el archivo no existe o no trae `header_key` (por ejemplo, es un
    /// apunte de pocas claves): entonces el escaneo queda como antes, sin
    /// descifrado.
    public init?(url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        self.init(text: text)
    }

    init?(text: String) {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            values[line[..<eq].trimmingCharacters(in: .whitespaces)] =
                line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        guard let hex = values["header_key"], let key = Data(hex: hex), key.count == 32 else { return nil }
        headerKey = key
    }
}

extension Data {
    /// `"a1648e…"` → Data. nil en cuanto algo no es hex.
    init?(hex: String) {
        let b = Array(hex.utf8)
        guard b.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        var d = Data(); d.reserveCapacity(b.count / 2)
        for i in stride(from: 0, to: b.count, by: 2) {
            guard let hi = nibble(b[i]), let lo = nibble(b[i + 1]) else { return nil }
            d.append(hi << 4 | lo)
        }
        self = d
    }
}

/// La cabecera de un NCA y su title ID.
public enum NCAHeader {
    /// El title ID del NCA en `offset` (absoluto en el archivo), o nil si no
    /// descifra o no es un NCA3. Se leen 0x400 bytes y nada más.
    public static func titleID(_ h: FileHandle, at offset: UInt64, keyset: Keyset) -> TitleID? {
        guard let raw = Containers.read(h, offset, 0x400), raw.count == 0x400,
              let dec = AES128.xtsDecrypt(raw, keyPair: keyset.headerKey),
              dec.dropFirst(0x200).prefix(4) == Data("NCA3".utf8) else { return nil }
        let t = TitleID(value: dec.u64(0x210))
        // Los title ID de Switch empiezan por 01: si no, no era un NCA.
        return t.value >> 56 == 0x01 ? t : nil
    }
}

/// AES-128 sin dependencias: las cabeceras NCA van en AES-XTS-128 y ni
/// CryptoKit ni CommonCrypto ofrecen XTS. Verificada con el vector oficial de
/// la FIPS-197 (cifrar y descifrar) y contra el descifrado de referencia de
/// una cabecera real; ambos en `Tests`.
struct AES128 {
    /// La clave ya expandida: 11 rondas de 16 bytes.
    private let rk: [UInt8]

    init(_ key: Data) {
        precondition(key.count == 16, "AES-128: la clave tiene 16 bytes")
        rk = Self.expand([UInt8](key))
    }

    func encrypt(_ block: [UInt8]) -> [UInt8] {
        precondition(block.count == 16)
        var s = block
        addRoundKey(&s, 0)
        for round in 1...9 {
            Self.substitute(&s, Self.sbox)
            Self.shiftRows(&s, inverse: false)
            Self.mix(&s)
            addRoundKey(&s, round)
        }
        Self.substitute(&s, Self.sbox)
        Self.shiftRows(&s, inverse: false)
        addRoundKey(&s, 10)
        return s
    }

    func decrypt(_ block: [UInt8]) -> [UInt8] {
        precondition(block.count == 16)
        var s = block
        addRoundKey(&s, 10)
        for round in (1...9).reversed() {
            Self.shiftRows(&s, inverse: true)
            Self.substitute(&s, Self.invSbox)
            addRoundKey(&s, round)
            Self.unmMix(&s)
        }
        Self.shiftRows(&s, inverse: true)
        Self.substitute(&s, Self.invSbox)
        addRoundKey(&s, 0)
        return s
    }

    // MARK: XTS

    /// Descifra `data` (múltiplo de 0x200) tal y como va una cabecera NCA:
    /// AES-XTS-128 por sectores de 0x200, con el tweak del sector cifrado y
    /// multiplicado por x en GF(2^128) bloque a bloque. `keyPair` es
    /// `header_key`: 16 bytes de datos || 16 de tweak.
    static func xtsDecrypt(_ data: Data, keyPair: Data) -> Data? {
        guard keyPair.count == 32, !data.isEmpty, data.count % 0x200 == 0 else { return nil }
        let dataKey = AES128(Data(keyPair.prefix(16)))
        let tweakKey = AES128(Data(keyPair.dropFirst(16)))
        let bytes = [UInt8](data)
        var out = Data(); out.reserveCapacity(data.count)
        for sector in 0..<(data.count / 0x200) {
            // El tweak es el número de sector, big-endian (así lo escribe el
            // aes_xts de hactool y así lo mide la implementación de referencia).
            var tweak = tweakKey.encrypt(UInt64(sector).bigEndian128)
            for block in 0..<0x20 {
                let base = sector * 0x200 + block * 16
                let c = Array(bytes[base..<(base + 16)])
                let pre = zip(c, tweak).map(^)
                let d = dataKey.decrypt(pre)
                for i in 0..<16 { out.append(d[i] ^ tweak[i]) }
                tweak = Self.mulX(tweak)
            }
        }
        return out
    }

    /// Multiplicar por x en GF(2^128) como la IEEE 1619: byte 0 = extremo
    /// bajo, el acarreo final reduce con 0x87 en el byte 0 (el gf128mul_x_ble
    /// de Linux, que usan hactool y cryptography).
    static func mulX(_ t: [UInt8]) -> [UInt8] {
        var t = t, carry: UInt8 = 0
        for i in 0..<16 {
            let c = t[i] >> 7
            t[i] = (t[i] << 1) | carry
            carry = c
        }
        if carry != 0 { t[0] ^= 0x87 }
        return t
    }

    // MARK: rondas

    private func addRoundKey(_ s: inout [UInt8], _ round: Int) {
        for i in 0..<16 { s[i] ^= rk[round * 16 + i] }
    }

    private static func substitute(_ s: inout [UInt8], _ box: [UInt8]) {
        for i in 0..<16 { s[i] = box[Int(s[i])] }
    }

    /// Estado en columnas (FIPS-197): fila r, columna c → s[r + 4c].
    private static func shiftRows(_ s: inout [UInt8], inverse: Bool) {
        for r in 1..<4 {
            let row = (0..<4).map { s[r + 4 * $0] }
            for c in 0..<4 { s[r + 4 * c] = row[(c + (inverse ? 4 - r : r)) % 4] }
        }
    }

    private static func mix(_ s: inout [UInt8]) {
        for c in 0..<4 {
            let a = (s[4 * c], s[4 * c + 1], s[4 * c + 2], s[4 * c + 3])
            s[4 * c]     = gm(a.0, 2) ^ gm(a.1, 3) ^ a.2 ^ a.3
            s[4 * c + 1] = a.0 ^ gm(a.1, 2) ^ gm(a.2, 3) ^ a.3
            s[4 * c + 2] = a.0 ^ a.1 ^ gm(a.2, 2) ^ gm(a.3, 3)
            s[4 * c + 3] = gm(a.0, 3) ^ a.1 ^ a.2 ^ gm(a.3, 2)
        }
    }

    private static func unmMix(_ s: inout [UInt8]) {
        for c in 0..<4 {
            let a = (s[4 * c], s[4 * c + 1], s[4 * c + 2], s[4 * c + 3])
            s[4 * c]     = gm(a.0, 14) ^ gm(a.1, 11) ^ gm(a.2, 13) ^ gm(a.3, 9)
            s[4 * c + 1] = gm(a.0, 9) ^ gm(a.1, 14) ^ gm(a.2, 11) ^ gm(a.3, 13)
            s[4 * c + 2] = gm(a.0, 13) ^ gm(a.1, 9) ^ gm(a.2, 14) ^ gm(a.3, 11)
            s[4 * c + 3] = gm(a.0, 11) ^ gm(a.1, 13) ^ gm(a.2, 9) ^ gm(a.3, 14)
        }
    }

    private static func gm(_ a: UInt8, _ n: UInt8) -> UInt8 {
        var a = a, n = n, r: UInt8 = 0
        while n != 0 {
            if n & 1 != 0 { r ^= a }
            a = a & 0x80 != 0 ? a << 1 ^ 0x1B : a << 1
            n >>= 1
        }
        return r
    }

    private static func expand(_ k: [UInt8]) -> [UInt8] {
        var w = k; w.reserveCapacity(176)
        var r = 0
        while w.count < 176 {
            var t = Array(w[(w.count - 4)...])
            if w.count % 16 == 0 {
                t = [sbox[Int(t[1])] ^ rcon[r], sbox[Int(t[2])], sbox[Int(t[3])], sbox[Int(t[0])]]
                r += 1
            }
            for j in 0..<4 { w.append(w[w.count - 16] ^ t[j]) }
        }
        return w
    }

    private static let rcon: [UInt8] = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36]

    private static let sbox: [UInt8] = [
        0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
        0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
        0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
        0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
        0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
        0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
        0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
        0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
        0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
        0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
        0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
        0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
        0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
        0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
        0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
        0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
    ]

    private static let invSbox: [UInt8] = [
        0x52, 0x09, 0x6a, 0xd5, 0x30, 0x36, 0xa5, 0x38, 0xbf, 0x40, 0xa3, 0x9e, 0x81, 0xf3, 0xd7, 0xfb,
        0x7c, 0xe3, 0x39, 0x82, 0x9b, 0x2f, 0xff, 0x87, 0x34, 0x8e, 0x43, 0x44, 0xc4, 0xde, 0xe9, 0xcb,
        0x54, 0x7b, 0x94, 0x32, 0xa6, 0xc2, 0x23, 0x3d, 0xee, 0x4c, 0x95, 0x0b, 0x42, 0xfa, 0xc3, 0x4e,
        0x08, 0x2e, 0xa1, 0x66, 0x28, 0xd9, 0x24, 0xb2, 0x76, 0x5b, 0xa2, 0x49, 0x6d, 0x8b, 0xd1, 0x25,
        0x72, 0xf8, 0xf6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xd4, 0xa4, 0x5c, 0xcc, 0x5d, 0x65, 0xb6, 0x92,
        0x6c, 0x70, 0x48, 0x50, 0xfd, 0xed, 0xb9, 0xda, 0x5e, 0x15, 0x46, 0x57, 0xa7, 0x8d, 0x9d, 0x84,
        0x90, 0xd8, 0xab, 0x00, 0x8c, 0xbc, 0xd3, 0x0a, 0xf7, 0xe4, 0x58, 0x05, 0xb8, 0xb3, 0x45, 0x06,
        0xd0, 0x2c, 0x1e, 0x8f, 0xca, 0x3f, 0x0f, 0x02, 0xc1, 0xaf, 0xbd, 0x03, 0x01, 0x13, 0x8a, 0x6b,
        0x3a, 0x91, 0x11, 0x41, 0x4f, 0x67, 0xdc, 0xea, 0x97, 0xf2, 0xcf, 0xce, 0xf0, 0xb4, 0xe6, 0x73,
        0x96, 0xac, 0x74, 0x22, 0xe7, 0xad, 0x35, 0x85, 0xe2, 0xf9, 0x37, 0xe8, 0x1c, 0x75, 0xdf, 0x6e,
        0x47, 0xf1, 0x1a, 0x71, 0x1d, 0x29, 0xc5, 0x89, 0x6f, 0xb7, 0x62, 0x0e, 0xaa, 0x18, 0xbe, 0x1b,
        0xfc, 0x56, 0x3e, 0x4b, 0xc6, 0xd2, 0x79, 0x20, 0x9a, 0xdb, 0xc0, 0xfe, 0x78, 0xcd, 0x5a, 0xf4,
        0x1f, 0xdd, 0xa8, 0x33, 0x88, 0x07, 0xc7, 0x31, 0xb1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xec, 0x5f,
        0x60, 0x51, 0x7f, 0xa9, 0x19, 0xb5, 0x4a, 0x0d, 0x2d, 0xe5, 0x7a, 0x9f, 0x93, 0xc9, 0x9c, 0xef,
        0xa0, 0xe0, 0x3b, 0x4d, 0xae, 0x2a, 0xf5, 0xb0, 0xc8, 0xeb, 0xbb, 0x3c, 0x83, 0x53, 0x99, 0x61,
        0x17, 0x2b, 0x04, 0x7e, 0xba, 0x77, 0xd6, 0x26, 0xe1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0c, 0x7d,
    ]
}

private extension UInt64 {
    /// El valor como entero big-endian de 128 bits (tweak XTS de un sector NCA).
    var bigEndian128: [UInt8] { (0..<16).map { UInt8(truncatingIfNeeded: self >> (8 * (15 - $0))) } }
}
