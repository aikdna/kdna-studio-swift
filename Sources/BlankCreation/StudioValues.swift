import Foundation
import CryptoKit
import KDNACore

public struct KDNAStudioFailure: Error, CustomStringConvertible {
    public let code: String
    public let message: String
    public var description: String { "\(code): \(message)" }

    init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

// JSON values are copied across the public boundary. This module does not
// define a public Core parser, validator, snapshot or digest domain.
enum StudioValues {
    static func fail(_ code: String, _ message: String) -> KDNAStudioFailure {
        KDNAStudioFailure(code, message)
    }

    static func record(_ value: KDNAValue, fields: [String]) throws {
        guard case .object(let object) = value else {
            throw fail("INPUT_INVALID", "Expected an input record.")
        }
        let allowed = Set(fields.map { KDNAKey($0) })
        guard object.keys.allSatisfy({ allowed.contains($0) }) else {
            throw fail("INPUT_FIELD_FORBIDDEN", "Unknown input field; asset identity and versions are compiler managed.")
        }
    }

    static func text(_ value: KDNAValue, _ label: String) throws -> String {
        guard case .string(let string) = value,
              string.utf8.count <= 1024 * 1024,
              string.unicodeScalars.contains(where: { !isECMAScriptWhitespace($0.value) }) else {
            throw fail("INPUT_INVALID", "\(label) requires nonempty Unicode text.")
        }
        return string
    }

    // Match the reference requiredText().trim() predicate, rather than a
    // locale/Foundation whitespace set (notably U+FEFF versus U+0085).
    private static func isECMAScriptWhitespace(_ value: UInt32) -> Bool {
        switch value {
        case 0x0009...0x000D, 0x0020, 0x00A0, 0x1680,
             0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F,
             0x3000, 0xFEFF: return true
        default: return false
        }
    }

    static func sameText(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    static func truthy(_ value: KDNAValue) -> Bool {
        switch value {
        case .null: return false
        case .bool(let x): return x
        case .number(let x): return x != 0 && !x.isNaN
        case .string(let x): return !x.isEmpty
        case .array, .object: return true
        }
    }

    static func array(_ value: KDNAValue) -> [KDNAValue]? {
        if case .array(let values) = value { return values }
        return nil
    }

    static func now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    static func uuid(_ prefix: String) -> String {
        prefix + UUID().uuidString.lowercased()
    }

    static func sha256(_ bytes: Data) -> String {
        "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    // Studio-private stableStringify representation. The common new format
    // owns its depth/value limits; the explicit legacy path keeps the old
    // traversal domain. Core supplies only finite-number leaf spelling.
    static func canonicalEvidence(_ value: KDNAValue, legacy: Bool = false) throws -> Data {
        var count = 0
        func quote(_ string: String) -> String {
            var encoded = "\""
            for scalar in string.unicodeScalars {
                switch scalar.value {
                case 34: encoded += "\\\""
                case 92: encoded += "\\\\"
                case 8: encoded += "\\b"
                case 9: encoded += "\\t"
                case 10: encoded += "\\n"
                case 12: encoded += "\\f"
                case 13: encoded += "\\r"
                case 0...31: encoded += String(format: "\\u%04x", scalar.value)
                default: encoded.unicodeScalars.append(scalar)
                }
            }
            return encoded + "\""
        }
        func encode(_ value: KDNAValue, _ depth: Int) throws -> String {
            count += 1
            guard legacy || (depth <= 64 && count <= 100000) else {
                throw fail("CREATION_EVIDENCE_MALFORMED", "Studio evidence exceeds the shared JSON depth/value limit.")
            }
            switch value {
            case .array(let values):
                return "[" + (try values.map { try encode($0, depth + 1) }).joined(separator: ",") + "]"
            case .object(let fields):
                let keys = fields.keys.sorted { $0.text.utf16.lexicographicallyPrecedes($1.text.utf16) }
                return "{" + (try keys.map { key in
                    quote(key.text) + ":" + (try encode(fields[key]!, depth + 1))
                }).joined(separator: ",") + "}"
            case .string(let text): return quote(text)
            default:
                return String(decoding: try KDNAJSON.canonical(value), as: UTF8.self)
            }
        }
        return Data(try encode(value, 0).utf8)
    }

    static func digest(_ value: KDNAValue, legacy: Bool = false) throws -> String {
        sha256(try canonicalEvidence(value, legacy: legacy))
    }

    static func appendHistory(_ state: inout KDNAValue, event: String, detail: KDNAValue) throws {
        var history = state["history"].list
        var entry: KDNAValue = [
            "sequence": .number(Double(history.count + 1)),
            "revision": state["revision"], "event": .string(event),
            "at": .string(now()), "detail": detail,
            "previous_digest": history.last?["digest"] ?? .null,
        ]
        entry["digest"] = .string(try digest(entry))
        history.append(entry)
        state["history"] = .array(history)
    }

    static func material(_ input: KDNAValue) throws -> KDNAValue {
        try record(input, fields: ["kind", "title", "content", "coordinate"])
        guard input["kind"] == "text" || input["kind"] == "interview" else {
            throw fail("MATERIAL_KIND_UNSUPPORTED", "Blank creation accepts text or interview material, never an existing asset.")
        }
        let content = try text(input["content"], "material.content")
        return [
            "id": .string(uuid("ev_")), "type": input["kind"],
            "title": .string(try text(input["title"], "material.title")),
            "content": .string(content),
            "coordinate": .string(try text(input["coordinate"], "material.coordinate")),
            "content_hash": .string(sha256(Data(content.utf8))),
            "imported_at": .string(now()),
        ]
    }
}
