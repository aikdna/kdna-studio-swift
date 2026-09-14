import Foundation
import KDNACore

enum StudioEvidence {
    static func export(state: KDNAValue, compiled: StudioCompiledArtifact,
                       finalDecision: KDNAValue) throws -> KDNAStudioExport {
        let base: KDNAValue = [
            "kind": "studio-blank-material-evidence", "session_id": state["session_id"],
            "synthetic_fixture": state["synthetic_fixture"], "agent": state["agent"], "compiler": state["compiler"],
            "revision": state["revision"], "materials": state["materials"], "candidates": state["candidates"],
            "human_messages": state["human_messages"], "history": state["history"], "final_decision": finalDecision,
            "artifact": ["digest": compiled.assetDigest, "bytes": .number(Double(compiled.bytes.count))],
            "creation": ["requiredness": "satisfied", "accepted": "not_evaluated"],
            "confirmation": "claimed_unverified", "identity": "not_verified",
            "read_permission": "not_evaluated", "action_authorization": "not_evaluated",
        ]
        // The Studio-owned shared format supplies the explicit contract and
        // actual provider coordinates. No Swift field is labelled as JS execution.
        let evidence = StudioEvidenceMetadata.decorate(base, digests: compiled.digests)
        let binding: KDNAValue = [
            "session_id": state["session_id"], "asset_digest": compiled.assetDigest,
            "evidence_digest": .string(try StudioValues.digest(evidence)),
        ]
        return KDNAStudioExport(bytes: compiled.bytes, evidence: evidence, binding: binding,
                                verification: verify(bytes: compiled.bytes, evidence: evidence, expectedBinding: binding))
    }

    static func verify(bytes: Data, evidence: KDNAValue?, expectedBinding: KDNAValue?) -> KDNAValue {
        func reject(_ reason: String, _ core: String = "valid") -> KDNAValue {
            ["status": "inconsistent", "reason": .string(reason), "core": .string(core),
             "creation_accepted": "not_evaluated", "confirmation": "not_evaluated",
             "identity": "not_verified", "action_authorization": "not_evaluated"]
        }
        let admission = KDNACore.admitBytes(bytes)
        guard let snapshot = admission.snapshot else { return reject(admission.result["reason"].text, "invalid") }
        guard let evidence, evidence != .null, let binding = expectedBinding, binding != .null else {
            return reject("CREATION_EVIDENCE_REQUIRED")
        }
        do {
            let legacy = !evidence.has("format")
            if let reason = try StudioEvidenceMetadata.preflight(evidence) { return reject(reason) }
            try StudioValues.record(binding, fields: ["session_id", "asset_digest", "evidence_digest"])
            let view = snapshot.inspect(), assetDigest = view["digests"]["A"]["observed"]
            guard evidence["session_id"] == binding["session_id"], assetDigest == binding["asset_digest"],
                  .string(try StudioValues.digest(evidence, legacy: legacy)) == binding["evidence_digest"],
                  evidence["artifact"]["digest"] == assetDigest,
                  evidence["artifact"]["bytes"] == .number(Double(bytes.count)) else {
                return reject("CREATION_BINDING_MISMATCH")
            }
            guard evidence["kind"] == "studio-blank-material-evidence", !evidence["materials"].list.isEmpty,
                  StudioValues.truthy(evidence["agent"]["name"]), StudioValues.truthy(evidence["agent"]["version"]),
                  StudioValues.truthy(evidence["compiler"]["name"]), StudioValues.truthy(evidence["compiler"]["version"]),
                  let candidates = StudioValues.array(evidence["candidates"]),
                  let messages = StudioValues.array(evidence["human_messages"]),
                  let history = StudioValues.array(evidence["history"]) else {
                return reject("CREATION_PREMISE_MISSING")
            }
            // Legacy interpretation and the shared current representation are
            // selected by the common format adapter, never by loading providers.
            if let reason = try StudioEvidenceMetadata.validate(evidence, digests: view["digests"]) {
                return reject(reason)
            }
            let materials = evidence["materials"].list
            for material in materials {
                guard StudioValues.truthy(material["coordinate"]), case .string(let content) = material["content"],
                      !content.isEmpty, .string(StudioValues.sha256(Data(content.utf8))) == material["content_hash"] else {
                    return reject("MATERIAL_DIGEST_MISMATCH")
                }
            }
            let materialIDs = materials.map { $0["id"] }
            guard distinct(materialIDs), candidates.contains(where: { $0["status"] == "selected" }),
                  candidates.allSatisfy({ item in
                      (item["status"] == "selected" || item["status"] == "rejected") &&
                      !item["material_refs"].list.isEmpty && item["material_refs"].list.allSatisfy { materialIDs.contains($0) }
                  }) else { return reject("CREATION_REVIEW_INCOMPLETE") }
            var previous: KDNAValue = .null
            for (index, original) in history.enumerated() {
                var entry = original
                let stored = entry["digest"]
                entry.remove("digest")
                guard entry["sequence"] == .number(Double(index + 1)), entry["previous_digest"] == previous,
                      .string(try StudioValues.digest(entry, legacy: legacy)) == stored else {
                    return reject("CREATION_AUDIT_CHAIN_MISMATCH")
                }
                previous = stored
            }
            guard distinct(messages.map { $0["id"] }) else { return reject("HUMAN_MESSAGE_REPLAY") }
            let decision = evidence["final_decision"]
            guard decision != .null,
                  let message = messages.first(where: { $0["id"] == decision["message_id"] }),
                  let preview = history.last(where: { $0["event"] == "compiler_preview" }),
                  let final = history.last(where: { $0["event"] == "human_final_decision" }),
                  message["role"] == "human", message["interpretation"]["kind"] == "confirm",
                  message["text"] == decision["text"], message["channel"] == decision["channel"],
                  message["review_id"] == decision["review_id"], message["review"]["review_id"] == decision["review_id"],
                  message["review"]["compiled"]["artifact_digest"] == assetDigest,
                  decision["session_id"] == evidence["session_id"], decision["artifact_digest"] == assetDigest,
                  decision["revision"] == evidence["revision"], preview["detail"]["artifact_digest"] == assetDigest,
                  preview["revision"] == evidence["revision"],
                  try StudioValues.digest(final["detail"], legacy: legacy) == StudioValues.digest(decision, legacy: legacy),
                  final["sequence"].numeric > preview["sequence"].numeric else {
                return reject("FINAL_DECISION_UNBOUND")
            }
            guard evidence["confirmation"] == "claimed_unverified", evidence["creation"]["accepted"] == "not_evaluated",
                  evidence["identity"] == "not_verified", evidence["action_authorization"] == "not_evaluated" else {
                return reject("AUTHORITY_CLAIM_UNSUPPORTED")
            }
            let result: KDNAValue = [
                "status": "consistent", "core": "valid", "requiredness": "satisfied",
                "creation_accepted": "not_evaluated", "confirmation": "claimed_unverified",
                "identity": "not_verified", "read_permission": "not_evaluated", "action_authorization": "not_evaluated",
                "asset_digest": assetDigest, "evidence_digest": binding["evidence_digest"],
            ]
            return StudioEvidenceMetadata.describeProviderStatus(result, evidence: evidence)
        } catch { return reject("CREATION_EVIDENCE_MALFORMED") }
    }

    private static func distinct(_ values: [KDNAValue]) -> Bool {
        for (index, value) in values.enumerated() where values[..<index].contains(value) { return false }
        return true
    }
}
