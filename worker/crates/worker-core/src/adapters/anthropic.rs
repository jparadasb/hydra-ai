//! Anthropic (Claude) adapter. Distinct wire format: `x-api-key` + `anthropic-version`
//! headers, a `/messages` endpoint, and a separate top-level `system` field.

use async_trait::async_trait;
use reqwest::Client;
use serde_json::json;

use super::openai_compatible::parse_json;
use super::tools::{forced_function_name, function_defs, parse_arguments};
use crate::adapter::{DeltaSink, ProviderAdapter};
use crate::error::{Error, Result};
use crate::retry::RetryExt;
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

    /// The `/messages` request body. Shared so the streaming path cannot drift from the
    /// blocking one — they must send the same request, differing only in `stream`.
    fn message_body(req: &ChatRequest) -> serde_json::Value {
        let (system, messages) = Self::split_system(req);
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
        body
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
                "system" => system = Some(m.content.text()),
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
                    // The filter checks `content[0]`, which indexing a non-array also answers
                    // — so `as_array_mut` was not guaranteed to be `Some` and the unwrap was a
                    // panic waiting for a malformed history. Start a new message instead.
                    let merged = msgs
                        .last_mut()
                        .filter(|l| l["role"] == "user" && l["content"][0]["type"] == "tool_result")
                        .and_then(|last| last["content"].as_array_mut())
                        .map(|blocks| blocks.push(block.clone()))
                        .is_some();

                    if !merged {
                        msgs.push(json!({ "role": "user", "content": [block] }));
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
            .send_retried()
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
            .send_retried()
            .await?;
        Ok(resp.status().is_success())
    }

    async fn run_chat_completion(&self, req: ChatRequest) -> Result<ChatResponse> {
        let body = Self::message_body(&req);

        let resp = self
            .req(self.client.post(format!("{}/messages", self.base_url)))
            .json(&body)
            .send_retried()
            .await?;
        let value = parse_json(resp).await?;

        // Concatenate text blocks; map tool_use blocks back to the OpenAI call shape.
        let mut content = String::new();
        let mut tool_calls = Vec::new();
        for block in value["content"]
            .as_array()
            .map(Vec::as_slice)
            .unwrap_or_default()
        {
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
            input_tokens: value["usage"]["input_tokens"].as_u64(),
            output_tokens: value["usage"]["output_tokens"].as_u64(),
            ..Default::default()
        };
        Ok(ChatResponse {
            model: req.model,
            content,
            tool_calls: (!tool_calls.is_empty()).then_some(tool_calls),
            usage,
        })
    }

    /// Anthropic streams SSE with a different event vocabulary from OpenAI's: text arrives as
    /// `content_block_delta` with a `text_delta`, tool arguments as `input_json_delta`
    /// fragments that have to be reassembled per block index, and token counts are split
    /// across `message_start` (input) and `message_delta` (output).
    ///
    /// Without this the trait default ran the blocking call, so a caller streaming against
    /// Anthropic waited in silence and then got the whole answer at once.
    async fn run_chat_completion_streaming(
        &self,
        req: ChatRequest,
        on_delta: DeltaSink,
    ) -> Result<ChatResponse> {
        use futures_util::StreamExt;

        let mut body = Self::message_body(&req);
        body["stream"] = json!(true);

        let resp = self
            .req(self.client.post(format!("{}/messages", self.base_url)))
            .json(&body)
            .send_retried()
            .await?;

        let status = resp.status();
        if !status.is_success() {
            let text = resp.text().await?;
            return Err(Error::ProviderStatus {
                status: status.as_u16(),
                body: crate::vault::redact(&text),
            });
        }

        let mut assembly = AnthropicStream::default();
        let mut stream = resp.bytes_stream();
        let mut buf = String::new();

        while let Some(chunk) = stream.next().await {
            buf.push_str(&String::from_utf8_lossy(&chunk?));
            while let Some(pos) = buf.find('\n') {
                let line: String = buf.drain(..=pos).collect();
                assembly.feed_line(line.trim_end(), on_delta.as_ref());
            }
        }

        Ok(assembly.finish(req.model))
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
            .send_retried()
            .await?;
        let value = parse_json(resp).await?;
        Ok(VisionResponse {
            model: req.model,
            content: value["content"][0]["text"]
                .as_str()
                .unwrap_or_default()
                .to_string(),
            usage: Usage {
                input_tokens: value["usage"]["input_tokens"].as_u64(),
                output_tokens: value["usage"]["output_tokens"].as_u64(),
                image_units: req.images.len() as u64,
                ..Default::default()
            },
        })
    }
}

