//  KDNAStudioCore — Compiler: locked cards → .kdna asset entries

import Foundation
import CryptoKit
import KDNACore

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
        var stances: [String] = []
        var scenariosList: [[String: Any]] = []
        var caseList: [[String: Any]] = []

        // Build KDNA_Patterns.json
        var misunderstandings: [[String: Any]] = []
        var selfChecks: [String] = []

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
            case .scenario:
                scenariosList.append(buildGenericCard(card))
            case .case:
                caseList.append(buildGenericCard(card))
            case .boundary, .risk, .aesthetic:
                if let st = KDNStudioCards.field(card, "out_of_scope") ?? KDNStudioCards.field(card, "failure_risk") {
                    stances.append(st)
                }
            }
        }

        // Build meta
        let meta: [String: String] = [
            "version": project.release?.version ?? "0.1.0",
            "domain": domainName,
            "created": project.created,
            "purpose": "Domain judgment compiled by KDNA Studio",
            "load_condition": "always"
        ]

        var coreData: [String: Any] = ["meta": meta]
        if !axioms.isEmpty { coreData["axioms"] = axioms }
        if !ontology.isEmpty { coreData["ontology"] = ontology }
        if !stances.isEmpty { coreData["stances"] = stances }

        var patternData: [String: Any] = ["meta": meta]
        if !misunderstandings.isEmpty { patternData["misunderstandings"] = misunderstandings }
        if !selfChecks.isEmpty { patternData["self_check"] = selfChecks }

        var files: [String: String] = [:]
        files["KDNA_Core.json"] = try jsonString(coreData)
        files["KDNA_Patterns.json"] = try jsonString(patternData)

        // Optional files
        if !scenariosList.isEmpty {
            files["KDNA_Scenarios.json"] = try jsonString(["meta": meta, "scenes": scenariosList])
        }
        if !caseList.isEmpty {
            files["KDNA_Cases.json"] = try jsonString(["meta": meta, "cases": caseList])
        }

        // Reasoning from axioms
        if !axioms.isEmpty {
            let chains = axioms.map { ax in
                ["id": "chain_\(ax["id"] ?? "")",
                 "one_sentence": ax["one_sentence"] ?? "",
                 "logic": [ax["full_statement"] ?? ""],
                 "so_what": ax["why"] ?? "Agent judgment changes when this axiom is loaded."] as [String: Any]
            }
            files["KDNA_Reasoning.json"] = try jsonString(["meta": meta, "reasoning_chains": chains])
        }

        // Evolution from audit logs
        let stages = lockedCards.compactMap { card -> [String: Any]? in
            guard let log = card.auditLog.last(where: { $0.event == "locked" }) else { return nil }
            return ["id": "stage_\(card.id)", "name": KDNStudioCards.field(card, "one_sentence") ?? card.id,
                    "description": "Card \(card.id) locked by \(log.by) at \(log.at)."]
        }
        if !stages.isEmpty {
            files["KDNA_Evolution.json"] = try jsonString([
                "meta": meta, "stages": stages,
                "evolution_layers": [["id": "layer_1", "name": "Foundation", "capability": "Core axioms established",
                                       "from_stage": stages.first?["id"] ?? "", "to_stage": stages.last?["id"] ?? ""]],
                "measurement": [["id": "meas_axioms", "what": "locked_axioms", "how": "Count of locked axiom cards",
                                  "threshold": "\(lockedCards.filter { $0.type == .axiom }.count)"]]
            ])
        }

        // ── Reports ──────────────────────────────────────────
        let buildId = "build_\(UUID().uuidString.lowercased())"
        let assetUID = UUID().uuidString.lowercased()
        let projectUID = project.projectId
        let domainId = domainName.components(separatedBy: "/").last ?? domainName
        let compiledAt = ISO8601DateFormatter().string(from: Date())
        let ratedTests = project.tests.filter { $0.result != nil }

        // Provenance
        let provenance = KDNStudioProvenance.build(
            project: project,
            identity: (buildId, projectUID, assetUID, domainId, compiledAt)
        )
        files["reports/provenance-report.json"] = try jsonString(provenance)

        // KDNA_CARD
        let kdnaCard = KDNStudioGovernance.generateCard(project: project, provenance: provenance)
        files["KDNA_CARD.json"] = try jsonString(kdnaCard)

        // Build report
        files["reports/build-report.json"] = try jsonString([
            "schema_version": "studio-build-report-v1",
            "build_id": buildId, "asset_uid": assetUID, "project_uid": projectUID, "domain_id": domainId,
            "compiler": "kdna-studio-swift", "compiler_version": "0.2.0", "compiled_at": compiledAt,
            "stats": ["total_cards": project.cards.count, "locked_cards": lockedCards.count,
                       "excluded_cards": excludedCards, "kdna_files": files.filter { $0.key.hasPrefix("KDNA_") }.count]
        ])

        // Human Lock report
        let lockedList = lockedCards.map { c -> [String: Any] in
            ["id": c.id, "type": c.type.rawValue, "locked": true,
             "locked_by": c.humanLock?.by ?? "", "locked_at": c.humanLock?.at ?? ""]
        }
        files["reports/human-lock-report.json"] = try jsonString([
            "schema_version": "human-lock-report-v1", "build_id": buildId,
            "human_lock_required": true, "human_lock_count": lockedCards.count,
            "judgment_card_count": project.cards.filter { KDNStudioCards.judgmentCardTypes.contains($0.type) }.count,
            "cards": lockedList
        ])

        // Quality gate report
        let readiness = KDNStudioQuality.computeReadiness(project)
        files["reports/quality-gate-report.json"] = try jsonString([
            "schema_version": "quality-gate-report-v1", "build_id": buildId,
            "quality_badge": readiness.grade == "publishable_grade" ? "tested" : "untested",
            "eval_count": project.tests.count, "rated_eval_count": ratedTests.count,
            "gates": ["untested": ["passed": true], "tested": ["passed": ratedTests.count >= 10],
                       "validated": ["passed": false, "required": "automated scoring + registry validation"]]
        ])

        // Eval report
        files["reports/eval-report.json"] = try jsonString([
            "schema_version": "eval-report-v1", "build_id": buildId,
            "total": project.tests.count, "rated": ratedTests.count,
            "cases": project.tests.map { t in
                ["id": t.id, "title": t.notes, "result": t.result ?? "", "linked_cards": t.linkedCards] as [String: Any]
            }
        ])

        // Build receipt
        files["build-receipt.json"] = try jsonString([
            "schema_version": "studio-build-receipt-v1",
            "asset_uid": assetUID, "project_uid": projectUID, "build_id": buildId, "domain_id": domainId,
            "version": project.release?.version ?? "0.1.0",
            "compiler": "kdna-studio-swift", "compiler_version": "0.2.0",
            "signature_status": "pending_export_sign",
            "built_at": compiledAt
        ])

        let kdnaCount = files.keys.filter { $0.hasPrefix("KDNA_") }.count

        return KDNCompileResult(
            success: true,
            domain: domainName,
            files: files,
            stats: KDNCompileStats(lockedCards: lockedCards.count, excludedCards: excludedCards, kdnaFiles: kdnaCount)
        )
    }

    // MARK: - Helpers

    private static func jsonString(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func buildGenericCard(_ card: KDNJudgmentCard) -> [String: Any] {
        var obj: [String: Any] = ["id": card.id, "type": card.type.rawValue]
        for (key, val) in card.fields {
            switch val {
            case .string(let s): obj[key] = s
            case .array(let a): obj[key] = a
            case .null: break
            }
        }
        return obj
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
    public static func exportAsset(_ compileResult: KDNCompileResult, to url: URL, project: KDNStudioProject? = nil) throws -> URL {
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
            entries["kdna.json"] = try buildAssetManifest(compileResult, project: project)
        }

        let archive = try buildStoredZip(entries: entries)
        try archive.write(to: assetURL, options: [.atomic])

        // P0-4: Verify exported asset digest consistency using KDNACore
        let reader = KDNAAssetReader()
        let asset = try reader.open(url: assetURL)
        let runtimeDigest = KDNAContentDigest.compute(asset: asset, reader: reader)
        guard let manifestData = try? reader.readEntry(asset: asset, name: "kdna.json"),
              let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let manifestDigest = manifest["content_digest"] as? String
        else { return assetURL }
        guard runtimeDigest == manifestDigest else {
            throw KDNStudioError.compileError(
                "Export verification failed: manifest.content_digest (\(manifestDigest.prefix(20))…) != runtime content_digest (\(runtimeDigest.prefix(20))…)"
            )
        }

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

    private static func buildAssetManifest(_ compileResult: KDNCompileResult, project: KDNStudioProject? = nil) throws -> String {
        let version = extractVersion(from: compileResult.files["KDNA_Core.json"]) ?? "0.1.0"
        let projectDigest = sha256(compileResult.files.keys.sorted().joined(separator: "\n"))
        let assetUID = UUID().uuidString.lowercased()
        let projectUID = UUID().uuidString.lowercased()
        let buildID = "build_\(UUID().uuidString.lowercased())"
        let domainID = normalizedDomainID(compileResult.domain)
        let registryName = compileResult.domain.hasPrefix("@") ? compileResult.domain : nil
        let compiledAt = ISO8601DateFormatter().string(from: Date())
        let sourceMode = project?.sourceMode ?? .blank

        // Build complete manifest without content_digest first,
        // then compute digest on the full file set including the manifest.
        var manifest: [String: Any] = [
            "format": "kdna",
            "format_version": "1.0",
            "spec_version": "1.0-rc",
            "name": compileResult.domain,
            "domain_id": domainID,
            "asset_uid": assetUID,
            "project_uid": projectUID,
            "build_id": buildID,
            "version": version,
            "judgment_version": version,
            "description": "KDNA asset exported by KDNAStudioCore.",
            "author": ["name": "KDNA Studio", "id": "kdna-studio"],
            "license": ["type": "UNSPECIFIED"],
            "status": "draft",
            "quality_badge": "untested",
            "access": "open",
            "languages": ["en"],
            "default_language": "en",
            "file_count": compileResult.files.count,
            "lineage": lineageFor(project),
            "authoring": [
                "created_by": "kdna-studio-sdk",
                "authoring_tool": "KDNA Studio Swift",
                "authoring_tool_version": "0.1.0",
                "compiler": "kdna-studio-swift",
                "compiler_version": "0.1.0",
                "source_mode": sourceMode.rawValue,
                "asset_uid": assetUID,
                "project_uid": projectUID,
                "build_id": buildID,
                "domain_id": domainID,
                "studio_project_digest": "sha256:\(projectDigest)",
                "human_lock_required": true,
                "human_lock_count": compileResult.stats.lockedCards,
                "ai_assisted": true,
                "human_confirmed": compileResult.stats.lockedCards > 0,
                "compiled_at": compiledAt,
            ],
        ]
        // Creator
        if let ci = project?.creatorIdentity {
            manifest["creator"] = [
                "creator_id": ci.creatorId, "display_name": ci.displayName,
                "public_key": ci.publicKey, "verified": ci.verified,
            ]
        }
        if let registryName { manifest["registry_name"] = registryName }

        // Build manifest JSON, add to files, compute digest on full set
        let manifestJSON = String(data: try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8) ?? "{}"
        var allFiles = compileResult.files
        allFiles["kdna.json"] = manifestJSON

        let contentDigest = KDNAContentDigest.compute(files: allFiles)

        // Set digest and finalize
        manifest["content_digest"] = contentDigest
        if var auth = manifest["authoring"] as? [String: Any] {
            auth["content_digest"] = contentDigest
            manifest["authoring"] = auth
        }

        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func lineageFor(_ project: KDNStudioProject?) -> [String: Any] {
        if let lin = project?.lineage {
            var d: [String: Any] = ["type": lin.type]
            if let pn = lin.parentName { d["parent_name"] = pn }
            if let pu = lin.parentAssetUID { d["parent_asset_uid"] = pu }
            if let pv = lin.parentVersion { d["parent_version"] = pv }
            if let pd = lin.parentAssetDigest { d["parent_asset_digest"] = pd }
            return d
        }
        return ["type": "original"]
    }

    /// Canonical content digest — delegates to KDNACore for single source of truth.
    private static func computeContentDigest(files: [String: String]) -> String {
        KDNAContentDigest.compute(files: files)
    }

    /// Canonicalize JSON — delegates to KDNACore.
    private static func canonicalizeJSON(name: String, content: String) -> String {
        KDNAContentDigest.canonicalizeJSON(name: name, content: content)
    }

    /// Stable-sort JSON — delegates to KDNACore.
    private static func stableStringify(_ value: Any) -> String {
        KDNAContentDigest.stableStringify(value)
    }

    private static func normalizedDomainID(_ domain: String) -> String {
        let base = domain.split(separator: "/").last.map(String.init) ?? domain
        let lowered = base.lowercased()
        let mapped = lowered.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "_" { return ch }
            return "_"
        }
        let collapsed = String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if let first = collapsed.first, first.isLetter {
            return collapsed
        }
        return "domain_\(collapsed.isEmpty ? "untitled" : collapsed)"
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