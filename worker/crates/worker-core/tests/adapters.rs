//! Adapter request/response mapping against a mock HTTP server.

use std::sync::{Arc, Mutex};

use reqwest::Client;
use serde_json::json;
use wiremock::matchers::{header, method, path, path_regex};
use wiremock::{Mock, MockServer, ResponseTemplate};

use worker_core::adapter::{DeltaSink, ProviderAdapter};
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
        response_format: None,
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
    assert_eq!(resp.usage.input_tokens, Some(10));
    assert_eq!(resp.usage.output_tokens, Some(5));
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
    assert_eq!(resp.usage.output_tokens, Some(7));
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
    assert_eq!(resp.usage.input_tokens, Some(9));
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
    assert_eq!(resp.usage.input_tokens, Some(7));
    assert_eq!(resp.usage.output_tokens, Some(2));
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
    assert_eq!(resp.usage.input_tokens, Some(20));
    assert_eq!(resp.usage.output_tokens, Some(8));
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

    let a =
        OpenAICompatibleAdapter::new("openai", server.uri(), Secret::new("sk-t"), Client::new());
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

// ---- retry ----------------------------------------------------------------------------------

#[tokio::test]
async fn a_transient_429_is_retried_instead_of_failing_the_job() {
    // A single 429 used to fail the job outright. The coordinator would then re-queue it,
    // spend one of its five attempts, and possibly hand it to another worker — for a condition
    // the provider itself said was temporary.
    let server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(ResponseTemplate::new(429).insert_header("retry-after", "0"))
        .up_to_n_times(1)
        .mount(&server)
        .await;

    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "choices": [{ "message": { "role": "assistant", "content": "recovered" } }],
            "usage": { "prompt_tokens": 3, "completion_tokens": 2 }
        })))
        .mount(&server)
        .await;

    let adapter =
        OpenAICompatibleAdapter::new("openai", server.uri(), Secret::new("sk-x"), Client::new());

    let resp = adapter
        .run_chat_completion(chat("gpt-4.1-mini"))
        .await
        .expect("the retry should have carried this through");

    assert_eq!(resp.content, "recovered");
}

#[tokio::test]
async fn a_503_is_retried_and_the_last_failure_is_still_reported() {
    // Retrying is bounded: a provider that is simply down must not be retried forever, and the
    // caller has to see why it failed.
    let server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(ResponseTemplate::new(503).insert_header("retry-after", "0"))
        .mount(&server)
        .await;

    let adapter =
        OpenAICompatibleAdapter::new("openai", server.uri(), Secret::new("sk-x"), Client::new());

    let error = adapter
        .run_chat_completion(chat("gpt-4.1-mini"))
        .await
        .expect_err("a permanently unavailable provider still fails");

    assert!(format!("{error}").contains("503"), "error was: {error}");
    // Three attempts total, not an unbounded loop.
    assert_eq!(server.received_requests().await.unwrap().len(), 3);
}

#[tokio::test]
async fn a_client_error_is_not_retried() {
    // A malformed request will not become well-formed on the second try; retrying it just
    // spends the caller's deadline.
    let server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(ResponseTemplate::new(400).set_body_json(json!({ "error": "bad model" })))
        .mount(&server)
        .await;

    let adapter =
        OpenAICompatibleAdapter::new("openai", server.uri(), Secret::new("sk-x"), Client::new());

    assert!(adapter.run_chat_completion(chat("nope")).await.is_err());
    assert_eq!(server.received_requests().await.unwrap().len(), 1);
}

// ---- streaming ------------------------------------------------------------------------------

/// Collects what a backend streams, so a test can assert the fragments arrived *as* fragments
/// rather than as one lump at the end.
fn delta_sink() -> (DeltaSink, Arc<Mutex<Vec<String>>>) {
    let seen = Arc::new(Mutex::new(Vec::new()));
    let sink_seen = seen.clone();
    let sink: DeltaSink = Arc::new(move |text: &str, reasoning: bool| {
        if !reasoning {
            sink_seen.lock().unwrap().push(text.to_string());
        }
    });
    (sink, seen)
}

#[tokio::test]
async fn ollama_streams_ndjson_fragments_and_final_counts() {
    // Ollama had no streaming override at all: the trait default ran the blocking call, so a
    // caller waited in silence and then received the whole answer at once.
    let server = MockServer::start().await;

    let ndjson = concat!(
        r#"{"message":{"content":"Hel"},"done":false}"#,
        "\n",
        r#"{"message":{"content":"lo"},"done":false}"#,
        "\n",
        r#"{"done":true,"prompt_eval_count":7,"eval_count":2}"#,
        "\n",
    );

    Mock::given(method("POST"))
        .and(path("/api/chat"))
        .respond_with(ResponseTemplate::new(200).set_body_string(ndjson))
        .mount(&server)
        .await;

    let adapter = OllamaAdapter::with_endpoint(server.uri(), Client::new());
    let (sink, seen) = delta_sink();

    let resp = adapter
        .run_chat_completion_streaming(chat("llama3"), sink)
        .await
        .unwrap();

    assert_eq!(resp.content, "Hello");
    assert_eq!(*seen.lock().unwrap(), vec!["Hel", "lo"]);
    assert_eq!(resp.usage.input_tokens, Some(7));
    assert_eq!(resp.usage.output_tokens, Some(2));
}

