//  KDNAStudioCore — Provenance builder
//
//  Builds provenance-report.json metadata for compiled .kdna assets.
//  Aligned with @aikdna/kdna-studio-core/src/provenance/index.js

import Foundation

public class KDNStudioProvenance {

    /// Build provenance metadata for a compiled project.
    public static func build(
        project: KDNStudioProject,
        identity: (buildId: String, projectUID: String, assetUID: String, domainId: String, compiledAt: String)? = nil,
        contentDigest: String? = nil
    ) -> [String: Any] {
        let lockedCards = project.cards.filter { $0.locked }
        let bid = identity?.buildId ?? "build_\(UUID().uuidString.lowercased())"
        let compiledAt = identity?.compiledAt ?? ISO8601DateFormatter().string(from: Date())

        var lineageInfo: [String: Any] = ["type": "original"]
        if let lin = project.lineage {
            lineageInfo["type"] = lin.type
            if let pn = lin.parentName { lineageInfo["parent_name"] = pn }
            if let pu = lin.parentAssetUID { lineageInfo["parent_asset_uid"] = pu }
            if let pv = lin.parentVersion { lineageInfo["parent_version"] = pv }
            if let pd = lin.parentAssetDigest { lineageInfo["parent_asset_digest"] = pd }
        }

        return [
            "studio_core": "aikdna/kdna-studio-swift",
            "studio_core_version": "0.2.0",
            "created_by": "kdna-studio-sdk",
            "compiler": "kdna-studio-swift",
            "compiler_version": "0.2.0",
            "build_id": bid,
            "project_id": project.projectId,
            "project_uid": identity?.projectUID as Any,
            "asset_uid": identity?.assetUID as Any,
            "domain_id": identity?.domainId as Any,
            "registry_name": project.name,
            "author_id": project.author.id,
            "creator_id": project.creatorIdentity?.creatorId as Any,
            "source_mode": project.sourceMode.rawValue,
            "lineage": lineageInfo,
            "locked_card_count": lockedCards.count,
            "test_case_count": project.tests.count,
            "built_at": compiledAt,
            "compiled_at": compiledAt,
            "content_fingerprint": contentDigest ?? "",
            "content_digest": contentDigest ?? "",
        ]
    }
}
