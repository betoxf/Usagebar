# Usagebar for Windows and Linux

A system tray version of Usagebar. It reads the same provider credentials as the macOS app and shows usage in a tray icon and a flyout panel.

- `core/` (`usagebar-core`): credential discovery and usage fetching for Claude, Codex, and Cursor, ported from the Swift services. Credentials are never logged or written back to provider files.
- `app/` (`usagebar-desktop`): the Tauri 2 tray app. The tray icon is the chosen provider's mark inside a ring that fills with usage; left click opens the flyout, right click opens a menu. Linux trays only open the menu, so it has **Open Usagebar**.
- `ui/`: the flyout (plain HTML, CSS, and JavaScript) and the brand marks as SVG.

## Develop

Needs Rust (stable) and Node for the Tauri CLI. The tray app also runs on macOS, which is handy for UI work.

```bash
cargo test --workspace
cargo run -p usagebar-core --example status   # print real usage, no secrets
cargo run -p usagebar-desktop                 # run the tray app
cd app && npx @tauri-apps/cli@2 build         # installer for this platform
```

`USAGEBAR_TRAY_PREVIEW=/abs/dir cargo test -p usagebar-desktop` saves tray icon previews on dark and light taskbars.

On Linux, install `libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev libxdo-dev libssl-dev` first. GNOME needs the AppIndicator extension to show tray icons.

## Credentials

| Provider | Windows | Linux |
| --- | --- | --- |
| Claude | `%USERPROFILE%\.claude\.credentials.json` | `~/.claude/.credentials.json` |
| Codex | `%USERPROFILE%\.codex\auth.json` (or `CODEX_HOME`) | `~/.codex/auth.json` (or `CODEX_HOME`) |
| Cursor | `%APPDATA%\Cursor\User\globalStorage\state.vscdb` | `~/.config/Cursor/User/globalStorage/state.vscdb` |

Network destinations are the same as the macOS app's, listed in `docs/ARCHITECTURE.md`.
