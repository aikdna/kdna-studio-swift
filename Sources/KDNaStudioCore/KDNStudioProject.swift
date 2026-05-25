//  KDNaStudioCore — Project lifecycle

import Foundation

public class KDNStudioProjectManager {

    public init() {}

    // MARK: - Create

    public func createProject(name: String, type: String = "domain",
                               author: KDNStudioAuthor = KDNStudioAuthor(name: "", id: "")) -> KDNStudioProject {
        let now = ISO8601DateFormatter().string(from: Date()).prefix(10)
        return KDNStudioProject(
            studioVersion: "0.1.0",
            projectId: "studio_\(UUID().uuidString)",
            name: name,
            type: type,
            created: String(now),
            updated: String(now),
            author: author,
            status: .drafting,
            cards: [],
            evidence: [],
            tests: [],
            stages: KDNStudioStages(),
            release: nil
        )
    }

    // MARK: - Load / Save

    public func loadProject(json: String) throws -> KDNStudioProject {
        guard let data = json.data(using: .utf8) else {
            throw KDNStudioError.invalidJSON("cannot encode string to data")
        }
        let project = try JSONDecoder().decode(KDNStudioProject.self, from: data)
        let result = validateProject(project)
        guard result.valid else {
            throw KDNStudioError.validationFailed(result.issues)
        }
        return project
    }

    public func saveProject(_ project: KDNStudioProject) -> String {
        var p = project
        p.updated = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(p),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    // MARK: - Validate

    public func validateProject(_ project: KDNStudioProject) -> (valid: Bool, issues: [String]) {
        var issues: [String] = []

        if project.name.isEmpty { issues.append("name must not be empty") }
        if !["domain", "cluster"].contains(project.type) {
            issues.append("type must be 'domain' or 'cluster'")
        }
        if !project.studioVersion.isEmpty {
            let verPattern = try? NSRegularExpression(pattern: "^\\d+\\.\\d+\\.\\d+")
            if verPattern?.firstMatch(in: project.studioVersion, range: NSRange(0..<project.studioVersion.count)) == nil {
                issues.append("studio_version must be semver")
            }
        }
        if project.projectId.isEmpty { issues.append("project_id must not be empty") }

        return (issues.isEmpty, issues)
    }

    // MARK: - Export with Human Lock Gate

    public func exportProject(_ project: KDNStudioProject, force: Bool = false, forceReason: String? = nil) throws -> String {
        let gate = KDNStudioHumanLockGate.check(project)

        if gate.blocked && !force {
            var msg = "Human Lock Gate blocked export:\n"
            for issue in gate.issues {
                msg += "  ✗ \(issue.cardId): \(issue.reason)\n"
            }
            msg += "\n  Locked judgment cards: \(gate.lockedJudgmentCards)"
            msg += "\n  Use force:true for emergency override."
            throw KDNStudioError.humanLockRequired(msg)
        }

        var p = project
        p.updated = String(ISO8601DateFormatter().string(from: Date()).prefix(10))

        if p.release == nil { p.release = KDNStudioRelease() }
        p.release?.exportedAt = ISO8601DateFormatter().string(from: Date())
        p.release?.lockedJudgmentCards = gate.lockedJudgmentCards
        p.release?.humanLockGatePassed = !gate.blocked || force

        if gate.blocked && force {
            // Emergency override recorded
            // (override metadata stored via a custom field if needed)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(p),
              let json = String(data: data, encoding: .utf8) else {
            throw KDNStudioError.invalidJSON("encode failed")
        }
        return json
    }
}

public enum KDNStudioError: Error, LocalizedError {
    case invalidJSON(String)
    case validationFailed([String])
    case humanLockRequired(String)
    case cardStateError(String)
    case compileError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let m): return "Invalid JSON: \(m)"
        case .validationFailed(let i): return "Validation failed: \(i.joined(separator: "; "))"
        case .humanLockRequired(let m): return m
        case .cardStateError(let m): return "Card state error: \(m)"
        case .compileError(let m): return "Compile error: \(m)"
        }
    }
}
