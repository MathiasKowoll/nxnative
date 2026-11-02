import Foundation
import Observation

/// Sigue el log de un juego (`~/Library/Logs/nxnative/<id>.log`).
///
/// Se lee por sondeo y no con eventos de archivo: el lanzador rota el log en
/// cada arranque (el viejo pasa a `.prev.log`), y un vigilante enganchado al
/// descriptor se quedaría mirando el archivo que ya no es. Las líneas del log
/// son diagnóstico para personas, no una interfaz (`docs/frontends.md`): aquí
/// solo se colorean las `[RED]`, no se interpretan.
@MainActor @Observable
final class LogTail {
    struct Line: Identifiable {
        let id: Int
        let text: String
        var isRed: Bool { text.contains("[RED]") }
    }

    private(set) var lines: [Line] = []
    private(set) var redCount = 0
    private(set) var exists = false
    let url: URL
    private let maxLines = 5000

    private var offset: UInt64 = 0
    private var inode: UInt64 = 0
    private var partial = ""
    private var counter = 0
    private var timer: Timer?

    init(url: URL) { self.url = url }

    func start() {
        poll()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func poll() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            exists = false
            return
        }
        exists = true
        let ino = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        if ino != inode || size < offset { reset(); inode = ino }
        guard size > offset, let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        // Un log de varios MB al abrir: solo nos interesa el final.
        if size - offset > 4_000_000 { try? h.seek(toOffset: size - 4_000_000); partial = "" }
        let data = h.readDataToEndOfFile()
        offset = size
        let text = partial + String(decoding: data, as: UTF8.self)
        var parts = text.components(separatedBy: "\n")
        partial = parts.removeLast()
        for p in parts {
            counter += 1
            let l = Line(id: counter, text: p)
            if l.isRed { redCount += 1 }
            lines.append(l)
        }
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    private func reset() {
        lines = []
        redCount = 0
        offset = 0
        partial = ""
    }
}
