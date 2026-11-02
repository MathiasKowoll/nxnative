import GameController
import AppKit
import Foundation
import Observation
import NXCore
import NXRuntime

/// Entrada del mando para la biblioteca y su atajo de salida global. Cuando se
/// abre un juego, las acciones normales siguen perteneciendo al juego; solo
/// Select + Start o el click del panel táctil de DualSense se observan para
/// pedir el regreso a la selección.
@MainActor @Observable
final class GamepadInput {
    typealias Action = ConsoleAction

    struct Prompt {
        let text: String
        let symbol: String?
    }
    private(set) var family: ConsoleControllerFamily = .xbox
    private(set) var primaryPrompt = Prompt(text: "A", symbol: nil)
    private(set) var backPrompt = Prompt(text: "B", symbol: nil)
    private(set) var configurationPrompt = Prompt(text: "Y", symbol: nil)
    var dialogPresented = false

    private enum ComboButton: Equatable {
        case select, start, touchpad
    }

    private let preferences: Preferences
    private(set) var lastAction: Action = .back
    private(set) var sequence = 0
    private(set) var controllerName = ""

    private var observers: [NSObjectProtocol] = []
    private var attached = Set<ObjectIdentifier>()
    private var axisAction: Action?
    private var axisRepeatTask: Task<Void, Never>?
    private var comboController: ObjectIdentifier?
    private var selectPressed = false
    private var startPressed = false
    private var touchpadPressed = false
    private var exitHoldTask: Task<Void, Never>?
    private var exitTriggered = false

