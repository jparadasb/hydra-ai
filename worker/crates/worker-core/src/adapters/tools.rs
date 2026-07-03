//! Shared helpers for translating OpenAI-shaped tool definitions / calls into the wire
//! formats of providers that don't speak the OpenAI schema (Anthropic, Gemini, Responses).
//!
//! The normalized [`crate::types::ChatRequest`] carries tools exactly as an OpenAI client
//! sent them: `tools: [{"type":"function","function":{name,description,parameters}}]` and
//! `tool_choice: "auto" | "none" | "required" | {"type":"function","function":{"name":..}}`.

use serde_json::Value;

/// One function definition pulled out of an OpenAI `tools` array.
pub(crate) struct FunctionDef<'a> {
    pub name: &'a str,
    pub description: Option<&'a str>,
    pub parameters: Option<&'a Value>,
}

/// Extract the function entries from an OpenAI-shaped `tools` array, skipping anything
/// malformed or non-function.
pub(crate) fn function_defs(tools: &Value) -> Vec<FunctionDef<'_>> {
    tools
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|t| {
                    let f = t.get("function")?;
                    Some(FunctionDef {
                        name: f.get("name")?.as_str()?,
                        description: f.get("description").and_then(Value::as_str),
                        parameters: f.get("parameters"),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Parse an OpenAI tool-call `arguments` JSON string; malformed input becomes `{}` so a
/// slightly-off model reply degrades to an empty call instead of a hard error.
pub(crate) fn parse_arguments(arguments: &str) -> Value {
    serde_json::from_str(arguments).unwrap_or_else(|_| serde_json::json!({}))
}

/// The function name when `tool_choice` forces one specific tool, else `None`.
pub(crate) fn forced_function_name(tool_choice: &Value) -> Option<&str> {
    tool_choice.get("function")?.get("name")?.as_str()
}
