import CryptoKit
import Foundation
import KDNAAppShared
import KDNACore
import XCTest
@testable import KDNAStudioCore

final class LocalUserExperienceTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDown() {
        for root in temporaryRoots { try? FileManager.default.removeItem(at: root) }
        temporaryRoots.removeAll()
        super.tearDown()
    }

    func testLocalFileInspectionUsesExactBytesWithoutAttaching() throws {
        let assetURL = try makeAsset()
        let bytes = try Data(contentsOf: assetURL)
        let reader = KDNAAssetReader()
        let manifest = try reader.decodeManifest(asset: reader.open(data: bytes))

        let inspection = try KDNStudioLocalAssetInspector.inspect(assetURL)

        XCTAssertEqual(inspection.assetID, manifest.asset_id)
        XCTAssertEqual(inspection.version, manifest.version)
        XCTAssertEqual(inspection.title, manifest.title)
        XCTAssertEqual(inspection.creatorName, "Local Author")
        XCTAssertEqual(
            inspection.digest,
            "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        )
        XCTAssertTrue(inspection.loadPlan.canLoadNow)
        XCTAssertEqual(inspection.loadPlan.state, "ready")
        XCTAssertEqual(inspection.appliesWhen, ["deployment review"])
        XCTAssertEqual(inspection.doesNotApplyWhen, ["poetry"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: assetURL.deletingLastPathComponent()
                .appendingPathComponent(".kdna/attachments.json").path
        ))
    }

    func testLocalFileInspectionRejectsSymlink() throws {
        let assetURL = try makeAsset()
        let link = assetURL.deletingLastPathComponent().appendingPathComponent("linked.kdna")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: assetURL)

        XCTAssertThrowsError(try KDNStudioLocalAssetInspector.inspect(link)) { error in
            XCTAssertEqual(error as? KDNStudioLocalAssetInspectionError, .unsafeFile)
        }
    }

