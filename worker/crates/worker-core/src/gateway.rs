//! The execution gateway: turns a leased [`Job`] into a [`JobResult`] by selecting a backend,
//! enforcing privacy + limits, running the adapter, and recording usage.
//!
//! This is where the worker's three guarantees meet:
//!   * **privacy** — [`crate::privacy::check`] gates external backends per job level;
//!   * **limits**  — [`LimitGuard`] reserves before any paid call;
//!   * **locality** — secrets stay inside the adapter; the result carries usage, never tokens.

use std::sync::Arc;
use std::time::Instant;

use crate::adapter::{AdapterRegistry, ProviderAdapter};
use crate::config::{Preference, RoutingPolicy};
use crate::limits::LimitGuard;
use crate::privacy::{self, Decision};
use crate::types::{ChatRequest, Job, JobResult, JobStatus, ModelInfo, ResultUsage, Usage};
use crate::usage::{CallOutcome, UsageStore};

/// A capability candidate: which adapter + model can serve it.
struct Candidate {
    adapter: Arc<dyn ProviderAdapter>,
    model: ModelInfo,
}

pub struct Gateway {
    registry: AdapterRegistry,
    policy: RoutingPolicy,
    limits: LimitGuard,
    usage: Arc<dyn UsageStore>,
    /// Cached (adapter, model) catalog, refreshed via [`Gateway::refresh_catalog`].
    catalog: Vec<(String, ModelInfo)>,
}

impl Gateway {
    pub fn new(
        registry: AdapterRegistry,
        policy: RoutingPolicy,
        limits: LimitGuard,
        usage: Arc<dyn UsageStore>,
    ) -> Self {
        Self {
            registry,
            policy,
            limits,
            usage,
            catalog: Vec::new(),
        }
    }

    /// Probe every adapter's models and cache the capability catalog. Call at startup and
    /// whenever providers/models change.
    pub async fn refresh_catalog(&mut self) {
        let mut catalog = Vec::new();
        for adapter in self.registry.iter() {
            if let Ok(models) = adapter.list_models().await {
                for m in models {
                    catalog.push((adapter.name().to_string(), m));
                }
            }
        }
        self.catalog = catalog;
    }

    /// Seed the catalog directly (tests / static configs).
    pub fn set_catalog(&mut self, catalog: Vec<(String, ModelInfo)>) {
        self.catalog = catalog;
    }

    /// The discovered models, for building the registration payload.
    pub fn model_catalog(&self) -> Vec<ModelInfo> {
        self.catalog.iter().map(|(_, m)| m.clone()).collect()
    }

    fn candidates_for(&self, capability: &str) -> Vec<Candidate> {
        let mut cands: Vec<Candidate> = self
            .catalog
            .iter()
            .filter(|(_, m)| m.capabilities.iter().any(|c| c == capability))
            .filter_map(|(name, m)| {
                self.registry.get(name).ok().map(|adapter| Candidate {
                    adapter,
                    model: m.clone(),
                })
            })
            .collect();

        // Order by routing preference. PreferLocal => local backends first.
        let local_first = matches!(
            self.policy.preference,
            Preference::PreferLocal | Preference::LocalOnly
        );
        cands.sort_by_key(|c| {
            let is_external = c.adapter.uses_external_provider();
            if local_first {
                is_external as u8 // local (false=0) first
            } else {
                !is_external as u8 // external first
            }
        });
        cands
    }

