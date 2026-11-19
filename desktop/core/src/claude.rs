//! Claude usage through Claude Code's OAuth credentials. Port of the macOS
//! app's `ClaudeOAuthService` (the OAuth path only: the browser-session
//! fallback and Usagebar's encrypted on-disk mirror are not ported).
//!
//! Claude Code owns and rotates its tokens. Usagebar only reads them, keeps a
//! token it refreshed itself in memory, and never writes Claude Code's
//! credentials file or Keychain item.

use std::fmt;
use std::sync::{Mutex, MutexGuard};
#[cfg(target_os = "macos")]
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use reqwest::StatusCode;
use serde_json::{Map, Value};

use crate::http::{network_error, status_error};
use crate::{paths, percent, Provider, ProviderUsage, UsageError, UsageWindow};

const OAUTH_CLIENT_ID: &str = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const TOKEN_ENDPOINT: &str = "https://platform.claude.com/v1/oauth/token";
const USAGE_ENDPOINT: &str = "https://api.anthropic.com/api/oauth/usage";
const OAUTH_USER_AGENT: &str = "claude-code/2.1.0";
const OAUTH_BETA: &str = "oauth-2025-04-20";
/// Treat a token as expired this long before it actually expires, so a menu
/// refresh never races the expiry.
const EXPIRY_SKEW_SECS: i64 = 60;

#[cfg(target_os = "macos")]
const KEYCHAIN_SERVICE: &str = "Claude Code-credentials";
#[cfg(target_os = "macos")]
const SECURITY_BINARY: &str = "/usr/bin/security";
/// How long `security` may take; a password dialog is left to the user.
#[cfg(target_os = "macos")]
const SECURITY_TIMEOUT: Duration = Duration::from_millis(1500);
/// How often a missing or expired token sends us back to the Keychain.
#[cfg(target_os = "macos")]
const KEYCHAIN_RECHECK: Duration = Duration::from_secs(30);

#[derive(Clone, PartialEq)]
struct Credentials {
    access_token: String,
    refresh_token: Option<String>,
    expires_at: Option<DateTime<Utc>>,
    scopes: Vec<String>,
}

/// Never prints tokens.
impl fmt::Debug for Credentials {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Credentials")
            .field("access_token", &"<redacted>")
            .field(
                "refresh_token",
                &self.refresh_token.as_ref().map(|_| "<redacted>"),
            )
            .field("expires_at", &self.expires_at)
            .field("scopes", &self.scopes)
            .finish()
    }
}

impl Credentials {
    fn is_expired(&self, now: DateTime<Utc>) -> bool {
        self.expires_at.is_some_and(|expires_at| {
            expires_at <= now + chrono::Duration::seconds(EXPIRY_SKEW_SECS)
        })
    }
}

#[derive(Default)]
struct State {
    /// The freshest token seen, including one Usagebar refreshed itself.
    mirror: Option<Credentials>,
    #[cfg(target_os = "macos")]
    keychain_checked_at: Option<Instant>,
}

#[derive(Default)]
pub struct Claude {
    state: Mutex<State>,
    /// Serializes fetches so two refreshes never rotate the same refresh token.
    fetch_lock: tokio::sync::Mutex<()>,
}

impl Claude {
    pub fn has_credentials(&self) -> bool {
        self.load_credentials(false).is_some()
    }

    pub async fn fetch(&self, client: &reqwest::Client) -> Result<ProviderUsage, UsageError> {
        let _serialized = self.fetch_lock.lock().await;
        let windows = self.fetch_windows(client).await?;
        Ok(ProviderUsage {
            provider: Provider::Claude,
            detail: Some("via OAuth".into()),
            windows,
        })
    }

