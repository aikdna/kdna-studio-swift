import Foundation
import KDNACore

// Stable authored identity follows the one Studio materialization rule. Core
// treats these IDs as opaque and independently checks actual relationships.
enum CreationIdentity {
    static let materializationRule = "kdna.studio-materialization/2"

    static func mint(_ kind: String, assetID: String, judgmentKey: String, additionalKeys: [String] = []) throws -> String {
        let input = [materializationRule, kind, assetID, judgmentKey] + additionalKeys
        let digest = try CreationValues.digest(.array(input.map(KDNAValue.string)))
        return kind + ":" + String(digest.dropFirst("sha256:".count))
    }

    static func freshAsset() -> KDNAValue {
        ["asset_id": .string(CreationValues.uuid("asset:")),
         "asset_uid": .string(CreationValues.uuid("urn:uuid:"))]
    }

    static func versioned(_ identity: KDNAValue, revision: Int) throws -> KDNAValue {
        guard revision >= 0, revision <= 9007199254740991 else {
            throw CreationValues.fail("STUDIO_REVISION_INVALID", "Revision must be an exact bounded nonnegative integer.")
        }
        var result = identity
        result["version"] = .string("0.1." + String(revision))
        return result
    }
}
