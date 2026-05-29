//  KDNAStudioCore — Judgment Cards with state machine and Human Lock

import Foundation
import CryptoKit

public class KDNStudioCards {

    public static let cardTypes: [KDNCardType] = KDNCardType.allCases
    public static let validStates: [KDNCardStatus] = [.draft, .revised, .locked, .tested, .published, .deprecated]

    public static let transitions: [KDNCardStatus: [KDNCardStatus]] = [
        .draft:       [.revised, .deprecated],
        .revised:     [.locked, .draft, .deprecated],
        .locked:      [.tested, .revised, .deprecated],
        .tested:      [.published, .locked, .deprecated],
        .published:   [.deprecated],
        .deprecated:  [],
    ]

    /// Card types that carry judgment-class fields requiring Human Lock per human-lock.md SPEC
    public static let judgmentCardTypes: Set<KDNCardType> = [.axiom, .boundary, .risk, .aesthetic]

    /// Fields that constitute "judgment content" — changes here require Human Lock
    public static let judgmentFields: Set<String> = [
        "one_sentence", "full_statement", "why", "essence", "boundary",
        "wrong", "correct", "key_distinction", "question", "scope",
        "out_of_scope", "applies_when", "does_not_apply_when", "failure_risk",
        "acceptable_exceptions", "trigger_signal", "when_to_use", "steps"
    ]

    // MARK: - Card Lifecycle

    public static func createCard(type: KDNCardType, fields: [String: KDNCardFieldValue], id: String? = nil) -> KDNJudgmentCard {
        return KDNJudgmentCard(
            id: id ?? "\(String(type.rawValue.prefix(2)))_\(UUID().uuidString)",
            type: type,
            status: .draft,
            locked: false,
            fields: fields,
            evidenceRefs: [],
            testRefs: [],
            humanLock: nil,
            feynmanRestatement: nil,
            auditLog: [KDNAuditEntry(at: ISO8601DateFormatter().string(from: Date()), event: "created", by: "ai", reason: nil)]
        )
    }

    @discardableResult
    public static func transitionCard(_ card: KDNJudgmentCard, to: KDNCardStatus, by: String, reason: String? = nil) throws -> KDNJudgmentCard {
        guard let allowed = transitions[card.status], allowed.contains(to) else {
            throw KDNStudioError.cardStateError("Invalid transition: \(card.status.rawValue) → \(to.rawValue)")
        }
        var c = card
        c.status = to
        c.locked = [.locked, .tested, .published].contains(to)
        c.auditLog.append(KDNAuditEntry(at: ISO8601DateFormatter().string(from: Date()), event: to.rawValue, by: by, reason: reason))
        return c
    }

    @discardableResult
    public static func lockCard(_ card: KDNJudgmentCard, by: String, statement: String,
                                 appliesWhen: Bool, doesNotApplyWhen: Bool, failureRisk: Bool,
                                 creatorID: String? = nil, signature: String? = nil) throws -> KDNJudgmentCard {
        guard appliesWhen else { throw KDNStudioError.cardStateError("Must confirm applies_when reviewed") }
        guard doesNotApplyWhen else { throw KDNStudioError.cardStateError("Must confirm does_not_apply_when reviewed") }
        guard failureRisk else { throw KDNStudioError.cardStateError("Must confirm failure_risk reviewed") }

        var c = card
        c.humanLock = KDNHumanLockRecord(
            by: by,
            at: ISO8601DateFormatter().string(from: Date()),
            statement: statement,
            checked: KDNLockChecks(appliesWhen: true, doesNotApplyWhen: true, failureRisk: true),
            creatorId: creatorID,
            signature: signature,
            judgmentFingerprint: cardJudgmentFingerprint(c)
        )
        return try transitionCard(c, to: .locked, by: by)
    }

    @discardableResult
    public static func unlockCard(_ card: KDNJudgmentCard, reason: String, by: String) throws -> KDNJudgmentCard {
        guard !reason.isEmpty else { throw KDNStudioError.cardStateError("Unlock requires a reason") }
        var c = card
        c.humanLock = nil
        return try transitionCard(c, to: .revised, by: by, reason: "unlocked: \(reason)")
    }

    // MARK: - Fingerprint

    public static func cardJudgmentFingerprint(_ card: KDNJudgmentCard) -> String {
        var relevant: [String: String] = [:]
        for key in judgmentFields {
            if let val = card.fields[key] {
                switch val {
                case .string(let s): relevant[key] = s
                case .array(let a): relevant[key] = a.joined(separator: "|")
                case .null: break
                }
            }
        }
        let sorted = relevant.sorted(by: { $0.key < $1.key }).map { "\($0.key):\($0.value)" }.joined(separator: "\n")
        let hash = SHA256.hash(data: Data("\(card.type.rawValue):\(sorted)".utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Queries

    public static func getLockedCards(_ project: KDNStudioProject) -> [KDNJudgmentCard] {
        project.cards.filter { [.locked, .tested, .published].contains($0.status) }
    }

    public static func getPublishableCards(_ project: KDNStudioProject) -> [KDNJudgmentCard] {
        project.cards.filter { $0.status == .tested || $0.status == .locked }
    }

    // MARK: - Field Helpers

    public static func field(_ card: KDNJudgmentCard, _ key: String) -> String? {
        guard let val = card.fields[key], case .string(let s) = val else { return nil }
        return s
    }

    public static func fieldArray(_ card: KDNJudgmentCard, _ key: String) -> [String] {
        guard let val = card.fields[key], case .array(let a) = val else { return [] }
        return a
    }
}
