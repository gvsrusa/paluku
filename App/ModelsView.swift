import PalukuCore
import SwiftUI

/// Provider, installed models, one-click downloads.
struct ModelsView: View {
    @Bindable var c = Coordinator.shared
    @State private var pullName = ""
    @State private var apiKey = Keychain.get("provider.apiKey") ?? ""
    /// Edited locally and applied on Return / leaving the tab: each keystroke would otherwise rebuild the client.
    @State private var urlDraft = ""
    private var savedURL: String { isOllama ? c.settings.ollamaURL : c.settings.openAIBaseURL }
    private func commitURL() {
        let u = urlDraft.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty, u != savedURL else { return }
        if isOllama { c.settings.ollamaURL = u } else { c.settings.openAIBaseURL = u }
    }

    var isOllama: Bool { c.settings.provider == .ollama }

    var body: some View {
        Form {
            Section {
                Picker("Runtime", selection: $c.settings.provider) {
                    ForEach(ModelProvider.allCases) { Text($0.label).tag($0) }
                }
                if isOllama {
                    TextField("Ollama URL", text: $urlDraft).onSubmit(commitURL)
                } else {
                    TextField("Base URL", text: $urlDraft, prompt: Text("http://127.0.0.1:1234/v1")).onSubmit(commitURL)
                    SecureField("API key (optional)", text: $apiKey)
                        .onSubmit { c.setAPIKey(apiKey) }
                    Text(
                        "LM Studio: 127.0.0.1:1234/v1 · llama.cpp server: 127.0.0.1:8080/v1 · MLX-LM: 127.0.0.1:8080/v1 · Jan: 127.0.0.1:1337/v1. Key is stored in the Keychain."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Runtime")
            }

            Section {
                ModelPicker(title: "Agent model", selection: $c.settings.agentModel)
                ModelPicker(title: "Dictation & edit model", selection: $c.settings.polishModel)
                Text("The agent model needs tool calling; pick one with vision to ask about your screen. A small model (3–8B) keeps dictation fast.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                HStack {
                    Text("Active models")
                    Spacer()
                    Button {
                        Task { await c.refreshModels() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).accessibilityLabel("Refresh model list")
                }
            }

            Section("Installed") {
                if let err = c.modelsError {
                    Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if c.availableModels.isEmpty {
                    Text("No models installed yet. Download one below.").foregroundStyle(.secondary)
                }
                ForEach(c.availableModels, id: \.self) { m in
                    HStack {
                        Text(m).font(.body.monospaced())
                        if m == c.settings.agentModel { Tag("agent") }
                        if m == c.settings.polishModel { Tag("dictation") }
                        Spacer()
                        Menu("Use") {
                            Button("For agent") { c.settings.agentModel = m }
                            Button("For dictation & edit") { c.settings.polishModel = m }
                            Button("For both") {
                                c.settings.agentModel = m; c.settings.polishModel = m
                            }
                        }
                        .fixedSize()
                        if isOllama {
                            Button(role: .destructive) {
                                c.deleteModel(m)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless).accessibilityLabel("Delete \(m)")
                            .disabled(m == c.settings.agentModel || m == c.settings.polishModel)
                            .help("Delete from disk (switch away first)")
                        }
                    }
                }
            }

            if isOllama {
                Section("Download") {
                    HStack {
                        TextField("Model name, e.g. qwen3:8b", text: $pullName)
                            .onSubmit {
                                c.pull(pullName); pullName = ""
                            }
                        Button("Download") {
                            c.pull(pullName); pullName = ""
                        }.disabled(pullName.isEmpty)
                    }
                    ForEach(c.pulls.keys.sorted(), id: \.self) { name in PullRow(name: name, progress: c.pulls[name]!) }
                    Link("Browse all models on ollama.com", destination: URL(string: "https://ollama.com/search?c=tools")!)
                }
                Section("Recommended open models") {
                    ForEach(ModelCatalog.recommended) { e in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(e.id).font(.body.monospaced())
                                    if e.vision { Tag("vision") }
                                }
                                Text("\(e.summary) · \(e.sizeGB, specifier: "%.1f") GB").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if c.availableModels.contains(e.id) {
                                Label("Installed", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.green)
                                    .accessibilityLabel("Installed")
                            } else if c.pulls[e.id] == nil {
                                Button("Download") { c.pull(e.id) }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Models")
        .task { await c.refreshModels() }
        .onAppear { urlDraft = savedURL }
        .onChange(of: c.settings.provider) { urlDraft = savedURL }
        .onDisappear {
            commitURL()
            if !isOllama { c.setAPIKey(apiKey) }
        }
    }
}

struct ModelPicker: View {
    var title: String
    @Binding var selection: String
    @Bindable var c = Coordinator.shared

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Array(Set(c.availableModels + [selection])).sorted(), id: \.self) { m in
                Text(c.availableModels.contains(m) ? m : "\(m) (not installed)").tag(m)
            }
        }
    }
}

struct PullRow: View {
    var name: String
    var progress: PullProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.body.monospaced())
                Spacer()
                Text(progress.fraction.map { "\(Int($0 * 100))%" } ?? progress.status).font(.caption).foregroundStyle(.secondary)
            }
            if let f = progress.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Downloading \(name)")
        .accessibilityValue(progress.fraction.map { "\(Int($0 * 100)) percent" } ?? progress.status)
    }
}

struct Tag: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}

/// Compact switcher used in the menu bar and the agent panel.
struct QuickModelMenu: View {
    @Bindable var c = Coordinator.shared
    var body: some View {
        Menu {
            Section("Agent model") {
                ForEach(c.availableModels, id: \.self) { m in
                    Button {
                        c.settings.agentModel = m
                    } label: {
                        if m == c.settings.agentModel { Label(m, systemImage: "checkmark") } else { Text(m) }
                    }
                }
            }
            Section("Dictation model") {
                ForEach(c.availableModels, id: \.self) { m in
                    Button {
                        c.settings.polishModel = m
                    } label: {
                        if m == c.settings.polishModel { Label(m, systemImage: "checkmark") } else { Text(m) }
                    }
                }
            }
            Divider()
            Button("Manage models…") { MainWindow.show(tab: .models) }
        } label: {
            Label(c.settings.agentModel, systemImage: "cpu")
        }
        .accessibilityLabel("Model: \(c.settings.agentModel)")
    }
}
