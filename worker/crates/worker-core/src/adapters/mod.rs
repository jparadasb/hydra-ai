//! Concrete [`crate::adapter::ProviderAdapter`] implementations.
//!
//! External providers (`uses_external_provider() == true`): OpenAI-compatible (OpenAI,
//! OpenRouter, Groq, Mistral, Together, Fireworks, custom), Anthropic, Gemini.
//! Local runtimes (`false`): Ollama, plus llama.cpp / vLLM / LM Studio (OpenAI-compatible).

pub mod anthropic;
pub mod gemini;
pub mod gemini_oauth;
pub mod local_openai;
pub mod ollama;
pub mod openai_chatgpt;
pub mod openai_compatible;

pub use anthropic::AnthropicAdapter;
pub use gemini::GeminiAdapter;
pub use gemini_oauth::GeminiCodeAssistAdapter;
pub use openai_chatgpt::ChatGptBackendAdapter;
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
///
/// A vault value that parses as an OAuth credential blob (`provider login`) selects the
/// matching OAuth adapter; a plain string is treated as a static API key as before.
pub fn build_external_adapter(
    provider: &str,
    base_url: Option<String>,
    token: Secret,
    client: reqwest::Client,
) -> Result<Arc<dyn ProviderAdapter>> {
    if let Some(oauth) = crate::oauth::OAuthTokens::from_vault_value(token.expose()) {
        return match oauth.flavor.as_str() {
            crate::oauth::FLAVOR_GOOGLE_CODE_ASSIST => Ok(Arc::new(match base_url {
                Some(b) => GeminiCodeAssistAdapter::with_base_url(b, oauth, client),
                None => GeminiCodeAssistAdapter::new(oauth, client),
            })),
            crate::oauth::FLAVOR_OPENAI_CHATGPT => Ok(Arc::new(match base_url {
                Some(b) => ChatGptBackendAdapter::with_base_url(b, oauth, client),
                None => ChatGptBackendAdapter::new(oauth, client),
            })),
            other => Err(Error::Other(format!(
                "unsupported oauth credential flavor '{other}' for provider '{provider}'"
            ))),
        };
    }

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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::oauth::{OAuthTokens, FLAVOR_GOOGLE_CODE_ASSIST};

    #[test]
    fn oauth_blob_selects_code_assist_adapter_and_plain_key_stays_static() {
        let client = reqwest::Client::new();

        let blob = OAuthTokens {
            flavor: FLAVOR_GOOGLE_CODE_ASSIST.into(),
            access_token: "ya29.x".into(),
            refresh_token: None,
            expires_at_unix: 0,
            project_id: Some("p".into()),
            account_id: None,
        }
        .to_vault_value();

        let oauth = build_external_adapter("gemini", None, Secret::new(blob), client.clone())
            .expect("oauth adapter builds");
        assert_eq!(oauth.name(), "gemini");
        assert!(oauth.uses_external_provider());

        // A plain key still yields the static-key Gemini adapter (same name, api-key path).
        let plain = build_external_adapter("gemini", None, Secret::new("AIzaKey"), client.clone())
            .expect("static adapter builds");
        assert_eq!(plain.name(), "gemini");

        // Unknown OAuth flavor is refused rather than silently treated as an API key.
        let bad = OAuthTokens {
            flavor: "mystery".into(),
            access_token: "t".into(),
            refresh_token: None,
            expires_at_unix: 0,
            project_id: None,
            account_id: None,
        }
        .to_vault_value();
        assert!(build_external_adapter("gemini", None, Secret::new(bad), client).is_err());
    }
}
