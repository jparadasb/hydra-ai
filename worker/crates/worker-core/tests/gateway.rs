//! End-to-end gateway behaviour: privacy routing across local vs external backends, plus the
//! critical secret-leak assertions on everything that crosses the coordinator boundary.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::json;

use worker_core::adapter::{AdapterRegistry, ProviderAdapter};
use worker_core::config::{Preference, PrivacyPrefs, RoutingPolicy};
use worker_core::gateway::Gateway;
use worker_core::limits::LimitGuard;
use worker_core::types::{
    ChatRequest, ChatResponse, Job, JobStatus, ModelInfo, PrivacyLevel, Usage,
};
use worker_core::usage::MemoryUsageStore;
use worker_core::Limits;

/// A fake adapter that returns a fixed reply and reports whether it is external.
struct FakeAdapter {
    name: &'static str,
    external: bool,
    reply: &'static str,
}

#[async_trait]
impl ProviderAdapter for FakeAdapter {
    fn name(&self) -> &str {
        self.name
    }
    fn uses_external_provider(&self) -> bool {
        self.external
    }
    async fn list_models(&self) -> worker_core::Result<Vec<ModelInfo>> {
        Ok(vec![ModelInfo {
            name: format!("{}-model", self.name),
            capabilities: vec!["text.extract_json".into()],
            context_length: Some(8000),
            modalities: vec!["text".into()],
            uses_external_provider: self.external,
        }])
    }
    async fn validate_credentials(&self) -> worker_core::Result<bool> {
        Ok(true)
    }
    async fn run_chat_completion(&self, req: ChatRequest) -> worker_core::Result<ChatResponse> {
        Ok(ChatResponse {
            model: req.model,
            content: self.reply.into(),
            // Echo tool requests back as a canned call, so tests can assert the
            // tools → adapter → result round-trip through the gateway.
            tool_calls: req.tools.as_ref().map(|_| {
                vec![worker_core::types::ToolCall {
                    id: "call_1".into(),
                    kind: "function".into(),
                    function: worker_core::types::ToolCallFunction {
                        name: "get_weather".into(),
                        arguments: "{\"city\":\"Berlin\"}".into(),
                    },
                }]
            }),
            usage: Usage {
                input_tokens: Some(5),
                output_tokens: Some(3),
                ..Default::default()
            },
        })
    }
}

/// An adapter whose model probe stalls, so the catalog sweep's shape (serial vs concurrent)
/// is observable in wall-clock time.
struct StallAdapter {
    name: String,
    delay: std::time::Duration,
}

#[async_trait]
impl ProviderAdapter for StallAdapter {
    fn name(&self) -> &str {
        &self.name
    }
    fn uses_external_provider(&self) -> bool {
        false
    }
    async fn list_models(&self) -> worker_core::Result<Vec<ModelInfo>> {
        tokio::time::sleep(self.delay).await;
        Ok(vec![ModelInfo {
            name: format!("{}-model", self.name),
            capabilities: vec!["text.extract_json".into()],
            context_length: Some(8000),
            modalities: vec!["text".into()],
            uses_external_provider: false,
        }])
    }
    async fn validate_credentials(&self) -> worker_core::Result<bool> {
        Ok(true)
    }
    async fn run_chat_completion(&self, _req: ChatRequest) -> worker_core::Result<ChatResponse> {
        unimplemented!("stall adapter never runs a job")
    }
}

#[tokio::test]
async fn catalog_probes_run_concurrently_across_adapters() {
    let delay = std::time::Duration::from_millis(300);
    let mut reg = AdapterRegistry::new();
    for i in 0..4 {
        reg.register(Arc::new(StallAdapter {
            name: format!("stalled-{i}"),
            delay,
        }));
    }

    let g = Gateway::new(
        reg,
        RoutingPolicy::default(),
        accept_all_levels(),
        LimitGuard::new(Limits::default()),
        Arc::new(MemoryUsageStore::default()),
    );

    let started = std::time::Instant::now();
    g.refresh_catalog().await;
    let elapsed = started.elapsed();

    assert_eq!(g.model_catalog().len(), 4);
    // Serial probing would take 4 × 300ms; concurrent probing takes ~300ms.
    assert!(
        elapsed < delay * 3,
        "catalog sweep took {elapsed:?}, expected roughly one probe delay ({delay:?})"
    );
}

