//! Shared HTTP behavior: one client without a cookie store, short timeouts,
//! and status codes mapped to [`UsageError`] the same way for every provider.

use std::time::Duration;

use reqwest::{Response, StatusCode};

use crate::UsageError;

pub(crate) fn client() -> reqwest::Client {
    reqwest::Client::builder()
        .user_agent(concat!("Usagebar/", env!("CARGO_PKG_VERSION")))
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(20))
        // An idle pooled connection wakes the process for keepalives; a new
        // handshake per refresh costs less, as on macOS.
        .pool_max_idle_per_host(0)
        .build()
        .expect("HTTP client configuration is valid")
}

/// Maps a non-success response to an error, honoring `Retry-After` seconds.
pub(crate) fn status_error(response: &Response) -> UsageError {
    match response.status() {
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => UsageError::Unauthorized,
        StatusCode::TOO_MANY_REQUESTS => UsageError::RateLimited {
            retry_after_secs: response
                .headers()
                .get(reqwest::header::RETRY_AFTER)
                .and_then(|value| value.to_str().ok())
                .and_then(|value| value.trim().parse().ok()),
        },
        status => UsageError::Network(format!("HTTP {}", status.as_u16())),
    }
}

/// Network failures never include the request URL, which can carry tokens.
pub(crate) fn network_error(error: reqwest::Error) -> UsageError {
    UsageError::Network(if error.is_timeout() {
        "timed out".into()
    } else if error.is_connect() {
        "could not connect".into()
    } else {
        "request failed".into()
    })
}
