import Foundation
import KDNACore

public enum KDNAStudioAdoptionKind: String {
    case humanClaimUnverified = "human_claim_unverified"
    case delegatedAgentEditorial = "delegated_agent_editorial"
}

/// The trusted embedding supplies the callback and channel declaration. This
/// value does not authenticate a person, Agent identity or delegation claim.
public struct KDNAStudioAdoptionInput {
    public let kind: KDNAStudioAdoptionKind
    public let channel: String
    public let authorization: KDNAValue?
    let receive: (KDNAValue) async throws -> KDNAValue

    public init(kind: KDNAStudioAdoptionKind, channel: String, authorization: KDNAValue? = nil,
                receive: @escaping (KDNAValue) async throws -> KDNAValue) {
        self.kind = kind
        self.channel = channel
        self.authorization = authorization
        self.receive = receive
    }
}

public typealias KDNAStudioInterpreter = (String, KDNAValue) async throws -> KDNAValue

public struct KDNAStudioExport {
    public let bytes: Data
    public let evidence: KDNAValue
    public let binding: KDNAValue
    public let verification: KDNAValue
}

public enum KDNAStudio {
    /// Authoring options contain only agent metadata and an optional explicit
    /// fixture flag. Runtime callbacks are captured separately and cannot be
    /// replaced by JSON. No public Compiler callback or asset-ID override exists.
    public static func createSession(options: KDNAValue,
                                     adoptionInput: KDNAStudioAdoptionInput,
                                     interpretReply: @escaping KDNAStudioInterpreter) throws -> KDNAStudioSession {
        try CreationAuthoring.object(options, allowed: ["agent", "syntheticFixture"], required: ["agent"])
        try CreationAuthoring.object(options["agent"], allowed: ["name", "version"], required: ["name", "version"])
        for field in ["name", "version"] { _ = try CreationValues.text(options["agent"][field], "agent." + field) }
        _ = try CreationValues.text(.string(adoptionInput.channel), "adoptionInput.channel")
        if options.has("syntheticFixture"), case .bool = options["syntheticFixture"] {
            // An explicitly authored Boolean is preserved below.
        } else if options.has("syntheticFixture") {
            throw CreationValues.fail("STUDIO_INPUT_INVALID", "syntheticFixture must be a Boolean.")
        }
        if adoptionInput.kind == .delegatedAgentEditorial {
            guard let authorization = adoptionInput.authorization else {
                throw CreationValues.fail("STUDIO_DELEGATION_REQUIRED", "The embedding must record its explicit delegated editorial authority claim.")
            }
            try CreationAuthoring.object(authorization, allowed: ["coordinate", "statement"], required: ["coordinate", "statement"])
            for field in ["coordinate", "statement"] { _ = try CreationValues.text(authorization[field], "authorization." + field) }
        } else if adoptionInput.authorization != nil {
            throw CreationValues.fail("STUDIO_INPUT_INVALID", "A human input channel does not carry an Agent delegation record.")
        }
        _ = try CreationValues.canonicalEvidence(options)
        return try KDNAStudioSession(options: options, adoptionInput: adoptionInput, interpretReply: interpretReply)
    }

    /// Static consistency cannot reconstruct a private live creation/save
    /// capability. External byte/evidence bindings are always required.
    public static func verifyCreationEvidence(bytes: Data, evidence: KDNAValue?, expectedBinding: KDNAValue?) -> KDNAValue {
        CreationEvidence.verify(bytes: bytes, evidence: evidence, expectedBinding: expectedBinding)
    }
}

public struct KDNAStudioAgent {
    let session: KDNAStudioSession
    public func setBrief(_ input: KDNAValue) async throws -> KDNAValue { try await session.setBrief(input) }
    public func recordMaterial(_ input: KDNAValue) async throws -> KDNAValue { try await session.recordMaterial(input) }
    public func propose(_ input: KDNAValue) async throws -> KDNAValue { try await session.propose(input) }
    public func revise(_ localKey: String, _ input: KDNAValue) async throws -> KDNAValue { try await session.revise(localKey, input) }
    public func compilePreview() async throws -> KDNAValue { try await session.compilePreview() }
}
