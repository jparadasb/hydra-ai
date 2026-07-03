//! Adapter request/response mapping against a mock HTTP server.

use reqwest::Client;
use serde_json::json;
use wiremock::matchers::{header, method, path, path_regex};
use wiremock::{Mock, MockServer, ResponseTemplate};

use worker_core::adapter::ProviderAdapter;
use worker_core::adapters::{
    AnthropicAdapter, GeminiAdapter, LocalOpenAiAdapter, OllamaAdapter, OpenAICompatibleAdapter,
};
use worker_core::types::{ChatMessage, ChatRequest};
use worker_core::vault::Secret;

fn chat(model: &str) -> ChatRequest {
    ChatRequest {
        model: model.into(),
        messages: vec![ChatMessage {
            role: "user".into(),
            content: "hi".into(),
            ..Default::default()
        }],
        max_tokens: Some(64),
        temperature: None,
        tools: None,
        tool_choice: None,
    }
}

/// OpenAI-shaped tool definitions as an opencode-style client sends them.
fn weather_tools() -> serde_json::Value {
    json!([{
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "Get the weather",
            "parameters": {
                "type": "object",
                "properties": { "city": { "type": "string" } },
                "required": ["city"],
                "additionalProperties": false
            }
        }
    }])
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
            ..Default::default()
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
async fn local_openai_runtime_is_local_no_auth() {
    let server = MockServer::start().await;
    // No Authorization header required for a local runtime.
    Mock::given(method("GET"))
        .and(path("/models"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "data": [{ "id": "llama-3.1-8b" }]
        })))
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "choices": [{ "message": { "content": "local-oai" } }],
            "usage": { "prompt_tokens": 7, "completion_tokens": 2 }
        })))
        .mount(&server)
        .await;

    // llama.cpp / vLLM share this adapter; base_url override points at the mock.
    let a = LocalOpenAiAdapter::new("llama_cpp", server.uri(), None, Client::new());
    assert!(!a.uses_external_provider());

    let models = a.list_models().await.unwrap();
    assert_eq!(models[0].name, "llama-3.1-8b");
    assert!(
        !models[0].uses_external_provider,
        "local models must not be flagged external"
    );

    let resp = a.run_chat_completion(chat("llama-3.1-8b")).await.unwrap();
    assert_eq!(resp.content, "local-oai");
    assert_eq!(resp.usage.input_tokens, 7);
    assert_eq!(resp.usage.output_tokens, 2);
}

#[tokio::test]
async fn local_runtime_constructors_are_local() {
    // llama.cpp / vLLM / LM Studio share one local adapter at distinct default endpoints.
    for a in [
        LocalOpenAiAdapter::llama_cpp(Client::new()),
        LocalOpenAiAdapter::vllm(Client::new()),
        LocalOpenAiAdapter::lm_studio(Client::new()),
    ] {
        assert!(!a.uses_external_provider());
    }
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

#[tokio::test]
async fn openai_compatible_passes_tools_and_maps_tool_calls() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .and(wiremock::matchers::body_partial_json(json!({
            "tools": weather_tools(),
            "tool_choice": "auto"
        })))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "choices": [{
                "message": {
                    "content": null,
                    "tool_calls": [{
                        "id": "call_abc",
                        "type": "function",
                        "function": { "name": "get_weather", "arguments": "{\"city\":\"Berlin\"}" }
                    }]
                },
                "finish_reason": "tool_calls"
            }],
            "usage": { "prompt_tokens": 11, "completion_tokens": 6 }
        })))
        .mount(&server)
        .await;

    let a = OpenAICompatibleAdapter::new("openai", server.uri(), Secret::new("sk-t"), Client::new());
    let mut req = chat("gpt-4.1-mini");
    req.tools = Some(weather_tools());
    req.tool_choice = Some(json!("auto"));
    let resp = a.run_chat_completion(req).await.unwrap();

    assert_eq!(resp.content, "");
    let calls = resp.tool_calls.expect("tool calls mapped");
    assert_eq!(calls[0].id, "call_abc");
    assert_eq!(calls[0].function.name, "get_weather");
    assert_eq!(calls[0].function.arguments, "{\"city\":\"Berlin\"}");
}

#[tokio::test]
async fn ollama_translates_tool_arguments_between_object_and_string() {
    let server = MockServer::start().await;
    // Ollama returns `arguments` as a JSON object and has no call ids.
    Mock::given(method("POST"))
        .and(path("/api/chat"))
        .and(wiremock::matchers::body_partial_json(json!({
            "tools": weather_tools()
        })))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "message": {
                "content": "",
                "tool_calls": [{ "function": { "name": "get_weather", "arguments": { "city": "Berlin" } } }]
            },
            "prompt_eval_count": 5,
            "eval_count": 3
        })))
        .mount(&server)
        .await;

    let a = OllamaAdapter::with_endpoint(server.uri(), Client::new());
    let mut req = chat("qwen3:8b");
    req.tools = Some(weather_tools());
    let resp = a.run_chat_completion(req).await.unwrap();

    let calls = resp.tool_calls.expect("tool calls mapped");
    assert_eq!(calls[0].id, "call_0");
    assert_eq!(calls[0].function.name, "get_weather");
    // Object arguments come back JSON-encoded, as OpenAI clients expect.
    assert_eq!(calls[0].function.arguments, "{\"city\":\"Berlin\"}");
}

