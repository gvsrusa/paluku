import Foundation

/// Loosely-typed JSON used for tool arguments/results crossing the LLM boundary.
public enum JSONValue: Codable, Sendable, Equatable, CustomStringConvertible {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        switch self {
        case .string(let s): s
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): String(b)
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let n): n
        case .string(let s): Double(s)
        default: nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): b
        case .string(let s): ["true", "yes", "1"].contains(s.lowercased())
        default: nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var description: String {
        guard let data = try? JSONEncoder.sorted.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Convert any JSONSerialization-compatible value.
    public init(any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSONValue(any: $0) })
        case let o as [String: Any]: self = .object(o.mapValues { JSONValue(any: $0) })
        default: self = .string(String(describing: any!))
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral
{
    public init(stringLiteral v: String) { self = .string(v) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(integerLiteral v: Int) { self = .number(Double(v)) }
}

extension JSONEncoder {
    static let sorted: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}

/// Helpers for tool argument access with readable errors.
public struct ToolArgumentError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

extension JSONValue {
    public func string(_ key: String) throws -> String {
        guard let v = self[key]?.stringValue, !v.isEmpty else {
            throw ToolArgumentError(message: "Missing required argument '\(key)'")
        }
        return v
    }
    public func optString(_ key: String) -> String? {
        guard let v = self[key]?.stringValue, !v.isEmpty else { return nil }
        return v
    }
    public func int(_ key: String) -> Int? {
        guard let d = self[key]?.doubleValue, abs(d) < 1e15 else { return nil }  // false for NaN/inf too
        return Int(d)
    }
    public func int(_ key: String, default d: Int, in range: ClosedRange<Int>) -> Int {
        min(max(int(key) ?? d, range.lowerBound), range.upperBound)
    }
    public func bool(_ key: String) -> Bool? { self[key]?.boolValue }
    /// Accepts ISO-8601 with or without timezone / seconds, or "YYYY-MM-DD".
    public func date(_ key: String) -> Date? {
        guard let s = optString(key) else { return nil }
        return DateParsing.parse(s)
    }
}

public enum DateParsing {
    public static func parse(_ s: String, timeZone: TimeZone = .current) -> Date? {
        let iso = ISO8601DateFormatter()
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = opts
            if let d = iso.date(from: s) { return d }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    public static func iso(_ d: Date, timeZone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}
