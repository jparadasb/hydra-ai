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
        let resp = self
            .client
            .get(format!("{}/models", self.base_url))
            .bearer_auth(self.token.expose())
            .send()
            .await?;
        let value = parse_json(resp).await?;
        let models = value["data"]
            .as_array()
            .map(|arr| {
                arr.iter()
                    .filter_map(|m| m["id"].as_str())
                    .map(|id| ModelInfo {
                        name: id.to_string(),
                        capabilities: vec!["text.clean".into(), "text.extract_json".into()],
                        context_length: None,
                        modalities: vec!["text".into()],
                        uses_external_provider: true,
                    })
                    .collect()
            })
            .unwrap_or_default();
        Ok(models)
    }

    async fn validate_credentials(&self) -> Result<bool> {
        let resp = self
            .client
            .get(format!("{}/models", self.base_url))
            .bearer_auth(self.token.expose())
            .send()
            .await?;
        Ok(resp.status().is_success())
    }

    async fn run_chat_completion(&self, req: ChatRequest) -> Result<ChatResponse> {
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

        let resp = self
            .client
            .post(format!("{}/chat/completions", self.base_url))
            .bearer_auth(self.token.expose())
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

    fn estimate_cost(&self, usage: &Usage) -> Option<crate::types::CostEstimate> {
        let p = self.pricing.as_ref()?;
        let usd = (usage.input_tokens as f64 / 1_000_000.0) * p.input_per_1m_usd
            + (usage.output_tokens as f64 / 1_000_000.0) * p.output_per_1m_usd;
        Some(crate::types::CostEstimate { usd })
    }
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
