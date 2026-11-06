//! Codex usage. Port of the macOS app's Swift service (`CodexAPIService`).
//!
//! Credentials come from `${CODEX_HOME}/auth.json`, re-read on every fetch.
//! Tokens refreshed here stay in memory only; Codex's files are never written.

use chrono::{DateTime, TimeZone, Utc};
use reqwest::{RequestBuilder, Response, StatusCode};
use serde_json::{Map, Value};
use tokio::sync::Mutex;

use crate::http::{network_error, status_error};
use crate::{paths, percent, Provider, ProviderUsage, UsageError, UsageWindow};

const OAUTH_CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
const TOKEN_ENDPOINT: &str = "https://auth.openai.com/oauth/token";
const DEFAULT_BASE_URL: &str = "https://chatgpt.com";
/// Swift refreshes ahead of time once `last_refresh` is older than this.
const PROACTIVE_REFRESH_SECS: i64 = 8 * 86_400;
const WEEK_SECS: i64 = 7 * 24 * 3600;

/// Codex credentials. Deliberately not `Debug`, so tokens can't be printed.
#[derive(Clone)]
struct Credentials {
    access_token: String,
    refresh_token: Option<String>,
    account_id: Option<String>,
    last_refresh: Option<DateTime<Utc>>,
    is_api_key: bool,
}

/// Tokens refreshed by Usagebar, kept only while auth.json still holds the
/// refresh token they were derived from. Once Codex rewrites the file, the
/// file wins again.
struct Mirror {
    source_refresh_token: String,
    credentials: Credentials,
}

#[derive(Default)]
pub struct Codex {
    /// Held for the whole fetch so two refreshes never race on one token.
    mirror: Mutex<Option<Mirror>>,
}

impl Codex {
    pub fn has_credentials(&self) -> bool {
        load_credentials().is_some()
    }

    pub async fn fetch(&self, client: &reqwest::Client) -> Result<ProviderUsage, UsageError> {
        let mut mirror = self.mirror.lock().await;
        let file_creds = load_credentials().ok_or(UsageError::NotSignedIn)?;

        // Use refreshed tokens while auth.json is unchanged since the refresh.
        let mut creds = match mirror.as_ref() {
            Some(m)
                if file_creds.refresh_token.as_deref() == Some(m.source_refresh_token.as_str()) =>
            {
                m.credentials.clone()
            }
            _ => {
                *mirror = None;
                file_creds.clone()
            }
        };

        if !creds.is_api_key && needs_proactive_refresh(&creds, Utc::now()) {
            if let Some(refresh_token) = creds.refresh_token.clone() {
                creds = refresh(client, &refresh_token, creds.account_id.clone()).await?;
                *mirror = mirror_for(&file_creds, &creds);
            }
        }

        let url = usage_url(&base_url(read_config().as_deref()));
        let response = usage_request(client, &url, &creds)
            .send()
            .await
            .map_err(network_error)?;

        match response.status() {
            StatusCode::OK => parse_usage_response(response).await,
            StatusCode::TOO_MANY_REQUESTS => Err(status_error(&response)),
            StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => {
                let refresh_token = match (&creds.refresh_token, creds.is_api_key) {
                    (Some(token), false) => token.clone(),
                    _ => {
                        *mirror = None;
                        return Err(UsageError::Unauthorized);
                    }
                };
                // As in Swift: anything but a rate limit during the retry
                // counts as an expired sign-in.
                match retry_after_refresh(client, &url, &refresh_token, &creds).await {
                    Ok((usage, refreshed)) => {
                        *mirror = mirror_for(&file_creds, &refreshed);
                        Ok(usage)
                    }
                    Err(error @ UsageError::RateLimited { .. }) => Err(error),
                    Err(_) => {
                        *mirror = None;
                        Err(UsageError::Unauthorized)
                    }
                }
            }
            _ => Err(status_error(&response)),
        }
    }
}

async fn retry_after_refresh(
    client: &reqwest::Client,
    url: &str,
    refresh_token: &str,
    creds: &Credentials,
) -> Result<(ProviderUsage, Credentials), UsageError> {
    let refreshed = refresh(client, refresh_token, creds.account_id.clone()).await?;
    let response = usage_request(client, url, &refreshed)
        .send()
        .await
        .map_err(network_error)?;
    match response.status() {
        StatusCode::OK => Ok((parse_usage_response(response).await?, refreshed)),
        StatusCode::TOO_MANY_REQUESTS => Err(status_error(&response)),
        _ => Err(UsageError::Unauthorized),
    }
}

