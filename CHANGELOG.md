# Changelog

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