#if os(macOS)
    func testRuntimeCLIStatusAndDirectControlUseOneExactRecord() async throws {
        let fixture = try makeFakeCLI()
        let workspace = try makeWorkspace(withRecord: true, under: fixture.root)
        let client = KDNStudioWorkspaceCLIClient(configuration: .init(
            launcherURL: fixture.executable
        ))

        let before = try await client.status(workspaceURL: workspace)
        let selected = try XCTUnwrap(before?.attachments.first)
        XCTAssertEqual(selected.state, .enabled)

        let after = try await client.perform(
            .disable,
            selected: selected,
            workspaceURL: workspace
        )
        XCTAssertEqual(after?.attachments.first?.state, .disabled)

        let invocations = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertTrue(invocations.contains("--version"))
        XCTAssertTrue(invocations.contains("attachments --cwd"))
        XCTAssertTrue(invocations.contains("disable \(selected.attachmentID) --cwd"))
    }

    func testRuntimeCLIRefusesStaleSelectionAndParentInheritance() async throws {
        let fixture = try makeFakeCLI()
        let workspace = try makeWorkspace(withRecord: true, under: fixture.root)
        let child = workspace.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let client = KDNStudioWorkspaceCLIClient(configuration: .init(
            launcherURL: fixture.executable
        ))
        let current = try await client.status(workspaceURL: workspace)
        let selected = try XCTUnwrap(current?.attachments.first)

        try Data("disabled\n".utf8).write(to: fixture.state)
        do {
            _ = try await client.perform(.disable, selected: selected, workspaceURL: workspace)
            XCTFail("expected stale-state rejection")
        } catch {
            XCTAssertEqual(error as? KDNStudioWorkspaceCLIError, .stateChanged)
        }
        let childStatus = try await client.status(workspaceURL: child)
        XCTAssertNil(childStatus)

        let workspaceLink = fixture.root.appendingPathComponent("workspace-link")
        try FileManager.default.createSymbolicLink(
            at: workspaceLink,
            withDestinationURL: workspace
        )
        do {
            _ = try await client.status(workspaceURL: workspaceLink)
            XCTFail("expected workspace symlink rejection")
        } catch {
            XCTAssertEqual(error as? KDNStudioWorkspaceCLIError, .unsafeWorkspace)
        }
    }

    func testRuntimeCLIRequiresExactCandidateVersion() async throws {
        let fixture = try makeFakeCLI(version: "0.35.0")
        let workspace = try makeWorkspace(withRecord: true, under: fixture.root)
        let client = KDNStudioWorkspaceCLIClient(configuration: .init(
            launcherURL: fixture.executable
        ))

        do {
            _ = try await client.status(workspaceURL: workspace)
            XCTFail("expected exact-version rejection")
        } catch {
            XCTAssertEqual(error as? KDNStudioWorkspaceCLIError, .incompatible)
        }
    }

    func testRuntimeCLITransportIsInjectableWithoutMovingClientPolicy() async throws {
        let fixture = try makeFakeCLI()
        let workspace = try makeWorkspace(withRecord: true, under: fixture.root)
        let transport = RecordingCLITransport()
        let client = KDNStudioWorkspaceCLIClient(
            configuration: .init(launcherURL: fixture.executable),
            transport: transport
        )

        let status = try await client.status(workspaceURL: workspace)

        XCTAssertEqual(status?.attachments.first?.state, .enabled)
        let calls = await transport.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].launcher, fixture.executable.resolvingSymlinksInPath())
        XCTAssertEqual(calls[0].arguments, ["--version"])
        XCTAssertEqual(calls[1].arguments, ["attachments", "--cwd", workspace.path])
        XCTAssertEqual(calls[1].cwd, workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.log.path))
    }

    func testRuntimeCLITransportCannotBypassLauncherExecutableMode() async throws {
        let fixture = try makeFakeCLI()
        let workspace = try makeWorkspace(withRecord: true, under: fixture.root)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.executable.path
        )
        let transport = RecordingCLITransport()
        let client = KDNStudioWorkspaceCLIClient(
            configuration: .init(launcherURL: fixture.executable),
            transport: transport
        )

        do {
            _ = try await client.status(workspaceURL: workspace)
            XCTFail("expected launcher mode rejection")
        } catch {
            XCTAssertEqual(error as? KDNStudioWorkspaceCLIError, .unavailable)
        }
        let calls = await transport.recordedCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testApprovalCommandsKeepExactPreviewInRuntimeCLI() async throws {
        let fixture = try makeFakeCLI()
        let workspace = try makeWorkspace(withRecord: true, under: fixture.root)
        let assetURL = try makeAsset()
        let client = KDNStudioWorkspaceCLIClient(configuration: .init(
            launcherURL: fixture.executable
        ))

        let command = try await client.attachApprovalCommand(
            assetURL: assetURL,
            workspaceURL: workspace,
            role: "deployment-review",
            appliesTo: ["deployment review"],
            doesNotApplyTo: ["poetry"]
        )

        XCTAssertEqual(command.executableURL, fixture.executable.resolvingSymlinksInPath())
        XCTAssertEqual(command.arguments.first, "attach")
        XCTAssertTrue(command.arguments.contains(assetURL.path))
        XCTAssertTrue(command.arguments.contains(workspace.path))
        XCTAssertFalse(command.arguments.contains("--yes"))

        let inspect = try await client.inspectTerminalCommand(assetURL: assetURL)
        XCTAssertEqual(inspect.arguments, ["inspect", assetURL.path, "--json"])
        let useOnce = try await client.useOnceTerminalCommand(assetURL: assetURL)
        XCTAssertEqual(
            useOnce.arguments,
            ["load", assetURL.path, "--profile", "compact", "--as", "json"]
        )
        XCTAssertFalse(useOnce.arguments.contains("--password"))
        XCTAssertFalse(useOnce.arguments.contains("--password-stdin"))
    }