fn mirror_for(file_creds: &Credentials, refreshed: &Credentials) -> Option<Mirror> {
    file_creds
        .refresh_token
        .clone()
        .map(|source_refresh_token| Mirror {
            source_refresh_token,
            credentials: refreshed.clone(),
        })
}

fn usage_request(client: &reqwest::Client, url: &str, creds: &Credentials) -> RequestBuilder {
    let request = client.get(url).bearer_auth(&creds.access_token);
    match &creds.account_id {
        Some(account_id) => request.header("ChatGPT-Account-Id", account_id),
        None => request,
    }
}

async fn parse_usage_response(response: Response) -> Result<ProviderUsage, UsageError> {
    let body = response.bytes().await.map_err(network_error)?;
    Ok(provider_usage(&parse_usage(&body)?))
}

async fn refresh(
    client: &reqwest::Client,
    refresh_token: &str,
    account_id: Option<String>,
) -> Result<Credentials, UsageError> {
    let body = serde_json::json!({
        "client_id": OAUTH_CLIENT_ID,
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "scope": "openid profile email",
    });
    let response = client
        .post(TOKEN_ENDPOINT)
        .json(&body)
        .send()
        .await
        .map_err(network_error)?;
    match response.status() {
        StatusCode::OK => {}
        StatusCode::TOO_MANY_REQUESTS => return Err(status_error(&response)),
        _ => return Err(UsageError::Unauthorized),
    }
    let body = response.bytes().await.map_err(network_error)?;
    parse_refresh(&body, refresh_token, account_id, Utc::now())
}

fn parse_refresh(
    body: &[u8],
    old_refresh_token: &str,
    account_id: Option<String>,
    now: DateTime<Utc>,
) -> Result<Credentials, UsageError> {
    let invalid = || UsageError::Parse("invalid refresh response".into());
    let json: Value = serde_json::from_slice(body).map_err(|_| invalid())?;
    let access_token = json
        .get("access_token")
        .and_then(Value::as_str)
        .ok_or_else(invalid)?;
    Ok(Credentials {
        access_token: access_token.to_owned(),
        refresh_token: Some(
            json.get("refresh_token")
                .and_then(Value::as_str)
                .unwrap_or(old_refresh_token)
                .to_owned(),
        ),
        account_id,
        last_refresh: Some(now),
        is_api_key: false,
    })
}

fn needs_proactive_refresh(creds: &Credentials, now: DateTime<Utc>) -> bool {
    creds.refresh_token.is_some()
        && creds
            .last_refresh
            .is_some_and(|last| (now - last).num_seconds() > PROACTIVE_REFRESH_SECS)
}

// MARK: - Credential discovery

fn load_credentials() -> Option<Credentials> {
    let path = paths::codex_home()?.join("auth.json");
    parse_auth(&std::fs::read(path).ok()?)
}

fn parse_auth(data: &[u8]) -> Option<Credentials> {
    let json: Map<String, Value> = serde_json::from_slice(data).ok()?;

    if let Some(api_key) = json.get("OPENAI_API_KEY").and_then(Value::as_str) {
        return Some(Credentials {
            access_token: api_key.to_owned(),
            refresh_token: None,
            account_id: None,
            last_refresh: None,
            is_api_key: true,
        });
    }

    let tokens = json.get("tokens")?.as_object()?;
    let string = |key: &str| tokens.get(key).and_then(Value::as_str).map(str::to_owned);
    Some(Credentials {
        access_token: string("access_token")?,
        refresh_token: string("refresh_token"),
        account_id: string("account_id"),
        last_refresh: json
            .get("last_refresh")
            .and_then(Value::as_str)
            .and_then(parse_last_refresh),
        is_api_key: false,
    })
}

/// Matches Swift's default `ISO8601DateFormatter`, which rejects fractional
/// seconds. Codex writes `last_refresh` with them, so on macOS the proactive
/// refresh effectively never runs and the CLI's refresh token isn't rotated
/// behind its back; this keeps that behavior.
fn parse_last_refresh(value: &str) -> Option<DateTime<Utc>> {
    if value.contains('.') {
        return None;
    }
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|date| date.with_timezone(&Utc))
}

fn read_config() -> Option<String> {
    std::fs::read_to_string(paths::codex_home()?.join("config.toml")).ok()
}

/// `chatgpt_base_url` from config.toml, otherwise `https://chatgpt.com`.
fn base_url(config: Option<&str>) -> String {
    config
        .and_then(|content| content.parse::<toml::Table>().ok())
        .and_then(|table| table.get("chatgpt_base_url")?.as_str().map(str::to_owned))
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| DEFAULT_BASE_URL.to_owned())
}

