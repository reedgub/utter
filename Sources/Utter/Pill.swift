import AppKit
import SwiftUI
import UtterCore

enum PillState: Equatable {
    case hidden
    /// `mode == nil` while it is not yet known whether this is a hold or a double-tap.
    case recording(mode: RecordingMode?, since: Date)
    case working(String)
    case message(String, isError: Bool)
}

@MainActor
final class PillModel: ObservableObject {
    @Published var state: PillState = .hidden
    @Published var level: Float = 0
    var hotkeyName = "fn"
    var maxDuration: TimeInterval = 300
}

/// The small floating capsule at the bottom of the screen. It never takes focus
/// or mouse clicks, follows you across Spaces and shows over full-screen apps.
@MainActor
final class PillController {
    private let model = PillModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?
    var isEnabled = true

    private static let size = NSSize(width: 420, height: 64)

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = NSHostingView(rootView: PillView(model: model))
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
    }

    func configure(hotkeyName: String, maxDuration: TimeInterval) {
        model.hotkeyName = hotkeyName
        model.maxDuration = maxDuration
    }

    func setLevel(_ level: Float) {
        model.level = level
    }

    func show(_ state: PillState) {
        hideWork?.cancel()
        hideWork = nil
        model.state = state
        if state == .hidden || !isEnabled {
            panel.orderOut(nil)
            return
        }
        if !panel.isVisible { position() }
        panel.orderFrontRegardless()
    }

    /// Shows a message and hides it after a moment unless something replaced it.
    func flash(_ text: String, isError: Bool = false, seconds: TimeInterval = 1.8) {
        show(.message(text, isError: isError))
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, case .message = self.model.state else { return }
                self.show(.hidden)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + 18)
        panel.setFrameOrigin(origin)
    }
}

private struct PillView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        ZStack {
            if model.state != .hidden {
                content
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(Capsule().fill(Color.black.opacity(0.85)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.12), value: model.state)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .hidden:
            EmptyView()

        case .recording(let mode, let since):
            HStack(spacing: 8) {
                Circle()
                    .fill(mode == .handsFree ? Color.orange : Color.red)
                    .frame(width: 8, height: 8)
                Text(label(for: mode))
                LevelMeter(level: model.level)
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(timeText(now: context.date, since: since, mode: mode))
                        .monospacedDigit()
                        .foregroundColor(.white.opacity(0.65))
                }
            }

        case .working(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                Text(text)
                Text("esc to cancel").foregroundColor(.white.opacity(0.45))
            }

        case .message(let text, let isError):
            HStack(spacing: 6) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundColor(isError ? .yellow : .white.opacity(0.7))
                Text(text).lineLimit(1)
            }
        }
    }

    private func label(for mode: RecordingMode?) -> String {
        switch mode {
        case .handsFree: return "Hands-free · tap \(model.hotkeyName) to finish"
        case .hold: return "Listening · release to insert"
        case nil: return "Listening"
        }
    }

    private func timeText(now: Date, since: Date, mode: RecordingMode?) -> String {
        let elapsed = max(0, now.timeIntervalSince(since))
        func clock(_ t: TimeInterval) -> String {
            let s = Int(t)
            return String(format: "%d:%02d", s / 60, s % 60)
        }
        if mode == .handsFree { return "\(clock(elapsed)) / \(clock(model.maxDuration))" }
        return clock(elapsed)
    }
}

private struct LevelMeter: View {
    let level: Float
    private let weights: [Float] = [0.55, 0.85, 1.0, 0.75, 0.5]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 3, height: CGFloat(3 + 11 * min(1, level * weights[i])))
            }
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