    /// Execute a leased job end to end. Never panics; failures map to a [`JobResult`].
    pub async fn execute(&self, job: &Job) -> JobResult {
        let reject = |reason: &str| JobResult {
            job_id: job.job_id.clone(),
            lease_id: job.lease_id.clone(),
            status: JobStatus::Rejected,
            reason: Some(reason.to_string()),
            output: None,
            usage: None,
        };

        // 1. Pick the first candidate allowed by the privacy policy. If the job requested a
        //    specific model, prefer the candidate serving that exact model (over the default
        //    first-capable one) so `model: qwen…` isn't answered by whatever model happens to
        //    be first. Falls back to any capable model when the requested one isn't available.
        let requested_model = job.payload.get("model").and_then(|v| v.as_str());
        let mut candidates = self.candidates_for(&job.capability);
        if let Some(req) = requested_model {
            // Stable sort keeps the local-first ordering within each group.
            candidates.sort_by_key(|c| c.model.name != req);
        }

        let mut chosen: Option<Candidate> = None;
        let mut last_denial: Option<&'static str> = None;
        for cand in candidates {
            match privacy::check(
                job.privacy,
                job.allow_external_providers,
                cand.adapter.uses_external_provider(),
                &self.policy,
            ) {
                Decision::Allow => {
                    chosen = Some(cand);
                    break;
                }
                Decision::Deny(why) => last_denial = Some(why),
            }
        }
        let Some(cand) = chosen else {
            return reject(
                last_denial
                    .map(|d| format!("privacy_violation: {d}"))
                    .unwrap_or_else(|| format!("no_capable_backend: {}", job.capability))
                    .as_str(),
            );
        };

        // 2. Parse the payload into a chat request.
        let req: ChatRequest = match parse_chat(&cand.model.name, &job.payload) {
            Ok(r) => r,
            Err(e) => {
                return JobResult {
                    job_id: job.job_id.clone(),
                    lease_id: job.lease_id.clone(),
                    status: JobStatus::Error,
                    reason: Some(format!("bad_payload: {e}")),
                    output: None,
                    usage: None,
                };
            }
        };

        // 3. Reserve against limits (only meaningful for paid external backends).
        let reservation = if cand.adapter.uses_external_provider() {
            match self.limits.try_reserve(0.0) {
                Ok(r) => Some(r),
                Err(e) => return reject(&format!("limit_exceeded: {e}")),
            }
        } else {
            None
        };

        // 4. Run.
        let started = Instant::now();
        let result = cand.adapter.run_chat_completion(req).await;
        let latency_ms = started.elapsed().as_secs_f64() * 1000.0;
        let provider = cand.adapter.name().to_string();
        let model = cand.model.name.clone();

        match result {
            Ok(resp) => {
                let cost = cand
                    .adapter
                    .estimate_cost(&resp.usage)
                    .map(|c| c.usd)
                    .unwrap_or(0.0);
                if let Some(r) = reservation {
                    r.commit_cost(cost);
                }
                self.record(&provider, &model, &resp.usage, cost, latency_ms, true);
                JobResult {
                    job_id: job.job_id.clone(),
                    lease_id: job.lease_id.clone(),
                    status: JobStatus::Ok,
                    reason: None,
                    output: Some(serde_json::json!({ "content": resp.content })),
                    usage: Some(ResultUsage {
                        provider,
                        model,
                        input_tokens: resp.usage.input_tokens,
                        output_tokens: resp.usage.output_tokens,
                        latency_ms,
                    }),
                }
            }
            Err(e) => {
                drop(reservation); // releases the parallel slot; no cost committed
                self.record(&provider, &model, &Usage::default(), 0.0, latency_ms, false);
                JobResult {
                    job_id: job.job_id.clone(),
                    lease_id: job.lease_id.clone(),
                    status: JobStatus::Error,
                    reason: Some(format!("provider_error: {e}")),
                    output: None,
                    usage: None,
                }
            }
        }
    }

    fn record(
        &self,
        provider: &str,
        model: &str,
        usage: &Usage,
        cost: f64,
        latency_ms: f64,
        ok: bool,
    ) {
        let period = current_month();
        let _ = self.usage.record(
            &period,
            &CallOutcome {
                provider: provider.to_string(),
                model: model.to_string(),
                usage: usage.clone(),
                cost_usd: cost,
                latency_ms,
                success: ok,
            },
        );
    }
}

fn parse_chat(model: &str, payload: &serde_json::Value) -> crate::error::Result<ChatRequest> {
    let messages = serde_json::from_value(payload.get("messages").cloned().unwrap_or_default())?;
    Ok(ChatRequest {
        model: model.to_string(),
        messages,
        max_tokens: payload
            .get("max_tokens")
            .and_then(|v| v.as_u64())
            .map(|v| v as u32),
        temperature: payload
            .get("temperature")
            .and_then(|v| v.as_f64())
            .map(|v| v as f32),
    })
}

/// UTC `YYYY-MM` for the current month, derived without pulling in a date crate.
fn current_month() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let days = secs / 86_400;
    let (y, m, _d) = civil_from_days(days as i64);
    format!("{y:04}-{m:02}")
}

/// Howard Hinnant's days→civil date algorithm.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}
