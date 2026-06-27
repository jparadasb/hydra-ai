//! worker-core — the local AI execution gateway.
//!
//! A worker runs leased jobs either on a **local model** (Ollama / llama.cpp / …) or via a
//! **user-owned external provider** (OpenAI / Anthropic / …) behind one [`adapter::ProviderAdapter`]
//! trait. Provider tokens live only in [`vault`] and never cross the coordinator boundary.

pub mod adapter;
pub mod adapters;
pub mod config;
pub mod error;
pub mod gateway;
pub mod limits;
pub mod privacy;
pub mod registration;
pub mod runtime;
pub mod types;
pub mod usage;
pub mod vault;

pub use adapter::{AdapterRegistry, ProviderAdapter};
pub use config::{Limits, Preference, PrivacyPrefs, RoutingPolicy, WorkerConfig};
pub use error::{Error, Result};
pub use gateway::Gateway;
pub use limits::LimitGuard;
pub use registration::WorkerRegistration;
pub use types::{ExecutionMode, Job, JobResult, JobStatus, PrivacyLevel};
pub use vault::{fingerprint, redact, Secret, Vault};