#[tokio::test]
async fn anthropic_translates_tools_and_tool_use_blocks() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/messages"))
        .and(wiremock::matchers::body_partial_json(json!({
            "tools": [{
                "name": "get_weather",
                "description": "Get the weather",
                "input_schema": {
                    "type": "object",
                    "properties": { "city": { "type": "string" } },
                    "required": ["city"],
                    "additionalProperties": false
                }
            }],
            "tool_choice": { "type": "auto" }
        })))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "content": [
                { "type": "text", "text": "checking" },
                { "type": "tool_use", "id": "toolu_1", "name": "get_weather", "input": { "city": "Berlin" } }
            ],
            "stop_reason": "tool_use",
            "usage": { "input_tokens": 9, "output_tokens": 4 }
        })))
        .mount(&server)
        .await;

    let a = AnthropicAdapter::with_base_url(server.uri(), Secret::new("sk-ant"), Client::new());
    let mut req = chat("claude-x");
    req.tools = Some(weather_tools());
    req.tool_choice = Some(json!("auto"));
    let resp = a.run_chat_completion(req).await.unwrap();

    assert_eq!(resp.content, "checking");
    let calls = resp.tool_calls.expect("tool_use mapped to tool calls");
    assert_eq!(calls[0].id, "toolu_1");
    assert_eq!(calls[0].function.name, "get_weather");
    assert_eq!(calls[0].function.arguments, "{\"city\":\"Berlin\"}");
}

#[tokio::test]
async fn anthropic_maps_tool_history_to_tool_use_and_tool_result_blocks() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/messages"))
        .and(wiremock::matchers::body_partial_json(json!({
            "messages": [
                { "role": "user", "content": "hi" },
                { "role": "assistant", "content": [
                    { "type": "tool_use", "id": "call_1", "name": "get_weather", "input": { "city": "Berlin" } }
                ]},
                { "role": "user", "content": [
                    { "type": "tool_result", "tool_use_id": "call_1", "content": "18C" }
                ]}
            ]
        })))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "content": [{ "type": "text", "text": "18 degrees" }],
            "usage": { "input_tokens": 20, "output_tokens": 5 }
        })))
        .mount(&server)
        .await;

    let a = AnthropicAdapter::with_base_url(server.uri(), Secret::new("sk-ant"), Client::new());
    let mut req = chat("claude-x");
    req.messages.push(ChatMessage {
        role: "assistant".into(),
        content: "".into(),
        tool_calls: Some(vec![worker_core::types::ToolCall {
            id: "call_1".into(),
            kind: "function".into(),
            function: worker_core::types::ToolCallFunction {
                name: "get_weather".into(),
                arguments: "{\"city\":\"Berlin\"}".into(),
            },
        }]),
        ..Default::default()
    });
    req.messages.push(ChatMessage {
        role: "tool".into(),
        content: "18C".into(),
        tool_call_id: Some("call_1".into()),
        ..Default::default()
    });

    let resp = a.run_chat_completion(req).await.unwrap();
    assert_eq!(resp.content, "18 degrees");
    assert!(resp.tool_calls.is_none());
}

#[tokio::test]
async fn gemini_translates_function_declarations_and_calls() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path_regex(r"^/models/.*:generateContent$"))
        .and(wiremock::matchers::body_partial_json(json!({
            // additionalProperties must be scrubbed for Gemini's schema dialect.
            "tools": [{ "functionDeclarations": [{
                "name": "get_weather",
                "description": "Get the weather",
                "parameters": {
                    "type": "object",
                    "properties": { "city": { "type": "string" } },
                    "required": ["city"]
                }
            }]}],
            "toolConfig": { "functionCallingConfig": { "mode": "AUTO" } }
        })))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "candidates": [{ "content": { "parts": [
                { "functionCall": { "name": "get_weather", "args": { "city": "Berlin" } } }
            ]}}],
            "usageMetadata": { "promptTokenCount": 8, "candidatesTokenCount": 3 }
        })))
        .mount(&server)
        .await;

    let a = GeminiAdapter::with_base_url(server.uri(), Secret::new("AIza-t"), Client::new());
    let mut req = chat("gemini-2.5-flash");
    req.tools = Some(weather_tools());
    req.tool_choice = Some(json!("auto"));
    let resp = a.run_chat_completion(req).await.unwrap();

    let calls = resp.tool_calls.expect("functionCall mapped");
    assert_eq!(calls[0].function.name, "get_weather");
    assert_eq!(calls[0].function.arguments, "{\"city\":\"Berlin\"}");
}
