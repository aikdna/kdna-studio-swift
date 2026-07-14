//  KDNAStudioCore — Human Lock Gate enforcement

import Foundation

public class KDNStudioHumanLockGate {

    /// Check whether all judgment-class cards satisfy Human Lock requirements.
    /// Returns blocked=true if any card fails.
    public static func check(_ project: KDNStudioProject) -> KDNHumanLockGateResult {
        validate(project, requireAllJudgmentCards: true)
    }

    /// Validate only cards that claim Human Lock provenance.
    ///
    /// Ordinary authoring does not require Human Lock. Once a card claims to be
    /// locked, however, the state, record, review confirmations, and optional
    /// fingerprint must remain internally consistent.
    public static func validateRecordedLocks(_ project: KDNStudioProject) -> KDNHumanLockGateResult {
        validate(project, requireAllJudgmentCards: false)
    }

    private static func validate(
        _ project: KDNStudioProject,
        requireAllJudgmentCards: Bool
    ) -> KDNHumanLockGateResult {
        var issues: [KDNLockIssue] = []

        for card in project.cards {
            guard KDNStudioCards.judgmentCardTypes.contains(card.type) else { continue }
            let cardId = card.id
            let hasLockedStatus = [KDNCardStatus.locked, .tested, .published].contains(card.status)
            let claimsHumanLock = hasLockedStatus || card.locked || card.humanLock != nil

            if !requireAllJudgmentCards && !claimsHumanLock {
                continue
            }

            // Rule 1: Required or claimed Human Lock must use a consistent state.
            if !hasLockedStatus || !card.locked {
                issues.append(KDNLockIssue(cardId: cardId, type: card.type.rawValue,
                    reason: "judgment-class card \"\(cardId)\" does not have a consistent locked state."))
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
            [KDNCardStatus.locked, .tested, .published].contains($0.status) &&
            $0.locked
        }.count

        return KDNHumanLockGateResult(blocked: !issues.isEmpty, issues: issues, lockedJudgmentCards: lockedCount)
    }
}
