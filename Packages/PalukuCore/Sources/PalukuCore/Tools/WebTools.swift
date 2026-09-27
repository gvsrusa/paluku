import AppKit
import MapKit

/// Web search (DuckDuckGo HTML), page fetch, weather (Open-Meteo), places (MapKit).
public enum WebTools {
    static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    static func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (d, r) = try await NetGuard.session.data(for: req)
        guard let http = r as? HTTPURLResponse else { throw Shell.Failure(message: "Bad response") }
        return (d, http)
    }

    public struct SearchResult: Equatable, Sendable { public var title: String; public var url: String; public var snippet: String }

    /// Parses html.duckduckgo.com results.
    public static func parseDuckDuckGo(_ html: String) -> [SearchResult] {
        let blocks = html.components(separatedBy: "result__body\"").dropFirst()
        return blocks.compactMap { b -> SearchResult? in
            guard let a = b.firstMatch(of: /class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)<\/a>/.dotMatchesNewlines()) else { return nil }
            var href = String(a.1).replacingOccurrences(of: "&amp;", with: "&")
            if let r = href.range(of: "uddg="), let enc = href[r.upperBound...].split(separator: "&").first {
                href = String(enc).removingPercentEncoding ?? href
            }
            if href.hasPrefix("//") { href = "https:" + href }
            let snippet = b.firstMatch(of: /class="result__snippet"[^>]*>(.*?)<\/a>/.dotMatchesNewlines()).map { stripTags(String($0.1)) } ?? ""
            guard !href.contains("duckduckgo.com/y.js") else { return nil }  // ads
            return SearchResult(title: stripTags(String(a.2)), url: href, snippet: snippet)
        }
    }

    public static func stripTags(_ s: String) -> String {
        var t = s.replacingOccurrences(
            of: "<script[\\s\\S]*?</script>|<style[\\s\\S]*?</style>|<noscript[\\s\\S]*?</noscript>", with: " ",
            options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "<(br|p|div|li|h[1-6]|tr)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (k, v) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&nbsp;": " "] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        return t.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n\\s*\\n+", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Weather code → words (WMO).
    static func weatherWord(_ c: Int) -> String {
        switch c {
        case 0: "clear"
        case 1, 2: "partly cloudy"
        case 3: "overcast"
        case 45, 48: "fog"
        case 51...57: "drizzle"
        case 61...67: "rain"
        case 71...77: "snow"
        case 80...82: "showers"
        case 85, 86: "snow showers"
        case 95...99: "thunderstorm"
        default: "mixed"
        }
    }

    public static func all(temperatureUnit: @escaping @Sendable () -> String = { Locale.current.measurementSystem == .us ? "fahrenheit" : "celsius" }) -> [Tool]
    {
        [
            // Fixed host (DuckDuckGo) → not an egress channel an attacker can read.
            Tool(
                name: "web_search", description: "Search the web. Returns titles, URLs and snippets. Use web_fetch to read a page.",
                parameters: Schema.object(["query": Schema.string("search query")], required: ["query"]), integration: "web", untrusted: true
            ) { args in
                let q = try args.string("query")
                var comps = URLComponents(string: "https://html.duckduckgo.com/html/")!
                comps.queryItems = [URLQueryItem(name: "q", value: q)]
                let (d, _) = try await get(comps.url!)
                let results = Array(parseDuckDuckGo(String(decoding: d, as: UTF8.self)).prefix(8))
                if results.isEmpty { return ToolResult("No results for '\(q)'.") }
                return ToolResult(
                    results.enumerated().map { "\($0 + 1). \($1.title)\n\($1.url)\n\($1.snippet)" }.joined(separator: "\n\n"),
                    card: Card(
                        icon: "globe", title: "Web: \(q)",
                        rows: results.prefix(5).map { Card.Row($0.title, detail: URL(string: $0.url)?.host(), url: URL(string: $0.url)) }))
            },
            Tool(
                name: "web_fetch", description: "Fetch a web page and return its readable text.",
                parameters: Schema.object(["url": Schema.string("https URL")], required: ["url"]), integration: "web", egress: true, untrusted: true
            ) { args in
                guard let url = URL(string: try args.string("url")) else { throw ToolArgumentError(message: "Invalid URL") }
                try NetGuard.check(url)
                let (d, r) = try await get(url)
                let html = String(decoding: d, as: UTF8.self)
                let text = (r.mimeType ?? "").contains("html") ? stripTags(html) : html
                return ToolResult(String(text.prefix(12_000)))
            },
            Tool(
                name: "weather", description: "Current weather and daily forecast (up to 7 days) for a place.",
                parameters: Schema.object(["location": Schema.string("city/place name"), "days": Schema.integer("1-7, default 3")], required: ["location"]),
                integration: "web"  // fixed host (Open-Meteo)
            ) { args in
                let place = try args.string("location")
                var g = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
                g.queryItems = [URLQueryItem(name: "name", value: place.components(separatedBy: ",")[0]), URLQueryItem(name: "count", value: "1")]
                let geo = try JSONSerialization.jsonObject(with: try await get(g.url!).0) as? [String: Any]
                guard let hit = (geo?["results"] as? [[String: Any]])?.first, let lat = hit["latitude"] as? Double, let lon = hit["longitude"] as? Double else {
                    throw Shell.Failure(message: "Unknown place \(place)")
                }
                let unit = temperatureUnit()
                let days = max(1, min(7, args.int("days") ?? 3))
                let url = URL(
                    string:
                        "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code,wind_speed_10m&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=auto&forecast_days=\(days)&temperature_unit=\(unit)"
                )!
                let w = try JSONSerialization.jsonObject(with: try await get(url).0) as? [String: Any]
                let cur = w?["current"] as? [String: Any] ?? [:]
                let daily = w?["daily"] as? [String: Any] ?? [:]
                let u = unit == "fahrenheit" ? "°F" : "°C"
                let dates = daily["time"] as? [String] ?? []
                var rows: [Card.Row] = []
                var lines = ["\(hit["name"] ?? place): now \(cur["temperature_2m"] ?? "?")\(u), \(weatherWord(cur["weather_code"] as? Int ?? -1))"]
                for (i, day) in dates.enumerated() {
                    let hi = (daily["temperature_2m_max"] as? [Double])?[safe: i] ?? 0, lo = (daily["temperature_2m_min"] as? [Double])?[safe: i] ?? 0
                    let code = (daily["weather_code"] as? [Int])?[safe: i] ?? -1, rain = (daily["precipitation_probability_max"] as? [Int])?[safe: i] ?? 0
                    lines.append("\(day): \(weatherWord(code)), \(Int(lo))–\(Int(hi))\(u), rain \(rain)%")
                    rows.append(Card.Row(day, detail: "\(weatherWord(code)) · \(Int(lo))–\(Int(hi))\(u) · ☔︎ \(rain)%"))
                }
                return ToolResult(lines.joined(separator: "\n"), card: Card(icon: "cloud.sun", title: "Weather · \(hit["name"] ?? place)", rows: rows))
            },
            Tool(
                name: "maps_search", description: "Find places (restaurants, shops, addresses) near the user or a location.",
                parameters: Schema.object(
                    ["query": Schema.string("what to find, e.g. 'coffee'"), "near": Schema.string("optional area/city")], required: ["query"]),
                integration: "maps", untrusted: true  // place names/phones are third-party text
            ) { args in
                let q = try args.string("query")
                let req = MKLocalSearch.Request()
                req.naturalLanguageQuery = args.optString("near").map { "\(q) near \($0)" } ?? q
                let items = try await MKLocalSearch(request: req).start().mapItems.prefix(8)
                if items.isEmpty { return ToolResult("No places found.") }
                let rows = items.map { i in
                    Card.Row(
                        i.name ?? "Place", detail: i.placemark.title,
                        url: URL(
                            string:
                                "maps://?q=\((i.name ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&ll=\(i.placemark.coordinate.latitude),\(i.placemark.coordinate.longitude)"
                        ))
                }
                return ToolResult(
                    items.map { "\($0.name ?? "") — \($0.placemark.title ?? "")\($0.phoneNumber.map { " — \($0)" } ?? "")" }.joined(separator: "\n"),
                    card: Card(icon: "map", title: "Places", rows: Array(rows)))
            },
            Tool(
                name: "maps_directions", description: "Open Apple Maps with directions to a destination.",
                parameters: Schema.object(
                    ["destination": Schema.string("address or place"), "mode": Schema.enumeration("transport", ["driving", "walking", "transit"])],
                    required: ["destination"]),
                integration: "maps"
            ) { args in
                let flag = ["walking": "w", "transit": "r"][args.optString("mode") ?? ""] ?? "d"
                let dest = try args.string("destination").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                let url = URL(string: "maps://?daddr=\(dest)&dirflg=\(flag)")!
                _ = await MainActor.run { NSWorkspace.shared.open(url) }
                return ToolResult("Opened directions in Maps.")
            },
        ]
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
