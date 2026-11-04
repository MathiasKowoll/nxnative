import AppKit
import Foundation
import NXCore
import Observation
import UniformTypeIdentifiers

/// User-selected artwork stays on this Mac, outside game bundles and the app.
@MainActor @Observable
final class ArtworkStore {
    enum Role: String, CaseIterable {
        case cover, hero

        var label: String { self == .cover ? "carátula" : "fondo" }
        var minimumPixels: Int { self == .cover ? 800 : 1920 }
        var fileName: String { rawValue + ".png" }
    }

    private(set) var revision = 0
    @ObservationIgnored private var cache: [String: NSImage] = [:]

    private var root: URL {
        MacGameBundle.supportRoot.appendingPathComponent("artwork", isDirectory: true)
    }

    func image(for game: MacGameBundle, role: Role) -> NSImage? {
        _ = revision
        let key = game.titleID + "/" + role.rawValue
        if let image = cache[key] { return image }
        let url = fileURL(for: game, role: role)
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache[key] = image
        return image
    }

    func chooseArtwork(for game: MacGameBundle, role: Role) throws -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Elegir \(role.label)"
        panel.message = role == .hero
            ? "Usa una imagen horizontal de al menos 1920 píxeles."
            : "Usa una carátula o arte de al menos 800 píxeles."
        panel.prompt = "Usar imagen"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        try importArtwork(from: url, for: game, role: role)
        return true
    }

    func importArtwork(from source: URL, for game: MacGameBundle, role: Role) throws {
        let values = try source.resourceValues(forKeys: [.fileSizeKey])
        if (values.fileSize ?? 0) > 40 * 1_024 * 1_024 {
            throw ArtworkError.tooLarge
        }
        guard let image = NSImage(contentsOf: source) else { throw ArtworkError.unreadable }
        let pixels = pixelSize(of: image)
        guard max(pixels.width, pixels.height) >= role.minimumPixels else {
            throw ArtworkError.tooSmall(role: role, pixels: pixels)
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ArtworkError.unreadable
        }
        guard data.count <= 40 * 1_024 * 1_024 else { throw ArtworkError.tooLarge }
        let destination = fileURL(for: game, role: role)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        cache[game.titleID + "/" + role.rawValue] = NSImage(data: data)
        revision &+= 1
    }

    func removeArtwork(for game: MacGameBundle, role: Role) throws {
        let destination = fileURL(for: game, role: role)
        guard FileManager.default.fileExists(atPath: destination.path) else { return }
        try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
        cache[game.titleID + "/" + role.rawValue] = nil
        revision &+= 1
    }

    func searchWeb(for game: MacGameBundle, role: Role) {
        var query = game.name + (role == .hero ? " official key art 4K" : " official cover art")
        if role == .hero { query += " widescreen" }
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "tbm", value: "isch"), URLQueryItem(name: "q", value: query)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    private func fileURL(for game: MacGameBundle, role: Role) -> URL {
        root.appendingPathComponent(game.titleID, isDirectory: true).appendingPathComponent(role.fileName)
    }

    private func pixelSize(of image: NSImage) -> (width: Int, height: Int) {
        image.representations.reduce((0, 0)) { size, representation in
            (max(size.0, representation.pixelsWide), max(size.1, representation.pixelsHigh))
        }
    }

    enum ArtworkError: LocalizedError {
        case unreadable, tooLarge, tooSmall(role: Role, pixels: (width: Int, height: Int))

        var errorDescription: String? {
            switch self {
            case .unreadable: "No se pudo leer la imagen elegida."
            case .tooLarge: "La imagen supera el límite local de 40 MB."
            case let .tooSmall(role, pixels):
                "La \(role.label) mide \(pixels.width) × \(pixels.height) px; usa al menos \(role.minimumPixels) px en su lado mayor."
            }
        }
    }
}
