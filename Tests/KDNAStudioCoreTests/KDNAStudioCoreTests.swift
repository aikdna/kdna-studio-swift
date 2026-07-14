import XCTest
import Foundation
import KDNACore
@testable import KDNAStudioCore

final class KDNAStudioCoreTests: XCTestCase {
    private func makeProject(name: String = "@test/open_authoring") -> KDNStudioProject {
        KDNStudioProjectManager().createProject(
            name: name,
            author: KDNStudioAuthor(name: "Test Author", id: "author_001")
        )
    }

    private func makeRevisedAxiom() throws -> KDNJudgmentCard {
        var card = KDNStudioCards.createCard(
            type: .axiom,
            fields: [
                "one_sentence": .string("Prefer reversible changes while evidence is incomplete."),
                "full_statement": .string("Choose a reversible step before expanding an uncertain change."),
                "why": .string("A reversible step preserves recovery while evidence is gathered."),
                "applies_when": .array(["Evidence is incomplete"]),
                "does_not_apply_when": .array(["The change is already proven safe"]),
                "failure_risk": .string("A broad change may become difficult to recover.")
            ],
            id: "ax_reversible"
        )
        card = try KDNStudioCards.transitionCard(card, to: .revised, by: "author_001")
        return card
    }

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

        let payload = try KDNACBOR.decodeObject(reader.readEntry(asset: asset, name: "payload.kdnab"))
        XCTAssertEqual(payload["profile"] as? String, "judgment-profile-v1")
        XCTAssertNil(payload["source_cards"])

