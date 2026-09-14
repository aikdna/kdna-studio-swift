import XCTest
import Foundation
import KDNACore
@testable import KDNAStudioCore

actor HumanScript {
    private var kind = "select"
    private var explicitRefs: [KDNAValue]?
    private var messageID: String?
    private var wrongChannel = false
    private var count = 0
    private var intentFailure = false
    private var gate: CheckedContinuation<Void, Never>?
    private var shouldSuspend = false
    private var received = false
    private var receiveObserver: CheckedContinuation<Void, Never>?

    func plan(_ kind: String, refs: [KDNAValue]? = nil, messageID: String? = nil,
              wrongChannel: Bool = false, intentFailure: Bool = false) {
        self.kind = kind; self.explicitRefs = refs; self.messageID = messageID
        self.wrongChannel = wrongChannel; self.intentFailure = intentFailure
    }
    func suspendNext() { shouldSuspend = true }
    func waitUntilReceived() async {
        if received { return }
        await withCheckedContinuation { receiveObserver = $0 }
    }
    func resume() { gate?.resume(); gate = nil }
    func receive(_ review: KDNAValue) async -> KDNAValue {
        count += 1
        received = true
        receiveObserver?.resume(); receiveObserver = nil
        if shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { gate = $0 }
        }
        return ["id": .string(messageID ?? "message:\(count)"), "role": "human",
                "channel": .string(wrongChannel ? "other" : "test-human"), "review_id": review["review_id"],
                "text": .string("人工回复：" + kind)]
    }
    func interpret(_ text: String, _ review: KDNAValue) throws -> KDNAValue {
        if intentFailure { throw KDNAStudioFailure("TEST_INTERPRETER_FAILURE", "Synthetic interpreter failure.") }
        var result: KDNAValue = ["kind": .string(kind)]
        if ["select", "reject", "revise"].contains(kind) {
            result["candidateRefs"] = .array(explicitRefs ?? review["candidates"].list.map { $0["ref"] })
        }
        return result
    }
}

func studioSession(_ script: HumanScript = HumanScript()) throws -> KDNAStudioSession {
    try KDNAStudio.createSession(
        options: ["agent": ["name": "studio-native-test", "version": "1.0.0"], "syntheticFixture": true],
        humanInput: KDNAStudioHumanInput(channel: "test-human", receive: { await script.receive($0) }),
        interpretHuman: { try await script.interpret($0, $1) })
}

func authored(_ material: KDNAValue, statement: String = "保留原始日期，并标记未知地点。") -> KDNAValue {
    ["title": "保留来源信息", "subject": "家庭照片整理者", "scope": "日期可见、地点不确定时",
     "statement": .string(statement), "rationale": "材料区分了可见日期与未经证实的地点。",
     "materialRefs": [material["id"]]]
}

@discardableResult
func prepareCandidate(_ session: KDNAStudioSession) async throws -> KDNAValue {
    _ = try await session.agent.setBrief(["title": "照片整理规则", "scope": "家庭照片的日期和地点记录"])
    let material = try await session.agent.recordMaterial([
        "kind": "interview", "title": "新访谈片段", "coordinate": "interview:photo-sort#turn-1",
        "content": "我能读出照片背面的日期，但不确定地点。请保留日期，并明确标注地点未知。",
    ])
    return try await session.agent.propose(authored(material))
}

final class StudioSessionTests: XCTestCase {
    func testBlankCreationReviewPreviewFinalAndSeal() async throws {
        let script = HumanScript(), session = try studioSession(script)
        _ = try await prepareCandidate(session)
        _ = try await session.receiveHumanReply()
        let preview = try await session.agent.compilePreview()
        XCTAssertEqual(preview["format_valid"], true)
        XCTAssertEqual(preview["creation_accepted"], "not_evaluated")
        await script.plan("confirm")
        _ = try await session.receiveHumanReply()
        let exported = try await session.exportAsset()
        XCTAssertEqual(exported.verification["status"], "consistent")
        XCTAssertEqual(exported.verification["confirmation"], "claimed_unverified")
        XCTAssertEqual(exported.verification["identity"], "not_verified")
        XCTAssertEqual(exported.verification["read_permission"], "not_evaluated")
        XCTAssertEqual(exported.verification["action_authorization"], "not_evaluated")
        XCTAssertNotNil(KDNACore.admitBytes(exported.bytes).snapshot)
        var copiedEvidence = exported.evidence
        copiedEvidence["identity"] = "verified"
        XCTAssertEqual(exported.evidence["identity"], "not_verified")
        var copiedBytes = exported.bytes
        copiedBytes[0] ^= 1
        XCTAssertNotEqual(copiedBytes, exported.bytes)
        await assertFailure("SESSION_SEALED") { _ = try await session.exportAsset() }
        await assertFailure("SESSION_SEALED") { _ = try await session.agent.setBrief(["title": "x", "scope": "y"]) }
    }

