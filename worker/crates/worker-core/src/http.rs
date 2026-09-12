//! Shared HTTP client construction for bounded network operations.

use std::time::Duration;

use crate::error::Result;

pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
pub const DEFAULT_REQUEST_TIMEOUT: Duration = Duration::from_secs(120);

pub fn client(read_timeout: Duration) -> Result<reqwest::Client> {
    if read_timeout.is_zero() {
        return Err(crate::error::Error::Other(
            "request_timeout_secs must be greater than zero".into(),
        ));
    }

    reqwest::Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        .read_timeout(read_timeout)
        .build()
        .map_err(Into::into)
}

/// Local inference may legitimately take minutes before emitting its first byte. Keep only the
/// connection bound here; job deadlines and coordinator cancellation bound total execution.
pub fn local_client() -> Result<reqwest::Client> {
    reqwest::Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        .build()
        .map_err(Into::into)
}

pub fn default_client() -> Result<reqwest::Client> {
    client(DEFAULT_REQUEST_TIMEOUT)
}

pub fn download_client() -> Result<reqwest::Client> {
    reqwest::Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        .read_timeout(DEFAULT_REQUEST_TIMEOUT)
        .build()
        .map_err(Into::into)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;

    #[tokio::test]
    async fn request_timeout_bounds_silent_server() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (_socket, _) = listener.accept().await.unwrap();
            tokio::time::sleep(Duration::from_secs(5)).await;
        });

        let http = client(Duration::from_millis(50)).unwrap();
        let started = tokio::time::Instant::now();
        let error = http.get(format!("http://{address}/silent")).send().await;

        assert!(error.is_err(), "silent server unexpectedly returned");
        assert!(started.elapsed() < Duration::from_secs(1));
        server.abort();
    }

    #[test]
    fn zero_request_timeout_is_rejected() {
        assert!(client(Duration::ZERO).is_err());
    }
}
