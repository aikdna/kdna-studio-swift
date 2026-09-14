import Foundation
import KDNACore

// This is the bounded Studio authoring grammar. It neither parses a wire asset
// nor independently interprets component content; public Core performs that job.
enum CreationAuthoring {
    static func object(_ value: KDNAValue, allowed: [String], required: [String]) throws {
        _ = try CreationValues.canonicalEvidence(value)
        try CreationValues.record(value, fields: allowed)
        guard required.allSatisfy({ value.has($0) }) else {
            throw CreationValues.fail("STUDIO_INPUT_INVALID", "Required authoring field is missing.")
        }
    }

    static func list(_ value: KDNAValue, _ name: String) throws -> [KDNAValue] {
        guard case .array(let items) = value else {
            throw CreationValues.fail("STUDIO_INPUT_INVALID", "\(name) requires an explicit array.")
        }
        return items
    }

    static func key(_ value: KDNAValue) throws -> String {
        guard case .string(let text) = value else {
            throw CreationValues.fail("STUDIO_LOCAL_KEY_INVALID", "Local key must be a string.")
        }
        let bytes = Array(text.utf8)
        guard (1...64).contains(bytes.count), let first = bytes.first, (97...122).contains(first),
              bytes.dropFirst().allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
            throw CreationValues.fail("STUDIO_LOCAL_KEY_INVALID", "Local key requires the complete bounded ASCII grammar.")
        }
        return text
    }

    static func unique(_ items: [KDNAValue], field: String, code: String) throws {
        var seen = Set<KDNAKey>()
        for item in items {
            let local = try key(item[field])
            guard seen.insert(KDNAKey(local)).inserted else {
                throw CreationValues.fail(code, "Local keys must be unique within their owner.")
            }
        }
    }

    static func method(_ value: KDNAValue) throws -> KDNAValue {
        try object(value, allowed: ["method", "components", "bindings"], required: ["method"])
        try object(value["method"], allowed: ["term", "extension"], required: ["term"])
        guard case .object = value["method"] else {
            throw CreationValues.fail("STUDIO_METHOD_REQUIRED", "An authored method requires an actual public TermRef.")
        }
        _ = try CreationValues.text(value["method"]["term"], "method.term")
        // Preserve the complete public TermRef. Its exact protocol schema is
        // checked through public Core when the independently expected plan is made.
        let components = value.has("components") ? try list(value["components"], "method.components") : []
        try unique(components, field: "localKey", code: "STUDIO_COMPONENT_KEY_DUPLICATE")
        for component in components {
            try object(component, allowed: ["localKey", "type", "content", "statement"], required: ["localKey", "type", "content"])
            guard ["taxonomy", "candidate-set", "discriminator-set"].contains(component["type"].text) else {
                throw CreationValues.fail("STUDIO_COMPONENT_TYPE_UNSUPPORTED", "Only the three registered component types are authored here.")
            }
            guard case .object = component["content"] else {
                throw CreationValues.fail("STUDIO_COMPONENT_CONTENT_INVALID", "Component content requires a record.")
            }
            if component.has("statement") { _ = try CreationValues.text(component["statement"], "component.statement") }
            if component["type"] == "taxonomy" {
                try object(component["content"], allowed: ["items", "broader"], required: ["items", "broader"])
                _ = try list(component["content"]["broader"], "content.broader")
            } else if component["type"] == "candidate-set" {
                try object(component["content"], allowed: ["items"], required: ["items"])
            }
            _ = try list(component["content"]["items"], "content.items")
            if component["type"] == "discriminator-set" {
                try object(component["content"], allowed: ["candidateSetLocalKey", "items"], required: ["candidateSetLocalKey", "items"])
                let target = try key(component["content"]["candidateSetLocalKey"])
                guard components.contains(where: { $0["localKey"] == .string(target) && $0["type"] == "candidate-set" }) else {
                    throw CreationValues.fail("STUDIO_COMPONENT_REFERENCE_INVALID", "Discriminator must target a candidate set in its owning judgment.")
                }
            }
            // Items, edges and contrasts stay exact. Shared public Core is the
            // only validator/interpreter for their grammar, limits and meaning.
        }
        if value.has("bindings") {
            let bindings = try list(value["bindings"], "method.bindings")
            var seen = Set<KDNAKey>()
            for binding in bindings {
                try object(binding, allowed: ["componentLocalKey", "role"], required: ["componentLocalKey", "role"])
                let component = try key(binding["componentLocalKey"])
                _ = try CreationValues.text(binding["role"], "binding.role")
                guard components.contains(where: { $0["localKey"] == .string(component) }) else {
                    throw CreationValues.fail("STUDIO_COMPONENT_REFERENCE_INVALID", "Binding requires a component in its owning judgment.")
                }
                let digest = try CreationValues.digest(binding)
                guard seen.insert(KDNAKey(digest)).inserted else {
                    throw CreationValues.fail("STUDIO_BINDING_DUPLICATE", "Repeated role binding is ambiguous.")
                }
            }
        }
        return value
    }

    static func alternative(_ value: KDNAValue, materialIDs: Set<KDNAKey>) throws -> KDNAValue {
        try object(value, allowed: ["localKey", "title", "subject", "scope", "statement", "rationale", "materialRefs", "method", "formationRule", "publicSources", "publicNotices"], required: ["localKey", "title", "subject", "scope", "statement", "rationale", "materialRefs"])
        _ = try key(value["localKey"])
        for name in ["title", "subject", "scope", "statement", "rationale"] { _ = try CreationValues.text(value[name], name) }
        let refs = try list(value["materialRefs"], "materialRefs")
        guard !refs.isEmpty, Set(refs.map { KDNAKey($0.text) }).count == refs.count,
              refs.allSatisfy({ if case .string(let id) = $0 { return materialIDs.contains(KDNAKey(id)) }; return false }) else {
            throw CreationValues.fail("STUDIO_MATERIAL_REFERENCE_INVALID", "Each alternative must bind actual recorded materials.")
        }
        if value.has("method") { _ = try method(value["method"]) }
        if value.has("formationRule") {
            try object(value["formationRule"], allowed: ["conditions"], required: ["conditions"])
            for condition in try list(value["formationRule"]["conditions"], "formationRule.conditions") {
                try object(condition, allowed: ["kind", "statement"], required: ["kind", "statement"])
                guard condition["kind"] == "interpreted" else {
                    throw CreationValues.fail("STUDIO_CONDITION_UNSUPPORTED", "Only explicit authored interpreted conditions are accepted.")
                }
                _ = try CreationValues.text(condition["statement"], "condition.statement")
            }
        }
        let sources = value.has("publicSources") ? try list(value["publicSources"], "publicSources") : []
        try unique(sources, field: "localKey", code: "STUDIO_SOURCE_KEY_DUPLICATE")
        let components = value["method"]["components"].list
        for source in sources {
            try object(source, allowed: ["localKey", "identity", "version", "digest", "uses"], required: ["localKey", "identity", "uses"])
            _ = try CreationValues.text(source["identity"], "source.identity")
            if source.has("version") { _ = try CreationValues.text(source["version"], "source.version") }
            if source.has("digest") {
                let bytes = Array(source["digest"].text.utf8)
                guard bytes.count == 71, source["digest"].text.hasPrefix("sha256:"), bytes.dropFirst(7).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    throw CreationValues.fail("COMPONENT_SOURCE_DIGEST_INVALID", "Public source digest must be a complete SHA-256 coordinate.")
                }
            }
            let uses = try list(source["uses"], "source.uses")
            try unique(uses, field: "localKey", code: "STUDIO_SOURCE_USE_KEY_DUPLICATE")
            for use in uses {
                try object(use, allowed: ["localKey", "role", "componentLocalKey"], required: ["localKey", "role"])
                _ = try CreationValues.text(use["role"], "source-use.role")
                if use.has("componentLocalKey") {
                    let local = try key(use["componentLocalKey"])
                    guard components.contains(where: { $0["localKey"] == .string(local) }) else {
                        throw CreationValues.fail("STUDIO_SOURCE_USE_REFERENCE_INVALID", "Source-use must target its owner or one of that owner's explicit components.")
                    }
                }
            }
        }
        let notices = value.has("publicNotices") ? try list(value["publicNotices"], "publicNotices") : []
        try unique(notices, field: "localKey", code: "STUDIO_NOTICE_KEY_DUPLICATE")
        for notice in notices {
            try object(notice, allowed: ["localKey", "statement", "sourceLocalKeys"], required: ["localKey", "statement", "sourceLocalKeys"])
            _ = try CreationValues.text(notice["statement"], "notice.statement")
            let names = try list(notice["sourceLocalKeys"], "notice.sourceLocalKeys")
            guard Set(names.map { KDNAKey($0.text) }).count == names.count else {
                throw CreationValues.fail("STUDIO_NOTICE_REFERENCE_INVALID", "Notice source references must be distinct.")
            }
            for name in names {
                let local = try key(name)
                guard sources.contains(where: { $0["localKey"] == .string(local) }) else {
                    throw CreationValues.fail("STUDIO_NOTICE_REFERENCE_INVALID", "Notice source reference is not authored in this owner.")
                }
            }
        }
        return value
    }

    static func alternatives(_ value: KDNAValue, materialIDs: Set<KDNAKey>) throws -> [KDNAValue] {
        let items = try list(value, "alternatives")
        guard items.count >= 2 else {
            throw CreationValues.fail("STUDIO_ALTERNATIVES_REQUIRED", "A judgment group requires at least two alternatives.")
        }
        try unique(items, field: "localKey", code: "STUDIO_ALTERNATIVE_KEY_DUPLICATE")
        var meanings = Set<KDNAKey>()
        for item in items {
            _ = try alternative(item, materialIDs: materialIDs)
            var semantic = item
            for field in ["localKey", "title", "rationale", "materialRefs"] { semantic.remove(field) }
            guard meanings.insert(KDNAKey(try CreationValues.digest(semantic))).inserted else {
                throw CreationValues.fail("STUDIO_ALTERNATIVES_NOT_DISTINCT", "Renaming the same authored alternative does not supply another choice.")
            }
        }
        return items
    }
}
