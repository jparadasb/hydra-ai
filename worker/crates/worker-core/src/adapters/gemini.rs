//! Google Gemini adapter. Auth via `x-goog-api-key` header; `:generateContent` endpoint with
//! a `contents`/`parts` body shape distinct from the OpenAI format.

use async_trait::async_trait;
use reqwest::Client;
use serde_json::json;

use super::openai_compatible::parse_json;
use super::tools::{forced_function_name, function_defs, parse_arguments};
use crate::adapter::{DeltaSink, ProviderAdapter};
use crate::error::{Error, Result};
use crate::retry::RetryExt;
use crate::types::{ChatRequest, ChatResponse, ModelInfo, ToolCall, ToolCallFunction, Usage};
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
            .send_retried()
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
                        // `image.describe` is deliberately absent: this adapter implements no
                        // `run_vision_task`, so the trait default answers "does not support
                        // vision tasks" — advertising it made the coordinator route jobs that
                        // were guaranteed to fail. The models can do vision; this adapter
                        // cannot yet, and the advertisement has to match the adapter.
                        capabilities: vec!["chat".into(), "text.extract_json".into()],
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
            .header("x-goog-api-key", self.token.expose())
            .send_retried()
            .await?;
        Ok(resp.status().is_success())
    }

    async fn run_chat_completion(&self, req: ChatRequest) -> Result<ChatResponse> {
        let body = build_generate_content_body(&req);
        let url = format!("{}/models/{}:generateContent", self.base_url, req.model);
        let resp = self
            .client
            .post(url)
            .header("x-goog-api-key", self.token.expose())
            .json(&body)
            .send_retried()
            .await?;
        let value = parse_json(resp).await?;
        Ok(parse_generate_content_response(&value, req.model))
    }

    /// Gemini streams through `:streamGenerateContent?alt=sse`, emitting the same
    /// `generateContent` response shape once per chunk rather than once at the end. Each
    /// carries the new text parts; the last carries `usageMetadata`.
    async fn run_chat_completion_streaming(
        &self,
        req: ChatRequest,
        on_delta: DeltaSink,
    ) -> Result<ChatResponse> {
        let body = build_generate_content_body(&req);
        let url = format!(
            "{}/models/{}:streamGenerateContent?alt=sse",
            self.base_url, req.model
        );

        let resp = self
            .client
            .post(url)
            .header("x-goog-api-key", self.token.expose())
            .json(&body)
            .send_retried()
            .await?;

        stream_generate_content(resp, req.model, on_delta).await
    }
}

/// Consume a `streamGenerateContent?alt=sse` response into one [`ChatResponse`], forwarding
/// text as it arrives. Shared with the Code Assist (OAuth) adapter, which streams the same
/// chunk shape inside its own envelope.
pub(crate) async fn stream_generate_content(
    resp: reqwest::Response,
    model: String,
    on_delta: DeltaSink,
) -> Result<ChatResponse> {
    use futures_util::StreamExt;

    let status = resp.status();
    if !status.is_success() {
        let text = resp.text().await?;
        return Err(Error::ProviderStatus {
            status: status.as_u16(),
            body: crate::vault::redact(&text),
        });
    }

    let mut assembly = GeminiStream::default();
    let mut stream = resp.bytes_stream();
    let mut buf = String::new();

    while let Some(chunk) = stream.next().await {
        buf.push_str(&String::from_utf8_lossy(&chunk?));
        while let Some(pos) = buf.find('\n') {
            let line: String = buf.drain(..=pos).collect();
            assembly.feed_line(line.trim_end(), on_delta.as_ref());
        }
    }

    Ok(assembly.finish(model))
}

/// Incremental state for one streamed Gemini generation. Pure — fed SSE lines, no I/O.
#[derive(Default)]
pub(crate) struct GeminiStream {
    content: String,
    tool_calls: Vec<ToolCall>,
    usage: Usage,
}

impl GeminiStream {
    pub(crate) fn feed_line(&mut self, line: &str, on_delta: &(dyn Fn(&str, bool) + Send + Sync)) {
        let Some(data) = line.strip_prefix("data: ") else {
            return;
        };
        let Ok(value) = serde_json::from_str::<serde_json::Value>(data) else {
            return;
        };

        self.feed_value(&value, on_delta);
    }

    /// Fold one decoded chunk. Separate from `feed_line` because the Code Assist adapter
    /// receives this same shape wrapped in a `response` envelope.
    pub(crate) fn feed_value(
        &mut self,
        value: &serde_json::Value,
        on_delta: &(dyn Fn(&str, bool) + Send + Sync),
    ) {
        for part in value["candidates"][0]["content"]["parts"]
            .as_array()
            .map(Vec::as_slice)
            .unwrap_or_default()
        {
            if let Some(text) = part["text"].as_str() {
                if !text.is_empty() {
                    self.content.push_str(text);
                    on_delta(text, false);
                }
            }

            // Function calls arrive whole rather than as fragments.
            if let Some(call) = part.get("functionCall").filter(|c| !c.is_null()) {
                self.tool_calls.push(ToolCall {
                    id: format!("call_{}", self.tool_calls.len()),
                    kind: "function".to_string(),
                    function: ToolCallFunction {
                        name: call["name"].as_str().unwrap_or_default().to_string(),
                        arguments: call["args"].to_string(),
                    },
                });
            }
        }

        // Every chunk may restate the running totals; the last one wins. Absent stays absent.
        if let Some(input) = value["usageMetadata"]["promptTokenCount"].as_u64() {
            self.usage.input_tokens = Some(input);
        }
        if let Some(output) = value["usageMetadata"]["candidatesTokenCount"].as_u64() {
            self.usage.output_tokens = Some(output);
        }
    }

