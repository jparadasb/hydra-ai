//! Worker-side request guardrails. Checked before every backend call.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::config::Limits;
use crate::error::{Error, Result};
use crate::sync::MutexExt;

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[derive(Default)]
struct State {
    /// Unix-second timestamps of recent requests (for the rolling-hour window).
    request_times: VecDeque<u64>,
    /// Currently in-flight provider calls.
    inflight: u32,
}

/// Enforces [`Limits`] across concurrent dispatches. Cheap to clone (shared state).
#[derive(Clone)]
pub struct LimitGuard {
    limits: Limits,
    state: Arc<Mutex<State>>,
}

/// Held while a call is in flight; releases a provider parallel slot on drop when applicable.
pub struct Reservation {
    state: Arc<Mutex<State>>,
    provider_slot: bool,
}

impl Drop for Reservation {
    fn drop(&mut self) {
        if self.provider_slot {
            let mut s = self.state.lock_recover();
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

    /// Count every request, and reserve a parallel slot for external-provider calls.
    pub fn try_reserve(&self, uses_external_provider: bool) -> Result<Reservation> {
        let now = now_secs();
        let mut s = self.state.lock_recover();

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

        // Parallelism.
        if uses_external_provider {
            if let Some(max) = self.limits.max_parallel_provider_requests {
                if s.inflight >= max {
                    return Err(Error::LimitExceeded(format!(
                        "max_parallel_provider_requests ({max}) reached"
                    )));
                }
            }
        }

        // Reserve.
        s.request_times.push_back(now);
        if uses_external_provider {
            s.inflight += 1;
        }
        Ok(Reservation {
            state: Arc::clone(&self.state),
            provider_slot: uses_external_provider,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn limits(req: Option<u32>, par: Option<u32>) -> Limits {
        Limits {
            max_requests_per_hour: req,
            max_parallel_provider_requests: par,
        }
    }

    #[test]
    fn parallel_slots_release_on_drop() {
        let g = LimitGuard::new(limits(None, Some(2)));
        let r1 = g.try_reserve(true).unwrap();
        let _r2 = g.try_reserve(true).unwrap();
        assert!(
            g.try_reserve(true).is_err(),
            "third should exceed parallelism"
        );
        drop(r1);
        assert!(g.try_reserve(true).is_ok(), "slot freed after drop");
    }

    #[test]
    fn local_requests_do_not_consume_provider_slots() {
        let g = LimitGuard::new(limits(None, Some(1)));
        let _local = g.try_reserve(false).unwrap();
        assert!(g.try_reserve(true).is_ok());
    }

    #[test]
    fn hourly_request_cap_enforced() {
        let g = LimitGuard::new(limits(Some(2), None));
        let _a = g.try_reserve(false).unwrap();
        let _b = g.try_reserve(true).unwrap();
        assert!(g.try_reserve(false).is_err());
    }
}
