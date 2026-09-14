import Foundation
import XCTest
import KDNACore
@testable import KDNAStudioCore

private actor SyntheticReplies {
    var kinds: [String]
    var count = 0
    let replay: Bool
    init(_ kinds: [String] = ["select", "confirm"], replay: Bool = false) { self.kinds = kinds; self.replay = replay }
    func receive(_ review: KDNAValue) throws -> KDNAValue {
        count += 1
        let kind = kinds.isEmpty ? "confirm" : kinds.removeFirst()
        var intent: KDNAValue = ["kind": .string(kind)]
        if kind == "select" {
            intent["choices"] = .array(review["groups"].list.map {
                ["judgmentLocalKey": $0["localKey"], "alternativeLocalKey": $0["alternatives"].list[0]["localKey"]]
            })
        }
        return ["id": .string(replay ? "reply:reused" : "reply:\(count)"),
                "role": review["kind"] == "delegated_agent_editorial" ? "agent" : "human",
                "channel": review["channel"], "review_id": review["review_id"],
                "text": .string(String(decoding: try KDNAJSON.canonical(intent), as: UTF8.self))]
    }
}
private final class CompilerProbe { var calls = 0; var changedBytes: Data? }

private actor PausedReply {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var replyWaiter: CheckedContinuation<KDNAValue, Error>?
    private var review: KDNAValue = .null
    func receive(_ value: KDNAValue) async throws -> KDNAValue {
        review = value; entered = true
        entryWaiter?.resume(); entryWaiter = nil
        return try await withCheckedThrowingContinuation { replyWaiter = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func resume() {
        let response: KDNAValue = ["id": "reply:paused", "role": "agent", "channel": review["channel"],
                                  "review_id": review["review_id"], "text": "{\"kind\":\"note\"}"]
        replyWaiter?.resume(returning: response); replyWaiter = nil
    }
}

final class CreationLifecycleTests: XCTestCase {
    private func make(kinds: [String] = ["select", "confirm"], replay: Bool = false,
                      kind: KDNAStudioAdoptionKind = .delegatedAgentEditorial,
                      compiler: ((KDNAValue) throws -> Data)? = nil) throws -> KDNAStudioSession {
        let replies = SyntheticReplies(kinds, replay: replay)
        let adoption = KDNAStudioAdoptionInput(kind: kind, channel: "synthetic-test-input",
            authorization: kind == .delegatedAgentEditorial ? ["coordinate": "synthetic://test-delegation", "statement": "Synthetic fixture execution only; no real Agent or human adoption is claimed."] : nil,
            receive: { try await replies.receive($0) })
        let options: KDNAValue = ["agent": ["name": "native-implementation-synthetic", "version": "1"], "syntheticFixture": true]
        let interpreter: KDNAStudioInterpreter = { text, _ in try KDNAJSON.parse(Data(text.utf8)) }
        if let compiler { return try KDNAStudioSession(options: options, adoptionInput: adoption, interpretReply: interpreter, compiler: compiler) }
        return try KDNAStudio.createSession(options: options, adoptionInput: adoption, interpretReply: interpreter)
    }
    private func method() -> KDNAValue {
        let items: KDNAValue = [["key": "observed", "title": "同名", "meaning": "记录中的观察"], ["key": "hypothesis", "title": "同名", "meaning": "待核实解释"], ["key": "other", "title": "其他", "meaning": "未排除的其他候选"]]
        return ["method": ["term": "comparative-analysis"], "components": [
            ["localKey": "distinguish", "type": "discriminator-set", "content": ["candidateSetLocalKey": "alternatives", "items": [
                ["key": "origin", "title": "证据来源", "prompt": "记录是否包含直接观察？", "contrasts": [
                    ["candidateKey": "observed", "criterion": "具名直接观察"], ["candidateKey": "hypothesis", "criterion": "明确标为假说"]]]]]],
            ["localKey": "alternatives", "type": "candidate-set", "content": ["items": items]],
            ["localKey": "independent", "type": "candidate-set", "statement": "相同类型仍是独立集合。", "content": ["items": items]],
            ["localKey": "hierarchy", "type": "taxonomy", "content": ["items": [
                ["key": "record", "title": "记录", "meaning": "所有输入记录"], ["key": "direct", "title": "直接", "meaning": "直接记录"],
                ["key": "review", "title": "复核", "meaning": "复核记录"], ["key": "shared", "title": "共享", "meaning": "多父级类别"]],
                "broader": [["narrowerKey": "shared", "broaderKey": "direct"], ["narrowerKey": "shared", "broaderKey": "review"], ["narrowerKey": "direct", "broaderKey": "record"], ["narrowerKey": "review", "broaderKey": "record"]]]],
        ], "bindings": [["componentLocalKey": "distinguish", "role": "comparison"], ["componentLocalKey": "distinguish", "role": "review"], ["componentLocalKey": "hierarchy", "role": "classification"]]]
    }
    @discardableResult private func populate(_ session: KDNAStudioSession, mechanism: Bool = false, presenceOnly: Bool = false, formation: Bool = false) async throws -> KDNAValue {
        _ = try await session.agent.setBrief(["title": "Native 创建检查 é / e\u{301}", "scope": "Private fixture scope\nNo authority inferred."])
        let material = try await session.agent.recordMaterial(["kind": "interview", "title": "合成访谈", "content": "观察与假说须分开。\n控制\t字符\u{0001}", "coordinate": "synthetic://native/source"])
        var first: KDNAValue = ["localKey": "keep-open", "title": "保留候选", "subject": "当前记录", "scope": "合成比较", "statement": "证据不足时保留多个解释。", "rationale": "区分依据须明确。", "materialRefs": [material["id"]]]
        if mechanism { first["method"] = method() }
        if presenceOnly { first["method"] = ["method": ["term": "review"]] }
        if formation { first["formationRule"] = ["conditions": [["kind": "interpreted", "statement": "作者明确给出的条件，非候选标准的合取。"]]] }
        if mechanism {
            first["publicSources"] = [["localKey": "publication", "identity": "synthetic-public-source", "version": "1",
                "uses": [["localKey": "judgment-use", "role": "support"], ["localKey": "component-use", "role": "method_component", "componentLocalKey": "distinguish"]]]]
            first["publicNotices"] = [["localKey": "notice", "statement": "显式公开说明；不自动公开私有材料路径。", "sourceLocalKeys": ["publication"]]]
        }
        var second = first; second["localKey"] = "reject-open"; second["statement"] = "仅保留一个解释的不同主张。"
        return try await session.agent.propose(["localKey": "decision", "alternatives": [first, second]])
    }
    private func ready(_ session: KDNAStudioSession) async throws {
        _ = try await session.receiveAdoptionReply(); _ = try await session.agent.compilePreview(); _ = try await session.receiveAdoptionReply()
    }
    private func error(_ expected: String, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual((error as? KDNAStudioFailure)?.code, expected, file: file, line: line) }
    }
    func testRealSaveReadbackAndCompleteThreeTypeInterpretation() async throws {
        let session = try make(); try await populate(session, mechanism: true, formation: true); try await ready(session)
        let exported = try await session.exportAsset()
        XCTAssertEqual(exported.verification["status"], "pending_saved_readback")
        XCTAssertEqual(exported.evidence["expected_component_bindings"].list.count, 4)
        let staticResult = KDNAStudio.verifyCreationEvidence(bytes: exported.bytes, evidence: exported.evidence, expectedBinding: exported.binding)
        XCTAssertEqual(staticResult["status"], "consistent", staticResult["reason"].text)
        XCTAssertEqual(staticResult["creation_accepted"], "not_evaluated")
        XCTAssertEqual(staticResult["live_context"], "unavailable")
        guard let scratch = ProcessInfo.processInfo.environment["TMPDIR"] else { return XCTFail("Own TMPDIR is required") }
        let folder = URL(fileURLWithPath: scratch).appendingPathComponent("creation-save-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = folder.appendingPathComponent("actual.kdna")
        try exported.bytes.write(to: file, options: .withoutOverwriting)
        let captured = try Data(contentsOf: file)
        let saved = try await session.completeSave(captured)
        XCTAssertEqual(saved["status"], "accepted_with_live_context")
        XCTAssertEqual(saved["identity"], "not_verified")
        XCTAssertEqual(saved["action_authorization"], "not_evaluated")
        XCTAssertEqual(saved["filesystem_durability"], "not_proven_by_library")
        let admitted = KDNACore.admitBytes(captured); let view = try XCTUnwrap(admitted.snapshot).inspect()
        let judgment = try XCTUnwrap(view["ir"]["nodes"].list.first { $0["role"] == "judgment" })["value"]
        XCTAssertFalse(judgment.has("result")); XCTAssertEqual(judgment["formation_rule"]["conditions"].list.count, 1)
        let method = try XCTUnwrap(view["ir"]["nodes"].list.first { $0["role"] == "method" })["value"]
        XCTAssertEqual(method["component_interpretations"].list.count, 4)
        XCTAssertEqual(method["component_interpretations"].list.filter { $0["component_type"] == "candidate-set" }.count, 2)
        await error("CREATION_SAVE_STATE_INVALID") { _ = try await session.completeSave(captured) }
        await error("CREATION_FINAL_REQUIRED") { _ = try await session.exportAsset() }
    }
    func testPresenceOnlyNeverInventsAdoptionOrAuthoredEmpty() async throws {
        let session = try make(); try await populate(session, presenceOnly: true); try await ready(session)
        let exported = try await session.exportAsset()
        XCTAssertEqual(exported.evidence["adoption"], .null)
        XCTAssertEqual(exported.evidence["expected_component_bindings"], [])
        XCTAssertEqual(exported.evidence["presence"].list.first?["components_state"], "undeclared")
        XCTAssertEqual(exported.evidence["presence"].list.first?["bindings_state"], "undeclared")
        XCTAssertEqual(KDNAStudio.verifyCreationEvidence(bytes: exported.bytes, evidence: exported.evidence, expectedBinding: exported.binding)["status"], "consistent")
        let saved = try await session.completeSave(exported.bytes); XCTAssertEqual(saved["status"], "accepted_with_live_context")
    }
    func testOrdinaryHumanClaimRemainsUnverified() async throws {
        let session = try make(kind: .humanClaimUnverified); try await populate(session); try await ready(session)
        let exported = try await session.exportAsset(); XCTAssertEqual(exported.evidence["decision"]["adoption_kind"], "human_claim_unverified")
        XCTAssertEqual(exported.evidence["context"]["authorization"], .null)
        XCTAssertEqual(exported.evidence["adoption"], .null)
        let saved = try await session.completeSave(exported.bytes); XCTAssertEqual(saved["identity"], "not_verified")
    }
    func testCompilerMutationIsRejectedEvenWhenPublicCoreAccepts() async throws {
        let probe = CompilerProbe()
        let session = try make(compiler: { input in
            probe.calls += 1
            var changed = input; changed["manifest"]["title"] = "Fresh valid but unapproved Compiler mutation"
            let bytes = try CreationCompiler.compile(changed)
            XCTAssertNotNil(KDNACore.admitBytes(bytes).snapshot)
            probe.changedBytes = bytes; return bytes
        })
        try await populate(session, mechanism: true); try await ready(session)
        await error("CREATION_COMPILER_EXPECTATION_MISMATCH") { _ = try await session.exportAsset() }
        XCTAssertEqual(probe.calls, 1); XCTAssertNotNil(probe.changedBytes)
        await error("CREATION_FINAL_REQUIRED") { _ = try await session.exportAsset() }
        let state = await session.inspect(); XCTAssertEqual(state["phase"], "failed")
    }
    func testInvalidGraphStopsBeforeCompiler() async throws {
        let probe = CompilerProbe(); let session = try make(compiler: { input in probe.calls += 1; return try CreationCompiler.compile(input) })
        var group = try await populate(session, mechanism: true)
        var alternatives = group["alternatives"].list
        for index in alternatives.indices {
            var comps = alternatives[index]["method"]["components"].list
            comps[3]["content"]["broader"] = [["narrowerKey": "record", "broaderKey": "record"]]
            alternatives[index]["method"]["components"] = .array(comps)
        }
        group = try await session.agent.revise("decision", ["baseRevision": 1, "alternatives": .array(alternatives), "explanation": "Synthetic invalid graph; no compiler should run."])
        XCTAssertEqual(group["revision"], 2)
        try await ready(session)
        await error("CREATION_EXPECTED_CORE_REJECTED") { _ = try await session.exportAsset() }
        XCTAssertEqual(probe.calls, 0)
    }
    func testChangedSavedBytesBurnPendingCapability() async throws {
        let session = try make(); try await populate(session); try await ready(session)
        let exported = try await session.exportAsset()
        var expected = try CreationMaterialization.build(context: exported.evidence["context"], descriptor: KDNACore.componentSemanticsContract(), decision: exported.evidence["decision"])
        expected["manifest"]["title"] = "Other technically valid saved artifact"
        let altered = try CreationCompiler.encodeExpected(expected); XCTAssertNotNil(KDNACore.admitBytes(altered).snapshot)
        await error("CREATION_SAVED_EXPECTATION_MISMATCH") { _ = try await session.completeSave(altered) }
        await error("CREATION_SAVE_STATE_INVALID") { _ = try await session.completeSave(exported.bytes) }
    }
    func testPreviewInvalidationStaleRevisionAndReplay() async throws {
        let session = try make(kinds: ["select", "confirm"]); let group = try await populate(session)
        _ = try await session.receiveAdoptionReply(); _ = try await session.agent.compilePreview()
        await error("CREATION_REVISION_BASE_STALE") { _ = try await session.agent.revise("decision", ["baseRevision": 2, "alternatives": group["alternatives"], "explanation": "Wrong base"] ) }
        _ = try await session.agent.setBrief(["title": "Changed", "scope": "Changed scope invalidates review"])
        await error("CREATION_FINAL_UNBOUND") { _ = try await session.receiveAdoptionReply() }
        let replay = try make(replay: true); try await populate(replay); _ = try await replay.receiveAdoptionReply(); _ = try await replay.agent.compilePreview()
        await error("CREATION_REPLY_REPLAY") { _ = try await replay.receiveAdoptionReply() }
    }
    func testRejectReviseReselectAndConfirmedMutationRefusal() async throws {
        let session = try make(kinds: ["reject", "select", "confirm"]); var group = try await populate(session)
        _ = try await session.receiveAdoptionReply()
        var alternatives = group["alternatives"].list; alternatives[0]["statement"] = "重新审定的明确主张。"
        group = try await session.agent.revise("decision", ["baseRevision": 1, "alternatives": .array(alternatives), "explanation": "根据拒绝输入修订。"])
        XCTAssertEqual(group["revision"], 2); try await ready(session)
        await error("CREATION_SESSION_SEALED") { _ = try await session.agent.setBrief(["title": "late", "scope": "late"] ) }
        await error("CREATION_SESSION_SEALED") { _ = try await session.receiveAdoptionReply() }
        let exported = try await session.exportAsset(); XCTAssertEqual(KDNAStudio.verifyCreationEvidence(bytes: exported.bytes, evidence: exported.evidence, expectedBinding: exported.binding)["status"], "consistent")
    }
    func testActualFrozenJavaScriptFormat2PeersAndExternalBindings() throws {
        let resources = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("JavaScript")
        for name in ["ordinary", "taxonomy", "differential"] {
            let folder = resources.appendingPathComponent(name)
            let bytes = try Data(contentsOf: folder.appendingPathComponent("asset.kdna"))
            let evidence = try KDNAJSON.parse(Data(contentsOf: folder.appendingPathComponent("evidence.json")))
            let binding = try KDNAJSON.parse(Data(contentsOf: folder.appendingPathComponent("binding.json")))
            let result = KDNAStudio.verifyCreationEvidence(bytes: bytes, evidence: evidence, expectedBinding: binding)
            XCTAssertEqual(result["status"], "consistent", name + ": " + result["reason"].text)
            XCTAssertEqual(result["creation_accepted"], "not_evaluated"); XCTAssertEqual(result["live_context"], "unavailable")
            var wrongBinding = binding; wrongBinding["session_id"] = "session:other"
            XCTAssertEqual(KDNAStudio.verifyCreationEvidence(bytes: bytes, evidence: evidence, expectedBinding: wrongBinding)["reason"], "CREATION_BINDING_MISMATCH")
            var old = evidence; old["format"] = ["id": "kdna.studio-creation-evidence/1", "version": "1.0.0"]
            XCTAssertEqual(KDNAStudio.verifyCreationEvidence(bytes: bytes, evidence: old, expectedBinding: binding)["reason"], "STUDIO_EVIDENCE_FORMAT_NOT_CURRENT")
            old.remove("format")
            XCTAssertEqual(KDNAStudio.verifyCreationEvidence(bytes: bytes, evidence: old, expectedBinding: binding)["reason"], "STUDIO_EVIDENCE_FORMAT_NOT_CURRENT")
        }
    }
    func testReboundPrivateMaterialAndOldGraphStillReject() async throws {
        let session = try make(); try await populate(session); try await ready(session); let exported = try await session.exportAsset()
        var wrong = exported.evidence
        var materials = wrong["context"]["materials"].list; materials[0]["content"] = "Tampered material"; wrong["context"]["materials"] = .array(materials)
        var binding = exported.binding; binding["evidence_digest"] = .string(try CreationValues.digest(wrong))
        XCTAssertEqual(KDNAStudio.verifyCreationEvidence(bytes: exported.bytes, evidence: wrong, expectedBinding: binding)["reason"], "CREATION_CONTEXT_BINDING_MISMATCH")
        wrong = exported.evidence; wrong["context"]["corePackageVersion"] = "0.24.0-rc.component-semantics.1"
        wrong["decision"]["context_digest"] = .string(try CreationValues.digest(wrong["context"])); binding["evidence_digest"] = .string(try CreationValues.digest(wrong))
        XCTAssertEqual(KDNAStudio.verifyCreationEvidence(bytes: exported.bytes, evidence: wrong, expectedBinding: binding)["reason"], "CREATION_CONTEXT_GRAPH_NOT_CURRENT")
    }
    func testBoundedAuthoringDuplicateMeaningAndExactKeys() throws {
        var a: KDNAValue = ["localKey": "a", "title": "Title", "subject": "Subject", "scope": "Scope", "statement": "Same assertion", "rationale": "One", "materialRefs": ["material:one"]]
        var b = a; b["localKey"] = "b"; b["title"] = "Different title"; b["rationale"] = "Other rationale"
        XCTAssertThrowsError(try CreationAuthoring.alternatives([a,b], materialIDs: [KDNAKey("material:one")]))
        for key in ["trailing\n", "trailing\r", "é", "Capital", String(repeating: "a", count: 65)] { XCTAssertThrowsError(try CreationAuthoring.key(.string(key))) }
        a["method"] = ["method": ["term": "review"], "components": .null]
        XCTAssertThrowsError(try CreationAuthoring.alternative(a, materialIDs: [KDNAKey("material:one")]))
    }
    func testCanonicalDomainHasNoExtraArrayLimitAndExactKeyIdentity() throws {
        let value: KDNAValue = .array(Array(repeating: .number(1), count: 10001))
        XCTAssertEqual(try CreationValues.canonicalEvidence(value).count, 20003)
        var keys: [KDNAKey: KDNAValue] = [:]; keys[KDNAKey("é")] = 1; keys[KDNAKey("e\u{301}")] = 2
        let canonical = String(decoding: try CreationValues.canonicalEvidence(.object(keys)), as: UTF8.self)
        XCTAssertEqual(keys.count, 2); XCTAssertEqual(canonical, "{\"e\u{301}\":2,\"é\":1}")
    }

    func testAsyncCallbackBusyAndAbortCannotMintFinalContext() async throws {
        let paused = PausedReply()
        let adoption = KDNAStudioAdoptionInput(kind: .delegatedAgentEditorial, channel: "synthetic-paused",
            authorization: ["coordinate": "synthetic://paused", "statement": "Fixture only"],
            receive: { try await paused.receive($0) })
        let session = try KDNAStudio.createSession(options: ["agent": ["name": "synthetic", "version": "1"], "syntheticFixture": true],
            adoptionInput: adoption, interpretReply: { text, _ in try KDNAJSON.parse(Data(text.utf8)) })
        try await populate(session)
        let pending = Task { try await session.receiveAdoptionReply() }
        await paused.waitForEntry()
        await error("CREATION_SESSION_BUSY") { _ = try await session.agent.setBrief(["title": "reentry", "scope": "reentry"]) }
        await error("CREATION_SESSION_BUSY") { _ = try await session.receiveAdoptionReply() }
        _ = await session.abort()
        await paused.resume()
        await error("CREATION_SESSION_ABORTED") { _ = try await pending.value }
        await error("CREATION_FINAL_REQUIRED") { _ = try await session.exportAsset() }
        let state = await session.inspect()
        XCTAssertEqual(state["phase"], "aborted")
    }

    func testRehashedAuditStillMustReconstructActualAuthoringState() async throws {
        let session = try make(); try await populate(session); try await ready(session)
        let exported = try await session.exportAsset()
        var evidence = exported.evidence
        evidence["context"]["brief"]["title"] = "Not the recorded brief"
        evidence["decision"]["context_digest"] = .string(try CreationValues.digest(evidence["context"]))
        var history = evidence["history"].list
        history[history.count - 1]["detail"] = evidence["decision"]
        var finalBody = history[history.count - 1]; finalBody.remove("digest")
        history[history.count - 1]["digest"] = .string(try CreationValues.digest(finalBody))
        evidence["history"] = .array(history)
        var rebound = exported.binding; rebound["evidence_digest"] = .string(try CreationValues.digest(evidence))
        let result = KDNAStudio.verifyCreationEvidence(bytes: exported.bytes, evidence: evidence, expectedBinding: rebound)
        XCTAssertEqual(result["reason"], "CREATION_AUDIT_STATE_MISMATCH")
        XCTAssertEqual(result["creation_accepted"], "not_evaluated")
    }

    func testProviderAndAuthorityClaimsCannotUpgradeWithRebinding() async throws {
        let session = try make(); try await populate(session); try await ready(session)
        let exported = try await session.exportAsset()
        for key in ["identity", "action_authorization", "creation_accepted"] {
            var evidence = exported.evidence; evidence[key] = "verified"
            var binding = exported.binding; binding["evidence_digest"] = .string(try CreationValues.digest(evidence))
            XCTAssertEqual(KDNAStudio.verifyCreationEvidence(bytes: exported.bytes, evidence: evidence, expectedBinding: binding)["reason"], "CREATION_AUTHORITY_CLAIM_INVALID")
        }
        var evidence = exported.evidence; evidence["compiler"]["provider"] = "javascript"
        var binding = exported.binding; binding["evidence_digest"] = .string(try CreationValues.digest(evidence))
        XCTAssertEqual(KDNAStudio.verifyCreationEvidence(bytes: exported.bytes, evidence: evidence, expectedBinding: binding)["reason"], "CREATION_PROVIDER_CONTRACT_NOT_CURRENT")
    }

    func testGenuineHistoricalProducerBytesRemainSeparateFormats() throws {
        let resources = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Historical")
        for name in ["format1", "unversioned"] {
            let folder = resources.appendingPathComponent(name)
            let bytes = try Data(contentsOf: folder.appendingPathComponent("artifact.kdna"))
            let evidence = try KDNAJSON.parse(Data(contentsOf: folder.appendingPathComponent("evidence.json")))
            let binding = try KDNAJSON.parse(Data(contentsOf: folder.appendingPathComponent("binding.json")))
            XCTAssertNotNil(KDNACore.admitBytes(bytes).snapshot, "Historical wire bytes remain technically admissible")
            XCTAssertEqual(KDNAStudio.verifyCreationEvidence(bytes: bytes, evidence: evidence, expectedBinding: binding)["reason"], "STUDIO_EVIDENCE_FORMAT_NOT_CURRENT")
        }
    }

    func testRepeatedLocalComponentKeysStayQualifiedByJudgmentOwner() async throws {
        let session = try make()
        let first = try await populate(session, mechanism: true)
        _ = try await session.agent.propose(["localKey": "separate-owner", "alternatives": first["alternatives"]])
        try await ready(session)
        let exported = try await session.exportAsset()
        let bindings = exported.evidence["expected_component_bindings"].list
        XCTAssertEqual(bindings.count, 8)
        XCTAssertEqual(Set(bindings.map { KDNAKey($0["carrier"]["component_ref"].text) }).count, 8)
        let owners = Set(bindings.map { KDNAKey($0["carrier"]["judgment_ref"].text) })
        XCTAssertEqual(owners.count, 2)
        for entry in bindings where entry["carrier"]["component_type"] == "discriminator-set" {
            let target = entry["carrier"]["content"]["candidateSetRef"]
            let candidates = bindings.filter { $0["carrier"]["judgment_ref"] == entry["carrier"]["judgment_ref"] && $0["carrier"]["component_type"] == "candidate-set" }
            XCTAssertTrue(candidates.contains { $0["carrier"]["component_ref"] == target })
        }
        let completion = try await session.completeSave(exported.bytes)
        XCTAssertEqual(completion["status"], "accepted_with_live_context")
        XCTAssertEqual(KDNAStudio.verifyCreationEvidence(bytes: exported.bytes, evidence: exported.evidence, expectedBinding: exported.binding)["status"], "consistent")
    }

    func testDeclaredEmptyAndUndeclaredFieldsRemainDifferent() async throws {
        for bothDeclared in [false, true] {
            let session = try make(); let group = try await populate(session)
            var alternatives = group["alternatives"].list
            for i in alternatives.indices {
                var method: KDNAValue = ["method": ["term": "review"], "components": []]
                if bothDeclared { method["bindings"] = [] }
                alternatives[i]["method"] = method
                alternatives[i]["formationRule"] = ["conditions": []]
            }
            _ = try await session.agent.revise("decision", ["baseRevision": 1, "alternatives": .array(alternatives), "explanation": "Explicitly authored field presence"])
            try await ready(session); let exported = try await session.exportAsset()
            XCTAssertEqual(exported.evidence["adoption"], .null)
            XCTAssertEqual(exported.evidence["presence"].list.count, bothDeclared ? 0 : 1)
            if !bothDeclared {
                XCTAssertEqual(exported.evidence["presence"].list[0]["components_state"], "declared")
                XCTAssertEqual(exported.evidence["presence"].list[0]["bindings_state"], "undeclared")
            }
            let admitted = try XCTUnwrap(KDNACore.admitBytes(exported.bytes).snapshot).inspect()
            let judgment = try XCTUnwrap(admitted["ir"]["nodes"].list.first { $0["role"] == "judgment" })["value"]
            XCTAssertFalse(judgment.has("result")); XCTAssertEqual(judgment["formation_rule"]["conditions"], [])
            let completion = try await session.completeSave(exported.bytes)
            XCTAssertEqual(completion["status"], "accepted_with_live_context")
        }
    }
}
