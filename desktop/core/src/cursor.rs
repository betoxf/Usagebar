//! Cursor usage. Port of the macOS app's Swift service (`CursorAPIService`).
//!
//! Reads the `cursorAuth/accessToken` JWT from Cursor's VS Code state database,
//! synthesizes the `WorkosCursorSessionToken` cookie Cursor's web API expects,
//! and fetches the monthly usage summary. Plans with a weekly allowance spend
//! it before the monthly one, so the weekly figure wins when Cursor reports it.

use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use base64::Engine as _;
use chrono::{DateTime, Utc};
use rusqlite::types::ValueRef;
use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde_json::Value;

use crate::http::{network_error, status_error};
use crate::{paths, percent, Provider, ProviderUsage, UsageError, UsageWindow};

const USAGE_SUMMARY_ENDPOINT: &str = "https://cursor.com/api/usage-summary";
const USAGE_STATUS_ENDPOINT: &str =
    "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus";
const ACCESS_TOKEN_KEY: &str = "cursorAuth/accessToken";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
const BUSY_TIMEOUT: Duration = Duration::from_millis(250);
/// A found token is reread every five minutes; an absent one every 30 seconds.
const TOKEN_CACHE_TTL: Duration = Duration::from_secs(300);
const MISSING_TOKEN_CACHE_TTL: Duration = Duration::from_secs(30);

#[derive(Default)]
pub struct Cursor {
    cache: Mutex<Option<TokenCheck>>,
}

/// The last credential lookup. `token` is `None` when none was found.
struct TokenCheck {
    token: Option<CursorToken>,
    checked_at: Instant,
}

/// Cursor's access token and the account it belongs to. Deliberately not
/// `Debug`, so it cannot end up in logs or panic messages.
#[derive(Clone)]
struct CursorToken {
    subject: String,
    user_id: String,
    access_token: String,
    expires_at: Option<DateTime<Utc>>,
}

impl CursorToken {
    /// Parses the JWT's claims; `sub` is required.
    fn from_jwt(access_token: &str) -> Option<Self> {
        if access_token.is_empty() {
            return None;
        }
        let claims = decode_jwt_claims(access_token)?;
        let subject = claims.get("sub")?.as_str()?.to_owned();
        // `sub` is typically "auth0|user_..."; Cursor's cookie wants the trailing id.
        let user_id = subject
            .split('|')
            .next_back()
            .unwrap_or(&subject)
            .to_owned();
        let expires_at = claims
            .get("exp")
            .and_then(Value::as_f64)
            .and_then(|exp| DateTime::from_timestamp_millis((exp * 1000.0) as i64));
        Some(Self {
            subject,
            user_id,
            access_token: access_token.to_owned(),
            expires_at,
        })
    }

    /// Cookie Cursor's web API expects: `WorkosCursorSessionToken=<userID>::<jwt>`.
    fn cookie_header(&self) -> String {
        let value = format!("{}::{}", self.user_id, self.access_token);
        format!("WorkosCursorSessionToken={}", percent_encode_cookie(&value))
    }

    fn is_expired(&self) -> bool {
        self.expires_at
            .is_some_and(|expires_at| expires_at <= Utc::now())
    }
}

impl Cursor {
    pub fn has_credentials(&self) -> bool {
        if let Some(token) = self.cached_token() {
            return token.is_some();
        }
        let token = paths::cursor_state_db().and_then(|path| load_token(&path));
        self.store_token(token.clone());
        token.is_some()
    }

    /// Whether Grok Bot, Cursor's agent app, is signed in to the same Cursor
    /// account. Only SHA-256 account keys are compared; Grok Bot's tokens are
    /// never read.
    pub fn shares_account_with_grok_bot(&self) -> bool {
        let token = match self.cached_token() {
            Some(token) => token,
            None => {
                let token = paths::cursor_state_db().and_then(|path| load_token(&path));
                self.store_token(token.clone());
                token
            }
        };
        token.is_some_and(|token| is_grok_bot_signed_in(&token.subject))
    }

