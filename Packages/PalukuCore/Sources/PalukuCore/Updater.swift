import CryptoKit
import Foundation
import Security

/// Installs a release over the running app: download DMG → SHA-256 → mount → copy next to the app → verify the copy's
/// code signature (same Developer ID team when we have one), bundle id and version → atomic swap → relaunch.
/// ponytail: notify + replace instead of Sparkle; add Sparkle (EdDSA-signed appcast, delta updates) if releases get big
/// or the checksum-from-the-same-release trust model isn't enough (ADR-0001).
public enum Updater {
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// False when the bundle can't be replaced in place: run from a DMG, App-Translocated (quarantined and never moved to
    /// Applications), or in a folder the user can't write.
    public static func canInstall(over app: URL) -> Bool {
        let path = app.standardizedFileURL.path
        guard !path.contains("/AppTranslocation/"), !path.hasPrefix("/Volumes/"), !path.hasPrefix("/System/") else { return false }
        return FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    /// `line` is the release's `.sha256` file: "<64 hex>  <file name>".
    static func verifyChecksum(of file: URL, against line: String) throws {
        guard let expected = line.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased(),
            expected.count == 64, expected.allSatisfy(\.isHexDigit)
        else { throw Failure(message: "The release's checksum file is malformed.") }
        let actual = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw Failure(message: "The download doesn't match the release checksum.") }
    }

