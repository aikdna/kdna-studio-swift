import Foundation
import KDNACore
import KDNAStudioCore

// Synthetic transport/adoption fixtures exercise the public API. They do not
// represent a person's or an editorial Agent's judgment of real task material.
private actor Replies {
    var count = 0
    func receive(_ review: KDNAValue) throws -> KDNAValue {
        count += 1
        let intent: KDNAValue = count == 1
            ? ["kind": "select", "choices": .array(review["groups"].list.map {
                ["judgmentLocalKey": $0["localKey"], "alternativeLocalKey": $0["alternatives"].list[0]["localKey"]]
            })]
            : ["kind": "confirm"]
        return ["id": .string("synthetic-reply-\(count)"), "role": "agent", "channel": review["channel"],
                "review_id": review["review_id"], "text": .string(String(decoding: try KDNAJSON.canonical(intent), as: UTF8.self))]
    }
}

private func require(_ value: Bool, _ message: String) throws {
    if !value { throw NSError(domain: "PublicConsumer", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func reject(_ code: String, _ operation: () async throws -> Void) async throws {
    do { try await operation() }
    catch let failure as KDNAStudioFailure { try require(failure.code == code, failure.code); return }
    throw NSError(domain: "PublicConsumer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected rejection: " + code])
}

@main
struct Consumer {
    static func main() async throws {
        let replies = Replies()
        let input = KDNAStudioAdoptionInput(kind: .delegatedAgentEditorial, channel: "synthetic-channel",
            authorization: ["coordinate": "synthetic://delegation", "statement": "Fixture execution only."],
            receive: { try await replies.receive($0) })
        let session = try KDNAStudio.createSession(
            options: ["agent": ["name": "public-consumer-fixture", "version": "1.0.0"], "syntheticFixture": true],
            adoptionInput: input, interpretReply: { text, _ in try KDNAJSON.parse(Data(text.utf8)) })
        _ = try await session.agent.setBrief(["title": "Observed signal", "scope": "Synthetic observation"])
        let material = try await session.agent.recordMaterial([
            "kind": "text", "title": "Observation", "content": "The sample contains an unverified signal.",
            "coordinate": "synthetic://private-material"])
        let first: KDNAValue = ["localKey": "preserve", "title": "Preserve uncertainty", "subject": "signal",
            "scope": "synthetic observation", "statement": "Preserve multiple possible explanations.",
            "rationale": "A signal alone does not isolate its cause.", "materialRefs": [material["id"]]]
        var second = first
        second["localKey"] = "select-cause"; second["statement"] = "Select one explanation as the cause."
        _ = try await session.agent.propose(["localKey": "signal", "alternatives": [first, second]])
        try await reject("CREATION_FINAL_REQUIRED") { _ = try await session.exportAsset() }
        _ = try await session.receiveAdoptionReply()
        _ = try await session.agent.compilePreview()
        _ = try await session.receiveAdoptionReply()
        let exported = try await session.exportAsset()
        try require(exported.verification["status"] == "pending_saved_readback", "save must remain pending")
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        try exported.bytes.write(to: destination, options: .withoutOverwriting)
        let savedBytes = try Data(contentsOf: destination)
        let saved = try await session.completeSave(savedBytes)
        try require(saved["status"] == "accepted_with_live_context", "actual saved readback")
        try require(saved["identity"] == "not_verified" && saved["action_authorization"] == "not_evaluated", "authority limits")
        let verified = KDNAStudio.verifyCreationEvidence(bytes: savedBytes, evidence: exported.evidence, expectedBinding: exported.binding)
        try require(verified["status"] == "consistent" && verified["creation_accepted"] == "not_evaluated" && verified["live_context"] == "unavailable", "static proof boundary")
        var wrong = exported.binding; wrong["asset_digest"] = .string(String(repeating: "0", count: 64))
        try require(KDNAStudio.verifyCreationEvidence(bytes: savedBytes, evidence: exported.evidence, expectedBinding: wrong)["status"] != "consistent", "external binding must match")
        try await reject("CREATION_SAVE_STATE_INVALID") { _ = try await session.completeSave(savedBytes) }
        try await reject("CREATION_FINAL_REQUIRED") { _ = try await session.exportAsset() }
        let admission = KDNACore.admitBytes(savedBytes)
        try require(admission.snapshot != nil, "real Core admission")
        let publicIR = try KDNAJSON.canonical(admission.snapshot!.inspect()["ir"])
        try require(!String(decoding: publicIR, as: UTF8.self).contains("synthetic://private-material"), "private source coordinate")
        print("{\"status\":\"PUBLIC_CONSUMER_PASS\",\"actual_saved_readback\":true,\"static_live_context\":\"unavailable\",\"identity\":\"not_verified\"}")
    }
}