    pub async fn fetch(&self, client: &reqwest::Client) -> Result<ProviderUsage, UsageError> {
        let mut token = self.token().await;
        // Cursor refreshes its own token in the database; if our copy has
        // expired, drop it and reread the fresh one before the request.
        if token.as_ref().is_some_and(CursorToken::is_expired) {
            self.clear_cache();
            token = self.token().await;
        }
        let token = token.ok_or(UsageError::NotSignedIn)?;

        let response = client
            .get(USAGE_SUMMARY_ENDPOINT)
            .timeout(REQUEST_TIMEOUT)
            .header(reqwest::header::ACCEPT, "application/json")
            .header(reqwest::header::COOKIE, token.cookie_header())
            .send()
            .await
            .map_err(network_error)?;

        if response.status() != reqwest::StatusCode::OK {
            let error = status_error(&response);
            if error == UsageError::Unauthorized {
                self.clear_cache();
            }
            return Err(error);
        }

        let body = response.bytes().await.map_err(network_error)?;
        let summary = parse_usage_summary(&body)?;
        let weekly = weekly_usage(client, &token).await;
        Ok(usage(summary, weekly))
    }

    /// The cached lookup while it is fresh, otherwise a read on a blocking thread.
    async fn token(&self) -> Option<CursorToken> {
        if let Some(token) = self.cached_token() {
            return token;
        }
        let path = paths::cursor_state_db()?;
        let token = tokio::task::spawn_blocking(move || load_token(&path))
            .await
            .ok()
            .flatten();
        self.store_token(token.clone());
        token
    }

    /// `Some(lookup)` while the last lookup is fresh, `None` when it is due.
    fn cached_token(&self) -> Option<Option<CursorToken>> {
        let cache = self
            .cache
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let check = cache.as_ref()?;
        let ttl = if check.token.is_some() {
            TOKEN_CACHE_TTL
        } else {
            MISSING_TOKEN_CACHE_TTL
        };
        (check.checked_at.elapsed() < ttl).then(|| check.token.clone())
    }

    fn store_token(&self, token: Option<CursorToken>) {
        let mut cache = self
            .cache
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        *cache = Some(TokenCheck {
            token,
            checked_at: Instant::now(),
        });
    }

    fn clear_cache(&self) {
        let mut cache = self
            .cache
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        *cache = None;
    }
}

// MARK: - Credential discovery

fn load_token(db: &Path) -> Option<CursorToken> {
    // Current Cursor builds write the live token encrypted with Electron's
    // safeStorage, which only Cursor can read. The JWT then survives in the
    // checkpointed database file, which is what the Swift service reads with
    // `immutable=1`. The live value wins whenever it is still a JWT.
    [Snapshot::Live, Snapshot::Checkpointed]
        .into_iter()
        .find_map(|snapshot| {
            let access_token = read_state_value(db, ACCESS_TOKEN_KEY, snapshot)?;
            CursorToken::from_jwt(&access_token)
        })
}

#[derive(Clone, Copy)]
enum Snapshot {
    /// The current value, including Cursor's uncheckpointed write-ahead log.
    Live,
    /// The database file alone, ignoring the write-ahead log and taking no locks.
    Checkpointed,
}

/// Reads one value from the VS Code-style `ItemTable` key/value store with a
/// single keyed lookup. The database can be gigabytes, so it is opened
/// read-only and never scanned, and a running Cursor is never blocked.
fn read_state_value(db: &Path, key: &str, snapshot: Snapshot) -> Option<String> {
    if !db.is_file() {
        return None;
    }
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let connection = match snapshot {
        Snapshot::Live => Connection::open_with_flags(db, flags),
        Snapshot::Checkpointed => Connection::open_with_flags(
            format!("{}?mode=ro&immutable=1", sqlite_file_uri(db)?),
            flags | OpenFlags::SQLITE_OPEN_URI,
        ),
    }
    .ok()?;
    connection.busy_timeout(BUSY_TIMEOUT).ok()?;
    connection
        .query_row(
            "SELECT value FROM ItemTable WHERE key = ?1 LIMIT 1",
            [key],
            |row| {
                Ok(match row.get_ref(0)? {
                    ValueRef::Text(bytes) => String::from_utf8(bytes.to_vec()).ok(),
                    ValueRef::Blob(bytes) => decode_blob(bytes),
                    _ => None,
                })
            },
        )
        .optional()
        .ok()
        .flatten()
        .flatten()
}

