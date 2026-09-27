import AppKit
import PalukuCore
import SwiftUI

/// Floating, non-activating panels: the top "notch" (pill + agent conversation) and the pointing-trail layer.
@MainActor
final class OverlayController {
    let panel: NSPanel
    let trailWindow: NSWindow
    private var contentSize = CGSize(width: 10, height: 10)

    init() {
        panel = Self.makePanel()
        trailWindow = NSWindow(contentRect: NSScreen.main?.frame ?? .zero, styleMask: .borderless, backing: .buffered, defer: false)
        trailWindow.isOpaque = false
        trailWindow.backgroundColor = .clear
        trailWindow.ignoresMouseEvents = true
        trailWindow.level = .screenSaver
        trailWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        trailWindow.contentView = NSHostingView(rootView: TrailView())

        let host = NSHostingView(rootView: OverlayView { [weak self] size in self?.resize(size) })
        host.translatesAutoresizingMaskIntoConstraints = true
        panel.contentView = host
        observe()
    }

    static func makePanel() -> NSPanel {
        let p = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 80),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isMovableByWindowBackground = false
        return p
    }

    private var shouldShow: Bool {
        let c = Coordinator.shared
        if c.panelVisible || c.toast != nil { return true }
        if case .recording = c.phase { return true }
        if case .transcribing = c.phase { return true }
        return false
    }

    private func observe() {
        withObservationTracking {
            _ = shouldShow
            let c = Coordinator.shared
            _ = c.trail.count
        } onChange: {
            Task { @MainActor [weak self] in
                self?.update()
                self?.observe()
            }
        }
        update()
    }

    private func update() {
        if shouldShow {
            position()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
        let trail = Coordinator.shared.trail
        if trail.count > 1 {
            if let screen = NSScreen.screens.first { trailWindow.setFrame(screen.frame, display: false) }
            trailWindow.orderFrontRegardless()
        } else {
            trailWindow.orderOut(nil)
        }
    }

    private func resize(_ size: CGSize) {
        guard size != contentSize, size.width > 0, size.height > 0 else { return }
        contentSize = size
        position()
    }

    /// Top-center of the screen with the mouse, just below the menu bar / notch.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let w = contentSize.width, h = min(contentSize.height, visible.height - 20)
        let frame = NSRect(x: screen.frame.midX - w / 2, y: visible.maxY - h - 6, width: w, height: h)
        panel.setFrame(frame, display: true)
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }  // lets text selection/buttons work without activating Paluku
}

// MARK: - Views

struct OverlayView: View {
    @Bindable var c = Coordinator.shared
    var onSize: (CGSize) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if c.panelVisible {
                AgentPanel()
            } else if isDictating || c.toast != nil {
                Pill()
            }
        }
        .fixedSize()
        .onGeometryChange(for: CGSize.self) {
            $0.size
        } action: {
            onSize($0)
        }
        .animation(.spring(duration: 0.25), value: c.panelVisible)
    }

    var isDictating: Bool {
        switch c.phase {
        case .recording(.dictation, _), .transcribing(.dictation): true
        default: false
        }
    }
}

struct Pill: View {
    @Bindable var c = Coordinator.shared

