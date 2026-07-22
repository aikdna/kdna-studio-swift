import CryptoKit
import Darwin
import Foundation
import KDNAAppShared
import KDNACore

public struct KDNStudioLocalAssetInspection: Equatable, Sendable {
    public let title: String
    public let assetID: String
    public let version: String
    public let digest: String
    public let creatorName: String?
    public let access: String?
    public let encrypted: Bool
    public let formatVersion: String
    public let minimumLoaderVersion: String
    public let appliesWhen: [String]
    public let doesNotApplyWhen: [String]
    public let loadPlan: KDNALoadPlanPresentationInput

    public var identity: String { "\(assetID)@\(version)" }
}

public enum KDNStudioLocalAssetInspectionError: Error, Equatable, LocalizedError, Sendable {
    case unsafeFile
    case oversizedFile
    case invalidAsset

    public var errorDescription: String? {
        switch self {
        case .unsafeFile:
            return "Choose a regular, non-symlink .kdna file."
        case .oversizedFile:
            return "The selected .kdna file exceeds the local inspection limit."
        case .invalidAsset:
            return "The selected file is not a valid KDNA runtime asset."
        }
    }
}

/// Content-neutral file inspection for the Studio open-file surface.
///
/// The source is read through one non-following descriptor, then Core plans an
/// isolated copy of those exact bytes. Opening a file does not attach or load
/// it into a task.
public enum KDNStudioLocalAssetInspector {
    private static let maximumAssetBytes = 256 * 1_024 * 1_024

    public static func inspect(_ sourceURL: URL) throws -> KDNStudioLocalAssetInspection {
        guard sourceURL.isFileURL, sourceURL.pathExtension.lowercased() == "kdna" else {
            throw KDNStudioLocalAssetInspectionError.unsafeFile
        }
        let bytes = try readRegularFile(sourceURL)
        let reader = KDNAAssetReader()
        let asset: KDNAAsset
        let manifest: KDNAManifest
        do {
            asset = try reader.open(data: bytes)
            manifest = try reader.decodeManifest(asset: asset)
        } catch {
            throw KDNStudioLocalAssetInspectionError.invalidAsset
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kdna-studio-inspect-\(UUID().uuidString)", isDirectory: true)
        let temporaryAsset = temporaryDirectory.appendingPathComponent("asset.kdna")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try bytes.write(to: temporaryAsset, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryAsset.path
            )
        } catch {
            throw KDNStudioLocalAssetInspectionError.invalidAsset
        }

        let plan = KDNARuntime.planLoad(assetURL: temporaryAsset)
        guard plan.checks.overall_valid,
              plan.state != "invalid",
              plan.asset.asset_id == manifest.asset_id,
              plan.asset.version == manifest.version
        else {
            throw KDNStudioLocalAssetInspectionError.invalidAsset
        }
        let digest = "sha256:" + SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let boundaries = manifest.payload.encrypted
            ? (applies: [], excludes: [])
            : inspectBoundaries(reader: reader, asset: asset)
        return KDNStudioLocalAssetInspection(
            title: manifest.title,
            assetID: manifest.asset_id,
            version: manifest.version,
            digest: digest,
            creatorName: manifest.creator?.name,
            access: plan.access,
            encrypted: manifest.payload.encrypted,
            formatVersion: manifest.format_version,
            minimumLoaderVersion: manifest.compatibility.min_loader_version,
            appliesWhen: boundaries.applies,
            doesNotApplyWhen: boundaries.excludes,
            loadPlan: KDNALoadPlanPresentationInput(
                assetTitle: manifest.title,
                state: plan.state,
                requiredAction: plan.required_action,
                canLoadNow: plan.can_load_now,
                issueCodes: plan.issues.map(\.code)
            )
        )
    }

    /// Reads only declared applicability fields from a validated public
    /// judgment payload. It never returns statements or a task projection.
    private static func inspectBoundaries(
        reader: KDNAAssetReader,
        asset: KDNAAsset
    ) -> (applies: [String], excludes: [String]) {
        guard let data = try? reader.readEntry(asset: asset, name: "payload.kdnab"),
              let payload = try? KDNACBOR.decodeObject(data),
              let core = payload["core"] as? [String: Any],
              let axioms = core["axioms"] as? [[String: Any]]
        else { return ([], []) }

        func terms(_ key: String) -> [String] {
            var seen = Set<String>()
            var result: [String] = []
            for axiom in axioms.prefix(1_024) {
                for case let text as String in (axiom[key] as? [Any] ?? []).prefix(256) {
                    let normalized = text
                        .split(whereSeparator: { $0.isWhitespace })
                        .joined(separator: " ")
                    guard !normalized.isEmpty, normalized.utf16.count <= 4_096 else { continue }
                    let key = normalized.lowercased()
                    guard seen.insert(key).inserted else { continue }
                    result.append(normalized)
                }
            }
            return result
        }
        return (terms("applies_when"), terms("does_not_apply_when"))
    }

    private static func readRegularFile(_ url: URL) throws -> Data {
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw KDNStudioLocalAssetInspectionError.unsafeFile
        }
        defer { close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0
        else {
            throw KDNStudioLocalAssetInspectionError.unsafeFile
        }
        guard before.st_size <= maximumAssetBytes else {
            throw KDNStudioLocalAssetInspectionError.oversizedFile
        }

        let byteCount = Int(before.st_size)
        var readFailed = false
        var data = Data(count: byteCount)
        let totalRead = data.withUnsafeMutableBytes { buffer -> Int in
            guard byteCount > 0, let baseAddress = buffer.baseAddress else { return 0 }
            var total = 0
            while total < byteCount {
                let count = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: total),
                    byteCount - total
                )
                if count <= 0 {
                    readFailed = true
                    break
                }
                total += count
            }
            return total
        }

        var after = stat()
        guard !readFailed,
              totalRead == byteCount,
              fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
        else {
            throw KDNStudioLocalAssetInspectionError.unsafeFile
        }
        return data
    }
}
