import Foundation

/// Service for loading credentials from config files or environment variables
/// Priority: 1. Environment vars, 2. Config file, 3. Keychain (handled by TokenService)
class ConfigService {
    static let shared = ConfigService()

    private let configFilePath = "~/.credentials/claude-usage-widget.env"

    private init() {}

    /// Check if we have config-based credentials (not Keychain)
    var hasConfigCredentials: Bool {
        return getConfigCredentials(for: "personal") != nil ||
               getConfigCredentials(for: "work") != nil
    }

    /// Get credentials from config sources (env vars or file)
    /// Returns (accessToken, refreshToken) or nil
    func getConfigCredentials(for accountType: String) -> (access: String, refresh: String)? {
        let type = accountType.lowercased()

        // Try environment variables first
        let accessKey = type == "personal" ? "CLAUDE_PERSONAL_TOKEN" : "CLAUDE_WORK_TOKEN"
        let refreshKey = type == "personal" ? "CLAUDE_PERSONAL_REFRESH" : "CLAUDE_WORK_REFRESH"

        if let access = ProcessInfo.processInfo.environment[accessKey],
           let refresh = ProcessInfo.processInfo.environment[refreshKey],
           !access.isEmpty, !refresh.isEmpty {
            return (access, refresh)
        }

        // Try config file
        return loadFromConfigFile(accessKey: accessKey, refreshKey: refreshKey)
    }

    private func loadFromConfigFile(accessKey: String, refreshKey: String) -> (access: String, refresh: String)? {
        let path = NSString(string: configFilePath).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: path),
              let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        var values: [String: String] = [:]

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let parts = trimmed.components(separatedBy: "=")
            guard parts.count >= 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
            values[key] = value
        }

        if let access = values[accessKey], let refresh = values[refreshKey],
           !access.isEmpty, !refresh.isEmpty {
            return (access, refresh)
        }

        return nil
    }

    /// Get all configured account types from config
    func getConfiguredAccounts() -> [String] {
        var accounts: [String] = []
        if getConfigCredentials(for: "personal") != nil {
            accounts.append("Personal")
        }
        if getConfigCredentials(for: "work") != nil {
            accounts.append("Work")
        }
        return accounts
    }
}
