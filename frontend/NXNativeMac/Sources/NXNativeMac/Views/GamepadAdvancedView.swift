import NXCore
import SwiftUI

/// Vista de Avanzado reducida a operaciones que se pueden hacer con un mando:
/// recorrer los interruptores activos, cambiar los valores que documenta
/// nxnative y añadir/quitar variables conocidas. El editor de texto libre se
/// mantiene en `AdvancedEnvView` para teclado y ratón.
struct GamepadAdvancedView: View {
    @Environment(AppModel.self) private var model
    @Bindable var store: GameSettingsStore

    enum Item: Hashable {
        case group
        case active(String)
        case known(String)
    }

    @State private var group: EnvSwitch.Group = .player
    @State private var selectedIndex = 0
    @FocusState private var listFocused: Bool

    private var groups: [EnvSwitch.Group] { EnvSwitch.Group.allCases.filter(\.offered) }

    private var activeKeys: Set<String> { Set(store.activeSwitches.map(\.key)) }

    private var knownSwitches: [EnvSwitch] {
        model.switches.filter { s in
            s.group == group && s.group.offered && !activeKeys.contains(s.name)
        }
    }

    private var items: [Item] {
        [.group]
            + store.activeSwitches.map { .active($0.key) }
            + knownSwitches.map { .known($0.name) }
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
                                    GamepadAdvancedRow(
                                item: item,
                                group: group,
                                known: known(for: item),
                                activeValue: activeValue(for: item),
                                selected: index == selectedIndex
                                    )
                                }
                                .buttonStyle(.plain)
                                if case .known = item {
                                    EmptyView()
                                } else {
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
                        }
                    }
                    .padding(22)
                }
                .onAppear { clampSelection() }
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
        .onChange(of: model.gamepad.sequence) { _, _ in
            handle(model.gamepad.lastAction)
        }
        .onChange(of: group) { _, _ in
            selectedIndex = 0
        }
        .onChange(of: store.rawText) { _, _ in
            clampSelection()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "switch.2")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ajustes avanzados")
                    .font(.headline)
                Text("Grupo: \(group.title) · \(selectedIndex + 1) de \(items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if group == .diagnostic || group == .test {
                Label("Puede llenar el log", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        VStack(spacing: 4) {
            HStack(spacing: 14) {
                Text("↑↓ seleccionar")
                Text("←→ cambiar grupo/valor")
                Text("Enter / clic: añadir o quitar")
            }
            Text("Activa Editor de texto para escribir valores libres.")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.vertical, 8)
    }

    private func handle(_ action: GamepadInput.Action) {
        guard !items.isEmpty else { return }
        switch action {
        case .up:
            selectedIndex = max(0, selectedIndex - 1)
        case .down:
            selectedIndex = min(items.count - 1, selectedIndex + 1)
        case .left:
            adjust(items[selectedIndex], by: -1)
        case .right:
            adjust(items[selectedIndex], by: 1)
        case .primary:
            activate(items[selectedIndex])
        case .back, .configure, .previousTab, .nextTab, .previousSection, .nextSection, .closeGame:
            break
        }
    }

    private func key(_ action: GamepadInput.Action) -> KeyPress.Result {
        handle(action)
        return .handled
    }

    private func activate(_ item: Item) {
        switch item {
        case .group:
            adjust(item, by: 1)
        case .active(let key):
            store.setSwitch(key, nil)
        case .known(let name):
            guard let sw = model.switches.first(where: { $0.name == name }) else { return }
            store.setSwitch(name, sw.suggestedValues.first ?? "1")
        }
    }

    private func adjust(_ item: Item, by delta: Int) {
        switch item {
        case .group:
            guard let index = groups.firstIndex(of: group), !groups.isEmpty else { return }
            group = groups[(index + delta + groups.count) % groups.count]
        case .active(let key):
            guard let sw = model.switches.first(where: { $0.name == key }), !sw.suggestedValues.isEmpty,
                  let current = activeValue(for: item) else { return }
            let values = sw.suggestedValues
            let currentIndex = values.firstIndex(of: current) ?? 0
            let next = values[(currentIndex + delta + values.count) % values.count]
            store.setSwitch(key, next)
        case .known:
            // Unactivated variables are added with A. ←→ only navigates the
            // group/value rows and deliberately does not mutate this row.
            break
        }
    }

    private func known(for item: Item) -> EnvSwitch? {
        let key: String
        switch item {
        case .group: return nil
        case .active(let value), .known(let value): key = value
        }
        return model.switches.first { $0.name == key }
    }

    private func activeValue(for item: Item) -> String? {
        guard case .active(let key) = item else { return nil }
        return store.activeSwitches.first { $0.key == key }?.value
    }

    private func clampSelection() {
        selectedIndex = min(selectedIndex, max(0, items.count - 1))
    }
}

private struct GamepadAdvancedRow: View {
    let item: GamepadAdvancedView.Item
    let group: EnvSwitch.Group
    let known: EnvSwitch?
    let activeValue: String?
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
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
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
    }

    private var title: String {
        switch item {
        case .group: return "Grupo de interruptores"
        case .active(let key), .known(let key): return key
        }
    }

    private var detail: String {
        switch item {
        case .group:
            return "←→ cambia el grupo que se muestra"
        case .active:
            return known?.meaning ?? "Variable activa no incluida en la tabla de nxnative."
        case .known:
            return known?.meaning ?? "Interruptor documentado."
        }
    }

    private var value: String {
        switch item {
        case .group: return group.title
        case .active:
            let text = activeValue ?? ""
            return text.isEmpty ? "(vacío)" : text
        case .known:
            return "No activo"
        }
    }

    private var icon: String {
        switch item {
        case .group: return "square.grid.2x2"
        case .active: return "checkmark.circle.fill"
        case .known: return "plus.circle"
        }
    }
}