/// An SQLite `file:` URI for an absolute path, with `\` turned into `/` on
/// Windows and the characters URIs reserve percent-encoded.
fn sqlite_file_uri(path: &Path) -> Option<String> {
    let mut path = path.to_str()?.to_owned();
    if cfg!(windows) {
        path = path.replace('\\', "/");
    }
    let mut uri = String::from(if path.starts_with('/') {
        "file://"
    } else {
        "file:///"
    });
    for byte in path.bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~/:".contains(&byte) {
            uri.push(byte as char);
        } else {
            uri.push_str(&format!("%{byte:02X}"));
        }
    }
    Some(uri)
}

/// UTF-8, falling back to UTF-16 little-endian, as the Swift service does.
fn decode_blob(bytes: &[u8]) -> Option<String> {
    if let Ok(text) = std::str::from_utf8(bytes) {
        return Some(text.to_owned());
    }
    let (pairs, []) = bytes.as_chunks::<2>() else {
        return None;
    };
    let units: Vec<u16> = pairs.iter().map(|pair| u16::from_le_bytes(*pair)).collect();
    String::from_utf16(&units).ok()
}

fn decode_jwt_claims(jwt: &str) -> Option<serde_json::Map<String, Value>> {
    let payload = jwt
        .split('.')
        .filter(|segment| !segment.is_empty())
        .nth(1)?;
    let mut base64 = payload.replace('-', "+").replace('_', "/");
    while base64.len() % 4 != 0 {
        base64.push('=');
    }
    let data = base64::engine::general_purpose::STANDARD
        .decode(base64)
        .ok()?;
    match serde_json::from_slice(&data).ok()? {
        Value::Object(claims) => Some(claims),
        _ => None,
    }
}

/// Percent-encodes the cookie value but keeps JWT-safe characters intact.
fn percent_encode_cookie(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
            encoded.push(byte as char);
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    encoded
}

// MARK: - Grok Bot

/// Grok Bot keeps its Cursor accounts keyed by the SHA-256 of the account's
/// subject. Only the keys are compared; its tokens are never read.
fn is_grok_bot_signed_in(subject: &str) -> bool {
    paths::grok_bot_secrets()
        .and_then(|path| std::fs::read(path).ok())
        .is_some_and(|secrets| grok_accounts_contain(&secrets, subject))
}

fn grok_accounts_contain(secrets: &[u8], subject: &str) -> bool {
    let Ok(Value::Object(secrets)) = serde_json::from_slice::<Value>(secrets) else {
        return false;
    };
    let Some(accounts_json) = secrets.get("cursor-accounts").and_then(Value::as_str) else {
        return false;
    };
    let Ok(accounts) = serde_json::from_str::<Value>(accounts_json) else {
        return false;
    };
    let Some(accounts) = accounts.get("accounts").and_then(Value::as_object) else {
        return false;
    };
    accounts.contains_key(&sha256_hex(subject.as_bytes()))
}

