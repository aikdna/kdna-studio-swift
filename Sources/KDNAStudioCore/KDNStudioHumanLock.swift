//  KDNAStudioCore — Human Lock Gate enforcement

import Foundation

public class KDNStudioHumanLockGate {

    /// Check whether all judgment-class cards satisfy Human Lock requirements.
    /// Returns blocked=true if any card fails.
    public static func check(_ project: KDNStudioProject) -> KDNHumanLockGateResult {
        var issues: [KDNLockIssue] = []

        for card in project.cards {
            guard KDNStudioCards.judgmentCardTypes.contains(card.type) else { continue }
            let cardId = card.id

            // Rule 1: Must be locked
            if ![KDNCardStatus.locked, .tested, .published].contains(card.status) {
                issues.append(KDNLockIssue(cardId: cardId, type: card.type.rawValue,
                    reason: "judgment-class card \"\(cardId)\" is not locked. Human Lock required before export."))
                continue
            }

            // Rule 2: Must have valid Human Lock record
            guard let hl = card.humanLock, !hl.by.isEmpty, !hl.statement.isEmpty else {
                issues.append(KDNLockIssue(cardId: cardId, type: card.type.rawValue,
                    reason: "locked card \"\(cardId)\" has no valid Human Lock record."))
                continue
            }

            // Rule 3: Lock must confirm judgment fields were reviewed
            if hl.checked?.appliesWhen != true {
                issues.append(KDNLockIssue(cardId: cardId, type: card.type.rawValue,
                    reason: "card \"\(cardId)\" Human Lock does not confirm applies_when was reviewed."))
            }
            if hl.checked?.doesNotApplyWhen != true {
                issues.append(KDNLockIssue(cardId: cardId, type: card.type.rawValue,
                    reason: "card \"\(cardId)\" Human Lock does not confirm does_not_apply_when was reviewed."))
            }
            if hl.checked?.failureRisk != true {
                issues.append(KDNLockIssue(cardId: cardId, type: card.type.rawValue,
                    reason: "card \"\(cardId)\" Human Lock does not confirm failure_risk was reviewed."))
            }

            // Rule 4: Judgment fields must not have changed since lock
            if let stored = hl.judgmentFingerprint {
                let current = KDNStudioCards.cardJudgmentFingerprint(card)
                if current != stored {
                    issues.append(KDNLockIssue(cardId: cardId, type: card.type.rawValue,
                        reason: "card \"\(cardId)\" judgment fields changed after Human Lock — re-lock required."))
                }
            }
        }

        let lockedCount = project.cards.filter {
            KDNStudioCards.judgmentCardTypes.contains($0.type) &&
            [KDNCardStatus.locked, .tested, .published].contains($0.status)
        }.count

        return KDNHumanLockGateResult(blocked: !issues.isEmpty, issues: issues, lockedJudgmentCards: lockedCount)
    }
}
