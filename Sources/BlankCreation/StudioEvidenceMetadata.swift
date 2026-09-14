import Foundation
import KDNACore

// Mechanical coordinates from the Studio-owned FORMAT.json, SHA-256
// 49eda6ab9e63713d2439a84648ae9c9e9098cdb5d3780dbf7ac59083ad789d05.
// A declaration is digest-bound metadata, never a provider loader or identity proof.
enum StudioEvidenceMetadata {
    static let format: KDNAValue = "kdna.studio-creation-evidence/1"
    static let compiler: KDNAValue = [
        "name": "KDNAStudioCore", "version": "0.5.0-rc.public-creation.1", "provider": "swift", "artifact_sha256": "UNKNOWN",
    ]
    static let reference: KDNAValue = [
        "core": ["package": "@aikdna/kdna-core", "version": "0.23.0", "artifact_sha256": "b2cecb761e599d8711114d7288d6caf627b1aa01620699ecb1fca49ac3bb6ba0"],
        "read": ["package": "@aikdna/kdna-read", "version": "0.2.0", "artifact_sha256": "1595075677dc1359c2df751ec54a706b55ffff6bfc77d117e16464fb16a5c96e"],
        "tuple": ["container": "0.2.0", "core": "kdna.core/0.2.0", "host": "kdna.agent-host/0.2.0",
                  "ir": "kdna.canonical-ir/0.1.0", "payload_profile": "kdna.payload.judgment", "payload_version": "0.2.0",
                  "plan": "kdna.consumption-plan/0.2.0", "read": "kdna.read/0.1.0",
                  "runtime": "kdna.runtime-capsule/0.2.0", "trace": "kdna.judgment-trace/0.2.0"],
    ]
    static let implementations: KDNAValue = [
        "javascript": ["provider": "javascript", "name": "@aikdna/kdna-core", "version": "0.23.0",
                       "artifact": ["kind": "npm-tgz", "sha256": "b2cecb761e599d8711114d7288d6caf627b1aa01620699ecb1fca49ac3bb6ba0"]],
        "swift": ["provider": "swift", "name": "KDNACore", "version": "0.3.1",
                  "artifact": ["kind": "source-tar-gz", "sha256": "fc0bbb87af1b418aeea3700a0d63e72fbec3af692838e1eefa68d77359c981a3"]],
    ]

    static func decorate(_ base: KDNAValue, digests: KDNAValue) -> KDNAValue {
        var result = base
        result["format"] = format
        result["core"] = ["status": "valid", "reference_contract": reference,
                          "implementation": implementations["swift"], "digests": digests]
        return result
    }

    static func preflight(_ evidence: KDNAValue) throws -> String? {
        guard evidence.has("format") else { return nil }
        guard evidence["format"] == format else { return "CREATION_EVIDENCE_FORMAT_UNSUPPORTED" }
        _ = try StudioValues.canonicalEvidence(evidence)
        let fields = ["format", "kind", "session_id", "synthetic_fixture", "agent", "compiler", "revision", "materials",
                      "candidates", "human_messages", "history", "final_decision", "artifact", "core", "creation", "confirmation",
                      "identity", "read_permission", "action_authorization"]
        guard exactKeys(evidence, fields),
              exactKeys(evidence["compiler"], ["name", "version", "provider", "artifact_sha256"]),
              isText(evidence["compiler"]["name"]), isText(evidence["compiler"]["version"]),
              isText(evidence["compiler"]["provider"]),
              evidence["compiler"]["artifact_sha256"] == "UNKNOWN" || isPin(evidence["compiler"]["artifact_sha256"]),
              exactKeys(evidence["artifact"], ["digest", "bytes"]),
              safeInteger(evidence["revision"]), safeInteger(evidence["artifact"]["bytes"]),
              safeInteger(evidence["final_decision"]["revision"]) else { return "CREATION_EVIDENCE_MALFORMED" }
        // Mixed Core shapes are deliberately diagnosed after the original
        // trusted-binding comparison, per the common verifier order.
        let core = evidence["core"]
        let allowedCoreKeys = Set(["status", "reference_contract", "implementation", "digests", "package", "version"].map { KDNAKey($0) })
        guard case .object(let coreFields) = core, coreFields.keys.allSatisfy({ allowedCoreKeys.contains($0) }) else {
            return "CREATION_EVIDENCE_MALFORMED"
        }
        if !core.has("package") && !core.has("version") {
            guard exactKeys(core, ["status", "reference_contract", "implementation", "digests"]),
                  exactKeys(core["implementation"], ["provider", "name", "version", "artifact"]),
                  exactKeys(core["implementation"]["artifact"], ["kind", "sha256"]) else {
                return "CREATION_EVIDENCE_MALFORMED"
            }
        }
        guard validNumbers(evidence), let candidates = StudioValues.array(evidence["candidates"]),
              candidates.allSatisfy({ safeInteger($0["revision"]) }),
              let messages = StudioValues.array(evidence["human_messages"]),
              messages.allSatisfy(validMessageNumbers),
              let history = StudioValues.array(evidence["history"]) else { return "CREATION_EVIDENCE_MALFORMED" }
        for entry in history {
            guard safeInteger(entry["sequence"]), safeInteger(entry["revision"]) else { return "CREATION_EVIDENCE_MALFORMED" }
            let detail = entry["detail"]
            switch entry["event"] {
            case "candidate_proposed", "compiler_preview", "human_final_decision":
                if !safeInteger(detail["revision"]) { return "CREATION_EVIDENCE_MALFORMED" }
            case "candidate_revised":
                if !safeInteger(detail["previous"]["revision"]) || !safeInteger(detail["replacement"]["revision"]) { return "CREATION_EVIDENCE_MALFORMED" }
            case "human_reply":
                if !validMessageNumbers(detail) { return "CREATION_EVIDENCE_MALFORMED" }
            default: break
            }
        }
        return nil
    }

