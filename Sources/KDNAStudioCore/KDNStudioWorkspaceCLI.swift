import Darwin
import Foundation
import KDNAAppShared

public struct KDNStudioRuntimeCLIConfiguration: Equatable, Sendable {
    public static let requiredVersion = "0.36.0"

    public let launcherURL: URL
    public let cliEntryURL: URL?

    public init(
        launcherURL: URL,
        cliEntryURL: URL? = nil
    ) {
        self.launcherURL = launcherURL
        self.cliEntryURL = cliEntryURL
    }
}

/// Exact argv for a visible Runtime CLI operation. A Studio app must launch
/// this in a real terminal. Attach and switch retain the CLI's own preview and
/// `y/N`; callers must not append `--yes` or reinterpret that preview.
public struct KDNStudioRuntimeCLITerminalCommand: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let workingDirectoryURL: URL
}

public enum KDNStudioWorkspaceCLIError: Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case incompatible
    case unsafeWorkspace
    case noAttachmentRecord
    case invalidAttachment
    case stateChanged
    case commandRejected
    case outputInvalid
    case outputTooLarge

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The configured KDNA runtime CLI is unavailable."
        case .incompatible:
            return "Workspace management requires the exact configured KDNA runtime CLI version."
        case .unsafeWorkspace:
            return "Choose an available local workspace with a safe attachment record."
        case .noAttachmentRecord:
            return "This exact workspace has no approved KDNA attachment record."
        case .invalidAttachment:
            return "The selected workspace attachment is invalid."
        case .stateChanged:
            return "Workspace attachment state changed. Refresh before applying a control."
        case .commandRejected:
            return "The KDNA runtime CLI rejected the workspace request."
        case .outputInvalid, .outputTooLarge:
            return "The KDNA runtime CLI returned an invalid workspace response."
        }
    }
}

#if os(macOS)
public protocol KDNStudioWorkspaceCLITransport: Sendable {
    func execute(
        launcher: URL,
        arguments: [String],
        cwd: URL
    ) async throws -> Data
}

/// Default transport for unsandboxed hosts and package-level consumers.
public struct KDNStudioProcessCLITransport: KDNStudioWorkspaceCLITransport {
    private static let maximumOutputBytes = 16 * 1_024 * 1_024
    private static let commandTimeout: TimeInterval = 30

    public init() {}

    public func execute(
        launcher: URL,
        arguments: [String],
        cwd: URL
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Self.executeSync(
                        launcher: launcher,
                        arguments: arguments,
                        cwd: cwd
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func executeSync(
        launcher: URL,
        arguments: [String],
        cwd: URL
    ) throws -> Data {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = launcher
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            throw KDNStudioWorkspaceCLIError.unavailable
        }

        let readers = DispatchGroup()
        let output = KDNStudioLockedData()
        let errorOutput = KDNStudioLockedData()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            output.value = outputPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorOutput.value = errorPipe.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }

        if exited.wait(timeout: .now() + commandTimeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
            readers.wait()
            throw KDNStudioWorkspaceCLIError.commandRejected
        }
        readers.wait()
        guard output.value.count <= maximumOutputBytes,
              errorOutput.value.count <= maximumOutputBytes
        else { throw KDNStudioWorkspaceCLIError.outputTooLarge }
        guard process.terminationStatus == 0 else {
            throw KDNStudioWorkspaceCLIError.commandRejected
        }
        return output.value
    }
}

