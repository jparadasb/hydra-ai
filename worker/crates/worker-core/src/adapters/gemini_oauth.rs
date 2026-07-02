//! Gemini via Google account sign-in (Code Assist free tier), the opencode/gemini-cli way.
//!
//! Same model family as [`super::gemini::GeminiAdapter`], different transport:
//! `cloudcode-pa.googleapis.com/v1internal:generateContent` with a
//! `{model, project, request}` envelope and `Authorization: Bearer <oauth access token>`.
//! The access token auto-refreshes in memory (the refresh token from login stays valid, so
//! nothing needs to be written back to the vault at run time).

use async_trait::async_trait;
use reqwest::Client;
use serde_json::json;
use tokio::sync::Mutex;

use super::gemini::{build_generate_content_body, parse_generate_content_response};
use super::openai_compatible::parse_json;
use crate::adapter::ProviderAdapter;
use crate::error::Result;
use crate::oauth::{refresh_google, OAuthTokens};
use crate::types::{ChatRequest, ChatResponse, ModelInfo};

const DEFAULT_BASE: &str = "https://cloudcode-pa.googleapis.com/v1internal";

/// Refresh when the access token is within this many seconds of expiry.
const REFRESH_MARGIN_SECONDS: u64 = 60;

/// Models the Code Assist tier serves (it has no list endpoint).
const MODELS: &[&str] = &["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite"];

pub struct GeminiCodeAssistAdapter {
    base_url: String,
    tokens: Mutex<OAuthTokens>,
    project_id: String,
    client: Client,
}

impl GeminiCodeAssistAdapter {
    pub fn new(tokens: OAuthTokens, client: Client) -> Self {
        Self::with_base_url(DEFAULT_BASE, tokens, client)
    }

    pub fn with_base_url(
        base_url: impl Into<String>,
        tokens: OAuthTokens,
        client: Client,
    ) -> Self {
        Self {
            base_url: base_url.into().trim_end_matches('/').to_string(),
            project_id: tokens.project_id.clone().unwrap_or_default(),
            tokens: Mutex::new(tokens),
            client,
        }
    }

    /// Current access token, refreshed under the lock when near expiry.
    async fn bearer(&self) -> Result<String> {
        let mut tokens = self.tokens.lock().await;
        if tokens.expires_within(REFRESH_MARGIN_SECONDS) {
            refresh_google(&self.client, &mut tokens).await?;
        }
        Ok(tokens.access_token.clone())
    }
}

#[async_trait]
impl ProviderAdapter for GeminiCodeAssistAdapter {
    fn name(&self) -> &str {
        "gemini"
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
                    "image.describe".into(),
                ],
                context_length: None,
                modalities: vec!["text".into(), "image".into()],
                uses_external_provider: true,
            })
            .collect())
    }

    async fn validate_credentials(&self) -> Result<bool> {
        let bearer = self.bearer().await?;
        let resp = self
            .client
            .post(format!("{}:loadCodeAssist", self.base_url))
            .bearer_auth(bearer)
            .json(&json!({
                "metadata": {
                    "ideType": "IDE_UNSPECIFIED",
                    "platform": "PLATFORM_UNSPECIFIED",
                    "pluginType": "GEMINI"
                }
            }))
            .send()
            .await?;
        Ok(resp.status().is_success())
    }

    async fn run_chat_completion(&self, req: ChatRequest) -> Result<ChatResponse> {
        let bearer = self.bearer().await?;
        let body = json!({
            "model": req.model,
            "project": self.project_id,
            "request": build_generate_content_body(&req),
        });

        let resp = self
            .client
            .post(format!("{}:generateContent", self.base_url))
            .bearer_auth(bearer)
            .json(&body)
            .send()
            .await?;
        let value = parse_json(resp).await?;

        // Code Assist nests the standard Gemini reply under "response".
        Ok(parse_generate_content_response(&value["response"], req.model))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::oauth::FLAVOR_GOOGLE_CODE_ASSIST;
    use crate::types::ChatMessage;
    use wiremock::matchers::{body_partial_json, header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn tokens(access: &str) -> OAuthTokens {
        OAuthTokens {
            flavor: FLAVOR_GOOGLE_CODE_ASSIST.into(),
            access_token: access.into(),
            refresh_token: Some("1//refresh".into()),
            // far future: no refresh attempted in tests
            expires_at_unix: crate::oauth::now_unix() + 3600,
            project_id: Some("proj-1".into()),
        }
    }

    #[tokio::test]
    async fn wraps_request_in_code_assist_envelope_and_unwraps_response() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/v1internal:generateContent"))
            .and(header("authorization", "Bearer ya29.test"))
            .and(body_partial_json(json!({
                "model": "gemini-2.5-flash",
                "project": "proj-1",
                "request": { "contents": [{ "role": "user", "parts": [{ "text": "hi" }] }] }
            })))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "response": {
                    "candidates": [
                        { "content": { "parts": [{ "text": "hello!" }] } }
                    ],
                    "usageMetadata": { "promptTokenCount": 3, "candidatesTokenCount": 5 }
                }
            })))
            .mount(&server)
            .await;

        let adapter = GeminiCodeAssistAdapter::with_base_url(
            format!("{}/v1internal", server.uri()),
            tokens("ya29.test"),
            reqwest::Client::new(),
        );

        let resp = adapter
            .run_chat_completion(ChatRequest {
                model: "gemini-2.5-flash".into(),
                messages: vec![ChatMessage {
                    role: "user".into(),
                    content: "hi".into(),
                }],
                max_tokens: None,
                temperature: None,
            })
            .await
            .unwrap();

        assert_eq!(resp.content, "hello!");
        assert_eq!(resp.usage.input_tokens, 3);
        assert_eq!(resp.usage.output_tokens, 5);
    }

    #[tokio::test]
    async fn lists_static_models_with_chat_capability() {
        let adapter =
            GeminiCodeAssistAdapter::new(tokens("ya29.x"), reqwest::Client::new());
        let models = adapter.list_models().await.unwrap();
        assert!(models.iter().any(|m| m.name == "gemini-2.5-flash"));
        assert!(models.iter().all(|m| m.uses_external_provider));
        assert!(models.iter().all(|m| m.capabilities.contains(&"chat".to_string())));
    }
}