#[tokio::test]
async fn ollama_advertises_vision_only_for_models_that_have_it() {
    // Every model used to advertise `ocr.extract` and `image.describe`, text-only ones
    // included, so the coordinator routed vision jobs to models guaranteed to fail them.
    let server = MockServer::start().await;

    Mock::given(method("GET"))
        .and(path("/api/tags"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "models": [
                { "name": "llama3:8b", "details": { "families": ["llama"] } },
                { "name": "llava:13b", "details": { "families": ["llama", "clip"] } }
            ]
        })))
        .mount(&server)
        .await;

    let adapter = OllamaAdapter::with_endpoint(server.uri(), Client::new());
    let models = adapter.list_models().await.unwrap();

    let text_only = models.iter().find(|m| m.name == "llama3:8b").unwrap();
    assert!(text_only.capabilities.contains(&"chat".to_string()));
    assert!(!text_only
        .capabilities
        .contains(&"image.describe".to_string()));
    assert_eq!(text_only.modalities, vec!["text".to_string()]);

    let vision = models.iter().find(|m| m.name == "llava:13b").unwrap();
    assert!(vision.capabilities.contains(&"image.describe".to_string()));
    assert!(vision.capabilities.contains(&"ocr.extract".to_string()));
    assert!(vision.modalities.contains(&"image".to_string()));
}

#[tokio::test]
async fn anthropic_streams_text_and_reassembles_tool_arguments() {
    let server = MockServer::start().await;

    // Anthropic's event vocabulary: counts split across message_start/message_delta, tool
    // arguments arriving as partial_json fragments that have to be concatenated.
    let sse = concat!(
        "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":11}}}\n",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Wor\"}}\n",
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"king\"}}\n",
        "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"get_weather\"}}\n",
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"city\\\":\"}}\n",
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"Tokyo\\\"}\"}}\n",
        "data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":4}}\n",
    );

    Mock::given(method("POST"))
        .and(path("/messages"))
        .respond_with(ResponseTemplate::new(200).set_body_string(sse))
        .mount(&server)
        .await;

    let adapter =
        AnthropicAdapter::with_base_url(server.uri(), Secret::new("sk-ant"), Client::new());
    let (sink, seen) = delta_sink();

    let resp = adapter
        .run_chat_completion_streaming(chat("claude-sonnet-4"), sink)
        .await
        .unwrap();

    assert_eq!(resp.content, "Working");
    assert_eq!(*seen.lock().unwrap(), vec!["Wor", "king"]);
    assert_eq!(resp.usage.input_tokens, Some(11));
    assert_eq!(resp.usage.output_tokens, Some(4));

    let calls = resp
        .tool_calls
        .expect("the tool call should survive reassembly");
    assert_eq!(calls[0].function.name, "get_weather");
    assert_eq!(calls[0].function.arguments, r#"{"city":"Tokyo"}"#);
}

#[tokio::test]
async fn gemini_streams_sse_chunks() {
    let server = MockServer::start().await;

    let sse = concat!(
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hi \"}]}}]}\n",
        "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"there\"}]}}],\"usageMetadata\":{\"promptTokenCount\":5,\"candidatesTokenCount\":3}}\n",
    );

    Mock::given(method("POST"))
        .and(path_regex(r".*streamGenerateContent.*"))
        .respond_with(ResponseTemplate::new(200).set_body_string(sse))
        .mount(&server)
        .await;

    let adapter = GeminiAdapter::with_base_url(server.uri(), Secret::new("AIza"), Client::new());
    let (sink, seen) = delta_sink();

    let resp = adapter
        .run_chat_completion_streaming(chat("gemini-2.5-flash"), sink)
        .await
        .unwrap();

    assert_eq!(resp.content, "Hi there");
    assert_eq!(*seen.lock().unwrap(), vec!["Hi ", "there"]);
    assert_eq!(resp.usage.input_tokens, Some(5));
    assert_eq!(resp.usage.output_tokens, Some(3));
}

#[tokio::test]
async fn gemini_does_not_advertise_a_vision_capability_it_cannot_serve() {
    let server = MockServer::start().await;

    Mock::given(method("GET"))
        .and(path("/models"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "models": [{ "name": "models/gemini-2.5-flash" }]
        })))
        .mount(&server)
        .await;

    let adapter = GeminiAdapter::with_base_url(server.uri(), Secret::new("AIza"), Client::new());
    let models = adapter.list_models().await.unwrap();

    // The adapter implements no run_vision_task, so the trait default would answer "does not
    // support vision tasks" for anything routed here on that basis.
    assert!(!models[0]
        .capabilities
        .contains(&"image.describe".to_string()));
    assert!(models[0].capabilities.contains(&"chat".to_string()));
}

