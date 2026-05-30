//  KDNAStudioCore — Quality gates and readiness scoring
//
//  Aligned with @aikdna/kdna-studio-core/src/quality/index.js
//  Includes source_mode trust differentiation.

import Foundation

public class KDNStudioQuality {

    public struct ReadinessReport {
        public let grade: String
        public let publishable: Bool
        public let blocking: [String]
        public let warnings: [String]
        public let score: Int
        public let stats: Stats
        public let nextStep: String

        public struct Stats {
            public let totalCards: Int
            public let lockedCards: Int
            public let lockedAxioms: Int
            public let lockedSelfChecks: Int
            public let totalTests: Int
            public let ratedTests: Int
            public let feynmanRatio: String
        }
    }

    /// Compute the readiness grade for a project.
    /// Returns 4-grade score: draft_grade, human_controlled, tested_grade, publishable_grade.
    public static func computeReadiness(_ project: KDNStudioProject) -> ReadinessReport {
        let cards = project.cards
        let tests = project.tests
        let locked = cards.filter { $0.locked }
        let lockedAxioms = locked.filter { $0.type == .axiom }
        let lockedSelfChecks = locked.filter { $0.type == .self_check }
        let ratedTests = tests.filter { $0.result != nil }

        var blocking: [String] = []
        var warnings: [String] = []

        // ── Source mode trust checks ──────────────────────────
        let sourceMode = project.sourceMode
        if sourceMode == .sourceFolder {
            blocking.append("source_folder: all imported cards must be re-locked — legacy trust is not inherited")
            blocking.append("source_folder: schema audit required; verify all required fields before Human Lock")
        }
        if sourceMode == .kdnaAsset {
            let hasLineage = project.lineage?.parentName != nil || project.lineage?.parentAssetUID != nil
            if !hasLineage {
                blocking.append("kdna_asset: lineage missing — must record parent KDNA identity")
            }
            warnings.append("kdna_asset: cards imported from existing KDNA must be re-locked; parent trust is not inherited")
        }

        // ── Minimum structure ────────────────────────────────
        if cards.isEmpty {
            blocking.append("Project has no cards")
            return buildResult(grade: "draft_grade", blocking: blocking, warnings: warnings, project: project)
        }
        if locked.isEmpty {
            blocking.append("No locked cards — nothing to compile")
            return buildResult(grade: "draft_grade", blocking: blocking, warnings: warnings, project: project)
        }

        // ── Axiom checks ─────────────────────────────────────
        for ax in lockedAxioms {
            let os = KDNStudioCards.field(ax, "one_sentence") ?? ""
            let fs = KDNStudioCards.field(ax, "full_statement") ?? ""
            let why = KDNStudioCards.field(ax, "why") ?? ""
            let aw = KDNStudioCards.fieldArray(ax, "applies_when")
            let dn = KDNStudioCards.fieldArray(ax, "does_not_apply_when")
            let fr = KDNStudioCards.field(ax, "failure_risk") ?? ""

            if os.count < 10 { blocking.append("\(ax.id): one_sentence too short") }
            if aw.isEmpty { blocking.append("\(ax.id): missing applies_when") }
            if dn.isEmpty { blocking.append("\(ax.id): missing does_not_apply_when") }
            if fr.isEmpty { blocking.append("\(ax.id): missing failure_risk") }
            if fs.count < 20 { blocking.append("\(ax.id): full_statement too short (<20 chars, SPEC required)") }
            if why.count < 20 { blocking.append("\(ax.id): why too short (<20 chars, SPEC required)") }
            if ax.humanLock == nil { blocking.append("\(ax.id): not locked") }
        }

        // ── Determine grade ──────────────────────────────────
        let axiomsComplete = lockedAxioms.count >= 1 &&
            lockedAxioms.allSatisfy { ax in
                let aw = KDNStudioCards.fieldArray(ax, "applies_when")
                let dn = KDNStudioCards.fieldArray(ax, "does_not_apply_when")
                let fr = KDNStudioCards.field(ax, "failure_risk") ?? ""
                return !aw.isEmpty && !dn.isEmpty && !fr.isEmpty && ax.humanLock != nil
            }

        let feynmanRatio = lockedAxioms.isEmpty ? 0.0 :
            Double(lockedAxioms.filter { $0.feynmanRestatement != nil }.count) / Double(lockedAxioms.count)

        var grade = "draft_grade"
        if locked.count >= 3 && axiomsComplete && feynmanRatio >= 0.5 { grade = "human_controlled" }
        if grade == "human_controlled" && ratedTests.count >= 5 && lockedSelfChecks.count >= 3 { grade = "tested_grade" }
        if grade == "tested_grade" && ratedTests.count >= 10 && lockedAxioms.count >= 3 && lockedSelfChecks.count >= 5 && blocking.isEmpty {
            grade = "publishable_grade"
        }

        // source_folder downgrade
        if sourceMode == .sourceFolder && grade == "publishable_grade" {
            grade = "tested_grade"
            warnings.append("source_folder: imported legacy content — publishable downgraded to tested until cards are re-locked")
        }

        return buildResult(grade: grade, blocking: blocking, warnings: warnings, project: project, feynmanRatio: feynmanRatio)
    }

    private static func buildResult(grade: String, blocking: [String], warnings: [String], project: KDNStudioProject, feynmanRatio: Double = 0) -> ReadinessReport {
        let cards = project.cards
        let tests = project.tests
        let locked = cards.filter { $0.locked }
        let ratedTests = tests.filter { $0.result != nil }

        let nextStep: String
        switch grade {
        case "draft_grade": nextStep = "Lock at least 3 axioms with boundaries and 50% Feynman."
        case "human_controlled": nextStep = "Add 5+ rated evals and 3+ self-checks."
        case "tested_grade": nextStep = "Add 10+ evals, complete Feynman on all axioms, resolve all blocking issues."
        default: nextStep = "Ready for Studio compile/export."
        }

        return ReadinessReport(
            grade: grade,
            publishable: grade == "publishable_grade" && blocking.isEmpty,
            blocking: blocking,
            warnings: warnings,
            score: max(0, 100 - blocking.count * 15 - warnings.count * 3),
            stats: ReadinessReport.Stats(
                totalCards: cards.count,
                lockedCards: locked.count,
                lockedAxioms: locked.filter { $0.type == .axiom }.count,
                lockedSelfChecks: locked.filter { $0.type == .self_check }.count,
                totalTests: tests.count,
                ratedTests: ratedTests.count,
                feynmanRatio: feynmanRatio > 0 ? "\(Int(feynmanRatio * 100))%" : "N/A"
            ),
            nextStep: nextStep
        )
    }
}
