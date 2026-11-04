import Foundation
import NXCore
import SwiftUI

/// Ajustes por juego pensados para una pantalla y un mando, no para un
/// teclado. Usa la misma GameSettingsStore que el formulario de escritorio,
/// por lo que sus cambios siguen siendo compatibles con abrir el juego desde
/// Finder.
struct GamepadSettingsView: View {
    @Environment(AppModel.self) private var model
    @Bindable var store: GameSettingsStore
    var rebuild: (() -> Void)? = nil

    enum Item: Hashable {
        case setting(String)
        case buttonGlyphs
        case highRefresh
        case reset
        case rebuild
    }

    @State private var selectedIndex = 0
    @State private var busy = false
    @State private var confirmReset = false
    @FocusState private var listFocused: Bool

    private var settings: [Setting] { store.settings?.settings ?? [] }

    private var items: [Item] {
        settings.map { Item.setting($0.id) } + [.buttonGlyphs, .highRefresh] + (rebuild == nil ? [] : [.rebuild]) + [.reset]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            HStack(spacing: 8) {
                                Button {
                                    selectedIndex = index
                                    activate(item)
                                } label: {
                                    GamepadSettingRow(
                                item: item,
                                setting: setting(for: item),
                                store: store,
                                selected: index == selectedIndex
                                    )
                                }
                                .buttonStyle(.plain)
                                if item != .reset && item != .rebuild {
                                Button {
                                    selectedIndex = index
                                    adjust(item, by: -1)
                                } label: { Image(systemName: "chevron.left") }
                                .accessibilityLabel("Valor anterior")
                                Button {
                                    selectedIndex = index
                                    adjust(item, by: 1)
                                } label: { Image(systemName: "chevron.right") }
                                .accessibilityLabel("Valor siguiente")
                                }
                            }
                            .id(index)
                            .disabled(busy)
                        }
                    }
                    .padding(22)
                }
                .onAppear {
                    selectedIndex = min(selectedIndex, max(0, items.count - 1))
                }
                .onChange(of: selectedIndex) { _, index in
                    withAnimation(.snappy(duration: 0.2)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }

            Divider()
            footer
        }
        .focusable().focusEffectDisabled().focused($listFocused)
        .onAppear { listFocused = true }
        .onKeyPress(.upArrow) { key(.up) }
        .onKeyPress(.downArrow) { key(.down) }
        .onKeyPress(.leftArrow) { key(.left) }
        .onKeyPress(.rightArrow) { key(.right) }
        .onKeyPress(.return, phases: .down) { _ in key(.primary) }
        .onChange(of: confirmReset) { _, presented in model.gamepad.dialogPresented = presented }
        .onDisappear { model.gamepad.dialogPresented = false }
        .alert("Restablecer ajustes", isPresented: $confirmReset) {
            Button("Restablecer", role: .destructive) { store.resetAll() }
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text("Se quitarán las elecciones de este juego y se conservarán los interruptores escritos en Avanzado.")
        }
        .onChange(of: model.gamepad.sequence) { _, _ in
            handle(model.gamepad.lastAction)
        }
        .onChange(of: store.settings) { _, _ in
            selectedIndex = min(selectedIndex, max(0, items.count - 1))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "gamecontroller.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ajustes del juego")
                    .font(.headline)
                Text("\(selectedIndex + 1) de \(items.count) · \(store.game.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        VStack(spacing: 4) {
            HStack(spacing: 14) {
                Text("↑↓ seleccionar")
                Text("←→ cambiar")
                Text("Enter / clic: aplicar")
            }
            if let error = store.error {
                Text(error).foregroundStyle(.red).lineLimit(2)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.vertical, 8)
    }

    private func handle(_ action: GamepadInput.Action) {
        if confirmReset {
            if action == .back { confirmReset = false }
            // Destructive confirmation remains an explicit dialog button.
            return
        }
        guard !items.isEmpty, !busy else { return }
        switch action {
        case .up:
            selectedIndex = max(0, selectedIndex - 1)
        case .down:
            selectedIndex = min(items.count - 1, selectedIndex + 1)
        case .left:
            adjust(items[selectedIndex], by: -1)
        case .right, .primary:
            adjust(items[selectedIndex], by: 1)
        case .back, .configure, .previousTab, .nextTab, .previousSection, .nextSection, .closeGame:
            break
        }
    }

    private func key(_ action: GamepadInput.Action) -> KeyPress.Result {
        guard !confirmReset else { return .ignored }
        handle(action)
        return .handled
    }

    private func activate(_ item: Item) {
        adjust(item, by: 1)
    }

    private func adjust(_ item: Item, by delta: Int) {
        switch item {
        case .setting(let id):
            guard let setting = settings.first(where: { $0.id == id }), !store.ownedByHighRefresh(setting) else { return }
            adjust(setting, by: delta)
        case .buttonGlyphs:
            cycleButtonGlyphs()
        case .highRefresh:
            store.setHighRefresh(!store.highRefresh)
        case .reset:
            confirmReset = true
        case .rebuild:
            rebuild?()
        }
    }

    private func adjust(_ setting: Setting, by delta: Int) {
        switch setting.kind {
        case .choice:
            let choices = setting.choices
            guard !choices.isEmpty else { return }
            let current = choices.firstIndex(where: { $0.value == store.value(setting) }) ?? (delta > 0 ? -1 : 0)
            let next = (current + delta + choices.count) % choices.count
            store.set(setting, choices[next].value)

        case .toggle:
            let on = setting.on ?? "1"
            let off = setting.off ?? "0"
            store.set(setting, store.value(setting) == on ? off : on)

        case .range:
            let low = setting.min ?? 0
            let high = setting.max ?? 1
            guard high >= low else { return }
            let current = Double(store.value(setting)) ?? Double(setting.defaultValue) ?? low
            let step = setting.step ?? max((high - low) / 20, 0.01)
            let next = min(high, max(low, current + (Double(delta) * step)))
            store.set(setting, setting.format(range: next))
        }
    }

    private func cycleButtonGlyphs() {
        guard let current = store.buttonGlyphs else { return }
        let next: ButtonGlyphs = current == .nintendo ? .playstation : .nintendo
        busy = true
        Task { @MainActor in
            await store.setButtonGlyphs(next, repository: model.repository, python: model.toolchain.python)
            busy = false
        }
    }

    private func setting(for item: Item) -> Setting? {
        guard case .setting(let id) = item else { return nil }
        return settings.first { $0.id == id }
    }
}