    pub(crate) fn finish(self, model: String) -> ChatResponse {
        ChatResponse {
            model,
            content: self.content,
            tool_calls: (!self.tool_calls.is_empty()).then_some(self.tool_calls),
            usage: self.usage,
        }
    }
}

/// Build a Gemini `generateContent` request body from a normalized chat request.
/// Roles map to "user"/"model"; "system" becomes `systemInstruction`; assistant tool calls
/// become `functionCall` parts and OpenAI `role:"tool"` results become `functionResponse`
/// parts (matched to their call's function name via `tool_call_id`, since Gemini has no call
/// ids). Shared with the Code Assist (OAuth) adapter, which wraps this same body in its own
/// envelope.
pub(crate) fn build_generate_content_body(req: &ChatRequest) -> serde_json::Value {
    // tool_call_id → function name, so tool results can name the function they answer.
    let mut call_names = std::collections::HashMap::new();
    for m in &req.messages {
        for c in m.tool_calls.as_deref().unwrap_or_default() {
            call_names.insert(c.id.as_str(), c.function.name.as_str());
        }
    }

    let mut contents = Vec::new();
    let mut system = None;
    for m in &req.messages {
        let text = m.content.text();
        match m.role.as_str() {
            "system" => system = Some(text.clone()),
            "assistant" | "model" => {
                let mut parts = Vec::new();
                if !m.content.is_empty() {
                    parts.push(json!({ "text": m.content }));
                }
                for c in m.tool_calls.as_deref().unwrap_or_default() {
                    parts.push(json!({ "functionCall": {
                        "name": c.function.name,
                        "args": parse_arguments(&c.function.arguments),
                    }}));
                }
                if parts.is_empty() {
                    parts.push(json!({ "text": "" }));
                }
                contents.push(json!({ "role": "model", "parts": parts }));
            }
            "tool" => {
                let name = m
                    .tool_call_id
                    .as_deref()
                    .and_then(|id| call_names.get(id).copied())
                    .unwrap_or_default();
                // Gemini wants an object; wrap plain-text results.
                let response = serde_json::from_str::<serde_json::Value>(&text)
                    .ok()
                    .filter(serde_json::Value::is_object)
                    .unwrap_or_else(|| json!({ "result": text }));
                contents.push(json!({
                    "role": "user",
                    "parts": [{ "functionResponse": { "name": name, "response": response } }]
                }));
            }
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
    if let Some(tools) = &req.tools {
        let decls = function_defs(tools)
            .iter()
            .map(|f| {
                let mut d = json!({ "name": f.name });
                if let Some(desc) = f.description {
                    d["description"] = json!(desc);
                }
                if let Some(p) = f.parameters {
                    d["parameters"] = scrub_schema(p);
                }
                d
            })
            .collect::<Vec<_>>();
        body["tools"] = json!([{ "functionDeclarations": decls }]);
        if let Some(choice) = &req.tool_choice {
            body["toolConfig"] = json!({ "functionCallingConfig": gemini_calling_config(choice) });
        }
    }
    body
}

/// Gemini's schema dialect rejects JSON-Schema bookkeeping keys OpenAI clients commonly send.
fn scrub_schema(schema: &serde_json::Value) -> serde_json::Value {
    match schema {
        serde_json::Value::Object(map) => serde_json::Value::Object(
            map.iter()
                .filter(|(k, _)| !matches!(k.as_str(), "additionalProperties" | "$schema"))
                .map(|(k, v)| (k.clone(), scrub_schema(v)))
                .collect(),
        ),
        serde_json::Value::Array(items) => {
            serde_json::Value::Array(items.iter().map(scrub_schema).collect())
        }
        other => other.clone(),
    }
}

/// OpenAI `tool_choice` → Gemini `functionCallingConfig`.
fn gemini_calling_config(choice: &serde_json::Value) -> serde_json::Value {
    if let Some(name) = forced_function_name(choice) {
        return json!({ "mode": "ANY", "allowedFunctionNames": [name] });
    }
    match choice.as_str() {
        Some("required") => json!({ "mode": "ANY" }),
        Some("none") => json!({ "mode": "NONE" }),
        _ => json!({ "mode": "AUTO" }),
    }
}

/// Map a Gemini `generateContent` response body to the normalized chat response.
pub(crate) fn parse_generate_content_response(
    value: &serde_json::Value,
    model: String,
) -> ChatResponse {
    let mut content = String::new();
    let mut tool_calls = Vec::new();
    for part in value["candidates"][0]["content"]["parts"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
    {
        if let Some(text) = part["text"].as_str() {
            content.push_str(text);
        }
        if let Some(call) = part.get("functionCall") {
            // Gemini has no call ids; synthesize stable ones for the OpenAI shape.
            tool_calls.push(ToolCall {
                id: format!("call_{}", tool_calls.len()),
                kind: "function".to_string(),
                function: ToolCallFunction {
                    name: call["name"].as_str().unwrap_or_default().to_string(),
                    arguments: call["args"].to_string(),
                },
            });
        }
    }
    let usage = Usage {
        input_tokens: value["usageMetadata"]["promptTokenCount"].as_u64(),
        output_tokens: value["usageMetadata"]["candidatesTokenCount"].as_u64(),
        ..Default::default()
    };
    ChatResponse {
        model,
        content,
        tool_calls: (!tool_calls.is_empty()).then_some(tool_calls),
        usage,
    }
}
