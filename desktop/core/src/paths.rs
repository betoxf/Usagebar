//! Where each provider keeps its credentials on Windows, Linux, and macOS.

use std::path::PathBuf;

/// The user's home directory, `%USERPROFILE%` on Windows.
pub fn home() -> Option<PathBuf> {
    dirs::home_dir()
}

/// Claude Code's credentials file, `~/.claude/.credentials.json`.
/// `CLAUDE_CONFIG_DIR` overrides `~/.claude`, as in Claude Code.
pub fn claude_credentials() -> Option<PathBuf> {
    let dir = std::env::var_os("CLAUDE_CONFIG_DIR")
        .map(PathBuf::from)
        .or_else(|| home().map(|home| home.join(".claude")))?;
    Some(dir.join(".credentials.json"))
}

/// Codex's home, `${CODEX_HOME}` or `~/.codex`.
pub fn codex_home() -> Option<PathBuf> {
    std::env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .or_else(|| home().map(|home| home.join(".codex")))
}

/// Cursor's VS Code state database: `%APPDATA%\Cursor\User\globalStorage\state.vscdb`
/// on Windows, `~/.config/Cursor/...` on Linux, `~/Library/Application Support/Cursor/...` on macOS.
pub fn cursor_state_db() -> Option<PathBuf> {
    Some(
        dirs::config_dir()?
            .join("Cursor")
            .join("User")
            .join("globalStorage")
            .join("state.vscdb"),
    )
}

/// Grok Bot's account file, used to tell whether Grok Bot shares the Cursor account.
pub fn grok_bot_secrets() -> Option<PathBuf> {
    Some(
        dirs::config_dir()?
            .join("Grok Bot")
            .join("sand-secrets.json"),
    )
}
