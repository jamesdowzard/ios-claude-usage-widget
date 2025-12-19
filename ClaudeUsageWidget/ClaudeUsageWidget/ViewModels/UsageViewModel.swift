import Foundation
import Combine
import SwiftUI
import AppKit

@MainActor
class UsageViewModel: ObservableObject {
    @Published var usageData: UsageData?
    @Published var isLoading = false
    @Published var error: UsageError?
    @Published var lastUpdated: Date?

    // Team usage support
    @Published var teamUsageData: TeamUsageData?
    @Published var isLoadingTeam = false
    @Published var teamError: UsageError?
    @Published var lastTeamUpdated: Date?

    // Multi-account support
    @Published var accountManager = AccountManager.shared
    @Published var selectedAccount: Account?

    @AppStorage("refreshInterval") var refreshInterval: Int = 1 // minutes - fixed at 1 minute
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false

    private var refreshTimer: Timer?
    private let apiService = UsageAPIService.shared
    private let adminAPIService = AdminAPIService.shared
    private var cancellables = Set<AnyCancellable>()

    // Track Claude Code credentials for auto-sync
    private var lastKnownClaudeCodeToken: String?

    // Track which account is currently active in Claude Code (matches keychain credentials)
    @Published var activeClaudeCodeAccountId: UUID?