private struct GamepadSettingRow: View {
    let item: GamepadSettingsView.Item
    let setting: Setting?
    @Bindable var store: GameSettingsStore
    let selected: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(selected ? .semibold : .regular))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(selected ? .primary : .secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? Color.accentColor : .clear, lineWidth: selected ? 2 : 0)
        }
        .opacity(isLocked ? 0.58 : 1)
    }

    private var title: String {
        switch item {
        case .setting: return setting?.label ?? "Ajuste"
        case .buttonGlyphs: return "Iconos de botones"
        case .highRefresh: return "Hasta 120 imágenes por segundo"
        case .reset: return "Restablecer valores probados"
        case .rebuild: return "Reconstruir en el Taller"
        }
    }

    private var subtitle: String {
        switch item {
        case .setting:
            guard let setting else { return "" }
            var text = setting.note
            if store.ownedByHighRefresh(setting) {
                text = text.isEmpty ? "Lo controla el modo 120 Hz." : "\(text) · Lo controla el modo 120 Hz."
            }
            return text
        case .buttonGlyphs:
            return "Se aplica en el próximo arranque del juego."
        case .highRefresh:
            return "Modo experimental por juego."
        case .reset:
            return "Conserva los interruptores escritos en Avanzado."
        case .rebuild:
            return "Revisar archivos, destino y recursos antes de empezar."
        }
    }

    private var value: String {
        switch item {
        case .setting:
            guard let setting else { return "—" }
            let raw = store.value(setting)
            switch setting.kind {
            case .choice:
                return setting.choices.first { $0.value == raw }?.label ?? raw
            case .range:
                return raw
            case .toggle:
                return raw == (setting.on ?? "1") ? "Activado" : "Desactivado"
            }
        case .buttonGlyphs:
            switch store.buttonGlyphs {
            case .nintendo: return "Switch"
            case .playstation: return "PlayStation"
            case nil: return "Manual"
            }
        case .highRefresh:
            return store.highRefresh ? "Activado" : "Desactivado"
        case .reset:
            return "A confirmar"
        case .rebuild:
            return "Abrir"
        }
    }

    private var icon: String {
        switch item {
        case .setting(let id):
            if id.localizedCaseInsensitiveContains("fps") || id.localizedCaseInsensitiveContains("resolution") {
                return "gauge.with.dots.needle.67percent"
            }
            return "slider.horizontal.3"
        case .buttonGlyphs: return "circle.grid.2x2.fill"
        case .highRefresh: return "speedometer"
        case .reset: return "arrow.counterclockwise"
        case .rebuild: return "hammer"
        }
    }

    private var isLocked: Bool {
        guard let setting else { return false }
        return store.ownedByHighRefresh(setting)
    }
}
