import Foundation
import KDNACore

enum CreationCompiler {
    // Called independently before the Compiler entry point receives its value
    // copy. The expectation is held privately, never returned by the Compiler.
    static func encodeExpected(_ plan: KDNAValue) throws -> Data {
        try CreationWriter.storedZIP([
            ("mimetype", Data("application/vnd.kdna.asset".utf8)),
            ("kdna.json", CreationValues.canonicalEvidence(plan["manifest"])),
            ("payload.kdnab", CreationWriter.encodeCBOR(plan["payload"])),
        ])
    }

    static func compile(_ input: KDNAValue) throws -> Data {
        try CreationAuthoring.object(input, allowed: ["manifest", "payload"], required: ["manifest", "payload"])
        return try encodeExpected(input)
    }
}