    async fn fetch_windows(
        &self,
        client: &reqwest::Client,
    ) -> Result<Vec<UsageWindow>, UsageError> {
        let creds = self.usable_credentials(client).await?;

        let response = send_usage(client, &creds.access_token).await?;
        match response.status() {
            StatusCode::OK => parse_usage(&response.bytes().await.map_err(network_error)?),
            StatusCode::TOO_MANY_REQUESTS => Err(status_error(&response)),
            status @ (StatusCode::BAD_REQUEST
            | StatusCode::UNAUTHORIZED
            | StatusCode::FORBIDDEN) => {
                let Some(refresh_token) = creds.refresh_token.as_deref() else {
                    let body = response.bytes().await.unwrap_or_default();
                    self.clear_mirror();
                    return if status == StatusCode::BAD_REQUEST && !is_expired_oauth_response(&body)
                    {
                        Err(UsageError::Network("HTTP 400".into()))
                    } else {
                        Err(UsageError::Unauthorized)
                    };
                };

                // Refresh once and retry.
                let refreshed = match refresh(client, refresh_token, &creds.scopes).await {
                    Ok(refreshed) => refreshed,
                    Err(error @ (UsageError::RateLimited { .. } | UsageError::Network(_))) => {
                        return Err(error)
                    }
                    Err(_) => {
                        self.clear_mirror();
                        return Err(UsageError::Unauthorized);
                    }
                };
                self.remember(refreshed.clone());

                let retry = send_usage(client, &refreshed.access_token).await?;
                match retry.status() {
                    StatusCode::OK => parse_usage(&retry.bytes().await.map_err(network_error)?),
                    StatusCode::TOO_MANY_REQUESTS => Err(status_error(&retry)),
                    _ => {
                        self.clear_mirror();
                        Err(UsageError::Unauthorized)
                    }
                }
            }
            _ => Err(status_error(&response)),
        }
    }

    /// An unexpired token, refreshing an expired one when Claude Code has not
    /// already supplied a newer token.
    async fn usable_credentials(
        &self,
        client: &reqwest::Client,
    ) -> Result<Credentials, UsageError> {
        let mut allow_rediscovery = true;
        loop {
            let creds = self
                .load_credentials(false)
                .ok_or(UsageError::NotSignedIn)?;
            if !creds.is_expired(Utc::now()) {
                return Ok(creds);
            }

            // Rotating the refresh token ourselves invalidates Claude Code's
            // copy, so first look again for a token Claude Code refreshed.
            let creds = match self.load_credentials(true) {
                Some(reloaded) if !reloaded.is_expired(Utc::now()) => return Ok(reloaded),
                Some(reloaded) => reloaded,
                None => creds,
            };

            let Some(refresh_token) = creds.refresh_token.as_deref() else {
                self.clear_mirror();
                return Err(UsageError::Unauthorized);
            };

            match refresh(client, refresh_token, &creds.scopes).await {
                Ok(refreshed) => {
                    self.remember(refreshed.clone());
                    return Ok(refreshed);
                }
                // A throttle or a dead network says nothing about the token: keep it.
                Err(error @ (UsageError::RateLimited { .. } | UsageError::Network(_))) => {
                    return Err(error)
                }
                Err(_) => {
                    // The mirror can hold a dead refresh token while Claude
                    // Code's file or Keychain has a fresh one. Drop it and
                    // rediscover once instead of staying signed out.
                    self.clear_mirror();
                    if allow_rediscovery {
                        allow_rediscovery = false;
                        continue;
                    }
                    return Err(UsageError::Unauthorized);
                }
            }
        }
    }

    /// The freshest credentials across the mirror, the credentials file and,
    /// on macOS, the Keychain. The Keychain is consulted only when nothing
    /// prompt-free holds an unexpired token.
    fn load_credentials(&self, force: bool) -> Option<Credentials> {
        let mut candidates: Vec<Credentials> = Vec::new();
        candidates.extend(self.state().mirror.clone());
        // Re-read every time so a token Claude Code refreshed is picked up.
        candidates.extend(read_credentials_file());

        if let Some(best) = freshest(&candidates) {
            if !best.is_expired(Utc::now()) {
                let best = best.clone();
                self.remember(best.clone());
                return Some(best);
            }
        }

        #[cfg(target_os = "macos")]
        if self.should_check_keychain(force) {
            candidates.extend(keychain::read(KEYCHAIN_SERVICE));
        }
        #[cfg(not(target_os = "macos"))]
        let _ = force;

        let best = freshest(&candidates)?.clone();
        self.remember(best.clone());
        Some(best)
    }