/// SHA-256 as lowercase hex.
fn sha256_hex(data: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(data)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

// MARK: - Weekly allowance

struct WeeklyUsage {
    percent: f64,
    resets_at: Option<DateTime<Utc>>,
}

/// The weekly allowance Cursor and Grok Bot show, or `None` when the plan has
/// none or the request fails; the monthly summary then stands.
async fn weekly_usage(client: &reqwest::Client, token: &CursorToken) -> Option<WeeklyUsage> {
    let response = client
        .post(USAGE_STATUS_ENDPOINT)
        .timeout(REQUEST_TIMEOUT)
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .header("Connect-Protocol-Version", "1")
        .bearer_auth(&token.access_token)
        .body("{}")
        .send()
        .await
        .ok()?;
    if response.status() != reqwest::StatusCode::OK {
        return None;
    }
    parse_weekly_usage(&response.bytes().await.ok()?)
}

fn parse_weekly_usage(data: &[u8]) -> Option<WeeklyUsage> {
    let json: Value = serde_json::from_slice(data).ok()?;
    let json = json.as_object()?;
    if json.get("hasNonZeroIncludedLimit").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    let percent = double_value(json.get("usagePercent"))?;
    let resets_at = json
        .get("nextResetTimestampUtc")
        .and_then(Value::as_str)
        .and_then(parse_date);
    Some(WeeklyUsage { percent, resets_at })
}

// MARK: - Monthly summary

struct UsageSummary {
    /// Cursor's `membershipType`, when present and non-empty.
    plan_name: Option<String>,
    used_percent: u8,
    resets_at: Option<DateTime<Utc>>,
}

fn parse_usage_summary(data: &[u8]) -> Result<UsageSummary, UsageError> {
    let invalid = || UsageError::Parse("invalid Cursor usage summary".into());
    let json: Value = serde_json::from_slice(data).map_err(|_| invalid())?;
    let json = json.as_object().ok_or_else(invalid)?;

    let plan_name = json
        .get("membershipType")
        .and_then(Value::as_str)
        .filter(|membership| !membership.is_empty())
        .map(str::to_owned);

    // Billing cycle end is the monthly reset.
    let resets_at = json
        .get("billingCycleEnd")
        .and_then(Value::as_str)
        .and_then(parse_date);

    let plan = json
        .get("individualUsage")
        .and_then(Value::as_object)
        .and_then(|individual| individual.get("plan"))
        .and_then(Value::as_object);
    let field = |name: &str| double_value(plan.and_then(|plan| plan.get(name)));

    // Percentage precedence mirrors CodexBar: totalPercentUsed, then the
    // average of the auto/api lanes, then either lane, then used/limit.
    let used_percent = if let Some(total) = field("totalPercentUsed") {
        percent(total)
    } else {
        match (field("autoPercentUsed"), field("apiPercentUsed")) {
            (Some(auto), Some(api)) => percent((auto + api) / 2.0),
            (Some(single), None) | (None, Some(single)) => percent(single),
            (None, None) => match (field("used"), field("limit")) {
                (Some(used), Some(limit)) if limit > 0.0 => percent(used / limit * 100.0),
                _ => 0,
            },
        }
    };

    Ok(UsageSummary {
        plan_name,
        used_percent,
        resets_at,
    })
}

/// Weekly first, as Cursor and Grok Bot show it; otherwise the billing month.
fn usage(summary: UsageSummary, weekly: Option<WeeklyUsage>) -> ProviderUsage {
    let window = match weekly {
        Some(weekly) => UsageWindow {
            label: "W".into(),
            used_percent: percent(weekly.percent),
            resets_at: weekly.resets_at,
        },
        None => UsageWindow {
            label: "M".into(),
            used_percent: summary.used_percent,
            resets_at: summary.resets_at,
        },
    };
    ProviderUsage {
        provider: Provider::Cursor,
        detail: summary.plan_name.as_deref().map(capitalized),
        windows: vec![window],
    }
}

/// A JSON number or numeric string.
fn double_value(value: Option<&Value>) -> Option<f64> {
    match value? {
        Value::Number(number) => number.as_f64(),
        Value::String(string) => string.parse().ok(),
        _ => None,
    }
}

/// ISO 8601 with or without fractional seconds.
fn parse_date(string: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(string)
        .ok()
        .map(|date| date.with_timezone(&Utc))
}

/// Foundation's `capitalized`: each whitespace-separated word gets an
/// uppercase first letter and lowercase rest, so "pro_plus" becomes "Pro_plus".
fn capitalized(string: &str) -> String {
    let mut result = String::with_capacity(string.len());
    let mut word_start = true;
    for character in string.chars() {
        if character.is_whitespace() {
            word_start = true;
            result.push(character);
        } else if word_start {
            word_start = false;
            result.extend(character.to_uppercase());
        } else {
            result.extend(character.to_lowercase());
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;

    /// An unsigned JWT with obviously fake claims.
    fn fake_jwt(claims: &str) -> String {
        format!(
            "{}.{}.fake-signature",
            URL_SAFE_NO_PAD.encode(r#"{"alg":"none","typ":"JWT"}"#),
            URL_SAFE_NO_PAD.encode(claims)
        )
    }

    fn fake_token() -> String {
        fake_jwt(r#"{"sub":"auth0|user_FAKE0000","exp":4102444800}"#)
    }

    struct TempDir(std::path::PathBuf);

    impl TempDir {
        fn new(name: &str) -> Self {
            let unique = format!(
                "usagebar-cursor-{name}-{}-{}",
                std::process::id(),
                Utc::now().timestamp_nanos_opt().unwrap_or_default()
            );
            let path = std::env::temp_dir().join(unique);
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn fake_state_db(dir: &TempDir, value: rusqlite::types::Value) -> std::path::PathBuf {
        let path = dir.0.join("state.vscdb");
        let connection = Connection::open(&path).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);",
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO ItemTable (key, value) VALUES (?1, ?2), ('other/key', 'x')",
                rusqlite::params![ACCESS_TOKEN_KEY, value],
            )
            .unwrap();
        path
    }

    #[test]
    fn extracts_subject_user_id_and_expiry_from_jwt() {
        let token = CursorToken::from_jwt(&fake_token()).unwrap();
        assert_eq!(token.subject, "auth0|user_FAKE0000");
        assert_eq!(token.user_id, "user_FAKE0000");
        assert_eq!(token.expires_at.unwrap().timestamp(), 4102444800);
        assert!(!token.is_expired());
    }

    #[test]
    fn subject_without_provider_prefix_is_the_user_id() {
        let token = CursorToken::from_jwt(&fake_jwt(r#"{"sub":"user_FAKE1111"}"#)).unwrap();
        assert_eq!(token.user_id, "user_FAKE1111");
        assert!(token.expires_at.is_none());
    }

    #[test]
    fn rejects_tokens_without_a_subject() {
        assert!(CursorToken::from_jwt("").is_none());
        assert!(CursorToken::from_jwt("not-a-jwt").is_none());
        assert!(CursorToken::from_jwt(&fake_jwt(r#"{"exp":1}"#)).is_none());
        assert!(CursorToken::from_jwt(&fake_jwt("[1,2]")).is_none());
    }

    #[test]
    fn expired_token_is_detected() {
        let token = CursorToken::from_jwt(&fake_jwt(r#"{"sub":"a|b","exp":1}"#)).unwrap();
        assert!(token.is_expired());
    }

    #[test]
    fn cookie_encodes_separator_and_keeps_jwt_characters() {
        let token = CursorToken {
            subject: "auth0|user_FAKE".into(),
            user_id: "user_FAKE".into(),
            access_token: "aaa.bbb-ccc_ddd".into(),
            expires_at: None,
        };
        assert_eq!(
            token.cookie_header(),
            "WorkosCursorSessionToken=user_FAKE%3A%3Aaaa.bbb-ccc_ddd"
        );
    }

    #[test]
    fn reads_text_token_from_state_db() {
        let dir = TempDir::new("text");
        let db = fake_state_db(&dir, rusqlite::types::Value::Text(fake_token()));
        assert_eq!(
            read_state_value(&db, ACCESS_TOKEN_KEY, Snapshot::Live),
            Some(fake_token())
        );
        assert_eq!(read_state_value(&db, "missing/key", Snapshot::Live), None);
        let token = load_token(&db).unwrap();
        assert_eq!(token.user_id, "user_FAKE0000");
    }

    #[test]
    fn reads_blob_token_from_state_db() {
        let dir = TempDir::new("blob");
        let db = fake_state_db(
            &dir,
            rusqlite::types::Value::Blob(fake_token().into_bytes()),
        );
        assert_eq!(load_token(&db).unwrap().subject, "auth0|user_FAKE0000");

        // "fé" in UTF-16LE is not valid UTF-8, so it takes the UTF-16 fallback.
        let utf16: Vec<u8> = "fé".encode_utf16().flat_map(u16::to_le_bytes).collect();
        assert_eq!(decode_blob(&utf16).as_deref(), Some("fé"));
    }

    #[test]
    fn missing_state_db_has_no_token() {
        let dir = TempDir::new("missing");
        assert!(load_token(&dir.0.join("state.vscdb")).is_none());
    }

    #[test]
    fn falls_back_to_checkpointed_jwt_when_live_value_is_encrypted() {
        let dir = TempDir::new("wal #1");
        let db = fake_state_db(&dir, rusqlite::types::Value::Text(fake_token()));
        // Cursor keeps the database open in WAL mode; a newer, encrypted value
        // sits in the write-ahead log until the next checkpoint.
        let writer = Connection::open(&db).unwrap();
        writer
            .execute_batch("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
            .unwrap();
        writer
            .execute(
                "UPDATE ItemTable SET value = 'fake-encrypted:v10:AAAA' WHERE key = ?1",
                [ACCESS_TOKEN_KEY],
            )
            .unwrap();

        assert_eq!(
            read_state_value(&db, ACCESS_TOKEN_KEY, Snapshot::Live).as_deref(),
            Some("fake-encrypted:v10:AAAA")
        );
        assert_eq!(
            read_state_value(&db, ACCESS_TOKEN_KEY, Snapshot::Checkpointed),
            Some(fake_token())
        );
        assert_eq!(load_token(&db).unwrap().user_id, "user_FAKE0000");
        drop(writer);
    }

    #[test]
    fn sqlite_uri_escapes_reserved_characters() {
        assert_eq!(
            sqlite_file_uri(Path::new("/tmp/a b/#?%.db")).unwrap(),
            "file:///tmp/a%20b/%23%3F%25.db"
        );
        assert_eq!(
            sqlite_file_uri(Path::new("C:/Users/x/state.vscdb")).unwrap(),
            "file:///C:/Users/x/state.vscdb"
        );
        #[cfg(windows)]
        assert_eq!(
            sqlite_file_uri(Path::new("C:\\Users\\x\\state.vscdb")).unwrap(),
            "file:///C:/Users/x/state.vscdb"
        );
    }

    #[test]
    fn parses_monthly_summary_with_total_percent() {
        let summary = parse_usage_summary(
            br#"{
                "membershipType": "pro",
                "billingCycleEnd": "2026-11-01T00:00:00.000Z",
                "individualUsage": {"plan": {"totalPercentUsed": 42.6, "autoPercentUsed": 1}}
            }"#,
        )
        .unwrap();
        assert_eq!(summary.used_percent, 43);
        let usage = usage(summary, None);
        assert_eq!(usage.detail.as_deref(), Some("Pro"));
        assert_eq!(usage.windows.len(), 1);
        assert_eq!(usage.windows[0].label, "M");
        assert_eq!(usage.windows[0].used_percent, 43);
        assert_eq!(
            usage.windows[0].resets_at.unwrap().to_rfc3339(),
            "2026-11-01T00:00:00+00:00"
        );
    }

    #[test]
    fn percentage_precedence_falls_back_through_lanes_and_used_over_limit() {
        let percent_of = |body: &str| parse_usage_summary(body.as_bytes()).unwrap().used_percent;
        let plan = |fields: &str| format!(r#"{{"individualUsage":{{"plan":{{{fields}}}}}}}"#);
        assert_eq!(
            percent_of(&plan(r#""autoPercentUsed":20,"apiPercentUsed":"60""#)),
            40
        );
        assert_eq!(percent_of(&plan(r#""apiPercentUsed":12.4"#)), 12);
        assert_eq!(percent_of(&plan(r#""used":250,"limit":500"#)), 50);
        assert_eq!(percent_of(&plan(r#""used":250,"limit":0"#)), 0);
        assert_eq!(percent_of(&plan(r#""totalPercentUsed":180"#)), 100);
        assert_eq!(percent_of("{}"), 0);
    }

    #[test]
    fn unknown_plan_has_no_detail_and_bad_json_is_a_parse_error() {
        let summary = parse_usage_summary(br#"{"membershipType":""}"#).unwrap();
        assert!(usage(summary, None).detail.is_none());
        assert!(matches!(
            parse_usage_summary(b"<html>"),
            Err(UsageError::Parse(_))
        ));
    }

    #[test]
    fn weekly_allowance_wins_over_monthly() {
        let weekly = parse_weekly_usage(
            br#"{"hasNonZeroIncludedLimit":true,"usagePercent":99.7,
                "nextResetTimestampUtc":"2026-10-27T17:00:00Z"}"#,
        )
        .unwrap();
        let summary = parse_usage_summary(
            br#"{"membershipType":"premium","billingCycleEnd":"2026-11-01T00:00:00Z",
                "individualUsage":{"plan":{"totalPercentUsed":10}}}"#,
        )
        .unwrap();
        let usage = usage(summary, Some(weekly));
        assert_eq!(usage.detail.as_deref(), Some("Premium"));
        assert_eq!(usage.windows[0].label, "W");
        assert_eq!(usage.windows[0].used_percent, 100);
        assert_eq!(
            usage.windows[0].resets_at.unwrap().to_rfc3339(),
            "2026-10-27T17:00:00+00:00"
        );
    }

    #[test]
    fn weekly_requires_included_limit_and_percent() {
        assert!(
            parse_weekly_usage(br#"{"hasNonZeroIncludedLimit":false,"usagePercent":5}"#).is_none()
        );
        assert!(parse_weekly_usage(br#"{"usagePercent":5}"#).is_none());
        assert!(parse_weekly_usage(br#"{"hasNonZeroIncludedLimit":true}"#).is_none());
        let weekly =
            parse_weekly_usage(br#"{"hasNonZeroIncludedLimit":true,"usagePercent":"7"}"#).unwrap();
        assert_eq!(weekly.percent, 7.0);
        assert!(weekly.resets_at.is_none());
    }

    #[test]
    fn sha256_matches_known_vectors() {
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            sha256_hex(&[b'a'; 1000]),
            "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"
        );
    }

    #[test]
    fn grok_bot_match_compares_hashed_subject_keys() {
        let key = sha256_hex(b"auth0|user_FAKE0000");
        let accounts = format!(r#"{{"accounts":{{"{key}":{{}}}}}}"#);
        let secrets = serde_json::json!({ "cursor-accounts": accounts }).to_string();
        assert!(grok_accounts_contain(
            secrets.as_bytes(),
            "auth0|user_FAKE0000"
        ));
        assert!(!grok_accounts_contain(
            secrets.as_bytes(),
            "auth0|user_OTHER"
        ));
        assert!(!grok_accounts_contain(b"{}", "auth0|user_FAKE0000"));
        assert!(!grok_accounts_contain(b"not json", "auth0|user_FAKE0000"));
    }

    #[test]
    fn capitalizes_like_foundation() {
        assert_eq!(capitalized("premium"), "Premium");
        assert_eq!(capitalized("PRO plus"), "Pro Plus");
        assert_eq!(capitalized("free_trial"), "Free_trial");
    }
}
