//! Usage tracking for external-provider calls.
//!
//! Records per `(provider, model, period)` rollups locally. The aggregated report (no
//! secrets) is what the worker may optionally forward to the coordinator.
//!
//! The store here is a JSON file for simplicity and testability; swapping in SQLite means
//! implementing [`UsageStore`] against `rusqlite` without touching call sites.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};
use crate::types::Usage;

/// One rollup row, mirroring `proto/usage_report.schema.json`.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct UsageRecord {
    pub provider: String,
    pub model: String,
    pub period: String,
    pub requests: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub image_units: u64,
    pub audio_units: u64,
    pub estimated_cost_usd: f64,
    pub successful_jobs: u64,
    pub failed_jobs: u64,
    /// Sum of latencies; divide by `requests` for the average reported externally.
    pub total_latency_ms: f64,
}

impl UsageRecord {
    pub fn average_latency_ms(&self) -> f64 {
        if self.requests == 0 {
            0.0
        } else {
            self.total_latency_ms / self.requests as f64
        }
    }
}

/// The outcome of a single recorded call.
pub struct CallOutcome {
    pub provider: String,
    pub model: String,
    pub usage: Usage,
    pub cost_usd: f64,
    pub latency_ms: f64,
    pub success: bool,
}

/// Persistence backend for usage rollups.
pub trait UsageStore: Send + Sync {
    fn record(&self, period: &str, outcome: &CallOutcome) -> Result<()>;
    /// All records, optionally filtered by period (`YYYY-MM` matches its days too).
    fn query(&self, period: Option<&str>) -> Result<Vec<UsageRecord>>;
}

fn key(provider: &str, model: &str, period: &str) -> String {
    format!("{provider}\u{1f}{model}\u{1f}{period}")
}

fn apply(rec: &mut UsageRecord, o: &CallOutcome, period: &str) {
    rec.provider = o.provider.clone();
    rec.model = o.model.clone();
    rec.period = period.to_string();
    rec.requests += 1;
    rec.input_tokens += o.usage.input_tokens;
    rec.output_tokens += o.usage.output_tokens;
    rec.image_units += o.usage.image_units;
    rec.audio_units += o.usage.audio_units;
    rec.estimated_cost_usd += o.cost_usd;
    rec.total_latency_ms += o.latency_ms;
    if o.success {
        rec.successful_jobs += 1;
    } else {
        rec.failed_jobs += 1;
    }
}

/// In-memory store (used in tests and as a JSON-store building block).
#[derive(Default)]
pub struct MemoryUsageStore {
    rows: Mutex<HashMap<String, UsageRecord>>,
}

impl UsageStore for MemoryUsageStore {
    fn record(&self, period: &str, outcome: &CallOutcome) -> Result<()> {
        let mut rows = self.rows.lock().unwrap();
        let rec = rows
            .entry(key(&outcome.provider, &outcome.model, period))
            .or_default();
        apply(rec, outcome, period);
        Ok(())
    }

    fn query(&self, period: Option<&str>) -> Result<Vec<UsageRecord>> {
        let rows = self.rows.lock().unwrap();
        Ok(rows
            .values()
            .filter(|r| period.map(|p| r.period.starts_with(p)).unwrap_or(true))
            .cloned()
            .collect())
    }
}

/// JSON-file backed store. Loads/saves the whole map per write (fine for worker volumes).
pub struct JsonUsageStore {
    path: PathBuf,
    cache: Mutex<HashMap<String, UsageRecord>>,
}

impl JsonUsageStore {
    pub fn new(path: PathBuf) -> Result<Self> {
        let cache = match std::fs::read(&path) {
            Ok(b) => serde_json::from_slice(&b)?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => HashMap::new(),
            Err(e) => return Err(Error::Other(format!("usage read: {e}"))),
        };
        Ok(Self {
            path,
            cache: Mutex::new(cache),
        })
    }

    pub fn default_path() -> PathBuf {
        directories::ProjectDirs::from("ai", "hydra", "worker")
            .map(|d| d.data_dir().join("usage.json"))
            .unwrap_or_else(|| PathBuf::from(".hydra-usage.json"))
    }

    fn flush(&self, map: &HashMap<String, UsageRecord>) -> Result<()> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| Error::Other(format!("usage mkdir: {e}")))?;
        }
        std::fs::write(&self.path, serde_json::to_vec_pretty(map)?)
            .map_err(|e| Error::Other(format!("usage write: {e}")))
    }
}

impl UsageStore for JsonUsageStore {
    fn record(&self, period: &str, outcome: &CallOutcome) -> Result<()> {
        let mut cache = self.cache.lock().unwrap();
        let rec = cache
            .entry(key(&outcome.provider, &outcome.model, period))
            .or_default();
        apply(rec, outcome, period);
        self.flush(&cache)
    }

    fn query(&self, period: Option<&str>) -> Result<Vec<UsageRecord>> {
        let cache = self.cache.lock().unwrap();
        Ok(cache
            .values()
            .filter(|r| period.map(|p| r.period.starts_with(p)).unwrap_or(true))
            .cloned()
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn outcome(success: bool, cost: f64) -> CallOutcome {
        CallOutcome {
            provider: "openai".into(),
            model: "gpt-4.1-mini".into(),
            usage: Usage {
                input_tokens: 100,
                output_tokens: 20,
                ..Default::default()
            },
            cost_usd: cost,
            latency_ms: 2000.0,
            success,
        }
    }

    #[test]
    fn accumulates_and_averages() {
        let s = MemoryUsageStore::default();
        s.record("2026-06", &outcome(true, 1.0)).unwrap();
        s.record("2026-06", &outcome(false, 0.5)).unwrap();
        let rows = s.query(Some("2026-06")).unwrap();
        assert_eq!(rows.len(), 1);
        let r = &rows[0];
        assert_eq!(r.requests, 2);
        assert_eq!(r.input_tokens, 200);
        assert_eq!(r.successful_jobs, 1);
        assert_eq!(r.failed_jobs, 1);
        assert!((r.estimated_cost_usd - 1.5).abs() < 1e-9);
        assert!((r.average_latency_ms() - 2000.0).abs() < 1e-9);
    }

    #[test]
    fn json_store_persists() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("usage.json");
        {
            let s = JsonUsageStore::new(path.clone()).unwrap();
            s.record("2026-06-26", &outcome(true, 0.25)).unwrap();
        }
        let s2 = JsonUsageStore::new(path).unwrap();
        let rows = s2.query(Some("2026-06")).unwrap(); // month prefix matches the day
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].requests, 1);
    }
}
