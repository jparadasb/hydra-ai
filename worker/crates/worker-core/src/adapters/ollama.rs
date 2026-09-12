//! Ollama adapter — a local runtime. `uses_external_provider() == false`: privacy-safe for
//! every job level. Talks to the local Ollama HTTP endpoint (default `127.0.0.1:11434`).

use async_trait::async_trait;
use reqwest::Client;
use serde_json::json;

use super::openai_compatible::parse_json;
use super::tools::parse_arguments;
use crate::adapter::{DeltaSink, ProviderAdapter};
use crate::error::{Error, Result};
use crate::retry::RetryExt;
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
            .send_retried()
            .await?;
        let value = parse_json(resp).await?;
        let models = value["models"]
            .as_array()
            .map(|arr| {
                arr.iter()
                    .filter_map(|m| m["name"].as_str().map(|name| (name, m)))
                    .map(|(name, m)| {
                        let vision = is_vision_model(name, m);
                        let mut modalities = vec!["text".to_string()];
                        if vision {
                            modalities.push("image".into());
                        }

                        ModelInfo {
                            name: name.to_string(),
                            capabilities: capabilities_for(vision),
                            context_length: None,
                            modalities,
                            uses_external_provider: false,
                        }
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
            .send_retried()
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
            .send_retried()
            .await?;
        let value = parse_json(resp).await?;

        let content = value["message"]["content"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        let tool_calls = parse_tool_calls(&value["message"]["tool_calls"]);
        let usage = Usage {
            input_tokens: value["prompt_eval_count"].as_u64(),
            output_tokens: value["eval_count"].as_u64(),
            ..Default::default()
        };
        Ok(ChatResponse {
            model: req.model,
            content,
            tool_calls,
            usage,
        })
    }

    /// Ollama streams newline-delimited JSON rather than SSE: one object per line, each with a
    /// `message.content` fragment, and a final `done` object carrying the token counts.
    ///
    /// Without this the trait default ran the blocking call, so a caller streaming against
    /// Ollama waited in silence and then received the whole answer at once, with nothing
    /// indicating the backend had not streamed.
    async fn run_chat_completion_streaming(
        &self,
        req: ChatRequest,
        on_delta: DeltaSink,
    ) -> Result<ChatResponse> {
        use futures_util::StreamExt;

        let mut body = json!({
            "model": req.model,
            "messages": build_messages(&req),
            "stream": true,
        });
        if let Some(tools) = &req.tools {
            body["tools"] = tools.clone();
        }

        let resp = self
            .client
            .post(format!("{}/api/chat", self.endpoint))
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

        let mut assembly = NdjsonAssembly::default();
        let mut stream = resp.bytes_stream();
        let mut buf = String::new();

        while let Some(chunk) = stream.next().await {
            buf.push_str(&String::from_utf8_lossy(&chunk?));
            while let Some(pos) = buf.find('\n') {
                let line: String = buf.drain(..=pos).collect();
                assembly.feed_line(line.trim_end(), on_delta.as_ref());
            }
        }
        // A final object need not be newline-terminated.
        if !buf.trim().is_empty() {
            assembly.feed_line(buf.trim(), on_delta.as_ref());
        }

        Ok(assembly.finish(req.model))
    }
}

/// Capabilities a model can actually serve. Every model used to advertise `ocr.extract` and
/// `image.describe`, text-only ones included, so the coordinator routed vision jobs to models
/// guaranteed to fail them.
fn capabilities_for(vision: bool) -> Vec<String> {
    let mut caps = vec!["chat".to_string(), "text.extract_json".to_string()];
    if vision {
        caps.push("ocr.extract".into());
        caps.push("image.describe".into());
    }
    caps
}

/// Ollama reports a model's architecture families in `/api/tags`; a vision model carries a
/// projector family such as `clip` or `mllama` alongside its text family. The name check is a
/// fallback for older servers that omit `details`.
fn is_vision_model(name: &str, meta: &serde_json::Value) -> bool {
    const VISION_FAMILIES: [&str; 4] = ["clip", "mllama", "qwen2vl", "gemma3"];
    const VISION_NAMES: [&str; 6] = [
        "llava",
        "bakllava",
        "moondream",
        "vision",
        "-vl",
        "minicpm-v",
    ];

    let families = meta["details"]["families"]
        .as_array()
        .map(|f| {
            f.iter()
                .filter_map(|v| v.as_str())
                .any(|fam| VISION_FAMILIES.iter().any(|v| fam.eq_ignore_ascii_case(v)))
        })
        .unwrap_or(false);

    let lowered = name.to_ascii_lowercase();
    families || VISION_NAMES.iter().any(|v| lowered.contains(v))
}

/// Incremental state for one streamed Ollama completion. Pure — fed NDJSON lines, no I/O.
#[derive(Default)]
struct NdjsonAssembly {
    content: String,
    tool_calls: Option<Vec<ToolCall>>,
    usage: Usage,
}

impl NdjsonAssembly {
    fn feed_line(&mut self, line: &str, on_delta: &(dyn Fn(&str, bool) + Send + Sync)) {
        let Ok(value) = serde_json::from_str::<serde_json::Value>(line) else {
            return;
        };

        if let Some(text) = value["message"]["content"].as_str() {
            if !text.is_empty() {
                self.content.push_str(text);
                on_delta(text, false);
            }
        }

        // Ollama emits tool calls whole, on one object, rather than as fragments.
        if let Some(calls) = parse_tool_calls(&value["message"]["tool_calls"]) {
            self.tool_calls = Some(calls);
        }

        // The closing object carries the counts. Absent stays absent: a stream that ends
        // without them reported nothing, which is not a measurement of zero.
        if value["done"].as_bool() == Some(true) {
            self.usage.input_tokens = value["prompt_eval_count"].as_u64();
            self.usage.output_tokens = value["eval_count"].as_u64();
        }
    }

    fn finish(self, model: String) -> ChatResponse {
        ChatResponse {
            model,
            content: self.content,
            tool_calls: self.tool_calls,
            usage: self.usage,
        }
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
