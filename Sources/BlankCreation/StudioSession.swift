import Foundation
import KDNACore

public struct KDNAStudioHumanInput {
    public let channel: String
    let receive: (KDNAValue) async throws -> KDNAValue

    public init(channel: String, receive: @escaping (KDNAValue) async throws -> KDNAValue) {
        self.channel = channel
        self.receive = receive
    }
}

public typealias KDNAStudioInterpreter = (String, KDNAValue) async throws -> KDNAValue

public struct KDNAStudioExport {
    public let bytes: Data
    public let evidence: KDNAValue
    public let binding: KDNAValue
    public let verification: KDNAValue
}

public enum KDNAStudio {
    /// Callable integrations are separate Swift parameters; options contains
    /// only agent metadata and optional syntheticFixture. No legacy project,
    /// card, asset ID, version, identity or consent input is accepted.
    public static func createSession(
        options: KDNAValue,
        humanInput: KDNAStudioHumanInput,
        interpretHuman: @escaping KDNAStudioInterpreter
    ) throws -> KDNAStudioSession {
        try StudioValues.record(options, fields: ["agent", "syntheticFixture"])
        try StudioValues.record(options["agent"], fields: ["name", "version"])
        let agent: KDNAValue = [
            "name": .string(try StudioValues.text(options["agent"]["name"], "agent.name")),
            "version": .string(try StudioValues.text(options["agent"]["version"], "agent.version")),
        ]
        _ = try StudioValues.text(.string(humanInput.channel), "humanInput.channel")
        if options.has("syntheticFixture"), case .bool = options["syntheticFixture"] {
            // The explicit Boolean is accepted below.
        } else if options.has("syntheticFixture") {
            throw StudioValues.fail("INPUT_INVALID", "syntheticFixture must be a Boolean.")
        }
        return KDNAStudioSession(agent: agent, humanInput: humanInput, interpretHuman: interpretHuman,
                                 syntheticFixture: options["syntheticFixture"] == true,
                                 compiler: StudioEvidenceMetadata.compiler)
    }

    public static func verifyCreationEvidence(
        bytes: Data, evidence: KDNAValue?, expectedBinding: KDNAValue?
    ) -> KDNAValue {
        StudioEvidence.verify(bytes: bytes, evidence: evidence, expectedBinding: expectedBinding)
    }
}

public struct KDNAStudioAgent {
    fileprivate let session: KDNAStudioSession

    public func setBrief(_ input: KDNAValue) async throws -> KDNAValue {
        try await session.setBrief(input)
    }
    public func recordMaterial(_ input: KDNAValue) async throws -> KDNAValue {
        try await session.recordMaterial(input)
    }
    public func propose(_ input: KDNAValue) async throws -> KDNAValue {
        try await session.propose(input)
    }
    public func revise(_ candidateRef: String, _ input: KDNAValue) async throws -> KDNAValue {
        try await session.revise(candidateRef, input)
    }
    public func compilePreview() async throws -> KDNAValue {
        try await session.compilePreview()
    }
}

