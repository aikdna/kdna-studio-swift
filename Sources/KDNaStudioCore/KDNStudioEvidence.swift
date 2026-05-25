//  KDNaStudioCore — Evidence import

import Foundation
import CryptoKit

public class KDNStudioEvidence {

    public static func createEntry(type: String, title: String, content: String, source: String = "manual") -> KDNEvidenceEntry {
        let hash = SHA256.hash(data: Data((content).utf8))
        return KDNEvidenceEntry(
            id: "ev_\(UUID().uuidString)",
            type: type,
            title: title,
            contentHash: "sha256:\(hash.compactMap { String(format: "%02x", $0) }.joined())",
            source: source,
            importedAt: ISO8601DateFormatter().string(from: Date()),
            spans: [],
            content: (type == "text" || type == "chat") ? content : nil
        )
    }

    @discardableResult
    public static func addEvidence(_ project: inout KDNStudioProject, _ entry: KDNEvidenceEntry) -> KDNStudioProject {
        project.evidence.append(entry)
        project.stages.evidenceRoom = .inProgress(count: project.evidence.count)
        return project
    }

    public static func linkEvidenceToCard(_ card: inout KDNJudgmentCard, evidenceId: String, spanId: String) {
        let ref = "\(evidenceId):\(spanId)"
        if !card.evidenceRefs.contains(ref) {
            card.evidenceRefs.append(ref)
        }
    }
}
