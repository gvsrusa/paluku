import Foundation
import Security
import Testing

@testable import PalukuCore

/// In-place updates: the update path runs downloaded code, so every check must fail closed.
@Suite struct UpdaterTests {
    func release(_ assets: [[String: String]]) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "tag_name": "v9.9.9", "html_url": "https://github.com/o/r/releases/tag/v9.9.9",
            "assets": assets.map { ["name": $0["name"]!, "browser_download_url": $0["url"]!] },
        ])
    }

    @Test func findsDMGAndChecksumOnlyFromThisReposReleases() throws {
        let good = release([
            ["name": "Paluku-9.9.9.dmg", "url": "https://github.com/o/r/releases/download/v9.9.9/Paluku-9.9.9.dmg"],
            ["name": "Paluku-9.9.9.dmg.sha256", "url": "https://github.com/o/r/releases/download/v9.9.9/Paluku-9.9.9.dmg.sha256"],
        ])
        let r = try #require(UpdateChecker.parse(good, repo: "o/r"))
        #expect(r.dmg?.lastPathComponent == "Paluku-9.9.9.dmg")
        #expect(r.checksum?.lastPathComponent == "Paluku-9.9.9.dmg.sha256")

        let foreign = release([
            ["name": "Paluku-9.9.9.dmg", "url": "https://evil.example/Paluku-9.9.9.dmg"],
            ["name": "Paluku-9.9.9.dmg.sha256", "url": "https://github.com/other/repo/releases/download/v9.9.9/Paluku-9.9.9.dmg.sha256"],
        ])
        let f = try #require(UpdateChecker.parse(foreign, repo: "o/r"))
        #expect(f.dmg == nil && f.checksum == nil)
    }

    @Test func assetURLMustBeExactlyThisReleasesFile() throws {
        for bad in [
            "https://github.com/o/r/releases/download/v9.9.9/../../../../x/y/releases/download/v9.9.9/Paluku-9.9.9.dmg",
            "https://user@github.com/o/r/releases/download/v9.9.9/Paluku-9.9.9.dmg",
            "https://github.com:8443/o/r/releases/download/v9.9.9/Paluku-9.9.9.dmg",
            "https://github.com/o/r/releases/download/v1.0.0/Paluku-9.9.9.dmg",
        ] {
            let r = try #require(UpdateChecker.parse(release([["name": "Paluku-9.9.9.dmg", "url": bad]]), repo: "o/r"))
            #expect(r.dmg == nil, "accepted \(bad)")
        }
    }

    @Test func leftoverStagingCopiesAreRemoved() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "upd-\(UUID())")
        let app = dir.appending(path: "Paluku.app"), stale = dir.appending(path: ".Paluku-update-ABC.app"), other = dir.appending(path: "Other.app")
        for d in [app, stale, other] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        Updater.removeLeftovers(near: app)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["Other.app", "Paluku.app"])
    }

    @Test func developerIDRequirementDemandsDeveloperIDCertificate() throws {
        let r = try Updater.requirement(team: "ABCDE12345")
        #expect(r.contains("1.2.840.113635.100.6.2.6") && r.contains("1.2.840.113635.100.6.1.13") && r.contains("\"ABCDE12345\""))
        #expect(throws: Updater.Failure.self) { try Updater.requirement(team: "abc\" or true") }
    }

    @Test func checksumMustMatch() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "upd-\(UUID()).bin")
        try Data("hello".utf8).write(to: file)
        let sha = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        try Updater.verifyChecksum(of: file, against: "\(sha)  Paluku-9.9.9.dmg\n")
        #expect(throws: Updater.Failure.self) { try Updater.verifyChecksum(of: file, against: "\(String(repeating: "0", count: 64))  x.dmg") }
        #expect(throws: Updater.Failure.self) { try Updater.verifyChecksum(of: file, against: "garbage") }
    }

    @Test func refusesTranslocatedOrReadOnlyLocations() {
        #expect(!Updater.canInstall(over: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Paluku.app")))
        #expect(!Updater.canInstall(over: URL(fileURLWithPath: "/Volumes/Paluku 1.2.0/Paluku.app")))
        #expect(!Updater.canInstall(over: URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        let dir = FileManager.default.temporaryDirectory.appending(path: "upd-\(UUID())/Paluku.app")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(Updater.canInstall(over: dir))
    }

    @Test func rejectsTamperedBundleAndForeignTeam() throws {
        let calc = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        // Valid Apple signature, but not our team → refused when we are Developer ID signed.
        #expect(throws: Updater.Failure.self) { try Updater.verifySignature(of: calc, requirement: try Updater.requirement(team: "ABCDE12345")) }
        // A modified copy fails signature validation even with no team requirement (ad-hoc current build).
        let copy = FileManager.default.temporaryDirectory.appending(path: "upd-\(UUID())/Calculator.app")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: calc, to: copy)
        let plist = copy.appending(path: "Contents/Info.plist")
        var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
        info["Injected"] = "yes"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        #expect(throws: Updater.Failure.self) { try Updater.verifySignature(of: copy, requirement: nil) }
        try Updater.verifySignature(of: calc, requirement: nil)
    }

    /// Self-signed releases: an update must satisfy the running app's own designated requirement (same identifier and
    /// signing certificate), which is also what keeps macOS permissions across versions.
    @Test func designatedRequirementPinsIdentifierAndCertificate() throws {
        let calc = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let dr = try #require(Updater.designatedRequirement(of: calc))
        try Updater.verifySignature(of: calc, requirement: dr)
        #expect(throws: Updater.Failure.self) {
            try Updater.verifySignature(of: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), requirement: dr)
        }
    }
}