async fn gateway_with(policy: RoutingPolicy) -> Gateway {
    let mut reg = AdapterRegistry::new();
    reg.register(Arc::new(FakeAdapter {
        name: "ollama",
        external: false,
        reply: "local-out",
    }));
    reg.register(Arc::new(FakeAdapter {
        name: "openai",
        external: true,
        reply: "remote-out",
    }));
    let g = Gateway::new(
        reg,
        policy,
        accept_all_levels(),
        LimitGuard::new(Limits::default()),
        Arc::new(MemoryUsageStore::default()),
    );
    g.refresh_catalog().await;
    g
}

/// Every privacy level accepted, so a test exercises the axis it is about rather than
/// tripping the accepted-levels gate. Tests for that gate build their own prefs.
fn accept_all_levels() -> PrivacyPrefs {
    PrivacyPrefs {
        accepted_job_levels: vec![
            PrivacyLevel::Public,
            PrivacyLevel::Private,
            PrivacyLevel::Sensitive,
            PrivacyLevel::LocalOnly,
        ],
        allow_private_jobs: true,
        allow_sensitive_jobs: true,
    }
}

fn job(privacy: PrivacyLevel, allow_external: bool) -> Job {
    Job {
        job_id: "j1".into(),
        lease_id: Some("l1".into()),
        capability: "text.extract_json".into(),
        privacy,
        allow_external_providers: allow_external,
        payload: json!({ "messages": [{ "role": "user", "content": "hi" }] }),
    }
}

#[tokio::test]
async fn public_prefers_local_under_prefer_local() {
    let g = gateway_with(RoutingPolicy::default()).await; // PreferLocal; public runs on local
    let r = g.execute(&job(PrivacyLevel::Public, false)).await;
    assert_eq!(r.status, JobStatus::Ok);
    assert_eq!(r.usage.unwrap().provider, "ollama");
}

#[tokio::test]
async fn local_only_never_hits_external_even_if_only_external_present() {
    // Registry with ONLY an external adapter; a local_only job must be rejected, not routed out.
    let mut reg = AdapterRegistry::new();
    reg.register(Arc::new(FakeAdapter {
        name: "openai",
        external: true,
        reply: "remote-out",
    }));
    let g = Gateway::new(
        reg,
        RoutingPolicy {
            preference: Preference::PreferExternal,
            fallback_to_external_provider: true,
            external_provider_allowed_privacy_levels: vec![
                PrivacyLevel::Public,
                PrivacyLevel::Private,
            ],
        },
        accept_all_levels(),
        LimitGuard::new(Limits::default()),
        Arc::new(MemoryUsageStore::default()),
    );
    g.refresh_catalog().await;

    let r = g.execute(&job(PrivacyLevel::LocalOnly, true)).await;
    assert_eq!(r.status, JobStatus::Rejected);
    assert!(r.reason.unwrap().contains("privacy_violation"));
}

#[tokio::test]
async fn private_routes_external_only_when_permitted() {
    let policy = RoutingPolicy {
        preference: Preference::PreferExternal,
        fallback_to_external_provider: true,
        external_provider_allowed_privacy_levels: vec![PrivacyLevel::Public, PrivacyLevel::Private],
    };
    // Only external adapter available.
    let mut reg = AdapterRegistry::new();
    reg.register(Arc::new(FakeAdapter {
        name: "openai",
        external: true,
        reply: "remote-out",
    }));
    let g = Gateway::new(
        reg,
        policy,
        accept_all_levels(),
        LimitGuard::new(Limits::default()),
        Arc::new(MemoryUsageStore::default()),
    );
    g.refresh_catalog().await;

    // owner forbids external -> rejected
    assert_eq!(
        g.execute(&job(PrivacyLevel::Private, false)).await.status,
        JobStatus::Rejected
    );
    // owner permits external -> ok
    assert_eq!(
        g.execute(&job(PrivacyLevel::Private, true)).await.status,
        JobStatus::Ok
    );
}

