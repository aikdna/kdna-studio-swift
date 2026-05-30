//  KDNAStudioCore — Governance & KDNA_CARD generation

import Foundation

public class KDNStudioGovernance {

    /// Generate KDNA_CARD.json from project metadata and provenance.
    public static func generateCard(
        project: KDNStudioProject,
        provenance: [String: Any]? = nil
    ) -> [String: Any] {
        let cards = project.cards
        let locked = cards.filter { $0.locked }
        let lockedAxioms = locked.filter { $0.type == .axiom }
        let lockedMisunderstandings = locked.filter { $0.type == .misunderstanding }
        let lockedSelfChecks = locked.filter { $0.type == .self_check }
        let ratedTests = project.tests.filter { $0.result != nil }

        let badge: String
        if ratedTests.count >= 10 { badge = "tested" }
        else if lockedAxioms.count >= 1 { badge = "untested" }
        else { badge = "draft" }

        var card: [String: Any] = [
            "name": project.name,
            "domain_id": project.name.components(separatedBy: "/").last ?? project.name,
            "risk_level": "R2",
            "intended_use": [
                "Domain-specific judgment assistance for AI agents",
                "NOT a replacement for professional human judgment",
                "NOT a safety-critical decision system",
            ],
            "out_of_scope": [
                "Safety-critical decisions without human review",
                "Medical, legal, or financial advice",
                "Decisions with irreversible consequences",
            ],
            "known_limitations": [
                "May not cover edge cases outside the domain's training scope",
                "Judgment quality depends on the completeness of axioms and eval coverage",
                "Agent behavior may vary across different LLM providers",
            ],
            "author_responsibility": "The author of this KDNA domain is responsible for the judgment principles encoded. Human Lock confirms the author has reviewed each card and stands behind the encoded judgment.",
            "human_lock_summary": [
                "locked_cards": locked.count,
                "total_cards": cards.count,
                "axioms": lockedAxioms.count,
                "misunderstandings": lockedMisunderstandings.count,
                "self_checks": lockedSelfChecks.count,
            ],
            "quality_badge": badge,
            "review_status": badge == "tested" ? "community" : "unlisted",
        ]

        if let provenance { card["provenance"] = provenance }
        if project.release != nil { card["license"] = ["type": "CC-BY-4.0"] }

        return card
    }

    /// Validate governance requirements for a project.
    public static func validate(_ project: KDNStudioProject) -> (valid: Bool, issues: [String]) {
        var issues: [String] = []
        let cards = project.cards
        let locked = cards.filter { $0.locked }
        let lockedAxioms = locked.filter { $0.type == .axiom }

        if lockedAxioms.isEmpty {
            issues.append("No locked axioms — domain has no enforceable judgment principles")
        }
        for ax in lockedAxioms {
            if KDNStudioCards.fieldArray(ax, "applies_when").isEmpty {
                issues.append("\(ax.id): missing applies_when (governance required)")
            }
            if KDNStudioCards.fieldArray(ax, "does_not_apply_when").isEmpty {
                issues.append("\(ax.id): missing does_not_apply_when (governance required)")
            }
            if (KDNStudioCards.field(ax, "failure_risk") ?? "").isEmpty {
                issues.append("\(ax.id): missing failure_risk (governance required)")
            }
        }

        return (issues.isEmpty, issues)
    }
}
