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

/// When a running job is worth telling the coordinator about. Pure; no networking, so the
/// policy is unit-testable on its own.
pub mod progress {
    /// Emit after this many new tokens, however fast they arrive. Chosen so a fast local model
    /// producing 60 tok/s reports a few times a second at most, rather than per token.
    pub const TOKEN_INTERVAL: u64 = 64;

    /// …or after this long, however few. A slow model on cold hardware can take minutes per
    /// token batch, and a caller polling a job needs to see it is alive well before then.
    pub const TIME_INTERVAL_MS: u64 = 2_000;

    /// Whether a job that has produced `tokens` at `now_ms` should report, given what was last
    /// reported. Either bound is enough: tokens keep a fast job's counts fresh, time keeps a
    /// slow one from looking stalled.
    pub fn should_emit(tokens: u64, last_tokens: u64, now_ms: u64, last_ms: u64) -> bool {
        tokens.saturating_sub(last_tokens) >= TOKEN_INTERVAL
            || now_ms.saturating_sub(last_ms) >= TIME_INTERVAL_MS
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn emits_on_token_count_alone() {
            assert!(should_emit(TOKEN_INTERVAL, 0, 0, 0));
            assert!(!should_emit(TOKEN_INTERVAL - 1, 0, 0, 0));
        }

        #[test]
        fn emits_on_elapsed_time_alone() {
            // A job generating almost nothing still has to look alive.
            assert!(should_emit(1, 0, TIME_INTERVAL_MS, 0));
            assert!(!should_emit(1, 0, TIME_INTERVAL_MS - 1, 0));
        }

        #[test]
        fn counters_that_went_backwards_do_not_emit_or_panic() {
            // Both counters are monotonic in practice; saturating arithmetic means a reordered
            // read cannot underflow into an emit-every-delta storm.
            assert!(!should_emit(0, 500, 0, 500));
        }
    }
}

/// Recognizing a job that is asking a question rather than answering one. Pure; no networking.
pub mod context_request {
    use crate::types::{JobInputRequest, JobResult, CONTEXT_REQUEST_TOOL};
    use serde_json::Value;

    /// Turn a result whose model called the reserved tool into the request to send instead.
    ///
    /// `None` for every ordinary result, which is almost all of them. The reserved name is the
    /// whole signal: it can only appear in a model's tool calls because the coordinator injected
    /// the tool, so there is nothing else to check.
    ///
    /// Only the reserved call is forwarded. A model may emit it alongside real tool calls, and
    /// those belong to the caller's own tools, not to this mechanism.
    pub fn from_result(result: &JobResult, request_id: &str) -> Option<JobInputRequest> {
        if result.status != crate::types::JobStatus::Ok {
            return None;
        }

        let lease_id = result.lease_id.clone()?;
        let calls = result.output.as_ref()?.get("tool_calls")?.as_array()?;

        let requests: Vec<Value> = calls
            .iter()
            .filter(|call| tool_name(call) == Some(CONTEXT_REQUEST_TOOL))
            .filter_map(arguments)
            .collect();

        if requests.is_empty() {
            return None;
        }

        Some(JobInputRequest {
            job_id: result.job_id.clone(),
            lease_id,
            request_id: request_id.to_string(),
            requests,
            // The turn that asked, so the coordinator can rebuild the conversation. The model
            // reads its own question back when the job resumes.
            assistant_message: Some(serde_json::json!({
                "role": "assistant",
                "content": result.output.as_ref().and_then(|o| o.get("content")).cloned(),
                "tool_calls": calls,
            })),
            usage: result.usage.clone(),
        })
    }

    fn tool_name(call: &Value) -> Option<&str> {
        call.get("function")
            .and_then(|f| f.get("name"))
            .or_else(|| call.get("name"))
            .and_then(Value::as_str)
    }