#[tokio::test]
async fn requested_model_is_honored_over_default_ordering() {
    // PreferLocal would normally pick the local "ollama-model"; requesting "openai-model"
    // must route to that exact model instead (bug: gateway served whatever was first).
    // Explicit policy: this test exercises model routing on a public+external job, so it
    // must allow external for public (the default now permits external for private only).
    let g = gateway_with(RoutingPolicy {
        preference: Preference::PreferLocal,
        fallback_to_external_provider: false,
        external_provider_allowed_privacy_levels: vec![PrivacyLevel::Public, PrivacyLevel::Private],
    })
    .await;
    let mut j = job(PrivacyLevel::Public, true);
    j.payload = json!({
        "messages": [{ "role": "user", "content": "hi" }],
        "model": "openai-model"
    });

    let r = g.execute(&j).await;
    assert_eq!(r.status, JobStatus::Ok);
    let usage = r.usage.unwrap();
    assert_eq!(usage.provider, "openai");
    assert_eq!(usage.model, "openai-model");
}

#[tokio::test]
async fn unavailable_requested_model_is_rejected_without_substitution() {
    let g = gateway_with(RoutingPolicy::default()).await;
    let mut j = job(PrivacyLevel::Public, false);
    j.payload["model"] = json!("missing-model");
    let r = g.execute(&j).await;
    assert_eq!(r.status, JobStatus::Rejected);
    assert_eq!(
        r.reason.as_deref(),
        Some("model_unavailable: missing-model")
    );
}

#[tokio::test]
async fn invalid_strict_json_is_an_error_not_a_best_effort_reply() {
    let g = gateway_with(RoutingPolicy::default()).await;
    let mut j = job(PrivacyLevel::Public, false);
    j.payload["response_format"] = json!({
        "type": "json_schema",
        "json_schema": {
            "name": "answer",
            "strict": true,
            "schema": {"type": "object", "required": ["answer"]}
        }
    });
    let r = g.execute(&j).await;
    assert_eq!(r.status, JobStatus::Error);
    assert!(r.reason.unwrap().starts_with("structured_output_invalid:"));
}

#[tokio::test]
async fn tools_flow_through_payload_and_tool_calls_surface_in_output() {
    let g = gateway_with(RoutingPolicy::default()).await;
    let mut j = job(PrivacyLevel::Public, false);
    j.payload = json!({
        "messages": [{ "role": "user", "content": "weather?" }],
        "tools": [{ "type": "function", "function": { "name": "get_weather", "parameters": {} } }],
        "tool_choice": "auto"
    });

    let r = g.execute(&j).await;
    assert_eq!(r.status, JobStatus::Ok);
    let output = r.output.unwrap();
    let call = &output["tool_calls"][0];
    assert_eq!(call["id"], "call_1");
    assert_eq!(call["type"], "function");
    assert_eq!(call["function"]["name"], "get_weather");
    assert_eq!(call["function"]["arguments"], "{\"city\":\"Berlin\"}");
}

#[tokio::test]
async fn plain_chat_output_has_no_tool_calls_key() {
    let g = gateway_with(RoutingPolicy::default()).await;
    let r = g.execute(&job(PrivacyLevel::Public, false)).await;
    assert!(r.output.unwrap().get("tool_calls").is_none());
}

