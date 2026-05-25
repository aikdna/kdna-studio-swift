//  KDNaStudioCore — Swift native KDNA authoring kernel
//  Ported from @aikdna/kdna-studio-core (JS)

import Foundation

// MARK: - Studio Project

public struct KDNStudioProject: Codable {
    public var studioVersion: String
    public var projectId: String
    public var name: String
    public var type: String          // "domain" | "cluster"
    public var created: String
    public var updated: String
    public var author: KDNStudioAuthor
    public var status: KDNStudioProjectStatus
    public var cards: [KDNJudgmentCard]
    public var evidence: [KDNEvidenceEntry]
    public var tests: [KDNTestCase]
    public var stages: KDNStudioStages
    public var release: KDNStudioRelease?

    enum CodingKeys: String, CodingKey {
        case studioVersion = "studio_version"
        case projectId = "project_id"
        case name, type, created, updated, author, status, cards, evidence, tests, stages, release
    }
}

public struct KDNStudioAuthor: Codable {
    public var name: String
    public var id: String
    public init(name: String = "", id: String = "") { self.name = name; self.id = id }
}

public enum KDNStudioProjectStatus: String, Codable {
    case drafting
    case cardsInProgress = "cards_in_progress"
    case readyForTest = "ready_for_test"
    case readyForRelease = "ready_for_release"
    case released
}

public struct KDNStudioStages: Codable {
    public var evidenceRoom: KDNStageState = .pending(count: 0)
    public var interviewRoom: KDNStageState = .pending(count: 0)
    public var judgmentCards: KDNStageState = .pending(count: 0)
    public var testLab: KDNStageState = .pending(count: 0)
    public var export: KDNStageState = .pending(count: 0)

    enum CodingKeys: String, CodingKey {
        case evidenceRoom = "evidence_room"
        case interviewRoom = "interview_room"
        case judgmentCards = "judgment_cards"
        case testLab = "test_lab"
        case export
    }
}

public enum KDNStageState: Codable {
    case pending(count: Int)
    case inProgress(count: Int)
    case complete(count: Int)

    enum CodingKeys: String, CodingKey { case status, count }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let s = try c.decode(String.self, forKey: .status)
        let n = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        switch s {
        case "in_progress": self = .inProgress(count: n)
        case "complete": self = .complete(count: n)
        default: self = .pending(count: n)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pending(let n): try c.encode("pending", forKey: .status); try c.encode(n, forKey: .count)
        case .inProgress(let n): try c.encode("in_progress", forKey: .status); try c.encode(n, forKey: .count)
        case .complete(let n): try c.encode("complete", forKey: .status); try c.encode(n, forKey: .count)
        }
    }
}

public struct KDNStudioRelease: Codable {
    public var version: String?
    public var publishedAt: String?
    public var exportedAt: String?
    public var lockedJudgmentCards: Int?
    public var humanLockGatePassed: Bool?

    enum CodingKeys: String, CodingKey {
        case version
        case publishedAt = "published_at"
        case exportedAt = "exported_at"
        case lockedJudgmentCards = "locked_judgment_cards"
        case humanLockGatePassed = "human_lock_gate_passed"
    }
}

// MARK: - Card Types

public struct KDNJudgmentCard: Codable {
    public var id: String
    public var type: KDNCardType
    public var status: KDNCardStatus
    public var locked: Bool
    public var fields: [String: KDNCardFieldValue]
    public var evidenceRefs: [String]
    public var testRefs: [String]
    public var humanLock: KDNHumanLockRecord?
    public var feynmanRestatement: KDNFeynmanRestatement?
    public var auditLog: [KDNAuditEntry]

    enum CodingKeys: String, CodingKey {
        case id, type, status, locked, fields
        case evidenceRefs = "evidence_refs"
        case testRefs = "test_refs"
        case humanLock = "human_lock"
        case feynmanRestatement = "feynman_restatement"
        case auditLog = "audit_log"
    }
}

public enum KDNCardType: String, Codable, CaseIterable {
    case axiom, ontology, misunderstanding, boundary
    case self_check, risk, aesthetic, scenario, `case`
}

public enum KDNCardStatus: String, Codable {
    case draft, revised, locked, tested, published, deprecated
}

public enum KDNCardFieldValue: Codable {
    case string(String)
    case array([String])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([String].self) { self = .array(a) }
        else { self = .null }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }
}

