//! Shared HTTP client construction for bounded network operations.

use std::time::Duration;

use crate::error::Result;

pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
pub const DEFAULT_REQUEST_TIMEOUT: Duration = Duration::from_secs(120);

pub fn client(request_timeout: Duration) -> Result<reqwest::Client> {
    reqwest::Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
        .timeout(request_timeout)
        .build()
        .map_err(Into::into)
}

pub fn default_client() -> Result<reqwest::Client> {
    client(DEFAULT_REQUEST_TIMEOUT)
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
}
