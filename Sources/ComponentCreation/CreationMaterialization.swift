import Foundation
import KDNACore

// One versioned authoring-to-wire mapping. There is no duplicated component
// interpreter here: public Core validates and derives every supported body.
enum CreationMaterialization {
    static func semantic(_ value: KDNAValue) -> KDNAValue {
        switch value {
        case .null: return ["kind": "null", "value": nil]
        case .string: return ["kind": "text", "value": value]
        case .number: return ["kind": "number", "value": value]
        case .bool: return ["kind": "boolean", "value": value]
        case .array(let values): return ["kind": "list", "items": .array(values.map(semantic))]
        case .object(let fields):
            let keys = fields.keys.sorted { $0.text.utf16.lexicographicallyPrecedes($1.text.utf16) }
            return ["kind": "record", "fields": .array(keys.map { ["name": .string($0.text), "value": semantic(fields[$0]!)] })]
        }
    }

    static func utf8Less(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }

    static func build(context: KDNAValue, descriptor: KDNAValue, decision: KDNAValue) throws -> KDNAValue {
        guard descriptor["contract_id"] == "kdna.component-semantics/1", descriptor["contract_version"] == "1.0.0",
              descriptor["definition_digest"] == .string(CreationRuntime.definitionDigest) else {
            throw CreationValues.fail("CREATION_COMPONENT_CONTRACT_MISMATCH", "Only the fixed public descriptor is supported.")
        }
        let s = context, contextDigest = try CreationValues.digest(s)
        _ = try CreationValues.text(s["corePackageVersion"], "corePackageVersion")
        var generated = [KDNAValue](), occupied = Set<KDNAKey>()
        func mint(_ kind: String, _ keys: [String]) throws -> KDNAValue {
            for key in keys { _ = try CreationAuthoring.key(.string(key)) }
            let id = try CreationIdentity.mint(kind, assetID: s["asset"]["asset_id"].text,
                                               judgmentKey: keys[0], additionalKeys: Array(keys.dropFirst()))
            guard occupied.insert(KDNAKey(id)).inserted else {
                throw CreationValues.fail("CREATION_GENERATED_ID_COLLISION", "Generated protocol identity collided; no retry or suffix is permitted.")
            }
            generated.append(.string(id)); return .string(id)
        }
        func carrier(_ kind: String, _ value: KDNAValue) -> KDNAValue {
            let schema = descriptor["carriers"][kind]
            return ["id": schema["id"], "critical": schema["critical"], "definition": schema["definition"], "value": semantic(value)]
        }
        var judgments = [KDNAValue](), reasons = [KDNAValue](), sources = [KDNAValue](), sourceUses = [KDNAValue]()
        var materials = [KDNAValue](), declarations = [KDNAValue](), presence = [KDNAValue](), expectedComponents = [KDNAValue]()
        var groupKeys = Set<KDNAKey>()
        for selected in s["selected"].list {
            let key = selected["judgmentLocalKey"].text, a = selected["alternative"]
            guard groupKeys.insert(KDNAKey(key)).inserted else { throw CreationValues.fail("CREATION_JUDGMENT_KEY_DUPLICATE", "Selected owner was repeated.") }
            let jid = try mint("judgment", [key]), rid = try mint("reason", [key]), rcid = try mint("result-contract", [key])
            var judgment: KDNAValue = [
                "id": jid, "label": a["title"], "focus": a["title"], "subject": ["actor_ids": [], "statement": a["subject"]],
                "scope": ["statement": a["scope"]],
                "result_contract": ["id": rcid, "form": ["term": "text"], "shape": ["kind": "scalar", "scalar_type": "text"],
                                    "minimum": 1, "maximum": 1, "allowed_result_types": [["term": "text"]]],
                "result": ["contract_ref": rcid, "result_type": ["term": "text"], "value": ["kind": "text", "value": a["statement"]]],
                "reason_refs": .array([rid]),
            ]
            if a.has("formationRule") {
                judgment.remove("result")
                judgment["formation_rule"] = ["statement": a["statement"], "conditions": a["formationRule"]["conditions"], "output_contract_ref": rcid]
            }
            reasons.append(["id": rid, "role": "support", "judgment_ref": jid, "statement": a["rationale"], "component_refs": []])
            var componentIDs = [KDNAKey: KDNAValue]()
            for component in a["method"]["components"].list {
                componentIDs[KDNAKey(component["localKey"].text)] = try mint("component", [key, component["localKey"].text])
            }
            if a.has("method") {
                let state: KDNAValue = ["judgment_ref": jid,
                                       "components_state": a["method"].has("components") ? "declared" : "undeclared",
                                       "bindings_state": a["method"].has("bindings") ? "declared" : "undeclared"]
                let nativeBindings: [KDNAValue] = try a["method"]["bindings"].list.map { binding in
                    guard let cid = componentIDs[KDNAKey(binding["componentLocalKey"].text)] else {
                        throw CreationValues.fail("CREATION_COMPONENT_BINDING_UNKNOWN", "Binding component is absent.")
                    }
                    return ["component_ref": cid, "role": binding["role"], "target_ref": jid]
                }
                judgment["method"] = ["method": a["method"]["method"], "components": [], "bindings": .array(nativeBindings)]
                if state["components_state"] == "undeclared" || state["bindings_state"] == "undeclared" {
                    judgment["extensions"] = .array([carrier("presence", state)]); presence.append(state)
                }
                for component in a["method"]["components"].list {
                    let local = component["localKey"].text
                    guard let cid = componentIDs[KDNAKey(local)] else { throw CreationValues.fail("CREATION_COMPONENT_BINDING_UNKNOWN", "Component ID missing.") }
                    var content = component["content"]
                    if component["type"] == "discriminator-set" {
                        guard let target = a["method"]["components"].list.first(where: {
                            $0["localKey"] == content["candidateSetLocalKey"] && $0["type"] == "candidate-set"
                        }), let targetID = componentIDs[KDNAKey(target["localKey"].text)] else {
                            throw CreationValues.fail("CREATION_COMPONENT_TARGET_UNKNOWN", "Discriminator target is not an authored candidate set.")
                        }
                        content["candidateSetRef"] = targetID; content.remove("candidateSetLocalKey")
                    }
                    let origin: KDNAValue = component.has("statement") ? "authored" : "mechanical_content_representation"
                    let statement = component.has("statement") ? component["statement"] : .string(String(decoding: try CreationValues.canonicalEvidence(content), as: UTF8.self))
                    let native: KDNAValue = ["id": cid, "method": ["term": component["type"]], "statement": statement]
                    var method = judgment["method"]; method["components"] = .array(method["components"].list + [native]); judgment["method"] = method
                    let bindings = nativeBindings.filter { $0["component_ref"] == cid }.sorted {
                        if $0["role"] != $1["role"] { return utf8Less($0["role"].text, $1["role"].text) }
                        return utf8Less($0["target_ref"].text, $1["target_ref"].text)
                    }
                    guard let profile = descriptor["profiles"].list.first(where: { $0["component_type"] == component["type"] }) else {
                        throw CreationValues.fail("CREATION_COMPONENT_TYPE_UNSUPPORTED", "Component type absent from public descriptor.")
                    }
                    let proposal: KDNAValue = ["rule": .string(CreationIdentity.materializationRule), "context_digest": .string(contextDigest),
                        "asset": s["asset"], "judgmentLocalKey": .string(key), "alternativeLocalKey": a["localKey"], "componentLocalKey": component["localKey"],
                        "profile": profile, "definition_digest": .string(CreationRuntime.definitionDigest), "authored_candidate_digest": .string(try CreationValues.digest(a)),
                        "content": content, "native_component": native, "statement_origin": origin, "bindings": .array(bindings), "presence": state]
                    let declaration: KDNAValue = ["contract_id": descriptor["contract_id"], "contract_version": descriptor["contract_version"],
                        "definition_digest": .string(CreationRuntime.definitionDigest), "judgment_ref": jid, "component_ref": cid, "component_type": component["type"],
                        "profile_id": profile["profile_id"], "content": content, "content_digest": .string(try CreationValues.digest(content)),
                        "component_declaration_digest": .string(try CreationValues.digest(["component": native, "statement_origin": origin])),
                        "statement_origin": origin, "bindings_digest": .string(try CreationValues.digest(.array(bindings))),
                        "adoption_proposal_digest": .string(try CreationValues.digest(proposal))]
                    judgment["extensions"] = .array(judgment["extensions"].list + [carrier("component", declaration)])
                    declarations.append(declaration)
                    expectedComponents.append(["proposal": proposal, "carrier": declaration, "native_component": native, "bindings": .array(bindings), "presence": state])
                }
            }
            var sourceIDs = [KDNAKey: KDNAValue]()
            for source in a["publicSources"].list {
                let sid = try mint("source", [key, source["localKey"].text]); sourceIDs[KDNAKey(source["localKey"].text)] = sid
                var record: KDNAValue = ["id": sid, "identity": source["identity"]]
                for field in ["version", "digest"] where source.has(field) { record[field] = source[field] }
                sources.append(record)
                for use in source["uses"].list {
                    let component = use.has("componentLocalKey")
                    guard let target = component ? componentIDs[KDNAKey(use["componentLocalKey"].text)] : jid else {
                        throw CreationValues.fail("CREATION_SOURCE_TARGET_UNKNOWN", "Source-use target is absent.")
                    }
                    sourceUses.append(["id": try mint("source-use", [key, source["localKey"].text, use["localKey"].text]),
                                       "role": use["role"], "source_ref": sid, "target_kind": component ? "method_component" : "judgment", "target_ref": target])
                }
            }
            if a.has("publicNotices") {
                judgment["material_refs"] = []
                for notice in a["publicNotices"].list {
                    let refs: [KDNAValue] = try notice["sourceLocalKeys"].list.map {
                        guard let ref = sourceIDs[KDNAKey($0.text)] else { throw CreationValues.fail("CREATION_NOTICE_SOURCE_UNKNOWN", "Notice source missing.") }; return ref
                    }
                    let id = try mint("material", [key, notice["localKey"].text])
                    judgment["material_refs"] = .array(judgment["material_refs"].list + [id])
                    materials.append(["id": id, "kind": "attachment", "statement": notice["statement"], "source_refs": .array(refs)])
                }
            }
            judgments.append(judgment)
        }
        declarations.sort {
            if $0["judgment_ref"] != $1["judgment_ref"] { return utf8Less($0["judgment_ref"].text, $1["judgment_ref"].text) }
            return utf8Less($0["component_ref"].text, $1["component_ref"].text)
        }
        let proposals = Set(declarations.map { KDNAKey($0["adoption_proposal_digest"].text) }).map(\.text).sorted(by: utf8Less).map(KDNAValue.string)
        var payload: KDNAValue = ["profile": "kdna.payload.judgment", "profile_version": "0.2.0",
            "asset": ["asset_id": s["asset"]["asset_id"], "asset_version": s["asset"]["version"], "judgment_version": s["asset"]["version"]],
            "actors": [], "scope": ["statement": s["brief"]["scope"]], "judgments": .array(judgments), "reasons": .array(reasons)]
        if !sources.isEmpty { payload["sources"] = .array(sources) }
        if !sourceUses.isEmpty { payload["source_uses"] = .array(sourceUses) }
        if !materials.isEmpty { payload["materials"] = .array(materials) }
        var adoption: KDNAValue = .null
        if !declarations.isEmpty {
            guard ["human_claim_unverified", "delegated_agent_editorial"].contains(decision["adoption_kind"].text) else {
                throw CreationValues.fail("CREATION_DECISION_REQUIRED", "Component creation requires an explicit adoption kind.")
            }
            adoption = ["contract_id": descriptor["contract_id"], "contract_version": descriptor["contract_version"],
                "definition_digest": .string(CreationRuntime.definitionDigest), "declaration_set_digest": .string(try CreationValues.digest(.array(declarations))),
                "proposal_set_digest": .string(try CreationValues.digest(.array(proposals))), "decision_digest": .string(try CreationValues.digest(decision)), "adoption_kind": decision["adoption_kind"]]
            payload["extensions"] = .array([carrier("adoption", adoption)])
        }
        let manifest: KDNAValue = ["format_version": "0.2.0", "asset_id": s["asset"]["asset_id"], "asset_uid": s["asset"]["asset_uid"],
            "asset_type": s["synthetic_fixture"] == true ? "fixture" : "domain", "title": s["brief"]["title"],
            "version": s["asset"]["version"], "judgment_version": s["asset"]["version"], "created_at": s["createdAt"], "updated_at": s["createdAt"],
            "compatibility": ["min_loader_version": s["corePackageVersion"], "profile": "kdna.payload.judgment", "profile_version": "0.2.0"],
            "payload": ["path": "payload.kdnab", "encoding": "cbor", "encrypted": false], "runtime": ["mandatory_entries": []]]
        return ["rule": .string(CreationIdentity.materializationRule), "context_digest": .string(contextDigest), "manifest": manifest, "payload": payload,
                "expectedComponents": .array(expectedComponents), "presence": .array(presence), "adoption": adoption,
                "proposalDigests": .array(proposals), "decision": decision, "generated_ids": .array(generated)]
    }
}
