import Foundation
import KDNACore

// Replays the private authoring audit. It is not a wire parser and never
// creates a live context from a transcript, digest or claimed confirmation.
enum CreationAudit {
    static func require(_ condition: Bool, _ code: String) throws {
        guard condition else { throw CreationValues.fail(code, "Current creation evidence is inconsistent.") }
    }
    static func record(_ value: KDNAValue, _ fields: [String], required: [String]? = nil) throws {
        try CreationAuthoring.object(value, allowed: fields, required: required ?? fields)
    }
    static func date(_ value: KDNAValue) -> Bool {
        guard case .string(let text) = value else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: text) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text) != nil
    }
    static func positiveRevision(_ value: KDNAValue) -> Bool {
        guard case .number(let number) = value else { return false }
        return number.isFinite && number >= 1 && number <= 9007199254740991 && number.rounded() == number
    }
    static func selection(intent: KDNAValue, groups: [KDNAValue]) throws -> KDNAValue {
        let choices = try CreationAuthoring.list(intent["choices"], "choices")
        try require(choices.count == groups.count, "CREATION_SELECTION_INCOMPLETE")
        var result: KDNAValue = [:]
        for choice in choices {
            try record(choice, ["judgmentLocalKey", "alternativeLocalKey"])
            guard let group = groups.first(where: { $0["localKey"] == choice["judgmentLocalKey"] }),
                  !result.has(choice["judgmentLocalKey"].text),
                  group["alternatives"].list.contains(where: { $0["localKey"] == choice["alternativeLocalKey"] }) else {
                throw CreationValues.fail("CREATION_SELECTION_INVALID", "Selection must name one current alternative in each group.")
            }
            result[choice["judgmentLocalKey"].text] = choice["alternativeLocalKey"]
        }
        return result
    }
    static func preview(context: KDNAValue, plan: KDNAValue) throws -> KDNAValue {
        ["session_id": context["session_id"], "revision": context["revision"], "kind": "pre_compiler_authoring_review",
         "context_digest": .string(try CreationValues.digest(context)), "selected": context["selected"],
         "expected_component_bindings": plan["expectedComponents"], "presence": plan["presence"],
         "proposal_digests": plan["proposalDigests"], "creation_accepted": "not_evaluated"]
    }
    static func group(_ value: KDNAValue, materials: [KDNAValue]) throws {
        try record(value, ["localKey", "alternatives", "revision"])
        _ = try CreationAuthoring.key(value["localKey"])
        _ = try CreationAuthoring.alternatives(value["alternatives"], materialIDs: Set(materials.map { KDNAKey($0["id"].text) }))
    }
    static func reply(_ entry: KDNAValue, context: KDNAValue, seen: inout Set<KDNAKey>) throws {
        try record(entry, ["response", "interpretation", "review", "interpreted_by", "identity"])
        let response = entry["response"], review = entry["review"], channel = context["adoption_channel"]
        try record(response, ["id", "role", "channel", "review_id", "text"])
        _ = try CreationValues.text(response["id"], "response.id"); _ = try CreationValues.text(response["text"], "response.text")
        try record(review, ["review_id", "session_id", "revision", "kind", "channel", "groups", "preview"])
        let role: KDNAValue = channel["kind"] == "delegated_agent_editorial" ? "agent" : "human"
        try require(entry["identity"] == "not_verified" && entry["interpreted_by"] == context["agent"] && response["role"] == role &&
            response["channel"] == channel["channel"] && review["channel"] == channel["channel"] && review["kind"] == channel["kind"] &&
            review["session_id"] == context["session_id"] && response["review_id"] == review["review_id"] &&
            !seen.contains(KDNAKey(response["id"].text)), "CREATION_AUDIT_REPLY_INVALID")
        seen.insert(KDNAKey(response["id"].text))
        try record(entry["interpretation"], ["kind", "choices"], required: ["kind"])
    }
    static func validate(_ evidence: KDNAValue, descriptor: KDNAValue) throws {
        let c = evidence["context"], d = evidence["decision"]
        try record(c, ["session_id", "revision", "agent", "asset", "createdAt", "adoption_channel", "corePackageVersion",
                       "synthetic_fixture", "brief", "materials", "groups", "history", "authorization", "selected"])
        try record(c["agent"], ["name", "version"])
        for field in ["name", "version"] { _ = try CreationValues.text(c["agent"][field], "agent." + field) }
        try record(c["asset"], ["asset_id", "asset_uid", "version"])
        for value in c["asset"].fields.values { _ = try CreationValues.text(value, "asset") }
        try record(c["adoption_channel"], ["kind", "channel"]); _ = try CreationValues.text(c["adoption_channel"]["channel"], "channel")
        try record(c["brief"], ["title", "scope"])
        for field in ["title", "scope"] { _ = try CreationValues.text(c["brief"][field], field) }
        guard case .bool = c["synthetic_fixture"] else { throw CreationValues.fail("CREATION_CONTEXT_INVALID", "Fixture field is not Boolean.") }
        try require(positiveRevision(c["revision"]) && date(c["createdAt"]), "CREATION_CONTEXT_INVALID")
        try record(d, ["format", "adoption_kind", "session_id", "revision", "context_digest", "preview_digest", "proposal_digests", "actual_reply", "authorization"])
        try require(d["format"] == "kdna.studio-decision/2" && d["adoption_kind"] == c["adoption_channel"]["kind"], "CREATION_DECISION_INVALID")
        let history = try CreationAuthoring.list(c["history"], "context.history")
        var revision = 0, brief: KDNAValue = .null, materials = [KDNAValue](), groups = [KDNAValue](), choices: KDNAValue = .null
        var previous: KDNAValue = .null, seen = Set<KDNAKey>()
        for (index, event) in history.enumerated() {
            try record(event, ["sequence", "revision", "event", "at", "detail", "previous_digest", "digest"])
            var body = event; body.remove("digest")
            try require(event["sequence"] == .number(Double(index + 1)) && event["previous_digest"] == previous &&
                        event["digest"] == .string(try CreationValues.digest(body)) && date(event["at"]), "CREATION_HISTORY_MISMATCH")
            previous = event["digest"]
            let value = event["detail"]
            if event["event"] == "reply_rejected" {
                try record(value, ["code"]); _ = try CreationValues.text(value["code"], "code")
                try require(event["revision"] == .number(Double(revision)), "CREATION_HISTORY_REVISION_MISMATCH")
                continue
            }
            switch event["event"].text {
            case "brief":
                try record(value, ["title", "scope"])
                for field in ["title", "scope"] { _ = try CreationValues.text(value[field], field) }
                brief = value; choices = .null
            case "material":
                try record(value, ["id", "kind", "title", "content", "coordinate", "content_digest", "recorded_at"])
                for field in ["id", "title", "content", "coordinate", "recorded_at"] { _ = try CreationValues.text(value[field], field) }
                try require((value["kind"] == "text" || value["kind"] == "interview") && date(value["recorded_at"]) &&
                    value["content_digest"] == .string(CreationValues.sha256(Data(value["content"].text.utf8))) &&
                    !materials.contains(where: { $0["id"] == value["id"] || $0["coordinate"] == value["coordinate"] }), "CREATION_MATERIAL_MISMATCH")
                materials.append(value); choices = .null
            case "proposal":
                try record(value, ["localKey", "alternatives", "revision"])
                try require(value["revision"] == 1 && !groups.contains(where: { $0["localKey"] == value["localKey"] }), "CREATION_AUDIT_PROPOSAL_INVALID")
                try group(value, materials: materials); groups.append(value); choices = .null
            case "revision":
                try record(value, ["prior", "next", "explanation"]); _ = try CreationValues.text(value["explanation"], "explanation")
                guard let index = groups.firstIndex(where: { $0["localKey"] == value["prior"]["localKey"] }) else { throw CreationValues.fail("CREATION_AUDIT_REVISION_INVALID", "Revised group missing.") }
                try require(groups[index] == value["prior"] && value["next"]["localKey"] == value["prior"]["localKey"] &&
                            value["next"]["revision"] == .number(value["prior"]["revision"].numeric + 1), "CREATION_AUDIT_REVISION_INVALID")
                try group(value["next"], materials: materials); groups[index] = value["next"]; choices = .null
            case "selection", "note", "reject":
                try reply(value, context: c, seen: &seen)
                try require(value["review"]["revision"] == .number(Double(revision)) && value["review"]["groups"] == .array(groups), "CREATION_AUDIT_REVIEW_STALE")
                if event["event"] == "selection" {
                    try require(value["interpretation"]["kind"] == "select", "CREATION_AUDIT_INTENT_MISMATCH")
                    choices = try selection(intent: value["interpretation"], groups: groups)
                } else {
                    try require(value["interpretation"]["kind"] == event["event"] && !value["interpretation"].has("choices"), "CREATION_AUDIT_INTENT_MISMATCH")
                    if event["event"] == "reject" { choices = .null }
                }
            default: throw CreationValues.fail("CREATION_HISTORY_EVENT_UNSUPPORTED", "This history event is not current authoring.")
            }
            revision += 1
            try require(event["revision"] == .number(Double(revision)), "CREATION_HISTORY_REVISION_MISMATCH")
        }
        try require(choices != .null && .number(Double(revision)) == c["revision"] && brief == c["brief"] &&
                    .array(materials) == c["materials"] && .array(groups) == c["groups"], "CREATION_AUDIT_STATE_MISMATCH")
        let selected: [KDNAValue] = try groups.map { group in
            guard let alternative = group["alternatives"].list.first(where: { $0["localKey"] == choices[group["localKey"].text] }) else { throw CreationValues.fail("CREATION_AUDIT_SELECTED_MISMATCH", "Selected alternative missing.") }
            return ["judgmentLocalKey": group["localKey"], "alternative": alternative]
        }
        try require(.array(selected) == c["selected"], "CREATION_AUDIT_SELECTED_MISMATCH")
        let plan = try CreationMaterialization.build(context: c, descriptor: descriptor, decision: ["adoption_kind": d["adoption_kind"], "phase": "preview-only"])
        var expectedPreview = try preview(context: c, plan: plan)
        expectedPreview["preview_digest"] = .string(try CreationValues.digest(expectedPreview))
        try reply(d["actual_reply"], context: c, seen: &seen)
        let actual = d["actual_reply"]
        try require(actual["review"]["revision"] == c["revision"] && actual["review"]["groups"] == c["groups"] &&
            actual["interpretation"]["kind"] == "confirm" && !actual["interpretation"].has("choices") && actual["review"]["preview"] == expectedPreview &&
            d["preview_digest"] == expectedPreview["preview_digest"] && d["proposal_digests"] == plan["proposalDigests"], "CREATION_PREVIEW_ADOPTION_MISMATCH")
        let full = try CreationAuthoring.list(evidence["history"], "history")
        try require(full.count == history.count + 1 && Array(full.dropLast()) == history, "CREATION_CONTEXT_HISTORY_MISMATCH")
        guard let final = full.last else { throw CreationValues.fail("CREATION_FINAL_HISTORY_MISMATCH", "Final history is absent.") }
        try record(final, ["sequence", "revision", "event", "at", "detail", "previous_digest", "digest"])
        var body = final; body.remove("digest")
        try require(final["sequence"] == .number(Double(history.count + 1)) && final["revision"] == c["revision"] &&
            final["event"] == "final_adoption" && final["detail"] == d && final["previous_digest"] == previous &&
            final["digest"] == .string(try CreationValues.digest(body)) && date(final["at"]), "CREATION_FINAL_HISTORY_MISMATCH")
    }
}
