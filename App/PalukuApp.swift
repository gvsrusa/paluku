import PalukuCore
import SwiftUI

@main
struct PalukuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Bindable var c = Coordinator.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            Image(systemName: menuIcon)
        }
    }

    var menuIcon: String {
        switch c.phase {
        case .recording: "waveform.circle.fill"
        case .transcribing, .thinking: "ellipsis.circle"
        case .idle: "waveform"
        }
    }
}

struct MenuContent: View {
    @Bindable var c = Coordinator.shared

    var body: some View {
        Text("Dictate: hold \(c.settings.dictationKey.label) · double-tap = hands-free")
        Text("Agent: hold \(c.settings.agentKey.label)")
        if case .downloading(let p) = c.speechModelState { Text("Downloading speech model… \(Int(p * 100))%") }
        if case .loading = c.speechModelState { Text("Loading speech model…") }
        if case .failed(let e) = c.speechModelState { Text("Speech model error: \(e)") }
        Divider()
        QuickModelMenu()
        Picker("Polish", selection: $c.settings.polishStyle) {
            ForEach(PolishStyle.allCases) { Text($0.rawValue.capitalized).tag($0) }
        }
        Toggle("Speak agent replies", isOn: $c.settings.speakReplies)
        Toggle("Use screen context", isOn: $c.settings.useScreenContext)
        Divider()
        if let status = c.updateStatus {
            Text("⬆︎ \(status)")
        } else if let u = c.update {
            Button("⬆︎ Install Paluku \(u.version) and restart") { c.installUpdate() }
            Button("What's new in \(u.version)…") { NSWorkspace.shared.open(u.url) }
            if (try? Updater.runningRequirement()) == nil {
                Text("Unsigned build: macOS will ask you to allow Paluku again after updating.").font(.caption)
            }
        }
        Button("Open Paluku…") { MainWindow.show() }.keyboardShortcut(",")
        Button("New agent conversation") { c.resetConversation() }
        Divider()
        Button("Check for Updates…") { c.checkForUpdates(manual: true) }
        Text("Paluku \(AppInfo.version)")
        Button("Quit Paluku") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var overlay: OverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Snapshot.runIfRequested()
        let c = Coordinator.shared
        c.start()
        overlay = OverlayController()
        if !c.settings.onboarded { MainWindow.show(tab: .setup) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let hub = Coordinator.shared.hub
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            await hub.stopAll(); sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2)
    }
}
