# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Open project in Xcode
open ClaudeUsageWidget/ClaudeUsageWidget.xcodeproj

# Build from command line
cd ClaudeUsageWidget && xcodebuild build -project ClaudeUsageWidget.xcodeproj -scheme ClaudeUsageWidget -configuration Debug

# Build for release (used by CI)
cd ClaudeUsageWidget && xcodebuild clean build -project ClaudeUsageWidget.xcodeproj -scheme ClaudeUsageWidget -configuration Release -derivedDataPath build
```

## Architecture

This is a macOS menu bar app using SwiftUI's `MenuBarExtra` API (macOS 13.0+). The app follows MVVM architecture.

### Data Flow
1. `ClaudeUsageWidgetApp` creates the menu bar extra with `MenuBarView` as content and `MenuBarLabel` as the menu bar icon
2. `UsageViewModel` is the central state manager - it holds all usage data and coordinates API calls
3. Two API services exist:
   - `UsageAPIService` - fetches personal usage via OAuth token from `api.anthropic.com/api/oauth/usage`
   - `AdminAPIService` - fetches team usage via Admin API key

### Multi-Account System
- `AccountManager` (in `Account.swift`) manages multiple Claude accounts
- Each account stores credentials separately in Keychain via `KeychainService`
- `TokenService` handles token retrieval with priority: Keychain stored token → Claude Code credentials → environment variable

### Three Usage Modes (`AppSettings.mode`)
- `.personal` - Shows individual 5-hour and 7-day usage windows
- `.team` - Shows team token consumption dashboard
- `.both` - Toggle between personal and team views

### Key Singletons
- `UsageAPIService.shared`, `AdminAPIService.shared`, `TokenService.shared`, `KeychainService.shared`, `AccountManager.shared`, `AppSettings.shared`

## API Details

Personal usage API requires OAuth token with `anthropic-beta: oauth-2025-04-20` header and `User-Agent: claude-code/2.0.31`.

## Release Process

Releases are automated via `.github/workflows/release.yml`. Pushing to `main` triggers:
1. Build with Xcode
2. Sign with Developer ID certificate
3. Notarize with Apple
4. Create GitHub release with signed zip

Required secrets: `DEVELOPER_ID_CERTIFICATE_BASE64`, `DEVELOPER_ID_CERTIFICATE_PASSWORD`, `KEYCHAIN_PASSWORD`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`
