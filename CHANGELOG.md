# Changelog

## [1.11.2](https://github.com/betoxf/Usagebar/releases/tag/v1.11.2) — 2026-10-29

- Find Cursor again after Cursor 3.28 started encrypting its sign-in on disk. Usagebar now falls back to the Cursor Agent CLI's sign-in, so the Cursor card and its xAI, Grok, Cursor and Grok Bot marks are back, and Grok Bot in front selects them again.
- Show Grok once: when Grok is on unified billing with Cursor, the Cursor card stands for both instead of a second XAI card with the same usage.
- Show the Claude spark and the Codex logo in the menu bar, the same marks as the panel.

## [1.11.1](https://github.com/betoxf/Usagebar/releases/tag/v1.11.1) — 2026-10-25

- Show the Usagebar icon beside the title of the usage panel.

## [1.11.0](https://github.com/betoxf/Usagebar/releases/tag/v1.11.0) — 2026-10-25

- Open a usage panel from the menu bar instead of a menu: one card per provider with its mark, plan, usage meters and reset times, the same design as Usagebar for Windows. Click a card to show that provider in the menu bar.
- Display, Launch at Login, sign-out and update settings moved to the panel's ⋯ button. An available update shows in the panel's footer.

## [1.10.7](https://github.com/betoxf/Usagebar/releases/tag/v1.10.7) — 2026-10-25

- Show each provider's mark in the menu's section headers, at full contrast instead of dimmed: the Claude spark, the Codex logo, Cursor's four plan marks, and ZCode's Z mark with "Code".

## [1.10.6](https://github.com/betoxf/Usagebar/releases/tag/v1.10.6) — 2026-10-25

- Show ZCode's Z mark followed by "Code" for z.ai in the menu bar, in black or white to match the menu bar, in place of the pink "Z" and "z.ai".

## [1.10.5](https://github.com/betoxf/Usagebar/releases/tag/v1.10.5) — 2026-10-25

- Show Cursor's percentage in its black brand color, white on dark menu bars, when usage reaches 90%. It was teal.

## [1.10.4](https://github.com/betoxf/Usagebar/releases/tag/v1.10.4) — 2026-10-25

- Show the marks of everything Cursor's plan covers (xAI, Grok, Cursor and Grok Bot) above the Cursor percentage in the menu bar, in place of the cube and the "Cursor" name. They are drawn as vectors, so they stay sharp on every display.

## [1.10.3](https://github.com/betoxf/Usagebar/releases/tag/v1.10.3) — 2026-10-15

- Show Cursor's weekly allowance, the figure Cursor and Grok Bot display, with a `W` label and its weekly reset. Plans without one keep the monthly reading.

## [1.10.2](https://github.com/betoxf/Usagebar/releases/tag/v1.10.2) — 2026-10-15

- Show Cursor usage while Grok Bot is in front. Grok Bot is Cursor's agent app and draws on the same subscription; when it is signed in to the same account the menu calls the section "Cursor & Grok Bot".

## [1.10.1](https://github.com/betoxf/Usagebar/releases/tag/v1.10.1) — 2026-10-09

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
