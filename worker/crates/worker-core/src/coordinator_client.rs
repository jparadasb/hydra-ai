//! Phoenix Channel client: the worker's link to the coordinator.
//!
//! The [`framing`] submodule implements the Phoenix v2 wire format (a JSON array
//! `[join_ref, ref, topic, event, payload]`) and is always compiled + unit-tested. The
//! networked [`CoordinatorClient`] (feature `transport`) joins `worker:<id>`, sends the
//! registration payload, receives `"job"` leases, runs each through [`crate::gateway::Gateway`],
//! and replies with a `"result"`.
//!
//! Provider tokens are *never* sent — only the registration + results. The single optional
//! secret on this link is the **join token** (a shared fleet secret), presented as the
//! `token` query param to authenticate the connection itself. Empty/absent => no auth.

/// Phoenix v2 message framing. Pure (de)serialization; no networking.
pub mod framing {
    use serde_json::{json, Value};

    pub const HEARTBEAT_TOPIC: &str = "phoenix";

    /// A decoded Phoenix message: `[join_ref, ref, topic, event, payload]`.
    #[derive(Debug, Clone, PartialEq)]
    pub struct PhoenixMsg {
        pub join_ref: Option<String>,
        pub msg_ref: Option<String>,
        pub topic: String,
        pub event: String,
        pub payload: Value,
    }

    impl PhoenixMsg {
        pub fn new(
            join_ref: Option<String>,
            msg_ref: Option<String>,
            topic: impl Into<String>,
            event: impl Into<String>,
            payload: Value,
        ) -> Self {
            Self {
                join_ref,
                msg_ref,
                topic: topic.into(),
                event: event.into(),
                payload,
            }
        }

        /// Encode to the Phoenix v2 array wire form.
        pub fn encode(&self) -> String {
            json!([
                self.join_ref,
                self.msg_ref,
                self.topic,
                self.event,
                self.payload
            ])
            .to_string()
        }

        /// Decode from the Phoenix v2 array wire form.
        pub fn decode(s: &str) -> Option<PhoenixMsg> {
            let v: Value = serde_json::from_str(s).ok()?;
            let arr = v.as_array()?;
            if arr.len() != 5 {
                return None;
            }
            Some(PhoenixMsg {
                join_ref: arr[0].as_str().map(String::from),
                msg_ref: arr[1].as_str().map(String::from),
                topic: arr[2].as_str()?.to_string(),
                event: arr[3].as_str()?.to_string(),
                payload: arr[4].clone(),
            })
        }

        /// Did this reply report success (`{"status":"ok",...}`)?
        pub fn reply_ok(&self) -> bool {
            self.event == "phx_reply" && self.payload["status"] == "ok"
        }
    }

    /// A `phx_join` for `worker:<id>` carrying the registration payload.
    pub fn join(join_ref: &str, topic: &str, registration: Value) -> PhoenixMsg {
        PhoenixMsg::new(
            Some(join_ref.to_string()),
            Some(join_ref.to_string()),
            topic,
            "phx_join",
            registration,
        )
    }

