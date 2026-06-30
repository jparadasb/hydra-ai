//! Local OpenAI-compatible runtimes: **llama.cpp** (`llama-server`), **vLLM**, and
//! **LM Studio**. All serve an OpenAI-style `/v1` API, so they reuse the shared
//! OpenAI-compatible HTTP path — but they run on this machine, so
//! `uses_external_provider() == false` (privacy-safe for every job level) and a token is
//! optional (most local setups need none).

use async_trait::async_trait;
use reqwest::Client;

use super::openai_compatible::{oai_chat, oai_list_models, oai_validate};
use crate::adapter::ProviderAdapter;
use crate::error::Result;
use crate::types::{ChatRequest, ChatResponse, ModelInfo};
use crate::vault::Secret;

/// llama.cpp `llama-server` default OpenAI endpoint.
pub const LLAMACPP_DEFAULT_ENDPOINT: &str = "http://127.0.0.1:8080/v1";
/// vLLM OpenAI-compatible server default endpoint.
pub const VLLM_DEFAULT_ENDPOINT: &str = "http://127.0.0.1:8000/v1";
/// LM Studio local server default endpoint.
pub const LM_STUDIO_DEFAULT_ENDPOINT: &str = "http://127.0.0.1:1234/v1";

/// A local runtime exposing an OpenAI-compatible `/v1` API.
pub struct LocalOpenAiAdapter {
    name: String,
    base_url: String,
    /// Optional key (e.g. vLLM started with `--api-key`); usually `None`.
    api_key: Option<Secret>,
    client: Client,
}

impl LocalOpenAiAdapter {
    pub fn new(
        name: impl Into<String>,
        base_url: impl Into<String>,
        api_key: Option<Secret>,
        client: Client,
    ) -> Self {
        Self {
            name: name.into(),
            base_url: base_url.into().trim_end_matches('/').to_string(),
            api_key,
            client,
        }
    }

    /// llama.cpp at the default endpoint.
    pub fn llama_cpp(client: Client) -> Self {
        Self::new("llama_cpp", LLAMACPP_DEFAULT_ENDPOINT, None, client)
    }

    /// vLLM at the default endpoint.
    pub fn vllm(client: Client) -> Self {
        Self::new("vllm", VLLM_DEFAULT_ENDPOINT, None, client)
    }

    /// LM Studio at the default endpoint.
    pub fn lm_studio(client: Client) -> Self {
        Self::new("lm_studio", LM_STUDIO_DEFAULT_ENDPOINT, None, client)
    }

    fn bearer(&self) -> Option<&str> {
        self.api_key.as_ref().map(|s| s.expose())
    }
}

#[async_trait]
impl ProviderAdapter for LocalOpenAiAdapter {
    fn name(&self) -> &str {
        &self.name
    }

    fn uses_external_provider(&self) -> bool {
        false
    }

    async fn list_models(&self) -> Result<Vec<ModelInfo>> {
        oai_list_models(
            &self.client,
            &self.base_url,
            self.bearer(),
            &["chat", "text.extract_json", "text.clean", "image.describe"],
            false,
        )
        .await
    }

    async fn validate_credentials(&self) -> Result<bool> {
        oai_validate(&self.client, &self.base_url, self.bearer()).await
    }

    async fn run_chat_completion(&self, req: ChatRequest) -> Result<ChatResponse> {
        oai_chat(&self.client, &self.base_url, self.bearer(), req).await
    }
}
