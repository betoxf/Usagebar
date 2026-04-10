//
//  CredentialStorage.swift
//  JustaUsageBar
//
//  Encrypted file-based credential storage (no Keychain prompts)
//

import Foundation
import CryptoKit

final class CredentialStorage {
    static let shared = CredentialStorage()

    private let fileName = "credentials.enc"
    private var cachedCredentials: Credentials?

    struct Credentials: Codable {
        var sessionKey: String?
        var organizationId: String?
        var claudeOAuth: ClaudeOAuthCredentials?
    }

    struct ClaudeOAuthCredentials: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var scopes: [String]
    }

    private init() {
        loadCredentials()
    }

    // MARK: - Public API

    var sessionKey: String? {
        get { cachedCredentials?.sessionKey }
        set {
            if cachedCredentials == nil {
                cachedCredentials = Credentials()
            }
            cachedCredentials?.sessionKey = newValue
            saveCredentials()
        }
    }

    var organizationId: String? {
        get { cachedCredentials?.organizationId }
        set {
            if cachedCredentials == nil {
                cachedCredentials = Credentials()
            }
            cachedCredentials?.organizationId = newValue
            saveCredentials()
        }
    }

    var hasCredentials: Bool {
        sessionKey != nil && organizationId != nil
    }

    var claudeOAuthCredentials: ClaudeOAuthCredentials? {
        get { cachedCredentials?.claudeOAuth }
        set {
            if cachedCredentials == nil {
                cachedCredentials = Credentials()
            }
            cachedCredentials?.claudeOAuth = newValue
            saveCredentials()
        }
    }

    func clearAll() {
        cachedCredentials = nil
        try? FileManager.default.removeItem(at: credentialsFileURL)
    }

    func clearClaudeOAuthCredentials() {
        guard cachedCredentials != nil else {
            return
        }

        cachedCredentials?.claudeOAuth = nil

        if cachedCredentials?.sessionKey == nil && cachedCredentials?.organizationId == nil {
            cachedCredentials = nil
            try? FileManager.default.removeItem(at: credentialsFileURL)
            return
        }

        saveCredentials()
    }

    // MARK: - File Storage

    private var credentialsFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("JustaUsageBar", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)

        return appFolder.appendingPathComponent(fileName)
    }

    private func loadCredentials() {
        guard FileManager.default.fileExists(atPath: credentialsFileURL.path) else {
            cachedCredentials = nil
            return
        }

        do {
            let encryptedData = try Data(contentsOf: credentialsFileURL)
            let decryptedData = try decrypt(encryptedData)
            cachedCredentials = try JSONDecoder().decode(Credentials.self, from: decryptedData)
        } catch {
            print("Failed to load credentials: \(error)")
            cachedCredentials = nil
        }
    }

    private func saveCredentials() {
        guard let credentials = cachedCredentials else {
            try? FileManager.default.removeItem(at: credentialsFileURL)
            return
        }

        do {
            let data = try JSONEncoder().encode(credentials)
            let encryptedData = try encrypt(data)
            try encryptedData.write(to: credentialsFileURL, options: .atomic)
        } catch {
            print("Failed to save credentials: \(error)")
        }
    }

    // MARK: - Encryption (AES-GCM with device-specific key)

    private var encryptionKey: SymmetricKey {
        // Generate a deterministic key based on machine-specific info
        // This ensures only this machine can decrypt the credentials
        let machineId = getMachineIdentifier()
        let salt = "JustaUsageBar.v1"
        let keyMaterial = "\(machineId).\(salt)"

        // Use SHA256 to derive a 256-bit key
        let hash = SHA256.hash(data: Data(keyMaterial.utf8))
        return SymmetricKey(data: hash)
    }

    private func getMachineIdentifier() -> String {
        // Use hardware UUID as machine identifier
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )

        defer { IOObjectRelease(platformExpert) }

        if let serialNumberAsCFString = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        ) {
            return (serialNumberAsCFString.takeUnretainedValue() as? String) ?? "default"
        }

        return "default"
    }

    private func encrypt(_ data: Data) throws -> Data {
        let sealedBox = try AES.GCM.seal(data, using: encryptionKey)
        guard let combined = sealedBox.combined else {
            throw NSError(domain: "CredentialStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Encryption failed"])
        }
        return combined
    }

    private func decrypt(_ data: Data) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: encryptionKey)
    }
}