// ---- usage ------------------------------------------------------------------------------------

#[tokio::test]
async fn a_provider_that_omits_usage_reports_nothing_rather_than_zero() {
    // Every usage field used to be `unwrap_or(0)`, so "the provider said nothing" and "the call
    // consumed nothing" produced the same result — which becomes zero cost, which never charges
    // a budget.
    let server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "choices": [{ "message": { "role": "assistant", "content": "no usage block" } }]
        })))
        .mount(&server)
        .await;

    let adapter =
        OpenAICompatibleAdapter::new("openai", server.uri(), Secret::new("sk-x"), Client::new());

    let resp = adapter
        .run_chat_completion(chat("gpt-4.1-mini"))
        .await
        .unwrap();

    assert_eq!(resp.usage.input_tokens, None);
    assert_eq!(resp.usage.output_tokens, None);
    assert!(!resp.usage.is_reported());
    // Arithmetic still has a number to work with.
    assert_eq!(resp.usage.input(), 0);
}

#[tokio::test]
async fn a_provider_reporting_zero_is_distinguishable_from_one_reporting_nothing() {
    let server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "choices": [{ "message": { "role": "assistant", "content": "" } }],
            "usage": { "prompt_tokens": 0, "completion_tokens": 0 }
        })))
        .mount(&server)
        .await;

    let adapter =
        OpenAICompatibleAdapter::new("openai", server.uri(), Secret::new("sk-x"), Client::new());

    let resp = adapter
        .run_chat_completion(chat("gpt-4.1-mini"))
        .await
        .unwrap();

    assert_eq!(resp.usage.input_tokens, Some(0));
    assert!(resp.usage.is_reported());
}

// ---- robustness -------------------------------------------------------------------------------

#[tokio::test]
async fn a_huge_tool_call_index_is_rejected_rather_than_allocated() {
    // `index` is the provider's number and it sized a `Vec::resize`. A backend answering
    // `index: 4294967295` asked this process for a four-billion-element allocation.
    let server = MockServer::start().await;

    let sse = concat!(
        "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n",
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":4294967295,\"id\":\"x\",\"function\":{\"name\":\"boom\",\"arguments\":\"{}\"}}]}}]}\n",
        "data: [DONE]\n",
    );

    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(ResponseTemplate::new(200).set_body_string(sse))
        .mount(&server)
        .await;

    let adapter =
        OpenAICompatibleAdapter::new("openai", server.uri(), Secret::new("sk-x"), Client::new());
    let (sink, _seen) = delta_sink();

    // Completes with the content it did get, instead of dying on the allocation.
    let resp = adapter
        .run_chat_completion_streaming(chat("gpt-4.1-mini"), sink)
        .await
        .unwrap();

    assert_eq!(resp.content, "hi");
    assert!(resp.tool_calls.is_none(), "the malformed call is dropped");
}

#[tokio::test]
async fn tool_calls_within_the_bound_still_work() {
    // The cap must not break ordinary parallel tool calls.
    let server = MockServer::start().await;

    let sse = concat!(
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"a\",\"function\":{\"name\":\"one\",\"arguments\":\"{}\"}}]}}]}\n",
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"b\",\"function\":{\"name\":\"two\",\"arguments\":\"{}\"}}]}}]}\n",
        "data: [DONE]\n",
    );

    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(ResponseTemplate::new(200).set_body_string(sse))
        .mount(&server)
        .await;

    let adapter =
        OpenAICompatibleAdapter::new("openai", server.uri(), Secret::new("sk-x"), Client::new());
    let (sink, _seen) = delta_sink();

    let resp = adapter
        .run_chat_completion_streaming(chat("gpt-4.1-mini"), sink)
        .await
        .unwrap();

    let calls = resp.tool_calls.expect("both calls survive");
    assert_eq!(calls.len(), 2);
    assert_eq!(calls[0].function.name, "one");
    assert_eq!(calls[1].function.name, "two");
}

#[tokio::test]
async fn a_stream_with_no_newline_fails_the_job_not_the_process() {
    // Without a cap this buffer grew for as long as the backend kept sending.
    let server = MockServer::start().await;

    let unterminated = "data: ".to_string() + &"x".repeat(2 * 1024 * 1024);

    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(ResponseTemplate::new(200).set_body_string(unterminated))
        .mount(&server)
        .await;

    let adapter =
        OpenAICompatibleAdapter::new("openai", server.uri(), Secret::new("sk-x"), Client::new());
    let (sink, _seen) = delta_sink();

    let error = adapter
        .run_chat_completion_streaming(chat("gpt-4.1-mini"), sink)
        .await
        .expect_err("an undelimited stream is refused");

    assert!(format!("{error}").contains("without a newline"), "{error}");
}
