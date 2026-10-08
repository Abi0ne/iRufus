import AppKit
import IrufusCore
import SwiftUI

@main
struct IRufusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("iRufus", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 580, idealWidth: 620, minHeight: 680, idealHeight: 820)
                .onAppear { delegate.model = model }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            AppCommands(model: model)
        }

        Window(String(localized: "Log"), id: "log") {
            LogView()
                .environment(model)
                .frame(minWidth: 560, minHeight: 360)
        }
        .keyboardShortcut("l", modifiers: [.command])

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Refresh Devices") { model.refreshDevices() }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.isBusy)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isBusy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "An operation is in progress")
        alert.informativeText = String(localized: "Quitting now would leave the device in an unusable state. Cancel the operation first.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Keep Working"))
        alert.runModal()
        return .terminateCancel
    }
}
