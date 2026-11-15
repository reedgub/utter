import AppKit
import ServiceManagement
import UtterCore

enum MenuIcon {
    case idle, disabled, recording, working, needsSetup

    var symbolName: String {
        switch self {
        case .idle: return "mic"
        case .disabled: return "mic.slash"
        case .recording: return "waveform"
        case .working: return "ellipsis.circle"
        case .needsSetup: return "exclamationmark.triangle"
        }
    }
}

/// The menu bar icon and its menu. The menu is rebuilt each time it opens, so
/// it always reflects current permissions, settings and launch-at-login state.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private unowned let app: AppController

    init(app: AppController) {
        self.app = app
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        setIcon(.idle)
    }

    func setIcon(_ icon: MenuIcon) {
        let image = NSImage(systemSymbolName: icon.symbolName, accessibilityDescription: "Utter")
        image?.isTemplate = true
        item.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let open = action("Open Utter…", #selector(openWindow))
        open.keyEquivalent = ","
        menu.addItem(open)
        menu.addItem(.separator())

        menu.addItem(disabled(app.statusLine))
        if let lastRun = app.lastRun { menu.addItem(disabled("Last: \(lastRun)")) }
        for warning in app.settingsWarnings.prefix(4) {
            menu.addItem(disabled("⚠︎ " + warning))
        }
        menu.addItem(.separator())

        let enabled = action("Enabled", #selector(toggleEnabled))
        enabled.state = app.isEnabled ? .on : .off
        menu.addItem(enabled)
        menu.addItem(.separator())

        menu.addItem(disabled("Transcription: \(app.transcriptionSummary)"))
        menu.addItem(disabled("Local engine: \(app.engineStatus)"))
        menu.addItem(disabled("Cleanup: \(app.cleanupSummary)"))
        menu.addItem(.separator())

        let permissions = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for permission in Permission.allCases {
            let granted = permission.isGranted
            let row = action("\(granted ? "✓" : "✗")  \(permission.title) — \(permission.purpose)", #selector(openPermission(_:)))
            row.representedObject = permission.title
            submenu.addItem(row)
        }
        permissions.submenu = submenu
        if Permission.allCases.contains(where: { !$0.isGranted }) { permissions.title = "Permissions (action needed)" }
        menu.addItem(permissions)

        let login = action("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        menu.addItem(action("Open Settings File", #selector(openSettings)))
        menu.addItem(action("Open .env File", #selector(openEnv)))
        menu.addItem(action("Open Models Folder", #selector(openModels)))
        menu.addItem(action("Reload Settings", #selector(reloadSettings)))
        menu.addItem(.separator())

        let quit = action("Quit Utter", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleEnabled() { app.isEnabled.toggle() }
    @objc private func openWindow() { app.showWindow() }

    @objc private func openPermission(_ sender: NSMenuItem) {
        guard let title = sender.representedObject as? String,
              let permission = Permission.allCases.first(where: { $0.title == title }) else { return }
        permission.request()
        permission.openSettings()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nMove Utter.app to /Applications and try again."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func openSettings() { openInTextEditor(Paths.configFile) }
    @objc private func openEnv() { openInTextEditor(Paths.envFile) }
    @objc private func openModels() { NSWorkspace.shared.open(Paths.modelsDir) }
    @objc private func reloadSettings() { app.reloadSettings(announce: true) }
    @objc private func quit() { NSApp.terminate(nil) }

    /// `open -t` uses the default text editor; .toml and dotfiles have no useful
    /// default app otherwise.
    private func openInTextEditor(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-t", url.path]
        try? process.run()
    }
}