fn usage_url(base: &str) -> String {
    let base = base.trim_end_matches('/');
    if base.contains("chatgpt.com") {
        // Codex's own default base already ends in /backend-api.
        if base.ends_with("/backend-api") {
            format!("{base}/wham/usage")
        } else {
            format!("{base}/backend-api/wham/usage")
        }
    } else {
        format!("{base}/api/codex/usage")
    }
}

// MARK: - Usage payload

/// Swift's `CodexUsageData`, limited to what the menu shows.
#[derive(Debug, PartialEq)]
struct CodexUsage {
    plan_type: String,
    primary_used_percent: i64,
    primary_reset_at: Option<DateTime<Utc>>,
    primary_window_seconds: i64,
    secondary_used_percent: i64,
    secondary_reset_at: Option<DateTime<Utc>>,
}

impl Default for CodexUsage {
    fn default() -> Self {
        Self {
            plan_type: "unknown".into(),
            primary_used_percent: 0,
            primary_reset_at: None,
            primary_window_seconds: 18_000,
            secondary_used_percent: 0,
            secondary_reset_at: None,
        }
    }
}

impl CodexUsage {
    fn primary_is_weekly(&self) -> bool {
        self.primary_window_seconds >= WEEK_SECS
    }
}

fn parse_usage(body: &[u8]) -> Result<CodexUsage, UsageError> {
    let json: Map<String, Value> =
        serde_json::from_slice(body).map_err(|_| UsageError::Parse("invalid JSON".into()))?;

    let mut usage = CodexUsage::default();
    if let Some(plan) = json.get("plan_type").and_then(Value::as_str) {
        usage.plan_type = plan.to_owned();
    }

    let rate_limit = json.get("rate_limit").and_then(Value::as_object);
    if let Some(primary) = rate_limit
        .and_then(|r| r.get("primary_window"))
        .and_then(Value::as_object)
    {
        if let Some(pct) = used_percent(primary) {
            usage.primary_used_percent = pct;
        }
        usage.primary_reset_at = reset_at(primary);
        if let Some(seconds) = primary.get("limit_window_seconds").and_then(integer) {
            usage.primary_window_seconds = seconds;
        }
    }
    if let Some(secondary) = rate_limit
        .and_then(|r| r.get("secondary_window"))
        .and_then(Value::as_object)
    {
        if let Some(pct) = used_percent(secondary) {
            usage.secondary_used_percent = pct;
        }
        usage.secondary_reset_at = reset_at(secondary);
    }
    Ok(usage)
}

/// Swift's `Int(pct)`: truncates toward zero.
fn used_percent(window: &Map<String, Value>) -> Option<i64> {
    let pct = window.get("used_percent")?.as_f64()?;
    pct.is_finite().then(|| pct.trunc() as i64)
}

fn reset_at(window: &Map<String, Value>) -> Option<DateTime<Utc>> {
    let seconds = window.get("reset_at")?.as_f64()?;
    if !seconds.is_finite() {
        return None;
    }
    Utc.timestamp_opt(seconds.trunc() as i64, (seconds.fract() * 1e9) as u32)
        .single()
}

/// An integral JSON number, as Swift's `as? Int` accepts.
fn integer(value: &Value) -> Option<i64> {
    value.as_i64().or_else(|| {
        let float = value.as_f64()?;
        (float.fract() == 0.0 && float.abs() < i64::MAX as f64).then_some(float as i64)
    })
}

/// The rows the macOS menu shows: primary ("7d" when weekly, else "<hours>h"),
/// then a "7d" secondary unless the primary is already weekly.
fn provider_usage(usage: &CodexUsage) -> ProviderUsage {
    let primary_label = if usage.primary_is_weekly() {
        "7d".to_owned()
    } else {
        format!("{}h", usage.primary_window_seconds / 3600)
    };
    let mut windows = vec![UsageWindow {
        label: primary_label,
        used_percent: percent(usage.primary_used_percent as f64),
        resets_at: usage.primary_reset_at,
    }];
    if !usage.primary_is_weekly()
        && (usage.secondary_used_percent > 0 || usage.secondary_reset_at.is_some())
    {
        windows.push(UsageWindow {
            label: "7d".into(),
            used_percent: percent(usage.secondary_used_percent as f64),
            resets_at: usage.secondary_reset_at,
        });
    }
    ProviderUsage {
        provider: Provider::Codex,
        detail: (usage.plan_type != "unknown").then(|| capitalized(&usage.plan_type)),
        windows,
    }
}