    // Arguments arrive as a JSON string from every OpenAI-compatible backend, and occasionally
    // as an object. Carry whichever came, and say which call it belongs to.
    fn arguments(call: &Value) -> Option<Value> {
        let raw = call
            .get("function")
            .and_then(|f| f.get("arguments"))
            .or_else(|| call.get("arguments"))?;

        let parsed = match raw {
            Value::String(text) => serde_json::from_str::<Value>(text).unwrap_or(Value::Null),
            other => other.clone(),
        };

        let mut request = serde_json::Map::new();
        if let Some(id) = call.get("id").and_then(Value::as_str) {
            request.insert("tool_call_id".into(), Value::String(id.into()));
        }
        request.insert("arguments".into(), parsed);
        Some(Value::Object(request))
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use crate::types::{JobResult, JobStatus};

        fn result_with(tool_calls: Value) -> JobResult {
            JobResult {
                job_id: "job-1".into(),
                lease_id: Some("lease-1".into()),
                status: JobStatus::Ok,
                reason: None,
                output: Some(serde_json::json!({"content": "", "tool_calls": tool_calls})),
                usage: None,
            }
        }

        #[test]
        fn recognizes_the_reserved_call_and_carries_its_arguments() {
            let result = result_with(serde_json::json!([{
                "id": "call_1",
                "function": {
                    "name": CONTEXT_REQUEST_TOOL,
                    "arguments": "{\"path\":\"src/foo.ex\"}"
                }
            }]));

            let request = from_result(&result, "ir-1").expect("should pause");
            assert_eq!(request.request_id, "ir-1");
            assert_eq!(request.requests.len(), 1);
            assert_eq!(request.requests[0]["arguments"]["path"], "src/foo.ex");
            assert_eq!(request.requests[0]["tool_call_id"], "call_1");
            assert!(request.assistant_message.is_some());
        }

        #[test]
        fn leaves_the_callers_own_tool_calls_alone() {
            // A model may call both. Only the reserved one is this mechanism's business; the
            // rest belong to whoever defined them.
            let result = result_with(serde_json::json!([
                {"id": "a", "function": {"name": "get_weather", "arguments": "{}"}},
                {"id": "b", "function": {"name": CONTEXT_REQUEST_TOOL, "arguments": "{}"}}
            ]));

            let request = from_result(&result, "ir-1").expect("should pause");
            assert_eq!(request.requests.len(), 1);
            assert_eq!(request.requests[0]["tool_call_id"], "b");
        }

        #[test]
        fn an_ordinary_result_does_not_pause() {
            let result = result_with(serde_json::json!([
                {"id": "a", "function": {"name": "get_weather", "arguments": "{}"}}
            ]));
            assert!(from_result(&result, "ir-1").is_none());

            let mut plain = result_with(serde_json::json!([]));
            plain.output = Some(serde_json::json!({"content": "just an answer"}));
            assert!(from_result(&plain, "ir-1").is_none());
        }

        #[test]
        fn a_failed_job_is_not_a_question() {
            let mut result = result_with(serde_json::json!([
                {"id": "a", "function": {"name": CONTEXT_REQUEST_TOOL, "arguments": "{}"}}
            ]));
            result.status = JobStatus::Error;
            assert!(from_result(&result, "ir-1").is_none());
        }

        #[test]
        fn a_job_leased_without_a_generation_cannot_park() {
            // Parking is guarded on the lease generation coordinator-side; without one there is
            // nothing to guard with, so it finishes normally instead.
            let mut result = result_with(serde_json::json!([
                {"id": "a", "function": {"name": CONTEXT_REQUEST_TOOL, "arguments": "{}"}}
            ]));
            result.lease_id = None;
            assert!(from_result(&result, "ir-1").is_none());
        }
    }
}

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
    use std::collections::HashMap;
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

    struct RunningJob {
        handle: tokio::task::JoinHandle<()>,
        heartbeat: tokio::task::JoinHandle<()>,
    }

    /// `(job_id, lease_id)`: one entry per lease generation, mirroring the coordinator's
    /// `active_leases`. Keying by `job_id` alone would make a re-lease silently abort the
    /// live generation without ever acking it as cancelled.
    type JobKey = (String, Option<String>);

    /// Track a newly dispatched lease. Only an identical generation replaces (and aborts) an
    /// existing entry; a different generation of the same job runs alongside it.
    /// Reports how far a job has got, at most as often as [`super::progress::should_emit`]
    /// allows.
    ///
    /// Shared with the delta sink, which is a synchronous `Fn` and cannot await — so this sends
    /// through the same bounded `try_send` path the streamed chunks use, and drops under
    /// backpressure for the same reason: a progress frame is visibility, and blocking the
    /// generation loop to deliver one would trade the job for the telemetry about it.
    struct ProgressMeter {
        job_id: String,
        lease_id: String,
        topic: String,
        tx: mpsc::Sender<String>,
        next_ref: Arc<dyn Fn() -> String + Send + Sync>,
        started: std::time::Instant,
        seq: AtomicU64,
        tokens: AtomicU64,
        last_emit_tokens: AtomicU64,
        last_emit_ms: AtomicU64,
    }

    impl ProgressMeter {
        fn elapsed_ms(&self) -> u64 {
            self.started.elapsed().as_millis() as u64
        }

        /// Count one streamed fragment, and report if it is time to.
        ///
        /// One fragment is treated as one token. Every streaming adapter here emits per-token
        /// deltas, and the authoritative counts arrive with the final result anyway — so this is
        /// a live approximation that `Coordinator.Usage` overwrites at completion.
        fn note_delta(&self) {
            let tokens = self.tokens.fetch_add(1, Ordering::Relaxed) + 1;
            let now_ms = self.elapsed_ms();
            let last_tokens = self.last_emit_tokens.load(Ordering::Relaxed);
            let last_ms = self.last_emit_ms.load(Ordering::Relaxed);

            if !super::progress::should_emit(tokens, last_tokens, now_ms, last_ms) {
                return;
            }

            // Claim this emission. Two deltas can pass the check at once; only the one that
            // wins the swap sends, so a burst produces one frame rather than a duplicate pair.
            if self
                .last_emit_ms
                .compare_exchange(last_ms, now_ms, Ordering::Relaxed, Ordering::Relaxed)
                .is_err()
            {
                return;
            }

            self.last_emit_tokens.store(tokens, Ordering::Relaxed);
            self.send(crate::types::JobPhase::Generating, Some(tokens));
        }

        fn send(&self, phase: crate::types::JobPhase, output_tokens: Option<u64>) {
            let frame = crate::types::JobProgress {
                job_id: self.job_id.clone(),
                lease_id: self.lease_id.clone(),
                seq: self.seq.fetch_add(1, Ordering::Relaxed),
                phase: Some(phase),
                input_tokens: None,
                output_tokens,
                model: None,
                provider: None,
            };

            let payload = serde_json::to_value(&frame).unwrap_or(Value::Null);
            let msg = PhoenixMsg::new(
                Some("1".into()),
                Some((self.next_ref)()),
                &self.topic,
                "job_progress",
                payload,
            );

            // Best-effort, like a streamed chunk: the final result carries the real counts.
            let _ = self.tx.try_send(msg.encode());
        }
    }

    fn track_job(
        jobs: &mut HashMap<JobKey, RunningJob>,
        job_id: String,
        lease_id: Option<String>,
        handle: tokio::task::JoinHandle<()>,
        heartbeat: tokio::task::JoinHandle<()>,
    ) {
        if let Some(old) = jobs.insert((job_id, lease_id), RunningJob { handle, heartbeat }) {
            old.heartbeat.abort();
            old.handle.abort();
        }
    }

    /// Abort the named generation, or every generation of `job_id` when the coordinator sends
    /// no `lease_id` (pre-generation coordinators).
    fn cancel_job(
        jobs: &mut HashMap<JobKey, RunningJob>,
        job_id: &str,
        lease_id: Option<&str>,
    ) -> bool {
        let targets: Vec<JobKey> = jobs
            .keys()
            .filter(|(id, lease)| {
                id == job_id && (lease_id.is_none() || lease.as_deref() == lease_id)
            })
            .cloned()
            .collect();

        for key in &targets {
            let running = jobs.remove(key).expect("running job disappeared");
            running.heartbeat.abort();
            running.handle.abort();
        }

        !targets.is_empty()
    }

    /// Outbound queue depth. Deep enough that a brief write stall does not stutter streaming,
    /// shallow enough that a coordinator which stops reading is bounded rather than fatal.
    const OUTBOUND_CAPACITY: usize = 1024;

    /// Largest WebSocket message accepted from the coordinator. A leased job is text, not
    /// media; tungstenite's 64 MiB default let the other end decide this process's memory use.
    const MAX_WS_MESSAGE_BYTES: usize = 8 * 1024 * 1024;

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

        // Without an explicit config, tungstenite allows a 64 MiB message. A leased job is
        // messages, not media; cap what the coordinator can make this process buffer.
        // `WebSocketConfig` is `#[non_exhaustive]`, so it is built through its setters rather
        // than a struct literal.
        let ws_config = tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default()
            .max_message_size(Some(MAX_WS_MESSAGE_BYTES))
            .max_frame_size(Some(MAX_WS_MESSAGE_BYTES));

        let (ws, _resp) = tokio::time::timeout(
            crate::http::CONNECT_TIMEOUT,
            tokio_tungstenite::connect_async_with_config(&url, Some(ws_config), false),
        )
        .await
        .map_err(|_| Error::Other("ws connect timed out".into()))?
        .map_err(|e| Error::Other(format!("ws connect: {e}")))?;
        status.mark_connected(true);
        let (mut sink, mut stream) = ws.split();

        // Outbound channel: heartbeat + results funnel through one writer.
        //
        // Bounded. Unbounded meant a coordinator that stopped reading let streamed
        // `result_chunk` messages queue until the process ran out of memory — the failure was
        // in the worker, for a fault on the other end. Senders that can wait do
        // (`send().await`, real backpressure); the streamed-chunk sink cannot, so it drops.
        let (tx, mut rx) = mpsc::channel::<String>(OUTBOUND_CAPACITY);
        let refs = Arc::new(AtomicU64::new(1));
        let next_ref = {
            let refs = Arc::clone(&refs);
            move || refs.fetch_add(1, Ordering::Relaxed).to_string()
        };

        // Join.
        let join = framing::join("1", &topic, config.registration.clone());
        tx.send(join.encode()).await.ok();

        // Writer task.
        let writer = tokio::spawn(async move {
            while let Some(text) = rx.recv().await {
                // `Message::Text` carries `Utf8Bytes` now; converting from `String` reuses
                // the allocation rather than copying.
                if sink.send(Message::Text(text.into())).await.is_err() {
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
                if hb_tx
                    .send(framing::heartbeat(&hb_ref()).encode())
                    .await
                    .is_err()
                {
                    break;
                }
            }
        });

        // Backends can become ready after this daemon starts. Re-probe and update the live
        // registration so the coordinator's model catalog heals without restarting us.
        let catalog_tx = tx.clone();
        let catalog_topic = topic.clone();
        let catalog_ref = next_ref.clone();
        let catalog_gateway = Arc::clone(&gateway);
        let registration_template = config.registration.clone();
        let catalog_refresh = tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(30));
            // A refresh slower than the interval must not queue missed ticks: bursting would
            // re-probe and re-send `registration` back to back with no gap.
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            tick.tick().await;
            loop {
                tick.tick().await;
                catalog_gateway.refresh_catalog().await;
                let mut registration = registration_template.clone();
                registration["models"] = serde_json::to_value(catalog_gateway.model_catalog())
                    .unwrap_or_else(|_| Value::Array(Vec::new()));
                let msg = PhoenixMsg::new(
                    Some("1".into()),
                    Some(catalog_ref()),
                    &catalog_topic,
                    "registration",
                    registration,
                );
                if catalog_tx.send(msg.encode()).await.is_err() {
                    break;
                }
            }
        });

        // Bounds how many jobs execute concurrently. The reader never blocks on it: each job is
        // spawned and acquires a permit inside its task, so the loop keeps reading the socket
        // (heartbeat replies, Close frames) while at most `max_parallel_jobs` run at once.
        let sem = Arc::new(Semaphore::new(config.max_parallel_jobs.max(1)));
        // Shared across jobs so the log reflects the connection, not one job.
        let dropped_chunks_counter = Arc::new(AtomicU64::new(0));
        let mut undecodable_frames: u64 = 0;
        let mut jobs = HashMap::<JobKey, RunningJob>::new();

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
                // Silently dropping these hid a protocol mismatch: the worker looked idle
                // while the coordinator believed it was talking to it. Logged on a doubling
                // scale so a persistent mismatch is loud without a flood.
                undecodable_frames += 1;
                if undecodable_frames.is_power_of_two() {
                    tracing::warn!(
                        frames = undecodable_frames,
                        last_frame_bytes = text.len(),
                        "coordinator sent undecodable frame(s)"
                    );
                }
                continue;
            };
            // Reap completed handles while traffic is flowing. Retaining the handles lets a
            // cancellation abort both jobs waiting for a semaphore permit and active adapters.
            jobs.retain(|_, running| {
                if running.handle.is_finished() {
                    running.heartbeat.abort();
                    false
                } else {
                    true
                }
            });
            if pm.event == "phx_reply" && pm.topic == topic {
                match pm.payload.get("status").and_then(Value::as_str) {
                    Some("ok") => tracing::debug!("coordinator acknowledged worker message"),
                    Some(status) => tracing::warn!(
                        status = %status,
                        payload = %crate::vault::redact(&pm.payload.to_string()),
                        "coordinator rejected worker message"
                    ),
                    None => {}
                }
            }
            if pm.event == "job" && pm.topic == topic {
                if let Ok(job) = serde_json::from_value::<Job>(pm.payload.clone()) {
                    let job_id = job.job_id.clone();
                    let gateway = Arc::clone(&gateway);
                    let status = Arc::clone(&status);
                    let sem = Arc::clone(&sem);
                    let tx = tx.clone();
                    let topic = topic.clone();
                    let next_ref = next_ref.clone();
                    let lease_id = job.lease_id.clone();
                    let heartbeat = {
                        let tx = tx.clone();
                        let topic = topic.clone();
                        let next_ref = next_ref.clone();
                        let job_id = job_id.clone();
                        let lease_id = lease_id.clone();

                        tokio::spawn(async move {
                            let Some(lease_id) = lease_id else { return };
                            let mut tick = tokio::time::interval(Duration::from_secs(20));

                            loop {
                                tick.tick().await;
                                let heartbeat = PhoenixMsg::new(
                                    Some("1".into()),
                                    Some(next_ref()),
                                    &topic,
                                    "lease_heartbeat",
                                    serde_json::json!({
                                        "job_id": job_id,
                                        "lease_id": lease_id,
                                    }),
                                );

                                if tx.send(heartbeat.encode()).await.is_err() {
                                    break;
                                }
                            }
                        })
                    };
                    let heartbeat_abort = heartbeat.abort_handle();
                    let dropped_chunks = Arc::clone(&dropped_chunks_counter);
                    let progress_lease = lease_id.clone();
                    let progress_topic = topic.clone();
                    let progress_tx = tx.clone();
                    let progress_next_ref = next_ref.clone();
                    let progress_job_id = job_id.clone();
                    let handle = tokio::spawn(async move {
                        // Wait for a free slot; if the semaphore is gone we're shutting down.
                        let Ok(_permit) = sem.acquire_owned().await else {
                            return;
                        };

                        // Progress needs a lease generation to be attributable, so a job leased
                        // without one (a coordinator predating generations) simply reports none.
                        let meter = progress_lease.map(|lease_id| {
                            Arc::new(ProgressMeter {
                                job_id: progress_job_id,
                                lease_id,
                                topic: progress_topic,
                                tx: progress_tx,
                                next_ref: Arc::new(progress_next_ref),
                                started: std::time::Instant::now(),
                                seq: AtomicU64::new(0),
                                tokens: AtomicU64::new(0),
                                last_emit_tokens: AtomicU64::new(0),
                                last_emit_ms: AtomicU64::new(0),
                            })
                        });

                        // A backend that does not stream produces no deltas, so the sink below
                        // never fires and the job would look silent for its whole run. These two
                        // frames are emitted outside the delta path, so such a job still reads
                        // loading_model -> finalizing -> completed rather than nothing at all.
                        if let Some(meter) = meter.as_ref() {
                            meter.send(crate::types::JobPhase::LoadingModel, None);
                        }
                        // Forward each streamed content fragment as a "result_chunk" so the
                        // coordinator can relay tokens live. Best-effort (send may fail on a
                        // closing socket); the final "result" below stays authoritative.
                        let seq = AtomicU64::new(0);
                        let on_delta: crate::adapter::DeltaSink = {
                            let tx = tx.clone();
                            let topic = topic.clone();
                            let dropped_chunks = Arc::clone(&dropped_chunks);
                            let next_ref = next_ref.clone();
                            let job_id = job.job_id.clone();
                            let meter = meter.clone();
                            Arc::new(move |delta: &str, is_reasoning: bool| {
                                if let Some(meter) = meter.as_ref() {
                                    meter.note_delta();
                                }

                                let chunk = crate::types::JobResultChunk {
                                    job_id: job_id.clone(),
                                    seq: seq.fetch_add(1, Ordering::Relaxed),
                                    delta: delta.to_string(),
                                    reasoning: is_reasoning,
                                };
                                let payload = serde_json::to_value(&chunk).unwrap_or(Value::Null);
                                let out = PhoenixMsg::new(
                                    Some("1".into()),
                                    Some(next_ref()),
                                    &topic,
                                    "result_chunk",
                                    payload,
                                );
                                // A sync closure cannot wait, and a chunk is best-effort UX —
                                // the final "result" is authoritative. Drop it rather than
                                // queue without limit, and count the drop so a coordinator
                                // that has stopped reading is visible.
                                if tx.try_send(out.encode()).is_err() {
                                    let dropped =
                                        dropped_chunks.fetch_add(1, Ordering::Relaxed) + 1;
                                    if dropped.is_power_of_two() {
                                        tracing::warn!(
                                            dropped,
                                            "coordinator not keeping up; dropping streamed chunks"
                                        );
                                    }
                                }
                            })
                        };
                        let result = gateway.execute_streaming(&job, on_delta).await;

                        // Generation is done; what remains is assembling and sending the result.
                        // On a job that buffered (tools or a strict schema suppress streaming)
                        // this is the first frame carrying a token count.
                        if let Some(meter) = meter.as_ref() {
                            let generated = meter.tokens.load(Ordering::Relaxed);
                            let tokens = result
                                .usage
                                .as_ref()
                                .and_then(|u| u.output_tokens)
                                .or(if generated > 0 { Some(generated) } else { None });

                            meter.send(crate::types::JobPhase::Finalizing, tokens);
                        }
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
                        // The model may have asked for context instead of answering. That is
                        // not a result: the job is paused, and the coordinator re-leases it once
                        // the caller replies. Nothing about the pause lives on this worker, so a
                        // worker that dies while a job is parked costs the job nothing.
                        let (event, payload) = match super::context_request::from_result(
                            &result,
                            &format!("ir-{}", result.job_id),
                        ) {
                            Some(request) => {
                                tracing::info!(
                                    job = %request.job_id,
                                    requests = request.requests.len(),
                                    "job paused: the model asked for more context"
                                );
                                ("input_request", serde_json::to_value(&request))
                            }
                            None => ("result", serde_json::to_value(&result)),
                        };

                        let payload = payload.unwrap_or(Value::Null);
                        let out = PhoenixMsg::new(
                            Some("1".into()),
                            Some(next_ref()),
                            &topic,
                            event,
                            payload,
                        );
                        // Send fails silently if the socket already closed; the coordinator
                        // re-leases the job on lease timeout.
                        tx.send(out.encode()).await.ok();
                        status.incr_jobs();
                        heartbeat_abort.abort();
                    });
                    track_job(&mut jobs, job_id, lease_id, handle, heartbeat);
                }
            }
            if pm.event == "cancel" && pm.topic == topic {
                if let Some(job_id) = pm.payload.get("job_id").and_then(Value::as_str) {
                    let lease_id = pm.payload.get("lease_id").and_then(Value::as_str);

                    cancel_job(&mut jobs, job_id, lease_id);

                    if let Some(lease_id) = lease_id {
                        let cancelled = PhoenixMsg::new(
                            Some("1".into()),
                            Some(next_ref()),
                            &topic,
                            "cancelled",
                            serde_json::json!({"job_id": job_id, "lease_id": lease_id}),
                        );
                        tx.send(cancelled.encode()).await.ok();
                    }
                }
            }
        }

        status.mark_connected(false);
        for (_, running) in jobs {
            running.heartbeat.abort();
            running.handle.abort();
        }
        heartbeat.abort();
        catalog_refresh.abort();
        writer.abort();
        Ok(())
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[tokio::test]
        async fn cancel_aborts_and_removes_running_job() {
            let mut jobs = HashMap::new();
            track_job(
                &mut jobs,
                "job-1".to_string(),
                Some("lease-1".to_string()),
                tokio::spawn(std::future::pending::<()>()),
                tokio::spawn(std::future::pending::<()>()),
            );

            assert!(!cancel_job(&mut jobs, "job-1", Some("stale-lease")));
            assert!(cancel_job(&mut jobs, "job-1", Some("lease-1")));
            assert!(jobs.is_empty());
            assert!(!cancel_job(&mut jobs, "job-1", Some("lease-1")));
        }

        #[tokio::test]
        async fn a_new_lease_generation_leaves_the_previous_one_running() {
            let mut jobs = HashMap::new();
            track_job(
                &mut jobs,
                "job-1".to_string(),
                Some("lease-1".to_string()),
                tokio::spawn(std::future::pending::<()>()),
                tokio::spawn(std::future::pending::<()>()),
            );
            track_job(
                &mut jobs,
                "job-1".to_string(),
                Some("lease-2".to_string()),
                tokio::spawn(std::future::pending::<()>()),
                tokio::spawn(std::future::pending::<()>()),
            );

            // Both generations run: the coordinator tracks each lease separately, so the
            // first must keep running until it is cancelled or finishes on its own.
            assert_eq!(jobs.len(), 2);

            assert!(cancel_job(&mut jobs, "job-1", Some("lease-1")));
            assert_eq!(jobs.len(), 1);
            assert!(jobs.contains_key(&("job-1".to_string(), Some("lease-2".to_string()))));
        }

        #[tokio::test]
        async fn cancel_without_a_lease_id_stops_every_generation() {
            let mut jobs = HashMap::new();
            for lease in ["lease-1", "lease-2"] {
                track_job(
                    &mut jobs,
                    "job-1".to_string(),
                    Some(lease.to_string()),
                    tokio::spawn(std::future::pending::<()>()),
                    tokio::spawn(std::future::pending::<()>()),
                );
            }

            assert!(cancel_job(&mut jobs, "job-1", None));
            assert!(jobs.is_empty());
        }
    }
}
