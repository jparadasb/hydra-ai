//! The unifying [`ProviderAdapter`] abstraction. Local runtimes and external APIs all
//! appear as different backends behind this one trait.

use async_trait::async_trait;
use std::collections::HashMap;
use std::sync::Arc;

use crate::error::{Error, Result};
use crate::types::{
    ChatRequest, ChatResponse, CostEstimate, ModelInfo, Usage, VisionRequest, VisionResponse,
};

/// Receives streamed content fragments during a chat completion. `Arc` (not `&dyn`) so the
/// `async_trait`-boxed futures can hold it without lifetime gymnastics.
pub type DeltaSink = Arc<dyn Fn(&str) + Send + Sync>;

/// A backend the worker can run jobs against (OpenAI, Anthropic, Ollama, …).
#[async_trait]
pub trait ProviderAdapter: Send + Sync {
    /// Stable adapter/provider name, e.g. `"openai"`, `"ollama"`.
    fn name(&self) -> &str;

    /// `true` if calls leave the machine to a third-party provider. Drives privacy routing.
    fn uses_external_provider(&self) -> bool;

    /// Models this adapter exposes.
    async fn list_models(&self) -> Result<Vec<ModelInfo>>;

    /// Cheap credential / connectivity check. `Ok(true)` means usable.
    async fn validate_credentials(&self) -> Result<bool>;

    /// Run a chat completion.
    async fn run_chat_completion(&self, req: ChatRequest) -> Result<ChatResponse>;

    /// Run a chat completion, invoking `on_delta` with each content fragment as the backend
    /// streams it. The returned [`ChatResponse`] is still the complete, authoritative result.
    /// Default: no streaming support — one blocking call, no deltas emitted.
    async fn run_chat_completion_streaming(
        &self,
        req: ChatRequest,
        _on_delta: DeltaSink,
    ) -> Result<ChatResponse> {
        self.run_chat_completion(req).await
    }

    /// Run a vision/multimodal task. Default: unsupported.
    async fn run_vision_task(&self, _req: VisionRequest) -> Result<VisionResponse> {
        Err(Error::Other(format!(
            "{} does not support vision tasks",
            self.name()
        )))
    }

    /// Estimate cost for some usage. Local runtimes return `None` (free).
    fn estimate_cost(&self, _usage: &Usage) -> Option<CostEstimate> {
        None
    }
}

/// Registry of adapters keyed by provider name.
#[derive(Default, Clone)]
pub struct AdapterRegistry {
    adapters: HashMap<String, Arc<dyn ProviderAdapter>>,
}

impl AdapterRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&mut self, adapter: Arc<dyn ProviderAdapter>) {
        self.adapters.insert(adapter.name().to_string(), adapter);
    }

    pub fn get(&self, name: &str) -> Result<Arc<dyn ProviderAdapter>> {
        self.adapters
            .get(name)
            .cloned()
            .ok_or_else(|| Error::UnknownAdapter(name.to_string()))
    }

    pub fn names(&self) -> Vec<String> {
        self.adapters.keys().cloned().collect()
    }

    /// All registered adapters.
    pub fn iter(&self) -> impl Iterator<Item = &Arc<dyn ProviderAdapter>> {
        self.adapters.values()
    }
}
