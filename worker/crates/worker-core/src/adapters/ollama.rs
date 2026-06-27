//! Ollama adapter — a local runtime. `uses_external_provider() == false`: privacy-safe for
//! every job level. Talks to the local Ollama HTTP endpoint (default `127.0.0.1:11434`).

use async_trait::async_trait;
use reqwest::Client;
use serde_json::json;

use super::openai_compatible::parse_json;
use crate::adapter::ProviderAdapter;
use crate::error::Result;
use crate::types::{ChatRequest, ChatResponse, ModelInfo, Usage};

pub const DEFAULT_ENDPOINT: &str = "http://127.0.0.1:11434";

pub struct OllamaAdapter {
    endpoint: String,
    client: Client,
}

impl OllamaAdapter {
    pub fn new(client: Client) -> Self {
        Self::with_endpoint(DEFAULT_ENDPOINT, client)
    }

    pub fn with_endpoint(endpoint: impl Into<String>, client: Client) -> Self {
        Self {
            endpoint: endpoint.into().trim_end_matches('/').to_string(),
            client,
        }
    }
}

#[async_trait]
impl ProviderAdapter for OllamaAdapter {
    fn name(&self) -> &str {
        "ollama"
    }

    fn uses_external_provider(&self) -> bool {
        false
    }

    async fn list_models(&self) -> Result<Vec<ModelInfo>> {
        let resp = self
            .client
            .get(format!("{}/api/tags", self.endpoint))
            .send()
            .await?;
        let value = parse_json(resp).await?;
        let models = value["models"]
            .as_array()
            .map(|arr| {
                arr.iter()
                    .filter_map(|m| m["name"].as_str())
                    .map(|name| ModelInfo {
                        name: name.to_string(),
                        capabilities: vec![
                            "text.extract_json".into(),
                            "ocr.extract".into(),
                            "image.describe".into(),
                        ],
                        context_length: None,
                        modalities: vec!["text".into()],
                        uses_external_provider: false,
                    })
                    .collect()
            })
            .unwrap_or_default();
        Ok(models)
    }

    async fn validate_credentials(&self) -> Result<bool> {
        // No credentials; "valid" means the runtime is reachable.
        let resp = self
            .client
            .get(format!("{}/api/tags", self.endpoint))
            .send()
            .await?;
        Ok(resp.status().is_success())
    }

    async fn run_chat_completion(&self, req: ChatRequest) -> Result<ChatResponse> {
        let body = json!({
            "model": req.model,
            "messages": req.messages,
            "stream": false,
        });
        let resp = self
            .client
            .post(format!("{}/api/chat", self.endpoint))
            .json(&body)
            .send()
            .await?;
        let value = parse_json(resp).await?;

        let content = value["message"]["content"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        let usage = Usage {
            input_tokens: value["prompt_eval_count"].as_u64().unwrap_or(0),
            output_tokens: value["eval_count"].as_u64().unwrap_or(0),
            ..Default::default()
        };
        Ok(ChatResponse {
            model: req.model,
            content,
            usage,
        })
    }
}
