import AppKit
import AVFoundation
import ServiceManagement
import UtterCore

/// Runs `body` on the main actor after the current event, preserving order.
func onMain(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private var config = Config()
    private var keys = APIKeys()
    private(set) var settingsWarnings: [String] = []

    private var machine = DictationMachine()
    private var detector = HotkeyDetector(hotkey: .modifier(.fn))
    private let recorder = AudioRecorder()
    private let tap = EventTap()
    private let pill = PillController()
    private var menu: MenuBarController!

    private let server = WhisperServer()
    let model = AppModel()
    private var window: MainWindowController!
    private var windowRefreshTimer: Timer?
    private(set) var lastRun: String?

    private var pipeline: Task<Void, Never>?
    private var pipelineID = 0
    private var permissionTimer: Timer?

    private var openWindowOnLaunch: Bool {
        get { UserDefaults.standard.object(forKey: "openWindowOnLaunch") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "openWindowOnLaunch") }
    }

    var isEnabled: Bool = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "enabled")
            if !isEnabled {
                detector.reset()
                send(.reset)
            }
            refreshIcon()
            refreshModel()
        }
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        writeTemplatesIfMissing()
        installMainMenu()
        menu = MenuBarController(app: self)
        window = MainWindowController(model: model, actions: self)
        window.onVisibilityChange = { [weak self] visible in self?.windowVisibilityChanged(visible) }
        server.onStateChange = { [weak self] in self?.refreshModel() }
        reloadSettings(announce: false)

        recorder.onLevel = { [weak self] rms in
            let level = AudioLevel.meter(rms: rms)
            onMain { self?.pill.setLevel(level) }
        }
        tap.handler = { [unowned self] event in self.handleKeyEvent(event) }

        Permission.microphone.request()
        tap.start()
        if !Permission.accessibility.isGranted { Permission.accessibility.request() }
        if !tap.isRunning { Permission.inputMonitoring.request() }
        if permissionsIncomplete { waitForPermissions() }
        refreshIcon()
        refreshModel()
        if openWindowOnLaunch || permissionsIncomplete { showWindow() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder.cancel()
        pipeline?.cancel()
        server.stop()
    }

    /// Opening Utter again (Finder, Spotlight, Launchpad, Dock) while it runs.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func showWindow() {
        refreshModel()
        window.show()
    }

    /// While the window is open, keep its permission list live: permissions are
    /// granted in System Settings, which tells us nothing.
    private func windowVisibilityChanged(_ visible: Bool) {
        windowRefreshTimer?.invalidate()
        windowRefreshTimer = nil
        guard visible else { return }
        windowRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshModel() }
        }
    }

    /// A normal app menu, so ⌘Q, ⌘W and ⌘V/⌘C work while the window is open.
    private func installMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Utter", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Utter", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Utter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    /// Without Accessibility the tap cannot start (or is listen-only) and Cmd-V
    /// cannot be sent.
    private var permissionsIncomplete: Bool {
        !tap.isRunning || tap.isListenOnly || !Permission.accessibility.isGranted
    }

    /// Permissions get granted in System Settings while we are running. Poll and
    /// pick them up, rather than asking for a relaunch.
    private func waitForPermissions() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                if self.tap.isListenOnly && Permission.accessibility.isGranted {
                    // Upgrade to an active tap so chord keys can be swallowed.
                    self.tap.stop()
                }
                self.tap.start()
                guard !self.permissionsIncomplete else { return }
                timer.invalidate()
                self.permissionTimer = nil
                self.refreshIcon()
                self.refreshModel()
                self.pill.flash("Ready · hold \(self.detector.hotkey.displayName) to dictate")
            }
        }
    }

    // MARK: Settings

    private func writeTemplatesIfMissing() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.modelsDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Paths.configFile.path) {
            try? Config.template.write(to: Paths.configFile, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: Paths.envFile.path) {
            fm.createFile(atPath: Paths.envFile.path, contents: Data((APIKeys.template + "\n").utf8),
                          attributes: [.posixPermissions: 0o600])
        }
    }

    func reloadSettings(announce: Bool) {
        var warnings: [String] = []

        let text = (try? String(contentsOf: Paths.configFile, encoding: .utf8)) ?? ""
        let parsed = ConfigParser.parse(text)
        config = parsed.config
        warnings += parsed.warnings

        let envText = (try? String(contentsOf: Paths.envFile, encoding: .utf8)) ?? ""
        keys = APIKeys(dotEnv: DotEnv.parse(envText), processEnvironment: ProcessInfo.processInfo.environment)

        do {
            detector.hotkey = try Hotkey.parse(config.hotkey)
        } catch {
            warnings.append("hotkey: \(error) · using fn")
            detector.hotkey = .modifier(.fn)
        }
        if case .failure(let e) = Backends.transcriber(for: config, keys: keys) { warnings.append(e.description) }
        if case .failure(let e) = Backends.cleanup(for: config, keys: keys) { warnings.append(e.description) }
        if case .chord = detector.hotkey, tap.isListenOnly {
            warnings.append("grant Accessibility so the hotkey's key is not also typed")
        }

        send(.reset)
        machine.timing = config.timing
        pill.isEnabled = config.showPill
        pill.configure(hotkeyName: detector.hotkey.displayName, maxDuration: config.timing.maxDuration)
        settingsWarnings = warnings
        for w in warnings { log.warning("settings: \(w, privacy: .public)") }
        updateServer()
        refreshModel()

        if announce {
            if warnings.isEmpty {
                pill.flash("Settings reloaded")
            } else {
                pill.flash("Settings: \(warnings.count) problem\(warnings.count == 1 ? "" : "s") · see menu", isError: true, seconds: 3)
            }
        }
        refreshIcon()
    }

    // MARK: Local model server

    private var usesLocalServer: Bool {
        guard config.localEngine == .server else { return false }
        if case .success(.local) = Backends.transcriber(for: config, keys: keys) { return true }
        return false
    }

    /// Starts, restarts or stops whisper-server to match the settings.
    private func updateServer() {
        guard usesLocalServer else {
            server.stop()
            return
        }
        if let spec = WhisperServerAPI.spec(for: config) {
            server.ensureRunning(spec)
        } else {
            server.stop()
        }
    }

    var engineStatus: String {
        guard case .success(.local) = Backends.transcriber(for: config, keys: keys) else {
            return "not used (cloud transcription)"
        }
        let modelURL = LocalWhisper.modelURL(for: config.localModel)
        if !FileManager.default.fileExists(atPath: modelURL.path) {
            return "\(config.localModel) not downloaded · run make model MODEL=\(config.localModel)"
        }
        if config.localEngine == .cli {
            return LocalWhisper.findExecutable(configured: config.whisperCLI) == nil
                ? "whisper-cli not found · brew install whisper-cpp"
                : "\(config.localModel) · loads per dictation"
        }
        if WhisperServerAPI.findExecutable(configuredCLI: config.whisperCLI) == nil {
            return "whisper-server not found · brew install whisper-cpp"
        }
        return "\(config.localModel) · \(server.summary)"
    }

    /// Pushes current state into the window's model.
    private func refreshModel() {
        model.status = statusLine
        model.isEnabled = isEnabled
        model.config = config
        model.warnings = settingsWarnings
        var permissions: [Permission: Bool] = [:]
        for p in Permission.allCases { permissions[p] = p.isGranted }
        model.permissions = permissions
        model.keysSaved = [
            "GROQ_API_KEY": keys.groq != nil,
            "OPENAI_API_KEY": keys.openai != nil,
            "ANTHROPIC_API_KEY": keys.anthropic != nil,
        ]
        model.installedModels = LocalWhisper.installedModels()
        model.engineStatus = engineStatus
        model.lastRun = lastRun
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
        model.openWindowOnLaunch = openWindowOnLaunch
    }

    // MARK: Menu state

    var statusLine: String {
        if !tap.isRunning { return "Waiting for Accessibility permission" }
        if !Permission.accessibility.isGranted { return "Needs Accessibility permission to paste" }
        if !isEnabled { return "Off" }
        switch machine.state {
        case .idle:
            return "Ready · hold \(detector.hotkey.displayName) or double-tap for hands-free"
        case .processing:
            return "Transcribing…"
        default:
            return "Recording…"
        }
    }

    var transcriptionSummary: String {
        switch Backends.transcriber(for: config, keys: keys) {
        case .success(.local): return "local · \(config.localModel)"
        case .success(.groq): return "Groq · \(config.groqTranscribeModel)"
        case .success(.openai): return "OpenAI · \(config.openaiTranscribeModel)"
        case .failure: return "not configured"
        }
    }

    var cleanupSummary: String {
        switch Backends.cleanup(for: config, keys: keys) {
        case .success(let backend): return backend.summary
        case .failure: return "not configured"
        }
    }

    private func refreshIcon() {
        guard let menu else { return }
        if !tap.isRunning || !Permission.accessibility.isGranted { menu.setIcon(.needsSetup) }
        else if !isEnabled { menu.setIcon(.disabled) }
        else if machine.state.isRecording { menu.setIcon(.recording) }
        else if machine.state == .processing { menu.setIcon(.working) }
        else { menu.setIcon(.idle) }
    }

    // MARK: Input

    /// Called synchronously from the event tap. Must be quick: it only decides
    /// whether to swallow the event and queues the real work.
    private func handleKeyEvent(_ event: RawKeyEvent) -> Bool {
        guard isEnabled else { return false }
        let output = detector.handle(event)
        if let signal = output.signal {
            let now = ProcessInfo.processInfo.systemUptime
            onMain { [weak self] in self?.handleSignal(signal, at: now) }
        }
        return output.swallow
    }

    private func handleSignal(_ signal: HotkeySignal, at time: TimeInterval) {
        switch signal {
        case .pressed: send(.hotkeyPressed(at: time))
        case .released: send(.hotkeyReleased(at: time))
        case .interrupted: send(.interrupted)
        case .escape:
            let wasRecording = machine.state.isRecording
            send(.escape)
            if wasRecording { pill.flash("Cancelled") }
        }
    }

    private func send(_ event: DictationEvent) {
        let before = machine.state
        let effects = machine.handle(event)
        for effect in effects { perform(effect) }
        if machine.state != before { stateChanged(from: before) }
    }

    private func perform(_ effect: DictationEffect) {
        switch effect {
        case .startRecording:
            startRecording()

        case .finishRecording(let mode, let autoStopped):
            let recording = recorder.stop()
            if config.sounds { NSSound(named: "Pop")?.play() }
            log.info("recorded \(recording.duration, format: .fixed(precision: 1))s (\(mode == .hold ? "hold" : "hands-free", privacy: .public))")
            process(recording, autoStopped: autoStopped)

        case .discardRecording:
            recorder.cancel()

        case .cancelProcessing:
            pipeline?.cancel()
            pipeline = nil
            pipelineID += 1
            pill.flash("Cancelled")

        case .schedule(let kind, let delay, let token):
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.send(.timerFired(kind, token: token)) }
            }
        }
    }

    private func stateChanged(from old: DictationState) {
        refreshIcon()
        switch machine.state {
        case .pressed(let since):
            pill.show(.recording(mode: nil, since: date(fromUptime: since)))
        case .holding(let since):
            pill.show(.recording(mode: .hold, since: date(fromUptime: since)))
        case .awaitingSecondTap:
            break
        case .handsFree(let since, _):
            pill.show(.recording(mode: .handsFree, since: date(fromUptime: since)))
        case .processing:
            break
        case .idle:
            // Coming from processing, pipelineFinished or the cancel already set the pill.
            if old.isRecording { pill.show(.hidden) }
        }
    }

    private func date(fromUptime uptime: TimeInterval) -> Date {
        Date(timeIntervalSinceNow: uptime - ProcessInfo.processInfo.systemUptime)
    }

    private func startRecording() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            Permission.microphone.request()
            fail("Microphone access needed · see menu")
            return
        }
        do {
            try recorder.start()
            if config.sounds { NSSound(named: "Tink")?.play() }
        } catch {
            fail("Mic error: \(error.localizedDescription)")
        }
    }

    private func fail(_ message: String) {
        log.error("\(message, privacy: .public)")
        send(.reset)
        pill.flash(message, isError: true, seconds: 3)
    }

    // MARK: Processing

    private func process(_ recording: Recording, autoStopped: Bool) {
        pipelineID += 1
        let id = pipelineID
        pill.show(.working(autoStopped ? "Time limit reached · transcribing" : "Transcribing"))

        let job = Pipeline(config: config, keys: keys, server: config.localEngine == .server ? server : nil) { stage in
            onMain { [weak self] in
                guard let self, self.pipelineID == id else { return }
                self.pill.show(.working(stage))
            }
        }
        let insertMethod = config.insertMethod
        let restoreClipboard = config.restoreClipboard

        self.pipeline = Task { [weak self] in
            let outcome: Result<PipelineOutcome, Error>
            do {
                outcome = .success(try await job.run(recording))
            } catch {
                outcome = .failure(error)
            }
            guard let self, self.pipelineID == id else { return }
            self.pipeline = nil
            self.pipelineFinished(outcome, insertMethod: insertMethod, restoreClipboard: restoreClipboard)
        }
    }

    private func pipelineFinished(_ outcome: Result<PipelineOutcome, Error>, insertMethod: InsertMethod, restoreClipboard: Bool) {
        switch outcome {
        case .success(.text(let text, let note, let timings)):
            Inserter.insert(text, method: insertMethod, restoreClipboard: restoreClipboard)
            lastRun = timings.summary
            log.info("dictation: \(timings.summary, privacy: .public)")
            if let note { pill.flash(note, isError: true, seconds: 2.5) } else { pill.show(.hidden) }
        case .success(.noSpeech):
            pill.flash("No speech detected")
        case .failure(let error):
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                pill.show(.hidden)
            } else {
                log.error("pipeline failed: \(error.localizedDescription, privacy: .public)")
                pill.flash(error.localizedDescription, isError: true, seconds: 4)
            }
        }
        send(.processingFinished)
        refreshModel()
    }
}

