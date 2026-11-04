import AppKit
import NXCore
import SwiftUI

/// Selector principal de la biblioteca: una tira de carátulas que se centra
/// en el juego elegido y deja la información rica debajo, como un menú de
/// homebrew de consola sin esconder las acciones de escritorio.
struct GameCarouselView: View {
    @Environment(AppModel.self) private var model
    let games: [MacGameBundle]
    @Binding var selection: MacGameBundle.ID?
    let configure: (MacGameBundle) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 18) {
                    ForEach(games) { game in
                        Button {
                            choose(game, proxy: proxy)
                        } label: {
                            GameCoverCard(game: game, selected: selection == game.id)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            selection = game.id
                            model.play(game)
                        })
                        .accessibilityLabel(game.name)
                        .accessibilityAddTraits(selection == game.id ? .isSelected : [])
                        .contextMenu {
                            Button("Jugar") { model.play(game) }
                            Button("Configuración") { configure(game) }
                        }
                        .id(game.id)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
            }
            .onAppear {
                if let selection { proxy.scrollTo(selection, anchor: .center) }
            }
            .onChange(of: selection) { _, id in
                guard let id else { return }
                withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(height: 218)
    }

    private func choose(_ game: MacGameBundle, proxy: ScrollViewProxy) {
        selection = game.id
        withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(game.id, anchor: .center) }
    }

}

struct GameCoverCard: View {
    @Environment(AppModel.self) private var model
    let game: MacGameBundle
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GameCoverImage(game: game)
                .frame(width: selected ? 184 : 164, height: selected ? 126 : 112)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(selected ? Color.accentColor : .white.opacity(0.12), lineWidth: selected ? 3 : 1)
                }
            Text(game.name)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.white)
            Text(game.version.isEmpty ? game.titleID : "v\(game.version)")
                .font(.caption2).foregroundStyle(.white.opacity(0.75))

            if model.runner.isRunning(game) {
                Label("Jugando", systemImage: "play.fill")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.green, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .frame(width: selected ? 184 : 164, height: selected ? 190 : 176, alignment: .topLeading)
        .shadow(color: selected ? .accentColor.opacity(0.28) : .black.opacity(0.16), radius: selected ? 12 : 5, y: 4)
        .scaleEffect(selected ? 1.02 : 1)
        .animation(.snappy(duration: 0.2), value: selected)
    }
}

struct GameShowcaseView: View {
    @Environment(AppModel.self) private var model
    let game: MacGameBundle

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            GameCoverImage(game: game)
                .frame(width: 178, height: 178)
                .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(game.name).font(.title2.weight(.bold))
                    if model.runner.isRunning(game) {
                        Label("En ejecución", systemImage: "play.circle.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(.green)
                    }
                }

                HStack(spacing: 10) {
                    if !game.version.isEmpty { Text("v\(game.version)") }
                    Text(game.titleID).monospaced()
                    if let language = game.language, !language.isEmpty { Text(language) }
                }
                .font(.callout).foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if game.hasPipelineArchive { Label("Pipelines precargados", systemImage: "cpu") }
                    if game.hasAddOns { Label("DLC", systemImage: "shippingbox") }
                }
                .font(.caption).foregroundStyle(.secondary)

                Spacer(minLength: 12)

                HStack(spacing: 10) {
                    if model.runner.isRunning(game) {
                        Button(role: .destructive) { model.runner.stop(game) } label: {
                            Label("Cerrar juego", systemImage: "stop.fill")
                        }
                        .controlSize(.large)
                    } else {
                        Button { model.play(game) } label: {
                            Label("Jugar", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    NavigationLink(value: game) {
                        Label("Configuración", systemImage: "slider.horizontal.3")
                    }
                    .controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 178, alignment: .topLeading)
        }
        .padding(24)
    }
}

struct GameCoverImage: View {
    @Environment(AppModel.self) private var model
    let game: MacGameBundle

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var image: NSImage {
        model.artwork.image(for: game, role: .cover)
            ?? NSImage(contentsOf: game.iconURL)
            ?? NSWorkspace.shared.icon(forFile: game.url.path)
    }
}