    /// Percent-encode a value for safe use in a URL query string. Keeps the RFC 3986
    /// unreserved set (`A-Z a-z 0-9 - _ . ~`); everything else becomes `%XX`.
    pub fn percent_encode(s: &str) -> String {
        let mut out = String::with_capacity(s.len());
        for b in s.bytes() {
            match b {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                    out.push(b as char)
                }
                _ => out.push_str(&format!("%{b:02X}")),
            }
        }
        out
    }

    /// A heartbeat keepalive on the `phoenix` topic.
    pub fn heartbeat(msg_ref: &str) -> PhoenixMsg {
        PhoenixMsg::new(
            None,
            Some(msg_ref.to_string()),
            HEARTBEAT_TOPIC,
            "heartbeat",
            json!({}),
        )
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn join_round_trips() {
            let m = join("1", "worker:w1", json!({"worker_id": "w1"}));
            let encoded = m.encode();
            let decoded = PhoenixMsg::decode(&encoded).unwrap();
            assert_eq!(decoded, m);
            assert_eq!(decoded.event, "phx_join");
            assert_eq!(decoded.payload["worker_id"], "w1");
        }

        #[test]
        fn decodes_a_job_push() {
            // Server push: join_ref/ref are null, event is "job".
            let raw =
                r#"[null,null,"worker:w1","job",{"job_id":"j1","capability":"text.extract_json"}]"#;
            let m = PhoenixMsg::decode(raw).unwrap();
            assert_eq!(m.event, "job");
            assert_eq!(m.payload["job_id"], "j1");
            assert!(m.join_ref.is_none());
        }

        #[test]
        fn detects_ok_reply() {
            let raw = r#"["1","1","worker:w1","phx_reply",{"status":"ok","response":{}}]"#;
            assert!(PhoenixMsg::decode(raw).unwrap().reply_ok());
            let err = r#"["1","1","worker:w1","phx_reply",{"status":"error","response":{}}]"#;
            assert!(!PhoenixMsg::decode(err).unwrap().reply_ok());
        }

        #[test]
        fn rejects_malformed() {
            assert!(PhoenixMsg::decode("not json").is_none());
            assert!(PhoenixMsg::decode(r#"["too","short"]"#).is_none());
        }

        #[test]
        fn percent_encode_keeps_unreserved_escapes_rest() {
            assert_eq!(percent_encode("abcXYZ-0_9.~"), "abcXYZ-0_9.~");
            assert_eq!(percent_encode("a b&c=d/e"), "a%20b%26c%3Dd%2Fe");
            assert_eq!(percent_encode("tok+/="), "tok%2B%2F%3D");
        }
    }
}

#[cfg(feature = "transport")]
pub use networked::{connect_and_run, ClientConfig};

#[cfg(feature = "transport")]
mod networked {
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Arc;
    use std::time::Duration;

    use futures_util::{SinkExt, StreamExt};
    use serde_json::Value;
    use tokio::sync::{mpsc, Semaphore};
    use tokio_tungstenite::tungstenite::Message;

    use super::framing::{self, PhoenixMsg};
    use crate::error::{Error, Result};
    use crate::gateway::Gateway;
    use crate::types::Job;

    pub struct ClientConfig {
        /// Base ws/wss URL, e.g. `ws://127.0.0.1:4000`.
        pub base_url: String,
        pub worker_id: String,
        /// Non-secret registration payload (see [`crate::registration::WorkerRegistration`]).
        pub registration: Value,
        pub heartbeat: Duration,
        /// Optional shared join token. Presented as the `token` query param to authenticate
        /// the connection. `None`/empty => connect without auth (open coordinator).
        pub join_token: Option<String>,
        /// Optional signed device-key challenge (Ed25519 TOFU). When set, the coordinator
        /// verifies the signature and pins the public key to this `worker_id` on first sight.
        pub auth: Option<crate::identity::AuthParams>,
        /// Max jobs executed in parallel. Leased jobs run in spawned tasks bounded by this; the
        /// reader stays responsive (so disconnects are detected promptly) while at most this many
        /// `gateway.execute` calls run at once. Must be >= 1.
        pub max_parallel_jobs: usize,
    }

    /// Connect, join `worker:<id>`, then process leased jobs until the socket closes. Updates
    /// `status` (connected flag + jobs-processed counter) for the UI to poll.
    pub async fn connect_and_run(
        config: ClientConfig,
        gateway: Arc<Gateway>,
        status: Arc<crate::worker_run::RunStatus>,
    ) -> Result<()> {
        let topic = format!("worker:{}", config.worker_id);
        let mut url = format!(
            "{}/worker/websocket?vsn=2.0.0",
            config.base_url.trim_end_matches('/')
        );
        if let Some(tok) = config.join_token.as_deref().filter(|t| !t.is_empty()) {
            url.push_str("&token=");
            url.push_str(&framing::percent_encode(tok));
        }
        if let Some(a) = &config.auth {
            url.push_str("&worker_id=");
            url.push_str(&framing::percent_encode(&a.worker_id));
            url.push_str("&pubkey=");
            url.push_str(&framing::percent_encode(&a.pubkey));
            url.push_str("&ts=");
            url.push_str(&a.ts.to_string());
            url.push_str("&nonce=");
            url.push_str(&framing::percent_encode(&a.nonce));
            url.push_str("&sig=");
            url.push_str(&framing::percent_encode(&a.sig));
        }

        let (ws, _resp) = tokio_tungstenite::connect_async(&url)
            .await
            .map_err(|e| Error::Other(format!("ws connect: {e}")))?;
        status.mark_connected(true);
        let (mut sink, mut stream) = ws.split();

        // Outbound channel: heartbeat + results funnel through one writer.
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let refs = Arc::new(AtomicU64::new(1));
        let next_ref = {
            let refs = Arc::clone(&refs);
            move || refs.fetch_add(1, Ordering::Relaxed).to_string()
        };

        // Join.
        let join = framing::join("1", &topic, config.registration.clone());
        tx.send(join.encode()).ok();

        // Writer task.
        let writer = tokio::spawn(async move {
            while let Some(text) = rx.recv().await {
                if sink.send(Message::Text(text)).await.is_err() {
                    break;
                }
            }
        });

        // Heartbeat task.
        let hb_tx = tx.clone();
        let hb_interval = config.heartbeat;
        let hb_ref = next_ref.clone();
        let heartbeat = tokio::spawn(async move {
            let mut tick = tokio::time::interval(hb_interval);
            loop {
                tick.tick().await;
                if hb_tx.send(framing::heartbeat(&hb_ref()).encode()).is_err() {
                    break;
                }
            }
        });

        // Bounds how many jobs execute concurrently. The reader never blocks on it: each job is
        // spawned and acquires a permit inside its task, so the loop keeps reading the socket
        // (heartbeat replies, Close frames) while at most `max_parallel_jobs` run at once.
        let sem = Arc::new(Semaphore::new(config.max_parallel_jobs.max(1)));

        // Reader loop: dispatch leased jobs to bounded background tasks; each replies with its
        // own result. Running jobs in tasks (not inline) lets a worker process many leases in
        // parallel instead of head-of-line blocking on one slow inference.
        while let Some(msg) = stream.next().await {
            let text = match msg {
                Ok(Message::Text(t)) => t,
                Ok(Message::Close(_)) | Err(_) => break,
                Ok(_) => continue,
            };
            let Some(pm) = PhoenixMsg::decode(&text) else {
                continue;
            };
            if pm.event == "job" && pm.topic == topic {
                if let Ok(job) = serde_json::from_value::<Job>(pm.payload.clone()) {
                    let gateway = Arc::clone(&gateway);
                    let status = Arc::clone(&status);
                    let sem = Arc::clone(&sem);
                    let tx = tx.clone();
                    let topic = topic.clone();
                    let next_ref = next_ref.clone();
                    tokio::spawn(async move {
                        // Wait for a free slot; if the semaphore is gone we're shutting down.
                        let Ok(_permit) = sem.acquire_owned().await else {
                            return;
                        };
                        // Forward each streamed content fragment as a "result_chunk" so the
                        // coordinator can relay tokens live. Best-effort (send may fail on a
                        // closing socket); the final "result" below stays authoritative.
                        let seq = AtomicU64::new(0);
                        let on_delta: crate::adapter::DeltaSink = {
                            let tx = tx.clone();
                            let topic = topic.clone();
                            let next_ref = next_ref.clone();
                            let job_id = job.job_id.clone();
                            Arc::new(move |delta: &str, is_reasoning: bool| {
                                let chunk = crate::types::JobResultChunk {
                                    job_id: job_id.clone(),
                                    seq: seq.fetch_add(1, Ordering::Relaxed),
                                    delta: delta.to_string(),
                                    reasoning: is_reasoning,
                                };
                                let payload =
                                    serde_json::to_value(&chunk).unwrap_or(Value::Null);
                                let out = PhoenixMsg::new(
                                    Some("1".into()),
                                    Some(next_ref()),
                                    &topic,
                                    "result_chunk",
                                    payload,
                                );
                                tx.send(out.encode()).ok();
                            })
                        };
                        let result = gateway.execute_streaming(&job, on_delta).await;
                        // Surface a failed job (rejected/errored — e.g. a provider rate limit)
                        // to the UI status; the coordinator still gets the full result below.
                        if !matches!(result.status, crate::types::JobStatus::Ok) {
                            let reason = result.reason.clone().unwrap_or_default();
                            // Log for headless workers (no UI); redact any token-shaped text.
                            tracing::warn!(
                                job = %result.job_id,
                                "job failed: {}",
                                crate::vault::redact(&reason)
                            );
                            status.note_job_error(format!("job {}: {}", result.job_id, reason));
                        }
                        let payload = serde_json::to_value(&result).unwrap_or(Value::Null);
                        let out = PhoenixMsg::new(
                            Some("1".into()),
                            Some(next_ref()),
                            &topic,
                            "result",
                            payload,
                        );
                        // Send fails silently if the socket already closed; the coordinator
                        // re-leases the job on lease timeout.
                        tx.send(out.encode()).ok();
                        status.incr_jobs();
                    });
                }
            }
        }

        status.mark_connected(false);
        heartbeat.abort();
        writer.abort();
        Ok(())
    }
}
