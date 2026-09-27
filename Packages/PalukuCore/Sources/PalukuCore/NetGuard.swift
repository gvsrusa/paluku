import Foundation

/// Blocks agent web requests to the local machine and private networks (SSRF): Ollama, local MCP servers,
/// router admin pages, cloud metadata. Checked on the initial URL and on every redirect.
public enum NetGuard {
    public static func isPrivateHost(_ rawHost: String) -> Bool {
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if host.isEmpty || host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal")
            || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa")
        {
            return true
        }
        // Ambiguous numeric forms: resolvers disagree on "0177.0.0.1" (decimal here, octal in WHATWG URL parsing). Fail closed.
        if host.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == "x" }), host.split(separator: ".").contains(where: { $0.count > 1 && ($0.hasPrefix("0")) }) {
            return true
        }
        // Let the system resolver interpret the host exactly as the network stack will (octal "0177.0.0.1",
        // decimal "2130706433", "127.1", every IPv6 spelling), then judge the numeric results by their bytes.
        let addresses = resolve(host)
        // Unresolvable now may resolve privately later (rebinding) → fail closed.
        if addresses.isEmpty { return true }
        return addresses.contains(where: isPrivateAddress)
        // ponytail: DNS rebinding (TTL-0 flip between this check and URLSession's own lookup) is a known TOCTOU gap;
        // closing it needs connecting to the pinned IP. Accepted: redirects are re-checked and fetches are read-only GETs.
    }

    static func isPrivateAddress(_ numeric: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, numeric, &v4) == 1 {
            return isPrivateV4(withUnsafeBytes(of: v4.s_addr) { Array($0) })
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, numeric, &v6) == 1 else { return true }  // unparseable → fail closed
        let b = withUnsafeBytes(of: v6) { Array($0) }
        let embeddedV4 = Array(b[12..<16])
        if b.allSatisfy({ $0 == 0 }) || (b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1) { return true }  // :: and ::1
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }  // fe80::/10 link-local
        if (b[0] & 0xfe) == 0xfc { return true }  // fc00::/7 unique-local
        if b[0] == 0xff { return true }  // multicast
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return isPrivateV4(embeddedV4) }  // ::ffff:a.b.c.d
        if b[0..<12].allSatisfy({ $0 == 0 }) { return isPrivateV4(embeddedV4) }  // ::a.b.c.d (deprecated compat)
        if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b { return isPrivateV4(embeddedV4) }  // 64:ff9b::/96 NAT64
        return false
    }

    static func isPrivateV4(_ b: [UInt8]) -> Bool {
        switch (b[0], b[1]) {
        case (0, _), (10, _), (127, _): true
        case (169, 254), (192, 168): true
        case (172, 16...31): true
        case (100, 64...127): true  // CGNAT
        default: b[0] >= 224  // multicast / reserved
        }
    }

    static func resolve(_ host: String) -> [String] {
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: buf))
            }
            p = ai.pointee.ai_next
        }
        return out
    }

    public static func check(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", let raw = url.host(percentEncoded: true), !raw.isEmpty else {
            throw ToolArgumentError(message: "Only http(s) web addresses are allowed.")
        }
        // URLSession decodes "%2e" in hosts; the resolver doesn't. Only plain hostname characters are acceptable.
        let host = raw.removingPercentEncoding ?? raw
        guard host == raw, host.allSatisfy({ $0.isLetter || $0.isNumber || ".-:[]".contains($0) }), host.unicodeScalars.allSatisfy(\.isASCII) else {
            throw ToolArgumentError(message: "That web address has an unusual host name; Paluku won't fetch it.")
        }
        if isPrivateHost(host) { throw ToolArgumentError(message: "Paluku won't fetch local or private-network addresses.") }
    }

    /// URLSession delegate that re-checks every redirect target.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest: URLRequest) async -> URLRequest? {
            guard let u = newRequest.url, (try? NetGuard.check(u)) != nil else { return nil }
            return newRequest
        }
    }

    public static let session = URLSession(configuration: .ephemeral, delegate: RedirectGuard(), delegateQueue: nil)
}

/// Which links from model/tool output Paluku may open: public web pages, Maps/Calendar, and harmless files.
/// Blocks custom app schemes (shortcuts://, x-apple…), private-network URLs and executables. Does DNS/file I/O.
public enum LinkPolicy {
    public static func isSafeToOpen(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": (try? NetGuard.check(url)) != nil
        case "maps", "ical": true
        case "file": (try? FinderTools.checkReadable(url)) != nil && (try? FinderTools.checkOpenable(url)) != nil
        default: false
        }
    }
}
