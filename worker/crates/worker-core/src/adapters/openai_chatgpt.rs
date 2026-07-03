//! OpenAI via "Sign in with ChatGPT" — talks to the ChatGPT backend's Codex Responses API
//! using the account's OAuth tokens directly, so accounts **without** a platform API
//! organization (i.e. a plain ChatGPT subscription) can be used with no API key.
//!
//! Transport: `POST {base}/responses` with `Authorization: Bearer <access token>` and the
//! `chatgpt-account-id` header (from the id_token). The endpoint answers Server-Sent Events;
//! we read the whole stream and pull the final text + usage out of it.
//!
//! NOTE: this is a reverse-engineered, undocumented backend (same one Codex/opencode use). The
//! base URL is overridable (`with_base_url` / `HYDRA_OPENAI_CHATGPT_BASE_URL`) so it can be
//! corrected without a rebuild if the contract shifts.

use async_trait::async_trait;
use reqwest::Client;
use serde_json::{json, Value};
use tokio::sync::Mutex;

use super::tools::{forced_function_name, function_defs};
use crate::adapter::ProviderAdapter;
use crate::error::{Error, Result};
use crate::oauth::{refresh_openai, OAuthTokens};
use crate::types::{ChatRequest, ChatResponse, ModelInfo, ToolCall, ToolCallFunction, Usage};

const DEFAULT_BASE: &str = "https://chatgpt.com/backend-api/codex";
const REFRESH_MARGIN_SECONDS: u64 = 60;

/// Models the ChatGPT backend serves for ChatGPT sign-in (it has no list endpoint, and the
/// allowed set churns — retired ids get a 400 "not supported when using Codex with a ChatGPT
/// account"). Override with `HYDRA_OPENAI_CHATGPT_MODELS` (comma-separated) without a rebuild.
const DEFAULT_MODELS: &[&str] = &["gpt-5.5", "gpt-5.4", "gpt-5.4-mini"];

fn chatgpt_models() -> Vec<String> {
    match std::env::var("HYDRA_OPENAI_CHATGPT_MODELS") {
        Ok(v) if !v.trim().is_empty() => v
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect(),
        _ => DEFAULT_MODELS.iter().map(|s| s.to_string()).collect(),
    }
}

pub struct ChatGptBackendAdapter {
    base_url: String,
    tokens: Mutex<OAuthTokens>,
    account_id: Option<String>,
    client: Client,
}

impl ChatGptBackendAdapter {
    pub fn new(tokens: OAuthTokens, client: Client) -> Self {
        let base = std::env::var("HYDRA_OPENAI_CHATGPT_BASE_URL")
            .unwrap_or_else(|_| DEFAULT_BASE.to_string());
        Self::with_base_url(base, tokens, client)
    }

    pub fn with_base_url(base_url: impl Into<String>, tokens: OAuthTokens, client: Client) -> Self {
        Self {
            base_url: base_url.into().trim_end_matches('/').to_string(),
            account_id: tokens.account_id.clone(),
            tokens: Mutex::new(tokens),
            client,
        }
    }

    /// Current access token, refreshed under the lock when near expiry.
    async fn bearer(&self) -> Result<String> {
        let mut tokens = self.tokens.lock().await;
        if tokens.expires_within(REFRESH_MARGIN_SECONDS) && tokens.refresh_token.is_some() {
            refresh_openai(&self.client, &mut tokens).await?;
        }
        Ok(tokens.access_token.clone())
    }
}

#[async_trait]
impl ProviderAdapter for ChatGptBackendAdapter {
    fn name(&self) -> &str {
        "openai"
    }

    fn uses_external_provider(&self) -> bool {
        true
    }

    async fn list_models(&self) -> Result<Vec<ModelInfo>> {
        Ok(chatgpt_models()
            .into_iter()
            .map(|name| ModelInfo {
                name,
                capabilities: vec![
                    "chat".into(),
                    "text.extract_json".into(),
                    "text.clean".into(),
                ],
                context_length: None,
                modalities: vec!["text".into()],
                uses_external_provider: true,
            })
            .collect())
    }

    async fn validate_credentials(&self) -> Result<bool> {
        // A usable credential is one we can present (refreshing if needed). We don't spend a
        // real request here.
        Ok(self.bearer().await.is_ok())
    }

    async fn run_chat_completion(&self, req: ChatRequest) -> Result<ChatResponse> {
        let bearer = self.bearer().await?;
        let body = build_responses_body(&req);

        let mut request = self
            .client
            .post(format!("{}/responses", self.base_url))
            .bearer_auth(bearer)
            .header("OpenAI-Beta", "responses=experimental")
            .header("originator", "codex_cli_rs")
            .header("accept", "text/event-stream")
            .json(&body);
        if let Some(acct) = &self.account_id {
            request = request.header("chatgpt-account-id", acct.clone());
        }

        let resp = request.send().await?;
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        if !status.is_success() {
            return Err(Error::ProviderStatus {
                status: status.as_u16(),
                body: format!("chatgpt responses: {}", crate::vault::redact(&text)),
            });
        }

        let (content, tool_calls, usage) = parse_responses_sse(&text);
        Ok(ChatResponse {
            model: req.model,
            content,
            tool_calls,
            usage,
        })
    }
}

