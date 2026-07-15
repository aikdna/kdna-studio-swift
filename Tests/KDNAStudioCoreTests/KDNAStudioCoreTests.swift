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
        XCTAssertEqual(payload["profile"] as? String, "kdna.payload.judgment")
        XCTAssertEqual(payload["profile_version"] as? String, "0.1.0")
        XCTAssertNil(payload["source_cards"])

        let manifestData = try reader.readEntry(asset: asset, name: "kdna.json")
        let manifest = try JSONDecoder().decode(KDNAManifest.self, from: manifestData)
        XCTAssertEqual(manifest.format_version, "0.1.0")
        XCTAssertEqual(manifest.compatibility.profile, "kdna.payload.judgment")
        XCTAssertEqual(manifest.compatibility.profile_version, "0.1.0")
        XCTAssertNil(manifest.creator, "export without project context must not invent creator identity")

        let capsule = try KDNARuntime.load(assetURL: assetURL)
        XCTAssertEqual(capsule.type, "kdna.runtime-capsule")
        XCTAssertEqual(capsule.contract_version, "0.1.0")
        XCTAssertEqual(capsule.digests.profile, "kdna.digest-evidence")
        XCTAssertEqual(capsule.digests.profile_version, "0.1.0")
        XCTAssertEqual(capsule.digests.runtime_entry_set.basis, "kdna.digest-basis.runtime-entry-set")
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
        XCTAssertEqual(payload["profile"] as? String, "kdna.payload.judgment")
        XCTAssertEqual(payload["profile_version"] as? String, "0.1.0")
        XCTAssertNil(payload["source_cards"])
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(files["kdna.json"])) as? [String: Any]
        )
        XCTAssertEqual(manifest["format_version"] as? String, "0.1.0")
        XCTAssertEqual((manifest["payload"] as? [String: Any])?["encoding"] as? String, "cbor")
        let compatibility = try XCTUnwrap(manifest["compatibility"] as? [String: Any])
        XCTAssertEqual(compatibility["profile"] as? String, "kdna.payload.judgment")
        XCTAssertEqual(compatibility["profile_version"] as? String, "0.1.0")
        let checksums = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(files["checksums.json"])) as? [String: Any]
        )
        let entrySetDigest = try XCTUnwrap(checksums["entry_set_digest"] as? String)
        XCTAssertEqual(checksums["digest_profile"] as? String, KDNAChecksumDigests.runtimeEntrySetProfile)
        XCTAssertEqual(checksums["digest_profile_version"] as? String, KDNAChecksumDigests.runtimeEntrySetProfileVersion)
        XCTAssertEqual(checksums["covered_entries"] as? [String], KDNAChecksumDigests.runtimeCoveredEntries)
        XCTAssertTrue(entrySetDigest.hasPrefix("sha256:"))
        XCTAssertEqual(
            entrySetDigest,
            KDNAChecksumDigests.computeRuntimeEntrySetDigest(
                manifest: try XCTUnwrap(files["kdna.json"]),
                payload: try XCTUnwrap(files["payload.kdnab"])
            )
        )
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

        let reader = KDNAAssetReader()
        let asset = try reader.open(url: assetURL)
        let manifest = try reader.decodeManifest(asset: asset)
        XCTAssertEqual(manifest.encryption?.profile, "kdna.encryption.password")
        XCTAssertEqual(manifest.encryption?.profile_version, "0.1.0")
        let envelope = try KDNACBOR.decode(
            KDNAProtectedEnvelope.self,
            from: reader.readEntry(asset: asset, name: "payload.kdnab")
        )
        XCTAssertEqual(envelope.profile, "kdna.encryption.password")
        XCTAssertEqual(envelope.profile_version, "0.1.0")
        XCTAssertThrowsError(try KDNARuntime.load(assetURL: assetURL))
        XCTAssertThrowsError(try KDNARuntime.load(
            assetURL: assetURL,
            credential: KDNACredential(password: "wrong-password")
        ))

        let capsule = try KDNARuntime.load(
            assetURL: assetURL,
            credential: KDNACredential(password: "correct-horse-battery-staple")
        )
        XCTAssertEqual(capsule.type, "kdna.runtime-capsule")
        XCTAssertEqual(capsule.contract_version, "0.1.0")
        XCTAssertEqual(capsule.access, "licensed")
        XCTAssertEqual(capsule.context["axioms"]?.arrayValue?.count, 1)
    }

    func testCompileReportsUseResponsibilityIdentityAndIndependentCoordinate() throws {
        var project = makeProject()
        project.cards = [try makeRevisedAxiom()]
        let compiled = try KDNStudioCompiler.compile(project)
        let expectedReports = [
            ("reports/build-report.json", "kdna.studio.build-report"),
            ("reports/human-lock-report.json", "kdna.studio.human-lock-report"),
            ("reports/quality-gate-report.json", "kdna.studio.quality-gate-report"),
            ("reports/eval-report.json", "kdna.studio.evaluation-report"),
            ("build-receipt.json", "kdna.studio.build-receipt"),
        ]

        for (path, type) in expectedReports {
            let data = try XCTUnwrap(compiled.files[path]?.data(using: .utf8))
            let report = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertEqual(report["type"] as? String, type, path)
            XCTAssertEqual(report["schema_version"] as? String, "0.1.0", path)
        }
    }

    func testMisunderstandingMapsToFailureModeWithoutCorruptingReasoningChain() throws {
        var project = makeProject()
        var misunderstanding = KDNStudioCards.createCard(
            type: .misunderstanding,
            fields: [
                "wrong": .string("Irreversible change is always faster."),
                "correct": .string("Recovery cost is part of delivery time."),
                "key_distinction": .string("Immediate speed differs from total recovery cost."),
                "why": .string("Rollback preserves evidence and service continuity."),
                "failure_risk": .string("A failed irreversible change can stop delivery."),
                "applies_when": .array(["Evidence is incomplete"]),
                "does_not_apply_when": .array(["The change is proven and reversible"]),
            ],
            id: "mis_recovery"
        )
        misunderstanding = try KDNStudioCards.transitionCard(
            misunderstanding,
            to: .revised,
            by: "author_001"
        )
        project.cards = [try makeRevisedAxiom(), misunderstanding]

        let files = try KDNStudioCompiler.buildRuntimeAssetFiles(
            KDNStudioCompiler.compile(project),
            project: project
        )
        let payload = try KDNACBOR.decodeObject(try XCTUnwrap(files["payload.kdnab"]))
        let reasoning = try XCTUnwrap(payload["reasoning"] as? [String: Any])
        let failureModes = try XCTUnwrap(reasoning["failure_modes"] as? [[String: Any]])
        let chains = try XCTUnwrap(reasoning["reasoning_chains"] as? [[String: Any]])

        XCTAssertEqual(failureModes.count, 1)
        XCTAssertEqual(failureModes[0]["id"] as? String, "mis_recovery")
        XCTAssertEqual(failureModes[0]["mode"] as? String, "Irreversible change is always faster.")
        XCTAssertEqual(failureModes[0]["failure_risk"] as? String, "A failed irreversible change can stop delivery.")
        XCTAssertEqual(failureModes[0]["applies_when"] as? [String], ["Evidence is incomplete"])
        XCTAssertEqual(chains.count, 1)
        XCTAssertEqual(chains[0]["id"] as? String, "chain_ax_reversible")
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

    func testExternalCoreFixtureExportHook() throws {
        let requestedDirectory = ProcessInfo.processInfo.environment["KDNA_STUDIO_FIXTURE_OUTPUT"]
            .map(URL.init(fileURLWithPath:))
        let outputDirectory = requestedDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("kdna-studio-external-fixture-\(UUID().uuidString)")
        let shouldCleanup = requestedDirectory == nil
        defer {
            if shouldCleanup { try? FileManager.default.removeItem(at: outputDirectory) }
        }
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        var project = makeProject(name: "@test/external_core_fixture")
        project.cards = [try makeRevisedAxiom()]
        let compiled = try KDNStudioCompiler.compile(project)
        let publicAsset = try KDNStudioCompiler.exportAsset(
            compiled,
            to: outputDirectory.appendingPathComponent("public.kdna"),
            project: project
        )
        let protectedAsset = try KDNStudioCompiler.exportAsset(
            compiled,
            to: outputDirectory.appendingPathComponent("protected.kdna"),
            project: project,
            password: "cross-language-password"
        )

        XCTAssertEqual(try KDNARuntime.load(assetURL: publicAsset).type, "kdna.runtime-capsule")
        XCTAssertEqual(
            try KDNARuntime.load(
                assetURL: protectedAsset,
                credential: KDNACredential(password: "cross-language-password")
            ).type,
            "kdna.runtime-capsule"
        )
    }
}
