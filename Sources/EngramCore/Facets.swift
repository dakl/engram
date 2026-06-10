import Foundation

/// Reserved facet keys (ADR 0013). A tag of the form `key:value` whose key is one
/// of these is presented in the faceted browser; everything else stays freeform.
/// Values are recommended, not enforced — `type:experiment` is allowed.
public enum FacetKey: String, CaseIterable, Sendable {
    case type
    case project
    case language
}

/// A memory's tags split into `key:value` facets and plain freeform tags
/// (ADR 0013). Facets are a tag convention, not a separate schema — this is the
/// pure parser the filter bar and CLI both read.
public struct Facets: Sendable, Equatable {
    /// All `key:value` facets, keyed by (lowercased) facet key, values in tag order.
    /// Includes non-reserved keys, which the UI may show as generic facets.
    public let byKey: [String: [String]]
    /// Tags with no `key:value` form.
    public let freeform: [String]

    public init(byKey: [String: [String]], freeform: [String]) {
        self.byKey = byKey
        self.freeform = freeform
    }

    /// Values for a reserved facet key (empty if none).
    public func values(_ key: FacetKey) -> [String] { byKey[key.rawValue] ?? [] }

    public var types: [String] { values(.type) }
    public var projects: [String] { values(.project) }
    public var languages: [String] { values(.language) }

    /// Whether this memory carries `value` under `key` (case-insensitive).
    public func matches(_ key: FacetKey, _ value: String) -> Bool {
        values(key).contains { $0.caseInsensitiveCompare(value) == .orderedSame }
    }

    /// Splits tags into facets and freeform, then **unions the capture origin
    /// (`source`) into the `project` facet** (ADR 0013 §2): a memory always
    /// appears under the project it came from, even before extra `project:` tags
    /// are added. `source` leads so the origin sorts first.
    public static func parse(tags: [String], source: String? = nil) -> Facets {
        var byKey: [String: [String]] = [:]
        var freeform: [String] = []
        for tag in tags {
            if let separator = tag.firstIndex(of: ":"), separator != tag.startIndex {
                let key = tag[..<separator].lowercased()
                let value = String(tag[tag.index(after: separator)...])
                if !value.isEmpty {
                    byKey[key, default: []].append(value)
                    continue
                }
            }
            freeform.append(tag)
        }
        if let source, !source.trimmingCharacters(in: .whitespaces).isEmpty {
            let origin = source.trimmingCharacters(in: .whitespaces).lowercased()
            var projects = byKey[FacetKey.project.rawValue] ?? []
            if !projects.contains(where: { $0.caseInsensitiveCompare(origin) == .orderedSame }) {
                projects.insert(origin, at: 0)
            }
            byKey[FacetKey.project.rawValue] = projects
        }
        return Facets(byKey: byKey, freeform: freeform)
    }
}

public extension Memory {
    /// This memory's tags parsed into facets, with `source` folded into `project`.
    var facets: Facets { Facets.parse(tags: tags, source: source) }
}
