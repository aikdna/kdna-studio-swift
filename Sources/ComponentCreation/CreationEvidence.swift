import Foundation
import KDNACore

enum CreationEvidence {
    static func reject(_ reason: String) -> KDNAValue {
        ["status": "inconsistent", "reason": .string(reason), "creation_accepted": "not_evaluated", "live_context": "unavailable",
         "identity": "not_verified", "action_authorization": "not_evaluated"]
    }
    static func verify(bytes: Data, evidence supplied: KDNAValue?, expectedBinding suppliedBinding: KDNAValue?) -> KDNAValue {
        do {
            let runtime = try CreationRuntime()
            let actual = try runtime.admit(bytes, code: "CREATION_CORE_REJECTED")
            let evidence = supplied ?? .null, binding = suppliedBinding ?? .null
            guard evidence["format"]["id"] == "kdna.studio-creation-evidence/2", evidence["format"]["version"] == "2.0.0" else { return reject("STUDIO_EVIDENCE_FORMAT_NOT_CURRENT") }
            try CreationAudit.record(evidence, ["format", "reference_contract", "component_definition", "compiler", "session_id", "revision", "context", "decision", "history",
                "expected_component_bindings", "presence", "adoption", "artifact", "identity", "action_authorization", "creation_accepted"])
            try CreationAudit.record(evidence["format"], ["id", "version"])
            let compiler = evidence["compiler"]
            try CreationAudit.record(compiler, ["name", "version", "provider", "artifact_sha256"])
            let js = compiler["provider"] == "javascript" && compiler["name"] == "@aikdna/kdna-studio-core" && compiler["version"] == "4.0.0-rc.components.1"
            let swift = compiler["provider"] == "swift" && compiler["name"] == "KDNAStudioCore" && compiler["version"] == "0.6.0-rc.components.1"
            guard (js || swift), compiler["artifact_sha256"] == "UNKNOWN", evidence["reference_contract"] == runtime.tuple,
                  evidence["component_definition"] == runtime.descriptor["definition_digest"] else { return reject("CREATION_PROVIDER_CONTRACT_NOT_CURRENT") }
            try CreationAudit.record(evidence["artifact"], ["bytes", "digest"])
            guard evidence["artifact"]["bytes"] == .number(Double(bytes.count)), evidence["artifact"]["digest"] == actual["digests"]["A"]["observed"] else { return reject("CREATION_ARTIFACT_BINDING_MISMATCH") }
            try CreationAudit.record(binding, ["session_id", "asset_digest", "evidence_digest"])
            guard binding["evidence_digest"] == .string(try CreationValues.digest(evidence)), binding["session_id"] == evidence["session_id"],
                  binding["asset_digest"] == actual["digests"]["A"]["observed"] else { return reject("CREATION_BINDING_MISMATCH") }
            guard evidence["identity"] == "not_verified", evidence["action_authorization"] == "not_evaluated", evidence["creation_accepted"] == "not_evaluated" else { return reject("CREATION_AUTHORITY_CLAIM_INVALID") }
            let context = evidence["context"], decision = evidence["decision"]
            guard context["session_id"] == evidence["session_id"], context["revision"] == evidence["revision"],
                  decision["session_id"] == evidence["session_id"], decision["revision"] == evidence["revision"],
                  decision["context_digest"] == .string(try CreationValues.digest(context)) else { return reject("CREATION_CONTEXT_BINDING_MISMATCH") }
            guard ["human_claim_unverified", "delegated_agent_editorial"].contains(decision["adoption_kind"].text),
                  context["adoption_channel"]["kind"] == decision["adoption_kind"], context["authorization"] == decision["authorization"] else { return reject("CREATION_ADOPTION_KIND_UNBOUND") }
            if decision["adoption_kind"] == "delegated_agent_editorial" {
                try CreationAudit.record(context["authorization"], ["coordinate", "statement"])
                guard CreationValues.truthy(context["authorization"]["coordinate"]), CreationValues.truthy(context["authorization"]["statement"]) else { return reject("CREATION_AUTHORIZATION_RECORD_MISSING") }
            } else if context["authorization"] != .null { return reject("CREATION_AUTHORIZATION_RECORD_INVALID") }
            guard context["corePackageVersion"] == .string(CreationRuntime.referenceCoreVersion) else { return reject("CREATION_CONTEXT_GRAPH_NOT_CURRENT") }
            let materials = try CreationAuthoring.list(context["materials"], "context.materials")
            for material in materials {
                guard case .string(let content) = material["content"], material["content_digest"] == .string(CreationValues.sha256(Data(content.utf8))) else { return reject("CREATION_MATERIAL_MISMATCH") }
            }
            let groups = try CreationAuthoring.list(context["groups"], "context.groups")
            for group in groups { try CreationAudit.group(group, materials: materials) }
            let selected = try CreationAuthoring.list(context["selected"], "context.selected")
            guard selected.count == groups.count, Set(selected.map { KDNAKey($0["judgmentLocalKey"].text) }).count == selected.count else { return reject("CREATION_SELECTION_INVALID") }
            for item in selected {
                guard let group = groups.first(where: { $0["localKey"] == item["judgmentLocalKey"] }), group["alternatives"].list.contains(item["alternative"]) else { return reject("CREATION_SELECTED_INPUT_MISMATCH") }
            }
            let final = decision["actual_reply"], response = final["response"], review = final["review"], channel = context["adoption_channel"]["channel"]
            let role: KDNAValue = decision["adoption_kind"] == "delegated_agent_editorial" ? "agent" : "human"
            guard response["channel"] == channel, review["channel"] == channel, review["kind"] == decision["adoption_kind"], response["role"] == role,
                  response["review_id"] == review["review_id"], review["session_id"] == context["session_id"], review["revision"] == context["revision"],
                  final["interpretation"]["kind"] == "confirm", review["preview"]["preview_digest"] == decision["preview_digest"] else { return reject("CREATION_FINAL_REPLY_UNBOUND") }
            let history = try CreationAuthoring.list(evidence["history"], "history")
            var previous: KDNAValue = .null
            for (index, event) in history.enumerated() {
                var body = event; body.remove("digest")
                guard event["sequence"] == .number(Double(index + 1)), event["previous_digest"] == previous,
                      event["digest"] == .string(try CreationValues.digest(body)) else { return reject("CREATION_HISTORY_MISMATCH") }
                previous = event["digest"]
            }
            guard let last = history.last, last["event"] == "final_adoption", last["detail"] == decision else { return reject("CREATION_FINAL_HISTORY_MISMATCH") }
            try CreationAudit.validate(evidence, descriptor: runtime.descriptor)
            let expected = try CreationMaterialization.build(context: context, descriptor: runtime.descriptor, decision: decision)
            let expectedView = try runtime.admit(CreationCompiler.encodeExpected(expected), code: "CREATION_STATIC_MATERIALIZATION_MISMATCH")
            guard expectedView["ir"] == actual["ir"], expected["expectedComponents"] == evidence["expected_component_bindings"],
                  expected["presence"] == evidence["presence"], expected["adoption"] == evidence["adoption"] else { return reject("CREATION_STATIC_MATERIALIZATION_MISMATCH") }
            return ["status": "consistent", "format": evidence["format"], "asset_digest": actual["digests"]["A"]["observed"],
                    "evidence_digest": binding["evidence_digest"], "adoption_kind": decision["adoption_kind"], "core": "valid", "interpretation": "supported",
                    "creation_accepted": "not_evaluated", "live_context": "unavailable", "identity": "not_verified", "action_authorization": "not_evaluated"]
        } catch { return reject((error as? KDNAStudioFailure)?.code ?? "CREATION_EVIDENCE_MALFORMED") }
    }