/// Map a normalized chat request into a Codex Responses request body. The system message
/// becomes `instructions`; the rest become `input` items — assistant tool calls as
/// `function_call` items and `role:"tool"` results as `function_call_output` items.
fn build_responses_body(req: &ChatRequest) -> Value {
    let mut instructions = String::new();
    let mut input = Vec::new();
    for m in &req.messages {
        match m.role.as_str() {
            "system" => {
                if !instructions.is_empty() {
                    instructions.push('\n');
                }
                instructions.push_str(&m.content);
            }
            "assistant" | "model" => {
                if !m.content.is_empty() || m.tool_calls.is_none() {
                    input.push(json!({
                        "type": "message", "role": "assistant",
                        "content": [{ "type": "output_text", "text": m.content }]
                    }));
                }
                for c in m.tool_calls.as_deref().unwrap_or_default() {
                    input.push(json!({
                        "type": "function_call",
                        "call_id": c.id,
                        "name": c.function.name,
                        "arguments": c.function.arguments,
                    }));
                }
            }
            "tool" => input.push(json!({
                "type": "function_call_output",
                "call_id": m.tool_call_id.clone().unwrap_or_default(),
                "output": m.content,
            })),
            _ => input.push(json!({
                "type": "message", "role": "user",
                "content": [{ "type": "input_text", "text": m.content }]
            })),
        }
    }

    // NOTE: no `max_output_tokens` — the ChatGPT (Codex) backend rejects it with
    // 400 "Unsupported parameter", so `req.max_tokens` is deliberately ignored here.
    let mut body = json!({
        "model": req.model,
        "instructions": instructions,
        "input": input,
        "stream": true,
        "store": false,
    });
    if let Some(tools) = &req.tools {
        // Responses flattens the OpenAI chat tool wrapper: {type, name, description, parameters}.
        body["tools"] = json!(function_defs(tools)
            .iter()
            .map(|f| json!({
                "type": "function",
                "name": f.name,
                "description": f.description.unwrap_or_default(),
                "parameters": f.parameters.cloned().unwrap_or_else(|| json!({ "type": "object" })),
            }))
            .collect::<Vec<_>>());
        if let Some(choice) = &req.tool_choice {
            body["tool_choice"] = match forced_function_name(choice) {
                Some(name) => json!({ "type": "function", "name": name }),
                None => choice.clone(),
            };
        }
    }
    body
}

/// Parse a Responses SSE stream (full body) into (text, tool calls, usage). Prefers the
/// terminal `response.completed` event's output; falls back to accumulated
/// `output_text.delta`s.
fn parse_responses_sse(body: &str) -> (String, Option<Vec<ToolCall>>, Usage) {
    let mut delta = String::new();
    let mut final_text: Option<String> = None;
    let mut tool_calls = Vec::new();
    let mut usage = Usage::default();

    for line in body.lines() {
        let line = line.trim_start();
        let Some(payload) = line.strip_prefix("data:") else {
            continue;
        };
        let payload = payload.trim();
        if payload.is_empty() || payload == "[DONE]" {
            continue;
        }
        let Ok(ev) = serde_json::from_str::<Value>(payload) else {
            continue;
        };

        match ev["type"].as_str().unwrap_or_default() {
            "response.output_text.delta" => {
                if let Some(d) = ev["delta"].as_str() {
                    delta.push_str(d);
                }
            }
            "response.completed" => {
                let response = &ev["response"];
                final_text = extract_output_text(response).or(final_text.take());
                tool_calls = extract_function_calls(response);
                usage = extract_usage(&response["usage"]);
            }
            _ => {}
        }
    }

    let content = final_text.filter(|s| !s.is_empty()).unwrap_or(delta);
    (content, (!tool_calls.is_empty()).then_some(tool_calls), usage)
}

