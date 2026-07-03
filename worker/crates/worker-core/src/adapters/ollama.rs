//! Ollama adapter — a local runtime. `uses_external_provider() == false`: privacy-safe for
//! every job level. Talks to the local Ollama HTTP endpoint (default `127.0.0.1:11434`).

use async_trait::async_trait;
use reqwest::Client;
use serde_json::json;

use super::openai_compatible::parse_json;
use super::tools::parse_arguments;
use crate::adapter::ProviderAdapter;
use crate::error::Result;
use crate::types::{ChatRequest, ChatResponse, ModelInfo, ToolCall, ToolCallFunction, Usage};

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
                            "chat".into(),
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
        let mut body = json!({
            "model": req.model,
            "messages": build_messages(&req),
            "stream": false,
        });
        // Ollama takes OpenAI-shaped tool definitions verbatim (it has no tool_choice knob).
        if let Some(tools) = &req.tools {
            body["tools"] = tools.clone();
        }
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
        let tool_calls = parse_tool_calls(&value["message"]["tool_calls"]);
        let usage = Usage {
            input_tokens: value["prompt_eval_count"].as_u64().unwrap_or(0),
            output_tokens: value["eval_count"].as_u64().unwrap_or(0),
            ..Default::default()
        };
        Ok(ChatResponse {
            model: req.model,
            content,
            tool_calls,
            usage,
        })
    }
}

/// Ollama's message shape differs from OpenAI's in one spot: tool-call `arguments` is a JSON
/// *object*, not an encoded string. It also has no call ids, so `tool_call_id` is dropped on
/// the way in (tool results follow their call by position).
fn build_messages(req: &ChatRequest) -> Vec<serde_json::Value> {
    req.messages
        .iter()
        .map(|m| {
            let mut msg = json!({ "role": m.role, "content": m.content });
            if let Some(calls) = &m.tool_calls {
                msg["tool_calls"] = json!(calls
                    .iter()
                    .map(|c| json!({
                        "function": {
                            "name": c.function.name,
                            "arguments": parse_arguments(&c.function.arguments),
                        }
                    }))
                    .collect::<Vec<_>>());
            }
            msg
        })
        .collect()
}

/// Map Ollama tool calls back to the OpenAI shape, synthesizing the ids Ollama doesn't have.
fn parse_tool_calls(value: &serde_json::Value) -> Option<Vec<ToolCall>> {
    let calls: Vec<ToolCall> = value
        .as_array()?
        .iter()
        .enumerate()
        .filter_map(|(i, c)| {
            let f = &c["function"];
            Some(ToolCall {
                id: format!("call_{i}"),
                kind: "function".to_string(),
                function: ToolCallFunction {
                    name: f["name"].as_str()?.to_string(),
                    arguments: f["arguments"].to_string(),
                },
            })
        })
        .collect();
    (!calls.is_empty()).then_some(calls)
}
