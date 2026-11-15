import AppKit
import SwiftUI
import UtterCore

/// What the window shows. AppController owns it and keeps it current.
@MainActor
final class AppModel: ObservableObject {
    @Published var status = ""
    @Published var isEnabled = true
    @Published var config = Config()
    @Published var warnings: [String] = []
    @Published var permissions: [Permission: Bool] = [:]
    @Published var keysSaved: [String: Bool] = [:]
    @Published var installedModels: [String] = []
    @Published var engineStatus = ""
    @Published var lastRun: String?
    @Published var launchAtLogin = false
    @Published var openWindowOnLaunch = true
}

/// The window's buttons and toggles call back into the controller through this.
@MainActor
protocol AppActions: AnyObject {
    func setEnabled(_ on: Bool)
    func setSetting(_ key: String, _ value: ConfigValue)
    func setAPIKey(_ name: String, _ value: String?)
    func setLaunchAtLogin(_ on: Bool)
    func setOpenWindowOnLaunch(_ on: Bool)
    func openPermission(_ permission: Permission)
    func openSettingsFile()
    func openModelsFolder()
    func quit()
}

/// Shows the window with a Dock icon while it is open; closing it goes back to
/// living in the menu bar only. Quit is the only way to stop Utter.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: AppModel
    private unowned let actions: AppActions
    var onVisibilityChange: (@MainActor (Bool) -> Void)?

    var isVisible: Bool { window?.isVisible ?? false }

    init(model: AppModel, actions: AppActions) {
        self.model = model
        self.actions = actions
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Utter"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 480, height: 480)
            window.contentView = NSHostingView(rootView: MainView(model: model, actions: actions))
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("UtterMainWindow")
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        onVisibilityChange?(true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        onVisibilityChange?(false)
    }
}

// MARK: - Views

private struct MainView: View {
    @ObservedObject var model: AppModel
    let actions: AppActions

    var body: some View {
        Form {
            header
            if !missingPermissions.isEmpty { permissionsSection }
            if !model.warnings.isEmpty { warningsSection }
            hotkeySection
            transcriptionSection
            cleanupSection
            keysSection
            insertionSection
            appSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 480)
    }

    private var missingPermissions: [Permission] {
        Permission.allCases.filter { model.permissions[$0] != true }
    }

    // MARK: Header