public struct KDNHumanLockRecord: Codable {
    public var by: String
    public var at: String
    public var statement: String
    public var checked: KDNLockChecks?
    public var judgmentFingerprint: String?

    enum CodingKeys: String, CodingKey {
        case by, at, statement, checked
        case judgmentFingerprint = "judgment_fingerprint"
    }
}

public struct KDNLockChecks: Codable {
    public var appliesWhen: Bool?
    public var doesNotApplyWhen: Bool?
    public var failureRisk: Bool?

    enum CodingKeys: String, CodingKey {
        case appliesWhen = "applies_when"
        case doesNotApplyWhen = "does_not_apply_when"
        case failureRisk = "failure_risk"
    }
}

public struct KDNFeynmanRestatement: Codable {
    public var text: String
    public var evaluatedAt: String
    public var score: KDNFeynmanScore?

    enum CodingKeys: String, CodingKey {
        case text
        case evaluatedAt = "evaluated_at"
        case score
    }
}

public struct KDNFeynmanScore: Codable {
    public var total: Int
    public var quality: String
    public var notJustRepeat: Bool?
    public var notTooAbstract: Bool?
    public var hasConcreteExample: Bool?
    public var clarifiesBoundary: Bool?
    public var ordinaryPersonUnderstands: Bool?

    enum CodingKeys: String, CodingKey {
        case total, quality
        case notJustRepeat = "not_just_repeat"
        case notTooAbstract = "not_too_abstract"
        case hasConcreteExample = "has_concrete_example"
        case clarifiesBoundary = "clarifies_boundary"
        case ordinaryPersonUnderstands = "ordinary_person_understands"
    }
}

public struct KDNAuditEntry: Codable {
    public var at: String
    public var event: String
    public var by: String
    public var reason: String?
}

// MARK: - Evidence

public struct KDNEvidenceEntry: Codable {
    public var id: String
    public var type: String      // "text" | "file" | "url" | "chat"
    public var title: String
    public var contentHash: String?
    public var source: String?
    public var importedAt: String?
    public var spans: [KDNEvidenceSpan]
    public var content: String?

    enum CodingKeys: String, CodingKey {
        case id, type, title
        case contentHash = "content_hash"
        case source
        case importedAt = "imported_at"
        case spans, content
    }
}

public struct KDNEvidenceSpan: Codable {
    public var id: String
    public var text: String
    public var start: Int
    public var end: Int
    public var candidatePattern: String?
    public var extractedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, text, start, end
        case candidatePattern = "candidate_pattern"
        case extractedAt = "extracted_at"
    }
}

// MARK: - Test Case

public struct KDNTestCase: Codable {
    public var id: String
    public var input: String
    public var expectedWithoutKdna: String?
    public var expectedWithKdna: String?
    public var domain: String?
    public var result: String?
    public var humanRating: String?
    public var ratedBy: String?
    public var ratedAt: String?
    public var notes: String
    public var linkedCards: [String]
    public var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, input
        case expectedWithoutKdna = "expected_without_kdna"
        case expectedWithKdna = "expected_with_kdna"
        case domain, result
        case humanRating = "human_rating"
        case ratedBy = "rated_by"
        case ratedAt = "rated_at"
        case notes
        case linkedCards = "linked_cards"
        case createdAt = "created_at"
    }
}

// MARK: - Human Lock Gate Result

public struct KDNHumanLockGateResult: Codable {
    public let blocked: Bool
    public let issues: [KDNLockIssue]
    public let lockedJudgmentCards: Int
}

public struct KDNLockIssue: Codable {
    public let cardId: String
    public let type: String
    public let reason: String
}

// MARK: - Quality Gate

public struct KDNReadinessReport: Codable {
    public let grade: String
    public let publishable: Bool
    public let score: Int
    public let blocking: [String]
    public let warnings: [String]
    public let stats: KDNReadinessStats?
    public let nextStep: String?
}

public struct KDNReadinessStats: Codable {
    public var lockedAxioms: Int = 0
    public var lockedMisunderstandings: Int = 0
    public var lockedSelfChecks: Int = 0
    public var ratedTests: Int = 0
    public var totalCards: Int = 0
}

// MARK: - Compile

public struct KDNCompileResult: Codable {
    public let success: Bool
    public let domain: String
    public let files: [String: String]  // filename → JSON content
    public let stats: KDNCompileStats
}

public struct KDNCompileStats: Codable {
    public var lockedCards: Int = 0
    public var excludedCards: Int = 0
    public var kdnaFiles: Int = 0
}