/// Incremental state for one streamed Anthropic message. Pure — fed SSE lines, no I/O.
#[derive(Default)]
struct AnthropicStream {
    content: String,
    /// Per content-block index: the tool id/name from `content_block_start`, plus the JSON
    /// argument fragments that arrive afterwards and have to be concatenated.
    blocks: Vec<(String, String, String)>,
    usage: Usage,
}

impl AnthropicStream {
    fn feed_line(&mut self, line: &str, on_delta: &(dyn Fn(&str, bool) + Send + Sync)) {
        let Some(data) = line.strip_prefix("data: ") else {
            return; // event:/comment/blank lines
        };
        let Ok(value) = serde_json::from_str::<serde_json::Value>(data) else {
            return;
        };

        match value["type"].as_str() {
            Some("message_start") => {
                self.usage.input_tokens = value["message"]["usage"]["input_tokens"].as_u64();
            }

            Some("content_block_start") => {
                let idx = value["index"].as_u64().unwrap_or(0) as usize;
                if self.blocks.len() <= idx {
                    self.blocks.resize(idx + 1, Default::default());
                }
                let block = &value["content_block"];
                if block["type"] == "tool_use" {
                    self.blocks[idx].0 = block["id"].as_str().unwrap_or_default().to_string();
                    self.blocks[idx].1 = block["name"].as_str().unwrap_or_default().to_string();
                }
            }

            Some("content_block_delta") => {
                let idx = value["index"].as_u64().unwrap_or(0) as usize;
                let delta = &value["delta"];

                match delta["type"].as_str() {
                    Some("text_delta") => {
                        if let Some(text) = delta["text"].as_str() {
                            if !text.is_empty() {
                                self.content.push_str(text);
                                on_delta(text, false);
                            }
                        }
                    }
                    // Extended thinking: streamed for live display, never mixed into the answer.
                    Some("thinking_delta") => {
                        if let Some(text) = delta["thinking"].as_str() {
                            if !text.is_empty() {
                                on_delta(text, true);
                            }
                        }
                    }
                    Some("input_json_delta") => {
                        if self.blocks.len() <= idx {
                            self.blocks.resize(idx + 1, Default::default());
                        }
                        if let Some(fragment) = delta["partial_json"].as_str() {
                            self.blocks[idx].2.push_str(fragment);
                        }
                    }
                    _ => {}
                }
            }

            // The output count arrives here, at the end, rather than with the input count.
            Some("message_delta") => {
                if let Some(output) = value["usage"]["output_tokens"].as_u64() {
                    self.usage.output_tokens = Some(output);
                }
            }

            _ => {}
        }
    }

    fn finish(self, model: String) -> ChatResponse {
        let tool_calls: Vec<ToolCall> = self
            .blocks
            .into_iter()
            .filter(|(id, name, _)| !id.is_empty() || !name.is_empty())
            .map(|(id, name, arguments)| ToolCall {
                id,
                kind: "function".to_string(),
                function: ToolCallFunction {
                    name,
                    // An empty-argument tool call still has to be valid JSON downstream.
                    arguments: if arguments.is_empty() {
                        "{}".to_string()
                    } else {
                        arguments
                    },
                },
            })
            .collect();

        ChatResponse {
            model,
            content: self.content,
            tool_calls: (!tool_calls.is_empty()).then_some(tool_calls),
            usage: self.usage,
        }
    }
}