    /// Code requirement for "Developer ID Application certificate of this team" (not just any Apple-issued
    /// certificate: development and App Store certificates of the same team are refused).
    static func requirement(team: String) throws -> String {
        guard team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
            throw Failure(message: "Invalid team identifier.")
        }
        return "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// Valid signature (strict, nested code) that satisfies `requirement` when given.
    static func verifySignature(of app: URL, requirement: String?) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw Failure(message: "The update isn't a signed app.")
        }
        var req: SecRequirement?
        if let requirement, SecRequirementCreateWithString(requirement as CFString, [], &req) != errSecSuccess {
            throw Failure(message: "Can't build the signing requirement.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess else {
            throw Failure(message: requirement == nil ? "The update's code signature is invalid." : "The update isn't signed by the Paluku developer.")
        }
    }

    /// The bundle's designated requirement as text (what macOS permissions are tied to).
    static func designatedRequirement(of app: URL) -> String? {
        var code: SecStaticCode?
        var req: SecRequirement?
        var text: CFString?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
            SecCodeCopyDesignatedRequirement(code, [], &req) == errSecSuccess, let req,
            SecRequirementCopyString(req, [], &text) == errSecSuccess
        else { return nil }
        return text as String?
    }

    /// What an update must satisfy, from the *running* code's signature (not the bundle on disk, which could have
    /// been re-signed):
    /// - Developer ID: a Developer ID certificate from the same team.
    /// - Self-signed release: the same designated requirement (identifier + our certificate).
    /// - Ad-hoc (cdhash-only) builds: nil — only signature validity can be checked.
    /// Throws if the signature can't be read, so a failure never silently drops the check.
    public static func runningRequirement() throws -> String? {
        var me: SecCode?
        var staticMe: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me, SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
            SecCodeCopySigningInformation(staticMe, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { throw Failure(message: "Can't read Paluku's own code signature.") }
        if let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String { return try requirement(team: team) }
        var req: SecRequirement?
        var text: CFString?
        guard SecCodeCopyDesignatedRequirement(staticMe, [], &req) == errSecSuccess, let req,
            SecRequirementCopyString(req, [], &text) == errSecSuccess, let dr = text as String?
        else { return nil }  // unsigned
        return dr.contains("cdhash") ? nil : try combine(dr, nextTeam: Bundle.main.object(forInfoDictionaryKey: "PalukuNextTeamID") as? String)
    }

    /// `dr` OR a Developer ID signature from `nextTeam` (Info.plist `PalukuNextTeamID`, set in the last self-signed
    /// release before switching to Developer ID, so that build can still update).
    static func combine(_ dr: String, nextTeam: String?) throws -> String {
        guard let nextTeam, !nextTeam.isEmpty else { return dr }
        return "(\(dr)) or (\(try requirement(team: nextTeam)))"
    }

    /// Deletes staging copies left by an update that was interrupted (crash, force quit) so LaunchServices can't
    /// resolve Paluku to a stale hidden bundle.
    public static func removeLeftovers(near app: URL) {
        let dir = app.deletingLastPathComponent()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(".Paluku-update-") && name.hasSuffix(".app") {
            try? FileManager.default.removeItem(at: dir.appending(path: name))
        }
    }

    public enum Readiness: Sendable {
        /// Install in place; the new build must satisfy `requirement` (nil = ad-hoc build, signature validity only).
        case ready(requirement: String?)
        /// Send the user to the release page instead.
        case manual(reason: String)
    }

    /// Whether `release` can be installed over `app`. `requirement` is `runningRequirement` (injectable for tests); if
    /// the running signature can't be read, never update in place.
    public static func readiness(
        _ release: UpdateChecker.Release, app: URL, requirement: () throws -> String? = runningRequirement
    ) -> Readiness {
        guard release.dmg != nil, release.checksum != nil else { return .manual(reason: "This release has no DMG to install.") }
        guard canInstall(over: app) else { return .manual(reason: "Paluku isn't in a folder it can update (move it to Applications).") }
        do { return .ready(requirement: try requirement()) } catch { return .manual(reason: "Paluku can't read its own signature.") }
    }

    /// Replaces `app` with the release's build. `requirement`: `runningRequirement()` of the installed app.
    /// `status` reports each step for the UI.
    public static func install(
        _ release: UpdateChecker.Release, over app: URL, requirement: String?, status: @Sendable (String) -> Void
    ) async throws {
        guard let dmgURL = release.dmg, let sumURL = release.checksum else { throw Failure(message: "This release has no downloadable DMG.") }
        guard canInstall(over: app) else { throw Failure(message: "Move Paluku to Applications first, then update.") }
        removeLeftovers(near: app)
        let work = FileManager.default.temporaryDirectory.appending(path: "paluku-update-\(UUID().uuidString)")
        let mount = work.appending(path: "mnt")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer {
            // Before attach: a timed-out attach can still finish mounting. Detaching an unmounted path is harmless.
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", mount.path, "-force", "-quiet"]
            try? detach.run()
            detach.waitUntilExit()
            try? FileManager.default.removeItem(at: work)
        }

        status("Downloading Paluku \(release.version)…")
        let (sumData, sumResp) = try await URLSession.shared.data(from: sumURL)
        try requireOK(sumResp, "GitHub")
        let (tmp, dmgResp) = try await URLSession.shared.download(from: dmgURL)
        try requireOK(dmgResp, "GitHub")
        let dmg = work.appending(path: "Paluku.dmg")
        try FileManager.default.moveItem(at: tmp, to: dmg)

        status("Verifying…")
        try verifyChecksum(of: dmg, against: String(decoding: sumData, as: UTF8.self))
        try await Shell.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path], timeout: 120)

        // Stage on the same volume as the app so the final swap is a rename.
        let staged = app.deletingLastPathComponent().appending(path: ".Paluku-update-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: staged) }
        try await Shell.run("/usr/bin/ditto", [mount.appending(path: "Paluku.app").path, staged.path], timeout: 120)
        guard let new = Bundle(url: staged), new.bundleIdentifier == Bundle(url: app)?.bundleIdentifier,
            new.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version
        else { throw Failure(message: "The downloaded app isn't Paluku \(release.version).") }
        try verifySignature(of: staged, requirement: requirement)

        status("Installing…")
        _ = try FileManager.default.replaceItemAt(app, withItemAt: staged)
        Telemetry.shared.event(.app, "update_installed", ["version": release.version])
    }

    /// Opens `app` again once this process has exited. Arguments are passed positionally (no shell interpolation).
    public static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"", "sh", String(getpid()), app.path]
        try? p.run()
    }
}
