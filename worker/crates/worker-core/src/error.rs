//! Error type for worker-core.

use thiserror::Error;

#[derive(Debug, Error)]
pub enum Error {
    #[error("http error: {0}")]
    Http(String),

    #[error("provider returned status {status}: {body}")]
    ProviderStatus { status: u16, body: String },

    #[error("unknown provider/adapter: {0}")]
    UnknownAdapter(String),

    #[error("no credentials available for provider: {0}")]
    MissingCredentials(String),

    #[error("vault error: {0}")]
    Vault(String),

    #[error("privacy violation: job {job} requires {required}, worker cannot satisfy ({detail})")]
    PrivacyViolation {
        job: String,
        required: String,
        detail: String,
    },

    #[error("limit exceeded: {0}")]
    LimitExceeded(String),

    #[error("serialization error: {0}")]
    Serde(#[from] serde_json::Error),

    #[error("{0}")]
    Other(String),
}

impl From<reqwest::Error> for Error {
    fn from(e: reqwest::Error) -> Self {
        Error::Http(e.to_string())
    }
}

pub type Result<T> = std::result::Result<T, Error>;