    init(preferences: Preferences) {
        self.preferences = preferences
        GCController.shouldMonitorBackgroundEvents = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshControllers() }
            },
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshControllers() }
            },
        ]
        refreshControllers()
    }

    var isConnected: Bool { !controllerName.isEmpty }

    private func refreshControllers() {
        let controllers = GCController.controllers()
        controllerName = controllers.first?.vendorName ?? (controllers.isEmpty ? "" : "Mando")
        if let controller = controllers.first { updatePrompts(controller) }
        for controller in controllers where attached.insert(ObjectIdentifier(controller)).inserted {
            attach(controller)
        }
        let connected = Set(controllers.map(ObjectIdentifier.init))
        if !attached.subtracting(connected).isEmpty {
            axisRepeatTask?.cancel()
            axisAction = nil
            exitHoldTask?.cancel()
            selectPressed = false
            startPressed = false
            touchpadPressed = false
            exitTriggered = false
        }
        attached = attached.intersection(connected)
        if controllers.isEmpty {
            axisAction = nil
            axisRepeatTask?.cancel()
        }
    }

    private func attach(_ controller: GCController) {
        if let pad = controller.extendedGamepad {
            let layout = ConsoleControllerFamily(category: controller.productCategory, vendor: controller.vendorName ?? "")
            bind(button: layout.confirmOnRight ? pad.buttonB : pad.buttonA, action: .primary, controller: controller)
            bind(button: layout.confirmOnRight ? pad.buttonA : pad.buttonB, action: .back, controller: controller)
            // GCExtendedGamepad names describe positions: Y is the top button,
            // including Triangle on Sony and X on Nintendo.
            bind(button: pad.buttonY, action: .configure, controller: controller)
            bind(button: pad.leftShoulder, action: .previousTab, controller: controller)
            bind(button: pad.rightShoulder, action: .nextTab, controller: controller)
            bind(comboButton: pad.buttonOptions, role: .select, controller: controller)
            bind(comboButton: pad.buttonMenu, role: .start, controller: controller)
            if let dualSense = pad as? GCDualSenseGamepad {
                bind(comboButton: dualSense.touchpadButton, role: .touchpad, controller: controller)
            }
            bind(direction: pad.dpad, controller: controller)
            pad.leftThumbstick.valueChangedHandler = { [weak self, weak controller] _, x, y in
                Task { @MainActor in
                    if let controller, abs(x) > 0.55 || abs(y) > 0.55 { self?.updatePrompts(controller) }
                    self?.axis(x: x, y: y)
                }
            }
        } else if let pad = controller.microGamepad {
            bind(button: pad.buttonA, action: .primary, controller: controller)
            bind(button: pad.buttonX, action: .configure, controller: controller)
            bind(direction: pad.dpad, controller: controller)
        }
    }

    private func updatePrompts(_ controller: GCController) {
        controllerName = controller.vendorName ?? "Mando"
        family = ConsoleControllerFamily(category: controller.productCategory, vendor: controllerName)
        let pad = controller.extendedGamepad
        primaryPrompt = Prompt(text: family.primary, symbol: (family.confirmOnRight ? pad?.buttonB : pad?.buttonA)?.sfSymbolsName)
        backPrompt = Prompt(text: family.back, symbol: (family.confirmOnRight ? pad?.buttonA : pad?.buttonB)?.sfSymbolsName)
        configurationPrompt = Prompt(text: family.configure, symbol: pad?.buttonY.sfSymbolsName ?? controller.microGamepad?.buttonX.sfSymbolsName)
    }

    private func bind(button: GCControllerButtonInput, action: Action, controller: GCController) {
        button.pressedChangedHandler = { [weak self, weak controller] _, _, pressed in
            guard pressed else { return }
            Task { @MainActor in
                if let controller { self?.updatePrompts(controller) }
                self?.emit(action)
            }
        }
    }

    private func bind(comboButton button: GCControllerButtonInput?, role: ComboButton, controller: GCController) {
        guard let button else { return }
        let id = ObjectIdentifier(controller)
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            Task { @MainActor in self?.comboButtonChanged(role, pressed: pressed, controller: id) }
        }
    }

    private func bind(direction: GCControllerDirectionPad, controller: GCController) {
        direction.valueChangedHandler = { [weak self, weak controller] _, x, y in
            Task { @MainActor in
                if let controller, abs(x) > 0.55 || abs(y) > 0.55 { self?.updatePrompts(controller) }
                self?.axis(x: x, y: y)
            }
        }
    }

    private func axis(x: Float, y: Float) {
        let threshold: Float = 0.55
        let next: Action?
        if abs(x) < threshold && abs(y) < threshold {
            next = nil
        } else if abs(x) >= abs(y) {
            next = x < 0 ? .left : .right
        } else {
            next = y < 0 ? .down : .up
        }
        guard next != axisAction else { return }
        axisRepeatTask?.cancel()
        axisAction = next
        guard let next else { return }
        emit(next)
        axisRepeatTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                while !Task.isCancelled {
                    guard let self, NSApp.isActive else { return }
                    self.emit(next)
                    try await Task.sleep(for: .milliseconds(120))
                }
            } catch { }
        }
    }

    private func emit(_ action: Action) {
        // El juego que acaba de abrirse conserva el mando para sí. No dejamos
        // que sus botones cambien la biblioteca que queda detrás.
        guard NSApp.isActive else { return }
        lastAction = action
        sequence &+= 1
    }

    private func comboButtonChanged(_ role: ComboButton, pressed: Bool, controller: ObjectIdentifier) {
        if comboController != controller {
            guard pressed else { return }
            exitHoldTask?.cancel()
            selectPressed = false
            startPressed = false
            touchpadPressed = false
            exitTriggered = false
            comboController = controller
        }
        switch role {
        case .select:
            selectPressed = pressed
        case .start:
            startPressed = pressed
        case .touchpad:
            touchpadPressed = pressed
        }
        updateExitHold()
    }

    private func updateExitHold() {
        exitHoldTask?.cancel()

        let selectStart = preferences.globalExitEnabled && preferences.globalExitSelectStart
            && selectPressed && startPressed
        let touchpad = preferences.globalExitEnabled && preferences.globalExitTouchpad && touchpadPressed
        guard selectStart || touchpad else {
            exitTriggered = false
            return
        }
        guard !exitTriggered else { return }

        let milliseconds = Int64(min(10, max(1, preferences.globalExitHoldSeconds)) * 1000)
        exitHoldTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(milliseconds))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            let stillHoldingSelectStart = self.preferences.globalExitEnabled
                && self.preferences.globalExitSelectStart
                && self.selectPressed && self.startPressed
            let stillHoldingTouchpad = self.preferences.globalExitEnabled
                && self.preferences.globalExitTouchpad && self.touchpadPressed
            guard stillHoldingSelectStart || stillHoldingTouchpad else { return }
            self.exitTriggered = true
            self.emitCloseGame()
        }
    }

    private func emitCloseGame() {
        // El cierre global debe detectarse incluso cuando el juego tiene el
        // foco. Las acciones normales siguen protegidas por NSApp.isActive.
        lastAction = .closeGame
        sequence &+= 1
    }
}
