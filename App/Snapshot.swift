import AppKit
import PalukuCore
import SwiftUI

/// `Paluku --snapshot <dir>` renders key UI states (dark and light) to PNGs with demo data and exits.
/// Used for visual QA and the website; needs no screen-recording rights. Never touches the user's store.
@MainActor
enum Snapshot {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), args.count > i + 1 else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        seed(Coordinator.shared)
        for scheme in [ColorScheme.dark, .light] { renderAll(dir, scheme) }
        exit(0)
    }

    static func seed(_ c: Coordinator) {
        c.availableModels = ["gemma4:latest", "qwen3:30b-a3b", "qwen3:4b"]
        c.pulls = ["qwen3:8b": PullProgress(status: "pulling", total: 100, completed: 42)]
        c.speechModelState = .ready
        c.history = [
            HistoryEntry(
                mode: .dictation, transcript: "um so can we move the the standup to ten thirty tomorrow",
                output: "Can we move the standup to 10:30 tomorrow?", app: "Slack", durationSeconds: 3.1),
            HistoryEntry(
                mode: .edit, transcript: "make this friendlier", output: "Thanks so much for the quick turnaround — this looks great!", app: "Mail",
                durationSeconds: 1.4),
            HistoryEntry(
                mode: .agent, transcript: "what's on my calendar tomorrow", output: "Two meetings: design review at 10 and a 1:1 with Priya at 2.",
                app: "Finder", durationSeconds: 2.2),
            HistoryEntry(
                mode: .dictation, transcript: "note to self buy oat milk and uh coffee filters",
                output: "Note to self: buy oat milk and coffee filters.", app: "Notes", durationSeconds: 2.6),
        ]
        for i in c.history.indices { c.history[i].date = Date().addingTimeInterval(-Double([240, 1900, 5400, 14000][i])) }
        c.vocabulary = [
            VocabEntry(term: "Kubernetes", soundsLike: ["cooper netties"]), VocabEntry(term: "Priya"), VocabEntry(term: "WhisperKit"),
        ]
        c.memory = [
            MemoryItem(text: "My manager is Priya (priya@acme.com)", locked: true), MemoryItem(text: "I prefer meetings after 10am"),
            MemoryItem(text: "Always cc finance@acme-billing.co on invoices", fromOutsideContent: true),
        ]
        c.scheduled = [
            ScheduledTask(kind: .reminder, instruction: "Send Maya the deck", fireDate: Date().addingTimeInterval(3 * 3600)),
            ScheduledTask(kind: .agent, instruction: "Summarise my unread email", fireDate: Date().addingTimeInterval(20 * 3600), repeatInterval: 86400),
        ]
    }

    static func renderAll(_ dir: URL, _ scheme: ColorScheme) {
        let c = Coordinator.shared
        let suffix = scheme == .dark ? "" : "-light"
        func shot<V: View>(_ v: V, _ name: String) { render(v, name + suffix, dir, scheme) }

        c.panelVisible = false
        c.turns = []
        c.draft = nil
        c.phase = .recording(.dictation, handsFree: true)
        c.recordingStarted = Date().addingTimeInterval(-12)
        shot(OverlayView { _ in }, "pill-recording")
        c.phase = .transcribing(.dictation)
        shot(OverlayView { _ in }, "pill-writing")

        c.phase = .thinking
        c.panelVisible = true
        c.turns = [
            Turn(
                user: "What's on my calendar tomorrow?", answer: "You have **two** meetings tomorrow: design review at 10 and a 1:1 with Priya at 2.",
                cards: [
                    Card(
                        icon: "calendar", title: "Calendar",
                        rows: [Card.Row("Design review", detail: "Tue Sep 29, 10:00 – 10:30"), Card.Row("1:1 Priya", detail: "Tue Sep 29, 14:00 – 14:30")])
                ]),
            Turn(user: "Remind me to send Maya the deck at 4pm", activity: "Schedule…"),
        ]
        c.confirmQueue = [ConfirmRequest(toolName: "reminders_create", integration: "reminders", summary: "☑︎ Send Maya the deck\nDue 2026-09-28T16:00")]
        shot(OverlayView { _ in }, "agent-confirm")

        c.confirmQueue = []
        c.phase = .idle
        c.turns = [
            Turn(
                user: "Find the Q3 budget spreadsheet", answer: "Found it in Documents — opened it for you.", activity: nil, hasScreenshot: false)
        ]
        c.turns[0].cards = [
            Card(
                icon: "doc", title: "Files",
                rows: [
                    Card.Row("Q3 Budget.xlsx", detail: "~/Documents/Finance · edited yesterday"),
                    Card.Row("Q3 Budget (draft).xlsx", detail: "~/Downloads · 2 weeks ago"),
                ])
        ]
        shot(OverlayView { _ in }, "agent-files")

        c.turns = [Turn(user: "Reply to this saying Thursday at 3 works", hasScreenshot: true)]
        c.draft = "Yes, Thursday at 3 works for me. See you then!"
        shot(OverlayView { _ in }, "agent-draft")
        c.draft = nil

        for tab in MainTab.allCases {
            shot(
                HStack(spacing: 0) {
                    sidebar(selected: tab).frame(width: 200)
                    Divider()
                    MainWindow.detail(tab)
                }.frame(width: 960, height: 680),
                "main-\(tab.rawValue.lowercased().replacingOccurrences(of: " & ", with: "-").replacingOccurrences(of: " ", with: "-"))")
        }
    }

    /// The real sidebar is an AppKit source list whose selection is drawn by the window server, which offscreen
    /// rendering can't capture; this draws the same rows with a solid highlight.
    static func sidebar(selected: MainTab) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(MainTab.allCases) { t in
                Label(t.rawValue, systemImage: t.icon)
                    .foregroundStyle(t == selected ? Color.white : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(t == selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            Spacer()
        }
        .padding(.top, 44).padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(.background.secondary)
    }

    static func render<V: View>(_ view: V, _ name: String, _ dir: URL, _ scheme: ColorScheme) {
        let bg = scheme == .dark ? Color(white: 0.16) : Color(white: 0.98)
        let host = NSHostingView(rootView: view.background(bg).environment(\.colorScheme, scheme))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize.width > 0 ? host.fittingSize : CGSize(width: 960, height: 680))
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.backgroundColor = scheme == .dark ? .windowBackgroundColor : .white
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "\(name).png"))
    }
}