    private var header: some View {
        Section {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: model.isEnabled ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(model.isEnabled ? .accentColor : .secondary)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.accentColor.opacity(model.isEnabled ? 0.15 : 0.06)))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Utter").font(.title2.weight(.semibold))
                    Text(model.status).font(.callout).foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { model.isEnabled }, set: { actions.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Turn dictation on or off")
            }
            .padding(.vertical, 4)
            if let lastRun = model.lastRun {
                LabeledContent("Last dictation") {
                    Text(lastRun).foregroundColor(.secondary).monospacedDigit()
                }
            }
        }
    }

    private var permissionsSection: some View {
        Section {
            ForEach(Permission.allCases, id: \.self) { permission in
                HStack {
                    Image(systemName: model.permissions[permission] == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(model.permissions[permission] == true ? .green : .red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(permission.title)
                        Text("Needed to \(permission.purpose)").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    if model.permissions[permission] != true {
                        Button("Open Settings") { actions.openPermission(permission) }
                    }
                }
            }
        } header: {
            Text("Permissions needed")
        } footer: {
            Text("Click Open Settings, then switch Utter on in the list (use + to add it from /Applications if it is missing). This window updates on its own.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var warningsSection: some View {
        Section("Problems in your settings") {
            ForEach(model.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.callout)
            }
        }
    }

    // MARK: Hotkey

    private static let hotkeyPresets: [(String, String)] = [
        ("fn", "fn / 🌐"),
        ("right_option", "Right ⌥ Option"),
        ("right_command", "Right ⌘ Command"),
        ("right_control", "Right ⌃ Control"),
        ("ctrl+option+space", "⌃⌥ Space"),
    ]

    private var hotkeySection: some View {
        Section {
            Picker("Hotkey", selection: Binding(
                get: { Self.hotkeyPresets.contains { $0.0 == model.config.hotkey } ? model.config.hotkey : "custom" },
                set: { if $0 != "custom" { actions.setSetting("hotkey", .string($0)) } }
            )) {
                ForEach(Self.hotkeyPresets, id: \.0) { Text($0.1).tag($0.0) }
                Text("Custom…").tag("custom")
            }
            if !Self.hotkeyPresets.contains(where: { $0.0 == model.config.hotkey }) {
                CommitField(title: "Custom hotkey", placeholder: "e.g. cmd+shift+d or f5",
                            value: model.config.hotkey) { actions.setSetting("hotkey", .string($0)) }
            }
            Stepper(value: Binding(
                get: { model.config.maxRecordingSeconds / 60 },
                set: { actions.setSetting("max_recording_seconds", .int(max(1, $0) * 60)) }
            ), in: 1...60) {
                LabeledContent("Hands-free stops after") {
                    Text("\(max(1, model.config.maxRecordingSeconds / 60)) min")
                }
            }
        } header: {
            Text("Hotkey")
        } footer: {
            Text("Hold to talk and release to insert. Double-tap for hands-free, tap again to finish. Esc cancels.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: Transcription

    private var transcriptionSection: some View {
        Section {
            Picker("Transcribe with", selection: Binding(
                get: { model.config.transcriber.rawValue },
                set: { actions.setSetting("transcriber", .string($0)) }
            )) {
                Text("This Mac (whisper.cpp, offline)").tag("local")
                Text("Groq (fastest, needs key)").tag("groq")
                Text("OpenAI (needs key)").tag("openai")
                Text("Auto: Groq, then OpenAI, then this Mac").tag("auto")
            }

            Picker("Local model", selection: Binding(
                get: { model.config.localModel },
                set: { actions.setSetting("local_model", .string($0)) }
            )) {
                ForEach(modelChoices, id: \.self) { name in
                    Text(model.installedModels.contains(name) ? name : "\(name) (not downloaded)").tag(name)
                }
            }

            Toggle("Keep the model loaded (much faster)", isOn: Binding(
                get: { model.config.localEngine == .server },
                set: { actions.setSetting("local_engine", .string($0 ? "server" : "cli")) }
            ))

            Picker("Accuracy", selection: Binding(
                get: { model.config.beamSize > 1 ? 5 : 1 },
                set: { actions.setSetting("beam_size", .int($0)) }
            )) {
                Text("Fast").tag(1)
                Text("Thorough (slower)").tag(5)
            }
            .pickerStyle(.segmented)

            LabeledContent("Local engine") {
                Text(model.engineStatus).foregroundColor(.secondary)
            }

            CommitField(title: "Vocabulary", placeholder: "Names and jargon, comma separated",
                        value: model.config.vocabulary) { actions.setSetting("vocabulary", .string($0)) }
        } header: {
            Text("Transcription")
        } footer: {
            HStack(spacing: 4) {
                Text("Get more models with `make model MODEL=medium.en` in Terminal.")
                Button("Show models folder") { actions.openModelsFolder() }
                    .buttonStyle(.link)
            }
            .font(.caption).foregroundColor(.secondary)
        }
    }

    private var modelChoices: [String] {
        var names = model.installedModels
        if !names.contains(model.config.localModel) { names.append(model.config.localModel) }
        return names
    }

    // MARK: Cleanup

    private var cleanupSection: some View {
        Section {
            Picker("Clean up with", selection: Binding(
                get: { model.config.cleanup.rawValue },
                set: { actions.setSetting("cleanup", .string($0)) }
            )) {
                Text("Auto (first key found)").tag("auto")
                Text("Groq").tag("groq")
                Text("OpenAI").tag("openai")
                Text("Anthropic").tag("anthropic")
                Text("Ollama (local, offline)").tag("ollama")
                Text("Off: insert the raw transcript").tag("off")
            }
        } header: {
            Text("Cleanup")
        } footer: {
            Text("Removes filler words and fixes punctuation and casing. If it fails or times out, the raw transcript is inserted.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var keysSection: some View {
        Section {
            KeyRow(name: "Groq", envName: "GROQ_API_KEY", saved: model.keysSaved["GROQ_API_KEY"] == true, actions: actions)
            KeyRow(name: "OpenAI", envName: "OPENAI_API_KEY", saved: model.keysSaved["OPENAI_API_KEY"] == true, actions: actions)
            KeyRow(name: "Anthropic", envName: "ANTHROPIC_API_KEY", saved: model.keysSaved["ANTHROPIC_API_KEY"] == true, actions: actions)
        } header: {
            Text("API keys")
        } footer: {
            Text("Stored in ~/.config/utter/.env on this Mac and sent only to the provider each belongs to.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: Insertion and app

    private var insertionSection: some View {
        Section("Inserting text") {
            Picker("Insert by", selection: Binding(
                get: { model.config.insertMethod.rawValue },
                set: { actions.setSetting("insert_method", .string($0)) }
            )) {
                Text("Pasting (fast)").tag("paste")
                Text("Typing (for apps that block paste)").tag("type")
            }
            Toggle("Put my previous clipboard back after inserting", isOn: Binding(
                get: { model.config.restoreClipboard },
                set: { actions.setSetting("restore_clipboard", .bool($0)) }
            ))
            Toggle("Show the floating pill while recording", isOn: Binding(
                get: { model.config.showPill },
                set: { actions.setSetting("show_pill", .bool($0)) }
            ))
            Toggle("Play sounds", isOn: Binding(
                get: { model.config.sounds },
                set: { actions.setSetting("sounds", .bool($0)) }
            ))
        }
    }

    private var appSection: some View {
        Section {
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { actions.setLaunchAtLogin($0) }))
            Toggle("Open this window when Utter starts", isOn: Binding(
                get: { model.openWindowOnLaunch }, set: { actions.setOpenWindowOnLaunch($0) }
            ))
            HStack {
                Button("Open Settings File") { actions.openSettingsFile() }
                Spacer()
                Button("Quit Utter") { actions.quit() }
            }
        } header: {
            Text("App")
        } footer: {
            Text("Closing this window keeps Utter running in the menu bar. Reopen it from the menu bar icon or by opening Utter again.")
                .font(.caption).foregroundColor(.secondary)
        }
    }
}

/// A text field that saves when you press Return or leave it, not on every keystroke.
private struct CommitField: View {
    let title: String
    let placeholder: String
    let value: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: Text(placeholder))
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { text = $0 }
            .onSubmit { save() }
            .onChange(of: focused) { if !$0 { save() } }
    }

    private func save() {
        if text != value { commit(text) }
    }
}

private struct KeyRow: View {
    let name: String
    let envName: String
    let saved: Bool
    let actions: AppActions
    @State private var draft = ""

    var body: some View {
        HStack {
            Text(name).frame(width: 80, alignment: .leading)
            if saved {
                Label("Saved", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                Spacer()
                Button("Remove") { actions.setAPIKey(envName, nil) }
            } else {
                SecureField("Paste key", text: $draft)
                    .onSubmit(save)
                Button("Save", action: save).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        actions.setAPIKey(envName, key)
        draft = ""
    }
}
