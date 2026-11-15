import AppKit

@main
enum UtterApp {
    static func main() {
        // main() runs on the main thread; say so to the compiler.
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let controller = AppController()
            app.delegate = controller
            // Menu bar only: no Dock icon or app-switcher entry. LSUIElement in
            // Info.plist does the same for the bundle; this covers the bare binary.
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(controller) {
                app.run()
            }
        }
    }
}
