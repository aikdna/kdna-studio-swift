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

    /// Compute the readiness stage for a project.
    /// Stages are `draft`, `reviewed`, and `tested`. No fixed card, character,
    /// or eval-count threshold is treated as intrinsic quality: the stage only
    /// reflects structural completeness, review state, and the presence of at
    /// least one rated evaluation result. Publishability is never inferred
    /// from counts; it requires an explicit release decision elsewhere.
    public static func computeReadiness(_ project: KDNStudioProject) -> ReadinessReport {
        let cards = project.cards
        let tests = project.tests
        let locked = cards.filter { $0.locked }
        let lockedAxioms = locked.filter { $0.type == .axiom }
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
            return buildResult(grade: "draft", blocking: blocking, warnings: warnings, project: project)
        }
        if locked.isEmpty {
            blocking.append("No locked cards — nothing to compile")
            return buildResult(grade: "draft", blocking: blocking, warnings: warnings, project: project)
        }

        // ── Axiom checks (structural completeness, not length) ─
        for ax in lockedAxioms {
            let os = KDNStudioCards.field(ax, "one_sentence") ?? ""
            let fs = KDNStudioCards.field(ax, "full_statement") ?? ""
            let why = KDNStudioCards.field(ax, "why") ?? ""
            let aw = KDNStudioCards.fieldArray(ax, "applies_when")
            let dn = KDNStudioCards.fieldArray(ax, "does_not_apply_when")
            let fr = KDNStudioCards.field(ax, "failure_risk") ?? ""

            if os.isEmpty { blocking.append("\(ax.id): missing one_sentence") }
            if fs.isEmpty { blocking.append("\(ax.id): missing full_statement") }
            if why.isEmpty { blocking.append("\(ax.id): missing why") }
            if aw.isEmpty { blocking.append("\(ax.id): missing applies_when") }
            if dn.isEmpty { blocking.append("\(ax.id): missing does_not_apply_when") }
            if fr.isEmpty { blocking.append("\(ax.id): missing failure_risk") }
            if ax.humanLock == nil { blocking.append("\(ax.id): not locked") }
        }

        // ── Determine stage ──────────────────────────────────
        let grade: String
        if !blocking.isEmpty {
            grade = "draft"
        } else if !ratedTests.isEmpty {
            grade = "tested"
        } else {
            grade = "reviewed"
        }

        // source_folder downgrade: imported legacy content can be reviewed but
        // never considered tested until cards are re-locked.
        if sourceMode == .sourceFolder && grade == "tested" {
            warnings.append("source_folder: imported legacy content — tested stage withheld until cards are re-locked")
        }

        return buildResult(grade: grade, blocking: blocking, warnings: warnings, project: project)
    }

    private static func buildResult(grade: String, blocking: [String], warnings: [String], project: KDNStudioProject) -> ReadinessReport {
        let cards = project.cards
        let tests = project.tests
        let locked = cards.filter { $0.locked }
        let ratedTests = tests.filter { $0.result != nil }
        let lockedAxioms = locked.filter { $0.type == .axiom }
        let feynmanRatio = lockedAxioms.isEmpty ? 0.0 :
            Double(lockedAxioms.filter { $0.feynmanRestatement != nil }.count) / Double(lockedAxioms.count)

        let nextStep: String
        switch grade {
        case "draft": nextStep = "Lock judgment cards with complete boundaries and failure risks."
        case "reviewed": nextStep = "Add at least one rated evaluation result to reach the tested stage."
        case "tested": nextStep = "Resolve every remaining blocking issue before considering release."
        default: nextStep = "Ready for Studio compile/export."
        }

        return ReadinessReport(
            grade: grade,
            publishable: false,
            blocking: blocking,
            warnings: warnings,
            score: max(0, 100 - blocking.count * 15 - warnings.count * 3),
            stats: ReadinessReport.Stats(
                totalCards: cards.count,
                lockedCards: locked.count,
                lockedAxioms: lockedAxioms.count,
                lockedSelfChecks: locked.filter { $0.type == .self_check }.count,
                totalTests: tests.count,
                ratedTests: ratedTests.count,
                feynmanRatio: feynmanRatio > 0 ? "\(Int(feynmanRatio * 100))%" : "N/A"
            ),
            nextStep: nextStep
        )
    }
}
