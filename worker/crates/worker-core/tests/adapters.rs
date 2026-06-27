//! Adapter request/response mapping against a mock HTTP server.

use reqwest::Client;
use serde_json::json;
use wiremock::matchers::{header, method, path, path_regex};
use wiremock::{Mock, MockServer, ResponseTemplate};

use worker_core::adapter::ProviderAdapter;
use worker_core::adapters::{
    AnthropicAdapter, GeminiAdapter, OllamaAdapter, OpenAICompatibleAdapter,
};
use worker_core::types::{ChatMessage, ChatRequest};
use worker_core::vault::Secret;

fn chat(model: &str) -> ChatRequest {
    ChatRequest {
        model: model.into(),
        messages: vec![ChatMessage {
            role: "user".into(),
            content: "hi".into(),
        }],
        max_tokens: Some(64),
        temperature: None,
    }
}

#[tokio::test]
async fn openai_compatible_chat_and_models() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/models"))
        .and(header("authorization", "Bearer sk-test"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "data": [{ "id": "gpt-4.1-mini" }]
        })))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "choices": [{ "message": { "content": "hello" } }],
            "usage": { "prompt_tokens": 10, "completion_tokens": 5 }
        })))
        .mount(&server)
        .await;

    let a = OpenAICompatibleAdapter::new(
        "openai",
        server.uri(),
        Secret::new("sk-test"),
        Client::new(),
    );
    assert!(a.validate_credentials().await.unwrap());
    let models = a.list_models().await.unwrap();
    assert_eq!(models[0].name, "gpt-4.1-mini");
    assert!(models[0].uses_external_provider);

    let resp = a.run_chat_completion(chat("gpt-4.1-mini")).await.unwrap();
    assert_eq!(resp.content, "hello");
    assert_eq!(resp.usage.input_tokens, 10);
    assert_eq!(resp.usage.output_tokens, 5);
}

#[tokio::test]
async fn openai_compatible_maps_error_status() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(ResponseTemplate::new(401).set_body_string("unauthorized"))
        .mount(&server)
        .await;
    let a =
        OpenAICompatibleAdapter::new("openai", server.uri(), Secret::new("sk-bad"), Client::new());
    let err = a
        .run_chat_completion(chat("gpt-4.1-mini"))
        .await
        .unwrap_err();
    assert!(matches!(
        err,
        worker_core::Error::ProviderStatus { status: 401, .. }
    ));
}

#[tokio::test]
async fn anthropic_chat_splits_system() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/messages"))
        .and(header("x-api-key", "sk-ant-test"))
        .and(header("anthropic-version", "2023-06-01"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "content": [{ "type": "text", "text": "claude-reply" }],
            "usage": { "input_tokens": 12, "output_tokens": 7 }
        })))
        .mount(&server)
        .await;

    let a =
        AnthropicAdapter::with_base_url(server.uri(), Secret::new("sk-ant-test"), Client::new());
    let mut req = chat("claude-x");
    req.messages.insert(
        0,
        ChatMessage {
            role: "system".into(),
            content: "be terse".into(),
        },
    );
    let resp = a.run_chat_completion(req).await.unwrap();
    assert_eq!(resp.content, "claude-reply");
    assert_eq!(resp.usage.output_tokens, 7);
}

#[tokio::test]
async fn gemini_chat_maps_usage_metadata() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path_regex(r"^/models/.*:generateContent$"))
        .and(header("x-goog-api-key", "AIza-test"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "candidates": [{ "content": { "parts": [{ "text": "gem-reply" }] } }],
            "usageMetadata": { "promptTokenCount": 9, "candidatesTokenCount": 4 }
        })))
        .mount(&server)
        .await;

    let a = GeminiAdapter::with_base_url(server.uri(), Secret::new("AIza-test"), Client::new());
    let resp = a
        .run_chat_completion(chat("gemini-1.5-flash"))
        .await
        .unwrap();
    assert_eq!(resp.content, "gem-reply");
    assert_eq!(resp.usage.input_tokens, 9);
}

#[tokio::test]
async fn ollama_is_local_and_maps_counts() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/api/chat"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "message": { "content": "local-reply" },
            "prompt_eval_count": 20,
            "eval_count": 8
        })))
        .mount(&server)
        .await;

    let a = OllamaAdapter::with_endpoint(server.uri(), Client::new());
    assert!(!a.uses_external_provider());
    let resp = a.run_chat_completion(chat("qwen2.5vl:7b")).await.unwrap();
    assert_eq!(resp.content, "local-reply");
    assert_eq!(resp.usage.input_tokens, 20);
    assert_eq!(resp.usage.output_tokens, 8);
}