    fn state(&self) -> MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn remember(&self, creds: Credentials) {
        self.state().mirror = Some(creds);
    }

    fn clear_mirror(&self) {
        let mut state = self.state();
        state.mirror = None;
        #[cfg(target_os = "macos")]
        {
            state.keychain_checked_at = None;
        }
    }

    #[cfg(target_os = "macos")]
    fn should_check_keychain(&self, force: bool) -> bool {
        let mut state = self.state();
        let due = force
            || state
                .keychain_checked_at
                .is_none_or(|checked| checked.elapsed() >= KEYCHAIN_RECHECK);
        if due {
            state.keychain_checked_at = Some(Instant::now());
        }
        due
    }
}

/// Latest expiry wins, a dated token beats an undated one, and the earlier
/// source wins a tie.
fn freshest(candidates: &[Credentials]) -> Option<&Credentials> {
    candidates
        .iter()
        .fold(None, |best: Option<&Credentials>, candidate| match best {
            Some(best) if best.expires_at >= candidate.expires_at => Some(best),
            _ => Some(candidate),
        })
}

fn read_credentials_file() -> Option<Credentials> {
    let data = std::fs::read(paths::claude_credentials()?).ok()?;
    parse_credentials_json(&data)
}

/// Parses the `{ "claudeAiOauth": { ... } }` shape shared by the credentials
/// file and the Keychain item.
fn parse_credentials_json(data: &[u8]) -> Option<Credentials> {
    let json: Value = serde_json::from_slice(data).ok()?;
    let oauth = json.get("claudeAiOauth")?.as_object()?;
    let access_token = oauth.get("accessToken")?.as_str()?.to_owned();
    let refresh_token = oauth
        .get("refreshToken")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let expires_at = oauth
        .get("expiresAt")
        .and_then(Value::as_f64)
        .and_then(|millis| DateTime::from_timestamp_millis(millis as i64));
    let scopes = oauth
        .get("scopes")
        .and_then(Value::as_array)
        .map(|scopes| {
            scopes
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default();
    Some(Credentials {
        access_token,
        refresh_token,
        expires_at,
        scopes,
    })
}

async fn send_usage(
    client: &reqwest::Client,
    access_token: &str,
) -> Result<reqwest::Response, UsageError> {
    client
        .get(USAGE_ENDPOINT)
        .bearer_auth(access_token)
        .header(reqwest::header::ACCEPT, "application/json")
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .header("anthropic-beta", OAUTH_BETA)
        .header(reqwest::header::USER_AGENT, OAUTH_USER_AGENT)
        .send()
        .await
        .map_err(network_error)
}

async fn refresh(
    client: &reqwest::Client,
    refresh_token: &str,
    scopes: &[String],
) -> Result<Credentials, UsageError> {
    let response = client
        .post(TOKEN_ENDPOINT)
        .form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token),
            ("client_id", OAUTH_CLIENT_ID),
        ])
        .send()
        .await
        .map_err(network_error)?;
    match response.status() {
        StatusCode::OK => {}
        StatusCode::TOO_MANY_REQUESTS => return Err(status_error(&response)),
        _ => return Err(UsageError::Unauthorized),
    }
    let body = response.bytes().await.map_err(network_error)?;
    parse_refresh_response(&body, refresh_token, scopes, Utc::now())
}

/// A refresh keeps the old refresh token when the response omits a new one.
fn parse_refresh_response(
    data: &[u8],
    previous_refresh_token: &str,
    scopes: &[String],
    now: DateTime<Utc>,
) -> Result<Credentials, UsageError> {
    let invalid = || UsageError::Parse("invalid refresh response".into());
    let json: Value = serde_json::from_slice(data).map_err(|_| invalid())?;
    let access_token = json
        .get("access_token")
        .and_then(Value::as_str)
        .ok_or_else(invalid)?;
    let refresh_token = json
        .get("refresh_token")
        .and_then(Value::as_str)
        .unwrap_or(previous_refresh_token);
    let expires_at = json
        .get("expires_in")
        .and_then(Value::as_f64)
        .filter(|secs| secs.is_finite())
        .and_then(|secs| chrono::Duration::try_milliseconds((secs * 1000.0) as i64))
        .and_then(|lifetime| now.checked_add_signed(lifetime));
    Ok(Credentials {
        access_token: access_token.to_owned(),
        refresh_token: Some(refresh_token.to_owned()),
        expires_at,
        scopes: scopes.to_vec(),
    })
}