#[tokio::test]
async fn result_carries_no_secret() {
    let g = gateway_with(RoutingPolicy::default()).await;
    let r = g.execute(&job(PrivacyLevel::Public, false)).await;
    let serialized = serde_json::to_string(&r).unwrap().to_lowercase();
    // Secret-shaped patterns. Note: token *counts* (input_tokens) are fine; a bare
    // `"token"` key or an `sk-`/`bearer` value is not.
    for needle in [
        "\"token\"",
        "api_key",
        "authorization",
        "x-api-key",
        "bearer ",
        "sk-",
        "secret",
    ] {
        assert!(
            !serialized.contains(needle),
            "job result leaked `{needle}`: {serialized}"
        );
    }
}

// ---- accepted_job_levels enforcement ---------------------------------------------------------

fn accepting(levels: Vec<PrivacyLevel>) -> PrivacyPrefs {
    PrivacyPrefs {
        accepted_job_levels: levels,
        allow_private_jobs: true,
        allow_sensitive_jobs: true,
    }
}

async fn gateway_accepting(levels: Vec<PrivacyLevel>) -> Gateway {
    let mut reg = AdapterRegistry::new();
    reg.register(Arc::new(FakeAdapter {
        name: "ollama",
        external: false,
        reply: "local-out",
    }));
    let g = Gateway::new(
        reg,
        RoutingPolicy::default(),
        accepting(levels),
        LimitGuard::new(Limits::default()),
        Arc::new(MemoryUsageStore::default()),
    );
    g.refresh_catalog().await;
    g
}

#[tokio::test]
async fn a_job_above_the_accepted_levels_is_refused_even_on_a_local_model() {
    // The operator's machine takes public work only. A local model could physically serve a
    // sensitive job, which is exactly why the coordinator's routing decision is not enough:
    // refusing sensitive work is a statement about the machine.
    let g = gateway_accepting(vec![PrivacyLevel::Public]).await;

    let r = g.execute(&job(PrivacyLevel::Sensitive, false)).await;
    assert_eq!(r.status, JobStatus::Rejected);
    let reason = r.reason.unwrap();
    assert!(reason.contains("privacy_violation"), "reason: {reason}");
    assert!(reason.contains("sensitive"), "reason: {reason}");
}

#[tokio::test]
async fn accepted_levels_admit_the_levels_they_list() {
    let g = gateway_accepting(vec![PrivacyLevel::Public, PrivacyLevel::Sensitive]).await;

    assert_eq!(
        g.execute(&job(PrivacyLevel::Public, false)).await.status,
        JobStatus::Ok
    );
    assert_eq!(
        g.execute(&job(PrivacyLevel::Sensitive, false)).await.status,
        JobStatus::Ok
    );
    assert_eq!(
        g.execute(&job(PrivacyLevel::Private, false)).await.status,
        JobStatus::Rejected
    );
}

// ---- preference as a hard constraint ---------------------------------------------------------

async fn gateway_external_only_registry(policy: RoutingPolicy) -> Gateway {
    let mut reg = AdapterRegistry::new();
    reg.register(Arc::new(FakeAdapter {
        name: "openai",
        external: true,
        reply: "remote-out",
    }));
    let g = Gateway::new(
        reg,
        policy,
        accept_all_levels(),
        LimitGuard::new(Limits::default()),
        Arc::new(MemoryUsageStore::default()),
    );
    g.refresh_catalog().await;
    g
}

#[tokio::test]
async fn local_only_preference_refuses_rather_than_routing_out() {
    // `LocalOnly` was applied as a sort key, so with no local candidate it still routed to an
    // external provider — the opposite of what the setting says.
    let g = gateway_external_only_registry(RoutingPolicy {
        preference: Preference::LocalOnly,
        fallback_to_external_provider: true,
        external_provider_allowed_privacy_levels: vec![PrivacyLevel::Public],
    })
    .await;

    assert_eq!(
        g.execute(&job(PrivacyLevel::Public, true)).await.status,
        JobStatus::Rejected
    );
}

