import AppKit
import SwiftUI

@main
struct NXNativeMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("NXNative") {
            RootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
                .task { await model.refresh() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Volver a escanear") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            EnvironmentView(compact: true)
                .environment(model)
                .frame(width: 640, height: 560)
        }
    }
}

/// Un ejecutable de SwiftPM lanzado desde la terminal no es una app «normal»
/// hasta que se lo dice: sin esto no sale en el Dock ni recibe el teclado.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
