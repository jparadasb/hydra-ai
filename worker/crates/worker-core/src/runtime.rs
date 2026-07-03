//! Local runtime management: hardware detection, connecting to a local runtime, and a small
//! benchmark used to register local capabilities.
//!
//! First-class runtime is Ollama; llama.cpp / LM Studio / vLLM plug in behind the same
//! [`crate::adapter::ProviderAdapter`] trait and reuse the probe/benchmark flow here.

use std::time::Instant;

use serde::{Deserialize, Serialize};

use crate::adapter::ProviderAdapter;
use crate::types::{ChatMessage, ChatRequest};

/// Coarse hardware snapshot used to decide which local models are viable.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HardwareInfo {
    pub cpu_count: usize,
    pub total_memory_mb: u64,
    pub available_memory_mb: u64,
    /// Best-effort GPU descriptors; empty when none detected/available.
    pub gpus: Vec<String>,
}

impl HardwareInfo {
    /// Detect CPU/memory via `sysinfo`. GPU detection is best-effort and may be empty.
    pub fn detect() -> Self {
        use sysinfo::System;
        let mut sys = System::new();
        sys.refresh_memory();
        sys.refresh_cpu_usage();
        HardwareInfo {
            cpu_count: sys.cpus().len().max(num_cpus_fallback()),
            total_memory_mb: sys.total_memory() / 1_048_576,
            available_memory_mb: sys.available_memory() / 1_048_576,
            gpus: detect_gpus(),
        }
    }
}

fn num_cpus_fallback() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1)
}

/// Best-effort GPU detection without native GPU libs: inspect well-known sysfs/dev nodes.
fn detect_gpus() -> Vec<String> {
    let mut gpus = Vec::new();
    // NVIDIA
    if std::path::Path::new("/proc/driver/nvidia/gpus").exists() {
        gpus.push("nvidia".to_string());
    }
    // Apple Metal (macOS)
    if cfg!(target_os = "macos") {
        gpus.push("apple-metal".to_string());
    }
    // Generic DRM render nodes (Linux)
    if let Ok(rd) = std::fs::read_dir("/dev/dri") {
        if rd
            .filter_map(|e| e.ok())
            .any(|e| e.file_name().to_string_lossy().starts_with("renderD"))
            && !gpus.iter().any(|g| g == "nvidia")
        {
            gpus.push("drm-render".to_string());
        }
    }
    gpus
}

/// Result of benchmarking one model through an adapter.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BenchmarkResult {
    pub model: String,
    pub ok: bool,
    pub latency_ms: f64,
    pub tokens_per_sec: f64,
}

/// Run a tiny prompt through `adapter` for `model` and time it. Used to decide whether a
/// locally-pulled model is fast enough to register, and to seed latency for scheduling.
pub async fn benchmark(adapter: &dyn ProviderAdapter, model: &str) -> BenchmarkResult {
    let req = ChatRequest {
        model: model.to_string(),
        messages: vec![ChatMessage {
            role: "user".into(),
            content: "Reply with the single word: ok".into(),
            ..Default::default()
        }],
        max_tokens: Some(16),
        temperature: Some(0.0),
        tools: None,
        tool_choice: None,
    };
    let start = Instant::now();
    match adapter.run_chat_completion(req).await {
        Ok(resp) => {
            let latency_ms = start.elapsed().as_secs_f64() * 1000.0;
            let tps = if latency_ms > 0.0 {
                resp.usage.output_tokens as f64 / (latency_ms / 1000.0)
            } else {
                0.0
            };
            BenchmarkResult {
                model: model.to_string(),
                ok: true,
                latency_ms,
                tokens_per_sec: tps,
            }
        }
        Err(_) => BenchmarkResult {
            model: model.to_string(),
            ok: false,
            latency_ms: start.elapsed().as_secs_f64() * 1000.0,
            tokens_per_sec: 0.0,
        },
    }
}

/// Probe a local runtime by listing its models. `Ok(models)` means it is reachable.
pub async fn probe(adapter: &dyn ProviderAdapter) -> crate::error::Result<Vec<String>> {
    Ok(adapter
        .list_models()
        .await?
        .into_iter()
        .map(|m| m.name)
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hardware_detect_is_sane() {
        let hw = HardwareInfo::detect();
        assert!(hw.cpu_count >= 1);
        assert!(hw.total_memory_mb >= 1);
    }
}