#[tokio::test]
async fn external_only_preference_ignores_local_backends() {
    let mut reg = AdapterRegistry::new();
    reg.register(Arc::new(FakeAdapter {
        name: "ollama",
        external: false,
        reply: "local-out",
    }));
    let g = Gateway::new(
        reg,
        RoutingPolicy {
            preference: Preference::ExternalOnly,
            fallback_to_external_provider: true,
            external_provider_allowed_privacy_levels: vec![PrivacyLevel::Public],
        },
        accept_all_levels(),
        LimitGuard::new(Limits::default()),
        Arc::new(MemoryUsageStore::default()),
    );
    g.refresh_catalog().await;

    assert_eq!(
        g.execute(&job(PrivacyLevel::Public, true)).await.status,
        JobStatus::Rejected
    );
}

// ---- fallback_to_external_provider -----------------------------------------------------------

#[tokio::test]
async fn without_fallback_a_local_capable_worker_does_not_reach_for_a_provider() {
    // Both backends serve the capability. `fallback_to_external_provider: false` means the
    // provider is not an option while a local backend could do the work.
    let g = gateway_with(RoutingPolicy {
        preference: Preference::PreferLocal,
        fallback_to_external_provider: false,
        external_provider_allowed_privacy_levels: vec![PrivacyLevel::Public],
    })
    .await;

    let r = g.execute(&job(PrivacyLevel::Public, true)).await;
    assert_eq!(r.status, JobStatus::Ok);
    assert_eq!(r.usage.unwrap().provider, "ollama");
}

#[tokio::test]
async fn without_fallback_a_provider_only_worker_still_works() {
    // No local candidate exists, so there is nothing to fall back *from*.
    let g = gateway_external_only_registry(RoutingPolicy {
        preference: Preference::PreferLocal,
        fallback_to_external_provider: false,
        external_provider_allowed_privacy_levels: vec![PrivacyLevel::Public],
    })
    .await;

    assert_eq!(
        g.execute(&job(PrivacyLevel::Public, true)).await.status,
        JobStatus::Ok
    );
}

// ---- lock poisoning ---------------------------------------------------------------------------

/// An adapter that panics on every call, to poison whatever lock is held around it.
struct PanickingAdapter;

#[async_trait]
impl ProviderAdapter for PanickingAdapter {
    fn name(&self) -> &str {
        "panicky"
    }
    fn uses_external_provider(&self) -> bool {
        false
    }
    async fn list_models(&self) -> worker_core::error::Result<Vec<ModelInfo>> {
        panic!("catalog probe blew up")
    }
    async fn validate_credentials(&self) -> worker_core::error::Result<bool> {
        Ok(true)
    }
    async fn run_chat_completion(
        &self,
        _req: ChatRequest,
    ) -> worker_core::error::Result<ChatResponse> {
        panic!("inference blew up")
    }
}

#[tokio::test]
async fn a_panicking_adapter_does_not_break_subsequent_jobs() {
    // The catalog lock was acquired with `.expect("catalog lock poisoned")`. One panic in an
    // adapter task holding it poisoned the lock, and every later job panicked on acquire — one
    // recoverable failure turned into a permanently dead worker.
    let mut reg = AdapterRegistry::new();
    reg.register(Arc::new(PanickingAdapter));
    reg.register(Arc::new(FakeAdapter {
        name: "ollama",
        external: false,
        reply: "still working",
    }));

    let g = Gateway::new(
        reg,
        RoutingPolicy::default(),
        accept_all_levels(),
        LimitGuard::new(Limits::default()),
        Arc::new(MemoryUsageStore::default()),
    );

    // The panicking probe runs while the catalog write lock is held.
    g.refresh_catalog().await;

    // The healthy backend is still reachable, and the gateway still serves jobs.
    assert!(
        !g.model_catalog().is_empty(),
        "the healthy adapter is catalogued"
    );

    let r = g.execute(&job(PrivacyLevel::Public, false)).await;
    assert_eq!(r.status, JobStatus::Ok);
    assert_eq!(r.usage.unwrap().provider, "ollama");
}
