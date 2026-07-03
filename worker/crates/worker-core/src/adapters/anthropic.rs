//! Anthropic (Claude) adapter. Distinct wire format: `x-api-key` + `anthropic-version`
//! headers, a `/messages` endpoint, and a separate top-level `system` field.

use async_trait::async_trait;
use reqwest::Client;
use serde_json::json;

use super::openai_compatible::parse_json;
use super::tools::{forced_function_name, function_defs, parse_arguments};
use crate::adapter::ProviderAdapter;
use crate::error::Result;
use crate::types::{
    ChatRequest, ChatResponse, ModelInfo, ToolCall, ToolCallFunction, Usage, VisionRequest,
    VisionResponse,
};
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

    /// Split out an optional leading system message (Anthropic wants it top-level) and map the
    /// rest into Anthropic messages: assistant tool calls become `tool_use` content blocks and
    /// OpenAI `role:"tool"` results become user-message `tool_result` blocks (consecutive tool
    /// results merge into one user message, as the API requires).
    fn split_system(req: &ChatRequest) -> (Option<String>, serde_json::Value) {
        let mut system = None;
        let mut msgs: Vec<serde_json::Value> = Vec::new();
        for m in &req.messages {
            match m.role.as_str() {
                "system" => system = Some(m.content.clone()),
                "assistant" if m.tool_calls.is_some() => {
                    let mut blocks = Vec::new();
                    if !m.content.is_empty() {
                        blocks.push(json!({ "type": "text", "text": m.content }));
                    }
                    for c in m.tool_calls.as_deref().unwrap_or_default() {
                        blocks.push(json!({
                            "type": "tool_use",
                            "id": c.id,
                            "name": c.function.name,
                            "input": parse_arguments(&c.function.arguments),
                        }));
                    }
                    msgs.push(json!({ "role": "assistant", "content": blocks }));
                }
                "tool" => {
                    let block = json!({
                        "type": "tool_result",
                        "tool_use_id": m.tool_call_id.clone().unwrap_or_default(),
                        "content": m.content,
                    });
                    match msgs.last_mut().filter(|l| {
                        l["role"] == "user" && l["content"][0]["type"] == "tool_result"
                    }) {
                        Some(last) => last["content"].as_array_mut().unwrap().push(block),
                        None => msgs.push(json!({ "role": "user", "content": [block] })),
                    }
                }
                _ => msgs.push(json!({ "role": m.role, "content": m.content })),
            }
        }
        (system, json!(msgs))
    }
}

/// OpenAI tool definitions → Anthropic `tools` (`input_schema` instead of `parameters`).
fn anthropic_tools(tools: &serde_json::Value) -> serde_json::Value {
    json!(function_defs(tools)
        .iter()
        .map(|f| json!({
            "name": f.name,
            "description": f.description.unwrap_or_default(),
            "input_schema": f.parameters.cloned().unwrap_or_else(|| json!({ "type": "object" })),
        }))
        .collect::<Vec<_>>())
}

/// OpenAI `tool_choice` → Anthropic `tool_choice`. `"none"` maps to no field (callers should
/// simply not send tools for that case, but a bare auto is the safest fallback).
fn anthropic_tool_choice(choice: &serde_json::Value) -> serde_json::Value {
    if let Some(name) = forced_function_name(choice) {
        return json!({ "type": "tool", "name": name });
    }
    match choice.as_str() {
        Some("required") => json!({ "type": "any" }),
        Some("none") => json!({ "type": "none" }),
        _ => json!({ "type": "auto" }),
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
                            "chat".into(),
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
        if let Some(tools) = &req.tools {
            body["tools"] = anthropic_tools(tools);
            if let Some(choice) = &req.tool_choice {
                body["tool_choice"] = anthropic_tool_choice(choice);
            }
        }

        let resp = self
            .req(self.client.post(format!("{}/messages", self.base_url)))
            .json(&body)
            .send()
            .await?;
        let value = parse_json(resp).await?;

        // Concatenate text blocks; map tool_use blocks back to the OpenAI call shape.
        let mut content = String::new();
        let mut tool_calls = Vec::new();
        for block in value["content"].as_array().map(Vec::as_slice).unwrap_or_default() {
            match block["type"].as_str() {
                Some("text") => content.push_str(block["text"].as_str().unwrap_or_default()),
                Some("tool_use") => tool_calls.push(ToolCall {
                    id: block["id"].as_str().unwrap_or_default().to_string(),
                    kind: "function".to_string(),
                    function: ToolCallFunction {
                        name: block["name"].as_str().unwrap_or_default().to_string(),
                        arguments: block["input"].to_string(),
                    },
                }),
                _ => {}
            }
        }
        let usage = Usage {
            input_tokens: value["usage"]["input_tokens"].as_u64().unwrap_or(0),
            output_tokens: value["usage"]["output_tokens"].as_u64().unwrap_or(0),
            ..Default::default()
        };
        Ok(ChatResponse {
            model: req.model,
            content,
            tool_calls: (!tool_calls.is_empty()).then_some(tool_calls),
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