    static func checkSaved(view: KDNAValue, expected: KDNAValue) throws {
        try CreationAudit.require(view["asset"] == expected["payload"]["asset"], "CREATION_SAVED_ASSET_MISMATCH")
        let nodes = view["ir"]["nodes"].list, methods = nodes.filter { $0["role"] == "method" }
        let judgments = expected["payload"]["judgments"].list
        func sorted(_ values: [KDNAValue]) -> [KDNAValue] {
            values.sorted { CreationMaterialization.utf8Less($0["id"].text, $1["id"].text) }
        }
        try CreationAudit.require(sorted(nodes.filter { $0["role"] == "judgment" }.map { $0["value"] }) == sorted(judgments), "CREATION_SAVED_JUDGMENT_MISMATCH")
        for judgment in judgments {
            let owned = methods.filter { $0["owner_judgment_id"] == judgment["id"] }
            if !judgment.has("method") { try CreationAudit.require(owned.isEmpty, "CREATION_METHOD_INVENTED"); continue }
            try CreationAudit.require(owned.count == 1 && owned[0]["value"]["declaration"] == judgment["method"], "CREATION_METHOD_CHANGED")
            let presence = expected["presence"].list.first { $0["judgment_ref"] == judgment["id"] }
            let state: KDNAValue = presence.map { ["components_state": $0["components_state"], "bindings_state": $0["bindings_state"]] }
                ?? ["components_state": "declared", "bindings_state": "declared"]
            try CreationAudit.require(owned[0]["value"]["declaration_presence"] == state, "CREATION_PRESENCE_CHANGED")
            let desired = expected["expectedComponents"].list.filter { $0["carrier"]["judgment_ref"] == judgment["id"] }
            let observed = owned[0]["value"]["component_interpretations"].list
            try CreationAudit.require(observed.count == desired.count, "CREATION_COMPONENT_SET_CHANGED")
            for entry in desired {
                guard let actual = observed.first(where: { $0["component_ref"] == entry["carrier"]["component_ref"] }) else { throw CreationValues.fail("CREATION_COMPONENT_CHANGED", "Expected interpretation is absent.") }
                try CreationAudit.require(actual["status"] == "supported" && actual["authored_content"] == entry["carrier"]["content"], "CREATION_COMPONENT_CHANGED")
                for key in ["judgment_ref", "component_type", "definition_digest", "profile_id", "content_digest", "component_declaration_digest", "statement_origin", "bindings_digest", "adoption_proposal_digest"] {
                    try CreationAudit.require(actual[key] == entry["carrier"][key], "CREATION_COMPONENT_BINDING_CHANGED")
                }
                try CreationAudit.require(actual["declaration_digest"] == .string(try CreationValues.digest(entry["carrier"])), "CREATION_COMPONENT_DECLARATION_CHANGED")
            }
        }
    }
}
