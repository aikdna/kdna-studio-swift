//  KDNaStudioCore — Compiler: locked cards → .kdna asset entries

import Foundation
import CryptoKit

public class KDNStudioCompiler {

    /// Compile locked judgment cards into the internal entries of a .kdna asset.
    public static func compile(_ project: KDNStudioProject) throws -> KDNCompileResult {
        let domainName = project.name
        let lockedCards = KDNStudioCards.getLockedCards(project)
        let excludedCards = project.cards.count - lockedCards.count

        guard !lockedCards.isEmpty else {
            throw KDNStudioError.compileError("No locked cards to compile. Lock at least one axiom or pattern card.")
        }

        // Build KDNA_Core.json
        var axioms: [[String: Any]] = []
        var ontology: [[String: Any]] = []
        var frameworks: [[String: Any]] = []
        var stances: [String] = []

        // Build KDNA_Patterns.json
        var misunderstandings: [[String: Any]] = []
        var selfChecks: [String] = []
        var bannedTerms: [[String: Any]] = []
        var terminology: [[String: Any]] = []

        for card in lockedCards {
            switch card.type {
            case .axiom:
                axioms.append(buildAxiom(card))
            case .ontology:
                ontology.append(buildOntology(card))
            case .misunderstanding:
                misunderstandings.append(buildMisunderstanding(card))
            case .self_check:
                if let q = KDNStudioCards.field(card, "question") { selfChecks.append(q) }
            case .boundary, .risk, .aesthetic:
                // These compile to stances or specialized sections
                if let st = KDNStudioCards.field(card, "out_of_scope") ?? KDNStudioCards.field(card, "failure_risk") {
                    stances.append(st)
                }
            default:
                break
            }
        }

        // Build meta
        let meta: [String: String] = [
            "version": project.release?.version ?? "0.1.0",
            "domain": domainName,
            "created": project.created,
            "purpose": "Domain judgment compiled by KDNA Studio Core",
            "load_condition": "always"
        ]

        var coreData: [String: Any] = ["meta": meta]
        if !axioms.isEmpty { coreData["axioms"] = axioms }
        if !ontology.isEmpty { coreData["ontology"] = ontology }
        if !frameworks.isEmpty { coreData["frameworks"] = frameworks }
        if !stances.isEmpty { coreData["stances"] = stances }

        var patternData: [String: Any] = ["meta": meta]
        if !misunderstandings.isEmpty { patternData["misunderstandings"] = misunderstandings }
        if !selfChecks.isEmpty { patternData["self_check"] = selfChecks }
        if !bannedTerms.isEmpty { patternData["terminology"] = ["banned_terms": bannedTerms] }
        if !terminology.isEmpty { patternData["terminology"] = (patternData["terminology"] as? [String: Any] ?? [:]).merging(["standard_terms": terminology]) { $1 } }

        // Serialize
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let coreJSON = try JSONSerialization.data(withJSONObject: coreData, options: [.prettyPrinted, .sortedKeys])
        let patJSON = try JSONSerialization.data(withJSONObject: patternData, options: [.prettyPrinted, .sortedKeys])

        let files: [String: String] = [
            "KDNA_Core.json": String(data: coreJSON, encoding: .utf8) ?? "{}",
            "KDNA_Patterns.json": String(data: patJSON, encoding: .utf8) ?? "{}",
        ]

        return KDNCompileResult(
            success: true,
            domain: domainName,
            files: files,
            stats: KDNCompileStats(lockedCards: lockedCards.count, excludedCards: excludedCards, kdnaFiles: files.count)
        )
    }

    // MARK: - Card → JSON builders

    private static func buildAxiom(_ card: KDNJudgmentCard) -> [String: Any] {
        var obj: [String: Any] = [
            "id": card.id,
            "one_sentence": KDNStudioCards.field(card, "one_sentence") ?? "",
            "full_statement": KDNStudioCards.field(card, "full_statement") ?? "",
            "why": KDNStudioCards.field(card, "why") ?? "",
        ]
        let aw = KDNStudioCards.fieldArray(card, "applies_when")
        if !aw.isEmpty { obj["applies_when"] = aw }
        let dn = KDNStudioCards.fieldArray(card, "does_not_apply_when")
        if !dn.isEmpty { obj["does_not_apply_when"] = dn }
        if let fr = KDNStudioCards.field(card, "failure_risk") { obj["failure_risk"] = fr }
        return obj
    }

    private static func buildOntology(_ card: KDNJudgmentCard) -> [String: Any] {
        return [
            "id": card.id,
            "one_sentence": KDNStudioCards.field(card, "one_sentence") ?? KDNStudioCards.field(card, "essence") ?? "",
            "essence": KDNStudioCards.field(card, "essence") ?? "",
            "boundary": KDNStudioCards.field(card, "boundary") ?? "",
            "trigger_signal": KDNStudioCards.field(card, "trigger_signal") ?? "",
        ]
    }

    private static func buildMisunderstanding(_ card: KDNJudgmentCard) -> [String: Any] {
        return [
            "id": card.id,
            "wrong": KDNStudioCards.field(card, "wrong") ?? "",
            "correct": KDNStudioCards.field(card, "correct") ?? "",
            "key_distinction": KDNStudioCards.field(card, "key_distinction") ?? "",
            "why": KDNStudioCards.field(card, "why") ?? "",
        ]
    }
}

// MARK: - Asset export

