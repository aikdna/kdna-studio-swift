import XCTest
import Foundation
import KDNACore
@testable import KDNAStudioCore

final class KDNAStudioCoreTests: XCTestCase {
    func testPackageVersion() {
        XCTAssertTrue(true)
    }

    func testExportAssetWritesKdnaZip() throws {
        let manager = KDNStudioProjectManager()
        var project = manager.createProject(
            name: "writing_judgment",
            author: KDNStudioAuthor(name: "Writing Expert", id: "writer_001")
        )

        var card = KDNStudioCards.createCard(
            type: .axiom,
            fields: [
                "one_sentence": .string("Most writing problems are structural."),
                "full_statement": .string("Diagnose structure before language."),
                "why": .string("Surface polishing on weak structure wastes effort."),
                "applies_when": .array(["User asks to review content"]),
                "does_not_apply_when": .array(["User asks for grammar only"]),
                "failure_risk": .string("May over-diagnose structure.")
            ]
        )
        card = try KDNStudioCards.transitionCard(card, to: .revised, by: "writer_001")
        card = try KDNStudioCards.lockCard(
            card,
            by: "writer_001",
            statement: "This represents my professional judgment.",
            appliesWhen: true,
            doesNotApplyWhen: true,
            failureRisk: true
        )
        project.cards.append(card)

        let result = try KDNStudioCompiler.compile(project)
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kdna-studio-swift-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let assetURL = try KDNStudioCompiler.exportAsset(result, to: outputDir)
        let data = try Data(contentsOf: assetURL)
        let reader = KDNAAssetReader()
        let asset = try reader.open(url: assetURL)
        let entries = Set(reader.listEntries(asset: asset))

        XCTAssertEqual(assetURL.pathExtension, "kdna")
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        XCTAssertEqual(entries, ["mimetype", "kdna.json", "payload.kdnab", "checksums.json"])
        XCTAssertEqual(try reader.readString(asset: asset, name: "mimetype"), "application/vnd.kdna.asset")
        XCTAssertFalse(entries.contains("KDNA_Core.json"))
        XCTAssertFalse(entries.contains("KDNA_Patterns.json"))

        let payload = try XCTUnwrap(try reader.readJSON(asset: asset, name: "payload.kdnab"))
        XCTAssertEqual(payload["profile"] as? String, "judgment-profile-v1")
        XCTAssertNil(payload["source_cards"])
    }

    func testRuntimeAssetFilesUseCanonicalCoreV1Shape() throws {
        let manager = KDNStudioProjectManager()
        var project = manager.createProject(
            name: "@test/writing_judgment",
            author: KDNStudioAuthor(name: "Writing Expert", id: "writer_001")
        )

        var card = KDNStudioCards.createCard(
            type: .axiom,
            fields: [
                "one_sentence": .string("Most writing problems are structural."),
                "full_statement": .string("Diagnose structure before language."),
                "why": .string("Surface polishing on weak structure wastes effort."),
                "applies_when": .array(["User asks to review content"]),
                "does_not_apply_when": .array(["User asks for grammar only"]),
                "failure_risk": .string("May over-diagnose structure.")
            ]
        )
        card = try KDNStudioCards.transitionCard(card, to: .revised, by: "writer_001")
        card = try KDNStudioCards.lockCard(
            card,
            by: "writer_001",
            statement: "This represents my professional judgment.",
            appliesWhen: true,
            doesNotApplyWhen: true,
            failureRisk: true
        )
        project.cards.append(card)

        let result = try KDNStudioCompiler.compile(project)
        let files = try KDNStudioCompiler.buildRuntimeAssetFiles(result, project: project)
        XCTAssertEqual(Set(files.keys), ["mimetype", "kdna.json", "payload.kdnab", "checksums.json"])
        XCTAssertFalse(files.keys.contains("KDNA_Core.json"))
        XCTAssertFalse(files["payload.kdnab"]?.contains("source_cards") ?? true)
    }
}
