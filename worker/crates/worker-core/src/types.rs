//! Wire and domain types. These mirror the schemas in `/proto`.
//!
//! INVARIANT: none of the *registration* / *usage* / *result* types carry a token,
//! api key, or authorization header. Secrets live only in [`crate::vault`].

use serde::{Deserialize, Serialize};

/// How a worker processes AI jobs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExecutionMode {
    LocalModel,
    ExternalProvider,
    Both,
}

/// Privacy class of a job; governs which workers may run it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PrivacyLevel {
    Public,
    Private,
    Sensitive,
    LocalOnly,
}

/// Capabilities of one model exposed by an adapter.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelInfo {
    pub name: String,
    pub capabilities: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_length: Option<u32>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub modalities: Vec<String>,
    pub uses_external_provider: bool,
}

/// A chat-completion request normalized across providers.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatRequest {
    pub model: String,
    pub messages: Vec<ChatMessage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temperature: Option<f32>,
    /// OpenAI-shaped tool definitions (`[{"type":"function","function":{...}}]`), kept as raw
    /// JSON: OpenAI-style backends take them verbatim, other adapters translate.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tools: Option<serde_json::Value>,
    /// OpenAI-shaped tool choice: `"auto"`, `"none"`, `"required"`, or
    /// `{"type":"function","function":{"name":...}}`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_choice: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ChatMessage {
    pub role: String,
    /// Message text. OpenAI clients send `null` on assistant tool-call turns and sometimes an
    /// array of content parts; both normalize to a plain string here.
    #[serde(default, deserialize_with = "content_as_string")]
    pub content: String,
    /// Tool calls made on an assistant turn (OpenAI wire shape).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<Vec<ToolCall>>,
    /// For `role: "tool"` messages: which call this result answers.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
}

/// One tool invocation requested by the model (OpenAI wire shape).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolCall {
    pub id: String,
    #[serde(rename = "type", default = "function_call_type")]
    pub kind: String,
    pub function: ToolCallFunction,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolCallFunction {
    pub name: String,
    /// JSON-encoded arguments, as OpenAI emits them.
    #[serde(default)]
    pub arguments: String,
}

fn function_call_type() -> String {
    "function".to_string()
}

/// Accept `"text"`, `null`, or `[{"type":"text","text":...}, ...]` for message content.
fn content_as_string<'de, D>(de: D) -> std::result::Result<String, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = serde_json::Value::deserialize(de)?;
    Ok(match value {
        serde_json::Value::String(s) => s,
        serde_json::Value::Null => String::new(),
        serde_json::Value::Array(parts) => parts
            .iter()
            .filter_map(|p| p["text"].as_str())
            .collect::<Vec<_>>()
            .join(""),
        other => other.to_string(),
    })
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatResponse {
    pub model: String,
    pub content: String,
    /// Tool calls the model wants executed (only when the request offered tools).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<Vec<ToolCall>>,
    pub usage: Usage,
}

/// A single vision/multimodal request.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VisionRequest {
    pub model: String,
    pub prompt: String,
    /// base64-encoded image(s).
    pub images: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VisionResponse {
    pub model: String,
    pub content: String,
    pub usage: Usage,
}

/// Token/unit usage for a single call.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Usage {
    pub input_tokens: u64,
    pub output_tokens: u64,
    #[serde(default)]
    pub image_units: u64,
    #[serde(default)]
    pub audio_units: u64,
}

/// Estimated cost of some usage.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CostEstimate {
    pub usd: f64,
}

/// A leased job from the coordinator. Mirrors `proto/job.schema.json`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Job {
    pub job_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lease_id: Option<String>,
    pub capability: String,
    pub privacy: PrivacyLevel,
    #[serde(default)]
    pub allow_external_providers: bool,
    /// Capability-specific input (e.g. `{ "messages": [...], "max_tokens": 256 }`).
    pub payload: serde_json::Value,
}

/// Status of a finished job.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JobStatus {
    Ok,
    Rejected,
    Error,
}

/// Result returned to the coordinator. Mirrors `proto/job_result.schema.json`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JobResult {
    pub job_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lease_id: Option<String>,
    pub status: JobStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usage: Option<ResultUsage>,
}

/// One streamed content fragment of a running job. Mirrors `proto/job_result_chunk.schema.json`.
/// Best-effort UX: the final [`JobResult`] remains the authoritative output.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JobResultChunk {
    pub job_id: String,
    /// Monotonic per-job counter, starting at 0.
    pub seq: u64,
    /// Text fragment, in generation order.
    pub delta: String,
    /// True when this fragment is model reasoning/thinking rather than answer content.
    /// Defaults false so an older coordinator/worker (no field) reads it as content.
    #[serde(default)]
    pub reasoning: bool,
}

/// Per-job usage attached to a result. No secrets.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResultUsage {
    pub provider: String,
    pub model: String,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub latency_ms: f64,
}
