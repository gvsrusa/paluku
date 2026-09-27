import Foundation

public enum AppInfo {
    public static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    public static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
    /// "owner/repo" whose GitHub Releases host the DMGs (Info.plist `PalukuUpdateRepo`).
    public static var releasesRepo: String { Bundle.main.object(forInfoDictionaryKey: "PalukuUpdateRepo") as? String ?? "gvsrusa/paluku" }
}

/// Checks GitHub Releases for a newer version; `Updater` installs it.
/// API: https://docs.github.com/en/rest/releases/releases#get-the-latest-release
public enum UpdateChecker {
    public struct Release: Sendable, Equatable {
        public var version: String
        public var url: URL
        public var notes: String
        /// This repo's release assets (nil if missing or hosted anywhere else).
        public var dmg: URL? = nil
        public var checksum: URL? = nil
    }

    /// Semantic-version comparison of "1.2.3" style strings (leading "v" and pre-release suffix ignored).
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).prefix { $0 != "-" }
                .split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0]
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<3 where a[i] != b[i] { return a[i] > b[i] }
        return false
    }

    /// The download link must point at this repo's releases on github.com (never an arbitrary host).
    static func parse(_ data: Data, repo: String = AppInfo.releasesRepo) -> Release? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = o["tag_name"] as? String, let html = (o["html_url"] as? String).flatMap(URL.init(string:)),
            html.scheme == "https", html.host() == "github.com", html.path.hasPrefix("/\(repo)/releases/"),
            (o["draft"] as? Bool) != true, (o["prerelease"] as? Bool) != true
        else { return nil }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        func asset(_ name: String) -> URL? {
            let assets = o["assets"] as? [[String: Any]] ?? []
            guard let u = assets.first(where: { $0["name"] as? String == name })?["browser_download_url"] as? String,
                let c = URLComponents(string: u), c.scheme == "https", c.host == "github.com", c.user == nil, c.password == nil, c.port == nil,
                c.query == nil, c.percentEncodedPath == "/\(repo)/releases/download/\(tag)/\(name)", let url = c.url
            else { return nil }
            return url
        }
        return Release(
            version: version, url: html, notes: o["body"] as? String ?? "", dmg: asset("Paluku-\(version).dmg"),
            checksum: asset("Paluku-\(version).dmg.sha256"))
    }

    public static func latestNewer(than current: String, repo: String = AppInfo.releasesRepo) async -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
            let r = parse(data, repo: repo), isNewer(r.version, than: current)
        else { return nil }
        Telemetry.shared.event(.app, "update_available", ["version": r.version])
        return r
    }
}
