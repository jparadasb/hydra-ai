//! Anthropic (Claude) adapter. Distinct wire format: `x-api-key` + `anthropic-version`
//! headers, a `/messages` endpoint, and a separate top-level `system` field.

use async_trait::async_trait;
use reqwest::Client;
use serde_json::json;

use super::openai_compatible::parse_json;
use crate::adapter::ProviderAdapter;
use crate::error::Result;
use crate::types::{ChatRequest, ChatResponse, ModelInfo, Usage, VisionRequest, VisionResponse};
use crate::vault::Secret;

const API_VERSION: &str = "2023-06-01";
const DEFAULT_BASE: &str = "https://api.anthropic.com/v1";

pub struct AnthropicAdapter {
    base_url: String,
    token: Secret,
    client: Client,
}

impl AnthropicAdapter {
    pub fn new(token: Secret, client: Client) -> Self {
        Self::with_base_url(DEFAULT_BASE, token, client)
    }

    pub fn with_base_url(base_url: impl Into<String>, token: Secret, client: Client) -> Self {
        Self {
            base_url: base_url.into().trim_end_matches('/').to_string(),
            token,
            client,
        }
    }

    fn req(&self, builder: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        builder
            .header("x-api-key", self.token.expose())
            .header("anthropic-version", API_VERSION)
    }

    /// Split out an optional leading system message; Anthropic wants it top-level.
    fn split_system(req: &ChatRequest) -> (Option<String>, serde_json::Value) {
        let mut system = None;
        let mut msgs = Vec::new();
        for m in &req.messages {
            if m.role == "system" {
                system = Some(m.content.clone());
            } else {
                msgs.push(json!({ "role": m.role, "content": m.content }));
            }
        }
        (system, json!(msgs))
    }
}

#[async_trait]
impl ProviderAdapter for AnthropicAdapter {
    fn name(&self) -> &str {
        "anthropic"
    }

    fn uses_external_provider(&self) -> bool {
        true
    }

    async fn list_models(&self) -> Result<Vec<ModelInfo>> {
        let resp = self
            .req(self.client.get(format!("{}/models", self.base_url)))
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
                        capabilities: vec![
                            "text.clean".into(),
                            "text.extract_json".into(),
                            "image.describe".into(),
                        ],
                        context_length: Some(200_000),
                        modalities: vec!["text".into(), "image".into()],
                        uses_external_provider: true,
                    })
                    .collect()
            })
            .unwrap_or_default();
        Ok(models)
    }

    async fn validate_credentials(&self) -> Result<bool> {
        let resp = self
            .req(self.client.get(format!("{}/models", self.base_url)))
            .send()
            .await?;
        Ok(resp.status().is_success())
    }

    async fn run_chat_completion(&self, req: ChatRequest) -> Result<ChatResponse> {
        let (system, messages) = Self::split_system(&req);
        let mut body = json!({
            "model": req.model,
            "max_tokens": req.max_tokens.unwrap_or(1024),
            "messages": messages,
        });
        if let Some(s) = system {
            body["system"] = json!(s);
        }
        if let Some(t) = req.temperature {
            body["temperature"] = json!(t);
        }

        let resp = self
            .req(self.client.post(format!("{}/messages", self.base_url)))
            .json(&body)
            .send()
            .await?;
        let value = parse_json(resp).await?;

        let content = value["content"][0]["text"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        let usage = Usage {
            input_tokens: value["usage"]["input_tokens"].as_u64().unwrap_or(0),
            output_tokens: value["usage"]["output_tokens"].as_u64().unwrap_or(0),
            ..Default::default()
        };
        Ok(ChatResponse {
            model: req.model,
            content,
            usage,
        })
    }

    async fn run_vision_task(&self, req: VisionRequest) -> Result<VisionResponse> {
        let mut parts = vec![json!({ "type": "text", "text": req.prompt })];
        for img in &req.images {
            parts.push(json!({
                "type": "image",
                "source": { "type": "base64", "media_type": "image/png", "data": img }
            }));
        }
        let body = json!({
            "model": req.model,
            "max_tokens": req.max_tokens.unwrap_or(1024),
            "messages": [{ "role": "user", "content": parts }],
        });
        let resp = self
            .req(self.client.post(format!("{}/messages", self.base_url)))
            .json(&body)
            .send()
            .await?;
        let value = parse_json(resp).await?;
        Ok(VisionResponse {
            model: req.model,
            content: value["content"][0]["text"]
                .as_str()
                .unwrap_or_default()
                .to_string(),
            usage: Usage {
                input_tokens: value["usage"]["input_tokens"].as_u64().unwrap_or(0),
                output_tokens: value["usage"]["output_tokens"].as_u64().unwrap_or(0),
                image_units: req.images.len() as u64,
                ..Default::default()
            },
        })
    }
}