        let capsule = try KDNARuntime.load(assetURL: assetURL)
        XCTAssertEqual(capsule.type, "kdna.context.capsule")
        XCTAssertEqual(capsule.context["axioms"]?.arrayValue?.count, 1)
    }

    func testRuntimeAssetFilesUseCanonicalShape() throws {
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
        let payload = try KDNACBOR.decodeObject(try XCTUnwrap(files["payload.kdnab"]))
        XCTAssertNil(payload["source_cards"])
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(files["kdna.json"])) as? [String: Any]
        )
        XCTAssertEqual((manifest["payload"] as? [String: Any])?["encoding"] as? String, "cbor")
    }

    func testPasswordProtectedExportLoadsOnlyThroughAuthorizedCapsule() throws {
        let manager = KDNStudioProjectManager()
        var project = manager.createProject(
            name: "@test/protected_judgment",
            author: KDNStudioAuthor(name: "Test Author", id: "author_001")
        )
        var card = KDNStudioCards.createCard(
            type: .axiom,
            fields: [
                "one_sentence": .string("Protected judgment stays inside the authorized runtime."),
                "full_statement": .string("Never expose decrypted judgment as a source file."),
                "why": .string("Authorization is part of the asset contract."),
            ]
        )
        card = try KDNStudioCards.transitionCard(card, to: .revised, by: "author_001")
        card = try KDNStudioCards.lockCard(
            card,
            by: "author_001",
            statement: "Confirmed.",
            appliesWhen: true,
            doesNotApplyWhen: true,
            failureRisk: true
        )
        project.cards.append(card)

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("kdna-studio-swift-protected-\(UUID().uuidString).kdna")
        defer { try? FileManager.default.removeItem(at: output) }
        let compiled = try KDNStudioCompiler.compile(project)
        let assetURL = try KDNStudioCompiler.exportAsset(
            compiled,
            to: output,
            project: project,
            password: "correct-horse-battery-staple"
        )

        let plan = KDNARuntime.planLoad(assetURL: assetURL)
        XCTAssertEqual(plan.state, "needs_password")
        XCTAssertFalse(plan.can_load_now)
        XCTAssertThrowsError(try KDNARuntime.load(assetURL: assetURL))
        XCTAssertThrowsError(try KDNARuntime.load(
            assetURL: assetURL,
            credential: KDNACredential(password: "wrong-password")
        ))

        let capsule = try KDNARuntime.load(
            assetURL: assetURL,
            credential: KDNACredential(password: "correct-horse-battery-staple")
        )
        XCTAssertEqual(capsule.type, "kdna.context.capsule")
        XCTAssertEqual(capsule.access, "licensed")
        XCTAssertEqual(capsule.context["axioms"]?.arrayValue?.count, 1)
    }

    func testOrdinaryCompileAndRuntimeExportWithoutHumanLock() throws {
        var project = makeProject()
        project.cards = [try makeRevisedAxiom()]

        let compiled = try KDNStudioCompiler.compile(project)
        XCTAssertEqual(compiled.stats.lockedCards, 0)
        XCTAssertEqual(compiled.stats.excludedCards, 0)

        let coreData = try XCTUnwrap(compiled.files["KDNA_Core.json"]?.data(using: .utf8))
        let core = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: coreData) as? [String: Any]
        )
        XCTAssertEqual((core["axioms"] as? [[String: Any]])?.count, 1)

        let lockReportData = try XCTUnwrap(
            compiled.files["reports/human-lock-report.json"]?.data(using: .utf8)
        )
        let lockReport = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: lockReportData) as? [String: Any]
        )
        XCTAssertEqual(lockReport["human_lock_required"] as? Bool, false)
        XCTAssertEqual(lockReport["human_lock_count"] as? Int, 0)

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("kdna-studio-swift-open-\(UUID().uuidString).kdna")
        defer { try? FileManager.default.removeItem(at: output) }
        let assetURL = try KDNStudioCompiler.exportAsset(compiled, to: output, project: project)
        let capsule = try KDNARuntime.load(assetURL: assetURL)
        XCTAssertEqual(capsule.context["axioms"]?.arrayValue?.count, 1)
    }

    func testReviewedOnlyModeRequiresLockAndLegacyCallsRemainCompatible() throws {
        let manager = KDNStudioProjectManager()
        var project = makeProject()
        project.cards = [try makeRevisedAxiom()]

        XCTAssertThrowsError(try KDNStudioCompiler.compile(project, requireHumanLock: true)) {
            guard case KDNStudioError.humanLockRequired = $0 else {
                return XCTFail("expected Human Lock policy failure, got \($0)")
            }
        }

        project.cards[0] = try KDNStudioCards.lockCard(
            project.cards[0],
            by: "author_001",
            statement: "This represents my reviewed judgment.",
            appliesWhen: true,
            doesNotApplyWhen: true,
            failureRisk: true
        )

        XCTAssertFalse(KDNStudioHumanLockGate.check(project).blocked)
        XCTAssertEqual(try KDNStudioCompiler.compile(project).stats.lockedCards, 1)
        XCTAssertEqual(
            try KDNStudioCompiler.compile(project, requireHumanLock: true).stats.lockedCards,
            1
        )
        XCTAssertNoThrow(try manager.exportProject(project))
        XCTAssertNoThrow(try manager.exportProject(project, requireHumanLock: true))
    }

    func testOrdinaryProjectExportDoesNotClaimHumanReview() throws {
        let manager = KDNStudioProjectManager()
        var project = makeProject()
        project.cards = [try makeRevisedAxiom()]

        let exported = try manager.exportProject(project)
        let decoded = try manager.loadProject(json: exported)
        XCTAssertEqual(decoded.release?.lockedJudgmentCards, 0)
        XCTAssertEqual(decoded.release?.humanLockGatePassed, false)

        XCTAssertThrowsError(try manager.exportProject(project, requireHumanLock: true))
        XCTAssertNoThrow(
            try manager.exportProject(project, force: true, forceReason: "legacy call compatibility")
        )
        let overridden = try manager.exportProject(
            project,
            requireHumanLock: true,
            force: true,
            forceReason: "explicit reviewed-only override"
        )
        let decodedOverride = try manager.loadProject(json: overridden)
        XCTAssertEqual(decodedOverride.release?.humanLockGatePassed, false)
    }

    func testInvalidRecordedHumanLockFailsClosed() throws {
        let manager = KDNStudioProjectManager()
        var missingRecordProject = makeProject()
        var missingRecord = try makeRevisedAxiom()
        missingRecord.status = .locked
        missingRecord.locked = true
        missingRecordProject.cards = [missingRecord]

        XCTAssertThrowsError(try KDNStudioCompiler.compile(missingRecordProject))
        XCTAssertThrowsError(try manager.exportProject(missingRecordProject))

        var tamperedProject = makeProject()
        var tampered = try KDNStudioCards.lockCard(
            makeRevisedAxiom(),
            by: "author_001",
            statement: "This represents my reviewed judgment.",
            appliesWhen: true,
            doesNotApplyWhen: true,
            failureRisk: true
        )
        tampered.fields["failure_risk"] = .string("Changed after review.")
        tamperedProject.cards = [tampered]

        XCTAssertTrue(KDNStudioHumanLockGate.validateRecordedLocks(tamperedProject).blocked)
        XCTAssertThrowsError(try KDNStudioCompiler.compile(tamperedProject))
        XCTAssertThrowsError(
            try manager.exportProject(
                tamperedProject,
                requireHumanLock: true,
                force: true,
                forceReason: "must not bypass a stale recorded lock"
            )
        )
    }
}