#endif

    private func makeAsset() throws -> URL {
        let root = try temporaryRoot("asset")
        var project = KDNStudioProjectManager().createProject(
            name: "@test/local_asset",
            author: KDNStudioAuthor(name: "Local Author", id: "author_001")
        )
        var card = KDNStudioCards.createCard(
            type: .axiom,
            fields: [
                "one_sentence": .string("Prefer a reversible step."),
                "full_statement": .string("Use a reversible step while evidence is incomplete."),
                "why": .string("Recovery remains possible."),
                "applies_when": .array(["deployment review"]),
                "does_not_apply_when": .array(["poetry"]),
                "failure_risk": .string("A broad change may be hard to recover."),
            ]
        )
        card = try KDNStudioCards.transitionCard(card, to: .revised, by: "author_001")
        project.cards = [card]
        return try KDNStudioCompiler.exportAsset(
            KDNStudioCompiler.compile(project),
            to: root.appendingPathComponent("local-asset.kdna"),
            project: project
        )
    }

    private func makeWorkspace(withRecord: Bool, under root: URL) throws -> URL {
        let workspace = root.appendingPathComponent("workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        if withRecord {
            let kdna = workspace.appendingPathComponent(".kdna", isDirectory: true)
            try FileManager.default.createDirectory(at: kdna, withIntermediateDirectories: false)
            try Data("{}\n".utf8).write(to: kdna.appendingPathComponent("attachments.json"))
        }
        return workspace
    }

#if os(macOS)
    private actor RecordingCLITransport: KDNStudioWorkspaceCLITransport {
        struct Call: Sendable {
            let launcher: URL
            let arguments: [String]
            let cwd: URL
        }

        private var calls: [Call] = []

        func execute(launcher: URL, arguments: [String], cwd: URL) async throws -> Data {
            calls.append(Call(launcher: launcher, arguments: arguments, cwd: cwd))
            if arguments == ["--version"] {
                return Data("0.36.0\n".utf8)
            }
            guard arguments.first == "attachments" else {
                throw KDNStudioWorkspaceCLIError.commandRejected
            }
            let digest = "sha256:" + String(repeating: "a", count: 64)
            return Data("""
            {"document_type":"kdna.workspace-attachments","schema_version":"0.1.0","workspace":{"root_marker":".kdna/attachments.json"},"attachments":[{"attachment_id":"att_0123456789abcdef01234567","asset":{"id":"kdna:example:review","version":"1.0.0","digest":"\(digest)","snapshot":"assets/sha256-\(String(repeating: "a", count: 64)).kdna"},"state":"enabled","role":"deployment-review","scope":{"kind":"workspace","applies_to":["deployment review"],"does_not_apply_to":["poetry"]},"resolution_policy":"load_when_clear_ask_when_ambiguous","approved_at":"2026-07-22T00:00:00.000Z","update_policy":"explicit_switch_only","history":[]}]}
            """.utf8)
        }

        func recordedCalls() -> [Call] { calls }
    }

    private func makeFakeCLI(version: String = "0.36.0") throws -> (
        root: URL,
        executable: URL,
        state: URL,
        log: URL
    ) {
        let root = try temporaryRoot("cli")
        let executable = root.appendingPathComponent("fake-kdna")
        let state = root.appendingPathComponent("state")
        let log = root.appendingPathComponent("args.log")
        try Data("enabled\n".utf8).write(to: state)
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let script = """
        #!/bin/sh
        printf '%s\n' "$*" >> '\(log.path)'
        if [ "$1" = "--version" ]; then
          printf '%s\n' '\(version)'
          exit 0
        fi
        case "$1" in
          attachments)
            STATE=$(cat '\(state.path)')
            printf '%s\n' '{"document_type":"kdna.workspace-attachments","schema_version":"0.1.0","workspace":{"root_marker":".kdna/attachments.json"},"attachments":[{"attachment_id":"att_0123456789abcdef01234567","asset":{"id":"kdna:example:review","version":"1.0.0","digest":"\(digest)","snapshot":"assets/sha256-\(String(repeating: "a", count: 64)).kdna"},"state":"'"$STATE"'","role":"deployment-review","scope":{"kind":"workspace","applies_to":["deployment review"],"does_not_apply_to":["poetry"]},"resolution_policy":"load_when_clear_ask_when_ambiguous","approved_at":"2026-07-22T00:00:00.000Z","update_policy":"explicit_switch_only","history":[]}]}'
            ;;
          disable)
            printf '%s\n' 'disabled' > '\(state.path)'
            printf '%s\n' '{"operation":"disable"}'
            ;;
          enable)
            printf '%s\n' 'enabled' > '\(state.path)'
            printf '%s\n' '{"operation":"enable"}'
            ;;
          *)
            exit 2
            ;;
        esac
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        return (root, executable, state, log)
    }
#endif

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kdna-studio-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        temporaryRoots.append(root)
        return root
    }
}