    func testRevisionAndNoteInvalidatePreviewAndFinal() async throws {
        let script = HumanScript(), session = try studioSession(script)
        let candidate = try await prepareCandidate(session)
        _ = try await session.receiveHumanReply()
        _ = try await session.agent.compilePreview()
        await script.plan("confirm")
        _ = try await session.receiveHumanReply()
        await script.plan("note")
        _ = try await session.receiveHumanReply()
        let draft = await session.inspect()
        XCTAssertEqual(draft["preview"], .null)
        XCTAssertEqual(draft["final_decision"], .null)
        await assertFailure("CREATION_EVIDENCE_REQUIRED") { _ = try await session.exportAsset() }
        await script.plan("revise", refs: [candidate["ref"]])
        _ = try await session.receiveHumanReply()
        let pending = await session.inspect()
        XCTAssertEqual(pending["candidates"].list[0]["status"], "awaiting_revision")
        await assertFailure("REVIEW_INCOMPLETE") { _ = try await session.agent.compilePreview() }
        let material = pending["materials"].list[0]
        let revised = try await session.agent.revise(candidate["ref"].text, [
            "authored": authored(material, statement: "保留背面所写日期，地点未核实。"), "explanation": "依照人工回复，明确不确定的信息。",
        ])
        XCTAssertEqual(revised["revision"], 2)
        XCTAssertEqual(revised["status"], "proposed")
        await script.plan("select")
        _ = try await session.receiveHumanReply()
        _ = try await session.agent.compilePreview()
        await script.plan("confirm")
        _ = try await session.receiveHumanReply()
        let result = try await session.exportAsset()
        XCTAssertEqual(result.verification["status"], "consistent")
    }

    func testFreshMaterialsClosedInputsAndCopyIsolation() async throws {
        let session = try studioSession()
        await assertFailure("MATERIAL_REQUIRED") {
            _ = try await session.agent.propose(["title": "x", "subject": "x", "scope": "x", "statement": "x", "rationale": "x", "materialRefs": ["missing"]])
        }
        await assertFailure("INPUT_FIELD_FORBIDDEN") {
            _ = try await session.agent.setBrief(["title": "x", "scope": "x", "asset_id": "forged"])
        }
        await assertFailure("MATERIAL_KIND_UNSUPPORTED") {
            _ = try await session.agent.recordMaterial(["kind": "kdna", "title": "x", "coordinate": "x", "content": "old asset"])
        }
        var material = try await session.agent.recordMaterial(["kind": "text", "title": "x", "coordinate": "é", "content": "记录"])
        material["content"] = "mutated copy"
        let actual = await session.inspect()
        XCTAssertEqual(actual["materials"].list[0]["content"], "记录")
        await assertFailure("MATERIAL_COORDINATE_REUSED") {
            _ = try await session.agent.recordMaterial(["kind": "text", "title": "x", "coordinate": "é", "content": "different"])
        }
        _ = try await session.agent.recordMaterial(["kind": "text", "title": "x", "coordinate": "e\u{301}", "content": "Unicode bytes differ"])
        var copy = await session.inspect()
        copy["materials"] = []
        let current = await session.inspect()
        XCTAssertEqual(current["materials"].list.count, 2)
    }

    func testRejectedReplyClearsFinalAndConsumedIDCannotReplay() async throws {
        let script = HumanScript(), session = try studioSession(script)
        _ = try await prepareCandidate(session)
        _ = try await session.receiveHumanReply()
        _ = try await session.agent.compilePreview()
        await script.plan("confirm")
        _ = try await session.receiveHumanReply()
        await script.plan("note", wrongChannel: true)
        await assertFailure("HUMAN_MESSAGE_UNBOUND") { _ = try await session.receiveHumanReply() }
        let state = await session.inspect()
        XCTAssertEqual(state["final_decision"], .null)
        XCTAssertNotEqual(state["preview"], .null)
        await assertFailure("CREATION_EVIDENCE_REQUIRED") { _ = try await session.exportAsset() }
        await script.plan("note", messageID: "consumed-on-failure", intentFailure: true)
        await assertFailure("TEST_INTERPRETER_FAILURE") { _ = try await session.receiveHumanReply() }
        await script.plan("note", messageID: "consumed-on-failure")
        await assertFailure("HUMAN_MESSAGE_REPLAY") { _ = try await session.receiveHumanReply() }
    }

    func testBusyActorRejectsReentryWhileAwaitingHuman() async throws {
        let script = HumanScript(), session = try studioSession(script)
        _ = try await prepareCandidate(session)
        await script.suspendNext()
        let pending = Task { try await session.receiveHumanReply() }
        await script.waitUntilReceived()
        await assertFailure("SESSION_BUSY") { _ = try await session.agent.setBrief(["title": "x", "scope": "y"]) }
        await assertFailure("SESSION_BUSY") { _ = try await session.receiveHumanReply() }
        await script.resume()
        _ = try await pending.value
        let state = await session.inspect()
        XCTAssertEqual(state["candidates"].list[0]["status"], "selected")
    }

    private func assertFailure(_ code: String, file: StaticString = #filePath, line: UInt = #line,
                               _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(code)", file: file, line: line) }
        catch { XCTAssertEqual((error as? KDNAStudioFailure)?.code, code, file: file, line: line) }
    }
}
