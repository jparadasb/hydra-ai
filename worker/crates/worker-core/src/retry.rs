//! Bounded retry for provider calls.
//!
//! A single 429 or 503 used to fail a job outright — the coordinator would then re-queue it,
//! spend one of its five attempts, and possibly hand it to a different worker, for a condition
//! the provider itself told us to wait out. Retrying here is both faster and cheaper than
//! retrying a job.
//!
//! Only requests that are safe to repeat are retried: the caller hands in a builder that can be
//! cloned, and a request carrying a stream body cannot be, so it is sent once. Only responses
//! that say "try again" are retried — 429 and 503 — never a 4xx that means the request itself
//! is wrong.

use std::time::Duration;

use reqwest::{RequestBuilder, Response, StatusCode};

use crate::error::{Error, Result};

/// Attempts in total, first included. Small on purpose: the coordinator has its own retry
/// budget above this one, and a worker that spends minutes on backoff is a worker holding a
/// lease it is not using.
const MAX_ATTEMPTS: u32 = 3;

/// Doubling from here: 500ms, then 1s.
const BASE_BACKOFF: Duration = Duration::from_millis(500);

/// However long `Retry-After` asks for, wait no longer than this. A provider asking for an
/// hour is telling us to give the job back, not to sit on it.
const MAX_BACKOFF: Duration = Duration::from_secs(10);

/// Send `builder`, retrying while the provider says the condition is temporary.
///
/// Honors `Retry-After`, clamped. Transport errors are retried too — a connection reset mid-handshake is the same kind of transient as a 503 — but
/// the last error is returned rather than swallowed if every attempt fails.
pub async fn send(builder: RequestBuilder) -> Result<Response> {
    let mut current = builder;
    let mut attempt = 1;

    loop {
        // Keep a spare only while another attempt is allowed. A request carrying a stream body
        // cannot be cloned at all, which makes it single-shot by construction.
        let spare = if attempt < MAX_ATTEMPTS {
            current.try_clone()
        } else {
            None
        };

        match current.send().await {
            Ok(resp) if should_retry(resp.status()) => {
                let Some(next) = spare else { return Ok(resp) };
                sleep(backoff(attempt, retry_after(&resp))).await;
                current = next;
            }

            Ok(resp) => return Ok(resp),

            Err(error) if is_transient(&error) => {
                let Some(next) = spare else {
                    return Err(Error::from(error));
                };
                sleep(backoff(attempt, None)).await;
                current = next;
            }

            Err(error) => return Err(Error::from(error)),
        }

        attempt += 1;
    }
}

/// `builder.send_retried().await` — [`send`] in postfix position, so a call site keeps its
/// shape instead of being turned inside out.
pub trait RetryExt {
    fn send_retried(self) -> impl std::future::Future<Output = Result<Response>> + Send;
}

impl RetryExt for RequestBuilder {
    fn send_retried(self) -> impl std::future::Future<Output = Result<Response>> + Send {
        send(self)
    }
}

/// Statuses that mean "the request was fine, the moment was not".
pub fn should_retry(status: StatusCode) -> bool {
    matches!(
        status,
        StatusCode::TOO_MANY_REQUESTS | StatusCode::SERVICE_UNAVAILABLE
    )
}

/// A transport failure worth one more try. A timeout is not: the caller's read timeout is
/// already the bound on how long this call may take, and retrying restarts that whole budget.
fn is_transient(error: &reqwest::Error) -> bool {
    error.is_connect() || error.is_request()
}

/// `Retry-After` in its delay-seconds form, clamped to [`MAX_BACKOFF`].
///
/// The HTTP-date form is ignored rather than parsed: it would mean a date-parsing dependency
/// for a header every provider in question sends as seconds, and the fallback — exponential
/// backoff — is already a reasonable answer.
pub fn retry_after(resp: &Response) -> Option<Duration> {
    resp.headers()
        .get(reqwest::header::RETRY_AFTER)?
        .to_str()
        .ok()?
        .trim()
        .parse::<u64>()
        .ok()
        .map(|seconds| Duration::from_secs(seconds).min(MAX_BACKOFF))
}

/// How long to wait before attempt `attempt + 1`. The provider's own answer wins when it gave
/// one; otherwise exponential from [`BASE_BACKOFF`].
pub fn backoff(attempt: u32, retry_after: Option<Duration>) -> Duration {
    match retry_after {
        Some(d) => d.min(MAX_BACKOFF),
        None => (BASE_BACKOFF * 2u32.saturating_pow(attempt.saturating_sub(1))).min(MAX_BACKOFF),
    }
}

async fn sleep(duration: Duration) {
    if !duration.is_zero() {
        tokio::time::sleep(duration).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_temporary_statuses_are_retried() {
        assert!(should_retry(StatusCode::TOO_MANY_REQUESTS));
        assert!(should_retry(StatusCode::SERVICE_UNAVAILABLE));

        // A bad request is not going to become a good one.
        assert!(!should_retry(StatusCode::BAD_REQUEST));
        assert!(!should_retry(StatusCode::UNAUTHORIZED));
        assert!(!should_retry(StatusCode::NOT_FOUND));
        assert!(!should_retry(StatusCode::INTERNAL_SERVER_ERROR));
        assert!(!should_retry(StatusCode::OK));
    }

    #[test]
    fn backoff_doubles_and_is_capped() {
        assert_eq!(backoff(1, None), Duration::from_millis(500));
        assert_eq!(backoff(2, None), Duration::from_secs(1));
        assert_eq!(backoff(30, None), MAX_BACKOFF);
    }

    #[test]
    fn a_providers_own_answer_wins_but_is_still_capped() {
        assert_eq!(
            backoff(1, Some(Duration::from_secs(2))),
            Duration::from_secs(2)
        );

        // An hour means "give the job back", not "hold the lease for an hour".
        assert_eq!(backoff(1, Some(Duration::from_secs(3600))), MAX_BACKOFF);
    }
}