    static func validate(_ evidence: KDNAValue, digests: KDNAValue) throws -> String? {
        let core = evidence["core"]
        if !evidence.has("format") {
            if core.has("reference_contract") || core.has("implementation") || core.has("provider") ||
                evidence["compiler"].has("provider") || evidence["compiler"].has("artifact_sha256") {
                return "CREATION_EVIDENCE_FORMAT_AMBIGUOUS"
            }
            guard core["status"] == "valid", core["package"] == "@aikdna/kdna-core", core["version"] == "0.23.0",
                  try StudioValues.digest(core["digests"], legacy: true) == StudioValues.digest(digests, legacy: true) else {
                return "CREATION_CORE_EVIDENCE_MISMATCH"
            }
        } else {
            if core.has("package") || core.has("version") { return "CREATION_EVIDENCE_FORMAT_AMBIGUOUS" }
            guard core["reference_contract"] == reference else { return "CREATION_CORE_CONTRACT_UNSUPPORTED" }
            let provider = core["implementation"]["provider"]
            guard provider == "swift" || provider == "javascript",
                  core["implementation"] == implementations[provider.text], evidence["compiler"]["provider"] == provider else {
                return "CREATION_PROVIDER_DECLARATION_UNSUPPORTED"
            }
            guard evidence["history"].list.filter({ $0["event"] == "compiler_preview" }).allSatisfy({
                $0["detail"]["compiler"] == evidence["compiler"]
            }) else { return "CREATION_PROVIDER_DECLARATION_UNSUPPORTED" }
            guard core["status"] == "valid", try StudioValues.digest(core["digests"]) == StudioValues.digest(digests) else {
                return "CREATION_CORE_EVIDENCE_MISMATCH"
            }
        }
        return nil
    }

    static func describeProviderStatus(_ base: KDNAValue, evidence: KDNAValue) -> KDNAValue {
        let legacy = !evidence.has("format")
        var result = base
        result["evidence_format"] = legacy ? "studio-blank-material-evidence/legacy" : format
        result["provider_assertion"] = "declared_not_authenticated"
        result["implementation_artifact_sha256"] = legacy ? "UNKNOWN" : evidence["core"]["implementation"]["artifact"]["sha256"]
        result["compiler_artifact_sha256"] = legacy ? "UNKNOWN" : evidence["compiler"]["artifact_sha256"]
        result["reference_contract"] = legacy ? "UNKNOWN" : "declared_supported_exact"
        return result
    }

    private static func exactKeys(_ value: KDNAValue, _ keys: [String]) -> Bool {
        guard case .object(let object) = value else { return false }
        return Set(object.keys) == Set(keys.map { KDNAKey($0) })
    }
    private static func safeInteger(_ value: KDNAValue) -> Bool {
        guard case .number(let number) = value else { return false }
        return number.isFinite && number >= 0 && number <= 9007199254740991 && number.rounded() == number
    }
    private static func isText(_ value: KDNAValue) -> Bool {
        guard case .string(let text) = value else { return false }
        return !text.isEmpty
    }
    private static func isPin(_ value: KDNAValue) -> Bool {
        guard case .string(let text) = value else { return false }
        return text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func validNumbers(_ value: KDNAValue) -> Bool {
        switch value {
        case .number: return safeInteger(value)
        case .array(let values): return values.allSatisfy(validNumbers)
        case .object(let fields):
            return fields.allSatisfy { key, item in
                (!["revision", "sequence", "bytes"].contains(key.text) || safeInteger(item)) && validNumbers(item)
            }
        default: return true
        }
    }
    private static func validMessageNumbers(_ message: KDNAValue) -> Bool {
        let review = message["review"]
        guard safeInteger(message["revision"]), safeInteger(review["revision"]),
              let candidates = StudioValues.array(review["candidates"]),
              candidates.allSatisfy({ safeInteger($0["revision"]) }) else { return false }
        return review["compiled"] == .null || safeInteger(review["compiled"]["revision"])
    }
}