public actor KDNAStudioSession {
    public nonisolated var agent: KDNAStudioAgent { KDNAStudioAgent(session: self) }

    private let agentInfo: KDNAValue
    private let compiler: KDNAValue
    private let channel: String
    private let receive: (KDNAValue) async throws -> KDNAValue
    private let interpret: KDNAStudioInterpreter
    private let sessionID: String
    private let assetID: String
    private let assetUID: String
    private let createdAt: String
    private var state: KDNAValue
    private var preview: (compiled: StudioCompiledArtifact, review: KDNAValue, revision: KDNAValue)?
    private var finalDecision: KDNAValue?
    private var busy = false
    private var exported = false
    private var seenMessages = Set<KDNAKey>()

    fileprivate init(agent: KDNAValue, humanInput: KDNAStudioHumanInput,
                     interpretHuman: @escaping KDNAStudioInterpreter,
                     syntheticFixture: Bool, compiler: KDNAValue) {
        self.agentInfo = agent
        self.compiler = compiler
        self.channel = humanInput.channel
        self.receive = humanInput.receive
        self.interpret = interpretHuman
        self.sessionID = StudioValues.uuid("session:")
        self.assetID = StudioValues.uuid("asset:")
        self.assetUID = StudioValues.uuid("urn:uuid:")
        self.createdAt = StudioValues.now()
        self.state = [
            "session_id": .string(sessionID), "revision": 0,
            "agent": agent, "compiler": compiler, "synthetic_fixture": .bool(syntheticFixture),
            "brief": nil, "materials": [], "candidates": [], "human_messages": [], "history": [],
        ]
    }

    private func ensureOpen() throws {
        if exported { throw StudioValues.fail("SESSION_SEALED", "Start a new blank session after export.") }
        if busy { throw StudioValues.fail("SESSION_BUSY", "A human review is in progress.") }
    }

    private func evolve(_ event: String, detail: KDNAValue,
                        mutate: (inout KDNAValue) throws -> Void) throws {
        var next = state
        try mutate(&next)
        next["revision"] = .number(next["revision"].numeric + 1)
        try StudioValues.appendHistory(&next, event: event, detail: detail)
        state = next
        preview = nil
        finalDecision = nil
    }

    private func candidateIndex(_ ref: String, in value: KDNAValue) throws -> Int {
        guard let index = value["candidates"].list.firstIndex(where: {
            StudioValues.sameText($0["ref"].text, ref)
        }) else { throw StudioValues.fail("CANDIDATE_UNKNOWN", "Select an existing candidate.") }
        return index
    }

    private func authoredCandidate(_ input: KDNAValue) throws -> KDNAValue {
        try StudioValues.record(input, fields: ["title", "subject", "scope", "statement", "rationale", "materialRefs"])
        guard !state["materials"].list.isEmpty else {
            throw StudioValues.fail("MATERIAL_REQUIRED", "Record source material before proposing a judgment.")
        }
        var result: KDNAValue = [:]
        for field in ["title", "subject", "scope", "statement", "rationale"] {
            result[field] = .string(try StudioValues.text(input[field], field))
        }
        guard let refs = StudioValues.array(input["materialRefs"]), !refs.isEmpty,
              Set(refs.map { KDNAKey($0.text) }).count == refs.count,
              refs.allSatisfy({ ref in state["materials"].list.contains { $0["id"] == ref } }) else {
            throw StudioValues.fail("MATERIAL_REFERENCE_INVALID", "Candidates must reference recorded material coordinates.")
        }
        result["material_refs"] = .array(refs)
        return result
    }

    public func inspect() -> KDNAValue {
        var result = state
        result["status"] = .string(exported ? "exported" : finalDecision != nil ? "confirmed_claim_unverified" :
                                    preview != nil ? "awaiting_final_decision" : "draft")
        result["final_decision"] = finalDecision ?? .null
        result["preview"] = preview?.review ?? .null
        result["authority"] = [
            "confirmation": finalDecision != nil ? "claimed_unverified" : "not_evaluated",
            "creation_accepted": "not_evaluated", "identity": "not_verified",
            "read_permission": "not_evaluated", "action_authorization": "not_evaluated",
        ]
        return result
    }

    fileprivate func setBrief(_ input: KDNAValue) throws -> KDNAValue {
        try ensureOpen()
        try StudioValues.record(input, fields: ["title", "scope"])
        let brief: KDNAValue = ["title": .string(try StudioValues.text(input["title"], "title")),
                               "scope": .string(try StudioValues.text(input["scope"], "scope"))]
        try evolve("brief_recorded", detail: brief) { $0["brief"] = brief }
        return inspect()
    }

    fileprivate func recordMaterial(_ input: KDNAValue) throws -> KDNAValue {
        try ensureOpen()
        let material = try StudioValues.material(input)
        guard !state["materials"].list.contains(where: { $0["coordinate"] == material["coordinate"] }) else {
            throw StudioValues.fail("MATERIAL_COORDINATE_REUSED", "Record a distinct immutable material coordinate.")
        }
        try evolve("material_recorded", detail: material) { next in
            next["materials"] = .array(next["materials"].list + [material])
        }
        return material
    }

    fileprivate func propose(_ input: KDNAValue) throws -> KDNAValue {
        try ensureOpen()
        var item = try authoredCandidate(input)
        item["ref"] = .string(StudioValues.uuid("candidate:"))
        item["revision"] = 1
        item["status"] = "proposed"
        item["revision_request"] = .null
        try evolve("candidate_proposed", detail: item) { next in
            next["candidates"] = .array(next["candidates"].list + [item])
        }
        return item
    }

    fileprivate func revise(_ ref: String, _ input: KDNAValue) throws -> KDNAValue {
        try ensureOpen()
        try StudioValues.record(input, fields: ["authored", "explanation"])
        let index = try candidateIndex(ref, in: state)
        let previous = state["candidates"].list[index]
        var replacement = try authoredCandidate(input["authored"])
        replacement["ref"] = .string(ref)
        replacement["revision"] = .number(previous["revision"].numeric + 1)
        replacement["status"] = "proposed"
        replacement["revision_request"] = .null
        let detail: KDNAValue = ["previous": previous, "replacement": replacement,
                                 "explanation": .string(try StudioValues.text(input["explanation"], "explanation")),
                                 "requested_by_message": previous["revision_request"]]
        try evolve("candidate_revised", detail: detail) { next in
            var candidates = next["candidates"].list
            candidates[index] = replacement
            next["candidates"] = .array(candidates)
        }
        return replacement
    }

    fileprivate func compilePreview() throws -> KDNAValue {
        try ensureOpen()
        guard state["brief"] != .null else { throw StudioValues.fail("BRIEF_REQUIRED", "Record the intended scope before compilation.") }
        guard !state["materials"].list.isEmpty else { throw StudioValues.fail("MATERIAL_REQUIRED", "Creation requires source material.") }
        let selected = state["candidates"].list.filter { $0["status"] == "selected" }
        guard !selected.isEmpty, state["candidates"].list.allSatisfy({ $0["status"] == "selected" || $0["status"] == "rejected" }) else {
            throw StudioValues.fail("REVIEW_INCOMPLETE", "Resolve the proposed candidates and requested revisions first.")
        }
        let revision = String(decoding: try KDNAJSON.canonical(state["revision"]), as: UTF8.self)
        let compiled = try StudioCompiler.compile(
            brief: state["brief"], candidates: selected,
            asset: ["asset_id": .string(assetID), "asset_uid": .string(assetUID), "version": .string("0.1." + revision)],
            createdAt: createdAt, syntheticFixture: state["synthetic_fixture"] == true)
        let judgments: [KDNAValue] = selected.map { item in
            ["candidate_ref": item["ref"], "title": item["title"], "subject": item["subject"],
             "scope": item["scope"], "statement": item["statement"], "rationale": item["rationale"]]
        }
        let review: KDNAValue = [
            "session_id": .string(sessionID), "revision": state["revision"], "artifact_digest": compiled.assetDigest,
            "title": state["brief"]["title"], "scope": state["brief"]["scope"], "judgments": .array(judgments),
            "format_valid": true, "creation_accepted": "not_evaluated",
        ]
        preview = (compiled, review, state["revision"])
        finalDecision = nil
        var detail = review
        detail["compiler"] = compiler
        detail["agent"] = agentInfo
        try StudioValues.appendHistory(&state, event: "compiler_preview", detail: detail)
        return review
    }

    public func receiveHumanReply() async throws -> KDNAValue {
        try ensureOpen()
        busy = true
        finalDecision = nil
        defer { busy = false }
        let reviewID = StudioValues.uuid("review:")
        let review: KDNAValue = [
            "review_id": .string(reviewID), "session_id": .string(sessionID), "revision": state["revision"],
            "brief": state["brief"], "candidates": state["candidates"], "compiled": preview?.review ?? .null,
        ]
        do {
            let message = try await receive(review)
            try StudioValues.record(message, fields: ["id", "role", "channel", "review_id", "text"])
            let messageID = try StudioValues.text(message["id"], "message.id")
            let text = try StudioValues.text(message["text"], "message.text")
            guard message["role"] == "human", message["channel"] == .string(channel), message["review_id"] == .string(reviewID) else {
                throw StudioValues.fail("HUMAN_MESSAGE_UNBOUND", "The reply must come from the declared human channel for this review.")
            }
            guard seenMessages.insert(KDNAKey(messageID)).inserted else {
                throw StudioValues.fail("HUMAN_MESSAGE_REPLAY", "This message has already been consumed.")
            }
            let intent = try await interpret(text, review)
            try StudioValues.record(intent, fields: ["kind", "candidateRefs"])
            let kind = intent["kind"].text
            guard ["select", "reject", "revise", "note", "confirm"].contains(kind) else {
                throw StudioValues.fail("HUMAN_INTERPRETATION_INVALID", "Unsupported human reply interpretation.")
            }
            var refs: [KDNAValue] = []
            if ["select", "reject", "revise"].contains(kind) {
                guard let values = StudioValues.array(intent["candidateRefs"]), !values.isEmpty,
                      Set(values.map { KDNAKey($0.text) }).count == values.count else {
                    throw StudioValues.fail("HUMAN_INTERPRETATION_INVALID", "Interpretation requires existing candidate references.")
                }
                for ref in values { _ = try candidateIndex(ref.text, in: state) }
                refs = values
            } else if intent.has("candidateRefs") {
                throw StudioValues.fail("HUMAN_INTERPRETATION_INVALID", "This reply does not select individual candidates.")
            }
            var record = message
            record["interpreted_by"] = agentInfo
            record["interpretation"] = intent
            record["revision"] = state["revision"]
            record["review"] = review
            record["identity_verification"] = "not_verified"
            if kind == "confirm" {
                guard let preview, preview.revision == state["revision"] else {
                    throw StudioValues.fail("FINAL_DECISION_UNBOUND", "Review the current compiled output before final confirmation.")
                }
                state["human_messages"] = .array(state["human_messages"].list + [record])
                let decision: KDNAValue = [
                    "message_id": message["id"], "channel": .string(channel), "text": message["text"],
                    "review_id": .string(reviewID), "session_id": .string(sessionID), "revision": state["revision"],
                    "artifact_digest": preview.compiled.assetDigest,
                    "confirmation": "claimed_unverified", "identity_verification": "not_verified",
                ]
                finalDecision = decision
                try StudioValues.appendHistory(&state, event: "human_final_decision", detail: decision)
            } else {
                try evolve("human_reply", detail: record) { next in
                    next["human_messages"] = .array(next["human_messages"].list + [record])
                    var candidates = next["candidates"].list
                    for ref in refs {
                        let index = try candidateIndex(ref.text, in: next)
                        candidates[index]["status"] = .string(["select": "selected", "reject": "rejected", "revise": "awaiting_revision"][kind]!)
                        candidates[index]["revision_request"] = kind == "revise" ? message["id"] : .null
                    }
                    next["candidates"] = .array(candidates)
                }
            }
            return inspect()
        } catch {
            try StudioValues.appendHistory(&state, event: "human_reply_rejected", detail: [
                "review_id": .string(reviewID),
                "code": .string((error as? KDNAStudioFailure)?.code ?? "HUMAN_CHANNEL_FAILURE"),
            ])
            throw error
        }
    }

    public func exportAsset() throws -> KDNAStudioExport {
        try ensureOpen()
        guard let preview, let finalDecision,
              finalDecision["revision"] == state["revision"],
              finalDecision["artifact_digest"] == preview.compiled.assetDigest else {
            throw StudioValues.fail("CREATION_EVIDENCE_REQUIRED", "Export requires the current compiled output and a bound human final decision.")
        }
        let result = try StudioEvidence.export(state: state, compiled: preview.compiled, finalDecision: finalDecision)
        guard result.verification["status"] == "consistent" else {
            throw StudioValues.fail("CREATION_EVIDENCE_INCONSISTENT", result.verification["reason"].text)
        }
        exported = true
        return result
    }
}
