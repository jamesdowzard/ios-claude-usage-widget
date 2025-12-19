import Foundation
import os.log

/// File-based credential storage - no keychain prompts
class FileCredentialService {
    static let shared = FileCredentialService()

    private let logger = Logger(subsystem: "com.jamesdowzard.ClaudeUsageWidget", category: "FileCredentialService")
    private let configDir: URL
    private let credentialsFile: URL

    private init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        configDir = homeDir.appendingPathComponent(".config/claude-usage-widget")
        credentialsFile = configDir.appendingPathComponent("credentials.json")

        // Ensure config directory exists
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    }

    // MARK: - Data Structures

    struct StoredCredentials: Codable {
        var accounts: [StoredAccount]
        var selectedAccountId: String?
    }

    struct StoredAccount: Codable {
        var id: String
        var name: String
        var icon: String
        var accessToken: String
        var refreshToken: String
        var expiresAt: Double  // Unix timestamp in seconds
        var email: String?  // Email associated with this Claude account
        var claudeAccountUUID: String?  // Anthropic's UUID for this Claude account (from statsig/profile API)
    }

    // MARK: - Read/Write

    func loadCredentials() -> StoredCredentials? {
        guard FileManager.default.fileExists(atPath: credentialsFile.path) else {
            logger.info("No credentials file found at \(self.credentialsFile.path)")
            return nil
        }

        do {
            let data = try Data(contentsOf: credentialsFile)
            let credentials = try JSONDecoder().decode(StoredCredentials.self, from: data)
            logger.info("Loaded \(credentials.accounts.count) accounts from file")
            return credentials
        } catch {
            logger.error("Failed to load credentials: \(error.localizedDescription)")
            return nil
        }
    }

    func saveCredentials(_ credentials: StoredCredentials) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(credentials)
            try data.write(to: credentialsFile, options: .atomic)

            // Set restrictive permissions (owner read/write only)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialsFile.path)

            logger.info("Saved \(credentials.accounts.count) accounts to file")
            return true
        } catch {
            logger.error("Failed to save credentials: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Account Operations

    func getAccount(byId id: String) -> StoredAccount? {
        return loadCredentials()?.accounts.first { $0.id == id }
    }

    func getAllAccounts() -> [StoredAccount] {
        return loadCredentials()?.accounts ?? []
    }

    func getSelectedAccountId() -> String? {
        return loadCredentials()?.selectedAccountId
    }

    func setSelectedAccountId(_ id: String) {
        guard var credentials = loadCredentials() else { return }
        credentials.selectedAccountId = id
        _ = saveCredentials(credentials)
    }

    func updateAccountToken(accountId: String, accessToken: String, refreshToken: String, expiresAt: Double) -> Bool {
        guard var credentials = loadCredentials() else { return false }

        if let index = credentials.accounts.firstIndex(where: { $0.id == accountId }) {
            credentials.accounts[index].accessToken = accessToken
            credentials.accounts[index].refreshToken = refreshToken
            credentials.accounts[index].expiresAt = expiresAt
            return saveCredentials(credentials)
        }
        return false
    }

    func addAccount(name: String, icon: String, accessToken: String, refreshToken: String, expiresAt: Double, email: String? = nil) -> StoredAccount {
        var credentials = loadCredentials() ?? StoredCredentials(accounts: [], selectedAccountId: nil)

        let newAccount = StoredAccount(
            id: UUID().uuidString.uppercased(),
            name: name,
            icon: icon,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            email: email
        )

        credentials.accounts.append(newAccount)
        if credentials.selectedAccountId == nil {
            credentials.selectedAccountId = newAccount.id
        }

        _ = saveCredentials(credentials)
        return newAccount
    }

    func updateAccountEmail(accountId: String, email: String) -> Bool {
        guard var credentials = loadCredentials() else { return false }

        if let index = credentials.accounts.firstIndex(where: { $0.id == accountId }) {
            credentials.accounts[index].email = email
            return saveCredentials(credentials)
        }
        return false
    }

    func getAccountByEmail(_ email: String) -> StoredAccount? {
        return loadCredentials()?.accounts.first { $0.email?.lowercased() == email.lowercased() }
    }

    func getAccountByClaudeUUID(_ uuid: String) -> StoredAccount? {
        return loadCredentials()?.accounts.first { $0.claudeAccountUUID == uuid }
    }

    func updateAccountClaudeUUID(accountId: String, claudeUUID: String) -> Bool {
        guard var credentials = loadCredentials() else { return false }

        if let index = credentials.accounts.firstIndex(where: { $0.id == accountId }) {
            credentials.accounts[index].claudeAccountUUID = claudeUUID
            return saveCredentials(credentials)
        }
        return false
    }

    func removeAccount(byId id: String) {
        guard var credentials = loadCredentials() else { return }
        credentials.accounts.removeAll { $0.id == id }
        if credentials.selectedAccountId == id {
            credentials.selectedAccountId = credentials.accounts.first?.id
        }
        _ = saveCredentials(credentials)
    }

    // MARK: - Token Helpers

    func getValidToken(forAccountId id: String) -> String? {
        guard let account = getAccount(byId: id) else { return nil }

        // Check if token is expired (with 5 min buffer)
        let now = Date().timeIntervalSince1970
        if account.expiresAt < now + 300 {
            return nil  // Token expired or expiring soon
        }

        return account.accessToken
    }

    func isTokenExpired(forAccountId id: String) -> Bool {
        guard let account = getAccount(byId: id) else { return true }
        let now = Date().timeIntervalSince1970
        return account.expiresAt < now + 300
    }

    func getRefreshToken(forAccountId id: String) -> String? {
        return getAccount(byId: id)?.refreshToken
    }

    // MARK: - Claude Code Statsig Integration

    /// Read the current Claude account UUID from Claude Code's statsig cache
    /// Statsig is a feature flagging service - Claude Code caches its response which includes the account UUID
    /// This file updates whenever Claude Code runs, so it reflects the currently logged-in account
    func getCurrentClaudeAccountUUID() -> String? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let statsigDir = homeDir.appendingPathComponent(".claude/statsig")

        // Find the most recent statsig cache file
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: statsigDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return nil
        }

        // Find the cached evaluations file
        guard let statsigFile = contents.first(where: { $0.lastPathComponent.hasPrefix("statsig.cached.evaluations.") }) else {
            return nil
        }

        // Read and parse the file
        guard let data = try? Data(contentsOf: statsigFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataString = json["data"] as? String,
              let innerData = dataString.data(using: .utf8),
              let innerJson = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any],
              let evaluatedKeys = innerJson["evaluated_keys"] as? [String: Any],
              let customIDs = evaluatedKeys["customIDs"] as? [String: Any],
              let accountUUID = customIDs["accountUUID"] as? String else {
            return nil
        }

        return accountUUID
    }
}
