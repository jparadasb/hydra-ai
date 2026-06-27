//! Worker-side spend / rate guardrails. Checked BEFORE any paid external call so the worker
//! never silently overspends; on breach the lease is rejected (reported, not run).

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::config::Limits;
use crate::error::{Error, Result};

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn day_bucket(secs: u64) -> u64 {
    secs / 86_400
}

#[derive(Default)]
struct State {
    /// Unix-second timestamps of recent requests (for the rolling-hour window).
    request_times: VecDeque<u64>,
    /// (day_bucket, accumulated cost) for the current day.
    cost_day: u64,
    cost_today_usd: f64,
    /// Currently in-flight provider calls.
    inflight: u32,
}

/// Enforces [`Limits`] across concurrent dispatches. Cheap to clone (shared state).
#[derive(Clone)]
pub struct LimitGuard {
    limits: Limits,
    state: Arc<Mutex<State>>,
}

/// Held while a provider call is in flight; releases the parallel slot on drop, and lets the
/// caller commit the actual cost once the call returns.
pub struct Reservation {
    state: Arc<Mutex<State>>,
    committed: bool,
}

impl Reservation {
    /// Record the actual cost once known. Call exactly once after the provider responds.
    pub fn commit_cost(mut self, actual_usd: f64) {
        let mut s = self.state.lock().unwrap();
        let today = day_bucket(now_secs());
        if s.cost_day != today {
            s.cost_day = today;
            s.cost_today_usd = 0.0;
        }
        s.cost_today_usd += actual_usd;
        s.inflight = s.inflight.saturating_sub(1);
        self.committed = true;
    }
}

impl Drop for Reservation {
    fn drop(&mut self) {
        if !self.committed {
            let mut s = self.state.lock().unwrap();
            s.inflight = s.inflight.saturating_sub(1);
        }
    }
}

impl LimitGuard {
    pub fn new(limits: Limits) -> Self {
        Self {
            limits,
            state: Arc::new(Mutex::new(State::default())),
        }
    }

    /// Check all limits and reserve a parallel slot + a request. Returns a [`Reservation`]
    /// that must outlive the call; commit the real cost on it afterward.
    ///
    /// `estimated_cost_usd` is checked against the daily budget up front so we never *start*
    /// a call we cannot afford.
    pub fn try_reserve(&self, estimated_cost_usd: f64) -> Result<Reservation> {
        let now = now_secs();
        let mut s = self.state.lock().unwrap();

        // Rolling-hour request count.
        let cutoff = now.saturating_sub(3600);
        while s.request_times.front().is_some_and(|&t| t < cutoff) {
            s.request_times.pop_front();
        }
        if let Some(max) = self.limits.max_requests_per_hour {
            if s.request_times.len() as u32 >= max {
                return Err(Error::LimitExceeded(format!(
                    "max_requests_per_hour ({max}) reached"
                )));
            }
        }

        // Daily cost budget.
        let today = day_bucket(now);
        if s.cost_day != today {
            s.cost_day = today;
            s.cost_today_usd = 0.0;
        }
        if let Some(max) = self.limits.max_cost_per_day_usd {
            if s.cost_today_usd + estimated_cost_usd > max {
                return Err(Error::LimitExceeded(format!(
                    "max_cost_per_day_usd ({max:.2}) would be exceeded"
                )));
            }
        }

        // Parallelism.
        if let Some(max) = self.limits.max_parallel_provider_requests {
            if s.inflight >= max {
                return Err(Error::LimitExceeded(format!(
                    "max_parallel_provider_requests ({max}) reached"
                )));
            }
        }

        // Reserve.
        s.request_times.push_back(now);
        s.inflight += 1;
        Ok(Reservation {
            state: Arc::clone(&self.state),
            committed: false,
        })
    }

    /// Cost spent today (for display / reporting).
    pub fn cost_today_usd(&self) -> f64 {
        let mut s = self.state.lock().unwrap();
        if s.cost_day != day_bucket(now_secs()) {
            s.cost_today_usd = 0.0;
        }
        s.cost_today_usd
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn limits(req: Option<u32>, cost: Option<f64>, par: Option<u32>) -> Limits {
        Limits {
            max_requests_per_hour: req,
            max_cost_per_day_usd: cost,
            max_parallel_provider_requests: par,
        }
    }

    #[test]
    fn parallel_slots_release_on_drop() {
        let g = LimitGuard::new(limits(None, None, Some(2)));
        let r1 = g.try_reserve(0.0).unwrap();
        let _r2 = g.try_reserve(0.0).unwrap();
        assert!(
            g.try_reserve(0.0).is_err(),
            "third should exceed parallelism"
        );
        drop(r1);
        assert!(g.try_reserve(0.0).is_ok(), "slot freed after drop");
    }

    #[test]
    fn daily_cost_budget_enforced() {
        let g = LimitGuard::new(limits(None, Some(1.0), None));
        let r = g.try_reserve(0.6).unwrap();
        r.commit_cost(0.6);
        // 0.6 spent; a 0.5 estimate would push to 1.1 > 1.0.
        assert!(g.try_reserve(0.5).is_err());
        // but a 0.3 estimate fits.
        assert!(g.try_reserve(0.3).is_ok());
    }

    #[test]
    fn hourly_request_cap_enforced() {
        let g = LimitGuard::new(limits(Some(2), None, None));
        let _a = g.try_reserve(0.0).unwrap();
        let _b = g.try_reserve(0.0).unwrap();
        assert!(g.try_reserve(0.0).is_err());
    }
}