fn is_expired_oauth_response(body: &[u8]) -> bool {
    let body = String::from_utf8_lossy(body).to_lowercase();
    body.contains("oauth token has expired")
        || body.contains("\"authentication_error\"")
        || body.contains("invalid_grant")
}

/// Windows in the macOS menu's order: 5h, 7d, then Fable when present.
/// Accounts without a 5h limit report no 5h number and get no 5h window. A
/// null `resets_at` doesn't mean that: an unused 5h window has one too.
fn parse_usage(data: &[u8]) -> Result<Vec<UsageWindow>, UsageError> {
    let json: Value =
        serde_json::from_slice(data).map_err(|_| UsageError::Parse("invalid JSON".into()))?;
    let json = json
        .as_object()
        .ok_or_else(|| UsageError::Parse("invalid JSON".into()))?;

    let mut windows = Vec::with_capacity(3);
    for (key, label) in [("five_hour", "5h"), ("seven_day", "7d")] {
        let window = json.get(key).and_then(Value::as_object);
        let used = window
            .and_then(|w| w.get("utilization"))
            .and_then(Value::as_f64);
        if used.is_none() && key == "five_hour" {
            continue;
        }
        let resets_at = window
            .and_then(|w| w.get("resets_at"))
            .and_then(Value::as_str)
            .and_then(parse_date);
        windows.push(UsageWindow {
            label: label.into(),
            used_percent: used.map_or(0, whole_percent),
            resets_at,
        });
    }

    if let Some((used, resets_at)) = parse_fable(json) {
        windows.push(UsageWindow {
            label: "Fable".into(),
            used_percent: used,
            resets_at,
        });
    }
    Ok(windows)
}

/// Fable weekly usage arrives in two shapes across API versions:
///  1. Newer: a `limits` array of model-scoped entries, each with
///     `scope.model.display_name` (or `id`) plus `percent`/`resets_at`.
///  2. Older: a top-level `seven_day_overage_included` window, or any
///     fable/mythos-named window, with `utilization`/`resets_at`.
fn parse_fable(json: &Map<String, Value>) -> Option<(u8, Option<DateTime<Utc>>)> {
    let is_fable = |name: &str| {
        let name = name.to_lowercase();
        name.contains("fable") || name.contains("mythos")
    };
    let mut used = None;
    let mut resets_at = None;

    if let Some(limits) = json.get("limits").and_then(Value::as_array) {
        for entry in limits.iter().filter_map(Value::as_object) {
            let model = entry.get("scope").and_then(|s| s.get("model"));
            let name = model
                .and_then(|m| m.get("display_name"))
                .and_then(Value::as_str)
                .or_else(|| model.and_then(|m| m.get("id")).and_then(Value::as_str))
                .unwrap_or("");
            if !is_fable(name) {
                continue;
            }
            if let Some(percent) = entry.get("percent").and_then(Value::as_f64) {
                used = Some(whole_percent(percent));
            }
            if let Some(resets) = entry.get("resets_at").and_then(Value::as_str) {
                resets_at = parse_date(resets);
            }
            if let Some(used) = used {
                return Some((used, resets_at));
            }
        }
    }

    let window = json
        .get("seven_day_overage_included")
        .and_then(Value::as_object)
        .or_else(|| {
            json.iter()
                .find(|(key, value)| is_fable(key) && value.is_object())
                .and_then(|(_, value)| value.as_object())
        });
    if let Some(window) = window {
        if let Some(utilization) = window.get("utilization").and_then(Value::as_f64) {
            used = Some(whole_percent(utilization));
            if let Some(resets) = window.get("resets_at").and_then(Value::as_str) {
                resets_at = parse_date(resets);
            }
        }
    }
    used.map(|used| (used, resets_at))
}

/// The macOS menu truncates Claude's utilization (`Int(utilization)`).
fn whole_percent(value: f64) -> u8 {
    percent(value.trunc())
}