    // Static DateFormatter to avoid creating it repeatedly
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    init() {
        selectedAccount = accountManager.selectedAccount

        // Track initial Claude Code token for change detection
        lastKnownClaudeCodeToken = KeychainService.shared.getClaudeCodeCredentials()?.accessToken

        // Detect which account is active in Claude Code
        detectActiveClaudeCodeAccount()

        startAutoRefresh()

        // Fetch initial data based on mode
        Task {
            await fetchUsage()

            // Also fetch team data if in team mode
            let settings = AppSettings.shared
            if settings.hasCompletedSetup &&
               (settings.mode == .team || settings.mode == .both) {
                await fetchTeamUsage()
            }
        }

        // Listen for account changes
        accountManager.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.selectedAccount = self?.accountManager.selectedAccount
            }
        }.store(in: &cancellables)

        // Setup app lifecycle observers
        setupAppLifecycleObservers()
    }

    private func setupAppLifecycleObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: NSApplication.willResignActiveNotification,
            object: nil
        )
    }

    @objc private func appDidBecomeActive() {
        Task { @MainActor in
            // Check for credential changes first (e.g., user did /login in Claude Code)
            checkAndSyncClaudeCodeCredentials()

            startAutoRefresh()
            // Immediately refresh data when app becomes active
            refresh()
            if AppSettings.shared.mode == .team ||
               (AppSettings.shared.mode == .both && AppSettings.shared.showTeamView) {
                refreshTeam()
            }
        }
    }

    @objc private func appWillResignActive() {
        // Keep timer running even when inactive for continuous updates
        // The timer will still fire and fetch fresh data
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func fetchUsage() async {
        isLoading = true
        error = nil

        // Always use the active Claude Code account if available, otherwise fall back to selected
        let accountToUse: Account?
        if let activeId = activeClaudeCodeAccountId,
           let activeAccount = accountManager.accounts.first(where: { $0.id == activeId }) {
            accountToUse = activeAccount
        } else {
            accountToUse = selectedAccount
        }

        guard let account = accountToUse else {
            error = .tokenNotFound
            isLoading = false
            return
        }

        do {
            usageData = try await apiService.fetchUsage(for: account)
            lastUpdated = Date()
        } catch let usageError as UsageError {
            error = usageError
        } catch {
            self.error = .networkError(error)
        }

        isLoading = false
    }

    /// Import credentials from Claude Code for the selected account
    func importCredentialsFromClaudeCode() -> Bool {
        guard let account = selectedAccount else { return false }
        let success = TokenService.shared.importFromClaudeCode(for: account)
        if success {
            // Also fetch and store the email for this account
            Task {
                if let email = await apiService.fetchCurrentProfile() {
                    _ = FileCredentialService.shared.updateAccountEmail(accountId: account.id.uuidString, email: email)
                    // Update active account detection
                    await detectActiveClaudeCodeAccountAsync()
                }
            }
            refresh()
        }
        return success
    }

    /// Get expiry description for current account
    var tokenExpiryDescription: String? {
        guard let account = selectedAccount else { return nil }
        return TokenService.shared.expiryDescription(for: account)
    }

    func selectAccount(_ account: Account) {
        accountManager.selectAccount(account)
        selectedAccount = account
        refresh()
    }

    /// Switch to the active Claude Code account if one is detected
    func switchToActiveAccountIfAvailable() {
        // First refresh the active account detection
        Task {
            await detectActiveClaudeCodeAccountAsync()

            // If we found an active account and it's different from current, switch to it
            if let activeId = activeClaudeCodeAccountId,
               activeId != selectedAccount?.id,
               let activeAccount = accountManager.accounts.first(where: { $0.id == activeId }) {
                selectAccount(activeAccount)
            }
        }
    }

    func fetchTeamUsage() async {
        isLoadingTeam = true
        teamError = nil

        do {
            // Fetch today's usage
            let response = try await adminAPIService.fetchTeamUsage(for: Date())

            // Convert to TeamUsageData format
            var totalTokens = 0
            var members: [TeamMember] = []

            for memberUsage in response.data {
                totalTokens += memberUsage.totalTokens

                // For now, we don't have edit/PR counts from the API
                // These would need to be tracked separately
                let member = TeamMember(
                    id: memberUsage.memberEmail,
                    email: memberUsage.memberEmail,
                    tokenCount: memberUsage.totalTokens,
                    editCount: 0,  // Not available from API
                    prCount: 0     // Not available from API
                )
                members.append(member)
            }

            // Calculate cost (approximate - adjust pricing as needed)
            let costPerMillion = 15.0 // Adjust based on actual pricing
            let totalCost = (Double(totalTokens) / 1_000_000.0) * costPerMillion

            teamUsageData = TeamUsageData(
                totalTokens: totalTokens,
                totalCost: totalCost,
                members: members
            )
            lastTeamUpdated = Date()
        } catch let adminError as AdminAPIError {
            teamError = .networkError(adminError)
        } catch {
            teamError = .networkError(error)
        }

        isLoadingTeam = false
    }

    func refreshTeam() {
        Task {
            await fetchTeamUsage()
        }
    }

    func refresh() {
        Task {
            await fetchUsage()
        }
    }

    func startAutoRefresh() {
        stopAutoRefresh()

        let interval = TimeInterval(refreshInterval * 60)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // Check for Claude Code credential changes and auto-sync
                self?.checkAndSyncClaudeCodeCredentials()

                self?.refresh()
                // Also refresh team data if in team mode
                if AppSettings.shared.mode == .team ||
                   (AppSettings.shared.mode == .both && AppSettings.shared.showTeamView) {
                    self?.refreshTeam()
                }
            }
        }

        // Add timer to common run loop mode so it fires even when menu is open
        if let timer = refreshTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    /// Check if Claude Code credentials have changed and auto-import if so
    private func checkAndSyncClaudeCodeCredentials() {
        guard let account = selectedAccount else { return }

        let currentClaudeCodeToken = KeychainService.shared.getClaudeCodeCredentials()?.accessToken

        // If token changed, auto-import the new credentials and update email
        if currentClaudeCodeToken != lastKnownClaudeCodeToken && currentClaudeCodeToken != nil {
            lastKnownClaudeCodeToken = currentClaudeCodeToken
            _ = TokenService.shared.importFromClaudeCode(for: account)

            // Also update the email
            Task {
                if let email = await apiService.fetchCurrentProfile() {
                    _ = FileCredentialService.shared.updateAccountEmail(accountId: account.id.uuidString, email: email)
                }
            }
        }

        // Update which account is active in Claude Code
        detectActiveClaudeCodeAccount()
    }

    /// Detect which account is currently logged into Claude Code by matching email
    private func detectActiveClaudeCodeAccount() {
        Task {
            await detectActiveClaudeCodeAccountAsync()
        }
    }

    /// Async version that fetches the profile email to detect active account
    private func detectActiveClaudeCodeAccountAsync() async {
        guard let email = await apiService.fetchCurrentProfile() else {
            activeClaudeCodeAccountId = nil
            return
        }

        // Find the account with matching email
        if let storedAccount = FileCredentialService.shared.getAccountByEmail(email),
           let uuid = UUID(uuidString: storedAccount.id) {
            activeClaudeCodeAccountId = uuid
        } else {
            // No matching account found - user may need to import to an account
            activeClaudeCodeAccountId = nil
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func updateRefreshInterval(_ minutes: Int) {
        refreshInterval = minutes
        startAutoRefresh()
    }

    var lastUpdatedText: String {
        guard let lastUpdated = lastUpdated else {
            return "Never"
        }

        let interval = Date().timeIntervalSince(lastUpdated)

        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes) min ago"
        } else {
            return Self.timeFormatter.string(from: lastUpdated)
        }
    }

    var statusColor: Color {
        guard let usage = usageData?.fiveHour else {
            return .secondary
        }

        let percentage = usage.utilization
        if percentage < 50 {
            return .green
        } else if percentage < 80 {
            return .yellow
        } else {
            return .red
        }
    }

    var hasToken: Bool {
        if let account = selectedAccount {
            return accountManager.getToken(for: account) != nil
        }
        return KeychainService.shared.getEffectiveToken() != nil
    }

    var currentAccountName: String {
        // Use active Claude Code account if available
        if let activeId = activeClaudeCodeAccountId,
           let activeAccount = accountManager.accounts.first(where: { $0.id == activeId }) {
            return activeAccount.name
        }
        return selectedAccount?.name ?? "Unknown"
    }
}
