//! Concrete [`crate::adapter::ProviderAdapter`] implementations.
//!
//! External providers (`uses_external_provider() == true`): OpenAI-compatible (OpenAI,
//! OpenRouter, Groq, Mistral, Together, Fireworks, custom), Anthropic, Gemini.
//! Local runtimes (`false`): Ollama, plus llama.cpp / vLLM / LM Studio (OpenAI-compatible).

pub mod anthropic;
pub mod gemini;
pub mod local_openai;
pub mod ollama;
pub mod openai_compatible;

pub use anthropic::AnthropicAdapter;
pub use gemini::GeminiAdapter;
pub use local_openai::LocalOpenAiAdapter;
pub use ollama::OllamaAdapter;
pub use openai_compatible::{OpenAICompatibleAdapter, Pricing};

/// Known OpenAI-compatible providers and their default base URLs. `custom` lets the user
/// point at any `/v1`-style endpoint.
pub fn openai_compatible_base_url(provider: &str) -> Option<&'static str> {
    Some(match provider {
        "openai" => "https://api.openai.com/v1",
        "openrouter" => "https://openrouter.ai/api/v1",
        "groq" => "https://api.groq.com/openai/v1",
        "mistral" => "https://api.mistral.ai/v1",
        "together" => "https://api.together.xyz/v1",
        "fireworks" => "https://api.fireworks.ai/inference/v1",
        _ => return None,
    })
}

use std::sync::Arc;

use crate::adapter::ProviderAdapter;
use crate::error::{Error, Result};
use crate::vault::Secret;

/// Build an external-provider adapter for `provider`, using `token`. `base_url` overrides the
/// default (required for `custom`). The token is moved into the adapter and never escapes it.
pub fn build_external_adapter(
    provider: &str,
    base_url: Option<String>,
    token: Secret,
    client: reqwest::Client,
) -> Result<Arc<dyn ProviderAdapter>> {
    match provider {
        "anthropic" | "claude" => Ok(Arc::new(match base_url {
            Some(b) => AnthropicAdapter::with_base_url(b, token, client),
            None => AnthropicAdapter::new(token, client),
        })),
        "gemini" | "google" => Ok(Arc::new(match base_url {
            Some(b) => GeminiAdapter::with_base_url(b, token, client),
            None => GeminiAdapter::new(token, client),
        })),
        other => {
            let base = base_url
                .or_else(|| openai_compatible_base_url(other).map(String::from))
                .ok_or_else(|| {
                    Error::Other(format!(
                        "unknown provider '{other}': pass a base_url for custom"
                    ))
                })?;
            Ok(Arc::new(OpenAICompatibleAdapter::new(
                other, base, token, client,
            )))
        }
    }
}
