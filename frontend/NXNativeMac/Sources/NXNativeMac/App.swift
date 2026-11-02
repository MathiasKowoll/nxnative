import AppKit
import SwiftUI

@main
struct NXNativeMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()
    @FocusedValue(\.consoleConfigurationAction) private var configure

    var body: some Scene {
        WindowGroup("NXNative") {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
                .task { delegate.model = model; await model.refresh() }
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Configuración…") { configure?() }
                    .keyboardShortcut(",")
                    .disabled(configure == nil)
            }
            CommandGroup(after: .newItem) {
                Button("Volver a escanear") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }
        }

    }
}

private struct ConsoleConfigurationActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var consoleConfigurationAction: (() -> Void)? {
        get { self[ConsoleConfigurationActionKey.self] }
        set { self[ConsoleConfigurationActionKey.self] = newValue }
    }
}

/// Un ejecutable de SwiftPM lanzado desde la terminal no es una app «normal»
/// hasta que se lo dice: sin esto no sale en el Dock ni recibe el teclado.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        (model?.builds.pendingCount ?? 0) == 0
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.builds.pendingCount > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Hay trabajos en el Taller"
        alert.informativeText = "Puedes cerrar la ventana y dejar que continúen. Para salir de NXNative hay que cancelar los trabajos activos y en cola."
        alert.addButton(withTitle: "Continuar trabajando")
        alert.addButton(withTitle: "Cancelar trabajos y salir")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        model.builds.cancelAll()
        Task { @MainActor in
            while model.builds.pendingCount > 0 { try? await Task.sleep(for: .milliseconds(200)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
