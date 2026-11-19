//! Usagebar's provider layer for Windows and Linux.
//!
//! Each provider module discovers the credentials its CLI or app already
//! stores on this machine, fetches usage from the provider's API, and returns
//! a normalized [`ProviderUsage`]. It mirrors the macOS app's Swift services:
//! discovery stays inside the provider, payload parsing is provider-specific,
//! and callers only see normalized models.
//!
//! Credentials are never logged, printed, or included in errors.

pub mod claude;
pub mod codex;
pub mod cursor;
mod http;
pub mod paths;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Claude,
    Codex,
    Cursor,
}

impl Provider {
    /// Display order, matching the macOS app.
    pub const ALL: [Provider; 3] = [Provider::Claude, Provider::Codex, Provider::Cursor];

    pub fn name(self) -> &'static str {
        match self {
            Provider::Claude => "Claude",
            Provider::Codex => "Codex",
            Provider::Cursor => "Cursor",
        }
    }
}

/// One usage limit, e.g. Claude's five-hour window.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct UsageWindow {
    /// Short label shown before the number: "5h", "7d", "W", "M", "Fable".
    pub label: String,
    /// Percent of the limit used, clamped to 0...100.
    pub used_percent: u8,
    pub resets_at: Option<DateTime<Utc>>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct ProviderUsage {
    pub provider: Provider,
    /// Plan or sign-in detail shown beside the provider name, e.g. "Prolite".
    pub detail: Option<String>,
    /// Limits in display order; the first is the headline number.
    pub windows: Vec<UsageWindow>,
}

#[derive(Clone, Debug, PartialEq, thiserror::Error, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum UsageError {
    #[error("Not signed in")]
    NotSignedIn,
    #[error("Sign-in expired")]
    Unauthorized,
    #[error("Rate limited")]
    RateLimited { retry_after_secs: Option<u64> },
    #[error("Network error: {0}")]
    Network(String),
    #[error("Unexpected response: {0}")]
    Parse(String),
}

/// Clamps a percentage to 0...100 and rounds it. Providers whose macOS menu
/// truncates (`Int(value)`) pass an already truncated value.
pub(crate) fn percent(value: f64) -> u8 {
    if value.is_nan() {
        return 0;
    }
    value.clamp(0.0, 100.0).round() as u8
}

/// Usagebar's providers with their shared HTTP client and in-memory token
/// mirrors. Create one and keep it for the life of the app.
pub struct Usagebar {
    client: reqwest::Client,
    claude: claude::Claude,
    codex: codex::Codex,
    cursor: cursor::Cursor,
}

impl Default for Usagebar {
    fn default() -> Self {
        Self::new()
    }
}

impl Usagebar {
    pub fn new() -> Self {
        Self {
            client: http::client(),
            claude: claude::Claude::default(),
            codex: codex::Codex::default(),
            cursor: cursor::Cursor::default(),
        }
    }

    /// Whether this machine has credentials for `provider`. Reads local files only.
    pub fn has_credentials(&self, provider: Provider) -> bool {
        match provider {
            Provider::Claude => self.claude.has_credentials(),
            Provider::Codex => self.codex.has_credentials(),
            Provider::Cursor => self.cursor.has_credentials(),
        }
    }

    pub async fn fetch(&self, provider: Provider) -> Result<ProviderUsage, UsageError> {
        match provider {
            Provider::Claude => self.claude.fetch(&self.client).await,
            Provider::Codex => self.codex.fetch(&self.client).await,
            Provider::Cursor => self.cursor.fetch(&self.client).await,
        }
    }
}
