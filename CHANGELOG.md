# Changelog

## Unreleased

- Read the z.ai Keychain key through the system `security` tool instead of in the app. An update no longer brings up a password dialog for it, and a dialog that is left unanswered no longer holds up the other providers.

## [1.10.0](https://github.com/betoxf/Usagebar/releases/tag/v1.10.0) — 2026-10-08

### Focus following

- Keep the last AI tool's provider on screen when another app comes to the front. The bar no longer jumps to the provider you last clicked, so z.ai appears only after you use ZCode or a z.ai CLI.
- Follow AI CLIs in any terminal: Claude Code, Codex, Cursor Agent, Kimi, and Grok. Claude Code pointed at the z.ai or Kimi gateway shows that provider. No new permission is needed.

### Performance

- Close provider connections after each refresh. Idle HTTP/2 and HTTP/3 connections kept waking the app between refreshes.
- Stop writing cookies and cached responses to disk.
- Refresh enabled providers that are not on screen five times less often, and immediately when they are shown or the menu opens.
- Look for new sign-ins at that slower pace. **Refresh** still checks at once.

## [1.9.0](https://github.com/betoxf/Usagebar/releases/tag/v1.9.0) — 2026-10-02

### Performance

- Move credential discovery and parsing off the UI thread; cache provider availability and skip unchanged credential writes.
- Reuse unchanged status images and build menus when opened.
- Stop login timers and pending credential extraction when the login view closes.
- Poll only enabled providers, retaining an authenticated fallback if all display switches are off.

### Refresh behavior

- Use a two-minute cadence normally and at least five minutes in Low Power Mode. Pause automatic provider rotation in Low Power Mode.
- Suspend usage requests and rotation during display/system sleep; fetch stale readings on wake.
- Back off repeated failures per provider and honor server retry deadlines. Keep the last successful reading after errors.
- Add **Last Updates** to show provider freshness and retry delays.

### Compatibility

- Include ZCode in Follow Active App, selecting z.ai usage when ZCode is active.
- Package both Apple silicon and Intel architectures for macOS 14+.
- Add scheduling, cancellation, timer, menu, and rendering regression checks to CI.

## [1.8.1](https://github.com/betoxf/Usagebar/releases/tag/v1.8.1) — 2026-07-30

- Show `7d` for Codex's weekly window in the open menu, retaining `W` in the compact menu bar.
- Keep duration-driven five-hour support ready when the provider returns that window.
- Update Homebrew checksums to match the published artifact.

## [1.8.0](https://github.com/betoxf/Usagebar/releases/tag/v1.8.0) — 2026-07-20

- Add XAI/Grok Build usage and local credential discovery.
- Restore z.ai credential discovery from the macOS Keychain and configuration files.

See [earlier releases](https://github.com/betoxf/Usagebar/releases) for older changes.
