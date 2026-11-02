import AppKit
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case installer, library, folders, builds, compatibility, environment
    var id: String { rawValue }

    var title: String {
        switch self {
        case .installer: "Instalar FC26/FC27"
        case .library: "Biblioteca"
        case .folders: "Juegos en disco"
        case .builds: "Construcciones"
        case .compatibility: "Compatibilidad"
        case .environment: "Entorno"
        }
    }

    var symbol: String {
        switch self {
        case .installer: "shippingbox"
        case .library: "gamecontroller"
        case .folders: "externaldrive"
        case .builds: "hammer"
        case .compatibility: "checklist"
        case .environment: "stethoscope"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.hasLoadedLibrary {
                LibraryView()
            } else {
                LaunchSplashView(scanning: model.scanning)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: model.hasLoadedLibrary)
    }

}

/// Builder and maintenance workflows remain inside the console window.
struct ConsoleToolsView: View {
    @State private var selection: SidebarItem = .folders
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Picker("Herramienta", selection: $selection) {
                    ForEach([SidebarItem.folders, .installer, .builds, .compatibility]) { item in
                        Text(item.title).tag(item)
                    }
                }
                .frame(maxWidth: 350)
                Spacer()
                ProfileSwitcher()
                AllSavesMenu()
            }
            .padding(.horizontal, 18).padding(.top, 14)
            NavigationStack {
                switch selection {
                case .installer: FC27InstallerView(onBuild: { selection = .builds })
                case .folders: DiskGamesView(onBuild: { selection = .builds })
                case .builds: BuildsView()
                case .compatibility: CompatibilityView()
                default: EmptyView()
                }
            }
        }
    }
}

/// Pantalla de entrada de la biblioteca. Se mantiene visible durante el
/// primer escaneo para que el arranque no parezca una ventana vacía o un
/// salto brusco directo a las carátulas.
struct LaunchSplashView: View {
    let scanning: Bool

    var body: some View {
        GeometryReader { proxy in
            let logoSize = min(180, max(112, min(proxy.size.width, proxy.size.height) * 0.22))

            ZStack {
                RadialGradient(
                    colors: [Color(red: 0.20, green: 0.10, blue: 0.42),
                             Color(red: 0.025, green: 0.018, blue: 0.07)],
                    center: .center,
                    startRadius: 10,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.72
                )
                LinearGradient(
                    colors: [.black.opacity(0.08), .black.opacity(0.62)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(spacing: 22) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: logoSize, height: logoSize)
                        .shadow(color: .black.opacity(0.45), radius: 28, y: 14)

                    VStack(spacing: 8) {
                        Text("NXNATIVE")
                            .font(.system(size: 30, weight: .black, design: .rounded))
                            .tracking(4)
                            .foregroundStyle(.white)
                        Text("Tu biblioteca de juegos")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.white.opacity(0.78))
                    }

                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(.white)
                        Text(scanning ? "Preparando juegos y perfiles…" : "Preparando la biblioteca…")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
    }
}

/// Utilidades de Finder compartidas por las vistas.
@MainActor
enum Finder {
    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    static func open(_ url: URL) { NSWorkspace.shared.open(url) }

    static func chooseFolder(prompt: String = "Elegir") -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = prompt
        return p.runModal() == .OK ? p.url : nil
    }

    static func chooseFile(prompt: String = "Elegir") -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = false
        p.canChooseFiles = true
        p.allowsMultipleSelection = false
        p.prompt = prompt
        return p.runModal() == .OK ? p.url : nil
    }
}

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