extension KDNStudioCompiler {
    /// Export the compiled result as a canonical `.kdna` asset.
    ///
    /// If `url` ends with `.kdna`, the asset is written to that exact file. Otherwise
    /// the method writes `<domain>.kdna` inside the target directory. The generated
    /// asset is a ZIP container with stored entries and no persistent extraction.
    @discardableResult
    public static func exportAsset(_ compileResult: KDNCompileResult, to url: URL) throws -> URL {
        let assetURL: URL
        if url.pathExtension == "kdna" {
            assetURL = url
            let parent = assetURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            assetURL = url.appendingPathComponent("\(compileResult.domain).kdna")
        }

        var entries = compileResult.files
        if entries["kdna.json"] == nil {
            entries["kdna.json"] = try buildAssetManifest(compileResult)
        }

        let archive = try buildStoredZip(entries: entries)
        try archive.write(to: assetURL, options: [.atomic])
        return assetURL
    }

    /// Developer-only source export. Canonical user-facing output is `.kdna`.
    public static func exportDevSourceDirectory(_ compileResult: KDNCompileResult, at path: URL) throws {
        let domainDir = path.appendingPathComponent(compileResult.domain)
        try FileManager.default.createDirectory(at: domainDir, withIntermediateDirectories: true)

        for (filename, content) in compileResult.files {
            let fileURL = domainDir.appendingPathComponent(filename)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    private static func buildAssetManifest(_ compileResult: KDNCompileResult) throws -> String {
        let version = extractVersion(from: compileResult.files["KDNA_Core.json"]) ?? "0.1.0"
        let projectDigest = sha256(compileResult.files.keys.sorted().joined(separator: "\n"))
        let manifest: [String: Any] = [
            "format": "kdna",
            "format_version": "1.0",
            "spec_version": "1.0-rc",
            "name": compileResult.domain,
            "version": version,
            "judgment_version": version,
            "description": "KDNA asset exported by KDNaStudioCore.",
            "author": [
                "name": "KDNA Studio",
                "id": "kdna-studio"
            ],
            "license": [
                "type": "UNSPECIFIED"
            ],
            "status": "draft",
            "quality_badge": "untested",
            "access": "open",
            "languages": ["en"],
            "default_language": "en",
            "file_count": compileResult.files.count,
            "authoring": [
                "created_by": "kdna-studio-sdk",
                "authoring_tool": "KDNA Studio Swift",
                "authoring_tool_version": "0.1.0",
                "compiler": "kdna-studio-swift",
                "compiler_version": "0.1.0",
                "studio_project_digest": "sha256:\(projectDigest)",
                "human_lock_required": true,
                "human_lock_count": compileResult.stats.lockedCards,
                "ai_assisted": true,
                "human_confirmed": compileResult.stats.lockedCards > 0,
                "compiled_at": ISO8601DateFormatter().string(from: Date())
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func extractVersion(from json: String?) -> String? {
        guard
            let json,
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let meta = object["meta"] as? [String: Any],
            let version = meta["version"] as? String
        else {
            return nil
        }
        return version
    }

    private static func sha256(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func buildStoredZip(entries: [String: String]) throws -> Data {
        var archive = Data()
        var centralEntries: [ZipCentralEntry] = []

        for name in entries.keys.sorted() {
            let payload = Data((entries[name] ?? "").utf8)
            let nameData = Data(name.utf8)
            let offset = UInt32(archive.count)
            let crc = crc32(payload)

            appendUInt32(0x04034b50, to: &archive)
            appendUInt16(20, to: &archive) // version needed
            appendUInt16(0x0800, to: &archive) // UTF-8 filenames
            appendUInt16(0, to: &archive) // no compression
            appendUInt16(0, to: &archive) // mod time
            appendUInt16(0, to: &archive) // mod date
            appendUInt32(crc, to: &archive)
            appendUInt32(UInt32(payload.count), to: &archive)
            appendUInt32(UInt32(payload.count), to: &archive)
            appendUInt16(UInt16(nameData.count), to: &archive)
            appendUInt16(0, to: &archive) // extra length
            archive.append(nameData)
            archive.append(payload)

            centralEntries.append(ZipCentralEntry(
                nameData: nameData,
                crc32: crc,
                size: UInt32(payload.count),
                localHeaderOffset: offset
            ))
        }

        let centralStart = UInt32(archive.count)
        for entry in centralEntries {
            appendUInt32(0x02014b50, to: &archive)
            appendUInt16(20, to: &archive) // version made by
            appendUInt16(20, to: &archive) // version needed
            appendUInt16(0x0800, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt32(entry.crc32, to: &archive)
            appendUInt32(entry.size, to: &archive)
            appendUInt32(entry.size, to: &archive)
            appendUInt16(UInt16(entry.nameData.count), to: &archive)
            appendUInt16(0, to: &archive) // extra length
            appendUInt16(0, to: &archive) // comment length
            appendUInt16(0, to: &archive) // disk number
            appendUInt16(0, to: &archive) // internal attrs
            appendUInt32(0, to: &archive) // external attrs
            appendUInt32(entry.localHeaderOffset, to: &archive)
            archive.append(entry.nameData)
        }

        let centralSize = UInt32(archive.count) - centralStart
        appendUInt32(0x06054b50, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(UInt16(centralEntries.count), to: &archive)
        appendUInt16(UInt16(centralEntries.count), to: &archive)
        appendUInt32(centralSize, to: &archive)
        appendUInt32(centralStart, to: &archive)
        appendUInt16(0, to: &archive)

        return archive
    }

    private struct ZipCentralEntry {
        let nameData: Data
        let crc32: UInt32
        let size: UInt32
        let localHeaderOffset: UInt32
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            var current = (crc ^ UInt32(byte)) & 0xff
            for _ in 0..<8 {
                if current & 1 == 1 {
                    current = (current >> 1) ^ 0xedb88320
                } else {
                    current >>= 1
                }
            }
            crc = (crc >> 8) ^ current
        }
        return crc ^ 0xffffffff
    }
}