private final class KDNStudioLockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var value: Data {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

/// Thin macOS adapter around the exact Runtime CLI.
///
/// It never parses `.kdna/attachments.json`, searches `PATH`, or owns a second
/// attachment state. Direct mutations are guarded against stale UI state.
public actor KDNStudioWorkspaceCLIClient {
    private static let maximumOutputBytes = 16 * 1_024 * 1_024
    private let configuration: KDNStudioRuntimeCLIConfiguration
    private let transport: any KDNStudioWorkspaceCLITransport
    private var resolvedLauncher: URL?
    private var resolvedEntry: URL?

    public init(
        configuration: KDNStudioRuntimeCLIConfiguration,
        transport: any KDNStudioWorkspaceCLITransport = KDNStudioProcessCLITransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    public func status(workspaceURL: URL) async throws -> KDNAWorkspaceAttachmentRecord? {
        let root = try workspaceRoot(workspaceURL, recordRequired: false)
        guard root.recordExists else { return nil }
        let output = try await run(["attachments", "--cwd", root.url.path], cwd: root.url)
        do {
            return try KDNAWorkspaceAttachmentStatusDecoder.decode(output)
        } catch KDNAWorkspaceAttachmentStatusError.outputTooLarge {
            throw KDNStudioWorkspaceCLIError.outputTooLarge
        } catch {
            throw KDNStudioWorkspaceCLIError.outputInvalid
        }
    }

    public func perform(
        _ action: KDNAWorkspaceAttachmentAction,
        selected: KDNAWorkspaceAttachment,
        workspaceURL: URL
    ) async throws -> KDNAWorkspaceAttachmentRecord? {
        guard [.enable, .disable, .rollback, .removeRelation].contains(action) else {
            throw KDNStudioWorkspaceCLIError.invalidAttachment
        }
        let current = try await currentAttachment(selected, workspaceURL: workspaceURL)
        guard current == selected else { throw KDNStudioWorkspaceCLIError.stateChanged }
        let command: String
        switch action {
        case .enable: command = "enable"
        case .disable: command = "disable"
        case .rollback: command = "rollback"
        case .removeRelation: command = "remove"
        case .switchExactFile: throw KDNStudioWorkspaceCLIError.invalidAttachment
        }
        let root = try workspaceRoot(workspaceURL, recordRequired: true)
        let output = try await run(
            [command, selected.attachmentID, "--cwd", root.url.path],
            cwd: root.url
        )
        try validateMutationOutput(output, operation: command)
        let updated = try await status(workspaceURL: root.url)
        try validatePostcondition(action, selected: selected, record: updated)
        return updated
    }

    public func attachApprovalCommand(
        assetURL: URL,
        workspaceURL: URL,
        role: String,
        appliesTo: [String],
        doesNotApplyTo: [String]
    ) async throws -> KDNStudioRuntimeCLITerminalCommand {
        let root = try workspaceRoot(workspaceURL, recordRequired: false)
        guard assetURL.isFileURL, assetURL.pathExtension.lowercased() == "kdna",
              validText(role), validTerms(appliesTo, required: true),
              validTerms(doesNotApplyTo, required: false)
        else { throw KDNStudioWorkspaceCLIError.invalidAttachment }
        var arguments = [
            "attach", assetURL.path,
            "--cwd", root.url.path,
            "--role", role,
        ]
        for scope in appliesTo { arguments += ["--applies-to", scope] }
        for scope in doesNotApplyTo { arguments += ["--does-not-apply-to", scope] }
        return try await approvalCommand(arguments, cwd: root.url)
    }

    public func switchApprovalCommand(
        selected: KDNAWorkspaceAttachment,
        assetURL: URL,
        workspaceURL: URL
    ) async throws -> KDNStudioRuntimeCLITerminalCommand {
        guard try await currentAttachment(selected, workspaceURL: workspaceURL) == selected else {
            throw KDNStudioWorkspaceCLIError.stateChanged
        }
        guard assetURL.isFileURL, assetURL.pathExtension.lowercased() == "kdna" else {
            throw KDNStudioWorkspaceCLIError.invalidAttachment
        }
        let root = try workspaceRoot(workspaceURL, recordRequired: true)
        return try await approvalCommand([
            "switch", selected.attachmentID, assetURL.path,
            "--cwd", root.url.path,
        ], cwd: root.url)
    }

    /// Opens the exact CLI's content-neutral inspection in a visible terminal.
    public func inspectTerminalCommand(
        assetURL: URL
    ) async throws -> KDNStudioRuntimeCLITerminalCommand {
        try await explicitAssetCommand(["inspect", assetURL.path, "--json"], assetURL: assetURL)
    }

    /// Loads one explicitly selected public/local asset without creating a
    /// persistent workspace relation. Protected assets remain in their
    /// authorization flow and are not given secrets on argv.
    public func useOnceTerminalCommand(
        assetURL: URL
    ) async throws -> KDNStudioRuntimeCLITerminalCommand {
        try await explicitAssetCommand(
            ["load", assetURL.path, "--profile", "compact", "--as", "json"],
            assetURL: assetURL
        )
    }

    private func currentAttachment(
        _ selected: KDNAWorkspaceAttachment,
        workspaceURL: URL
    ) async throws -> KDNAWorkspaceAttachment {
        guard let record = try await status(workspaceURL: workspaceURL),
              let current = record.attachments.first(where: { $0.attachmentID == selected.attachmentID })
        else { throw KDNStudioWorkspaceCLIError.stateChanged }
        return current
    }

    private func approvalCommand(
        _ commandArguments: [String],
        cwd: URL
    ) async throws -> KDNStudioRuntimeCLITerminalCommand {
        let executable = try await verifiedExecutable()
        return KDNStudioRuntimeCLITerminalCommand(
            executableURL: executable.launcher,
            arguments: executable.prefix + commandArguments,
            workingDirectoryURL: cwd
        )
    }

    private func explicitAssetCommand(
        _ arguments: [String],
        assetURL: URL
    ) async throws -> KDNStudioRuntimeCLITerminalCommand {
        guard assetURL.isFileURL, assetURL.pathExtension.lowercased() == "kdna" else {
            throw KDNStudioWorkspaceCLIError.invalidAttachment
        }
        return try await approvalCommand(arguments, cwd: assetURL.deletingLastPathComponent())
    }

    private func validatePostcondition(
        _ action: KDNAWorkspaceAttachmentAction,
        selected: KDNAWorkspaceAttachment,
        record: KDNAWorkspaceAttachmentRecord?
    ) throws {
        let current = record?.attachments.first(where: { $0.attachmentID == selected.attachmentID })
        switch action {
        case .enable where current?.state == .enabled: return
        case .disable where current?.state == .disabled: return
        case .rollback:
            guard let current,
                  let previous = selected.history.last,
                  current.asset == previous.asset,
                  current.history == Array(selected.history.dropLast())
            else { throw KDNStudioWorkspaceCLIError.commandRejected }
            return
        case .removeRelation where current == nil: return
        default: throw KDNStudioWorkspaceCLIError.commandRejected
        }
    }

    private func validateMutationOutput(_ data: Data, operation: String) throws {
        guard data.count <= Self.maximumOutputBytes,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["operation"] as? String == operation
        else { throw KDNStudioWorkspaceCLIError.outputInvalid }
    }

    private func workspaceRoot(
        _ workspaceURL: URL,
        recordRequired: Bool
    ) throws -> (url: URL, recordExists: Bool) {
        guard workspaceURL.isFileURL else { throw KDNStudioWorkspaceCLIError.unsafeWorkspace }
        let root = workspaceURL.resolvingSymlinksInPath().standardizedFileURL
        guard root == workspaceURL.standardizedFileURL else {
            throw KDNStudioWorkspaceCLIError.unsafeWorkspace
        }
        let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues?.isDirectory == true else {
            throw KDNStudioWorkspaceCLIError.unsafeWorkspace
        }
        let recordURL = root
            .appendingPathComponent(".kdna", isDirectory: true)
            .appendingPathComponent("attachments.json")
        guard FileManager.default.fileExists(atPath: recordURL.path) else {
            if recordRequired { throw KDNStudioWorkspaceCLIError.noAttachmentRecord }
            return (root, false)
        }
        let recordValues = try? recordURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard recordValues?.isRegularFile == true,
              recordValues?.isSymbolicLink != true,
              recordURL.resolvingSymlinksInPath().standardizedFileURL == recordURL.standardizedFileURL
        else { throw KDNStudioWorkspaceCLIError.unsafeWorkspace }
        return (root, true)
    }

    private func verifiedExecutable() async throws -> (launcher: URL, prefix: [String]) {
        if let resolvedLauncher {
            return (resolvedLauncher, resolvedEntry.map { [$0.path] } ?? [])
        }
        let launcher = try regularFile(configuration.launcherURL, executable: true)
        let entry = try configuration.cliEntryURL.map { try regularFile($0, executable: false) }
        let prefix = entry.map { [$0.path] } ?? []
        let output = try await transport.execute(
            launcher: launcher,
            arguments: prefix + ["--version"],
            cwd: FileManager.default.temporaryDirectory
        )
        guard String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) ==
            KDNStudioRuntimeCLIConfiguration.requiredVersion
        else { throw KDNStudioWorkspaceCLIError.incompatible }
        resolvedLauncher = launcher
        resolvedEntry = entry
        return (launcher, prefix)
    }

    private func regularFile(_ url: URL, executable: Bool) throws -> URL {
        guard url.isFileURL else { throw KDNStudioWorkspaceCLIError.unavailable }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true,
              !executable || FileManager.default.isExecutableFile(atPath: resolved.path)
        else { throw KDNStudioWorkspaceCLIError.unavailable }
        return resolved
    }

    private func run(_ arguments: [String], cwd: URL) async throws -> Data {
        let executable = try await verifiedExecutable()
        return try await transport.execute(
            launcher: executable.launcher,
            arguments: executable.prefix + arguments,
            cwd: cwd
        )
    }

    private func validText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            value.utf16.count <= 4_096
    }

    private func validTerms(_ values: [String], required: Bool) -> Bool {
        guard values.count <= 256, !required || !values.isEmpty else { return false }
        var normalized = Set<String>()
        for value in values {
            guard validText(value) else { return false }
            let key = value
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
                .lowercased()
            guard normalized.insert(key).inserted else { return false }
        }
        return true
    }
}
#endif
