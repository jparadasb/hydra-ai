//! The execution gateway: turns a leased [`Job`] into a [`JobResult`] by selecting a backend,
//! enforcing privacy + limits, running the adapter, and recording usage.
//!
//! This is where the worker's three guarantees meet:
//!   * **privacy** — [`crate::privacy::check`] gates external backends per job level;
//!   * **limits**  — [`LimitGuard`] reserves before any paid call;
//!   * **locality** — secrets stay inside the adapter; the result carries usage, never tokens.

use std::sync::{Arc, RwLock};
use std::time::Duration;
use std::time::Instant;

use crate::adapter::{AdapterRegistry, DeltaSink, ProviderAdapter};
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
    catalog: RwLock<Vec<(String, ModelInfo)>>,
}

impl Gateway {
    const CATALOG_PROBE_TIMEOUT: Duration = Duration::from_secs(10);
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
            catalog: RwLock::new(Vec::new()),
        }
    }

    /// Probe every adapter's models and cache the capability catalog. Call at startup and
    /// whenever providers/models change.
    pub async fn refresh_catalog(&self) {
        // Probe every adapter at once: the timeout is per adapter, so a serial sweep would
        // stall startup for `timeout × adapter count` against silent or firewalled hosts.
        let probes = self.registry.iter().map(|adapter| async move {
            let name = adapter.name().to_string();
            let probe = tokio::time::timeout(Self::CATALOG_PROBE_TIMEOUT, adapter.list_models());
            (name, probe.await)
        });

        let mut catalog = Vec::new();
        for (name, outcome) in futures_util::future::join_all(probes).await {
            match outcome {
                Ok(Ok(models)) => {
                    for m in models {
                        catalog.push((name.clone(), m));
                    }
                }
                Ok(Err(error)) => eprintln!("Model catalog probe failed for {name}: {error}"),
                Err(_) => eprintln!("Model catalog probe timed out for {name}"),
            }
        }
        let mut current = self.catalog.write().expect("catalog lock poisoned");
        let changed = current.len() != catalog.len();
        *current = catalog;
        if changed {
            eprintln!("Model catalog refreshed: {} model(s).", current.len());
        }
    }

    /// Seed the catalog directly (tests / static configs).
    pub fn set_catalog(&self, catalog: Vec<(String, ModelInfo)>) {
        *self.catalog.write().expect("catalog lock poisoned") = catalog;
    }

    /// The discovered models, for building the registration payload.
    pub fn model_catalog(&self) -> Vec<ModelInfo> {
        self.catalog
            .read()
            .expect("catalog lock poisoned")
            .iter()
            .map(|(_, m)| m.clone())
            .collect()
    }

    fn candidates_for(&self, capability: &str) -> Vec<Candidate> {
        let catalog = self.catalog.read().expect("catalog lock poisoned");
        let mut cands: Vec<Candidate> = catalog
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
        self.execute_streaming(job, Arc::new(|_, _| {})).await
    }

    /// Like [`Gateway::execute`], but forwards each streamed content fragment to `on_delta`
    /// while the backend generates (backends without streaming emit no deltas). The returned
    /// [`JobResult`] is the complete, authoritative output either way.
    pub async fn execute_streaming(&self, job: &Job, on_delta: DeltaSink) -> JobResult {
        let reject = |reason: &str| JobResult {
            job_id: job.job_id.clone(),
            lease_id: job.lease_id.clone(),
            status: JobStatus::Rejected,
            reason: Some(reason.to_string()),
            output: None,
            usage: None,
        };

        // 1. Pick the first privacy-compatible candidate. A requested model is an exact
        //    constraint: silently substituting a different model violates the API contract.
        let requested_model = job.payload.get("model").and_then(|v| v.as_str());
        let mut candidates = self.candidates_for(&job.capability);
        if let Some(req) = requested_model {
            candidates.retain(|c| c.model.name == req);
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
                    .unwrap_or_else(|| {
                        requested_model
                            .map(|m| format!("model_unavailable: {m}"))
                            .unwrap_or_else(|| format!("no_capable_backend: {}", job.capability))
                    })
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

        // 3. Count every request; provider calls additionally consume a provider slot.
        let reservation = match self
            .limits
            .try_reserve(cand.adapter.uses_external_provider())
        {
            Ok(r) => r,
            Err(e) => return reject(&format!("limit_exceeded: {e}")),
        };

        let strict_schema = match strict_json_schema(req.response_format.as_ref()) {
            Ok(schema) => schema,
            Err(e) => return error_result(job, &format!("bad_payload: {e}")),
        };
        let must_buffer = strict_schema.is_some() || req.tools.is_some();
        let backend_sink = if must_buffer {
            Arc::new(|_: &str, _: bool| {}) as DeltaSink
        } else {
            on_delta.clone()
        };

        // 4. Run.
        let started = Instant::now();
        let tools = req.tools.clone();
        let result = cand
            .adapter
            .run_chat_completion_streaming(req, backend_sink)
            .await;
        let latency_ms = started.elapsed().as_secs_f64() * 1000.0;
        let provider = cand.adapter.name().to_string();
        let model = cand.model.name.clone();

        match result {
            Ok(mut resp) => {
                if resp.tool_calls.is_none() {
                    if let Some(offered) = tools.as_ref() {
                        match crate::adapters::tools::normalize_tool_markup(&resp.content, offered)
                        {
                            Ok(Some((content, calls))) => {
                                resp.content = content;
                                resp.tool_calls = Some(calls);
                            }
                            Ok(None) => {}
                            Err(e) => return error_result(job, &e.to_string()),
                        }
                    }
                }
                if let Some(schema) = strict_schema {
                    match validate_json_output(&resp.content, &schema) {
                        Ok(content) => resp.content = content,
                        Err(e) => {
                            return error_result(job, &format!("structured_output_invalid: {e}"))
                        }
                    }
                }
                if must_buffer && !resp.content.is_empty() {
                    on_delta(&resp.content, false);
                }
                let cost = cand
                    .adapter
                    .estimate_cost(&resp.usage)
                    .map(|c| c.usd)
                    .unwrap_or(0.0);
                drop(reservation);
                self.record(&provider, &model, &resp.usage, cost, latency_ms, true);
                let mut output = serde_json::json!({ "content": resp.content });
                if let Some(calls) = &resp.tool_calls {
                    output["tool_calls"] = serde_json::json!(calls);
                }
                JobResult {
                    job_id: job.job_id.clone(),
                    lease_id: job.lease_id.clone(),
                    status: JobStatus::Ok,
                    reason: None,
                    output: Some(output),
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
                drop(reservation);
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

fn error_result(job: &Job, reason: &str) -> JobResult {
    JobResult {
        job_id: job.job_id.clone(),
        lease_id: job.lease_id.clone(),
        status: JobStatus::Error,
        reason: Some(reason.to_string()),
        output: None,
        usage: None,
    }
}

fn strict_json_schema(
    format: Option<&serde_json::Value>,
) -> Result<Option<serde_json::Value>, String> {
    let Some(format) = format else {
        return Ok(None);
    };
    if format.get("type").and_then(|v| v.as_str()) != Some("json_schema") {
        return Err("unsupported_response_format".into());
    }
    let definition = format
        .get("json_schema")
        .and_then(|v| v.as_object())
        .ok_or("response_format.json_schema is required")?;
    if definition.get("strict").and_then(|v| v.as_bool()) != Some(true) {
        return Err("only strict JSON schemas are supported".into());
    }
    definition
        .get("schema")
        .cloned()
        .map(Some)
        .ok_or_else(|| "response_format.json_schema.schema is required".into())
}

fn validate_json_output(content: &str, schema: &serde_json::Value) -> Result<String, String> {
    let trimmed = content.trim();
    let json_text = if trimmed.starts_with("```") && trimmed.ends_with("```") {
        let inner = trimmed
            .strip_prefix("```json")
            .or_else(|| trimmed.strip_prefix("```"))
            .ok_or("invalid JSON fence")?;
        inner.strip_suffix("```").unwrap_or(inner).trim()
    } else {
        trimmed
    };
    let instance: serde_json::Value = serde_json::from_str(json_text).map_err(|e| e.to_string())?;
    let validator =
        jsonschema::validator_for(schema).map_err(|e| format!("invalid schema: {e}"))?;
    validator.validate(&instance).map_err(|e| e.to_string())?;
    serde_json::to_string(&instance).map_err(|e| e.to_string())
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
        tools: payload.get("tools").filter(|v| !v.is_null()).cloned(),
        tool_choice: payload.get("tool_choice").filter(|v| !v.is_null()).cloned(),
        response_format: payload
            .get("response_format")
            .filter(|v| !v.is_null())
            .cloned(),
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