/// Pull `function_call` output items from a Responses `response` object, in OpenAI chat shape.
fn extract_function_calls(response: &Value) -> Vec<ToolCall> {
    response["output"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
        .iter()
        .filter(|item| item["type"].as_str() == Some("function_call"))
        .map(|item| ToolCall {
            id: item["call_id"]
                .as_str()
                .or(item["id"].as_str())
                .unwrap_or_default()
                .to_string(),
            kind: "function".to_string(),
            function: ToolCallFunction {
                name: item["name"].as_str().unwrap_or_default().to_string(),
                arguments: item["arguments"].as_str().unwrap_or("{}").to_string(),
            },
        })
        .collect()
}

/// Pull the concatenated assistant text from a Responses `response` object's `output` array.
fn extract_output_text(response: &Value) -> Option<String> {
    let items = response["output"].as_array()?;
    let mut out = String::new();
    for item in items {
        if item["type"].as_str() == Some("message") {
            if let Some(parts) = item["content"].as_array() {
                for part in parts {
                    if let Some(t) = part["text"].as_str() {
                        out.push_str(t);
                    }
                }
            }
        }
    }
    (!out.is_empty()).then_some(out)
}

fn extract_usage(u: &Value) -> Usage {
    Usage {
        input_tokens: u["input_tokens"].as_u64().unwrap_or(0),
        output_tokens: u["output_tokens"].as_u64().unwrap_or(0),
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::oauth::FLAVOR_OPENAI_CHATGPT;
    use crate::types::ChatMessage;
    use wiremock::matchers::{body_partial_json, header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn tokens() -> OAuthTokens {
        OAuthTokens {
            flavor: FLAVOR_OPENAI_CHATGPT.into(),
            access_token: "acc-token".into(),
            refresh_token: None,
            expires_at_unix: crate::oauth::now_unix() + 3600,
            project_id: None,
            account_id: Some("acct-123".into()),
        }
    }

    #[test]
    fn sse_parse_prefers_completed_output_and_reads_usage() {
        let sse = concat!(
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hel\"}\n\n",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"lo\"}\n\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello there\"}]}],\"usage\":{\"input_tokens\":4,\"output_tokens\":2}}}\n\n",
            "data: [DONE]\n\n",
        );
        let (text, tool_calls, usage) = parse_responses_sse(sse);
        assert_eq!(text, "Hello there");
        assert!(tool_calls.is_none());
        assert_eq!(usage.input_tokens, 4);
        assert_eq!(usage.output_tokens, 2);
    }

    #[test]
    fn sse_parse_extracts_function_calls() {
        let sse = concat!(
            "data: {\"type\":\"response.completed\",\"response\":{\"output\":[{\"type\":\"function_call\",\"call_id\":\"call_9\",\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}],\"usage\":{\"input_tokens\":4,\"output_tokens\":2}}}\n\n",
            "data: [DONE]\n\n",
        );
        let (_text, tool_calls, _usage) = parse_responses_sse(sse);
        let calls = tool_calls.expect("tool calls parsed");
        assert_eq!(calls[0].id, "call_9");
        assert_eq!(calls[0].function.name, "read_file");
        assert_eq!(calls[0].function.arguments, "{\"path\":\"a.txt\"}");
    }

    #[test]
    fn sse_parse_falls_back_to_deltas_without_completed_output() {
        let sse = concat!(
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"par\"}\n\n",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"tial\"}\n\n",
        );
        let (text, _tool_calls, _usage) = parse_responses_sse(sse);
        assert_eq!(text, "partial");
    }

    #[tokio::test]
    async fn run_posts_responses_with_account_header_and_maps_reply() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/responses"))
            .and(header("authorization", "Bearer acc-token"))
            .and(header("chatgpt-account-id", "acct-123"))
            .and(body_partial_json(json!({
                "model": "gpt-5",
                "instructions": "be brief",
                "input": [{ "type": "message", "role": "user",
                            "content": [{ "type": "input_text", "text": "hi" }] }]
            })))
            .respond_with(ResponseTemplate::new(200).set_body_string(concat!(
                "data: {\"type\":\"response.completed\",\"response\":{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"hey!\"}]}],\"usage\":{\"input_tokens\":3,\"output_tokens\":1}}}\n\n"
            )))
            .mount(&server)
            .await;

        let adapter =
            ChatGptBackendAdapter::with_base_url(server.uri(), tokens(), reqwest::Client::new());
        let resp = adapter
            .run_chat_completion(ChatRequest {
                model: "gpt-5".into(),
                messages: vec![
                    ChatMessage { role: "system".into(), content: "be brief".into(), ..Default::default() },
                    ChatMessage { role: "user".into(), content: "hi".into(), ..Default::default() },
                ],
                max_tokens: None,
                temperature: None,
                tools: None,
                tool_choice: None,
            })
            .await
            .unwrap();

        assert_eq!(resp.content, "hey!");
        assert_eq!(resp.usage.output_tokens, 1);
    }

    #[tokio::test]
    async fn lists_static_models_with_chat_capability() {
        let a = ChatGptBackendAdapter::with_base_url("http://x", tokens(), reqwest::Client::new());
        let models = a.list_models().await.unwrap();
        assert!(models.iter().any(|m| m.name == "gpt-5.5"));
        assert!(models.iter().all(|m| m.capabilities.contains(&"chat".to_string())));
    }

    #[test]
    fn model_list_env_override_splits_and_trims() {
        std::env::set_var("HYDRA_OPENAI_CHATGPT_MODELS", " gpt-6 , gpt-6-mini ");
        let models = chatgpt_models();
        std::env::remove_var("HYDRA_OPENAI_CHATGPT_MODELS");
        assert_eq!(models, vec!["gpt-6".to_string(), "gpt-6-mini".to_string()]);
    }
}