/// Foundation's `capitalized`: each whitespace-separated word gets an
/// uppercase first letter and lowercase rest.
fn capitalized(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut word_start = true;
    for ch in value.chars() {
        if ch.is_whitespace() {
            word_start = true;
            out.push(ch);
        } else if word_start {
            out.extend(ch.to_uppercase());
            word_start = false;
        } else {
            out.extend(ch.to_lowercase());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_oauth_auth() {
        let json = br#"{
            "OPENAI_API_KEY": null,
            "auth_mode": "chatgpt",
            "last_refresh": "2026-01-02T03:04:05Z",
            "tokens": {
                "access_token": "fake-access",
                "refresh_token": "fake-refresh",
                "account_id": "fake-account",
                "id_token": "fake-id"
            }
        }"#;
        let creds = parse_auth(json).expect("oauth credentials");
        assert!(!creds.is_api_key);
        assert_eq!(creds.access_token, "fake-access");
        assert_eq!(creds.refresh_token.as_deref(), Some("fake-refresh"));
        assert_eq!(creds.account_id.as_deref(), Some("fake-account"));
        assert_eq!(
            creds.last_refresh,
            Utc.with_ymd_and_hms(2026, 1, 2, 3, 4, 5).single()
        );
    }

    #[test]
    fn fractional_last_refresh_is_ignored_like_swift() {
        let json = br#"{"last_refresh": "2026-01-02T03:04:05.123456Z",
            "tokens": {"access_token": "fake-access", "refresh_token": "fake-refresh"}}"#;
        let creds = parse_auth(json).expect("oauth credentials");
        assert_eq!(creds.last_refresh, None);
        assert_eq!(creds.account_id, None);
    }

    #[test]
    fn parses_api_key_auth() {
        let json = br#"{"OPENAI_API_KEY": "sk-fake", "tokens": {"access_token": "fake-access"}}"#;
        let creds = parse_auth(json).expect("api key credentials");
        assert!(creds.is_api_key);
        assert_eq!(creds.access_token, "sk-fake");
        assert_eq!(creds.refresh_token, None);
    }

    #[test]
    fn rejects_auth_without_tokens() {
        assert!(parse_auth(br#"{"OPENAI_API_KEY": null}"#).is_none());
        assert!(parse_auth(br#"{"tokens": {"refresh_token": "fake-refresh"}}"#).is_none());
        assert!(parse_auth(b"not json").is_none());
    }

    #[test]
    fn proactive_refresh_after_eight_days() {
        let now = Utc.with_ymd_and_hms(2026, 1, 20, 0, 0, 0).unwrap();
        let mut creds = parse_auth(
            br#"{"last_refresh": "2026-01-10T00:00:00Z",
                "tokens": {"access_token": "fake-access", "refresh_token": "fake-refresh"}}"#,
        )
        .unwrap();
        assert!(needs_proactive_refresh(&creds, now));
        creds.last_refresh = Some(now - chrono::Duration::days(7));
        assert!(!needs_proactive_refresh(&creds, now));
        creds.last_refresh = None;
        assert!(!needs_proactive_refresh(&creds, now));
    }

    #[test]
    fn parses_refresh_response() {
        let now = Utc::now();
        let creds = parse_refresh(
            br#"{"access_token": "fake-new"}"#,
            "fake-old",
            Some("fake-account".into()),
            now,
        )
        .unwrap();
        assert_eq!(creds.access_token, "fake-new");
        assert_eq!(creds.refresh_token.as_deref(), Some("fake-old"));
        assert_eq!(creds.account_id.as_deref(), Some("fake-account"));
        assert_eq!(creds.last_refresh, Some(now));

        let rotated = parse_refresh(
            br#"{"access_token": "fake-new", "refresh_token": "fake-rotated"}"#,
            "fake-old",
            None,
            now,
        )
        .unwrap();
        assert_eq!(rotated.refresh_token.as_deref(), Some("fake-rotated"));

        let error = parse_refresh(br#"{"error": "x"}"#, "fake-old", None, now).err();
        assert_eq!(
            error,
            Some(UsageError::Parse("invalid refresh response".into()))
        );
    }

    #[test]
    fn resolves_base_url_from_config() {
        assert_eq!(base_url(None), "https://chatgpt.com");
        assert_eq!(base_url(Some("model = \"gpt-5\"\n")), "https://chatgpt.com");
        assert_eq!(
            base_url(Some("chatgpt_base_url = \"\"\n")),
            "https://chatgpt.com"
        );
        assert_eq!(base_url(Some("not = = toml")), "https://chatgpt.com");
        assert_eq!(
            base_url(Some("model = \"x\"\nchatgpt_base_url = 'https://proxy.example.test'\n[profiles.a]\nmodel = \"y\"\n")),
            "https://proxy.example.test"
        );
        // Only the top-level key counts.
        assert_eq!(
            base_url(Some(
                "[profiles.a]\nchatgpt_base_url = \"https://proxy.example.test\"\n"
            )),
            "https://chatgpt.com"
        );
    }

    #[test]
    fn builds_usage_url() {
        assert_eq!(
            usage_url("https://chatgpt.com"),
            "https://chatgpt.com/backend-api/wham/usage"
        );
        assert_eq!(
            usage_url("https://chatgpt.com/"),
            "https://chatgpt.com/backend-api/wham/usage"
        );
        assert_eq!(
            usage_url("https://chatgpt.com/backend-api/"),
            "https://chatgpt.com/backend-api/wham/usage"
        );
        assert_eq!(
            usage_url("https://proxy.example.test"),
            "https://proxy.example.test/api/codex/usage"
        );
    }

    #[test]
    fn parses_five_hour_and_weekly_usage() {
        let body = br#"{
            "plan_type": "prolite",
            "rate_limit": {
                "allowed": true,
                "primary_window": {"used_percent": 42.9, "limit_window_seconds": 18000, "reset_at": 1767225600},
                "secondary_window": {"used_percent": 17, "limit_window_seconds": 604800, "reset_at": 1767830400}
            },
            "credits": {"has_credits": false, "unlimited": false, "balance": null}
        }"#;
        let usage = provider_usage(&parse_usage(body).unwrap());
        assert_eq!(usage.provider, Provider::Codex);
        assert_eq!(usage.detail.as_deref(), Some("Prolite"));
        assert_eq!(usage.windows.len(), 2);
        assert_eq!(usage.windows[0].label, "5h");
        assert_eq!(usage.windows[0].used_percent, 42);
        assert_eq!(
            usage.windows[0].resets_at,
            Utc.timestamp_opt(1_767_225_600, 0).single()
        );
        assert_eq!(usage.windows[1].label, "7d");
        assert_eq!(usage.windows[1].used_percent, 17);
        assert_eq!(
            usage.windows[1].resets_at,
            Utc.timestamp_opt(1_767_830_400, 0).single()
        );
    }

    #[test]
    fn weekly_primary_hides_secondary() {
        let body = br#"{
            "plan_type": "plus",
            "rate_limit": {
                "primary_window": {"used_percent": 17.4, "limit_window_seconds": 604800, "reset_at": 1767830400},
                "secondary_window": {"used_percent": 17.4, "limit_window_seconds": 604800, "reset_at": 1767830400}
            }
        }"#;
        let usage = provider_usage(&parse_usage(body).unwrap());
        assert_eq!(usage.detail.as_deref(), Some("Plus"));
        assert_eq!(usage.windows.len(), 1);
        assert_eq!(usage.windows[0].label, "7d");
        assert_eq!(usage.windows[0].used_percent, 17);
    }

    #[test]
    fn missing_fields_use_swift_defaults() {
        let usage =
            provider_usage(&parse_usage(br#"{"plan_type": null, "rate_limit": null}"#).unwrap());
        assert_eq!(usage.detail, None);
        assert_eq!(usage.windows.len(), 1);
        assert_eq!(usage.windows[0].label, "5h");
        assert_eq!(usage.windows[0].used_percent, 0);
        assert_eq!(usage.windows[0].resets_at, None);

        // An unused secondary with no reset time is not shown.
        let body = br#"{"plan_type": "unknown", "rate_limit": {
            "primary_window": {"used_percent": 5, "limit_window_seconds": 18000.0},
            "secondary_window": {"used_percent": 0}}}"#;
        let usage = provider_usage(&parse_usage(body).unwrap());
        assert_eq!(usage.detail, None);
        assert_eq!(usage.windows.len(), 1);
        assert_eq!(usage.windows[0].label, "5h");
    }

    #[test]
    fn invalid_usage_json_is_a_parse_error_without_body() {
        let error = parse_usage(b"<html>fake-secret</html>").unwrap_err();
        assert_eq!(error, UsageError::Parse("invalid JSON".into()));
        assert!(!error.to_string().contains("fake-secret"));
    }

    #[test]
    fn capitalizes_like_foundation() {
        assert_eq!(capitalized("prolite"), "Prolite");
        assert_eq!(capitalized("PRO"), "Pro");
        assert_eq!(capitalized("team plan"), "Team Plan");
        assert_eq!(capitalized(""), "");
    }
}
