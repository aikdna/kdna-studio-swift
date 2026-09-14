import Foundation
import KDNACore

struct CreationRuntime {
    static let definitionDigest = "sha256:3087cd19542e72322aec19b3015c916d2cfb074fa42e3fd76b3756bb4f097de3"
    static let referenceCoreVersion = "0.24.0-rc.component-semantics.2"
    static let expectedTuple: KDNAValue = [
        "container": "0.2.0", "payload_profile": "kdna.payload.judgment", "payload_version": "0.2.0",
        "core": "kdna.core/0.3.0", "ir": "kdna.canonical-ir/0.2.0", "runtime": "kdna.runtime-capsule/0.2.0",
        "plan": "kdna.consumption-plan/0.2.0", "host": "kdna.agent-host/0.2.0",
        "trace": "kdna.judgment-trace/0.2.0", "read": "kdna.read/0.2.0",
    ]
    static let compiler: KDNAValue = ["name": "KDNAStudioCore", "version": "0.6.0-rc.components.1",
                                             "provider": "swift", "artifact_sha256": "UNKNOWN"]
    let descriptor: KDNAValue
    let tuple: KDNAValue

    init() throws {
        descriptor = try KDNACore.componentSemanticsContract()
        tuple = try KDNACore.versionTuple()
        guard tuple == Self.expectedTuple,
              descriptor["contract_id"] == "kdna.component-semantics/1",
              descriptor["contract_version"] == "1.0.0",
              descriptor["definition_digest"] == .string(Self.definitionDigest) else {
            throw CreationValues.fail("CREATION_COMPONENT_CONTRACT_MISMATCH", "The compiled public Core does not expose the pinned current contract.")
        }
    }

    func admit(_ bytes: Data, code: String) throws -> KDNAValue {
        let admitted = KDNACore.admitBytes(bytes)
        guard let snapshot = admitted.snapshot else {
            throw CreationValues.fail(code, "Public Core rejected the captured bytes: \(admitted.result["reason"].text)")
        }
        return snapshot.inspect()
    }
}
