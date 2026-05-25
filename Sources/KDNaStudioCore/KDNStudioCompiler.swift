//  KDNaStudioCore — Compiler: locked cards → KDNA JSON files

import Foundation

public class KDNStudioCompiler {

    /// Compile locked judgment cards into KDNA_Core.json and KDNA_Patterns.json.
    public static func compile(_ project: KDNStudioProject) throws -> KDNCompileResult {
        let domainName = project.name
        let lockedCards = KDNStudioCards.getLockedCards(project)
        let excludedCards = project.cards.count - lockedCards.count

        guard !lockedCards.isEmpty else {
            throw KDNStudioError.compileError("No locked cards to compile. Lock at least one axiom or pattern card.")
        }

        // Build KDNA_Core.json
        var axioms: [[String: Any]] = []
        var ontology: [[String: Any]] = []
        var frameworks: [[String: Any]] = []
        var stances: [String] = []

        // Build KDNA_Patterns.json
        var misunderstandings: [[String: Any]] = []
        var selfChecks: [String] = []
        var bannedTerms: [[String: Any]] = []
        var terminology: [[String: Any]] = []

        for card in lockedCards {
            switch card.type {
            case .axiom:
                axioms.append(buildAxiom(card))
            case .ontology:
                ontology.append(buildOntology(card))
            case .misunderstanding:
                misunderstandings.append(buildMisunderstanding(card))
            case .self_check:
                if let q = KDNStudioCards.field(card, "question") { selfChecks.append(q) }
            case .boundary, .risk, .aesthetic:
                // These compile to stances or specialized sections
                if let st = KDNStudioCards.field(card, "out_of_scope") ?? KDNStudioCards.field(card, "failure_risk") {
                    stances.append(st)
                }
            default:
                break
            }
        }

        // Build meta
        let meta: [String: String] = [
            "version": project.release?.version ?? "0.1.0",
            "domain": domainName,
            "created": project.created,
            "purpose": "Domain judgment compiled by KDNA Studio Core",
            "load_condition": "always"
        ]

        var coreData: [String: Any] = ["meta": meta]
        if !axioms.isEmpty { coreData["axioms"] = axioms }
        if !ontology.isEmpty { coreData["ontology"] = ontology }
        if !frameworks.isEmpty { coreData["frameworks"] = frameworks }
        if !stances.isEmpty { coreData["stances"] = stances }

        var patternData: [String: Any] = ["meta": meta]
        if !misunderstandings.isEmpty { patternData["misunderstandings"] = misunderstandings }
        if !selfChecks.isEmpty { patternData["self_check"] = selfChecks }
        if !bannedTerms.isEmpty { patternData["terminology"] = ["banned_terms": bannedTerms] }
        if !terminology.isEmpty { patternData["terminology"] = (patternData["terminology"] as? [String: Any] ?? [:]).merging(["standard_terms": terminology]) { $1 } }

        // Serialize
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let coreJSON = try JSONSerialization.data(withJSONObject: coreData, options: [.prettyPrinted, .sortedKeys])
        let patJSON = try JSONSerialization.data(withJSONObject: patternData, options: [.prettyPrinted, .sortedKeys])

        let files: [String: String] = [
            "KDNA_Core.json": String(data: coreJSON, encoding: .utf8) ?? "{}",
            "KDNA_Patterns.json": String(data: patJSON, encoding: .utf8) ?? "{}",
        ]

        return KDNCompileResult(
            success: true,
            domain: domainName,
            files: files,
            stats: KDNCompileStats(lockedCards: lockedCards.count, excludedCards: excludedCards, kdnaFiles: files.count)
        )
    }

    // MARK: - Card → JSON builders

    private static func buildAxiom(_ card: KDNJudgmentCard) -> [String: Any] {
        var obj: [String: Any] = [
            "id": card.id,
            "one_sentence": KDNStudioCards.field(card, "one_sentence") ?? "",
            "full_statement": KDNStudioCards.field(card, "full_statement") ?? "",
            "why": KDNStudioCards.field(card, "why") ?? "",
        ]
        let aw = KDNStudioCards.fieldArray(card, "applies_when")
        if !aw.isEmpty { obj["applies_when"] = aw }
        let dn = KDNStudioCards.fieldArray(card, "does_not_apply_when")
        if !dn.isEmpty { obj["does_not_apply_when"] = dn }
        if let fr = KDNStudioCards.field(card, "failure_risk") { obj["failure_risk"] = fr }
        return obj
    }

    private static func buildOntology(_ card: KDNJudgmentCard) -> [String: Any] {
        return [
            "id": card.id,
            "one_sentence": KDNStudioCards.field(card, "one_sentence") ?? KDNStudioCards.field(card, "essence") ?? "",
            "essence": KDNStudioCards.field(card, "essence") ?? "",
            "boundary": KDNStudioCards.field(card, "boundary") ?? "",
            "trigger_signal": KDNStudioCards.field(card, "trigger_signal") ?? "",
        ]
    }

    private static func buildMisunderstanding(_ card: KDNJudgmentCard) -> [String: Any] {
        return [
            "id": card.id,
            "wrong": KDNStudioCards.field(card, "wrong") ?? "",
            "correct": KDNStudioCards.field(card, "correct") ?? "",
            "key_distinction": KDNStudioCards.field(card, "key_distinction") ?? "",
            "why": KDNStudioCards.field(card, "why") ?? "",
        ]
    }
}

// Extension to help export domain to filesystem
extension KDNStudioCompiler {
    public static func exportToDirectory(_ compileResult: KDNCompileResult, at path: URL) throws {
        let domainDir = path.appendingPathComponent(compileResult.domain)
        try FileManager.default.createDirectory(at: domainDir, withIntermediateDirectories: true)

        for (filename, content) in compileResult.files {
            let fileURL = domainDir.appendingPathComponent(filename)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}