    var body: some View {
        HStack(spacing: 10) {
            switch c.phase {
            case .recording(_, let handsFree):
                Circle().fill(.red).frame(width: 8, height: 8)
                Waveform(level: c.level)
                if handsFree { Text("Hands-free · tap to stop").font(.caption).foregroundStyle(.secondary) }
                RecordingClock(start: c.recordingStarted)
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Writing…").font(.callout)
            default:
                if let t = c.toast { Text(t).font(.callout).lineLimit(3).frame(maxWidth: 380) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.black.opacity(0.85), in: Capsule())
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .padding(8)
    }
}

struct RecordingClock: View {
    var start: Date?
    var body: some View {
        if let start {
            TimelineView(.periodic(from: start, by: 1)) { ctx in
                let s = Int(ctx.date.timeIntervalSince(start))
                if s >= 5 { Text(String(format: "%d:%02d", s / 60, s % 60)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
        }
    }
}

struct Waveform: View {
    var level: Float
    @State private var history: [CGFloat] = Array(repeating: 0.05, count: 18)

    var body: some View {
        HStack(spacing: 2) {
            ForEach(history.indices, id: \.self) { i in
                Capsule().fill(.white).frame(width: 3, height: 4 + history[i] * 20)
            }
        }
        .frame(height: 24)
        .onChange(of: level) { _, l in
            history.removeFirst()
            history.append(CGFloat(max(0.05, l)))
        }
    }
}

struct AgentPanel: View {
    @Bindable var c = Coordinator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let t = c.toast { Label(t, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
            ForEach(c.notices) { n in NoticeView(notice: n) }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(c.turns.suffix(4)) { t in TurnView(turn: t).id(t.id) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: c.turns.last?.answer) { _, _ in if let id = c.turns.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            if let d = c.draft { DraftCard(text: d) }
            if let req = c.pendingConfirm { ConfirmCard(req: req) }
            footer
        }
        .padding(14)
        .frame(width: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .padding(8)
    }

    var header: some View {
        HStack {
            Image(systemName: "waveform").foregroundStyle(.tint)
            Text("Paluku").font(.headline)
            Spacer()
            QuickModelMenu().menuStyle(.borderlessButton).fixedSize().font(.caption).foregroundStyle(.secondary)
            if !c.turns.isEmpty {
                Button {
                    c.resetConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless).help("New conversation").accessibilityLabel("New conversation")
            }
            Button {
                c.closePanel()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless).help("Close (Esc)").accessibilityLabel("Close panel")
        }
    }

    @ViewBuilder var footer: some View {
        switch c.phase {
        case .recording(.agent, let handsFree):
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Waveform(level: c.level).colorMultiply(.primary)
                Text(handsFree ? "Listening · tap \(c.settings.agentKey.label) to send" : "Listening… move the cursor to point").font(.caption).foregroundStyle(
                    .secondary)
            }
        case .transcribing(.agent):
            HStack {
                ProgressView().controlSize(.small); Text("Transcribing…").font(.caption).foregroundStyle(.secondary)
            }
        case .thinking:
            HStack {
                ProgressView().controlSize(.small)
                Text(c.turns.last?.activity ?? "Thinking…").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { c.stopAgent() }.controlSize(.small)
            }
        default:
            if c.turns.isEmpty && c.notices.isEmpty && c.draft == nil {
                Text("Hold \(c.settings.agentKey.label) and ask anything.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Links in agent output come from the model (possibly injected): web pages and harmless files only.
/// DNS lookup + file checks run off the main thread; open only if they pass.
func openIfSafe(_ url: URL) {
    Task.detached {
        if LinkPolicy.isSafeToOpen(url) { await MainActor.run { _ = NSWorkspace.shared.open(url) } }
    }
}

extension View {
    /// Markdown links in model-written text open only through `openIfSafe`.
    func safeLinks() -> some View {
        environment(
            \.openURL,
            OpenURLAction {
                openIfSafe($0); return .handled
            })
    }
}

struct TurnView: View {
    var turn: Turn
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                if turn.hasScreenshot { Image(systemName: "macwindow").font(.caption).foregroundStyle(.secondary).help("Screen context attached") }
                Text(turn.user).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !turn.answer.isEmpty {
                Text(LocalizedStringKey(turn.answer)).font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .safeLinks()
            }
            ForEach(turn.cards) { CardView(card: $0) }
        }
    }
}

struct CardView: View {
    var card: Card
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(card.title, systemImage: card.icon).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let d = card.imageData, let img = NSImage(data: d) {
                Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 160).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            ForEach(card.rows.prefix(8), id: \.self) { row in
                if let url = row.url {
                    Button {
                        openIfSafe(url)
                    } label: {
                        rowLabel(row).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onDrag { NSItemProvider(object: url as NSURL) }
                } else {
                    rowLabel(row)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

extension CardView {
    func rowLabel(_ row: Card.Row) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.title).font(.callout).lineLimit(3).multilineTextAlignment(.leading).textSelection(.enabled)
            if let d = row.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConfirmCard: View {
    var req: ConfirmRequest
    @Bindable var c = Coordinator.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Confirm \(Coordinator.activityLabel(req.toolName).dropLast())", systemImage: "hand.raised.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            ScrollView { Text(req.summary).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 200).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { c.resolveConfirm(id: req.id, false) }.keyboardShortcut(.cancelAction)
                Spacer()
                if req.canAlwaysAllow {
                    Menu("Always allow") { Button("Always allow \(req.integration)") { c.resolveConfirm(id: req.id, true, always: true) } }
                        .menuStyle(.borderlessButton).fixedSize().font(.caption)
                }
                if c.confirmQueue.count > 1 { Text("+\(c.confirmQueue.count - 1) more").font(.caption).foregroundStyle(.secondary) }
                Button("Approve") { c.resolveConfirm(id: req.id, true) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            Text("Or hold \(c.settings.agentKey.label) and say “yes” / “cancel”.").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.orange.opacity(0.35)))
    }
}

struct DraftCard: View {
    var text: String
    @Bindable var c = Coordinator.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Draft", systemImage: "text.cursor").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView { Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 220).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); c.draft = nil
                }
                Spacer()
                Button("Insert + ↩︎") { c.insertDraft(pressReturn: true) }
                Button("Insert") { c.insertDraft(pressReturn: false) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct NoticeView: View {
    var notice: Notice
    @Bindable var c = Coordinator.shared
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: notice.icon).foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text(notice.title).font(.caption.weight(.semibold))
                Text(LocalizedStringKey(notice.body)).font(.callout).textSelection(.enabled)
                    .safeLinks()
            }
            Spacer()
            Button {
                c.notices.removeAll { $0.id == notice.id }
            } label: {
                Image(systemName: "xmark")
            }.buttonStyle(.borderless).accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct TrailView: View {
    @Bindable var c = Coordinator.shared
    var body: some View {
        Canvas { ctx, size in
            guard c.trail.count > 1 else { return }
            var p = Path()
            // CG global (top-left origin) == SwiftUI coords on the primary screen.
            p.addLines(c.trail)
            ctx.stroke(p, with: .color(.red.opacity(0.85)), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        }
        .ignoresSafeArea()
    }
}
