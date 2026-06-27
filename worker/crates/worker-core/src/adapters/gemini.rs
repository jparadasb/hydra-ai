//! Google Gemini adapter. Auth via `x-goog-api-key` header; `:generateContent` endpoint with
//! a `contents`/`parts` body shape distinct from the OpenAI format.

use async_trait::async_trait;
use reqwest::Client;
use serde_json::json;

use super::openai_compatible::parse_json;
use crate::adapter::ProviderAdapter;
use crate::error::Result;
use crate::types::{ChatRequest, ChatResponse, ModelInfo, Usage};
use crate::vault::Secret;

const DEFAULT_BASE: &str = "https://generativelanguage.googleapis.com/v1beta";

pub struct GeminiAdapter {
    base_url: String,
    token: Secret,
    client: Client,
}

impl GeminiAdapter {
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
}

#[async_trait]
impl ProviderAdapter for GeminiAdapter {
    fn name(&self) -> &str {
        "gemini"
    }

    fn uses_external_provider(&self) -> bool {
        true
    }

    async fn list_models(&self) -> Result<Vec<ModelInfo>> {
        let resp = self
            .client
            .get(format!("{}/models", self.base_url))
            .header("x-goog-api-key", self.token.expose())
            .send()
            .await?;
        let value = parse_json(resp).await?;
        let models = value["models"]
            .as_array()
            .map(|arr| {
                arr.iter()
                    .filter_map(|m| m["name"].as_str())
                    .map(|name| ModelInfo {
                        // names come back as "models/gemini-1.5-flash"
                        name: name.trim_start_matches("models/").to_string(),
                        capabilities: vec!["text.extract_json".into(), "image.describe".into()],
                        context_length: None,
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
            .client
            .get(format!("{}/models", self.base_url))
            .header("x-goog-api-key", self.token.expose())
            .send()
            .await?;
        Ok(resp.status().is_success())
    }

    async fn run_chat_completion(&self, req: ChatRequest) -> Result<ChatResponse> {
        // Map roles: Gemini uses "user"/"model"; "system" → systemInstruction.
        let mut contents = Vec::new();
        let mut system = None;
        for m in &req.messages {
            match m.role.as_str() {
                "system" => system = Some(m.content.clone()),
                "assistant" | "model" => contents.push(json!({
                    "role": "model", "parts": [{ "text": m.content }]
                })),
                _ => contents.push(json!({
                    "role": "user", "parts": [{ "text": m.content }]
                })),
            }
        }
        let mut body = json!({ "contents": contents });
        if let Some(s) = system {
            body["systemInstruction"] = json!({ "parts": [{ "text": s }] });
        }
        if let Some(mt) = req.max_tokens {
            body["generationConfig"] = json!({ "maxOutputTokens": mt });
        }

        let url = format!("{}/models/{}:generateContent", self.base_url, req.model);
        let resp = self
            .client
            .post(url)
            .header("x-goog-api-key", self.token.expose())
            .json(&body)
            .send()
            .await?;
        let value = parse_json(resp).await?;

        let content = value["candidates"][0]["content"]["parts"][0]["text"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        let usage = Usage {
            input_tokens: value["usageMetadata"]["promptTokenCount"]
                .as_u64()
                .unwrap_or(0),
            output_tokens: value["usageMetadata"]["candidatesTokenCount"]
                .as_u64()
                .unwrap_or(0),
            ..Default::default()
        };
        Ok(ChatResponse {
            model: req.model,
            content,
            usage,
        })
    }
}
