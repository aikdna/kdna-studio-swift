//  KDNAStudioCore — Local-first creator identity via macOS Keychain + CryptoKit
//
//  Aligned with: @aikdna/kdna-studio-core/src/creator-identity.js
//
//  Key design:
//   - Private key stored in macOS Keychain (never on disk)
//   - Public key + metadata stored in ~/.kdna/identity/creator.json
//   - creator_id = "kdna:creator:ed25519:<SHA256-of-public-key-DER>"
//   - Signing: Ed25519 via CryptoKit
//   - No registration. No upload. No cloud dependency.

import Foundation
import CryptoKit

#if os(macOS)
import Security
#endif

public class KDNStudioIdentity: @unchecked Sendable {
    public static let shared = KDNStudioIdentity()

    private static let keychainService = "com.aikdna.kdna-studio"
    private static let keychainAccount = "creator-identity-ed25519"
    private static let creatorIDPrefix = "kdna:creator:ed25519:"

    // MARK: - Init

    /// Initialize a new creator identity. Generates an Ed25519 keypair,
    /// stores the private key in Keychain, and writes identity metadata to disk.
    /// Throws if an identity already exists.
    @discardableResult
    public func initIdentity(displayName: String, identityDir: String? = nil) throws -> KDNCreatorIdentity {
        let dir = identityDir ?? Self.defaultIdentityDir()
        let identityPath = (dir as NSString).appendingPathComponent("creator.json")

        // Guard: identity already exists
        if FileManager.default.fileExists(atPath: identityPath) {
            throw KDNStudioIdentityError.identityAlreadyExists(dir)
        }

        // Generate Ed25519 keypair
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        let publicKeyRaw = publicKey.rawRepresentation

        // Build Ed25519 SPKI DER:
        // SEQUENCE (42) { SEQUENCE (5) { OID 1.3.101.112 }, BIT STRING (33) { 00 + 32 raw } }
        let publicKeyDER = Self.buildEd25519SPKI(rawKey: publicKeyRaw)
        let publicKeyPEM = Self.derToPEM(publicKeyDER)

        // Compute creator_id fingerprint from raw key (matches JS: SHA256 of PEM)
        let fingerprint = SHA256.hash(data: publicKeyPEM.data(using: .utf8)!)
        let creatorID = Self.creatorIDPrefix + fingerprint.compactMap { String(format: "%02x", $0) }.joined()

        // Store private key in Keychain
        try storePrivateKey(privateKey.rawRepresentation)

        // Write identity metadata
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let identity: [String: Any] = [
            "creator_id": creatorID,
            "display_name": displayName,
            "public_key": publicKeyPEM,
            "verified": false,
            "created_at": ISO8601DateFormatter().string(from: Date()),
        ]
        let json = try JSONSerialization.data(withJSONObject: identity, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: URL(fileURLWithPath: identityPath), options: [.atomic])

        return try loadIdentity(identityDir: dir)!
    }

    /// Load an existing identity from disk + Keychain.
    /// Returns nil if no identity found.
    public func loadIdentity(identityDir: String? = nil) throws -> KDNCreatorIdentity? {
        let dir = identityDir ?? Self.defaultIdentityDir()
        let identityPath = (dir as NSString).appendingPathComponent("creator.json")

        guard FileManager.default.fileExists(atPath: identityPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: identityPath)),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let creatorID = dict["creator_id"] as? String,
              let displayName = dict["display_name"] as? String,
              let publicKeyPEM = dict["public_key"] as? String
        else { return nil }

        return KDNCreatorIdentity(
            creatorId: creatorID,
            displayName: displayName,
            publicKey: publicKeyPEM,
            verified: dict["verified"] as? Bool ?? false,
            createdAt: dict["created_at"] as? String
        )
    }

    /// Sign a payload with the creator's Ed25519 private key.
    /// Returns the signature as "ed25519:<hex>".
    public func sign(_ payload: Data) throws -> String {
        let rawKey = try loadPrivateKey()
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
        let signature = try privateKey.signature(for: payload)
        return "ed25519:" + signature.hexString
    }

    /// Sign a Human Lock statement. Payload: `cardId\nstatement\nfingerprint`
    public func signHumanLock(cardID: String, statement: String, judgmentFingerprint: String) throws -> String {
        let payload = [cardID, statement, judgmentFingerprint].joined(separator: "\n")
        return try sign(Data(payload.utf8))
    }

    /// Get the identity directory (~/.kdna/identity by default).
    public func identityDir() -> String {
        Self.defaultIdentityDir()
    }

    // MARK: - Keychain

    #if os(macOS)

    private func storePrivateKey(_ rawKey: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecValueData as String: rawKey,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        // Delete any existing item first
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KDNStudioIdentityError.keychainWriteFailed(status)
        }
    }

    private func loadPrivateKey() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KDNStudioIdentityError.keychainReadFailed(status)
        }
        return data
    }

    #elseif os(iOS)

    // iOS: use Keychain (same API via Security framework)
    private func storePrivateKey(_ rawKey: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecValueData as String: rawKey,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KDNStudioIdentityError.keychainWriteFailed(status)
        }
    }

    private func loadPrivateKey() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KDNStudioIdentityError.keychainReadFailed(status)
        }
        return data
    }

    #endif

    // MARK: - Helpers

    private static func defaultIdentityDir() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".kdna/identity")
    }

    private static func derToPEM(_ der: Data) -> String {
        let base64 = der.base64EncodedString()
        var lines = "-----BEGIN PUBLIC KEY-----"
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines += "\n" + base64[index..<end]
            index = end
        }
        lines += "\n-----END PUBLIC KEY-----"
        return lines
    }

    /// Build Ed25519 SubjectPublicKeyInfo DER (matches Node.js Ed25519 PEM format)
    private static func buildEd25519SPKI(rawKey: Data) -> Data {
        var der = Data()
        let oid: [UInt8] = [0x06, 0x03, 0x2b, 0x65, 0x70] // OID 1.3.101.112
        let algoSequence = encodeDERLength(oid.count) + Data(oid)

        var bitString = Data([0x00]) // unused bits = 0
        bitString.append(rawKey)
        let bitStringEnc = encodeDERLength(bitString.count) + bitString

        let seq = encodeDERLength(algoSequence.count + bitStringEnc.count) + algoSequence + bitStringEnc
        der.append(0x30) // SEQUENCE
        der.append(seq)
        return der
    }

    private static func encodeDERLength(_ len: Int) -> Data {
        if len < 128 {
            return Data([UInt8(len)])
        }
        var l = len
        var bytes: [UInt8] = []
        while l > 0 {
            bytes.insert(UInt8(l & 0xff), at: 0)
            l >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }
}

// MARK: - Errors

public enum KDNStudioIdentityError: Error, LocalizedError {
    case identityAlreadyExists(String)
    case keychainWriteFailed(OSStatus)
    case keychainReadFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .identityAlreadyExists(let dir):
            return "Creator identity already exists at \(dir). Use loadIdentity() to access it."
        case .keychainWriteFailed(let status):
            return "Keychain write failed with status \(status)."
        case .keychainReadFailed(let status):
            return "Keychain read failed with status \(status). No identity found."
        }
    }
}

// MARK: - Data hex extension

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