fn parse_date(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|date| date.with_timezone(&Utc))
}

#[cfg(target_os = "macos")]
mod keychain {
    use std::io::Read;
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};

    use super::{parse_credentials_json, Credentials, SECURITY_BINARY, SECURITY_TIMEOUT};

    /// Reads the item's secret through Apple's `security` tool, never in
    /// process: Claude Code created the item with that tool, so it reads it
    /// without a dialog. If it does ask, we stop waiting after a short bound.
    pub(super) fn read(service: &str) -> Option<Credentials> {
        if !std::path::Path::new(SECURITY_BINARY).is_file() {
            return None;
        }
        let mut child = Command::new(SECURITY_BINARY)
            .args(["find-generic-password", "-s", service, "-w"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .ok()?;

        let deadline = Instant::now() + SECURITY_TIMEOUT;
        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break status,
                Ok(None) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(25))
                }
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return None;
                }
            }
        };
        if !status.success() {
            return None;
        }

        let mut output = Vec::new();
        child.stdout.take()?.read_to_end(&mut output).ok()?;
        let secret = output.trim_ascii();
        if secret.is_empty() {
            return None;
        }
        parse_credentials_json(secret)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(rfc3339: &str) -> DateTime<Utc> {
        parse_date(rfc3339).unwrap()
    }

    fn creds(expires_at: Option<&str>, token: &str) -> Credentials {
        Credentials {
            access_token: token.into(),
            refresh_token: Some("fake-refresh".into()),
            expires_at: expires_at.map(at),
            scopes: vec![],
        }
    }

    #[test]
    fn claude_is_send_sync_default() {
        fn check<T: Send + Sync + Default>() {}
        check::<Claude>();
    }

    #[test]
    fn parses_credentials_file() {
        let json = br#"{
            "claudeAiOauth": {
                "accessToken": "fake-access-token",
                "refreshToken": "fake-refresh-token",
                "expiresAt": 1767225600000,
                "scopes": ["user:inference", "user:profile"],
                "subscriptionType": "max"
            }
        }"#;
        let creds = parse_credentials_json(json).unwrap();
        assert_eq!(creds.access_token, "fake-access-token");
        assert_eq!(creds.refresh_token.as_deref(), Some("fake-refresh-token"));
        assert_eq!(creds.expires_at, Some(at("2026-01-01T00:00:00Z")));
        assert_eq!(creds.scopes, ["user:inference", "user:profile"]);
    }

    #[test]
    fn parses_minimal_credentials_and_keychain_newline() {
        let creds =
            parse_credentials_json(b"{\"claudeAiOauth\":{\"accessToken\":\"fake\"}}\n").unwrap();
        assert_eq!(creds.access_token, "fake");
        assert_eq!(creds.refresh_token, None);
        assert_eq!(creds.expires_at, None);
        assert!(creds.scopes.is_empty());
    }

    #[test]
    fn rejects_malformed_credentials() {
        assert!(parse_credentials_json(b"not json").is_none());
        assert!(parse_credentials_json(b"{}").is_none());
        assert!(parse_credentials_json(br#"{"claudeAiOauth":{"refreshToken":"fake"}}"#).is_none());
        assert!(parse_credentials_json(br#"{"claudeAiOauth":{"accessToken":42}}"#).is_none());
    }

    #[test]
    fn expiry_uses_a_one_minute_skew() {
        let now = at("2026-01-01T00:00:00Z");
        assert!(!creds(None, "fake").is_expired(now));
        assert!(!creds(Some("2026-01-01T00:01:01Z"), "fake").is_expired(now));
        assert!(creds(Some("2026-01-01T00:01:00Z"), "fake").is_expired(now));
        assert!(creds(Some("2025-12-31T00:00:00Z"), "fake").is_expired(now));
    }

    #[test]
    fn freshest_prefers_latest_expiry_then_earlier_source() {
        let undated = creds(None, "undated");
        let old = creds(Some("2026-01-01T00:00:00Z"), "old");
        let new = creds(Some("2026-01-02T00:00:00Z"), "new");
        let tie = creds(Some("2026-01-02T00:00:00Z"), "tie");
        assert_eq!(freshest(&[]), None);
        assert_eq!(
            freshest(&[undated.clone(), old.clone()])
                .unwrap()
                .access_token,
            "old"
        );
        assert_eq!(
            freshest(&[new.clone(), old.clone()]).unwrap().access_token,
            "new"
        );
        assert_eq!(freshest(&[old, new, tie]).unwrap().access_token, "new");
        assert_eq!(freshest(&[undated]).unwrap().access_token, "undated");
    }

    #[test]
    fn debug_never_prints_tokens() {
        let printed = format!("{:?}", creds(None, "fake-secret-token"));
        assert!(!printed.contains("fake-secret-token"));
        assert!(!printed.contains("fake-refresh"));
    }

    #[test]
    fn parses_refresh_response() {
        let now = at("2026-01-01T00:00:00Z");
        let scopes = vec!["user:inference".to_string()];
        let rotated = parse_refresh_response(
            br#"{"access_token":"fake-new","refresh_token":"fake-rotated","expires_in":28800}"#,
            "fake-old",
            &scopes,
            now,
        )
        .unwrap();
        assert_eq!(rotated.access_token, "fake-new");
        assert_eq!(rotated.refresh_token.as_deref(), Some("fake-rotated"));
        assert_eq!(rotated.expires_at, Some(at("2026-01-01T08:00:00Z")));
        assert_eq!(rotated.scopes, scopes);

        let kept = parse_refresh_response(br#"{"access_token":"fake-new"}"#, "fake-old", &[], now)
            .unwrap();
        assert_eq!(kept.refresh_token.as_deref(), Some("fake-old"));
        assert_eq!(kept.expires_at, None);

        let error =
            parse_refresh_response(br#"{"error":"fake"}"#, "fake-old", &[], now).unwrap_err();
        assert_eq!(error, UsageError::Parse("invalid refresh response".into()));
        assert!(!error.to_string().contains("fake"));
    }

    #[test]
    fn recognizes_expired_oauth_bodies() {
        assert!(is_expired_oauth_response(
            br#"{"error":{"type":"authentication_error"}}"#
        ));
        assert!(is_expired_oauth_response(b"OAuth token has expired"));
        assert!(is_expired_oauth_response(br#"{"error":"invalid_grant"}"#));
        assert!(!is_expired_oauth_response(
            br#"{"error":"invalid_request"}"#
        ));
    }

    #[test]
    fn parses_usage_with_model_scoped_fable_limit() {
        let json = br#"{
            "five_hour": {"utilization": 42.7, "resets_at": "2026-01-01T05:00:00.123456+00:00"},
            "seven_day": {"utilization": 18, "resets_at": "2026-01-07T00:00:00Z"},
            "seven_day_opus": null,
            "limits": [
                {"scope": {"model": {"display_name": "Opus"}}, "percent": 99, "resets_at": "2026-01-08T00:00:00Z"},
                {"scope": {"model": {"display_name": "Fable"}}, "percent": 63.9, "resets_at": "2026-01-07T12:00:00Z"}
            ]
        }"#;
        let windows = parse_usage(json).unwrap();
        assert_eq!(summary(&windows), [("5h", 42), ("7d", 18), ("Fable", 63)]);
        assert_eq!(
            windows[0].resets_at,
            Some(at("2026-01-01T05:00:00.123456Z"))
        );
        assert_eq!(windows[1].resets_at, Some(at("2026-01-07T00:00:00Z")));
        assert_eq!(windows[2].resets_at, Some(at("2026-01-07T12:00:00Z")));
    }

    #[test]
    fn parses_fable_by_model_id() {
        let json =
            br#"{"limits": [{"scope": {"model": {"id": "claude-mythos-1"}}, "percent": 5}]}"#;
        let fable = parse_fable(
            serde_json::from_slice::<Value>(json)
                .unwrap()
                .as_object()
                .unwrap(),
        );
        assert_eq!(fable, Some((5, None)));
    }

    #[test]
    fn parses_older_fable_window_shapes() {
        let overage = br#"{
            "five_hour": {"utilization": 1, "resets_at": null},
            "seven_day": {"utilization": 2, "resets_at": null},
            "seven_day_overage_included": {"utilization": 77.2, "resets_at": "2026-01-07T00:00:00Z"}
        }"#;
        let windows = parse_usage(overage).unwrap();
        assert_eq!(windows[2].label, "Fable");
        assert_eq!(windows[2].used_percent, 77);
        assert_eq!(windows[2].resets_at, Some(at("2026-01-07T00:00:00Z")));

        let named = br#"{"seven_day_fable": {"utilization": 12}}"#;
        let windows = parse_usage(named).unwrap();
        assert_eq!(windows[1].label, "Fable");
        assert_eq!(windows[1].used_percent, 12);
        assert_eq!(windows[1].resets_at, None);
    }

    fn summary(windows: &[UsageWindow]) -> Vec<(&str, u8)> {
        windows
            .iter()
            .map(|w| (w.label.as_str(), w.used_percent))
            .collect()
    }

    #[test]
    fn usage_without_fable_or_numbers_shows_only_a_zeroed_7d() {
        let windows =
            parse_usage(br#"{"five_hour": null, "seven_day": {"utilization": null}}"#).unwrap();
        assert_eq!(summary(&windows), [("7d", 0)]);
        assert!(windows.iter().all(|w| w.resets_at.is_none()));
    }

    #[test]
    fn account_without_a_5h_window_shows_7d_and_fable() {
        let json = br#"{
            "five_hour": null,
            "seven_day": {"utilization": 31.6, "resets_at": "2026-01-07T00:00:00Z"},
            "limits": [
                {"type": "weekly_all", "percent": 31.6, "resets_at": "2026-01-07T00:00:00Z"},
                {"type": "weekly_scoped", "scope": {"model": {"display_name": "Fable"}}, "percent": 12.9}
            ]
        }"#;
        let windows = parse_usage(json).unwrap();
        assert_eq!(summary(&windows), [("7d", 31), ("Fable", 12)]);
        assert_eq!(windows[0].resets_at, Some(at("2026-01-07T00:00:00Z")));
    }

    #[test]
    fn account_without_a_5h_window_or_fable_shows_only_7d() {
        let json = br#"{"five_hour": null, "seven_day": {"utilization": 31.6, "resets_at": null}}"#;
        assert_eq!(summary(&parse_usage(json).unwrap()), [("7d", 31)]);

        let missing = br#"{"seven_day": {"utilization": 31.6, "resets_at": null}}"#;
        assert_eq!(summary(&parse_usage(missing).unwrap()), [("7d", 31)]);
    }

    #[test]
    fn reset_time_alone_does_not_make_a_5h_window() {
        let json = br#"{
            "five_hour": {"utilization": null, "resets_at": "2026-01-01T05:00:00Z"},
            "seven_day": {"utilization": 9, "resets_at": null}
        }"#;
        assert_eq!(summary(&parse_usage(json).unwrap()), [("7d", 9)]);
    }

    #[test]
    fn unused_5h_window_with_no_reset_keeps_its_row() {
        let json = br#"{
            "five_hour": {"utilization": 0, "resets_at": null},
            "seven_day": {"utilization": 9, "resets_at": null}
        }"#;
        let windows = parse_usage(json).unwrap();
        assert_eq!(summary(&windows), [("5h", 0), ("7d", 9)]);
        assert_eq!(windows[0].resets_at, None);
    }

    #[test]
    fn usage_clamps_out_of_range_values() {
        let windows = parse_usage(
            br#"{"five_hour": {"utilization": 130}, "seven_day": {"utilization": -4}}"#,
        )
        .unwrap();
        assert_eq!(windows[0].used_percent, 100);
        assert_eq!(windows[1].used_percent, 0);
    }

    #[test]
    fn invalid_usage_payload_is_a_parse_error_without_the_body() {
        for body in [&b"<html>fake-body</html>"[..], b"[1,2]"] {
            let error = parse_usage(body).unwrap_err();
            assert_eq!(error, UsageError::Parse("invalid JSON".into()));
            assert!(!error.to_string().contains("fake-body"));
        }
    }
}
