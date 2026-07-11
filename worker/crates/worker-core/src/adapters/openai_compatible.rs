//! OpenAI-compatible adapter. One implementation covers OpenAI, OpenRouter, Groq, Mistral,
//! Together, Fireworks, and any custom `/v1`-style endpoint — they differ only by `base_url`
//! and the bearer token.

use async_trait::async_trait;
use reqwest::Client;
use serde_json::json;

use crate::adapter::{DeltaSink, ProviderAdapter};
use crate::error::{Error, Result};
use crate::types::{ChatRequest, ChatResponse, ModelInfo, ToolCall, Usage};
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

    async fn run_chat_completion_streaming(
        &self,
        req: ChatRequest,
        on_delta: DeltaSink,
    ) -> Result<ChatResponse> {
        oai_chat_stream(
            &self.client,
            &self.base_url,
            Some(self.token.expose()),
            req,
            on_delta,
        )
        .await
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

fn chat_body(req: &ChatRequest) -> serde_json::Value {
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
    if let Some(tools) = &req.tools {
        body["tools"] = tools.clone();
    }
    if let Some(choice) = &req.tool_choice {
        body["tool_choice"] = choice.clone();
    }
    body
}

/// `POST /chat/completions` with the normalized request shape.
pub(crate) async fn oai_chat(
    client: &Client,
    base_url: &str,
    bearer: Option<&str>,
    req: ChatRequest,
) -> Result<ChatResponse> {
    let body = chat_body(&req);
    let resp = auth(client.post(format!("{base_url}/chat/completions")), bearer)
        .json(&body)
        .send()
        .await?;
    let value = parse_json(resp).await?;

    let message = &value["choices"][0]["message"];
    let content = message["content"].as_str().unwrap_or_default().to_string();
    // Same wire shape as ours, so this is a straight decode; absent/empty means no calls.
    let tool_calls = serde_json::from_value::<Vec<ToolCall>>(message["tool_calls"].clone())
        .ok()
        .filter(|calls| !calls.is_empty());
    let usage = Usage {
        input_tokens: value["usage"]["prompt_tokens"].as_u64().unwrap_or(0),
        output_tokens: value["usage"]["completion_tokens"].as_u64().unwrap_or(0),
        ..Default::default()
    };
    Ok(ChatResponse {
        model: req.model,
        content,
        tool_calls,
        usage,
    })
}

/// `POST /chat/completions` with `stream: true`, invoking `on_delta` for each content
/// fragment as it arrives, and assembling the same [`ChatResponse`] `oai_chat` would return.
/// Usage comes from the final usage chunk (`stream_options.include_usage`, honored by
/// OpenAI, llama.cpp and vLLM; other backends just yield zero usage).
pub(crate) async fn oai_chat_stream(
    client: &Client,
    base_url: &str,
    bearer: Option<&str>,
    req: ChatRequest,
    on_delta: DeltaSink,
) -> Result<ChatResponse> {
    use futures_util::StreamExt;

    let mut body = chat_body(&req);
    body["stream"] = json!(true);
    body["stream_options"] = json!({ "include_usage": true });

    let resp = auth(client.post(format!("{base_url}/chat/completions")), bearer)
        .json(&body)
        .send()
        .await?;
    let status = resp.status();
    if !status.is_success() {
        let text = resp.text().await?;
        return Err(Error::ProviderStatus {
            status: status.as_u16(),
            body: crate::vault::redact(&text),
        });
    }

    let mut assembly = StreamAssembly::default();
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

/// Incremental state for one streamed completion: accumulated content, tool-call fragments
/// (keyed by delta `index`), and the trailing usage chunk. Pure — fed SSE lines, no I/O.
#[derive(Default)]
pub(crate) struct StreamAssembly {
    content: String,
    // (id, name, arguments) per tool-call index; streamed deltas set id/name once and
    // append argument fragments.
    calls: Vec<(String, String, String)>,
    usage: Usage,
}

impl StreamAssembly {
    /// Feed one SSE line (`data: {...}` / `data: [DONE]` / keepalives). Content fragments are
    /// forwarded to `on_delta` with `is_reasoning=false`; reasoning/thinking fragments
    /// (`reasoning_content`, or `reasoning`) with `is_reasoning=true`. Reasoning is streamed for
    /// live display but not accumulated into the final answer content.
    pub(crate) fn feed_line(&mut self, line: &str, on_delta: &(dyn Fn(&str, bool) + Send + Sync)) {
        let Some(data) = line.strip_prefix("data: ") else {
            return; // event:/comment/blank lines
        };
        if data == "[DONE]" {
            return;
        }
        let Ok(value) = serde_json::from_str::<serde_json::Value>(data) else {
            return;
        };

        // The usage chunk (empty `choices`) closes an include_usage stream.
        if let Some(u) = value.get("usage").filter(|u| !u.is_null()) {
            self.usage.input_tokens = u["prompt_tokens"].as_u64().unwrap_or(0);
            self.usage.output_tokens = u["completion_tokens"].as_u64().unwrap_or(0);
        }

        let delta = &value["choices"][0]["delta"];
        // Reasoning field name varies by backend: llama.cpp/Qwen/DeepSeek use `reasoning_content`;
        // some (vLLM configs) use `reasoning`. Forward either, live only — never mixed into the
        // answer text.
        for key in ["reasoning_content", "reasoning"] {
            if let Some(text) = delta[key].as_str() {
                if !text.is_empty() {
                    on_delta(text, true);
                }
            }
        }
        if let Some(text) = delta["content"].as_str() {
            if !text.is_empty() {
                self.content.push_str(text);
                on_delta(text, false);
            }
        }
        if let Some(fragments) = delta["tool_calls"].as_array() {
            for frag in fragments {
                let idx = frag["index"].as_u64().unwrap_or(0) as usize;
                if self.calls.len() <= idx {
                    self.calls.resize(idx + 1, Default::default());
                }
                let slot = &mut self.calls[idx];
                if let Some(id) = frag["id"].as_str() {
                    slot.0 = id.to_string();
                }
                if let Some(name) = frag["function"]["name"].as_str() {
                    slot.1 = name.to_string();
                }
                if let Some(args) = frag["function"]["arguments"].as_str() {
                    slot.2.push_str(args);
                }
            }
        }
    }

    pub(crate) fn finish(self, model: String) -> ChatResponse {
        let tool_calls: Vec<ToolCall> = self
            .calls
            .into_iter()
            .filter(|(id, name, _)| !id.is_empty() || !name.is_empty())
            .map(|(id, name, arguments)| ToolCall {
                id,
                kind: "function".to_string(),
                function: crate::types::ToolCallFunction { name, arguments },
            })
            .collect();
        ChatResponse {
            model,
            content: self.content,
            tool_calls: Some(tool_calls).filter(|c| !c.is_empty()),
            usage: self.usage,
        }
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // Captures content deltas only (ignores reasoning), so the content-focused tests below read
    // cleanly. The reasoning test uses its own capturing closure.
    fn feed(assembly: &mut StreamAssembly, lines: &[&str], deltas: &Mutex<Vec<String>>) {
        for line in lines {
            assembly.feed_line(line, &|d: &str, is_reasoning: bool| {
                if !is_reasoning {
                    deltas.lock().unwrap().push(d.to_string());
                }
            });
        }
    }

    #[test]
    fn assembles_streamed_content_and_usage() {
        let deltas = Mutex::new(Vec::new());
        let mut a = StreamAssembly::default();
        feed(
            &mut a,
            &[
                r#"data: {"choices":[{"index":0,"delta":{"role":"assistant"}}]}"#,
                r#"data: {"choices":[{"index":0,"delta":{"content":"Hel"}}]}"#,
                ": keepalive comment",
                r#"data: {"choices":[{"index":0,"delta":{"content":"lo"}}]}"#,
                r#"data: {"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":2}}"#,
                "data: [DONE]",
            ],
            &deltas,
        );
        let resp = a.finish("m".into());
        assert_eq!(resp.content, "Hello");
        assert_eq!(*deltas.lock().unwrap(), vec!["Hel", "lo"]);
        assert_eq!(resp.usage.input_tokens, 7);
        assert_eq!(resp.usage.output_tokens, 2);
        assert!(resp.tool_calls.is_none());
    }

    #[test]
    fn assembles_streamed_tool_call_fragments() {
        let deltas = Mutex::new(Vec::new());
        let mut a = StreamAssembly::default();
        feed(
            &mut a,
            &[
                r#"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"get_weather","arguments":""}}]}}]}"#,
                r#"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":"}}]}}]}"#,
                r#"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Paris\"}"}}]}}]}"#,
                "data: [DONE]",
            ],
            &deltas,
        );
        let resp = a.finish("m".into());
        let calls = resp.tool_calls.expect("tool calls assembled");
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].id, "c1");
        assert_eq!(calls[0].function.name, "get_weather");
        assert_eq!(calls[0].function.arguments, r#"{"city":"Paris"}"#);
        assert!(deltas.lock().unwrap().is_empty());
    }

    #[test]
    fn streams_reasoning_separately_from_content() {
        // Qwen/llama.cpp emit thinking in `reasoning_content` before the answer's `content`.
        let events: Mutex<Vec<(String, bool)>> = Mutex::new(Vec::new());
        let mut a = StreamAssembly::default();
        for line in [
            r#"data: {"choices":[{"index":0,"delta":{"reasoning_content":"Let me"}}]}"#,
            r#"data: {"choices":[{"index":0,"delta":{"reasoning_content":" think"}}]}"#,
            r#"data: {"choices":[{"index":0,"delta":{"content":"42"}}]}"#,
            "data: [DONE]",
        ] {
            a.feed_line(line, &|d: &str, r: bool| {
                events.lock().unwrap().push((d.to_string(), r))
            });
        }
        let resp = a.finish("m".into());
        // Reasoning was forwarded live, tagged, and NOT folded into the answer.
        assert_eq!(
            *events.lock().unwrap(),
            vec![
                ("Let me".to_string(), true),
                (" think".to_string(), true),
                ("42".to_string(), false),
            ]
        );
        assert_eq!(resp.content, "42");
    }

    #[test]
    fn tolerates_garbage_lines() {
        let deltas = Mutex::new(Vec::new());
        let mut a = StreamAssembly::default();
        feed(
            &mut a,
            &["data: not json", "", "event: ping", r#"data: {"choices":[{"index":0,"delta":{"content":"ok"}}]}"#],
            &deltas,
        );
        assert_eq!(a.finish("m".into()).content, "ok");
    }
}
