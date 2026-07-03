//! End-to-end gateway behaviour: privacy routing across local vs external backends, plus the
//! critical secret-leak assertions on everything that crosses the coordinator boundary.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::json;

use worker_core::adapter::{AdapterRegistry, ProviderAdapter};
use worker_core::config::{Preference, RoutingPolicy};
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
            usage: Usage {
                input_tokens: 5,
                output_tokens: 3,
                ..Default::default()
            },
        })
    }
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
    let mut g = Gateway::new(
        reg,
        policy,
        LimitGuard::new(Limits::default()),
        Arc::new(MemoryUsageStore::default()),
    );
    g.refresh_catalog().await;
    g
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
    let g = gateway_with(RoutingPolicy::default()).await; // PreferLocal, external allowed for public
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
    let mut g = Gateway::new(
        reg,
        RoutingPolicy {
            preference: Preference::PreferExternal,
            fallback_to_external_provider: true,
            external_provider_allowed_privacy_levels: vec![
                PrivacyLevel::Public,
                PrivacyLevel::Private,
            ],
        },
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
    let mut g = Gateway::new(
        reg,
        policy,
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
    let g = gateway_with(RoutingPolicy::default()).await;
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
