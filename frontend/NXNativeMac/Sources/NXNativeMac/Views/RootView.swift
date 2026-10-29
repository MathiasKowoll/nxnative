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
    @State private var selection: SidebarItem? = .library

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.symbol)
                    .badge(badge(for: item))
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .top, alignment: .leading) { ProfileSwitcher() }
            .safeAreaInset(edge: .bottom) { statusFooter }
        } detail: {
            switch selection ?? .library {
            case .installer: FC27InstallerView(onBuild: { selection = .builds })
            case .library: LibraryView()
            case .folders: DiskGamesView(onBuild: { selection = .builds })
            case .builds: BuildsView()
            case .compatibility: CompatibilityView()
            case .environment: EnvironmentView(compact: false)
            }
        }
    }

    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .installer: 0
        case .library: model.games.count
        case .folders: model.library.count
        case .builds: model.builds.pendingCount
        case .environment: model.toolchain.checks.filter { $0.status == .failure }.count
        case .compatibility: 0
        }
    }

    @ViewBuilder private var statusFooter: some View {
        if model.scanning || model.toolchain.running {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Escaneando…").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
        } else if let job = model.builds.active {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title).font(.caption).lineLimit(1)
                ProgressView(value: job.overallFraction ?? 0).controlSize(.small)
            }
            .padding(10)
        }
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
