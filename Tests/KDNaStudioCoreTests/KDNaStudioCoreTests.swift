import XCTest
import Foundation
@testable import KDNaStudioCore

final class KDNaStudioCoreTests: XCTestCase {
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

        XCTAssertEqual(assetURL.pathExtension, "kdna")
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
    }
}