/// Any local Paluku.app build to update from (scripts/build.sh Release).
let localPalukuApp = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../../build/dd/Build/Products/Release/Paluku.app")
    .standardizedFileURL

/// Real GitHub release installed over a copy of a local build. Run with: PALUKU_LIVE=1 swift test --filter LiveUpdater
@Suite(.enabled(if: live && FileManager.default.fileExists(atPath: localPalukuApp.path))) struct LiveUpdaterTests {
    @Test func installsLatestReleaseOverAnOlderCopy() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "paluku-live-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appending(path: "Paluku.app")
        try FileManager.default.copyItem(at: localPalukuApp, to: app)
        let release = try #require(await UpdateChecker.latestNewer(than: "0.0.1", repo: "gvsrusa/paluku"))
        try await Updater.install(release, over: app, requirement: nil) { print("update:", $0) }
        // Read from disk: Bundle caches Info.plist per path.
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appending(path: "Contents/Info.plist")), format: nil)
        #expect((info as? [String: Any])?["CFBundleShortVersionString"] as? String == release.version)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["Paluku.app"], "staging copy left behind")
    }
}

@Suite struct UpdateReadinessTests {
    func release(dmg: Bool = true, sum: Bool = true) -> UpdateChecker.Release {
        let base = "https://github.com/o/r/releases/download/v9.9.9/"
        return UpdateChecker.Release(
            version: "9.9.9", url: URL(string: "https://github.com/o/r/releases/tag/v9.9.9")!, notes: "",
            dmg: dmg ? URL(string: base + "Paluku-9.9.9.dmg") : nil, checksum: sum ? URL(string: base + "Paluku-9.9.9.dmg.sha256") : nil)
    }

    /// Regression: an unsigned (no-team) build must still update in place; a nil team is not an error.
    @Test func unsignedBuildInAWritableFolderIsReady() throws {
        let app = FileManager.default.temporaryDirectory.appending(path: "upd-\(UUID())/Paluku.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        guard case .ready = Updater.readiness(release(), app: app, requirement: { nil }) else { Issue.record("not ready"); return }
        guard case .manual = Updater.readiness(release(sum: false), app: app, requirement: { nil }) else { Issue.record("no checksum"); return }
        guard case .manual = Updater.readiness(release(), app: URL(fileURLWithPath: "/Volumes/Paluku/Paluku.app"), requirement: { nil }) else {
            Issue.record("DMG"); return
        }
        guard case .manual = Updater.readiness(release(), app: app, requirement: { throw Updater.Failure(message: "x") }) else {
            Issue.record("unreadable signature must not update"); return
        }
    }
}

@Suite struct SigningTransitionTests {
    /// Moving from self-signed to Developer ID: the last self-signed build names the new team, so it accepts either.
    @Test func nextTeamWidensTheRequirement() throws {
        let dr = #"identifier "com.gvsrusa.Paluku" and certificate root = H"951a3602f93c8431c8c53439edcf9b796afff332""#
        #expect(try Updater.combine(dr, nextTeam: nil) == dr)
        let both = try Updater.combine(dr, nextTeam: "ABCDE12345")
        #expect(both.hasPrefix("(\(dr)) or (anchor apple generic") && both.contains("\"ABCDE12345\""))
        var req: SecRequirement?
        #expect(SecRequirementCreateWithString(both as CFString, [], &req) == errSecSuccess)
        #expect(throws: Updater.Failure.self) { try Updater.combine(dr, nextTeam: "bad\" or 1") }
    }
}
