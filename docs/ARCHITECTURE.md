# Usagebar architecture

Usagebar is a native macOS status-bar application with no project-operated backend and no embedded web runtime for its normal usage flow.

```mermaid
flowchart LR
    subgraph Local["Local Mac"]
        CLI["Provider CLI credentials"]
        Store["Encrypted Usagebar storage"]
        Services["Provider services"]
        VM["UsageViewModel"]
        UI["AppDelegate and status menu"]
        CLI --> Services
        Store --> Services
        Services --> VM
        VM --> UI
    end
    Services --> Claude["Anthropic usage API"]
    Services --> Codex["OpenAI usage API"]
    UI --> Releases["GitHub Releases API"]
```

## Component responsibilities

| Component | Responsibility |
| --- | --- |
| `JustaUsageBarApp` | SwiftUI entry point and settings scene. |
| `AppDelegate` | Creates the `NSStatusItem`, menus, provider images, switching, and release checks. |
| `UsageViewModel` | Usage state, display preferences, credential availability, refresh orchestration, and launch at login. |
| `ClaudeAPIService` | Selects Claude authentication mode and normalizes responses. |
| `ClaudeOAuthService` | Discovers Claude CLI credentials, refreshes OAuth tokens, and fetches usage. |
| `CodexAPIService` | Discovers Codex credentials, resolves the base URL, refreshes OAuth, and normalizes usage. |
| `CredentialStorage` | Encrypts Usagebar-managed Claude browser-session data locally. |

## Runtime data flow

1. `UsageViewModel` discovers available credentials during initialization.
2. With at least one provider, it starts an immediate refresh and a two-minute timer.
3. Claude and Codex refresh concurrently.
4. Services validate responses and normalize payloads.
5. The view model publishes state and posts `UsageDataChanged`.
6. `AppDelegate` redraws the status item and rebuilds the menu.

UI state is main-actor isolated. Network requests use `URLSession` and do not pass through a Usagebar service.

## Credential discovery

Claude priority is: Usagebar's encrypted OAuth mirror, `~/.claude/.credentials.json`, the `Claude Code-credentials` Keychain item through `/usr/bin/security`, direct Keychain lookup, then the Usagebar-managed browser session fallback.

Codex reads `${CODEX_HOME}/auth.json` or `~/.codex/auth.json`. It reads `chatgpt_base_url` from `${CODEX_HOME}/config.toml` when present and otherwise uses `https://chatgpt.com`.

## Network boundaries

| Purpose | Default destination |
| --- | --- |
| Claude OAuth usage | `https://api.anthropic.com/api/oauth/usage` |
| Claude OAuth refresh | `https://platform.claude.com/v1/oauth/token` |
| Claude browser-session usage | `https://claude.ai/api/organizations/{orgId}/usage` |
| Codex usage | `https://chatgpt.com/backend-api/wham/usage` |
| Codex OAuth refresh | `https://auth.openai.com/oauth/token` |
| Update discovery | `https://api.github.com/repos/betoxf/Usagebar/releases/latest` |

A configured Codex base URL changes the Codex usage destination. Provider-private endpoints or payloads can change independently.

## Local persistence

| Data | Storage |
| --- | --- |
| Display preferences | `UserDefaults` through `@AppStorage` |
| Launch at login | `SMAppService.mainApp` |
| Claude browser-session data and OAuth mirror | `~/Library/Application Support/JustaUsageBar/credentials.enc` |
| Provider CLI credentials | Provider-owned files or Keychain items, read in place |

Usagebar-managed credential data uses AES-256-GCM with a key derived from the Mac hardware UUID and an application salt.

The primary interface is AppKit for precise status-item drawing; SwiftUI is used for settings and authentication. The app runs as `LSUIElement`, so it has no normal Dock icon while running, but the application icon remains visible in Finder and installation surfaces.

Provider changes must keep discovery inside services, raw payload parsing provider-specific, published state in `UsageViewModel`, and menu rendering based on normalized models. New storage or network destinations require documentation and security review.
