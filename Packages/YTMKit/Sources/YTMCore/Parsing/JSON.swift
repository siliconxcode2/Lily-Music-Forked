import Foundation

/// A read-only view into a parsed InnerTube response. Every step is optional,
/// so an item in an odd shape reads as missing rather than failing the page.
/// Lookups stay on `NSDictionary`/`NSArray`, as a Swift cast copies each step.
struct JSON: @unchecked Sendable {
    // `@unchecked`: the wrapped Foundation containers are immutable once
    // parsed and never handed out mutably.
    let raw: Any?

    init(_ raw: Any?) {
        self.raw = raw
    }

    init(data: Data) throws {
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw YTMError(.parse, "YouTube sent a reply that isn't JSON")
        }
    }

    static let missing = JSON(nil)

    subscript(key: String) -> JSON {
        JSON((raw as? NSDictionary)?.object(forKey: key))
    }

    subscript(index: Int) -> JSON {
        guard let list = raw as? NSArray, index >= 0, index < list.count else { return .missing }
        return JSON(list.object(at: index))
    }

    subscript(path: String...) -> JSON {
        path.reduce(self) { $0[$1] }
    }

    var exists: Bool { raw != nil && !(raw is NSNull) }
    var isObject: Bool { raw is NSDictionary }
    var isArray: Bool { raw is NSArray }
    var string: String? { raw as? String }
    var bool: Bool? { (raw as? NSNumber)?.boolValue ?? (raw as? String).flatMap(Bool.init) }

    var int: Int? {
        if let n = raw as? NSNumber { return n.intValue }
        return (raw as? String).flatMap { Int($0) }
    }

    var double: Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        return (raw as? String).flatMap { Double($0) }
    }

    var array: [JSON] { (raw as? NSArray)?.map(JSON.init) ?? [] }

    /// An array's last element, without wrapping the rest.
    var last: JSON { JSON((raw as? NSArray)?.lastObject) }

    /// The value of a one-key object, whatever the key: InnerTube wraps
    /// items as `{"someRenderer": {...}}`.
    var onlyValue: (key: String, value: JSON)? {
        guard let dict = raw as? NSDictionary, dict.count == 1,
              let key = dict.keyEnumerator().nextObject() as? String else { return nil }
        return (key, JSON(dict.object(forKey: key)))
    }

    /// The first of several keys that is present.
    func first(_ keys: String...) -> JSON {
        for key in keys {
            let value = self[key]
            if value.exists { return value }
        }
        return .missing
    }

    /// Whether `key` is set anywhere within, at any depth.
    func contains(key: String) -> Bool {
        if let dict = raw as? NSDictionary {
            return dict[key] != nil || dict.allValues.contains { JSON($0).contains(key: key) }
        }
        return array.contains { $0.contains(key: key) }
    }
}

// MARK: - Text

extension JSON {
    /// A text object's words: `{"runs": [{"text": …}]}` or `{"simpleText": …}`.
    var text: String? {
        if let simple = self["simpleText"].string { return simple }
        guard let runs = self["runs"].raw as? NSArray, runs.count > 0 else { return string }
        var out = ""
        for run in runs {
            if let t = JSON(run)["text"].string { out += t }
        }
        return out
    }

    var runs: [JSON] { self["runs"].array }
}
