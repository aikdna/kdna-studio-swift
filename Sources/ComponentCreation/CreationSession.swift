import Foundation
import KDNACore

public actor KDNAStudioSession {
    public nonisolated var agent: KDNAStudioAgent { KDNAStudioAgent(session: self) }
    private struct Preview { let snapshot: KDNAValue; let review: KDNAValue }
    private struct LiveContext { let snapshot: KDNAValue; let decision: KDNAValue; let descriptor: KDNAValue }
    private struct PendingSave { let expected: KDNAValue; let bytes: Data; let evidence: KDNAValue }
    private let runtime: CreationRuntime
    private let agentInfo: KDNAValue
    private let adoption: KDNAStudioAdoptionInput
    private let interpret: KDNAStudioInterpreter
    private let fixture: Bool
    private let createdAt: String
    private let identity: KDNAValue
    private let compiler: (KDNAValue) throws -> Data
    private var state: KDNAValue
    private var preview: Preview?
    private var live: LiveContext?
    private var pending: PendingSave?
    private var busy = false
    private var phase = "draft"
    private var seen = Set<KDNAKey>()

    // Compiler injection is module-internal, for adversarial implementation
    // tests. The public createSession API never accepts this capability.
    init(options: KDNAValue, adoptionInput: KDNAStudioAdoptionInput,
         interpretReply: @escaping KDNAStudioInterpreter,
         compiler: @escaping (KDNAValue) throws -> Data = CreationCompiler.compile) throws {
        self.runtime = try CreationRuntime()
        self.agentInfo = options["agent"]
        self.adoption = adoptionInput
        self.interpret = interpretReply
        self.fixture = options["syntheticFixture"] == true
        self.createdAt = CreationValues.now()
        self.identity = CreationIdentity.freshAsset()
        self.compiler = compiler
        self.state = ["session_id": .string(CreationValues.uuid("session:")), "revision": 0,
                      "brief": nil, "materials": [], "groups": [], "choices": nil, "history": []]
    }

    private func open() throws {
        guard !busy else { throw CreationValues.fail("CREATION_SESSION_BUSY", "An adoption callback is in progress.") }
        guard phase == "draft" else { throw CreationValues.fail("CREATION_SESSION_SEALED", "This creation session no longer accepts changes.") }
    }
    private func invalidate() { live = nil; preview = nil }
    private func append(_ event: String, _ detail: KDNAValue) throws {
        var history = state["history"].list
        var entry: KDNAValue = ["sequence": .number(Double(history.count + 1)), "revision": state["revision"],
            "event": .string(event), "at": .string(CreationValues.now()), "detail": detail,
            "previous_digest": history.last?["digest"] ?? .null]
        entry["digest"] = .string(try CreationValues.digest(entry))
        history.append(entry); state["history"] = .array(history)
    }
    private func evolve(_ event: String, detail: KDNAValue, mutation: (inout KDNAValue) throws -> Void) throws {
        invalidate()
        var next = state; try mutation(&next)
        next["revision"] = .number(next["revision"].numeric + 1); state = next
        try append(event, detail)
    }
    public func inspect() -> KDNAValue {
        var value = state
        value["phase"] = .string(phase); value["preview"] = preview?.review ?? .null
        value["authority"] = ["identity": "not_verified", "creation": "not_evaluated", "action": "not_evaluated"]
        return value
    }
    func setBrief(_ input: KDNAValue) throws -> KDNAValue {
        try open(); try CreationAuthoring.object(input, allowed: ["title", "scope"], required: ["title", "scope"])
        for key in ["title", "scope"] { _ = try CreationValues.text(input[key], key) }
        try evolve("brief", detail: input) { $0["brief"] = input; $0["choices"] = .null }
        return inspect()
    }
    func recordMaterial(_ input: KDNAValue) throws -> KDNAValue {
        try open(); try CreationAuthoring.object(input, allowed: ["kind", "title", "content", "coordinate"], required: ["kind", "title", "content", "coordinate"])
        guard input["kind"] == "text" || input["kind"] == "interview" else { throw CreationValues.fail("CREATION_MATERIAL_KIND_UNSUPPORTED", "Record text or interview material.") }
        for key in ["title", "content", "coordinate"] { _ = try CreationValues.text(input[key], key) }
        guard !state["materials"].list.contains(where: { $0["coordinate"] == input["coordinate"] }) else {
            throw CreationValues.fail("CREATION_MATERIAL_COORDINATE_REUSED", "Material coordinates are immutable and distinct.")
        }
        var material = input
        material["id"] = .string(CreationValues.uuid("material:"))
        material["content_digest"] = .string(CreationValues.sha256(Data(input["content"].text.utf8)))
        material["recorded_at"] = .string(CreationValues.now())
        try evolve("material", detail: material) { $0["materials"] = .array($0["materials"].list + [material]); $0["choices"] = .null }
        return material
    }
    func propose(_ input: KDNAValue) throws -> KDNAValue {
        try open(); try CreationAuthoring.object(input, allowed: ["localKey", "alternatives"], required: ["localKey", "alternatives"])
        _ = try CreationAuthoring.key(input["localKey"])
        let alternatives = try CreationAuthoring.alternatives(input["alternatives"], materialIDs: Set(state["materials"].list.map { KDNAKey($0["id"].text) }))
        guard !state["groups"].list.contains(where: { $0["localKey"] == input["localKey"] }) else { throw CreationValues.fail("CREATION_JUDGMENT_KEY_DUPLICATE", "Judgment group already exists.") }
        let group: KDNAValue = ["localKey": input["localKey"], "alternatives": .array(alternatives), "revision": 1]
        try evolve("proposal", detail: group) { $0["groups"] = .array($0["groups"].list + [group]); $0["choices"] = .null }
        return group
    }
    func revise(_ key: String, _ input: KDNAValue) throws -> KDNAValue {
        try open(); try CreationAuthoring.object(input, allowed: ["baseRevision", "alternatives", "explanation"], required: ["baseRevision", "alternatives", "explanation"])
        _ = try CreationValues.text(input["explanation"], "explanation")
        guard let index = state["groups"].list.firstIndex(where: { $0["localKey"] == .string(key) }) else { throw CreationValues.fail("CREATION_JUDGMENT_UNKNOWN", "Judgment group does not exist.") }
        let prior = state["groups"].list[index]
        guard input["baseRevision"] == prior["revision"] else { throw CreationValues.fail("CREATION_REVISION_BASE_STALE", "Revision must name the exact current proposal revision.") }
        let alternatives = try CreationAuthoring.alternatives(input["alternatives"], materialIDs: Set(state["materials"].list.map { KDNAKey($0["id"].text) }))
        let next: KDNAValue = ["localKey": .string(key), "alternatives": .array(alternatives), "revision": .number(prior["revision"].numeric + 1)]
        try evolve("revision", detail: ["prior": prior, "next": next, "explanation": input["explanation"]]) { value in
            var groups = value["groups"].list; groups[index] = next; value["groups"] = .array(groups); value["choices"] = .null
        }
        return next
    }
    private func snapshot() throws -> KDNAValue {
        guard state["brief"] != .null, !state["materials"].list.isEmpty, !state["groups"].list.isEmpty,
              case .object = state["choices"] else { throw CreationValues.fail("CREATION_REVIEW_INCOMPLETE", "Record a brief/materials/groups and one selection per group.") }
        let selected: [KDNAValue] = try state["groups"].list.map { group in
            guard let alternative = group["alternatives"].list.first(where: { $0["localKey"] == state["choices"][group["localKey"].text] }) else {
                throw CreationValues.fail("CREATION_SELECTION_INVALID", "Current selection does not identify an alternative.")
            }
            return ["judgmentLocalKey": group["localKey"], "alternative": alternative]
        }
        return ["session_id": state["session_id"], "revision": state["revision"], "agent": agentInfo,
                "asset": try CreationIdentity.versioned(identity, revision: Int(state["revision"].numeric)), "createdAt": .string(createdAt),
                "adoption_channel": ["kind": .string(adoption.kind.rawValue), "channel": .string(adoption.channel)],
                "corePackageVersion": .string(CreationRuntime.referenceCoreVersion), "synthetic_fixture": .bool(fixture),
                "brief": state["brief"], "materials": state["materials"], "groups": state["groups"], "history": state["history"],
                "authorization": adoption.authorization ?? .null, "selected": .array(selected)]
    }
    func compilePreview() throws -> KDNAValue {
        try open(); invalidate()
        let captured = try snapshot()
        let plan = try CreationMaterialization.build(context: captured, descriptor: runtime.descriptor,
                                                     decision: ["adoption_kind": .string(adoption.kind.rawValue), "phase": "preview-only"])
        var review = try CreationAudit.preview(context: captured, plan: plan)
        review["preview_digest"] = .string(try CreationValues.digest(review))
        preview = Preview(snapshot: captured, review: review)
        return review
    }
    public func receiveAdoptionReply() async throws -> KDNAValue {
        try open(); busy = true; live = nil
        defer { busy = false }
        let review: KDNAValue = ["review_id": .string(CreationValues.uuid("review:")), "session_id": state["session_id"], "revision": state["revision"],
            "kind": .string(adoption.kind.rawValue), "channel": .string(adoption.channel), "groups": state["groups"], "preview": preview?.review ?? .null]
        do {
            let response = try await adoption.receive(review)
            guard phase == "draft", state["revision"] == review["revision"] else { throw CreationValues.fail("CREATION_SESSION_ABORTED", "The pending callback no longer owns the current session.") }
            try CreationAuthoring.object(response, allowed: ["id", "role", "channel", "review_id", "text"], required: ["id", "role", "channel", "review_id", "text"])
            let messageID = try CreationValues.text(response["id"], "reply.id")
            let text = try CreationValues.text(response["text"], "reply.text")
            let role: KDNAValue = adoption.kind == .delegatedAgentEditorial ? "agent" : "human"
            guard response["role"] == role, response["channel"] == .string(adoption.channel), response["review_id"] == review["review_id"] else { throw CreationValues.fail("CREATION_REPLY_UNBOUND", "Reply role/channel/review must match the captured input channel.") }
            guard seen.insert(KDNAKey(messageID)).inserted else { throw CreationValues.fail("CREATION_REPLY_REPLAY", "This reply was already consumed.") }
            let intent = try await interpret(text, review)
            guard phase == "draft", state["revision"] == review["revision"] else { throw CreationValues.fail("CREATION_SESSION_ABORTED", "Session changed during interpretation.") }
            try CreationAuthoring.object(intent, allowed: ["kind", "choices"], required: ["kind"])
            guard ["select", "confirm", "note", "reject"].contains(intent["kind"].text) else { throw CreationValues.fail("CREATION_INTENT_INVALID", "Unsupported adoption interpretation.") }
            let entry: KDNAValue = ["response": response, "interpretation": intent, "review": review, "interpreted_by": agentInfo, "identity": "not_verified"]
            if intent["kind"] == "select" {
                let choices = try CreationAudit.selection(intent: intent, groups: state["groups"].list)
                try evolve("selection", detail: entry) { $0["choices"] = choices }
            } else if intent["kind"] == "confirm" {
                guard !intent.has("choices"), let current = preview, current.snapshot["revision"] == state["revision"] else { throw CreationValues.fail("CREATION_FINAL_UNBOUND", "Confirmation requires the exact current pre-compiler review.") }
                let decision: KDNAValue = ["format": "kdna.studio-decision/2", "adoption_kind": .string(adoption.kind.rawValue),
                    "session_id": state["session_id"], "revision": state["revision"], "context_digest": .string(try CreationValues.digest(current.snapshot)),
                    "preview_digest": current.review["preview_digest"], "proposal_digests": current.review["proposal_digests"], "actual_reply": entry,
                    "authorization": adoption.authorization ?? .null]
                try append("final_adoption", decision)
                live = LiveContext(snapshot: current.snapshot, decision: decision, descriptor: runtime.descriptor); phase = "confirmed"
            } else {
                guard !intent.has("choices") else { throw CreationValues.fail("CREATION_INTENT_INVALID", "This intent has no selection field.") }
                try evolve(intent["kind"].text, detail: entry) { if intent["kind"] == "reject" { $0["choices"] = .null } }
            }
            return inspect()
        } catch {
            invalidate(); try append("reply_rejected", ["code": .string((error as? KDNAStudioFailure)?.code ?? "CREATION_CHANNEL_FAILURE")]); throw error
        }
    }
    public func exportAsset() throws -> KDNAStudioExport {
        guard !busy else { throw CreationValues.fail("CREATION_SESSION_BUSY", "An adoption callback is in progress.") }
        guard phase == "confirmed", let stored = live, let current = preview else { throw CreationValues.fail("CREATION_FINAL_REQUIRED", "Export requires the private confirmed live context.") }
        live = nil; phase = "compiling" // Consume before any comparison or Compiler call.
        do {
            guard stored.snapshot == current.snapshot else { throw CreationValues.fail("CREATION_CONTEXT_REPLAY_OR_STALE", "Live context no longer matches the captured authoring snapshot.") }
            let expected = try CreationMaterialization.build(context: stored.snapshot, descriptor: stored.descriptor, decision: stored.decision)
            let expectedBytes = try CreationCompiler.encodeExpected(expected)
            _ = try runtime.admit(expectedBytes, code: "CREATION_EXPECTED_CORE_REJECTED")
            let actual = try compiler(["manifest": expected["manifest"], "payload": expected["payload"]])
            guard actual == expectedBytes else { throw CreationValues.fail("CREATION_COMPILER_EXPECTATION_MISMATCH", "Compiler output differs from the independently captured pre-Compiler expectation.") }
            let evidence: KDNAValue = ["format": ["id": "kdna.studio-creation-evidence/2", "version": "2.0.0"],
                "reference_contract": runtime.tuple, "component_definition": runtime.descriptor["definition_digest"], "compiler": CreationRuntime.compiler,
                "session_id": state["session_id"], "revision": state["revision"], "context": stored.snapshot, "decision": stored.decision,
                "history": state["history"], "expected_component_bindings": expected["expectedComponents"], "presence": expected["presence"], "adoption": expected["adoption"],
                "artifact": ["bytes": .number(Double(actual.count)), "digest": .string(CreationValues.sha256(actual))],
                "identity": "not_verified", "action_authorization": "not_evaluated", "creation_accepted": "not_evaluated"]
            pending = PendingSave(expected: expected, bytes: expectedBytes, evidence: evidence); phase = "awaiting_saved_readback"
            return KDNAStudioExport(bytes: actual, evidence: evidence,
                binding: ["session_id": state["session_id"], "asset_digest": evidence["artifact"]["digest"], "evidence_digest": .string(try CreationValues.digest(evidence))],
                verification: ["status": "pending_saved_readback", "creation_accepted": "not_evaluated"])
        } catch { phase = "failed"; throw error }
    }
    public func completeSave(_ actualReadbackBytes: Data) throws -> KDNAValue {
        guard !busy, phase == "awaiting_saved_readback" else { throw CreationValues.fail("CREATION_SAVE_STATE_INVALID", "No live save completion is available.") }
        phase = "sealed"
        let captured = pending; pending = nil // Failed admission also burns this save capability.
        do {
            guard let captured else { throw CreationValues.fail("CREATION_SAVE_CONTEXT_MISSING", "Pending private save context is absent.") }
            let view = try runtime.admit(actualReadbackBytes, code: "CREATION_SAVED_CORE_REJECTED")
            guard actualReadbackBytes == captured.bytes else { throw CreationValues.fail("CREATION_SAVED_EXPECTATION_MISMATCH", "Captured file bytes differ from the pre-Compiler expectation.") }
            try CreationEvidence.checkSaved(view: view, expected: captured.expected)
            return ["status": "accepted_with_live_context", "scope": "captured saved bytes equal external pre-compiler expectation and fresh public Core observations",
                "asset_digest": view["digests"]["A"]["observed"], "evidence_digest": .string(try CreationValues.digest(captured.evidence)),
                "adoption_kind": captured.expected["decision"]["adoption_kind"], "identity": "not_verified",
                "action_authorization": "not_evaluated", "filesystem_durability": "not_proven_by_library"]
        } catch { phase = "failed"; throw error }
    }
    public func abort() -> KDNAValue { invalidate(); pending = nil; phase = "aborted"; return inspect() }
}
