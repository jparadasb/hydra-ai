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

use crate::adapter::ProviderAdapter;
use crate::error::{Error, Result};
use crate::oauth::{refresh_openai, OAuthTokens};
use crate::types::{ChatRequest, ChatResponse, ModelInfo, Usage};

const DEFAULT_BASE: &str = "https://chatgpt.com/backend-api/codex";
const REFRESH_MARGIN_SECONDS: u64 = 60;

/// Models the ChatGPT backend serves (no list endpoint). Adjust if your plan differs.
const MODELS: &[&str] = &["gpt-5", "gpt-4o"];

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
        Ok(MODELS
            .iter()
            .map(|name| ModelInfo {
                name: (*name).to_string(),
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

        let (content, usage) = parse_responses_sse(&text);
        Ok(ChatResponse {
            model: req.model,
            content,
            usage,
        })
    }
}

/// Map a normalized chat request into a Codex Responses request body. The system message
/// becomes `instructions`; the rest become `input` messages.
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
            "assistant" | "model" => input.push(json!({
                "type": "message", "role": "assistant",
                "content": [{ "type": "output_text", "text": m.content }]
            })),
            _ => input.push(json!({
                "type": "message", "role": "user",
                "content": [{ "type": "input_text", "text": m.content }]
            })),
        }
    }

    let mut body = json!({
        "model": req.model,
        "instructions": instructions,
        "input": input,
        "stream": true,
        "store": false,
    });
    if let Some(mt) = req.max_tokens {
        body["max_output_tokens"] = json!(mt);
    }
    body
}

/// Parse a Responses SSE stream (full body) into (text, usage). Prefers the terminal
/// `response.completed` event's output; falls back to accumulated `output_text.delta`s.
fn parse_responses_sse(body: &str) -> (String, Usage) {
    let mut delta = String::new();
    let mut final_text: Option<String> = None;
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
                usage = extract_usage(&response["usage"]);
            }
            _ => {}
        }
    }

    let content = final_text.filter(|s| !s.is_empty()).unwrap_or(delta);
    (content, usage)
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
        let (text, usage) = parse_responses_sse(sse);
        assert_eq!(text, "Hello there");
        assert_eq!(usage.input_tokens, 4);
        assert_eq!(usage.output_tokens, 2);
    }

    #[test]
    fn sse_parse_falls_back_to_deltas_without_completed_output() {
        let sse = concat!(
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"par\"}\n\n",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"tial\"}\n\n",
        );
        let (text, _usage) = parse_responses_sse(sse);
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
                    ChatMessage { role: "system".into(), content: "be brief".into() },
                    ChatMessage { role: "user".into(), content: "hi".into() },
                ],
                max_tokens: None,
                temperature: None,
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
        assert!(models.iter().any(|m| m.name == "gpt-5"));
        assert!(models.iter().all(|m| m.capabilities.contains(&"chat".to_string())));
    }
}
