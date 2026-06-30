//! OpenAI-compatible adapter. One implementation covers OpenAI, OpenRouter, Groq, Mistral,
//! Together, Fireworks, and any custom `/v1`-style endpoint — they differ only by `base_url`
//! and the bearer token.

use async_trait::async_trait;
use reqwest::Client;
use serde_json::json;

use crate::adapter::ProviderAdapter;
use crate::error::{Error, Result};
use crate::types::{ChatRequest, ChatResponse, ModelInfo, Usage};
use crate::vault::Secret;

/// Per-1M-token pricing used by `estimate_cost`, when known.
#[derive(Debug, Clone, Default)]
pub struct Pricing {
    pub input_per_1m_usd: f64,
    pub output_per_1m_usd: f64,
}

pub struct OpenAICompatibleAdapter {
    name: String,
    base_url: String,
    token: Secret,
    client: Client,
    pricing: Option<Pricing>,
}

impl OpenAICompatibleAdapter {
    pub fn new(
        name: impl Into<String>,
        base_url: impl Into<String>,
        token: Secret,
        client: Client,
    ) -> Self {
        Self {
            name: name.into(),
            base_url: base_url.into().trim_end_matches('/').to_string(),
            token,
            client,
            pricing: None,
        }
    }

    pub fn with_pricing(mut self, pricing: Pricing) -> Self {
        self.pricing = Some(pricing);
        self
    }
}

#[async_trait]
impl ProviderAdapter for OpenAICompatibleAdapter {
    fn name(&self) -> &str {
        &self.name
    }

    fn uses_external_provider(&self) -> bool {
        true
    }

    async fn list_models(&self) -> Result<Vec<ModelInfo>> {
        oai_list_models(
            &self.client,
            &self.base_url,
            Some(self.token.expose()),
            &["chat", "text.clean", "text.extract_json"],
            true,
        )
        .await
    }

    async fn validate_credentials(&self) -> Result<bool> {
        oai_validate(&self.client, &self.base_url, Some(self.token.expose())).await
    }

    async fn run_chat_completion(&self, req: ChatRequest) -> Result<ChatResponse> {
        oai_chat(&self.client, &self.base_url, Some(self.token.expose()), req).await
    }

    fn estimate_cost(&self, usage: &Usage) -> Option<crate::types::CostEstimate> {
        let p = self.pricing.as_ref()?;
        let usd = (usage.input_tokens as f64 / 1_000_000.0) * p.input_per_1m_usd
            + (usage.output_tokens as f64 / 1_000_000.0) * p.output_per_1m_usd;
        Some(crate::types::CostEstimate { usd })
    }
}

/// Apply an optional bearer token (local runtimes often need none).
fn auth(rb: reqwest::RequestBuilder, bearer: Option<&str>) -> reqwest::RequestBuilder {
    match bearer {
        Some(t) => rb.bearer_auth(t),
        None => rb,
    }
}

/// `GET /models` → `ModelInfo`s, tagged with `uses_external` + the given capabilities.
/// Shared by the external OpenAI-compatible adapter and the local llama.cpp / vLLM adapter.
pub(crate) async fn oai_list_models(
    client: &Client,
    base_url: &str,
    bearer: Option<&str>,
    capabilities: &[&str],
    uses_external: bool,
) -> Result<Vec<ModelInfo>> {
    let resp = auth(client.get(format!("{base_url}/models")), bearer)
        .send()
        .await?;
    let value = parse_json(resp).await?;
    let caps: Vec<String> = capabilities.iter().map(|s| s.to_string()).collect();
    let models = value["data"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|m| m["id"].as_str())
                .map(|id| ModelInfo {
                    name: id.to_string(),
                    capabilities: caps.clone(),
                    context_length: None,
                    modalities: vec!["text".into()],
                    uses_external_provider: uses_external,
                })
                .collect()
        })
        .unwrap_or_default();
    Ok(models)
}

/// `GET /models` success check (credential / reachability).
pub(crate) async fn oai_validate(
    client: &Client,
    base_url: &str,
    bearer: Option<&str>,
) -> Result<bool> {
    let resp = auth(client.get(format!("{base_url}/models")), bearer)
        .send()
        .await?;
    Ok(resp.status().is_success())
}

/// `POST /chat/completions` with the normalized request shape.
pub(crate) async fn oai_chat(
    client: &Client,
    base_url: &str,
    bearer: Option<&str>,
    req: ChatRequest,
) -> Result<ChatResponse> {
    let mut body = json!({
        "model": req.model,
        "messages": req.messages,
    });
    if let Some(mt) = req.max_tokens {
        body["max_tokens"] = json!(mt);
    }
    if let Some(t) = req.temperature {
        body["temperature"] = json!(t);
    }

    let resp = auth(client.post(format!("{base_url}/chat/completions")), bearer)
        .json(&body)
        .send()
        .await?;
    let value = parse_json(resp).await?;

    let content = value["choices"][0]["message"]["content"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    let usage = Usage {
        input_tokens: value["usage"]["prompt_tokens"].as_u64().unwrap_or(0),
        output_tokens: value["usage"]["completion_tokens"].as_u64().unwrap_or(0),
        ..Default::default()
    };
    Ok(ChatResponse {
        model: req.model,
        content,
        usage,
    })
}

/// Read a response, mapping non-2xx into a [`Error::ProviderStatus`] with the body.
pub(crate) async fn parse_json(resp: reqwest::Response) -> Result<serde_json::Value> {
    let status = resp.status();
    let text = resp.text().await?;
    if !status.is_success() {
        return Err(Error::ProviderStatus {
            status: status.as_u16(),
            body: crate::vault::redact(&text),
        });
    }
    serde_json::from_str(&text).map_err(Error::from)
}
