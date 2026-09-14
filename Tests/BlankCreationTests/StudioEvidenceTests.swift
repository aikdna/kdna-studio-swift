import XCTest
import Foundation
import KDNACore
@testable import KDNAStudioCore

final class StudioEvidenceTests: XCTestCase {
    func testPinnedSharedCanonicalVectorsAndDomainLimits() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "canonical-vectors", withExtension: "json"))
        let vectors = try KDNAJSON.parse(Data(contentsOf: url))
        for vector in vectors["vectors"].list {
            var input = vector["input"]
            if vector["name"] == "numbers" {
                input = .array(try vectors["number_bits"].list.map { bits in
                    .number(Double(bitPattern: try XCTUnwrap(UInt64(bits.text, radix: 16))))
                })
            }
            let bytes = try StudioValues.canonicalEvidence(input)
            XCTAssertEqual(bytes.map { String(format: "%02x", $0) }.joined(), vector["utf8_hex"].text, vector["name"].text)
            XCTAssertEqual(StudioValues.sha256(bytes), "sha256:" + vector["sha256"].text, vector["name"].text)
        }
        XCTAssertThrowsError(try StudioValues.canonicalEvidence(.number(.nan)))
        var deep: KDNAValue = .null
        for _ in 0..<65 { deep = [deep] }
        XCTAssertThrowsError(try StudioValues.canonicalEvidence(deep))
        XCTAssertNoThrow(try StudioValues.canonicalEvidence(deep, legacy: true))
        XCTAssertThrowsError(try StudioValues.canonicalEvidence(.array(Array(repeating: .null, count: 100000))))
        XCTAssertNoThrow(try StudioValues.canonicalEvidence(.array(Array(repeating: .null, count: 10001))))
    }

    func testPrivateBindingMaterialAuditAndFinalRejectIndependently() async throws {
        let exported = try await makeExport()
        var evidence = exported.evidence
        evidence["materials"] = .array(evidence["materials"].list.map { material in
            var item = material; item["content"] = "tampered private source"; return item
        })
        XCTAssertEqual(try verify(exported, evidence, rebind: false)["reason"], "CREATION_BINDING_MISMATCH")
        XCTAssertEqual(try verify(exported, evidence, rebind: true)["reason"], "MATERIAL_DIGEST_MISMATCH")

        evidence = exported.evidence
        var history = evidence["history"].list
        history[0]["digest"] = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
        evidence["history"] = .array(history)
        XCTAssertEqual(try verify(exported, evidence, rebind: true)["reason"], "CREATION_AUDIT_CHAIN_MISMATCH")

        evidence = exported.evidence
        evidence["final_decision"]["artifact_digest"] = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
        XCTAssertEqual(try verify(exported, evidence, rebind: true)["reason"], "FINAL_DECISION_UNBOUND")
        evidence = exported.evidence
        evidence["identity"] = "verified"
        XCTAssertEqual(try verify(exported, evidence, rebind: true)["reason"], "AUTHORITY_CLAIM_UNSUPPORTED")
    }

    func testFormatContractProviderAndNumericFailuresDoNotSelectCode() async throws {
        let exported = try await makeExport()
        XCTAssertEqual(exported.verification["provider_assertion"], "declared_not_authenticated")
        XCTAssertEqual(exported.verification["implementation_artifact_sha256"], StudioEvidenceMetadata.implementations["swift"]["artifact"]["sha256"])
        XCTAssertEqual(exported.verification["compiler_artifact_sha256"], "UNKNOWN")
        XCTAssertEqual(exported.verification["reference_contract"], "declared_supported_exact")
        var evidence = exported.evidence
        evidence["format"] = "unknown-format"
        XCTAssertEqual(try verify(exported, evidence, rebind: false)["reason"], "CREATION_EVIDENCE_FORMAT_UNSUPPORTED")
        evidence = exported.evidence
        evidence["core"]["reference_contract"]["core"]["artifact_sha256"] = "02b766"
        XCTAssertEqual(try verify(exported, evidence, rebind: true)["reason"], "CREATION_CORE_CONTRACT_UNSUPPORTED")
        evidence = exported.evidence
        evidence["core"]["implementation"]["provider"] = "file:///outside/module"
        XCTAssertEqual(try verify(exported, evidence, rebind: true)["reason"], "CREATION_PROVIDER_DECLARATION_UNSUPPORTED")
        evidence = exported.evidence
        evidence["compiler"]["provider"] = "javascript"
        XCTAssertEqual(try verify(exported, evidence, rebind: true)["reason"], "CREATION_PROVIDER_DECLARATION_UNSUPPORTED")
        evidence = exported.evidence
        evidence["core"]["package"] = "@aikdna/kdna-core"
        XCTAssertEqual(try verify(exported, evidence, rebind: true)["reason"], "CREATION_EVIDENCE_FORMAT_AMBIGUOUS")
        evidence = exported.evidence
        evidence["revision"] = "5"
        XCTAssertEqual(try verify(exported, evidence, rebind: false)["reason"], "CREATION_EVIDENCE_MALFORMED")
        evidence = exported.evidence
        evidence["agent"]["extra_numeric"] = 1.5
        XCTAssertEqual(try verify(exported, evidence, rebind: false)["reason"], "CREATION_EVIDENCE_MALFORMED")
        evidence = exported.evidence
        evidence["unexpected"] = true
        XCTAssertEqual(try verify(exported, evidence, rebind: false)["reason"], "CREATION_EVIDENCE_MALFORMED")
    }

    private func makeExport() async throws -> KDNAStudioExport {
        let script = HumanScript(), session = try studioSession(script)
        _ = try await prepareCandidate(session)
        _ = try await session.receiveHumanReply()
        _ = try await session.agent.compilePreview()
        await script.plan("confirm")
        _ = try await session.receiveHumanReply()
        return try await session.exportAsset()
    }

    // Rebinding is deliberate adversarial test setup, never a claim that an
    // attacker can replace the caller's trusted expectedBinding in production.
    private func verify(_ exported: KDNAStudioExport, _ evidence: KDNAValue, rebind: Bool) throws -> KDNAValue {
        var binding = exported.binding
        if rebind { binding["evidence_digest"] = .string(try StudioValues.digest(evidence)) }
        return KDNAStudio.verifyCreationEvidence(bytes: exported.bytes, evidence: evidence, expectedBinding: binding)
    }
}