// MARK: - Window actions

extension AppController: AppActions {
    func setEnabled(_ on: Bool) {
        isEnabled = on
    }

    func setSetting(_ key: String, _ value: ConfigValue) {
        let text = (try? String(contentsOf: Paths.configFile, encoding: .utf8)) ?? Config.template
        let updated = ConfigEditor.set(key, to: value, in: text)
        do {
            try updated.write(to: Paths.configFile, atomically: true, encoding: .utf8)
        } catch {
            pill.flash("Could not save settings: \(error.localizedDescription)", isError: true, seconds: 3)
            return
        }
        reloadSettings(announce: false)
    }

    func setAPIKey(_ name: String, _ value: String?) {
        let text = (try? String(contentsOf: Paths.envFile, encoding: .utf8)) ?? APIKeys.template
        let updated = DotEnv.set(name, to: value, in: text)
        do {
            // Written whole and then locked back down: an atomic write makes a new
            // file, which would otherwise be readable by other users.
            try updated.write(to: Paths.envFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.envFile.path)
        } catch {
            pill.flash("Could not save key: \(error.localizedDescription)", isError: true, seconds: 3)
            return
        }
        reloadSettings(announce: false)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nMove Utter.app to /Applications (make install) and try again."
            alert.runModal()
        }
        refreshModel()
    }

    func setOpenWindowOnLaunch(_ on: Bool) {
        openWindowOnLaunch = on
        refreshModel()
    }

    func openPermission(_ permission: Permission) {
        permission.request()
        permission.openSettings()
    }

    func openSettingsFile() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-t", Paths.configFile.path]
        try? process.run()
    }

    func openModelsFolder() {
        NSWorkspace.shared.open(Paths.modelsDir)
    }

    func quit() {
        NSApp.terminate(nil)
    }
}
