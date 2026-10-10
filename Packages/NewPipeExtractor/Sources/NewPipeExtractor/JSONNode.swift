import Foundation

/// Accès tolérant à un arbre JSON non typé (les réponses InnerTube changent souvent de forme).
public struct JSONNode: @unchecked Sendable {
    public let raw: Any?

    public init(_ raw: Any?) { self.raw = raw }

    public init(data: Data) throws {
        self.raw = try JSONSerialization.jsonObject(with: data)
    }

    public subscript(key: String) -> JSONNode {
        JSONNode((raw as? [String: Any])?[key])
    }

    public subscript(index: Int) -> JSONNode {
        guard let array = raw as? [Any], array.indices.contains(index) else { return JSONNode(nil) }
        return JSONNode(array[index])
    }

    /// Suit un chemin "a.b.0.c".
    public func path(_ path: String) -> JSONNode {
        path.split(separator: ".").reduce(self) { node, part in
            if let i = Int(part) { return node[i] }
            return node[String(part)]
        }
    }

    public var exists: Bool { raw != nil && !(raw is NSNull) }
    public var dict: [String: Any]? { raw as? [String: Any] }
    public var array: [JSONNode] { (raw as? [Any])?.map(JSONNode.init) ?? [] }
    public var last: JSONNode { array.last ?? JSONNode(nil) }
    public var bool: Bool? { raw as? Bool }

    public var string: String? {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    public var int: Int? {
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    /// Texte YouTube : `{simpleText}`, `{runs:[{text}]}` ou `{content}`.
    public var text: String? {
        if let s = raw as? String { return s }
        if let s = self["simpleText"].string { return s }
        let runs = self["runs"].array
        if !runs.isEmpty { return runs.compactMap { $0["text"].string }.joined() }
        if let s = self["content"].string { return s }
        return nil
    }

    /// Parcours en profondeur, dans l'ordre du document, de tous les objets portant une des clés données.
    /// On ne descend pas dans un élément trouvé (évite les doublons imbriqués).
    public func collect(_ keys: Set<String>) -> [(key: String, node: JSONNode)] {
        var result: [(String, JSONNode)] = []
        func walk(_ value: Any) {
            if let d = value as? [String: Any] {
                for (k, v) in d where keys.contains(k) {
                    result.append((k, JSONNode(v)))
                }
                for (k, v) in d where !keys.contains(k) {
                    walk(v)
                }
            } else if let a = value as? [Any] {
                for v in a { walk(v) }
            }
        }
        if let raw { walk(raw) }
        return result
    }

    /// Première valeur trouvée pour une clé, n'importe où dans l'arbre.
    public func first(_ key: String) -> JSONNode {
        collect([key]).first?.node ?? JSONNode(nil)
    }

    /// Toutes les chaînes de l'arbre associées à une clé donnée.
    public func strings(forKey key: String) -> [String] {
        collect([key]).compactMap { $0.node.string ?? $0.node.text }
    }
}
